//! A small APNs provider for opaque calendar hints and generic reminder alerts.
//!
//! The caller owns durable scheduling, retries, and installation registration.
//! This crate performs one HTTP request per `send` and never reads credentials
//! from the environment or filesystem. An accepted push is not a delivery receipt.

use std::{
    fmt,
    future::Future,
    pin::Pin,
    sync::{Arc, Mutex},
    time::{Duration, SystemTime},
};

use chrono::{DateTime, Utc};
pub use dayfold_domain::{NotificationKind, PushEnvironment as Environment};
use jsonwebtoken::{Algorithm, EncodingKey, Header, encode};
use reqwest::{
    StatusCode, Url, Version,
    header::{AUTHORIZATION, CONTENT_TYPE, HeaderMap, HeaderValue, RETRY_AFTER},
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use thiserror::Error;
use uuid::Uuid;

const TOKEN_LIFETIME: i64 = 20 * 60;
const MAX_PAYLOAD_BYTES: usize = 4096;
const MAX_RESPONSE_BYTES: usize = 4096;
const MAX_RETRY: Duration = Duration::from_secs(24 * 60 * 60);
const SERVER_RETRY: Duration = Duration::from_secs(15 * 60);
const TRANSPORT_RETRY: Duration = Duration::from_secs(30);

/// Credentials are supplied once at startup. Do not reuse the test fixture key.
pub struct ApnsConfig {
    pub team_id: String,
    pub key_id: String,
    pub topic: String,
    pub private_key_pem: Vec<u8>,
}

impl fmt::Debug for ApnsConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ApnsConfig")
            .field("team_id", &self.team_id)
            .field("key_id", &self.key_id)
            .field("topic", &self.topic)
            .field("private_key_pem", &"[REDACTED]")
            .finish()
    }
}

/// The topic and host cannot be overridden by a notification request.
#[derive(Clone)]
pub struct PushRequest {
    pub token: String,
    pub environment: Environment,
    pub notification_id: Uuid,
    pub kind: NotificationKind,
    pub subject_id: Uuid,
    /// Reminder revision lets a receiving client discard a superseded schedule.
    pub revision: Option<i64>,
    pub expires_at: DateTime<Utc>,
}

impl fmt::Debug for PushRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PushRequest")
            .field("token", &"[REDACTED]")
            .field("environment", &self.environment)
            .field("notification_id", &self.notification_id)
            .field("kind", &self.kind)
            .field("subject_id", &self.subject_id)
            .field("revision", &self.revision)
            .field("expires_at", &self.expires_at)
            .finish()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    /// APNs accepted the request; device delivery is still best effort.
    Delivered,
    /// Only invalidate the matching token registration, never the account.
    InvalidToken {
        /// APNs 410 timestamps are milliseconds since Unix epoch.
        invalidated_at: Option<DateTime<Utc>>,
    },
    /// A bounded, static code suitable for logs; never a token or upstream body.
    Permanent { reason: &'static str },
    /// The worker should schedule this delay durably, subject to job expiry.
    Retry { after: Duration },
}

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("APNs team ID must contain 10 ASCII letters or digits")]
    TeamId,
    #[error("APNs key ID must contain 10 ASCII letters or digits")]
    KeyId,
    #[error("APNs topic must be a valid app bundle identifier")]
    Topic,
    #[error("APNs signing key must be a valid ES256 PKCS#8 PEM private key")]
    SigningKey,
    #[error("APNs HTTP/2 client could not be initialized")]
    HttpClient,
    #[error("APNs token cache is unavailable")]
    TokenCache,
    #[error("APNs provider clock must be valid and must not move backwards")]
    Clock,
}

/// Clones share the HTTP connection pools and provider-token cache.
#[derive(Clone)]
pub struct ApnsClient {
    topic: HeaderValue,
    credentials: Arc<Credentials>,
    transport: Arc<dyn Transport>,
    clock: Arc<dyn Clock>,
}

impl ApnsClient {
    pub fn new(config: ApnsConfig) -> Result<Self, ConfigError> {
        let http = reqwest::Client::builder()
            .http2_prior_knowledge()
            .https_only(true)
            .min_tls_version(reqwest::tls::Version::TLS_1_2)
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .retry(reqwest::retry::never())
            .connect_timeout(Duration::from_secs(5))
            .timeout(Duration::from_secs(15))
            .pool_idle_timeout(Duration::from_secs(60 * 60))
            .build()
            .map_err(|_| ConfigError::HttpClient)?;
        Self::with_components(config, Arc::new(HttpTransport(http)), Arc::new(SystemClock))
    }

