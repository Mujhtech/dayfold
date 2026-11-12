use crate::{AuthError, dpop::key_thumbprint, json};
use jsonwebtoken::{Algorithm, DecodingKey, Validation, decode, jwk::Jwk};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::HashSet,
    future::Future,
    pin::Pin,
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::sync::Mutex;
use url::Url;

const CACHE_LIFETIME: Duration = Duration::from_secs(300);
const REFRESH_COOLDOWN: Duration = Duration::from_secs(30);
const MAX_RESPONSE: usize = 131_072;
const CLOCK_SKEW: u64 = 60;
const CHALLENGE_LIFETIME: u64 = 600;

#[derive(Clone, Debug)]
pub struct OidcConfig {
    pub issuer: String,
    pub client_ids: Vec<String>,
    pub jwks_uri: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, Eq, PartialEq)]
pub struct OidcMetadata {
    pub issuer: String,
    pub authorization_endpoint: String,
    pub token_endpoint: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VerifiedIdentity {
    pub issuer: String,
    pub subject: String,
    pub client_id: String,
}

#[derive(Clone)]
pub struct OidcVerifier {
    config: OidcConfig,
    discovery_url: Url,
    jwks_url: Url,
    transport: Arc<dyn Transport>,
    state: Arc<Mutex<State>>,
}

#[derive(Default)]
struct State {
    metadata: Option<(Instant, OidcMetadata)>,
    keys: Option<(Instant, Vec<VerificationKey>)>,
    last_metadata_attempt: Option<Instant>,
    last_keys_attempt: Option<Instant>,
}

struct VerificationKey {
    kid: String,
    algorithm: Algorithm,
    key: DecodingKey,
}

type FetchFuture<'a> = Pin<Box<dyn Future<Output = Result<Vec<u8>, AuthError>> + Send + 'a>>;
trait Transport: Send + Sync {
    fn get(&self, url: Url) -> FetchFuture<'_>;
}

struct HttpTransport(reqwest::Client);

impl HttpTransport {
    fn new() -> Result<Self, AuthError> {
        Self::builder()
            .build()
            .map(Self)
            .map_err(|_| AuthError::InvalidConfiguration)
    }

    fn builder() -> reqwest::ClientBuilder {
        reqwest::Client::builder()
            .https_only(true)
            .redirect(reqwest::redirect::Policy::none())
            .retry(reqwest::retry::never())
            .no_proxy()
            .tls_version_min(reqwest::tls::Version::TLS_1_2)
            .connect_timeout(Duration::from_secs(3))
            .timeout(Duration::from_secs(8))
    }
}

impl Transport for HttpTransport {
    fn get(&self, url: Url) -> FetchFuture<'_> {
        Box::pin(async move {
            let mut response = self
                .0
                .get(url.clone())
                .header("accept", "application/json")
                .send()
                .await
                .map_err(|_| AuthError::Unavailable)?;
            if !response.status().is_success()
                || response.url() != &url
                || response
                    .content_length()
                    .is_some_and(|length| length > MAX_RESPONSE as u64)
            {
                return Err(AuthError::Unavailable);
            }
            let mut bytes = Vec::new();
            while let Some(chunk) = response.chunk().await.map_err(|_| AuthError::Unavailable)? {
                if bytes.len() + chunk.len() > MAX_RESPONSE {
                    return Err(AuthError::Unavailable);
                }
                bytes.extend_from_slice(&chunk);
            }
            Ok(bytes)
        })
    }
}

impl OidcVerifier {
    pub fn new(config: OidcConfig) -> Result<Self, AuthError> {
        Self::with_transport(config, Arc::new(HttpTransport::new()?))
    }

    fn with_transport(
        config: OidcConfig,
        transport: Arc<dyn Transport>,
    ) -> Result<Self, AuthError> {
        let issuer = secure_url(&config.issuer)?;
        let jwks_url = secure_url(&config.jwks_uri)?;
        if issuer.query().is_some()
            || config.client_ids.is_empty()
            || config.client_ids.len() > 32
            || config
                .client_ids
                .iter()
                .any(|id| !bounded_identifier(id, 512))
            || config.client_ids.iter().collect::<HashSet<_>>().len() != config.client_ids.len()
        {
            return Err(AuthError::InvalidConfiguration);
        }
        let discovery_url = secure_url(&format!(
            "{}/.well-known/openid-configuration",
            config.issuer.trim_end_matches('/')
        ))?;
        Ok(Self {
            config,
            discovery_url,
            jwks_url,
            transport,
            state: Arc::new(Mutex::new(State::default())),
        })
    }

    pub async fn discover_metadata(&self) -> Result<OidcMetadata, AuthError> {
        let mut state = self.state.lock().await;
        self.metadata_locked(&mut state).await
    }

