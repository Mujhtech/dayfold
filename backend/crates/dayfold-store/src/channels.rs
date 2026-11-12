use crate::{
    Channel, Result, Store, StoreError, WebhookOutcome,
    store::{
        MAX_CHANNELS, domain_error, insert_notification, lock_device, timestamp, validate_hash,
        write_error,
    },
};
use chrono::{DateTime, TimeDelta, Utc};
use dayfold_domain::{NotificationKind, validate_channel_expiration, validate_resource_id};
use uuid::Uuid;

impl Store {
    /// Authenticate before allocating a public webhook rate-limit bucket. The
    /// mutation below repeats authentication under locks to close revocation races.
    pub async fn authenticate_channel(&self, channel_id: Uuid, token_hash: &str) -> Result<()> {
        validate_hash(token_hash).map_err(|_| StoreError::Unauthorized)?;
        let (valid,): (bool,) = sqlx::query_as("SELECT EXISTS(SELECT 1 FROM channels c JOIN devices d ON d.id = c.device_id WHERE c.id = $1 AND c.token_hash = $2 AND c.revoked_at IS NULL AND c.expires_at > clock_timestamp() AND d.revoked_at IS NULL)")
            .bind(channel_id).bind(token_hash).fetch_one(&self.pool).await?;
        if !valid {
            return Err(StoreError::Unauthorized);
        }
        Ok(())
    }

    pub async fn reserve_channel(
        &self,
        device_id: Uuid,
        channel_id: Uuid,
        token_hash: &str,
        scope_id: Uuid,
        expires_at: DateTime<Utc>,
    ) -> Result<Channel> {
        validate_hash(token_hash)?;
        validate_channel_expiration(expires_at, Utc::now()).map_err(domain_error)?;
        let mut tx = self.pool.begin().await?;
        lock_device(&mut tx, device_id).await?;
        let (count,): (i64,) = sqlx::query_as("SELECT count(*) FROM channels WHERE device_id = $1 AND revoked_at IS NULL AND expires_at > clock_timestamp()")
            .bind(device_id).fetch_one(&mut *tx).await?;
        if count >= MAX_CHANNELS {
            return Err(StoreError::Capacity);
        }
        let channel = sqlx::query_as("INSERT INTO channels (id, device_id, token_hash, scope_id, expires_at) VALUES ($1, $2, $3, $4, $5) RETURNING id, scope_id, resource_id, expires_at, activated_at")
            .bind(channel_id).bind(device_id).bind(token_hash).bind(scope_id).bind(timestamp(expires_at))
            .fetch_one(&mut *tx).await.map_err(write_error)?;
        tx.commit().await?;
        Ok(channel)
    }

    pub async fn activate_channel(
        &self,
        device_id: Uuid,
        channel_id: Uuid,
        resource_id: &str,
        expires_at: DateTime<Utc>,
    ) -> Result<Channel> {
        validate_resource_id(resource_id).map_err(domain_error)?;
        validate_channel_expiration(expires_at, Utc::now()).map_err(domain_error)?;
        let mut tx = self.pool.begin().await?;
        lock_device(&mut tx, device_id).await?;
        let channel = sqlx::query_as::<_, Channel>("SELECT id, scope_id, resource_id, expires_at, activated_at FROM channels WHERE id = $1 AND device_id = $2 AND revoked_at IS NULL AND expires_at > clock_timestamp() FOR UPDATE")
            .bind(channel_id).bind(device_id).fetch_optional(&mut *tx).await?.ok_or(StoreError::NotFound)?;
        if channel
            .resource_id
            .as_deref()
            .is_some_and(|bound| bound != resource_id)
        {
            return Err(StoreError::Conflict);
        }
        let channel = sqlx::query_as("UPDATE channels SET resource_id = $2, activated_at = COALESCE(activated_at, now()), expires_at = LEAST(expires_at, $3) WHERE id = $1 RETURNING id, scope_id, resource_id, expires_at, activated_at")
            .bind(channel_id).bind(resource_id).bind(timestamp(expires_at)).fetch_one(&mut *tx).await?;
        tx.commit().await?;
        Ok(channel)
    }

