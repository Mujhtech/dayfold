//! Public OIDC enrollment and sender-constrained device sessions.
use std::sync::Arc;

use axum::{
    Extension, Json,
    extract::{Path, Request, State},
    http::{HeaderMap, StatusCode},
    middleware::Next,
    response::{IntoResponse, Response},
};
use chrono::{DateTime, Utc};
use dayfold_auth::{
    AuthError, DpopExpectation, OidcConfig, OidcVerifier, VerifiedDpop, verify_dpop,
};
use dayfold_domain::hash_secret;
use dayfold_store::{SessionCredentials, Store};
use serde::Deserialize;
use serde_json::{Value, json};
use uuid::Uuid;

use crate::{ApiError, ApiState};

#[cfg(test)]
mod tests;

pub struct SessionConfiguration {
    verifier: OidcVerifier,
    client_ids: Vec<String>,
}

impl SessionConfiguration {
    /// Resolve discovery from the operator's pinned issuer before accepting traffic.
    pub async fn new(config: OidcConfig) -> Result<Self, AuthError> {
        let client_ids = config.client_ids.clone();
        let verifier = OidcVerifier::new(config)?;
        verifier.discover_metadata().await?;
        Ok(Self {
            verifier,
            client_ids,
        })
    }
}

#[derive(Clone)]
pub(crate) struct Authenticated {
    pub device_id: Uuid,
    pub user_id: Option<Uuid>,
    access_hash: String,
}

impl Authenticated {
    pub(crate) async fn still_valid(&self, store: &Store) -> bool {
        if self.user_id.is_some() {
            store.authenticate_access(&self.access_hash).await.is_ok()
        } else {
            store.authenticate(&self.access_hash).await.is_ok()
        }
    }

    fn user(&self) -> Result<Uuid, ApiError> {
        self.user_id
            .ok_or(ApiError(StatusCode::FORBIDDEN, "user_session_required"))
    }
}

fn unauthorized() -> ApiError {
    ApiError(StatusCode::UNAUTHORIZED, "unauthorized")
}

fn auth_error(error: AuthError) -> ApiError {
    match error {
        AuthError::Unavailable | AuthError::InvalidConfiguration => ApiError(
            StatusCode::SERVICE_UNAVAILABLE,
            "authentication_unavailable",
        ),
        AuthError::InvalidToken | AuthError::InvalidProof => unauthorized(),
    }
}

fn single_header<'a>(
    headers: &'a HeaderMap,
    name: &str,
    maximum: usize,
) -> Result<&'a str, ApiError> {
    if headers.get_all(name).iter().count() != 1 {
        return Err(unauthorized());
    }
    headers
        .get(name)
        .and_then(|value| value.to_str().ok())
        .filter(|value| !value.is_empty() && value.len() <= maximum)
        .ok_or_else(unauthorized)
}

