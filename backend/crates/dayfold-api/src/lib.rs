//! Authenticated device API and Google Calendar webhook ingress.
mod auth;

use auth::Authenticated;
pub use auth::SessionConfiguration;
use std::{
    collections::HashMap,
    convert::Infallible,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use axum::{
    Extension, Json, Router,
    extract::{DefaultBodyLimit, Path, Query, State},
    http::{HeaderMap, StatusCode},
    response::{
        IntoResponse, Response,
        sse::{Event, KeepAlive, Sse},
    },
    routing::{delete, get, post, put},
};
use chrono::Utc;
use dayfold_domain::{
    Ack, ActivateChannel, ChannelReservation, PutReminder, RegisterPush, ReserveChannel,
    generate_secret, hash_secret,
};
use dayfold_store::{Store, StoreError};
use futures_util::Stream;
use serde::Deserialize;
use serde_json::json;
use uuid::Uuid;

type RateBuckets = Arc<Mutex<HashMap<(u8, Uuid), (Instant, u32)>>>;

#[derive(Clone)]
pub struct ApiState {
    pub store: Store,
    webhook_address: String,
    public_origin: String,
    session: Option<Arc<SessionConfiguration>>,
    allow_legacy_bearer: bool,
    apns_enabled: bool,
    limits: RateBuckets,
    streams: Arc<Mutex<HashMap<Uuid, usize>>>,
    shutdown: tokio::sync::watch::Receiver<bool>,
}

impl ApiState {
    pub fn new(store: Store, public_origin: &str) -> Result<Self, &'static str> {
        let origin = url::Url::parse(public_origin).map_err(|_| "invalid public origin")?;
        if origin.scheme() != "https"
            || origin.host_str().is_none()
            || !origin.username().is_empty()
            || origin.password().is_some()
            || origin.query().is_some()
            || origin.fragment().is_some()
            || origin.path() != "/"
        {
            return Err(
                "public origin must be an HTTPS origin without credentials, path, query or fragment",
            );
        }
        Ok(Self {
            store,
            public_origin: origin.as_str().trim_end_matches('/').to_owned(),
            session: None,
            allow_legacy_bearer: false,
            webhook_address: format!(
                "{}/v1/webhooks/google",
                origin.as_str().trim_end_matches('/')
            ),
            apns_enabled: false,
            limits: Default::default(),
            streams: Default::default(),
            shutdown: tokio::sync::watch::channel(false).1,
        })
    }

    pub fn with_shutdown(mut self, shutdown: tokio::sync::watch::Receiver<bool>) -> Self {
        self.shutdown = shutdown;
        self
    }

    /// Set from successfully initialized server APNs configuration, never a
    /// device-provided capability or an assumption in the macOS client.
    pub fn with_apns_enabled(mut self, enabled: bool) -> Self {
        self.apns_enabled = enabled;
        self
    }

    fn rate_limit(&self, key: (u8, Uuid), maximum: u32) -> Result<(), ApiError> {
        let mut limits = self.limits.lock().expect("rate limit lock");
        // Bound memory even under untrusted channel identifiers. No forwarded-IP trust.
        if limits.len() >= 10_000 {
            limits.retain(|_, (start, _)| start.elapsed() < Duration::from_secs(60));
            if limits.len() >= 10_000 && !limits.contains_key(&key) {
                return Err(ApiError(StatusCode::TOO_MANY_REQUESTS, "rate_limited"));
            }
        }
        let value = limits.entry(key).or_insert((Instant::now(), 0));
        if value.0.elapsed() >= Duration::from_secs(60) {
            *value = (Instant::now(), 0);
        }
        value.1 += 1;
        if value.1 > maximum {
            return Err(ApiError(StatusCode::TOO_MANY_REQUESTS, "rate_limited"));
        }
        Ok(())
    }

    /// Legacy operator credentials are available only through an explicit local
    /// development server setting; public servers must configure OIDC sessions.
    pub fn with_legacy_development_auth(mut self, enabled: bool) -> Self {
        self.allow_legacy_bearer = enabled;
        self
    }

    pub fn with_session_configuration(mut self, configuration: SessionConfiguration) -> Self {
        self.session = Some(Arc::new(configuration));
        self
    }
}

