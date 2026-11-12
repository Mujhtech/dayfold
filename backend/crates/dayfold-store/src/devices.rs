use crate::{
    Device, Result, Store, StoreError,
    store::{domain_error, lock_device, validate_hash, write_error},
};
use dayfold_domain::{PushEnvironment, validate_push_token};
use sqlx::{Postgres, Transaction};
use uuid::Uuid;

impl Store {
    pub async fn provision(&self, device_id: Uuid, bearer_hash: &str) -> Result<Device> {
        validate_hash(bearer_hash)?;
        sqlx::query_as("INSERT INTO devices (id, bearer_hash) VALUES ($1, $2) RETURNING id, created_at, acknowledged_sequence")
            .bind(device_id).bind(bearer_hash).fetch_one(&self.pool).await.map_err(write_error)
    }

    pub async fn authenticate(&self, bearer_hash: &str) -> Result<Device> {
        validate_hash(bearer_hash).map_err(|_| StoreError::Unauthorized)?;
        sqlx::query_as("SELECT id, created_at, acknowledged_sequence FROM devices WHERE bearer_hash = $1 AND revoked_at IS NULL")
            .bind(bearer_hash).fetch_optional(&self.pool).await?
            .ok_or(StoreError::Unauthorized)
    }

    pub async fn revoke_device(&self, device_id: Uuid) -> Result<()> {
        let mut tx = self.pool.begin().await?;
        lock_device(&mut tx, device_id).await?;
        revoke_device_locked(&mut tx, device_id).await?;
        tx.commit().await?;
        Ok(())
    }

    pub async fn register_push(
        &self,
        device_id: Uuid,
        token: &str,
        environment: PushEnvironment,
    ) -> Result<()> {
        validate_push_token(token).map_err(domain_error)?;
        let mut tx = self.pool.begin().await?;
        lock_device(&mut tx, device_id).await?;
        // Increment even when APNs returns the same token: a new registration must
        // not be removed by an old in-flight Unregistered response.
        sqlx::query("UPDATE devices SET apns_token = $2, apns_environment = $3, push_revision = push_revision + 1, push_registered_at = clock_timestamp() WHERE id = $1")
            .bind(device_id).bind(token.to_ascii_lowercase()).bind(environment.as_str())
            .execute(&mut *tx).await.map_err(write_error)?;
        tx.commit().await?;
        Ok(())
    }
}

/// Caller holds the device row lock. Security revocation and ordinary logout
/// share this cleanup so inaccessible sessions cannot keep sending reminders.
pub(crate) async fn revoke_device_locked(
    tx: &mut Transaction<'_, Postgres>,
    device_id: Uuid,
) -> Result<()> {
    sqlx::query("UPDATE devices SET push_revision = push_revision + CASE WHEN revoked_at IS NULL THEN 1 ELSE 0 END, revoked_at = COALESCE(revoked_at, now()), apns_token = NULL, apns_environment = NULL, push_registered_at = NULL WHERE id = $1")
        .bind(device_id).execute(&mut **tx).await?;
    sqlx::query(
        "UPDATE auth_families SET revoked_at = COALESCE(revoked_at, now()) WHERE device_id = $1",
    )
    .bind(device_id)
    .execute(&mut **tx)
    .await?;
    sqlx::query(
        "UPDATE channels SET revoked_at = COALESCE(revoked_at, now()) WHERE device_id = $1",
    )
    .bind(device_id)
    .execute(&mut **tx)
    .await?;
    sqlx::query("UPDATE reminders SET deleted_at = COALESCE(deleted_at, now()), updated_at = now() WHERE device_id = $1")
        .bind(device_id).execute(&mut **tx).await?;
    sqlx::query("UPDATE notifications SET cancelled_at = COALESCE(cancelled_at, now()) WHERE device_id = $1")
        .bind(device_id).execute(&mut **tx).await?;
    sqlx::query("UPDATE push_outbox SET status = 'cancelled', lease_id = NULL, lease_until = NULL, claimed_token = NULL, updated_at = now() WHERE device_id = $1 AND status IN ('pending', 'leased')")
        .bind(device_id).execute(&mut **tx).await?;
    Ok(())
}
