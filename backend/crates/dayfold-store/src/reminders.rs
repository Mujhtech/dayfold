use crate::{
    Reminder, Result, Store, StoreError,
    store::{
        MAX_ACTIVE_REMINDERS, MAX_INBOX, MAX_REMINDERS, domain_error, insert_notification,
        lock_device, timestamp, validate_batch,
    },
};
use chrono::{DateTime, Utc};
use dayfold_domain::{NotificationKind, PutReminder};
use sqlx::{FromRow, Postgres, Transaction};
use uuid::Uuid;

#[derive(FromRow)]
struct ReminderRow {
    revision: i64,
    due_at: Option<DateTime<Utc>>,
    expires_at: Option<DateTime<Utc>>,
    deleted_at: Option<DateTime<Utc>>,
}

impl Store {
    pub async fn put_reminder(
        &self,
        device_id: Uuid,
        id: Uuid,
        revision: i64,
        due_at: DateTime<Utc>,
        expires_at: DateTime<Utc>,
    ) -> Result<Reminder> {
        PutReminder {
            revision,
            due_at,
            expires_at,
        }
        .validate(Utc::now())
        .map_err(domain_error)?;
        let due_at = timestamp(due_at);
        let expires_at = timestamp(expires_at);
        let mut tx = self.pool.begin().await?;
        lock_device(&mut tx, device_id).await?;
        let existing = sqlx::query_as::<_, ReminderRow>("SELECT revision, due_at, expires_at, deleted_at FROM reminders WHERE device_id = $1 AND id = $2 FOR UPDATE")
            .bind(device_id).bind(id).fetch_optional(&mut *tx).await?;
        if let Some(existing) = &existing {
            if revision < existing.revision
                || (revision == existing.revision
                    && (existing.deleted_at.is_some()
                        || existing.due_at != Some(due_at)
                        || existing.expires_at != Some(expires_at)))
            {
                return Err(StoreError::Conflict);
            }
            if revision == existing.revision {
                tx.commit().await?;
                return Ok(Reminder {
                    id,
                    revision,
                    due_at,
                    expires_at,
                });
            }
        }
        if existing.is_none() {
            check_total_quota(&mut tx, device_id).await?;
        }
        if existing
            .as_ref()
            .is_none_or(|r| r.deleted_at.is_some() || r.expires_at.is_none_or(|e| e <= Utc::now()))
        {
            let (active,): (i64,) = sqlx::query_as("SELECT count(*) FROM reminders WHERE device_id = $1 AND deleted_at IS NULL AND expires_at > clock_timestamp()")
                .bind(device_id).fetch_one(&mut *tx).await?;
            if active >= MAX_ACTIVE_REMINDERS {
                return Err(StoreError::Capacity);
            }
        }
        cancel_deliveries(&mut tx, device_id, id).await?;
        sqlx::query("INSERT INTO reminders (device_id, id, revision, due_at, expires_at) VALUES ($1, $2, $3, $4, $5) ON CONFLICT (device_id, id) DO UPDATE SET revision = EXCLUDED.revision, due_at = EXCLUDED.due_at, expires_at = EXCLUDED.expires_at, deleted_at = NULL, materialized_revision = NULL, updated_at = now()")
            .bind(device_id).bind(id).bind(revision).bind(due_at).bind(expires_at).execute(&mut *tx).await?;
        tx.commit().await?;
        Ok(Reminder {
            id,
            revision,
            due_at,
            expires_at,
        })
    }

    pub async fn delete_reminder(&self, device_id: Uuid, id: Uuid, revision: i64) -> Result<()> {
        if revision <= 0 {
            return Err(StoreError::Invalid("revision must be positive"));
        }
        let mut tx = self.pool.begin().await?;
        lock_device(&mut tx, device_id).await?;
        let existing = sqlx::query_as::<_, ReminderRow>("SELECT revision, due_at, expires_at, deleted_at FROM reminders WHERE device_id = $1 AND id = $2 FOR UPDATE")
            .bind(device_id).bind(id).fetch_optional(&mut *tx).await?;
        if let Some(existing) = &existing {
            if revision < existing.revision
                || (revision == existing.revision && existing.deleted_at.is_none())
            {
                return Err(StoreError::Conflict);
            }
            if revision == existing.revision {
                tx.commit().await?;
                return Ok(());
            }
        } else {
            check_total_quota(&mut tx, device_id).await?;
        }
        cancel_deliveries(&mut tx, device_id, id).await?;
        sqlx::query("INSERT INTO reminders (device_id, id, revision, deleted_at) VALUES ($1, $2, $3, now()) ON CONFLICT (device_id, id) DO UPDATE SET revision = EXCLUDED.revision, due_at = NULL, expires_at = NULL, deleted_at = now(), materialized_revision = NULL, updated_at = now()")
            .bind(device_id).bind(id).bind(revision).execute(&mut *tx).await?;
        tx.commit().await?;
        Ok(())
    }

