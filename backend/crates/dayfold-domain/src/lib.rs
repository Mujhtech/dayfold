//! Transport-independent contracts for Dayfold's optional notification relay.
//!
//! Routing identifiers are random, opaque UUIDs. Calendar contents, Google access
//! tokens, and refresh tokens are deliberately absent from this protocol.

use chrono::{DateTime, TimeDelta, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{error::Error, fmt, str::FromStr};
use uuid::Uuid;

pub const MAX_CHANNEL_LIFETIME: TimeDelta = TimeDelta::days(30);
pub const MAX_RESOURCE_ID_BYTES: usize = 512;
pub const MIN_PUSH_TOKEN_CHARACTERS: usize = 32;
pub const MAX_PUSH_TOKEN_CHARACTERS: usize = 256;
pub const MAX_REMINDER_HORIZON: TimeDelta = TimeDelta::days(30);
pub const REMINDER_CLOCK_TOLERANCE: TimeDelta = TimeDelta::seconds(60);
pub const MAX_REMINDER_LIFETIME: TimeDelta = TimeDelta::days(1);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DomainError {
    Validation(&'static str),
    RandomUnavailable,
}

impl fmt::Display for DomainError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Validation(message) => f.write_str(message),
            Self::RandomUnavailable => f.write_str("secure random generation failed"),
        }
    }
}

impl Error for DomainError {}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PushEnvironment {
    Sandbox,
    Production,
}

impl PushEnvironment {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Sandbox => "sandbox",
            Self::Production => "production",
        }
    }
}

impl fmt::Display for PushEnvironment {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for PushEnvironment {
    type Err = DomainError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "sandbox" => Ok(Self::Sandbox),
            "production" => Ok(Self::Production),
            _ => Err(DomainError::Validation("invalid push environment")),
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum NotificationKind {
    CalendarChanged,
    ReminderDue,
}

impl NotificationKind {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::CalendarChanged => "calendar_changed",
            Self::ReminderDue => "reminder_due",
        }
    }
}

impl fmt::Display for NotificationKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for NotificationKind {
    type Err = DomainError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "calendar_changed" => Ok(Self::CalendarChanged),
            "reminder_due" => Ok(Self::ReminderDue),
            _ => Err(DomainError::Validation("invalid notification kind")),
        }
    }
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ReserveChannel {
    pub scope_id: Uuid,
    pub expires_at: DateTime<Utc>,
}

impl ReserveChannel {
    pub fn validate(&self, now: DateTime<Utc>) -> Result<(), DomainError> {
        validate_channel_expiration(self.expires_at, now)
    }
}

#[derive(Clone, Deserialize, Serialize)]
pub struct ChannelReservation {
    pub id: Uuid,
    pub token: String,
    pub address: String,
    pub expires_at: DateTime<Utc>,
}

impl fmt::Debug for ChannelReservation {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ChannelReservation")
            .field("id", &self.id)
            .field("token", &"[REDACTED]")
            .field("address", &self.address)
            .field("expires_at", &self.expires_at)
            .finish()
    }
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ActivateChannel {
    pub resource_id: String,
    pub expires_at: DateTime<Utc>,
}

impl ActivateChannel {
    pub fn validate(&self, now: DateTime<Utc>) -> Result<(), DomainError> {
        validate_resource_id(&self.resource_id)?;
        validate_channel_expiration(self.expires_at, now)
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct RegisterPush {
    pub token: String,
    pub environment: PushEnvironment,
}

impl RegisterPush {
    pub fn validate(&self, _now: DateTime<Utc>) -> Result<(), DomainError> {
        validate_push_token(&self.token)
    }
}

impl fmt::Debug for RegisterPush {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RegisterPush")
            .field("token", &"[REDACTED]")
            .field("environment", &self.environment)
            .finish()
    }
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct PutReminder {
    pub revision: i64,
    pub due_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
}

impl PutReminder {
    pub fn validate(&self, now: DateTime<Utc>) -> Result<(), DomainError> {
        if self.revision <= 0 {
            return Err(DomainError::Validation("revision must be positive"));
        }
        let delay = self.due_at.signed_duration_since(now);
        if delay < -REMINDER_CLOCK_TOLERANCE || delay > MAX_REMINDER_HORIZON {
            return Err(DomainError::Validation(
                "reminder due time must be within the next 30 days (60 seconds clock tolerance)",
            ));
        }
        let lifetime = self.expires_at.signed_duration_since(self.due_at);
        if lifetime <= TimeDelta::zero() || lifetime > MAX_REMINDER_LIFETIME {
            return Err(DomainError::Validation(
                "reminder expiration must be after its due time and within 24 hours",
            ));
        }
        if self.expires_at <= now {
            return Err(DomainError::Validation("reminder is already expired"));
        }
        Ok(())
    }
}

/// Cancellation is a versioned tombstone so a delayed upsert cannot resurrect
/// an older schedule. Reusing the reminder ID requires a higher revision.
#[derive(Debug, Clone, Copy, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DeleteReminder {
    pub revision: i64,
}

impl DeleteReminder {
    pub fn validate(&self, _now: DateTime<Utc>) -> Result<(), DomainError> {
        if self.revision <= 0 {
            return Err(DomainError::Validation("revision must be positive"));
        }
        Ok(())
    }
}

/// Acknowledges a contiguous prefix of this installation's notification inbox.
/// For reminders this advances replay only; taking local presentation ownership
/// requires the separate atomic notification claim endpoint.
#[derive(Debug, Clone, Copy, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Ack {
    pub sequence: i64,
}