    // Private injection seam: production callers cannot substitute an APNs host.
    fn with_components(
        config: ApnsConfig,
        transport: Arc<dyn Transport>,
        clock: Arc<dyn Clock>,
    ) -> Result<Self, ConfigError> {
        if !valid_identifier(&config.team_id) {
            return Err(ConfigError::TeamId);
        }
        if !valid_identifier(&config.key_id) {
            return Err(ConfigError::KeyId);
        }
        if config.topic.len() > 255
            || config.topic.split('.').any(|part| {
                part.is_empty()
                    || !part
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
            })
        {
            return Err(ConfigError::Topic);
        }
        let topic = HeaderValue::from_str(&config.topic).map_err(|_| ConfigError::Topic)?;
        let key = EncodingKey::from_ec_pem(&config.private_key_pem)
            .map_err(|_| ConfigError::SigningKey)?;
        let credentials = Arc::new(Credentials {
            team_id: config.team_id,
            key_id: config.key_id,
            key,
            cache: Mutex::new(TokenCache::default()),
        });
        // Sign once at startup as well as decoding the PEM. A different EC curve
        // may decode successfully but must not become a runtime signing failure.
        credentials.token(clock.now())?;
        Ok(Self {
            topic,
            credentials,
            transport,
            clock,
        })
    }

    pub async fn send(&self, request: &PushRequest) -> Outcome {
        let now = self.clock.now();
        if request.expires_at <= now {
            return Outcome::Permanent { reason: "expired" };
        }
        if dayfold_domain::validate_push_token(&request.token).is_err() {
            return Outcome::Permanent {
                reason: "invalid_device_token_format",
            };
        }
        if !matches!(
            (request.kind, request.revision),
            (NotificationKind::CalendarChanged, None) | (NotificationKind::ReminderDue, Some(1..))
        ) {
            return Outcome::Permanent {
                reason: "invalid_reminder_revision",
            };
        }
        let jwt = match self.credentials.token(now) {
            Ok(jwt) => jwt,
            Err(ConfigError::Clock) => {
                return Outcome::Permanent {
                    reason: "provider_clock_invalid",
                };
            }
            Err(_) => {
                return Outcome::Permanent {
                    reason: "provider_authentication_unavailable",
                };
            }
        };
        let prepared = match self.prepare(request, &jwt) {
            Ok(prepared) => prepared,
            Err(reason) => return Outcome::Permanent { reason },
        };
        let response = match self.transport.send(prepared).await {
            Ok(response) => response,
            // A lost response is ambiguous: APNs might already have accepted it.
            // Keep the same logical notification ID when the worker retries.
            Err(TransportError) => {
                return Outcome::Retry {
                    after: TRANSPORT_RETRY,
                };
            }
        };
        if response.version != Version::HTTP_2 {
            return Outcome::Permanent {
                reason: "unexpected_http_version",
            };
        }
        match classify(response, self.clock.now()) {
            Classification::Outcome(outcome) => outcome,
            Classification::ExpiredProviderToken => {
                if self.credentials.reject_expired(&jwt, self.clock.now()) {
                    Outcome::Retry {
                        after: Duration::from_secs(1),
                    }
                } else {
                    Outcome::Permanent {
                        reason: "expired_provider_token",
                    }
                }
            }
        }
    }

    fn prepare(&self, request: &PushRequest, jwt: &str) -> Result<PreparedRequest, &'static str> {
        let host = match request.environment {
            Environment::Sandbox => "https://api.sandbox.push.apple.com",
            Environment::Production => "https://api.push.apple.com",
        };
        let url = Url::parse(&format!("{host}/3/device/{}", request.token))
            .map_err(|_| "invalid_device_token_format")?;
        let (aps, push_type, priority, collapse_prefix) = match request.kind {
            NotificationKind::CalendarChanged => (
                json!({ "content-available": 1 }),
                "background",
                "5",
                "calendar",
            ),
            NotificationKind::ReminderDue => (
                json!({
                    "alert": { "title": "Upcoming event", "body": "An event is starting soon." },
                    "sound": "default"
                }),
                "alert",
                "10",
                "reminder",
            ),
        };
        let body = serde_json::to_vec(&json!({
            "aps": aps,
            "notification_id": request.notification_id,
            "kind": request.kind,
            "subject_id": request.subject_id,
            "revision": request.revision
        }))
        .map_err(|_| "invalid_payload")?;
        if body.len() > MAX_PAYLOAD_BYTES {
            return Err("payload_too_large");
        }
        let collapse = format!("{collapse_prefix}-{}", request.subject_id);
        if collapse.len() > 64 {
            return Err("invalid_collapse_id");
        }
        let mut authorization = HeaderValue::from_str(&format!("bearer {jwt}"))
            .map_err(|_| "invalid_provider_token")?;
        authorization.set_sensitive(true);
        let mut headers = HeaderMap::new();
        headers.insert(AUTHORIZATION, authorization);
        headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
        headers.insert("apns-topic", self.topic.clone());
        headers.insert("apns-push-type", HeaderValue::from_static(push_type));
        headers.insert("apns-priority", HeaderValue::from_static(priority));
        headers.insert(
            "apns-id",
            HeaderValue::from_str(&request.notification_id.to_string())
                .map_err(|_| "invalid_notification_id")?,
        );
        headers.insert(
            "apns-expiration",
            HeaderValue::from_str(&request.expires_at.timestamp().to_string())
                .map_err(|_| "invalid_expiration")?,
        );
        headers.insert(
            "apns-collapse-id",
            HeaderValue::from_str(&collapse).map_err(|_| "invalid_collapse_id")?,
        );
        Ok(PreparedRequest { url, headers, body })
    }
}

