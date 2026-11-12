use super::*;
use chrono::TimeDelta;
use jsonwebtoken::{DecodingKey, Validation, decode};
use serde_json::Value;
use std::{
    collections::VecDeque,
    sync::atomic::{AtomicI64, Ordering},
};

// These deliberately public keys were generated only for this test suite.
// They have never been registered with Apple. See tests/fixtures/README.md.
const TEST_KEY: &[u8] = include_bytes!("../tests/fixtures/test-signing-key.p8");
const TEST_PUBLIC_KEY: &[u8] = include_bytes!("../tests/fixtures/test-public-key.pem");
const TEST_TIME: i64 = 1_793_966_400;

struct TestClock(AtomicI64);

impl TestClock {
    fn set(&self, timestamp: i64) {
        self.0.store(timestamp, Ordering::SeqCst);
    }
}

impl Clock for TestClock {
    fn now(&self) -> DateTime<Utc> {
        DateTime::from_timestamp(self.0.load(Ordering::SeqCst), 0).unwrap()
    }
}

#[derive(Default)]
struct FakeTransport {
    requests: Mutex<Vec<PreparedRequest>>,
    responses: Mutex<VecDeque<Result<RawResponse, TransportError>>>,
}

impl FakeTransport {
    fn respond(&self, response: RawResponse) {
        self.responses.lock().unwrap().push_back(Ok(response));
    }

    fn take_requests(&self) -> Vec<PreparedRequest> {
        std::mem::take(&mut self.requests.lock().unwrap())
    }
}

impl Transport for FakeTransport {
    fn send(&self, request: PreparedRequest) -> SendFuture<'_> {
        self.requests.lock().unwrap().push(request);
        let response = self
            .responses
            .lock()
            .unwrap()
            .pop_front()
            .unwrap_or_else(|| Ok(raw_response(StatusCode::OK, None, None)));
        Box::pin(async { response })
    }
}

struct Fixture {
    client: ApnsClient,
    transport: Arc<FakeTransport>,
    clock: Arc<TestClock>,
}

impl Fixture {
    fn new() -> Self {
        let transport = Arc::new(FakeTransport::default());
        let clock = Arc::new(TestClock(AtomicI64::new(TEST_TIME)));
        let client =
            ApnsClient::with_components(config(), transport.clone(), clock.clone()).unwrap();
        Self {
            client,
            transport,
            clock,
        }
    }
}

fn config() -> ApnsConfig {
    ApnsConfig {
        team_id: "TEAM123456".into(),
        key_id: "KEY1234567".into(),
        topic: "com.example.dayfold".into(),
        private_key_pem: TEST_KEY.to_vec(),
    }
}

fn push(kind: NotificationKind) -> PushRequest {
    PushRequest {
        token: "aB12".repeat(16),
        environment: Environment::Sandbox,
        notification_id: Uuid::from_u128(1),
        kind,
        subject_id: Uuid::from_u128(2),
        revision: (kind == NotificationKind::ReminderDue).then_some(7),
        expires_at: DateTime::from_timestamp(TEST_TIME + 86_400, 0).unwrap(),
    }
}

fn raw_response(status: StatusCode, reason: Option<&str>, retry: Option<&str>) -> RawResponse {
    RawResponse {
        status,
        version: Version::HTTP_2,
        retry_after: retry.map(str::to_owned),
        body: reason
            .map(|reason| serde_json::to_vec(&json!({"reason": reason})).unwrap())
            .unwrap_or_default(),
    }
}

fn classified(status: StatusCode, reason: Option<&str>, retry: Option<&str>) -> Outcome {
    match classify(
        raw_response(status, reason, retry),
        DateTime::from_timestamp(TEST_TIME, 0).unwrap(),
    ) {
        Classification::Outcome(outcome) => outcome,
        Classification::ExpiredProviderToken => panic!("expected a terminal classification"),
    }
}

fn bearer(request: &PreparedRequest) -> &str {
    request.headers[AUTHORIZATION]
        .to_str()
        .unwrap()
        .strip_prefix("bearer ")
        .unwrap()
}

fn decode_provider_token(token: &str) -> jsonwebtoken::TokenData<Value> {
    let key = DecodingKey::from_ec_pem(TEST_PUBLIC_KEY).unwrap();
    let mut validation = Validation::new(Algorithm::ES256);
    // APNs provider tokens have iss and iat, no exp; signatures stay verified.
    validation.set_required_spec_claims(&["iss"]);
    validation.set_issuer(&["TEAM123456"]);
    validation.validate_exp = false;
    decode::<Value>(token, &key, &validation).unwrap()
}