    pub async fn revoke_channel(&self, device_id: Uuid, channel_id: Uuid) -> Result<()> {
        let mut tx = self.pool.begin().await?;
        lock_device(&mut tx, device_id).await?;
        let result = sqlx::query("UPDATE channels SET revoked_at = COALESCE(revoked_at, now()) WHERE id = $1 AND device_id = $2")
            .bind(channel_id).bind(device_id).execute(&mut *tx).await?;
        if result.rows_affected() == 0 {
            return Err(StoreError::NotFound);
        }
        tx.commit().await?;
        Ok(())
    }

    pub async fn accept_webhook(
        &self,
        channel_id: Uuid,
        token_hash: &str,
        resource_id: &str,
        state: &str,
        message_number: &str,
    ) -> Result<WebhookOutcome> {
        validate_hash(token_hash).map_err(|_| StoreError::Unauthorized)?;
        validate_resource_id(resource_id).map_err(domain_error)?;
        if !matches!(state, "sync" | "exists" | "not_exists") {
            return Err(StoreError::Invalid("unsupported Google resource state"));
        }
        if message_number.is_empty() || !message_number.bytes().all(|c| c.is_ascii_digit()) {
            return Err(StoreError::Invalid(
                "message number must be an unsigned 64-bit integer",
            ));
        }
        let message_number = message_number
            .parse::<u64>()
            .map_err(|_| StoreError::Invalid("message number must be an unsigned 64-bit integer"))?
            .to_string();
        // Resolve ownership without taking a channel lock first. Every mutation
        // locks the installation before its children, preventing lock inversion.
        let (device_id,): (Uuid,) = sqlx::query_as("SELECT device_id FROM channels WHERE id = $1 AND token_hash = $2 AND revoked_at IS NULL AND expires_at > clock_timestamp()")
            .bind(channel_id).bind(token_hash).fetch_optional(&self.pool).await?.ok_or(StoreError::Unauthorized)?;
        let mut tx = self.pool.begin().await?;
        lock_device(&mut tx, device_id).await?;
        let channel = sqlx::query_as::<_, Channel>("SELECT id, scope_id, resource_id, expires_at, activated_at FROM channels WHERE id = $1 AND token_hash = $2 AND revoked_at IS NULL AND expires_at > clock_timestamp() FOR UPDATE")
            .bind(channel_id).bind(token_hash).fetch_optional(&mut *tx).await?.ok_or(StoreError::Unauthorized)?;
        if channel
            .resource_id
            .as_deref()
            .is_some_and(|bound| bound != resource_id)
        {
            return Err(StoreError::Conflict);
        }
        if channel.resource_id.is_none() {
            sqlx::query("UPDATE channels SET resource_id = $2 WHERE id = $1")
                .bind(channel_id)
                .bind(resource_id)
                .execute(&mut *tx)
                .await?;
        }
        let inserted = sqlx::query("INSERT INTO webhook_receipts (channel_id, message_number) VALUES ($1, $2) ON CONFLICT DO NOTHING")
            .bind(channel_id).bind(&message_number).execute(&mut *tx).await?.rows_affected() > 0;
        let notification = if inserted {
            let accepted = sqlx::query("UPDATE channels SET accepted_messages = accepted_messages + 1 WHERE id = $1 AND accepted_messages < 100000")
                .bind(channel_id).execute(&mut *tx).await?.rows_affected();
            if accepted == 0 {
                return Err(StoreError::Capacity);
            }
            Some(
                insert_notification(
                    &mut tx,
                    device_id,
                    NotificationKind::CalendarChanged,
                    channel.scope_id,
                    Utc::now() + TimeDelta::days(1),
                    None,
                )
                .await?,
            )
        } else {
            None
        };
        tx.commit().await?;
        Ok(WebhookOutcome {
            duplicate: !inserted,
            notification,
        })
    }
}