fn valid_identifier(value: &str) -> bool {
    value.len() == 10 && value.bytes().all(|byte| byte.is_ascii_alphanumeric())
}

struct Credentials {
    team_id: String,
    key_id: String,
    key: EncodingKey,
    cache: Mutex<TokenCache>,
}

#[derive(Default)]
struct TokenCache {
    token: Option<CachedToken>,
    last_forced_refresh: Option<i64>,
}

struct CachedToken {
    issued_at: i64,
    value: String,
}

#[derive(Serialize)]
struct Claims<'a> {
    iss: &'a str,
    iat: i64,
}

impl Credentials {
    fn token(&self, now: DateTime<Utc>) -> Result<String, ConfigError> {
        let now = now.timestamp();
        if now < 0 {
            return Err(ConfigError::Clock);
        }
        let mut cache = self.cache.lock().map_err(|_| ConfigError::TokenCache)?;
        if let Some(token) = &cache.token {
            if now < token.issued_at {
                return Err(ConfigError::Clock);
            }
            if now - token.issued_at < TOKEN_LIFETIME {
                return Ok(token.value.clone());
            }
        }
        let mut header = Header::new(Algorithm::ES256);
        header.kid = Some(self.key_id.clone());
        let value = encode(
            &header,
            &Claims {
                iss: &self.team_id,
                iat: now,
            },
            &self.key,
        )
        .map_err(|_| ConfigError::SigningKey)?;
        cache.token = Some(CachedToken {
            issued_at: now,
            value: value.clone(),
        });
        Ok(value)
    }

    fn reject_expired(&self, used_token: &str, now: DateTime<Utc>) -> bool {
        let Ok(mut cache) = self.cache.lock() else {
            return false;
        };
        // A concurrent request may have refreshed the token already.
        if cache
            .token
            .as_ref()
            .is_none_or(|token| token.value != used_token)
        {
            return true;
        }
        let now = now.timestamp();
        if cache
            .last_forced_refresh
            .is_some_and(|last| now - last < TOKEN_LIFETIME)
        {
            return false;
        }
        cache.token = None;
        cache.last_forced_refresh = Some(now);
        true
    }
}

trait Clock: Send + Sync {
    fn now(&self) -> DateTime<Utc>;
}

struct SystemClock;
impl Clock for SystemClock {
    fn now(&self) -> DateTime<Utc> {
        Utc::now()
    }
}

struct PreparedRequest {
    url: Url,
    headers: HeaderMap,
    body: Vec<u8>,
}

struct RawResponse {
    status: StatusCode,
    version: Version,
    retry_after: Option<String>,
    body: Vec<u8>,
}

struct TransportError;
type SendFuture<'a> =
    Pin<Box<dyn Future<Output = Result<RawResponse, TransportError>> + Send + 'a>>;

trait Transport: Send + Sync {
    fn send(&self, request: PreparedRequest) -> SendFuture<'_>;
}

struct HttpTransport(reqwest::Client);

impl HttpTransport {
    fn build_request(&self, request: PreparedRequest) -> Result<reqwest::Request, reqwest::Error> {
        self.0
            .post(request.url)
            .version(Version::HTTP_2)
            .headers(request.headers)
            .body(request.body)
            .build()
    }
}