#[tokio::test]
async fn calendar_hint_has_only_opaque_metadata_and_background_delivery_headers() {
    let fixture = Fixture::new();
    let request = push(NotificationKind::CalendarChanged);
    assert_eq!(fixture.client.send(&request).await, Outcome::Delivered);
    let sent = fixture.transport.take_requests().pop().unwrap();
    assert_eq!(sent.url.scheme(), "https");
    assert_eq!(sent.url.host_str(), Some("api.sandbox.push.apple.com"));
    assert_eq!(sent.url.path(), format!("/3/device/{}", request.token));
    assert_eq!(sent.headers["apns-topic"], "com.example.dayfold");
    assert_eq!(sent.headers["apns-push-type"], "background");
    assert_eq!(sent.headers["apns-priority"], "5");
    assert_eq!(sent.headers["apns-id"], request.notification_id.to_string());
    assert_eq!(
        sent.headers["apns-expiration"],
        request.expires_at.timestamp().to_string()
    );
    assert_eq!(
        sent.headers["apns-collapse-id"],
        format!("calendar-{}", request.subject_id)
    );
    assert!(sent.headers[AUTHORIZATION].is_sensitive());
    assert_eq!(sent.headers[CONTENT_TYPE], "application/json");
    assert!(sent.body.len() <= 4096);
    let body: Value = serde_json::from_slice(&sent.body).unwrap();
    assert_eq!(
        body,
        json!({
            "aps": {"content-available": 1},
            "notification_id": request.notification_id,
            "kind": "calendar_changed",
            "subject_id": request.subject_id,
            "revision": null
        })
    );
}

#[tokio::test]
async fn reminder_alert_is_generic_carries_revision_and_uses_production_endpoint() {
    let fixture = Fixture::new();
    let mut request = push(NotificationKind::ReminderDue);
    request.environment = Environment::Production;
    assert_eq!(fixture.client.send(&request).await, Outcome::Delivered);
    let sent = fixture.transport.take_requests().pop().unwrap();
    assert_eq!(sent.url.host_str(), Some("api.push.apple.com"));
    assert_eq!(sent.headers["apns-push-type"], "alert");
    assert_eq!(sent.headers["apns-priority"], "10");
    assert_eq!(
        sent.headers["apns-collapse-id"],
        format!("reminder-{}", request.subject_id)
    );
    let body: Value = serde_json::from_slice(&sent.body).unwrap();
    assert_eq!(
        body,
        json!({
            "aps": {"alert": {"title": "Upcoming event", "body": "An event is starting soon."}, "sound": "default"},
            "notification_id": request.notification_id,
            "kind": "reminder_due",
            "subject_id": request.subject_id,
            "revision": 7
        })
    );
}

#[test]
fn http_transport_builds_post_with_explicit_http2_and_preserves_sensitive_authentication() {
    let fixture = Fixture::new();
    let prepared = fixture
        .client
        .prepare(&push(NotificationKind::CalendarChanged), "fixture-jwt")
        .unwrap();
    let expected_body = prepared.body.clone();
    let transport = HttpTransport(reqwest::Client::new());
    let request = transport.build_request(prepared).unwrap();
    assert_eq!(request.method(), reqwest::Method::POST);
    assert_eq!(request.version(), Version::HTTP_2);
    assert_eq!(request.url().scheme(), "https");
    assert_eq!(request.headers()["apns-push-type"], "background");
    assert!(request.headers()[AUTHORIZATION].is_sensitive());
    assert_eq!(request.body().unwrap().as_bytes().unwrap(), expected_body);
}