fn valid_token(token: &str) -> bool {
    token.len() == 64
        && token
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

impl ApiState {
    fn sessions(&self) -> Result<Arc<SessionConfiguration>, ApiError> {
        self.session.clone().ok_or(ApiError(
            StatusCode::SERVICE_UNAVAILABLE,
            "authentication_unavailable",
        ))
    }

    fn proof(
        &self,
        headers: &HeaderMap,
        method: &str,
        path: &str,
        access_token: Option<&str>,
    ) -> Result<VerifiedDpop, ApiError> {
        let proof = single_header(headers, "dpop", 8192)?;
        verify_dpop(
            proof,
            &DpopExpectation {
                method: method.to_owned(),
                uri: format!("{}{}", self.public_origin, path),
                now: Utc::now().timestamp() as u64,
                access_token: access_token.map(str::to_owned),
                nonce: None,
                expected_jkt: None,
            },
        )
        .map_err(auth_error)
    }

    async fn remember_proof(&self, proof: &VerifiedDpop) -> Result<(), ApiError> {
        let expiry =
            DateTime::from_timestamp(proof.expires_at as i64, 0).ok_or_else(unauthorized)?;
        self.store
            .register_dpop_proof(&proof.thumbprint, &proof.jti.to_string(), expiry)
            .await?;
        Ok(())
    }

    fn auth_key_limit(&self, proof: &VerifiedDpop) -> Result<(), ApiError> {
        // Hashing the public thumbprint avoids retaining arbitrary-size values
        // in the bounded shared counter. Database limits additionally bound
        // issuance across replicas; this guard reduces work before those locks.
        let digest = hash_secret(&proof.thumbprint);
        let key = Uuid::parse_str(&digest[..32]).expect("SHA-256 hex prefix");
        self.rate_limit((4, key), 30)
    }

    fn preauth_limit(&self) -> Result<(), ApiError> {
        // A bounded process-wide guard complements mandatory edge/global limits.
        // Never trust an arbitrary X-Forwarded-For value as a client identity.
        self.rate_limit((2, Uuid::nil()), 600)
    }
}

pub(crate) async fn preauthenticate(
    State(s): State<ApiState>,
    request: Request,
    next: Next,
) -> Response {
    match s.preauth_limit() {
        Ok(()) => next.run(request).await,
        Err(error) => error.into_response(),
    }
}

pub(crate) async fn authenticate(
    State(s): State<ApiState>,
    mut request: Request,
    next: Next,
) -> Response {
    async fn verify(
        s: &ApiState,
        headers: &HeaderMap,
        method: &str,
        path: &str,
    ) -> Result<Authenticated, ApiError> {
        s.rate_limit((3, Uuid::nil()), 30_000)?;
        let authorization = single_header(headers, "authorization", 128)?;
        if let Some(token) = authorization
            .strip_prefix("DPoP ")
            .filter(|token| valid_token(token))
        {
            s.sessions()?;
            let proof = s.proof(headers, method, path, Some(token))?;
            let access_hash = hash_secret(token);
            let principal = s.store.authenticate_access(&access_hash).await?;
            if principal.key_thumbprint != proof.thumbprint {
                return Err(unauthorized());
            }
            s.rate_limit((0, principal.device_id), 180)?;
            s.remember_proof(&proof).await?;
            Ok(Authenticated {
                device_id: principal.device_id,
                user_id: Some(principal.user_id),
                access_hash,
            })
        } else if s.allow_legacy_bearer {
            let token = authorization
                .strip_prefix("Bearer ")
                .filter(|token| valid_token(token))
                .ok_or_else(unauthorized)?;
            // Mixed schemes/proofs are rejected instead of falling back after a bad DPoP proof.
            if headers.contains_key("dpop") {
                return Err(unauthorized());
            }
            let access_hash = hash_secret(token);
            let device = s.store.authenticate(&access_hash).await?;
            s.rate_limit((0, device.id), 180)?;
            Ok(Authenticated {
                device_id: device.id,
                user_id: None,
                access_hash,
            })
        } else {
            Err(unauthorized())
        }
    }
    let headers = request.headers().clone();
    let method = request.method().as_str().to_owned();
    let path = request.uri().path().to_owned();
    match verify(&s, &headers, &method, &path).await {
        Ok(auth) => {
            request.extensions_mut().insert(auth);
            next.run(request).await
        }
        Err(error) => error.into_response(),
    }
}

pub(crate) async fn configuration(State(s): State<ApiState>) -> Result<Json<Value>, ApiError> {
    let configuration = s.sessions()?;
    let metadata = configuration
        .verifier
        .discover_metadata()
        .await
        .map_err(auth_error)?;
    Ok(Json(json!({
        "issuer": metadata.issuer,
        "client_id": configuration.client_ids[0],
        "authorization_endpoint": metadata.authorization_endpoint,
        "token_endpoint": metadata.token_endpoint,
    })))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ChallengeRequest {
    client_id: String,
    device_name: String,
}

pub(crate) async fn challenge(
    State(s): State<ApiState>,
    headers: HeaderMap,
    Json(body): Json<ChallengeRequest>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    let configuration = s.sessions()?;
    if !configuration.client_ids.contains(&body.client_id)
        || body.device_name.trim().is_empty()
        || body.device_name.len() > 80
        || body.device_name.chars().any(char::is_control)
    {
        return Err(ApiError(StatusCode::BAD_REQUEST, "invalid_request"));
    }
    let proof = s.proof(&headers, "POST", "/v1/auth/challenges", None)?;
    s.auth_key_limit(&proof)?;
    s.remember_proof(&proof).await?;
    let challenge = s
        .store
        .create_auth_challenge(&body.client_id, &body.device_name, &proof.thumbprint)
        .await?;
    Ok((
        StatusCode::CREATED,
        Json(json!({"id":challenge.id,"nonce":challenge.nonce,"expires_at":challenge.expires_at})),
    ))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct EnrollRequest {
    challenge_id: Uuid,
    id_token: String,
}

pub(crate) async fn enroll(
    State(s): State<ApiState>,
    headers: HeaderMap,
    Json(body): Json<EnrollRequest>,
) -> Result<Json<SessionCredentials>, ApiError> {
    let configuration = s.sessions()?;
    if body.id_token.len() > 12_000 {
        return Err(unauthorized());
    }
    let proof = s.proof(&headers, "POST", "/v1/auth/enroll", None)?;
    s.auth_key_limit(&proof)?;
    s.remember_proof(&proof).await?;
    let challenge = s
        .store
        .auth_challenge(body.challenge_id, &proof.thumbprint)
        .await?;
    let identity = configuration
        .verifier
        .verify(
            &body.id_token,
            &challenge.client_id,
            &challenge.nonce,
            challenge.created_at.timestamp() as u64,
            Utc::now().timestamp() as u64,
        )
        .await
        .map_err(auth_error)?;
    let credentials = s
        .store
        .enroll_device(
            challenge.id,
            &proof.thumbprint,
            &identity.issuer,
            &identity.subject,
            &hash_secret(&body.id_token),
        )
        .await?;
    tracing::info!(user_id = %credentials.user_id, device_id = %credentials.device_id, "device session enrolled");
    Ok(Json(credentials))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RefreshRequest {
    refresh_token: String,
    request_id: Uuid,
}

pub(crate) async fn refresh(
    State(s): State<ApiState>,
    headers: HeaderMap,
    Json(body): Json<RefreshRequest>,
) -> Result<Json<SessionCredentials>, ApiError> {
    s.sessions()?;
    if !valid_token(&body.refresh_token) || body.request_id.is_nil() {
        return Err(unauthorized());
    }
    let proof = s.proof(&headers, "POST", "/v1/auth/refresh", None)?;
    s.auth_key_limit(&proof)?;
    s.remember_proof(&proof).await?;
    let credentials = s
        .store
        .refresh_session(&body.refresh_token, body.request_id, &proof.thumbprint)
        .await?;
    tracing::info!(device_id = %credentials.device_id, "device credentials rotated or recovered");
    Ok(Json(credentials))
}

pub(crate) async fn devices(
    State(s): State<ApiState>,
    Extension(auth): Extension<Authenticated>,
) -> Result<Json<Value>, ApiError> {
    let devices = s
        .store
        .list_user_devices(auth.user()?, auth.device_id, &auth.access_hash)
        .await?;
    Ok(Json(json!({"devices":devices})))
}

pub(crate) async fn revoke_account_device(
    State(s): State<ApiState>,
    Extension(auth): Extension<Authenticated>,
    Path(id): Path<Uuid>,
) -> Result<StatusCode, ApiError> {
    let user_id = auth.user()?;
    s.store
        .revoke_user_device(user_id, id, &auth.access_hash)
        .await?;
    tracing::info!(%user_id, device_id = %id, "user revoked device");
    Ok(StatusCode::NO_CONTENT)
}

pub(crate) async fn revoke_all(
    State(s): State<ApiState>,
    Extension(auth): Extension<Authenticated>,
) -> Result<StatusCode, ApiError> {
    let user_id = auth.user()?;
    s.store
        .revoke_all_user_devices(user_id, &auth.access_hash)
        .await?;
    tracing::info!(%user_id, "user revoked all devices");
    Ok(StatusCode::NO_CONTENT)
}

pub(crate) async fn delete_account(
    State(s): State<ApiState>,
    Extension(auth): Extension<Authenticated>,
) -> Result<StatusCode, ApiError> {
    let user_id = auth.user()?;
    s.store.delete_user(user_id, &auth.access_hash).await?;
    tracing::info!(%user_id, "user deleted relay account");
    Ok(StatusCode::NO_CONTENT)
}
