use crate::{DeviceRow, NotificationRow, Result, StoreError};
use chrono::{DateTime, Utc};
use dayfold_domain::{DomainError, Notification, NotificationKind};
use sqlx::{PgPool, Postgres, Transaction, postgres::PgPoolOptions};
use std::{sync::Arc, time::Duration};
use uuid::Uuid;

pub(crate) const MAX_CHANNELS: i64 = 128;
pub(crate) const MAX_REMINDERS: i64 = 10_000;
pub(crate) const MAX_ACTIVE_REMINDERS: i64 = 1_000;
pub(crate) const MAX_INBOX: i64 = 10_000;

#[derive(Clone)]
pub struct Store {
    pub(crate) pool: PgPool,
    pub(crate) session_key: Option<Arc<crate::SessionKey>>,
}

impl Store {
    pub fn new(pool: PgPool) -> Self {
        Self {
            pool,
            session_key: None,
        }
    }

    /// All API/worker clones must share a persistent deployment key. No key is
    /// generated implicitly on restart, and legacy provisioning never enables it.
    pub fn with_session_key(mut self, key: crate::SessionKey) -> Self {
        self.session_key = Some(Arc::new(key));
        self
    }

    pub async fn connect(database_url: &str, max_connections: u32) -> Result<Self> {
        if !(1..=100).contains(&max_connections) {
            return Err(StoreError::Invalid(
                "database pool must have 1 to 100 connections",
            ));
        }
        let pool = PgPoolOptions::new()
            .max_connections(max_connections)
            .acquire_timeout(Duration::from_secs(5))
            .after_connect(|connection, _| {
                Box::pin(async move {
                    sqlx::query("SET statement_timeout = '10s'")
                        .execute(&mut *connection)
                        .await?;
                    sqlx::query("SET lock_timeout = '5s'")
                        .execute(&mut *connection)
                        .await?;
                    Ok(())
                })
            })
            .connect(database_url)
            .await?;
        Ok(Self::new(pool))
    }

    pub async fn migrate(&self) -> Result<()> {
        sqlx::migrate!("./migrations")
            .run(&self.pool)
            .await
            .map_err(|error| StoreError::Database(sqlx::Error::Migrate(Box::new(error))))
    }

    pub async fn health(&self) -> Result<()> {
        sqlx::query("SELECT 1").execute(&self.pool).await?;
        Ok(())
    }
}

pub(crate) async fn lock_device(tx: &mut Transaction<'_, Postgres>, id: Uuid) -> Result<DeviceRow> {
    let row = sqlx::query_as::<_, DeviceRow>(
        "SELECT id, last_sequence, acknowledged_sequence, cursor_floor, revoked_at, apns_token, apns_environment, push_revision, push_registered_at FROM devices d WHERE id = $1 AND (d.user_id IS NULL OR EXISTS(SELECT 1 FROM auth_families f WHERE f.device_id=d.id AND f.revoked_at IS NULL AND f.refresh_expires_at > clock_timestamp() AND f.absolute_expires_at > clock_timestamp())) FOR UPDATE"
    )
    .bind(id)
    .fetch_optional(&mut **tx)
    .await?
    .ok_or(StoreError::Unauthorized)?;
    if row.revoked_at.is_some() {
        return Err(StoreError::Unauthorized);
    }
    Ok(row)
}

pub(crate) fn validate_hash(hash: &str) -> Result<()> {
    if hash.len() != 64
        || !hash
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
    {
        return Err(StoreError::Invalid("expected a lowercase SHA-256 digest"));
    }
    Ok(())
}

pub(crate) fn domain_error(error: DomainError) -> StoreError {
    match error {
        DomainError::Validation(message) => StoreError::Invalid(message),
        DomainError::RandomUnavailable => StoreError::Invalid("random generation unavailable"),
    }
}

pub(crate) fn write_error(error: sqlx::Error) -> StoreError {
    if error
        .as_database_error()
        .is_some_and(|error| error.is_unique_violation())
    {
        StoreError::Conflict
    } else {
        StoreError::Database(error)
    }
}

pub(crate) fn validate_batch(limit: i64) -> Result<()> {
    if !(1..=1000).contains(&limit) {
        return Err(StoreError::Invalid("batch size must be between 1 and 1000"));
    }
    Ok(())
}

// PostgreSQL stores microseconds. Canonicalize before comparing idempotent writes.
pub(crate) fn timestamp(value: DateTime<Utc>) -> DateTime<Utc> {
    DateTime::from_timestamp_micros(value.timestamp_micros()).unwrap_or(value)
}

/// Caller holds the device row lock through commit. Sequence allocation therefore
/// follows commit order, unlike a PostgreSQL sequence/identity column.
pub(crate) async fn insert_notification(
    tx: &mut Transaction<'_, Postgres>,
    device_id: Uuid,
    kind: NotificationKind,
    subject_id: Uuid,
    expires_at: DateTime<Utc>,
    reminder_revision: Option<i64>,
) -> Result<Notification> {
    let count: (i64,) = sqlx::query_as("SELECT count(*) FROM notifications WHERE device_id = $1")
        .bind(device_id)
        .fetch_one(&mut **tx)
        .await?;
    if count.0 >= MAX_INBOX {
        crate::inbox::prune_prefix(tx, device_id, MAX_INBOX).await?;
        let remaining: (i64,) =
            sqlx::query_as("SELECT count(*) FROM notifications WHERE device_id = $1")
                .bind(device_id)
                .fetch_one(&mut **tx)
                .await?;
        if remaining.0 >= MAX_INBOX {
            return Err(StoreError::Capacity);
        }
    }
    let (sequence,): (i64,) = sqlx::query_as("UPDATE devices SET last_sequence = last_sequence + 1 WHERE id = $1 RETURNING last_sequence")
        .bind(device_id).fetch_one(&mut **tx).await?;
    let id = Uuid::new_v4();
    let row = sqlx::query_as::<_, NotificationRow>(
        "INSERT INTO notifications (device_id, sequence, id, kind, subject_id, expires_at, reminder_id, reminder_revision) \
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8) \
         RETURNING sequence, id, kind, subject_id, reminder_revision AS revision, created_at, expires_at")
        .bind(device_id).bind(sequence).bind(id).bind(kind.as_str()).bind(subject_id).bind(expires_at)
        .bind(reminder_revision.map(|_| subject_id)).bind(reminder_revision)
        .fetch_one(&mut **tx).await?;
    // Give connected clients a chance to acknowledge over SSE before waking APNs.
    sqlx::query("INSERT INTO push_outbox (id, device_id, notification_id, available_at) VALUES ($1, $2, $3, now() + interval '5 seconds')")
        .bind(Uuid::new_v4()).bind(device_id).bind(id).execute(&mut **tx).await?;
    row.try_into()
}
