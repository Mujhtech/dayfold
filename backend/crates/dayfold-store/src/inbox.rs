use crate::{
    NotificationPage, NotificationRow, Result, Store, StoreError,
    store::{lock_device, validate_batch},
};
use sqlx::{Postgres, Transaction};
use uuid::Uuid;

impl Store {
    /// Chooses the local client as the sole presenter only before any APNs try.
    /// Retry after a lost claim response is safe while the notification is live.
    pub async fn claim_reminder(&self, device_id: Uuid, notification_id: Uuid) -> Result<bool> {
        let mut tx = self.pool.begin().await?;
        lock_device(&mut tx, device_id).await?;
        let existing: Option<(bool,)> = sqlx::query_as(
            "SELECT client_claimed FROM notifications WHERE device_id = $1 AND id = $2 \
             AND kind = 'reminder_due' AND cancelled_at IS NULL AND expires_at > clock_timestamp() FOR UPDATE")
            .bind(device_id).bind(notification_id).fetch_optional(&mut *tx).await?;
        let Some((already_claimed,)) = existing else {
            tx.commit().await?;
            return Ok(false);
        };
        if already_claimed {
            tx.commit().await?;
            return Ok(true);
        }
        let claimed = sqlx::query(
            "UPDATE push_outbox SET status = 'cancelled', lease_id = NULL, lease_until = NULL, \
             claimed_token = NULL, updated_at = now() \
             WHERE device_id = $1 AND notification_id = $2 AND status = 'pending' AND attempts = 0",
        )
        .bind(device_id)
        .bind(notification_id)
        .execute(&mut *tx)
        .await?
        .rows_affected()
            == 1;
        if claimed {
            sqlx::query(
                "UPDATE notifications SET client_claimed = true WHERE device_id = $1 AND id = $2",
            )
            .bind(device_id)
            .bind(notification_id)
            .execute(&mut *tx)
            .await?;
        }
        tx.commit().await?;
        Ok(claimed)
    }

    pub async fn cursor_bounds(&self, device_id: Uuid) -> Result<(i64, i64)> {
        let mut tx = self.pool.begin().await?;
        let device = lock_device(&mut tx, device_id).await?;
        tx.commit().await?;
        Ok((device.cursor_floor, device.last_sequence))
    }

    /// Reads never acknowledge. The device lock makes the retention boundary and
    /// page one consistent view, including concurrent producers and cleanup.
    pub async fn notifications(
        &self,
        device_id: Uuid,
        after: i64,
        limit: i64,
    ) -> Result<NotificationPage> {
        validate_batch(limit)?;
        let mut tx = self.pool.begin().await?;
        let device = lock_device(&mut tx, device_id).await?;
        if after < 0 || after > device.last_sequence {
            return Err(StoreError::Invalid(
                "cursor is outside the installation inbox",
            ));
        }
        let reset_required = after < device.cursor_floor;
        let notifications = if reset_required {
            vec![]
        } else {
            sqlx::query_as::<_, NotificationRow>(
                "SELECT sequence, id, kind, subject_id, reminder_revision AS revision, created_at, expires_at \
                 FROM notifications WHERE device_id = $1 AND sequence > $2 \
                 AND cancelled_at IS NULL AND expires_at > clock_timestamp() ORDER BY sequence LIMIT $3")
                .bind(device_id).bind(after).bind(limit).fetch_all(&mut *tx).await?
                .into_iter().map(TryInto::try_into).collect::<Result<Vec<_>>>()?
        };
        tx.commit().await?;
        Ok(NotificationPage {
            notifications,
            cursor_floor: device.cursor_floor,
            latest_sequence: device.last_sequence,
            reset_required,
        })
    }

    pub async fn acknowledge(&self, device_id: Uuid, sequence: i64) -> Result<()> {
        let mut tx = self.pool.begin().await?;
        let device = lock_device(&mut tx, device_id).await?;
        if sequence < 0 || sequence > device.last_sequence {
            return Err(StoreError::Invalid(
                "acknowledgement is outside the installation inbox",
            ));
        }
        sqlx::query("UPDATE devices SET acknowledged_sequence = GREATEST(acknowledged_sequence, $2) WHERE id = $1")
            .bind(device_id).bind(sequence).execute(&mut *tx).await?;
        // A cursor ack suppresses hints, but only a successful delivery claim can
        // transfer reminder responsibility away from APNs.
        sqlx::query("UPDATE push_outbox p SET status = 'cancelled', lease_id = NULL, lease_until = NULL, claimed_token = NULL, updated_at = now() FROM notifications n WHERE p.device_id = $1 AND n.device_id = p.device_id AND n.id = p.notification_id AND n.sequence <= $2 AND (n.kind = 'calendar_changed' OR n.client_claimed) AND p.status IN ('pending', 'leased')")
            .bind(device_id).bind(sequence).execute(&mut *tx).await?;
        tx.commit().await?;
        Ok(())
    }