    async fn metadata_locked(&self, state: &mut State) -> Result<OidcMetadata, AuthError> {
        if let Some((fetched, metadata)) = &state.metadata
            && fetched.elapsed() < CACHE_LIFETIME
        {
            return Ok(metadata.clone());
        }
        if state
            .last_metadata_attempt
            .is_some_and(|attempt| attempt.elapsed() < REFRESH_COOLDOWN)
        {
            return Err(AuthError::Unavailable);
        }
        state.last_metadata_attempt = Some(Instant::now());
        let bytes = self.transport.get(self.discovery_url.clone()).await?;
        if bytes.len() > MAX_RESPONSE {
            return Err(AuthError::Unavailable);
        }
        let value = json::parse(&bytes).map_err(|_| AuthError::Unavailable)?;
        if value.get("issuer").and_then(Value::as_str) != Some(&self.config.issuer)
            || value.get("jwks_uri").and_then(Value::as_str) != Some(&self.config.jwks_uri)
        {
            return Err(AuthError::Unavailable);
        }
        let metadata: OidcMetadata =
            serde_json::from_value(value).map_err(|_| AuthError::Unavailable)?;
        secure_url(&metadata.authorization_endpoint).map_err(|_| AuthError::Unavailable)?;
        secure_url(&metadata.token_endpoint).map_err(|_| AuthError::Unavailable)?;
        state.metadata = Some((Instant::now(), metadata.clone()));
        Ok(metadata)
    }

    pub async fn verify(
        &self,
        id_token: &str,
        client_id: &str,
        nonce: &str,
        challenge_created_at: u64,
        now: u64,
    ) -> Result<VerifiedIdentity, AuthError> {
        if !self
            .config
            .client_ids
            .iter()
            .any(|allowed| allowed == client_id)
            || !bounded_identifier(nonce, 512)
            || challenge_created_at > now.saturating_add(CLOCK_SKEW)
            || now.saturating_sub(challenge_created_at) > CHALLENGE_LIFETIME
        {
            return Err(AuthError::InvalidToken);
        }
        let (header, _) = json::token_parts(id_token).map_err(|_| AuthError::InvalidToken)?;
        if !json::acceptable_header(&header)
            || header.get("jwk").is_some()
            || header
                .get("typ")
                .is_some_and(|value| value.as_str() != Some("JWT"))
        {
            return Err(AuthError::InvalidToken);
        }
        let algorithm = match header.get("alg").and_then(Value::as_str) {
            Some("RS256") => Algorithm::RS256,
            Some("ES256") => Algorithm::ES256,
            _ => return Err(AuthError::InvalidToken),
        };
        let kid = header
            .get("kid")
            .and_then(Value::as_str)
            .filter(|value| bounded_identifier(value, 256))
            .ok_or(AuthError::InvalidToken)?;
        let key = self.key(kid, algorithm).await?;
        let mut validation = Validation::new(algorithm);
        validation.set_required_spec_claims::<&str>(&[]);
        validation.validate_exp = false;
        validation.validate_nbf = false;
        validation.validate_aud = false;
        // Signature verification remains enabled. Typed fields require all OIDC
        // claims, including iat and nonce, which required_spec_claims ignores.
        // Time checks use the same trusted instant as the enrollment transaction.
        let claims = decode::<IdentityClaims>(id_token, &key, &validation)
            .map_err(|_| AuthError::InvalidToken)?
            .claims;
        claims.validate(
            &self.config.issuer,
            &self.config.client_ids,
            client_id,
            nonce,
            challenge_created_at,
            now,
        )?;
        Ok(VerifiedIdentity {
            issuer: claims.iss,
            subject: claims.sub,
            client_id: client_id.into(),
        })
    }

    async fn key(&self, kid: &str, algorithm: Algorithm) -> Result<DecodingKey, AuthError> {
        // Holding the mutex through fetch deliberately single-flights discovery
        // and rotation. It also bounds unknown-kid traffic across all callers.
        let mut state = self.state.lock().await;
        let current = state
            .keys
            .as_ref()
            .filter(|(instant, _)| instant.elapsed() < CACHE_LIFETIME);
        if let Some((_, keys)) = current
            && let Some(key) = keys
                .iter()
                .find(|key| key.kid == kid && key.algorithm == algorithm)
        {
            return Ok(key.key.clone());
        }
        if state
            .last_keys_attempt
            .is_some_and(|attempt| attempt.elapsed() < REFRESH_COOLDOWN)
        {
            return Err(if current.is_some() {
                AuthError::InvalidToken
            } else {
                AuthError::Unavailable
            });
        }
        state.last_keys_attempt = Some(Instant::now());
        self.metadata_locked(&mut state).await?;
        let bytes = self.transport.get(self.jwks_url.clone()).await?;
        let keys = parse_keys(&bytes)?;
        let result = keys
            .iter()
            .find(|key| key.kid == kid && key.algorithm == algorithm)
            .map(|key| key.key.clone())
            .ok_or(AuthError::InvalidToken);
        state.keys = Some((Instant::now(), keys));
        result
    }
}

#[derive(Clone, Deserialize)]
#[serde(untagged)]
enum Audience {
    One(String),
    Many(Vec<String>),
}

#[derive(Clone, Deserialize)]
struct IdentityClaims {
    iss: String,
    sub: String,
    aud: Audience,
    exp: u64,
    iat: u64,
    nonce: String,
    azp: Option<String>,
    nbf: Option<u64>,
}