impl Ack {
    pub fn validate(&self, _now: DateTime<Utc>) -> Result<(), DomainError> {
        if self.sequence < 0 {
            return Err(DomainError::Validation(
                "acknowledgement sequence must not be negative",
            ));
        }
        Ok(())
    }
}

/// A durable, replayable hint. `subject_id` is a scope or reminder UUID assigned
/// by the device, never a Google calendar address or event title.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct Notification {
    pub sequence: i64,
    pub id: Uuid,
    pub kind: NotificationKind,
    pub subject_id: Uuid,
    /// Reminder schedule revision, absent for calendar change hints. Clients
    /// compare this with their current local reminder before presenting it.
    pub revision: Option<i64>,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
}

pub fn validate_channel_expiration(
    expires_at: DateTime<Utc>,
    now: DateTime<Utc>,
) -> Result<(), DomainError> {
    let lifetime = expires_at.signed_duration_since(now);
    if lifetime <= TimeDelta::zero() || lifetime > MAX_CHANNEL_LIFETIME {
        return Err(DomainError::Validation(
            "channel expiration must be in the future and within 30 days",
        ));
    }
    Ok(())
}

pub fn validate_resource_id(resource_id: &str) -> Result<(), DomainError> {
    if resource_id.is_empty()
        || resource_id.len() > MAX_RESOURCE_ID_BYTES
        || !resource_id.is_ascii()
        || resource_id.bytes().any(|byte| byte.is_ascii_control())
    {
        return Err(DomainError::Validation(
            "resource ID must contain 1 to 512 ASCII bytes without control characters",
        ));
    }
    Ok(())
}

/// APNs token lengths can change; validate the wire representation, not a
/// historical fixed byte count.
pub fn validate_push_token(token: &str) -> Result<(), DomainError> {
    if !(MIN_PUSH_TOKEN_CHARACTERS..=MAX_PUSH_TOKEN_CHARACTERS).contains(&token.len())
        || !token.len().is_multiple_of(2)
        || !token.bytes().all(|byte| byte.is_ascii_hexdigit())
    {
        return Err(DomainError::Validation(
            "push token must be 32 to 256 hexadecimal characters with an even length",
        ));
    }
    Ok(())
}

/// Generates a 256-bit secret using the operating system's random generator.
/// Only the hash should be persisted; return the secret to its owner once.
pub fn generate_secret() -> Result<String, DomainError> {
    let mut bytes = [0u8; 32];
    getrandom::fill(&mut bytes).map_err(|_| DomainError::RandomUnavailable)?;
    Ok(hex(&bytes))
}

/// Hashes a high-entropy bearer/channel secret for storage. This is not a
/// password hashing function and must not be used for human-chosen passwords.
pub fn hash_secret(secret: &str) -> String {
    hex(&Sha256::digest(secret.as_bytes()))
}

fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        output.push(DIGITS[usize::from(byte >> 4)] as char);
        output.push(DIGITS[usize::from(byte & 0x0f)] as char);
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;

    fn now() -> DateTime<Utc> {
        DateTime::parse_from_rfc3339("2026-11-06T12:00:00Z")
            .unwrap()
            .with_timezone(&Utc)
    }

    #[test]
    fn reservation_accepts_boundary_but_rejects_expired_or_unbounded_watches() {
        assert!(validate_channel_expiration(now() + TimeDelta::days(30), now()).is_ok());
        assert!(validate_channel_expiration(now(), now()).is_err());
        assert!(validate_channel_expiration(now() - TimeDelta::seconds(1), now()).is_err());
        assert!(
            validate_channel_expiration(
                now() + TimeDelta::days(30) + TimeDelta::nanoseconds(1),
                now()
            )
            .is_err()
        );
    }

    #[test]
    fn push_tokens_allow_variable_lengths_but_not_path_or_header_injection() {
        for length in [32, 64, 128, 256] {
            assert!(validate_push_token(&"A0".repeat(length / 2)).is_ok());
        }
        for value in [
            "ab".repeat(15),
            "a".repeat(33),
            "ab".repeat(129),
            format!("{}\r\n", "ab".repeat(20)),
            format!("{}/../", "ab".repeat(20)),
        ] {
            assert!(validate_push_token(&value).is_err());
        }
    }

    #[test]
    fn reminders_bound_clock_skew_horizon_and_delivery_lifetime() {
        let mut reminder = PutReminder {
            revision: 1,
            due_at: now() - TimeDelta::seconds(60),
            expires_at: now() + TimeDelta::minutes(5),
        };
        assert!(reminder.validate(now()).is_ok());
        reminder.due_at -= TimeDelta::nanoseconds(1);
        assert!(reminder.validate(now()).is_err());
        reminder.due_at = now() + TimeDelta::days(30);
        reminder.expires_at = reminder.due_at + TimeDelta::days(1);
        assert!(reminder.validate(now()).is_ok());
        reminder.expires_at += TimeDelta::nanoseconds(1);
        assert!(reminder.validate(now()).is_err());
        reminder.expires_at = reminder.due_at;
        assert!(reminder.validate(now()).is_err());
        reminder.expires_at = reminder.due_at + TimeDelta::hours(1);
        reminder.revision = 0;
        assert!(reminder.validate(now()).is_err());
    }

    #[test]
    fn expired_reminders_are_rejected_within_clock_skew_allowance() {
        let reminder = PutReminder {
            revision: 1,
            due_at: now() - TimeDelta::seconds(50),
            expires_at: now() - TimeDelta::seconds(1),
        };
        assert!(reminder.validate(now()).is_err());
    }

    #[test]
    fn resource_ids_are_bounded_and_header_safe() {
        assert!(validate_resource_id("opaque-resource-_id").is_ok());
        assert!(validate_resource_id(&"a".repeat(512)).is_ok());
        for value in ["", "r\r\nInjected: x", "non-ascii-💡", "null\0id"] {
            assert!(validate_resource_id(value).is_err());
        }
        assert!(validate_resource_id(&"a".repeat(513)).is_err());
    }

    #[test]
    fn unknown_input_fields_and_enum_values_are_rejected() {
        assert!(serde_json::from_str::<PutReminder>(
            r#"{"revision":1,"due_at":"2026-11-06T12:00:00Z","expires_at":"2026-11-06T13:00:00Z","title":"should stay on device"}"#
        ).is_err());
        assert!(serde_json::from_str::<PushEnvironment>("\"staging\"").is_err());
        assert_eq!(
            serde_json::to_string(&NotificationKind::CalendarChanged).unwrap(),
            "\"calendar_changed\""
        );
    }

    #[test]
    fn diagnostics_redact_secrets_but_wire_serialization_preserves_them() {
        let request = RegisterPush {
            token: "secret-push-token".into(),
            environment: PushEnvironment::Sandbox,
        };
        assert!(!format!("{request:?}").contains("secret-push-token"));
        assert!(
            serde_json::to_string(&request)
                .unwrap()
                .contains("secret-push-token")
        );
        let reservation = ChannelReservation {
            id: Uuid::nil(),
            token: "secret-channel-token".into(),
            address: "https://example.test/webhooks/google".into(),
            expires_at: now(),
        };
        assert!(!format!("{reservation:?}").contains("secret-channel-token"));
    }

    #[test]
    fn secrets_use_256_random_bits_and_hashes_match_sha256_vector() {
        let first = generate_secret().unwrap();
        let second = generate_secret().unwrap();
        assert_eq!(first.len(), 64);
        assert!(first.bytes().all(|byte| byte.is_ascii_hexdigit()));
        assert_ne!(first, second);
        assert_eq!(
            hash_secret("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn acknowledgements_accept_empty_prefix_and_reject_negative_cursors() {
        assert!(Ack { sequence: 0 }.validate(now()).is_ok());
        assert!(Ack { sequence: -1 }.validate(now()).is_err());
    }
}