    pub async fn materialize_due(&self, limit: i64) -> Result<u64> {
        validate_batch(limit)?;
        let mut tx = self.pool.begin().await?;
        // Filter capacity before LIMIT so a full installation cannot monopolize
        // every batch. Retention cleanup releases its eligible inbox prefixes.
        let devices: Vec<(Uuid,)> = sqlx::query_as(
            "SELECT d.id FROM devices d WHERE d.revoked_at IS NULL AND (d.user_id IS NULL OR EXISTS(SELECT 1 FROM auth_families f WHERE f.device_id=d.id AND f.revoked_at IS NULL AND f.refresh_expires_at > clock_timestamp() AND f.absolute_expires_at > clock_timestamp())) AND EXISTS \
             (SELECT 1 FROM reminders r WHERE r.device_id = d.id AND r.deleted_at IS NULL AND r.materialized_revision IS NULL AND r.due_at <= now() AND r.expires_at > clock_timestamp()) \
             AND (SELECT count(*) FROM notifications n WHERE n.device_id = d.id) < $2 \
             ORDER BY d.id LIMIT $1 FOR UPDATE OF d SKIP LOCKED")
            .bind(limit.min(100)).bind(MAX_INBOX).fetch_all(&mut *tx).await?;
        let mut count = 0;
        for (device_id,) in devices {
            if count >= limit as u64 {
                break;
            }
            let reminders = sqlx::query_as::<_, Reminder>(
                "SELECT id, revision, due_at, expires_at FROM reminders WHERE device_id = $1 AND deleted_at IS NULL AND materialized_revision IS NULL AND due_at <= now() AND expires_at > clock_timestamp() ORDER BY due_at, id LIMIT $2 FOR UPDATE SKIP LOCKED")
                .bind(device_id).bind(limit - count as i64).fetch_all(&mut *tx).await?;
            for reminder in reminders {
                match insert_notification(
                    &mut tx,
                    device_id,
                    NotificationKind::ReminderDue,
                    reminder.id,
                    reminder.expires_at,
                    Some(reminder.revision),
                )
                .await
                {
                    Ok(_) => {}
                    Err(StoreError::Capacity) => break, // Full inbox: retain the due schedule for a later pass.
                    Err(error) => return Err(error),
                }
                sqlx::query("UPDATE reminders SET materialized_revision = revision, updated_at = now() WHERE device_id = $1 AND id = $2")
                    .bind(device_id).bind(reminder.id).execute(&mut *tx).await?;
                count += 1;
            }
        }
        tx.commit().await?;
        Ok(count)
    }
}

async fn check_total_quota(tx: &mut Transaction<'_, Postgres>, device_id: Uuid) -> Result<()> {
    let (count,): (i64,) = sqlx::query_as("SELECT count(*) FROM reminders WHERE device_id = $1")
        .bind(device_id)
        .fetch_one(&mut **tx)
        .await?;
    if count >= MAX_REMINDERS {
        return Err(StoreError::Capacity);
    }
    Ok(())
}

async fn cancel_deliveries(
    tx: &mut Transaction<'_, Postgres>,
    device_id: Uuid,
    reminder_id: Uuid,
) -> Result<()> {
    sqlx::query("UPDATE notifications SET cancelled_at = COALESCE(cancelled_at, now()) WHERE device_id = $1 AND reminder_id = $2")
        .bind(device_id).bind(reminder_id).execute(&mut **tx).await?;
    sqlx::query("UPDATE push_outbox p SET status = 'cancelled', lease_id = NULL, lease_until = NULL, claimed_token = NULL, updated_at = now() FROM notifications n WHERE p.device_id = $1 AND p.notification_id = n.id AND n.device_id = p.device_id AND n.reminder_id = $2 AND p.status IN ('pending', 'leased')")
        .bind(device_id).bind(reminder_id).execute(&mut **tx).await?;
    Ok(())
}
