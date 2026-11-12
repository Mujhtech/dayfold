use crate::{
    ClaimedPush, DeviceRow, NotificationRow, Result, Store, StoreError, store::lock_device,
};
use chrono::{DateTime, Utc};
use sqlx::{FromRow, Postgres, Transaction};
use uuid::Uuid;

#[derive(FromRow)]
struct ReadyPush {
    id: Uuid,
    notification_id: Uuid,
}

#[derive(FromRow)]
struct LeasedPush {
    notification_id: Uuid,
    attempts: i32,
    claimed_token: Option<String>,
    claimed_environment: Option<String>,
    claimed_push_revision: Option<i64>,
}

impl Store {
    /// Claims serialize with acknowledgement, schedule edits, and revocation via
    /// the device row. SKIP LOCKED lets multiple workers process other devices.
    pub async fn claim_pushes(
        &self,
        limit: i64,
        lease_seconds: i64,
        max_attempts: i32,
    ) -> Result<Vec<ClaimedPush>> {
        if !(1..=100).contains(&limit)
            || !(5..=300).contains(&lease_seconds)
            || !(1..=100).contains(&max_attempts)
        {
            return Err(StoreError::Invalid(
                "invalid push batch, lease, or attempt limit",
            ));
        }
        let mut tx = self.pool.begin().await?;
        let devices = sqlx::query_as::<_, DeviceRow>(
            "SELECT id, last_sequence, acknowledged_sequence, cursor_floor, revoked_at, apns_token, apns_environment, push_revision, push_registered_at FROM devices d WHERE d.revoked_at IS NULL AND d.apns_token IS NOT NULL AND (d.user_id IS NULL OR EXISTS(SELECT 1 FROM auth_families f WHERE f.device_id=d.id AND f.revoked_at IS NULL AND f.refresh_expires_at > clock_timestamp() AND f.absolute_expires_at > clock_timestamp())) AND EXISTS \
             (SELECT 1 FROM push_outbox p WHERE p.device_id = d.id AND ((p.status = 'pending' AND p.available_at <= now()) OR (p.status = 'leased' AND p.lease_until <= clock_timestamp()))) \
             ORDER BY d.id LIMIT $1 FOR UPDATE OF d SKIP LOCKED")
            .bind(limit).fetch_all(&mut *tx).await?;
        let mut claimed = Vec::new();
        for device in devices {
            if claimed.len() >= limit as usize {
                break;
            }
            sqlx::query("UPDATE push_outbox p SET status = 'cancelled', lease_id = NULL, lease_until = NULL, claimed_token = NULL, updated_at = now() FROM notifications n WHERE p.device_id = $1 AND n.device_id = p.device_id AND n.id = p.notification_id AND p.status IN ('pending', 'leased') AND (n.cancelled_at IS NOT NULL OR n.expires_at <= clock_timestamp() OR n.client_claimed OR (n.kind = 'calendar_changed' AND n.sequence <= $2))")
                .bind(device.id).bind(device.acknowledged_sequence).execute(&mut *tx).await?;
            sqlx::query("UPDATE push_outbox SET status = 'dead', lease_id = NULL, lease_until = NULL, claimed_token = NULL, updated_at = now() WHERE device_id = $1 AND attempts >= $2 AND (status = 'pending' OR (status = 'leased' AND lease_until <= clock_timestamp()))")
                .bind(device.id).bind(max_attempts).execute(&mut *tx).await?;
            let jobs = sqlx::query_as::<_, ReadyPush>(
                "SELECT p.id, p.notification_id FROM push_outbox p JOIN notifications n ON n.id = p.notification_id AND n.device_id = p.device_id \
                 WHERE p.device_id = $1 AND p.attempts < $2 AND n.expires_at > clock_timestamp() AND n.cancelled_at IS NULL AND NOT n.client_claimed AND (n.kind = 'reminder_due' OR n.sequence > $3) \
                 AND ((p.status = 'pending' AND p.available_at <= now()) OR (p.status = 'leased' AND p.lease_until <= clock_timestamp())) \
                 ORDER BY n.sequence LIMIT $4 FOR UPDATE OF p SKIP LOCKED")
                .bind(device.id).bind(max_attempts).bind(device.acknowledged_sequence).bind(limit - claimed.len() as i64)
                .fetch_all(&mut *tx).await?;
            let token = device
                .apns_token
                .as_deref()
                .ok_or(StoreError::Invalid("missing stored APNs token"))?;
            let environment = device
                .apns_environment
                .as_deref()
                .ok_or(StoreError::Invalid("missing stored APNs environment"))?
                .parse()
                .map_err(|_| StoreError::Invalid("invalid stored APNs environment"))?;
            for job in jobs {
                let lease_id = Uuid::new_v4();
                let (attempt,): (i32,) = sqlx::query_as("UPDATE push_outbox SET status = 'leased', attempts = attempts + 1, lease_id = $2, lease_until = clock_timestamp() + ($3 * interval '1 second'), claimed_token = $4, claimed_environment = $5, claimed_push_revision = $6, updated_at = now() WHERE id = $1 RETURNING attempts")
                    .bind(job.id).bind(lease_id).bind(lease_seconds as f64).bind(token).bind(device.apns_environment.as_deref()).bind(device.push_revision)
                    .fetch_one(&mut *tx).await?;
                let notification = sqlx::query_as::<_, NotificationRow>("SELECT sequence, id, kind, subject_id, reminder_revision AS revision, created_at, expires_at FROM notifications WHERE id = $1")
                    .bind(job.notification_id).fetch_one(&mut *tx).await?.try_into()?;
                claimed.push(ClaimedPush {
                    id: job.id,
                    lease_id,
                    attempt,
                    device_id: device.id,
                    token: token.to_owned(),
                    environment,
                    notification,
                });
            }
        }
        tx.commit().await?;
        Ok(claimed)
    }