#[tokio::test]
async fn jwt_is_es256_signed_and_shared_between_clones_until_rotation_boundary() {
    let fixture = Fixture::new();
    let request = push(NotificationKind::CalendarChanged);
    let clone = fixture.client.clone();
    assert_eq!(fixture.client.send(&request).await, Outcome::Delivered);
    fixture.clock.set(TEST_TIME + TOKEN_LIFETIME - 1);
    assert_eq!(clone.send(&request).await, Outcome::Delivered);
    fixture.clock.set(TEST_TIME + TOKEN_LIFETIME);
    assert_eq!(clone.send(&request).await, Outcome::Delivered);
    let sent = fixture.transport.take_requests();
    assert_eq!(bearer(&sent[0]), bearer(&sent[1]));
    assert_ne!(bearer(&sent[1]), bearer(&sent[2]));
    let original = decode_provider_token(bearer(&sent[0]));
    assert_eq!(original.header.alg, Algorithm::ES256);
    assert_eq!(original.header.kid.as_deref(), Some("KEY1234567"));
    assert_eq!(
        original.claims,
        json!({"iss": "TEAM123456", "iat": TEST_TIME})
    );
    let rotated = decode_provider_token(bearer(&sent[2]));
    assert_eq!(rotated.claims["iat"], TEST_TIME + TOKEN_LIFETIME);
}

#[tokio::test]
async fn expired_provider_token_forces_one_refresh_without_inline_resend_or_token_churn() {
    let fixture = Fixture::new();
    let request = push(NotificationKind::CalendarChanged);
    fixture.transport.respond(raw_response(
        StatusCode::FORBIDDEN,
        Some("ExpiredProviderToken"),
        None,
    ));
    assert_eq!(
        fixture.client.send(&request).await,
        Outcome::Retry {
            after: Duration::from_secs(1)
        }
    );
    let first = fixture.transport.take_requests();
    assert_eq!(first.len(), 1, "retries belong to the durable worker");
    let first_jwt = bearer(&first[0]).to_owned();
    fixture.clock.set(TEST_TIME + 1);
    fixture.transport.respond(raw_response(
        StatusCode::FORBIDDEN,
        Some("ExpiredProviderToken"),
        None,
    ));
    assert_eq!(
        fixture.client.send(&request).await,
        Outcome::Permanent {
            reason: "expired_provider_token"
        }
    );
    let second = fixture.transport.take_requests();
    assert_eq!(second.len(), 1);
    let fresh_jwt = bearer(&second[0]);
    assert_ne!(first_jwt, fresh_jwt);
    // A concurrent response for the old JWT must not evict its replacement.
    assert!(
        fixture
            .client
            .credentials
            .reject_expired(&first_jwt, fixture.clock.now())
    );
    assert_eq!(
        fixture
            .client
            .credentials
            .token(fixture.clock.now())
            .unwrap(),
        fresh_jwt
    );
}

#[tokio::test]
async fn a_backwards_provider_clock_does_not_send_or_remint_a_token() {
    let fixture = Fixture::new();
    fixture.clock.set(TEST_TIME - 1);
    assert_eq!(
        fixture
            .client
            .send(&push(NotificationKind::CalendarChanged))
            .await,
        Outcome::Permanent {
            reason: "provider_clock_invalid"
        }
    );
    assert!(fixture.transport.take_requests().is_empty());
}

#[tokio::test]
async fn invalid_or_expired_requests_never_reach_the_transport() {
    let fixture = Fixture::new();
    for token in [
        String::new(),
        "abcd".into(),
        "a".repeat(33),
        "g".repeat(64),
        "a".repeat(258),
        "ab/../cd".repeat(8),
    ] {
        let mut request = push(NotificationKind::CalendarChanged);
        request.token = token;
        assert_eq!(
            fixture.client.send(&request).await,
            Outcome::Permanent {
                reason: "invalid_device_token_format"
            }
        );
    }
    let mut request = push(NotificationKind::CalendarChanged);
    request.expires_at = fixture.clock.now();
    assert_eq!(
        fixture.client.send(&request).await,
        Outcome::Permanent { reason: "expired" }
    );
    request.expires_at -= TimeDelta::seconds(1);
    assert_eq!(
        fixture.client.send(&request).await,
        Outcome::Permanent { reason: "expired" }
    );
    for (kind, revision) in [
        (NotificationKind::CalendarChanged, Some(1)),
        (NotificationKind::ReminderDue, None),
        (NotificationKind::ReminderDue, Some(0)),
        (NotificationKind::ReminderDue, Some(-1)),
    ] {
        let mut request = push(kind);
        request.revision = revision;
        assert_eq!(
            fixture.client.send(&request).await,
            Outcome::Permanent {
                reason: "invalid_reminder_revision"
            }
        );
    }
    assert!(fixture.transport.take_requests().is_empty());
}

