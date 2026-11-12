use super::*;
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use jsonwebtoken::{Algorithm, EncodingKey, Header, encode, jwk::Jwk};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use uuid::Uuid;

pub(crate) const NOW: u64 = 1_793_966_400;
pub(crate) const EC_KEY: &[u8] = include_bytes!("../tests/fixtures/test-es256.pem");
pub(crate) const RSA_KEY: &[u8] = include_bytes!("../tests/fixtures/test-rs256.pem");

pub(crate) fn signing_key(algorithm: Algorithm) -> EncodingKey {
    match algorithm {
        Algorithm::ES256 => EncodingKey::from_ec_pem(EC_KEY).unwrap(),
        Algorithm::RS256 => EncodingKey::from_rsa_pem(RSA_KEY).unwrap(),
        _ => panic!("unsupported fixture algorithm"),
    }
}

pub(crate) fn public_jwk(algorithm: Algorithm) -> Value {
    serde_json::to_value(Jwk::from_encoding_key(&signing_key(algorithm), algorithm).unwrap())
        .unwrap()
}

fn expectation() -> DpopExpectation {
    DpopExpectation {
        method: "POST".into(),
        uri: "https://relay.example/v1/auth/enroll".into(),
        now: NOW,
        access_token: None,
        nonce: None,
        expected_jkt: None,
    }
}

fn proof_claims() -> Value {
    json!({"jti": Uuid::new_v4().to_string(), "htm": "POST", "htu": "https://relay.example/v1/auth/enroll", "iat": NOW})
}

fn proof_header() -> Value {
    json!({"typ":"dpop+jwt", "alg":"ES256", "jwk":public_jwk(Algorithm::ES256)})
}

pub(crate) fn sign_values(header: &Value, claims: &Value) -> String {
    // Raw signing permits intentionally malformed-but-signed headers and claims.
    sign_raw(&header.to_string(), &claims.to_string(), Algorithm::ES256)
}

pub(crate) fn sign_raw(header: &str, claims: &str, algorithm: Algorithm) -> String {
    let message = format!(
        "{}.{}",
        URL_SAFE_NO_PAD.encode(header),
        URL_SAFE_NO_PAD.encode(claims)
    );
    let signature =
        jsonwebtoken::crypto::sign(message.as_bytes(), &signing_key(algorithm), algorithm).unwrap();
    format!("{message}.{signature}")
}

#[test]
fn verifies_device_proof_and_rfc7638_thumbprint() {
    let header = proof_header();
    let claims = proof_claims();
    let actual = verify_dpop(&sign_values(&header, &claims), &expectation()).unwrap();
    let key = &header["jwk"];
    let canonical = format!(
        r#"{{"crv":"P-256","kty":"EC","x":"{}","y":"{}"}}"#,
        key["x"].as_str().unwrap(),
        key["y"].as_str().unwrap()
    );
    assert_eq!(
        actual.thumbprint,
        URL_SAFE_NO_PAD.encode(Sha256::digest(canonical))
    );
    assert_eq!(actual.jti.to_string(), claims["jti"].as_str().unwrap());
    assert_eq!(actual.issued_at, NOW);
    assert_eq!(actual.expires_at, NOW + 60);
}

#[test]
fn verifies_exact_access_token_hash_key_and_optional_nonce() {
    let header = proof_header();
    let mut claims = proof_claims();
    let mut expected = expectation();
    expected.access_token = Some("fixture-access-token".into());
    expected.nonce = Some("server-nonce".into());
    expected.expected_jkt = Some(dpop::key_thumbprint(&header["jwk"]).unwrap());
    claims["ath"] = json!(URL_SAFE_NO_PAD.encode(Sha256::digest(b"fixture-access-token")));
    claims["nonce"] = json!("server-nonce");
    let token = sign_values(&header, &claims);
    assert!(verify_dpop(&token, &expected).is_ok());
    expected.access_token = Some("different-access-token".into());
    assert_eq!(verify_dpop(&token, &expected), Err(AuthError::InvalidProof));
    expected.access_token = Some("fixture-access-token".into());
    expected.nonce = Some("different-nonce".into());
    assert_eq!(verify_dpop(&token, &expected), Err(AuthError::InvalidProof));
    expected.nonce = Some("server-nonce".into());
    expected.expected_jkt = Some("different-device".into());
    assert_eq!(verify_dpop(&token, &expected), Err(AuthError::InvalidProof));
}