impl Transport for HttpTransport {
    fn send(&self, request: PreparedRequest) -> SendFuture<'_> {
        Box::pin(async move {
            let request = self.build_request(request).map_err(|_| TransportError)?;
            let mut response = self.0.execute(request).await.map_err(|_| TransportError)?;
            let status = response.status();
            let version = response.version();
            let retry_after = response
                .headers()
                .get(RETRY_AFTER)
                .and_then(|value| value.to_str().ok())
                .map(str::to_owned);
            let mut body = Vec::new();
            while let Some(chunk) = response.chunk().await.map_err(|_| TransportError)? {
                if body.len() + chunk.len() > MAX_RESPONSE_BYTES {
                    return Err(TransportError);
                }
                body.extend_from_slice(&chunk);
            }
            Ok(RawResponse {
                status,
                version,
                retry_after,
                body,
            })
        })
    }
}

#[derive(Deserialize)]
struct ApnsFailure {
    reason: String,
    timestamp: Option<i64>,
}

enum Classification {
    Outcome(Outcome),
    ExpiredProviderToken,
}

fn classify(response: RawResponse, now: DateTime<Utc>) -> Classification {
    let error: Option<ApnsFailure> = serde_json::from_slice(&response.body).ok();
    let reason = error.as_ref().map(|error| error.reason.as_str());
    let outcome = if response.status == StatusCode::OK {
        Outcome::Delivered
    } else if response.status == StatusCode::GONE {
        Outcome::InvalidToken {
            invalidated_at: error
                .and_then(|error| error.timestamp)
                .and_then(DateTime::from_timestamp_millis),
        }
    } else if response.status == StatusCode::BAD_REQUEST
        && matches!(reason, Some("BadDeviceToken" | "DeviceTokenNotForTopic"))
    {
        Outcome::InvalidToken {
            invalidated_at: None,
        }
    } else if response.status == StatusCode::FORBIDDEN && reason == Some("ExpiredProviderToken") {
        return Classification::ExpiredProviderToken;
    } else if response.status == StatusCode::TOO_MANY_REQUESTS {
        let floor = if reason == Some("TooManyProviderTokenUpdates") {
            Duration::from_secs(TOKEN_LIFETIME as u64)
        } else {
            Duration::from_secs(1)
        };
        let delay =
            retry_after(response.retry_after.as_deref(), now).unwrap_or(Duration::from_secs(60));
        Outcome::Retry {
            after: delay.max(floor),
        }
    } else if response.status.is_server_error() {
        Outcome::Retry {
            after: retry_after(response.retry_after.as_deref(), now)
                .unwrap_or(SERVER_RETRY)
                .max(SERVER_RETRY),
        }
    } else if response.status == StatusCode::BAD_REQUEST && reason == Some("IdleTimeout") {
        Outcome::Retry {
            after: TRANSPORT_RETRY,
        }
    } else {
        Outcome::Permanent {
            reason: safe_failure_reason(response.status, reason),
        }
    };
    Classification::Outcome(outcome)
}

fn safe_failure_reason(status: StatusCode, reason: Option<&str>) -> &'static str {
    match reason {
        Some("BadCollapseId") => "bad_collapse_id",
        Some("BadExpirationDate") => "bad_expiration",
        Some("BadMessageId") => "bad_notification_id",
        Some("BadPriority") => "bad_priority",
        Some("BadTopic" | "MissingTopic" | "TopicDisallowed") => "invalid_topic",
        Some("InvalidPushType") => "invalid_push_type",
        Some("PayloadEmpty") => "empty_payload",
        Some("PayloadTooLarge") => "payload_too_large",
        Some("InvalidProviderToken") => "invalid_provider_token",
        Some("MissingProviderToken") => "missing_provider_token",
        Some("Forbidden") => "forbidden",
        Some("UnrelatedKeyIdInToken" | "BadEnvironmentKeyIdInToken") => {
            "provider_key_configuration"
        }
        _ if status == StatusCode::FORBIDDEN || status == StatusCode::UNAUTHORIZED => {
            "provider_authentication_rejected"
        }
        _ if status == StatusCode::PAYLOAD_TOO_LARGE => "payload_too_large",
        _ => "apns_rejected",
    }
}

fn retry_after(value: Option<&str>, now: DateTime<Utc>) -> Option<Duration> {
    let value = value?;
    let duration = if let Ok(seconds) = value.parse::<u64>() {
        Duration::from_secs(seconds)
    } else {
        let date = httpdate::parse_http_date(value).ok()?;
        date.duration_since(SystemTime::from(now))
            .unwrap_or_default()
    };
    Some(duration.clamp(Duration::from_secs(1), MAX_RETRY))
}

#[cfg(test)]
mod tests;