#[tokio::test]
async fn tokens_are_not_restricted_to_one_historical_byte_length() {
    let fixture = Fixture::new();
    for length in [32, 64, 128, 256] {
        let mut request = push(NotificationKind::CalendarChanged);
        request.token = "a".repeat(length);
        assert_eq!(fixture.client.send(&request).await, Outcome::Delivered);
    }
    assert_eq!(fixture.transport.take_requests().len(), 4);
}

#[tokio::test]
async fn transport_failures_retry_once_per_call_and_non_http2_responses_fail_closed() {
    let fixture = Fixture::new();
    fixture
        .transport
        .responses
        .lock()
        .unwrap()
        .push_back(Err(TransportError));
    let request = push(NotificationKind::CalendarChanged);
    assert_eq!(
        fixture.client.send(&request).await,
        Outcome::Retry {
            after: TRANSPORT_RETRY
        }
    );
    let mut response = raw_response(StatusCode::OK, None, None);
    response.version = Version::HTTP_11;
    fixture.transport.respond(response);
    assert_eq!(
        fixture.client.send(&request).await,
        Outcome::Permanent {
            reason: "unexpected_http_version"
        }
    );
    assert_eq!(fixture.transport.take_requests().len(), 2);
}

#[test]
fn invalid_device_tokens_include_410_millisecond_invalidation_timestamps() {
    let millis = TEST_TIME * 1000 + 456;
    let mut response = raw_response(StatusCode::GONE, Some("Unregistered"), None);
    response.body =
        serde_json::to_vec(&json!({"reason": "Unregistered", "timestamp": millis})).unwrap();
    let Classification::Outcome(outcome) =
        classify(response, DateTime::from_timestamp(TEST_TIME, 0).unwrap())
    else {
        panic!("unexpected provider token refresh")
    };
    assert_eq!(
        outcome,
        Outcome::InvalidToken {
            invalidated_at: DateTime::from_timestamp_millis(millis)
        }
    );
    for reason in ["BadDeviceToken", "DeviceTokenNotForTopic"] {
        assert_eq!(
            classified(StatusCode::BAD_REQUEST, Some(reason), None),
            Outcome::InvalidToken {
                invalidated_at: None
            }
        );
    }
    assert_eq!(
        classified(StatusCode::GONE, Some("ExpiredToken"), None),
        Outcome::InvalidToken {
            invalidated_at: None
        }
    );
    assert_eq!(
        classified(StatusCode::GONE, None, None),
        Outcome::InvalidToken {
            invalidated_at: None
        }
    );
}

#[test]
fn error_classification_retries_only_transient_failures_and_sanitizes_unknown_reasons() {
    let cases = [
        (StatusCode::OK, None, Outcome::Delivered),
        (
            StatusCode::BAD_REQUEST,
            Some("IdleTimeout"),
            Outcome::Retry {
                after: TRANSPORT_RETRY,
            },
        ),
        (
            StatusCode::BAD_REQUEST,
            Some("BadTopic"),
            Outcome::Permanent {
                reason: "invalid_topic",
            },
        ),
        (
            StatusCode::FORBIDDEN,
            Some("InvalidProviderToken"),
            Outcome::Permanent {
                reason: "invalid_provider_token",
            },
        ),
        (
            StatusCode::FORBIDDEN,
            Some("Forbidden"),
            Outcome::Permanent {
                reason: "forbidden",
            },
        ),
        (
            StatusCode::FORBIDDEN,
            Some("BadEnvironmentKeyIdInToken"),
            Outcome::Permanent {
                reason: "provider_key_configuration",
            },
        ),
        (
            StatusCode::PAYLOAD_TOO_LARGE,
            Some("PayloadTooLarge"),
            Outcome::Permanent {
                reason: "payload_too_large",
            },
        ),
        (
            StatusCode::BAD_REQUEST,
            Some("token or upstream diagnostic must never enter logs"),
            Outcome::Permanent {
                reason: "apns_rejected",
            },
        ),
        (
            StatusCode::FORBIDDEN,
            None,
            Outcome::Permanent {
                reason: "provider_authentication_rejected",
            },
        ),
        (
            StatusCode::NOT_FOUND,
            None,
            Outcome::Permanent {
                reason: "apns_rejected",
            },
        ),
    ];
    for (status, reason, expected) in cases {
        assert_eq!(classified(status, reason, None), expected);
    }
}

