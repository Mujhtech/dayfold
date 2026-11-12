use chrono::{DateTime, Utc};
use dayfold_domain::{Notification, PushEnvironment};
use serde::Serialize;
use sqlx::FromRow;
use uuid::Uuid;

pub type Result<T> = std::result::Result<T, StoreError>;

#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    #[error("installation or channel credentials are invalid")]
    Unauthorized,
    #[error("sign in again to recover the device session")]
    ReauthenticationRequired,
    #[error("this rotation was superseded by a newer credential")]
    RotationSuperseded,
    #[error("resource not found")]
    NotFound,
    #[error("conflicting version or resource binding")]
    Conflict,
    #[error("notification relay capacity is exhausted")]
    Capacity,
    #[error("{0}")]
    Invalid(&'static str),
    #[error("database operation failed")]
    Database(#[from] sqlx::Error),
}

#[derive(Debug, Clone, FromRow, Serialize)]
pub struct Device {
    pub id: Uuid,
    pub created_at: DateTime<Utc>,
    pub acknowledged_sequence: i64,
}

#[derive(Debug, Clone, FromRow, Serialize)]
pub struct Channel {
    pub id: Uuid,
    pub scope_id: Uuid,
    pub resource_id: Option<String>,
    pub expires_at: DateTime<Utc>,
    pub activated_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, FromRow, Serialize)]
pub struct Reminder {
    pub id: Uuid,
    pub revision: i64,
    pub due_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize)]
pub struct WebhookOutcome {
    pub duplicate: bool,
    pub notification: Option<Notification>,
}

#[derive(Debug, Clone, Serialize)]
pub struct NotificationPage {
    pub notifications: Vec<Notification>,
    /// Requests older than this cursor must resynchronize before replaying.
    pub cursor_floor: i64,
    pub latest_sequence: i64,
    pub reset_required: bool,
}

#[derive(Clone)]
pub struct ClaimedPush {
    pub id: Uuid,
    /// A fresh fencing token for every claim, including expired-lease recovery.
    pub lease_id: Uuid,
    /// Starts at one; claim attempts count toward the configured delivery limit.
    pub attempt: i32,
    pub device_id: Uuid,
    pub token: String,
    pub environment: PushEnvironment,
    pub notification: Notification,
}

impl std::fmt::Debug for ClaimedPush {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ClaimedPush")
            .field("id", &self.id)
            .field("lease_id", &self.lease_id)
            .field("attempt", &self.attempt)
            .field("device_id", &self.device_id)
            .field("token", &"[REDACTED]")
            .field("environment", &self.environment)
            .field("notification", &self.notification)
            .finish()
    }
}

#[derive(FromRow)]
pub(crate) struct DeviceRow {
    pub id: Uuid,
    pub last_sequence: i64,
    pub acknowledged_sequence: i64,
    pub cursor_floor: i64,
    pub revoked_at: Option<DateTime<Utc>>,
    pub apns_token: Option<String>,
    pub apns_environment: Option<String>,
    pub push_revision: i64,
    pub push_registered_at: Option<DateTime<Utc>>,
}

#[derive(FromRow)]
pub(crate) struct NotificationRow {
    pub sequence: i64,
    pub id: Uuid,
    pub kind: String,
    pub subject_id: Uuid,
    pub revision: Option<i64>,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
}

impl TryFrom<NotificationRow> for Notification {
    type Error = StoreError;

    fn try_from(row: NotificationRow) -> Result<Self> {
        Ok(Self {
            sequence: row.sequence,
            id: row.id,
            kind: row
                .kind
                .parse()
                .map_err(|_| StoreError::Invalid("invalid stored notification kind"))?,
            subject_id: row.subject_id,
            revision: row.revision,
            created_at: row.created_at,
            expires_at: row.expires_at,
        })
    }
}
