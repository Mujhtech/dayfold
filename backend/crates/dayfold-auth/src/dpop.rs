use crate::{AuthError, json};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use jsonwebtoken::{Algorithm, DecodingKey, Validation, decode, jwk::Jwk};
use serde::Deserialize;
use serde_json::Value;
use sha2::{Digest, Sha256};
use url::{Host, Url};
use uuid::Uuid;

const PROOF_WINDOW: u64 = 60;

/// Values supplied by the server, never copied from the unverified proof.
pub struct DpopExpectation {
    pub method: String,
    pub uri: String,
    pub now: u64,
    pub access_token: Option<String>,
    pub nonce: Option<String>,
    pub expected_jkt: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VerifiedDpop {
    pub thumbprint: String,
    pub jti: Uuid,
    pub issued_at: u64,
    /// Retain the consumed jti at least through this instant (inclusive).
    pub expires_at: u64,
}

#[derive(Clone, Deserialize)]
struct ProofClaims {
    jti: String,
    htm: String,
    htu: String,
    iat: u64,
    ath: Option<String>,
    nonce: Option<String>,
}

/// Verify cryptography and request binding. Replay consumption and authorization
/// are deliberately left to the caller's persistent transaction.
pub fn verify_dpop(proof: &str, expected: &DpopExpectation) -> Result<VerifiedDpop, AuthError> {
    verify(proof, expected).map_err(|_| AuthError::InvalidProof)
}

fn verify(proof: &str, expected: &DpopExpectation) -> Result<VerifiedDpop, ()> {
    let (header, raw_claims) = json::token_parts(proof)?;
    if !json::acceptable_header(&header)
        || header.get("typ").and_then(Value::as_str) != Some("dpop+jwt")
        || header.get("alg").and_then(Value::as_str) != Some("ES256")
    {
        return Err(());
    }
    let public_key = header.get("jwk").ok_or(())?;
    let thumbprint = key_thumbprint(public_key)?;
    if expected
        .expected_jkt
        .as_ref()
        .is_some_and(|value| value != &thumbprint)
    {
        return Err(());
    }
    let jwk: Jwk = serde_json::from_value(public_key.clone()).map_err(|_| ())?;
    let key = DecodingKey::from_jwk(&jwk).map_err(|_| ())?;
    let mut validation = Validation::new(Algorithm::ES256);
    validation.set_required_spec_claims::<&str>(&[]);
    validation.validate_exp = false;
    validation.validate_nbf = false;
    validation.validate_aud = false;
    // These JWTs have no exp/aud. Every protocol-required claim is a required
    // typed field, then checked below against the caller's trusted clock/context.
    let claims = decode::<ProofClaims>(proof, &key, &validation)
        .map_err(|_| ())?
        .claims;
    let jti = Uuid::parse_str(&claims.jti).map_err(|_| ())?;
    if claims.jti.len() != 36
        || jti.is_nil()
        || jti.is_max()
        || claims.htm != expected.method
        || expected.method.is_empty()
        || !expected
            .method
            .bytes()
            .all(|byte| byte.is_ascii_uppercase())
        || normalize_uri(&claims.htu)? != normalize_uri(&expected.uri)?
        || claims.iat.abs_diff(expected.now) > PROOF_WINDOW
        || expected
            .nonce
            .as_ref()
            .is_some_and(|value| claims.nonce.as_ref() != Some(value))
    {
        return Err(());
    }
    match expected.access_token.as_deref() {
        Some(token) => {
            if token.is_empty()
                || !token.is_ascii()
                || claims.ath.as_deref()
                    != Some(
                        URL_SAFE_NO_PAD
                            .encode(Sha256::digest(token.as_bytes()))
                            .as_str(),
                    )
            {
                return Err(());
            }
        }
        None if raw_claims.get("ath").is_some() => return Err(()),
        None => {}
    }
    Ok(VerifiedDpop {
        thumbprint,
        jti,
        issued_at: claims.iat,
        expires_at: claims.iat.checked_add(PROOF_WINDOW).ok_or(())?,
    })
}

pub(crate) fn key_thumbprint(key: &Value) -> Result<String, ()> {
    if !json::public_key_only(key)
        || key.get("kty").and_then(Value::as_str) != Some("EC")
        || key.get("crv").and_then(Value::as_str) != Some("P-256")
        || key
            .get("alg")
            .is_some_and(|value| value.as_str() != Some("ES256"))
        || key
            .get("use")
            .is_some_and(|value| value.as_str() != Some("sig"))
        || key
            .get("key_ops")
            .is_some_and(|value| value != &serde_json::json!(["verify"]))
    {
        return Err(());
    }
    let x = key.get("x").and_then(Value::as_str).ok_or(())?;
    let y = key.get("y").and_then(Value::as_str).ok_or(())?;
    if json::decode_canonical(x)?.len() != 32 || json::decode_canonical(y)?.len() != 32 {
        return Err(());
    }
    // RFC 7638 lexicographic order, with canonical base64url coordinates.
    let canonical = format!(r#"{{"crv":"P-256","kty":"EC","x":"{x}","y":"{y}"}}"#);
    Ok(URL_SAFE_NO_PAD.encode(Sha256::digest(canonical.as_bytes())))
}

fn normalize_uri(raw: &str) -> Result<String, ()> {
    if raw.len() > 4096 || raw.bytes().any(|byte| byte.is_ascii_control()) {
        return Err(());
    }
    let mut url = Url::parse(raw).map_err(|_| ())?;
    let loopback = match url.host() {
        Some(Host::Ipv4(address)) => address.is_loopback(),
        Some(Host::Ipv6(address)) => address.is_loopback(),
        _ => false,
    };
    if !url.username().is_empty()
        || url.password().is_some()
        || url.host().is_none()
        || (url.scheme() != "https" && !(url.scheme() == "http" && loopback))
    {
        return Err(());
    }
    url.set_query(None);
    url.set_fragment(None);
    Ok(url.into())
}