pub fn router(state: ApiState) -> Router {
    let protected = Router::new()
        .route("/v1/capabilities", get(capabilities))
        .route("/v1/device", delete(revoke_device))
        .route("/v1/device/push", put(register_push))
        .route("/v1/channels", post(reserve_channel))
        .route(
            "/v1/channels/{id}",
            put(activate_channel).delete(revoke_channel),
        )
        .route(
            "/v1/reminders/{id}",
            put(put_reminder).delete(delete_reminder),
        )
        .route("/v1/notifications", get(notifications))
        .route("/v1/notifications/ack", post(acknowledge))
        .route("/v1/notifications/cursor", get(cursor_snapshot))
        .route("/v1/notifications/{id}/claim", post(claim_reminder))
        .route("/v1/events", get(events))
        .route("/v1/account/devices", get(auth::devices))
        .route(
            "/v1/account/devices/{id}",
            delete(auth::revoke_account_device),
        )
        .route("/v1/account/revoke-all", post(auth::revoke_all))
        .route("/v1/account", delete(auth::delete_account))
        .route_layer(axum::middleware::from_fn_with_state(
            state.clone(),
            auth::authenticate,
        ));
    let authentication = Router::new()
        .route("/v1/auth/config", get(auth::configuration))
        .route("/v1/auth/challenges", post(auth::challenge))
        .route("/v1/auth/enroll", post(auth::enroll))
        .route("/v1/auth/refresh", post(auth::refresh))
        .route_layer(axum::middleware::from_fn_with_state(
            state.clone(),
            auth::preauthenticate,
        ));
    Router::new()
        .merge(protected)
        .merge(authentication)
        .route("/healthz", get(|| async { Json(json!({"status":"ok"})) }))
        .route("/readyz", get(ready))
        .route("/v1/webhooks/google", post(webhook))
        .layer(DefaultBodyLimit::max(16 * 1024))
        .layer(axum::middleware::from_fn(bounded_request))
        .with_state(state)
}

#[derive(Debug)]
pub struct ApiError(StatusCode, &'static str);
impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let mut response = (self.0, Json(json!({"error": self.1}))).into_response();
        if matches!(
            self.0,
            StatusCode::TOO_MANY_REQUESTS | StatusCode::SERVICE_UNAVAILABLE
        ) {
            response
                .headers_mut()
                .insert("retry-after", "60".parse().unwrap());
        }
        response
            .headers_mut()
            .insert("cache-control", "no-store".parse().unwrap());
        if self.0 == StatusCode::UNAUTHORIZED {
            response.headers_mut().insert(
                "www-authenticate",
                "DPoP error=\"invalid_token\"".parse().unwrap(),
            );
        }
        response
    }
}
impl From<StoreError> for ApiError {
    fn from(error: StoreError) -> Self {
        match error {
            StoreError::Unauthorized => Self(StatusCode::UNAUTHORIZED, "unauthorized"),
            StoreError::ReauthenticationRequired => {
                Self(StatusCode::UNAUTHORIZED, "reauthentication_required")
            }
            StoreError::RotationSuperseded => Self(StatusCode::CONFLICT, "rotation_superseded"),
            StoreError::NotFound => Self(StatusCode::NOT_FOUND, "not_found"),
            StoreError::Capacity => Self(StatusCode::SERVICE_UNAVAILABLE, "capacity_exceeded"),
            StoreError::Conflict => Self(StatusCode::CONFLICT, "revision_or_identity_conflict"),
            StoreError::Invalid(_) => Self(StatusCode::BAD_REQUEST, "invalid_request"),
            StoreError::Database(_) => {
                tracing::error!("database operation failed");
                Self(StatusCode::SERVICE_UNAVAILABLE, "temporarily_unavailable")
            }
        }
    }
}
fn valid(result: Result<(), dayfold_domain::DomainError>) -> Result<(), ApiError> {
    result.map_err(|_| ApiError(StatusCode::BAD_REQUEST, "invalid_request"))
}