#[test]
fn proof_rejects_missing_or_wrong_claims_and_ath_without_access_token() {
    for missing in ["jti", "htm", "htu", "iat"] {
        let mut claims = proof_claims();
        claims.as_object_mut().unwrap().remove(missing);
        assert_eq!(
            verify_dpop(&sign_values(&proof_header(), &claims), &expectation()),
            Err(AuthError::InvalidProof),
            "{missing}"
        );
    }
    for (name, value) in [
        ("jti", json!("not-a-uuid")),
        ("jti", json!(Uuid::nil())),
        ("htm", json!("GET")),
        ("htm", json!("post")),
        ("htu", json!("https://other.example/v1/auth/enroll")),
        ("htu", json!("https://relay.example/v1/auth/refresh")),
        ("htu", json!("https://user@relay.example/v1/auth/enroll")),
        ("iat", json!(NOW - 61)),
        ("iat", json!(NOW + 61)),
        ("iat", json!(NOW.to_string())),
        ("iat", json!(NOW as f64 + 0.5)),
        ("ath", json!("unexpected")),
        ("ath", Value::Null),
    ] {
        let mut claims = proof_claims();
        claims[name] = value;
        assert_eq!(
            verify_dpop(&sign_values(&proof_header(), &claims), &expectation()),
            Err(AuthError::InvalidProof),
            "{name}"
        );
    }
    let mut expected = expectation();
    expected.access_token = Some("missing-hash".into());
    assert_eq!(
        verify_dpop(&sign_values(&proof_header(), &proof_claims()), &expected),
        Err(AuthError::InvalidProof)
    );
}

#[test]
fn proof_rejects_private_jwk_remote_keys_extensions_and_wrong_curves() {
    for (name, value) in [
        ("d", json!("private")),
        ("k", json!("symmetric")),
        ("kty", json!("RSA")),
        ("crv", json!("P-384")),
        ("x", json!("short")),
        ("use", json!("enc")),
        ("key_ops", json!(["sign"])),
        ("alg", json!("HS256")),
    ] {
        let mut header = proof_header();
        header["jwk"][name] = value;
        assert_eq!(
            verify_dpop(&sign_values(&header, &proof_claims()), &expectation()),
            Err(AuthError::InvalidProof),
            "{name}"
        );
    }
    for (name, value) in [
        ("typ", json!("JWT")),
        ("alg", json!("RS256")),
        ("crit", json!(["custom"])),
        ("b64", json!(false)),
        ("jku", json!("https://attacker.example/keys")),
        ("x5u", json!("https://attacker.example/cert")),
    ] {
        let mut header = proof_header();
        header[name] = value;
        assert_eq!(
            verify_dpop(&sign_values(&header, &proof_claims()), &expectation()),
            Err(AuthError::InvalidProof),
            "{name}"
        );
    }
}

#[test]
fn proof_uri_normalization_excludes_query_fragment_and_retains_path() {
    let mut expected = expectation();
    expected.uri = "https://RELAY.example:443/v1/auth/enroll?a=b#ignored".into();
    let claims = proof_claims();
    assert!(verify_dpop(&sign_values(&proof_header(), &claims), &expected).is_ok());
    expected.uri = "https://relay.example/v1/auth/enroll/".into();
    assert_eq!(
        verify_dpop(&sign_values(&proof_header(), &claims), &expected),
        Err(AuthError::InvalidProof)
    );
    let mut local = claims.clone();
    local["htu"] = json!("http://127.0.0.1:8080/v1/auth/enroll");
    expected.uri = "http://127.0.0.1:8080/v1/auth/enroll".into();
    assert!(verify_dpop(&sign_values(&proof_header(), &local), &expected).is_ok());
    local["htu"] = json!("http://relay.example/v1/auth/enroll");
    expected.uri = "http://relay.example/v1/auth/enroll".into();
    assert_eq!(
        verify_dpop(&sign_values(&proof_header(), &local), &expected),
        Err(AuthError::InvalidProof)
    );
}

#[test]
fn rejects_duplicate_json_members_invalid_signatures_and_algorithm_confusion() {
    let header = proof_header().to_string();
    let claims = proof_claims().to_string();
    let duplicated_claims = claims.replacen('{', &format!("{{\"iat\":{},", NOW), 1);
    assert_eq!(
        verify_dpop(
            &sign_raw(&header, &duplicated_claims, Algorithm::ES256),
            &expectation()
        ),
        Err(AuthError::InvalidProof)
    );
    let duplicated_header = header.replacen('{', "{\"alg\":\"ES256\",", 1);
    assert_eq!(
        verify_dpop(
            &sign_raw(&duplicated_header, &claims, Algorithm::ES256),
            &expectation()
        ),
        Err(AuthError::InvalidProof)
    );
    let mut invalid = sign_raw(&header, &claims, Algorithm::ES256);
    let replacement = if invalid.ends_with('A') { "B" } else { "A" };
    invalid.replace_range(invalid.len() - 1.., replacement);
    assert_eq!(
        verify_dpop(&invalid, &expectation()),
        Err(AuthError::InvalidProof)
    );
    let mut header = Header::new(Algorithm::HS256);
    header.typ = Some("dpop+jwt".into());
    header.jwk = Some(serde_json::from_value(public_jwk(Algorithm::ES256)).unwrap());
    let token = encode(
        &header,
        &proof_claims(),
        &EncodingKey::from_secret(b"fake-key"),
    )
    .unwrap();
    assert_eq!(
        verify_dpop(&token, &expectation()),
        Err(AuthError::InvalidProof)
    );
}

#[test]
fn token_parser_bounds_and_rejects_duplicate_nested_jwk_members() {
    for token in ["", "a.b", "a.b.c.d", "a==.b.c"] {
        assert!(json::token_parts(token).is_err());
    }
    assert!(json::token_parts(&"x".repeat(16_385)).is_err());
    assert!(json::parse(br#"{"jwk":{"x":"one","x":"two"}}"#).is_err());
}