    /// Removes bounded contiguous inbox prefixes and expired channels. A client
    /// behind the retained prefix receives reset_required rather than silent loss.
    /// Reminder tombstones remain until installation revocation to fence old PUTs.
    pub async fn cleanup(&self, limit: i64) -> Result<u64> {
        validate_batch(limit)?;
        self.cleanup_auth(limit).await?;
        let mut tx = self.pool.begin().await?;
        let devices: Vec<(Uuid,)> = sqlx::query_as(
            "SELECT d.id FROM devices d WHERE \
             EXISTS (SELECT 1 FROM notifications n WHERE n.device_id = d.id \
             AND n.sequence = (SELECT min(head.sequence) FROM notifications head WHERE head.device_id = d.id) \
             AND (n.expires_at <= clock_timestamp() OR n.cancelled_at IS NOT NULL \
             OR ((n.sequence <= d.acknowledged_sequence OR n.created_at <= now() - interval '7 days') \
             AND (n.kind = 'calendar_changed' OR n.client_claimed OR EXISTS \
             (SELECT 1 FROM push_outbox p WHERE p.notification_id = n.id AND p.status IN ('sent', 'dead', 'cancelled')))))) \
             OR EXISTS (SELECT 1 FROM channels c WHERE c.device_id = d.id AND (c.expires_at <= clock_timestamp() OR c.revoked_at IS NOT NULL)) \
             OR d.revoked_at <= now() - interval '7 days' \
             ORDER BY d.id LIMIT $1 FOR UPDATE OF d SKIP LOCKED")
            .bind(limit.min(100)).fetch_all(&mut *tx).await?;
        let mut removed = 0;
        for (device_id,) in devices {
            if removed >= limit as u64 {
                break;
            }
            let result = sqlx::query(
                "DELETE FROM devices WHERE id = $1 AND revoked_at <= now() - interval '7 days'",
            )
            .bind(device_id)
            .execute(&mut *tx)
            .await?;
            if result.rows_affected() > 0 {
                removed += 1;
                continue;
            }
            removed += prune_prefix(&mut tx, device_id, limit - removed as i64).await?;
            if removed >= limit as u64 {
                break;
            }
            removed += sqlx::query("DELETE FROM channels WHERE id IN (SELECT id FROM channels WHERE device_id = $1 AND (expires_at <= clock_timestamp() OR revoked_at IS NOT NULL) ORDER BY expires_at LIMIT $2 FOR UPDATE SKIP LOCKED)")
                .bind(device_id).bind(limit - removed as i64).execute(&mut *tx).await?.rows_affected();
        }
        tx.commit().await?;
        Ok(removed)
    }
}

pub(crate) async fn prune_prefix(
    tx: &mut Transaction<'_, Postgres>,
    device_id: Uuid,
    limit: i64,
) -> Result<u64> {
    let rows: Vec<(i64, bool)> = sqlx::query_as(
        "SELECT n.sequence, (n.expires_at <= clock_timestamp() OR n.cancelled_at IS NOT NULL \
         OR ((n.sequence <= d.acknowledged_sequence OR n.created_at <= now() - interval '7 days') \
         AND (n.kind = 'calendar_changed' OR n.client_claimed OR EXISTS \
         (SELECT 1 FROM push_outbox p WHERE p.notification_id = n.id AND p.status IN ('sent', 'dead', 'cancelled'))))) AS removable \
         FROM notifications n JOIN devices d ON d.id = n.device_id WHERE n.device_id = $1 ORDER BY n.sequence LIMIT $2")
        .bind(device_id).bind(limit).fetch_all(&mut **tx).await?;
    let mut floor = None;
    for (sequence, removable) in rows {
        if !removable {
            break;
        }
        floor = Some(sequence);
    }
    let Some(floor) = floor else {
        return Ok(0);
    };
    let removed = sqlx::query("DELETE FROM notifications WHERE device_id = $1 AND sequence <= $2")
        .bind(device_id)
        .bind(floor)
        .execute(&mut **tx)
        .await?
        .rows_affected();
    sqlx::query("UPDATE devices SET cursor_floor = GREATEST(cursor_floor, $2) WHERE id = $1")
        .bind(device_id)
        .bind(floor)
        .execute(&mut **tx)
        .await?;
    Ok(removed)
}