async fn ready(State(s): State<ApiState>) -> Result<Json<serde_json::Value>, ApiError> {
    s.store.health().await?;
    Ok(Json(json!({"status":"ready"})))
}
async fn capabilities(
    State(s): State<ApiState>,
    Extension(auth): Extension<Authenticated>,
) -> Result<impl IntoResponse, ApiError> {
    Ok((
        [("cache-control", "no-store")],
        // User sessions cannot activate APNs routing until destination
        // possession is verified by the separate push-enrollment protocol.
        Json(json!({"apns_enabled": s.apns_enabled && auth.user_id.is_none()})),
    ))
}
async fn claim_reminder(
    State(s): State<ApiState>,
    Extension(auth): Extension<Authenticated>,
    Path(id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    let device = auth.device_id;
    let claimed = s.store.claim_reminder(device, id).await?;
    Ok((
        [("cache-control", "no-store")],
        Json(json!({"claimed": claimed})),
    ))
}
async fn register_push(
    State(s): State<ApiState>,
    Extension(auth): Extension<Authenticated>,
    Json(body): Json<RegisterPush>,
) -> Result<StatusCode, ApiError> {
    if auth.user_id.is_some() {
        return Err(ApiError(
            StatusCode::FORBIDDEN,
            "push_verification_required",
        ));
    }
    let d = auth.device_id;
    valid(body.validate(Utc::now()))?;
    s.store
        .register_push(d, &body.token, body.environment)
        .await?;
    Ok(StatusCode::NO_CONTENT)
}
async fn revoke_device(
    State(s): State<ApiState>,
    Extension(auth): Extension<Authenticated>,
) -> Result<StatusCode, ApiError> {
    let d = auth.device_id;
    s.store.revoke_device(d).await?;
    Ok(StatusCode::NO_CONTENT)
}
async fn reserve_channel(
    State(s): State<ApiState>,
    Extension(auth): Extension<Authenticated>,
    Json(body): Json<ReserveChannel>,
) -> Result<impl IntoResponse, ApiError> {
    let d = auth.device_id;
    valid(body.validate(Utc::now()))?;
    let token = generate_secret()
        .map_err(|_| ApiError(StatusCode::INTERNAL_SERVER_ERROR, "entropy_unavailable"))?;
    let channel = s
        .store
        .reserve_channel(
            d,
            Uuid::new_v4(),
            &hash_secret(&token),
            body.scope_id,
            body.expires_at,
        )
        .await?;
    Ok((
        StatusCode::CREATED,
        [("cache-control", "no-store")],
        Json(ChannelReservation {
            id: channel.id,
            token,
            address: s.webhook_address,
            expires_at: channel.expires_at,
        }),
    ))
}
async fn activate_channel(
    State(s): State<ApiState>,
    Extension(auth): Extension<Authenticated>,
    Path(id): Path<Uuid>,
    Json(body): Json<ActivateChannel>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let d = auth.device_id;
    valid(body.validate(Utc::now()))?;
    let c = s
        .store
        .activate_channel(d, id, &body.resource_id, body.expires_at)
        .await?;
    Ok(Json(
        json!({"id":c.id,"scope_id":c.scope_id,"expires_at":c.expires_at}),
    ))
}
async fn revoke_channel(
    State(s): State<ApiState>,
    Extension(auth): Extension<Authenticated>,
    Path(id): Path<Uuid>,
) -> Result<StatusCode, ApiError> {
    let d = auth.device_id;
    s.store.revoke_channel(d, id).await?;
    Ok(StatusCode::NO_CONTENT)
}
async fn put_reminder(
    State(s): State<ApiState>,
    Extension(auth): Extension<Authenticated>,
    Path(id): Path<Uuid>,
    Json(body): Json<PutReminder>,
) -> Result<StatusCode, ApiError> {
    let d = auth.device_id;
    valid(body.validate(Utc::now()))?;
    s.store
        .put_reminder(d, id, body.revision, body.due_at, body.expires_at)
        .await?;
    Ok(StatusCode::NO_CONTENT)
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct DeleteReminder {
    revision: i64,
}
async fn delete_reminder(
    State(s): State<ApiState>,
    Extension(auth): Extension<Authenticated>,
    Path(id): Path<Uuid>,
    Query(body): Query<DeleteReminder>,
) -> Result<StatusCode, ApiError> {
    let d = auth.device_id;
    if body.revision <= 0 {
        return Err(ApiError(StatusCode::BAD_REQUEST, "invalid_revision"));
    }
    s.store.delete_reminder(d, id, body.revision).await?;
    Ok(StatusCode::NO_CONTENT)
}
#[derive(Deserialize, Default)]
#[serde(deny_unknown_fields)]
struct Cursor {
    after: Option<i64>,
}
fn cursor(headers: &HeaderMap, query: Cursor) -> Result<i64, ApiError> {
    if headers.get_all("last-event-id").iter().count() > 1 {
        return Err(ApiError(StatusCode::BAD_REQUEST, "invalid_cursor"));
    }
    let last = headers
        .get("last-event-id")
        .map(|v| {
            v.to_str()
                .ok()
                .and_then(|s| s.parse::<i64>().ok())
                .ok_or(ApiError(StatusCode::BAD_REQUEST, "invalid_cursor"))
        })
        .transpose()?;
    if query.after.is_some() && last.is_some() && query.after != last {
        return Err(ApiError(StatusCode::BAD_REQUEST, "conflicting_cursor"));
    }
    let value = query.after.or(last).unwrap_or(0);
    if value < 0 {
        return Err(ApiError(StatusCode::BAD_REQUEST, "invalid_cursor"));
    }
    Ok(value)
}
async fn notifications(
    State(s): State<ApiState>,
    headers: HeaderMap,
    Extension(auth): Extension<Authenticated>,
    Query(query): Query<Cursor>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let d = auth.device_id;
    let after = cursor(&headers, query)?;
    let page = s.store.notifications(d, after, 100).await?;
    if page.reset_required {
        return Err(ApiError(StatusCode::GONE, "resync_required"));
    }
    Ok(Json(
        json!({"notifications":page.notifications,"cursor_floor":page.cursor_floor,"latest_sequence":page.latest_sequence}),
    ))
}
async fn cursor_snapshot(
    State(s): State<ApiState>,
    Extension(auth): Extension<Authenticated>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let d = auth.device_id;
    let (floor, current) = s.store.cursor_bounds(d).await?;
    Ok(Json(json!({"floor":floor,"current":current})))
}
async fn acknowledge(
    State(s): State<ApiState>,
    Extension(auth): Extension<Authenticated>,
    Json(body): Json<Ack>,
) -> Result<StatusCode, ApiError> {
    let d = auth.device_id;
    valid(body.validate(Utc::now()))?;
    s.store.acknowledge(d, body.sequence).await?;
    Ok(StatusCode::NO_CONTENT)
}

struct StreamPermit {
    counts: Arc<Mutex<HashMap<Uuid, usize>>>,
    id: Uuid,
}
impl Drop for StreamPermit {
    fn drop(&mut self) {
        let mut counts = self.counts.lock().expect("streams lock");
        if let Some(n) = counts.get_mut(&self.id) {
            *n -= 1;
            if *n == 0 {
                counts.remove(&self.id);
            }
        }
    }
}
async fn check_cursor(store: &Store, id: Uuid, after: i64) -> Result<(), ApiError> {
    let (floor, current) = store.cursor_bounds(id).await?;
    if after < floor {
        return Err(ApiError(StatusCode::GONE, "resync_required"));
    }
    if after > current {
        return Err(ApiError(StatusCode::BAD_REQUEST, "cursor_ahead"));
    }
    Ok(())
}
async fn events(
    State(s): State<ApiState>,
    headers: HeaderMap,
    Extension(auth): Extension<Authenticated>,
    Query(query): Query<Cursor>,
) -> Result<impl IntoResponse, ApiError> {
    let d = auth.device_id;
    let after = cursor(&headers, query)?;
    check_cursor(&s.store, d, after).await?;
    let permit = {
        let mut counts = s.streams.lock().expect("streams lock");
        if counts.values().sum::<usize>() >= 256 || counts.get(&d).copied().unwrap_or(0) >= 2 {
            return Err(ApiError(StatusCode::TOO_MANY_REQUESTS, "too_many_streams"));
        }
        *counts.entry(d).or_default() += 1;
        StreamPermit {
            counts: s.streams.clone(),
            id: d,
        }
    };
    let stream = notification_stream(s, auth, after, permit);
    Ok((
        [("cache-control", "no-store"), ("x-accel-buffering", "no")],
        Sse::new(stream).keep_alive(
            KeepAlive::new()
                .interval(Duration::from_secs(15))
                .text("keepalive"),
        ),
    ))
}
fn notification_stream(
    s: ApiState,
    auth: Authenticated,
    mut after: i64,
    permit: StreamPermit,
) -> impl Stream<Item = Result<Event, Infallible>> {
    async_stream::stream! {
        let _permit = permit;
        let device_id = auth.device_id;
        let mut shutdown = s.shutdown.clone();
        loop {
            if *shutdown.borrow() { break; }
            // Recheck revocation while connected; a failed database closes the stream so the client resumes.
            if !auth.still_valid(&s.store).await { break; }
            let page = match s.store.notifications(device_id, after, 100).await { Ok(v) => v, Err(_) => break };
            if page.reset_required { yield Ok(Event::default().event("resync_required").data("{}")); break; }
            let full = page.notifications.len() == 100;
            for notification in page.notifications {
                after = notification.sequence;
                match Event::default().event("notification").id(after.to_string()).json_data(&notification) {
                    Ok(event) => yield Ok(event), Err(_) => return,
                }
            }
            if !full {
                tokio::select! {
                    _ = tokio::time::sleep(Duration::from_millis(500)) => {},
                    result = shutdown.changed(), if shutdown.has_changed().is_ok() => { if result.is_ok() && *shutdown.borrow() { break; } }
                }
            }
        }
    }
}

fn header<'a>(headers: &'a HeaderMap, name: &str, max: usize) -> Result<&'a str, ApiError> {
    if headers.get_all(name).iter().count() != 1 {
        return Err(ApiError(StatusCode::BAD_REQUEST, "invalid_webhook_headers"));
    }
    headers
        .get(name)
        .and_then(|v| v.to_str().ok())
        .filter(|v| !v.is_empty() && v.len() <= max && !v.bytes().any(|b| b.is_ascii_control()))
        .ok_or(ApiError(StatusCode::BAD_REQUEST, "invalid_webhook_headers"))
}
async fn webhook(
    State(s): State<ApiState>,
    headers: HeaderMap,
    body: axum::body::Bytes,
) -> Result<StatusCode, ApiError> {
    if !body.is_empty() {
        return Err(ApiError(StatusCode::BAD_REQUEST, "unexpected_webhook_body"));
    }
    let id = Uuid::parse_str(header(&headers, "x-goog-channel-id", 64)?)
        .map_err(|_| ApiError(StatusCode::BAD_REQUEST, "invalid_channel"))?;
    let token = header(&headers, "x-goog-channel-token", 256)?;
    let resource = header(&headers, "x-goog-resource-id", 512)?;
    let state = header(&headers, "x-goog-resource-state", 32)?;
    let number = header(&headers, "x-goog-message-number", 20)?;
    if !matches!(state, "sync" | "exists" | "not_exists") || number.parse::<u64>().is_err() {
        return Err(ApiError(StatusCode::BAD_REQUEST, "invalid_webhook_headers"));
    }
    let token_hash = hash_secret(token);
    s.store.authenticate_channel(id, &token_hash).await?;
    s.rate_limit((1, id), 600)
        .map_err(|_| ApiError(StatusCode::SERVICE_UNAVAILABLE, "webhook_rate_limited"))?;
    s.store
        .accept_webhook(id, &token_hash, resource, state, number)
        .await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn bounded_request(
    request: axum::extract::Request,
    next: axum::middleware::Next,
) -> Response {
    let mut response = match tokio::time::timeout(Duration::from_secs(15), next.run(request)).await
    {
        Ok(response) => response,
        Err(_) => ApiError(StatusCode::SERVICE_UNAVAILABLE, "request_timeout").into_response(),
    };
    response
        .headers_mut()
        .insert("cache-control", "no-store".parse().unwrap());
    response
}

#[cfg(test)]
mod tests {
    use super::*;
    use tower::ServiceExt;

    fn state() -> ApiState {
        let pool = sqlx::postgres::PgPoolOptions::new()
            .connect_lazy("postgres://unused:unused@127.0.0.1:1/unused")
            .unwrap();
        ApiState::new(Store::new(pool), "https://relay.example.test").unwrap()
    }

    #[tokio::test]
    async fn missing_credentials_and_nonempty_webhooks_never_need_a_database() {
        for (path, method, body, expected) in [
            ("/v1/notifications", "GET", "", StatusCode::UNAUTHORIZED),
            ("/v1/capabilities", "GET", "", StatusCode::UNAUTHORIZED),
            (
                "/v1/notifications/00000000-0000-4000-8000-000000000001/claim",
                "POST",
                "",
                StatusCode::UNAUTHORIZED,
            ),
            (
                "/v1/webhooks/google",
                "POST",
                "unexpected",
                StatusCode::BAD_REQUEST,
            ),
        ] {
            let response = router(state())
                .oneshot(
                    axum::http::Request::builder()
                        .uri(path)
                        .method(method)
                        .body(axum::body::Body::from(body))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(response.status(), expected);
            assert_eq!(response.headers()["cache-control"], "no-store");
        }
    }

    #[tokio::test]
    async fn apns_capability_defaults_to_disabled_and_uses_server_configuration() {
        assert!(!state().apns_enabled);
        assert!(state().with_apns_enabled(true).apns_enabled);
        assert!(
            !state()
                .with_apns_enabled(true)
                .with_apns_enabled(false)
                .apns_enabled
        );
    }

    #[tokio::test]
    async fn bounds_request_bodies_and_keeps_rate_limit_namespaces_separate() {
        let state = state();
        let id = Uuid::new_v4();
        assert!(state.rate_limit((0, id), 1).is_ok());
        assert!(state.rate_limit((0, id), 1).is_err());
        assert!(state.rate_limit((1, id), 1).is_ok());
        let response = router(state)
            .oneshot(
                axum::http::Request::builder()
                    .uri("/v1/channels")
                    .method("POST")
                    .header("content-type", "application/json")
                    .body(axum::body::Body::from("x".repeat(16 * 1024 + 1)))
                    .unwrap(),
            )
            .await
            .unwrap();
        // Authentication rejects the request before the JSON body is read.
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn only_accepts_https_origins_without_embedded_secrets_or_paths() {
        let store = state().store;
        for origin in [
            "http://relay.test",
            "https://token@relay.test",
            "https://relay.test/path",
            "https://relay.test?token=x",
        ] {
            assert!(ApiState::new(store.clone(), origin).is_err());
        }
    }

    #[test]
    fn validates_resume_cursor() {
        let mut headers = HeaderMap::new();
        headers.insert("last-event-id", "12".parse().unwrap());
        assert_eq!(cursor(&headers, Cursor::default()).unwrap(), 12);
        assert!(cursor(&headers, Cursor { after: Some(11) }).is_err());
        assert!(cursor(&HeaderMap::new(), Cursor { after: Some(-1) }).is_err());
        headers.insert("last-event-id", "bad".parse().unwrap());
        assert!(cursor(&headers, Cursor::default()).is_err());
    }
}