    /// Recheck immediately before the HTTP request. An already in-flight network
    /// request cannot be recalled; clients must also check reminder revisions.
    pub async fn push_is_current(&self, job_id: Uuid, lease_id: Uuid) -> Result<bool> {
        let mut tx = self.pool.begin().await?;
        let Some((device, job)) = lease_context(&mut tx, job_id, lease_id).await? else {
            return Ok(false);
        };
        if !notification_is_live(&mut tx, &device, job.notification_id).await? {
            finish(&mut tx, job_id, "cancelled").await?;
            tx.commit().await?;
            return Ok(false);
        }
        if !registration_matches(&device, &job) {
            sqlx::query("UPDATE push_outbox SET status = 'pending', available_at = now(), lease_id = NULL, lease_until = NULL, claimed_token = NULL, updated_at = now() WHERE id = $1")
                .bind(job_id).execute(&mut *tx).await?;
            tx.commit().await?;
            return Ok(false);
        }
        tx.commit().await?;
        Ok(true)
    }

    pub async fn complete_push(&self, job_id: Uuid, lease_id: Uuid) -> Result<bool> {
        let mut tx = self.pool.begin().await?;
        let Some((device, job)) = lease_context(&mut tx, job_id, lease_id).await? else {
            return Ok(false);
        };
        let live = notification_is_live(&mut tx, &device, job.notification_id).await?;
        finish(&mut tx, job_id, if live { "sent" } else { "cancelled" }).await?;
        tx.commit().await?;
        Ok(live)
    }

    pub async fn retry_push(
        &self,
        job_id: Uuid,
        lease_id: Uuid,
        retry_at: DateTime<Utc>,
        max_attempts: i32,
    ) -> Result<bool> {
        if !(1..=100).contains(&max_attempts) {
            return Err(StoreError::Invalid("invalid push attempt limit"));
        }
        let mut tx = self.pool.begin().await?;
        let Some((device, job)) = lease_context(&mut tx, job_id, lease_id).await? else {
            return Ok(false);
        };
        if !notification_is_live(&mut tx, &device, job.notification_id).await? {
            finish(&mut tx, job_id, "cancelled").await?;
        } else {
            let (expires_at,): (DateTime<Utc>,) =
                sqlx::query_as("SELECT expires_at FROM notifications WHERE id = $1")
                    .bind(job.notification_id)
                    .fetch_one(&mut *tx)
                    .await?;
            if job.attempts >= max_attempts || retry_at >= expires_at {
                finish(&mut tx, job_id, "dead").await?;
            } else {
                sqlx::query("UPDATE push_outbox SET status = 'pending', available_at = GREATEST(now(), $2), lease_id = NULL, lease_until = NULL, claimed_token = NULL, updated_at = now() WHERE id = $1")
                    .bind(job_id).bind(retry_at).execute(&mut *tx).await?;
            }
        }
        tx.commit().await?;
        Ok(true)
    }