impl IdentityClaims {
    fn validate(
        &self,
        issuer: &str,
        trusted_audiences: &[String],
        client_id: &str,
        nonce: &str,
        challenge_created_at: u64,
        now: u64,
    ) -> Result<(), AuthError> {
        let audiences = match &self.aud {
            Audience::One(value) => std::slice::from_ref(value),
            Audience::Many(values) => values.as_slice(),
        };
        if self.iss != issuer
            || !bounded_identifier(&self.sub, 255)
            || audiences.is_empty()
            || audiences.len() > 32
            || audiences
                .iter()
                .any(|value| !bounded_identifier(value, 512) || !trusted_audiences.contains(value))
            || audiences.iter().collect::<HashSet<_>>().len() != audiences.len()
            || !audiences.iter().any(|value| value == client_id)
            || (audiences.len() > 1 && self.azp.as_deref() != Some(client_id))
            || self.azp.as_deref().is_some_and(|value| value != client_id)
            || self.nonce != nonce
            || self.exp <= now
            || self.exp <= self.iat
            || self.iat > now.saturating_add(CLOCK_SKEW)
            || self.iat < challenge_created_at.saturating_sub(CLOCK_SKEW)
            || now.saturating_sub(self.iat) > CHALLENGE_LIFETIME
            || self
                .nbf
                .is_some_and(|value| value > now.saturating_add(CLOCK_SKEW) || value >= self.exp)
        {
            return Err(AuthError::InvalidToken);
        }
        Ok(())
    }
}

fn parse_keys(bytes: &[u8]) -> Result<Vec<VerificationKey>, AuthError> {
    let invalid = || AuthError::Unavailable;
    if bytes.len() > MAX_RESPONSE {
        return Err(invalid());
    }
    let value = json::parse(bytes).map_err(|_| invalid())?;
    let keys = value
        .get("keys")
        .and_then(Value::as_array)
        .ok_or_else(invalid)?;
    if keys.is_empty() || keys.len() > 32 {
        return Err(invalid());
    }
    let mut result = Vec::new();
    let mut seen = HashSet::new();
    for key in keys {
        let kid = key
            .get("kid")
            .and_then(Value::as_str)
            .filter(|value| bounded_identifier(value, 256))
            .ok_or_else(invalid)?;
        if !seen.insert(kid) || !json::public_key_only(key) {
            return Err(invalid());
        }
        if key
            .get("use")
            .is_some_and(|value| value.as_str() != Some("sig"))
            || key
                .get("key_ops")
                .is_some_and(|value| value != &serde_json::json!(["verify"]))
        {
            continue;
        }
        let algorithm = match key.get("kty").and_then(Value::as_str) {
            Some("RSA") => {
                if key
                    .get("alg")
                    .is_some_and(|value| value.as_str() != Some("RS256"))
                {
                    continue;
                }
                let modulus = key.get("n").and_then(Value::as_str).ok_or_else(invalid)?;
                let modulus = json::decode_canonical(modulus).map_err(|_| invalid())?;
                let exponent = key.get("e").and_then(Value::as_str).ok_or_else(invalid)?;
                let exponent = json::decode_canonical(exponent).map_err(|_| invalid())?;
                if !(256..=1024).contains(&modulus.len())
                    || modulus[0] & 0x80 == 0
                    || exponent.is_empty()
                    || exponent.len() > 8
                    || exponent[0] == 0
                    || exponent.last().is_none_or(|byte| byte & 1 == 0)
                    || (exponent.len() == 1 && exponent[0] < 3)
                {
                    return Err(invalid());
                }
                Algorithm::RS256
            }
            Some("EC") if key.get("crv").and_then(Value::as_str) == Some("P-256") => {
                if key
                    .get("alg")
                    .is_some_and(|value| value.as_str() != Some("ES256"))
                {
                    continue;
                }
                key_thumbprint(key).map_err(|_| invalid())?;
                Algorithm::ES256
            }
            _ => continue,
        };
        let jwk: Jwk = serde_json::from_value(key.clone()).map_err(|_| invalid())?;
        let decoding = DecodingKey::from_jwk(&jwk).map_err(|_| invalid())?;
        result.push(VerificationKey {
            kid: kid.into(),
            algorithm,
            key: decoding,
        });
    }
    if result.is_empty() {
        return Err(invalid());
    }
    Ok(result)
}

fn secure_url(raw: &str) -> Result<Url, AuthError> {
    if raw.len() > 4096
        || raw
            .bytes()
            .any(|byte| byte.is_ascii_control() || byte.is_ascii_whitespace())
    {
        return Err(AuthError::InvalidConfiguration);
    }
    let url = Url::parse(raw).map_err(|_| AuthError::InvalidConfiguration)?;
    if url.scheme() != "https"
        || url.host().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.fragment().is_some()
    {
        return Err(AuthError::InvalidConfiguration);
    }
    Ok(url)
}

fn bounded_identifier(value: &str, max: usize) -> bool {
    !value.is_empty() && value.len() <= max && !value.chars().any(char::is_control)
}

#[cfg(test)]
#[path = "oidc_tests.rs"]
mod tests;