#[test]
fn retries_honor_provider_delays_and_required_backoff_floors() {
    let cases = [
        (
            StatusCode::TOO_MANY_REQUESTS,
            Some("TooManyRequests"),
            None,
            60,
        ),
        (
            StatusCode::TOO_MANY_REQUESTS,
            Some("TooManyRequests"),
            Some("0"),
            1,
        ),
        (
            StatusCode::TOO_MANY_REQUESTS,
            Some("TooManyRequests"),
            Some("300"),
            300,
        ),
        (
            StatusCode::TOO_MANY_REQUESTS,
            Some("TooManyProviderTokenUpdates"),
            Some("1"),
            1200,
        ),
        (
            StatusCode::TOO_MANY_REQUESTS,
            Some("TooManyProviderTokenUpdates"),
            Some("1800"),
            1800,
        ),
        (StatusCode::INTERNAL_SERVER_ERROR, None, None, 900),
        (
            StatusCode::SERVICE_UNAVAILABLE,
            Some("Shutdown"),
            Some("30"),
            900,
        ),
        (StatusCode::SERVICE_UNAVAILABLE, None, Some("1800"), 1800),
        (
            StatusCode::SERVICE_UNAVAILABLE,
            None,
            Some("999999999"),
            86_400,
        ),
    ];
    for (status, reason, header, seconds) in cases {
        assert_eq!(
            classified(status, reason, header),
            Outcome::Retry {
                after: Duration::from_secs(seconds)
            }
        );
    }
}

#[test]
fn retry_after_supports_http_dates_and_clamps_untrusted_durations() {
    let now = DateTime::from_timestamp(TEST_TIME, 0).unwrap();
    let later = httpdate::fmt_http_date(SystemTime::from(now + TimeDelta::seconds(300)));
    let earlier = httpdate::fmt_http_date(SystemTime::from(now - TimeDelta::seconds(30)));
    assert_eq!(
        retry_after(Some(&later), now),
        Some(Duration::from_secs(300))
    );
    assert_eq!(
        retry_after(Some(&earlier), now),
        Some(Duration::from_secs(1))
    );
    assert_eq!(retry_after(Some("0"), now), Some(Duration::from_secs(1)));
    assert_eq!(
        retry_after(Some("18446744073709551615"), now),
        Some(MAX_RETRY)
    );
    assert_eq!(retry_after(Some("18446744073709551616"), now), None);
    assert_eq!(retry_after(Some("-1"), now), None);
    assert_eq!(retry_after(Some("not a date"), now), None);
    assert_eq!(retry_after(None, now), None);
}

#[test]
fn configuration_rejects_invalid_identifiers_topics_and_non_es256_keys_at_startup() {
    let transport = Arc::new(FakeTransport::default());
    let clock = Arc::new(TestClock(AtomicI64::new(TEST_TIME)));
    let check = |config| {
        ApnsClient::with_components(config, transport.clone(), clock.clone())
            .err()
            .unwrap()
    };
    let mut invalid = config();
    invalid.team_id = "short".into();
    assert!(matches!(check(invalid), ConfigError::TeamId));
    let mut invalid = config();
    invalid.key_id = "KEY\n123456".into();
    assert!(matches!(check(invalid), ConfigError::KeyId));
    for topic in [
        "".into(),
        "com..dayfold".into(),
        ".dayfold".into(),
        "com.day fold".into(),
        "com.dayfold\r\nfoo:bar".into(),
        "a".repeat(256),
    ] {
        let mut invalid = config();
        invalid.topic = topic;
        assert!(matches!(check(invalid), ConfigError::Topic));
    }
    for key in [
        b"invalid key".as_slice(),
        TEST_PUBLIC_KEY,
        include_bytes!("../tests/fixtures/test-wrong-curve.p8").as_slice(),
    ] {
        let mut invalid = config();
        invalid.private_key_pem = key.to_vec();
        assert!(matches!(check(invalid), ConfigError::SigningKey));
    }
    clock.set(-1);
    assert!(matches!(check(config()), ConfigError::Clock));
}

#[test]
fn diagnostic_formatting_redacts_private_keys_and_device_tokens() {
    let config_text = format!("{:?}", config());
    assert!(config_text.contains("[REDACTED]"));
    assert!(!config_text.contains("BEGIN PRIVATE KEY"));
    let request = push(NotificationKind::CalendarChanged);
    let request_text = format!("{request:?}");
    assert!(request_text.contains("[REDACTED]"));
    assert!(!request_text.contains(&request.token));
}