    pub async fn dead_push(&self, job_id: Uuid, lease_id: Uuid) -> Result<bool> {
        let mut tx = self.pool.begin().await?;
        if lease_context(&mut tx, job_id, lease_id).await?.is_none() {
            return Ok(false);
        }
        finish(&mut tx, job_id, "dead").await?;
        tx.commit().await?;
        Ok(true)
    }

    pub async fn invalidate_push_token(
        &self,
        job_id: Uuid,
        lease_id: Uuid,
        invalidated_at: Option<DateTime<Utc>>,
    ) -> Result<bool> {
        let mut tx = self.pool.begin().await?;
        let Some((device, job)) = lease_context(&mut tx, job_id, lease_id).await? else {
            return Ok(false);
        };
        let invalidates_registration = invalidated_at.is_none_or(|at| {
            device
                .push_registered_at
                .is_some_and(|registered| registered <= at)
        });
        if registration_matches(&device, &job) && invalidates_registration {
            sqlx::query("UPDATE devices SET apns_token = NULL, apns_environment = NULL, push_registered_at = NULL, push_revision = push_revision + 1 WHERE id = $1")
                .bind(device.id).execute(&mut *tx).await?;
            finish(&mut tx, job_id, "dead").await?;
        } else if notification_is_live(&mut tx, &device, job.notification_id).await?
            && device.apns_token.is_some()
        {
            // The failed request used an older registration. Keep the durable
            // notice eligible for delivery to the current registration.
            sqlx::query("UPDATE push_outbox SET status = 'pending', available_at = clock_timestamp(), lease_id = NULL, lease_until = NULL, claimed_token = NULL, updated_at = now() WHERE id = $1")
                .bind(job_id).execute(&mut *tx).await?;
        } else {
            finish(&mut tx, job_id, "dead").await?;
        }
        tx.commit().await?;
        Ok(true)
    }
}

async fn lease_context(
    tx: &mut Transaction<'_, Postgres>,
    job_id: Uuid,
    lease_id: Uuid,
) -> Result<Option<(DeviceRow, LeasedPush)>> {
    let Some((device_id,)): Option<(Uuid,)> =
        sqlx::query_as("SELECT device_id FROM push_outbox WHERE id = $1")
            .bind(job_id)
            .fetch_optional(&mut **tx)
            .await?
    else {
        return Ok(None);
    };
    let device = match lock_device(tx, device_id).await {
        Ok(device) => device,
        Err(StoreError::Unauthorized) => return Ok(None),
        Err(error) => return Err(error),
    };
    let job = sqlx::query_as::<_, LeasedPush>("SELECT notification_id, attempts, claimed_token, claimed_environment, claimed_push_revision FROM push_outbox WHERE id = $1 AND lease_id = $2 AND status = 'leased' AND lease_until > clock_timestamp() FOR UPDATE")
        .bind(job_id).bind(lease_id).fetch_optional(&mut **tx).await?;
    Ok(job.map(|job| (device, job)))
}

fn registration_matches(device: &DeviceRow, job: &LeasedPush) -> bool {
    device.apns_token.is_some()
        && device.apns_token == job.claimed_token
        && device.apns_environment == job.claimed_environment
        && job.claimed_push_revision == Some(device.push_revision)
}

async fn notification_is_live(
    tx: &mut Transaction<'_, Postgres>,
    device: &DeviceRow,
    notification_id: Uuid,
) -> Result<bool> {
    let (live,): (bool,) = sqlx::query_as("SELECT EXISTS(SELECT 1 FROM notifications WHERE id = $1 AND device_id = $2 AND (kind = 'reminder_due' OR sequence > $3) AND NOT client_claimed AND cancelled_at IS NULL AND expires_at > clock_timestamp())")
        .bind(notification_id).bind(device.id).bind(device.acknowledged_sequence).fetch_one(&mut **tx).await?;
    Ok(live)
}

async fn finish(tx: &mut Transaction<'_, Postgres>, job_id: Uuid, status: &str) -> Result<()> {
    sqlx::query("UPDATE push_outbox SET status = $2, lease_id = NULL, lease_until = NULL, claimed_token = NULL, updated_at = now() WHERE id = $1")
        .bind(job_id).bind(status).execute(&mut **tx).await?;
    Ok(())
}
