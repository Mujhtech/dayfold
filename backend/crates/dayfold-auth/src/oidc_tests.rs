use super::*;
use crate::tests::{NOW, public_jwk, sign_raw, signing_key};
use jsonwebtoken::{Header, encode};
use serde_json::json;
use std::{collections::VecDeque, sync::Mutex as StdMutex};

#[derive(Default)]
struct FakeTransport {
    requests: StdMutex<Vec<Url>>,
    responses: StdMutex<VecDeque<Result<Vec<u8>, AuthError>>>,
}
impl Transport for FakeTransport {
    fn get(&self, url: Url) -> FetchFuture<'_> {
        self.requests.lock().unwrap().push(url);
        let response = self
            .responses
            .lock()
            .unwrap()
            .pop_front()
            .unwrap_or(Err(AuthError::Unavailable));
        Box::pin(async move { response })
    }
}
impl FakeTransport {
    fn respond(&self, value: Value) {
        self.responses
            .lock()
            .unwrap()
            .push_back(Ok(serde_json::to_vec(&value).unwrap()));
    }
    fn count(&self) -> usize {
        self.requests.lock().unwrap().len()
    }
}

fn config() -> OidcConfig {
    OidcConfig {
        issuer: "https://id.example/tenant".into(),
        client_ids: vec!["native-client".into()],
        jwks_uri: "https://keys.example/trusted.json".into(),
    }
}
fn metadata() -> Value {
    json!({"issuer": config().issuer, "jwks_uri":config().jwks_uri, "authorization_endpoint":"https://id.example/authorize", "token_endpoint":"https://id.example/token"})
}
fn jwks(algorithm: Algorithm, kid: &str) -> Value {
    let mut jwk = public_jwk(algorithm);
    jwk["kid"] = json!(kid);
    json!({"keys":[jwk]})
}
fn fixture(algorithm: Algorithm) -> (OidcVerifier, Arc<FakeTransport>) {
    let transport = Arc::new(FakeTransport::default());
    transport.respond(metadata());
    transport.respond(jwks(algorithm, "trusted-key"));
    (
        OidcVerifier::with_transport(config(), transport.clone()).unwrap(),
        transport,
    )
}
fn claims() -> Value {
    json!({"iss":config().issuer, "sub":"stable-subject", "aud":"native-client", "iat":NOW, "exp":NOW+300, "nonce":"challenge-nonce"})
}
fn token(algorithm: Algorithm, claims: &Value, kid: &str) -> String {
    let mut header = Header::new(algorithm);
    header.kid = Some(kid.into());
    encode(&header, claims, &signing_key(algorithm)).unwrap()
}
async fn verify(verifier: &OidcVerifier, token: &str) -> Result<VerifiedIdentity, AuthError> {
    verifier
        .verify(token, "native-client", "challenge-nonce", NOW - 30, NOW)
        .await
}

#[tokio::test]
async fn verifies_rs256_and_es256_with_pinned_discovery_and_cached_keys() {
    for algorithm in [Algorithm::RS256, Algorithm::ES256] {
        let (verifier, transport) = fixture(algorithm);
        let jwt = token(algorithm, &claims(), "trusted-key");
        let identity = verify(&verifier, &jwt).await.unwrap();
        assert_eq!(
            identity,
            VerifiedIdentity {
                issuer: config().issuer,
                subject: "stable-subject".into(),
                client_id: "native-client".into()
            }
        );
        assert!(verify(&verifier.clone(), &jwt).await.is_ok());
        assert_eq!(transport.count(), 2);
        assert_eq!(
            transport.requests.lock().unwrap()[0].as_str(),
            "https://id.example/tenant/.well-known/openid-configuration"
        );
        assert_eq!(
            transport.requests.lock().unwrap()[1].as_str(),
            config().jwks_uri
        );
    }
}

#[test]
fn rejects_insecure_ambiguous_or_empty_configuration() {
    for issuer in [
        "http://id.example",
        "https://user@id.example",
        "https://id.example#fragment",
        "https://id.example?query",
        "https://id.example\n",
    ] {
        let mut c = config();
        c.issuer = issuer.into();
        assert!(matches!(
            OidcVerifier::with_transport(c, Arc::new(FakeTransport::default())),
            Err(AuthError::InvalidConfiguration)
        ));
    }
    for clients in [vec![], vec!["".into()], vec!["same".into(), "same".into()]] {
        let mut c = config();
        c.client_ids = clients;
        assert!(OidcVerifier::with_transport(c, Arc::new(FakeTransport::default())).is_err());
    }
    let mut c = config();
    c.jwks_uri = "http://keys.example".into();
    assert!(OidcVerifier::with_transport(c, Arc::new(FakeTransport::default())).is_err());
}

#[tokio::test]
async fn discovery_rejects_issuer_key_location_and_endpoint_substitution() {
    for (name, value) in [
        ("issuer", "https://attacker.example"),
        ("issuer", "https://id.example/tenant/"),
        ("jwks_uri", "https://attacker.example/keys"),
        ("authorization_endpoint", "http://id.example/authorize"),
        ("token_endpoint", "https://user@id.example/token"),
    ] {
        let transport = Arc::new(FakeTransport::default());
        let mut meta = metadata();
        meta[name] = json!(value);
        transport.respond(meta);
        let verifier = OidcVerifier::with_transport(config(), transport.clone()).unwrap();
        assert_eq!(
            verifier.discover_metadata().await,
            Err(AuthError::Unavailable),
            "{name}"
        );
        assert_eq!(
            verifier.discover_metadata().await,
            Err(AuthError::Unavailable)
        );
        assert_eq!(transport.count(), 1);
    }
}

#[tokio::test]
async fn requires_all_typed_oidc_claims_including_iat_and_nonce() {
    let (verifier, _) = fixture(Algorithm::ES256);
    for name in ["iss", "sub", "aud", "exp", "iat", "nonce"] {
        let mut value = claims();
        value.as_object_mut().unwrap().remove(name);
        assert_eq!(
            verify(&verifier, &token(Algorithm::ES256, &value, "trusted-key")).await,
            Err(AuthError::InvalidToken),
            "{name}"
        );
    }
    for (name, value) in [
        ("iss", json!("https://attacker.example")),
        ("sub", json!("")),
        ("aud", json!("wrong-client")),
        ("nonce", json!("other-challenge")),
        ("iat", json!(NOW.to_string())),
        ("iat", json!(NOW as f64 + 0.5)),
        ("exp", json!((NOW + 100).to_string())),
        ("nonce", Value::Null),
    ] {
        let mut body = claims();
        body[name] = value;
        assert_eq!(
            verify(&verifier, &token(Algorithm::ES256, &body, "trusted-key")).await,
            Err(AuthError::InvalidToken),
            "{name}"
        );
    }
}

#[tokio::test]
async fn validates_audience_azp_and_fresh_challenge_times() {
    let (mut verifier, _) = fixture(Algorithm::ES256);
    let mut body = claims();
    body["aud"] = json!(["native-client", "other-client"]);
    assert_eq!(
        verify(&verifier, &token(Algorithm::ES256, &body, "trusted-key")).await,
        Err(AuthError::InvalidToken)
    );
    body["azp"] = json!("native-client");
    assert_eq!(
        verify(&verifier, &token(Algorithm::ES256, &body, "trusted-key")).await,
        Err(AuthError::InvalidToken)
    );
    verifier.config.client_ids.push("other-client".into());
    assert!(
        verify(&verifier, &token(Algorithm::ES256, &body, "trusted-key"))
            .await
            .is_ok()
    );
    for (name, value) in [
        ("azp", json!("wrong-client")),
        ("aud", json!([])),
        ("aud", json!(["native-client", "native-client"])),
        ("iat", json!(NOW + 61)),
        ("iat", json!(NOW - 91)),
        ("exp", json!(NOW)),
        ("exp", json!(NOW - 1)),
        ("nbf", json!(NOW + 61)),
    ] {
        let mut body = claims();
        body[name] = value;
        assert_eq!(
            verify(&verifier, &token(Algorithm::ES256, &body, "trusted-key")).await,
            Err(AuthError::InvalidToken),
            "{name}"
        );
    }
    let jwt = token(Algorithm::ES256, &claims(), "trusted-key");
    assert_eq!(
        verifier
            .verify(&jwt, "not-allowlisted", "challenge-nonce", NOW - 30, NOW)
            .await,
        Err(AuthError::InvalidToken)
    );
    assert_eq!(
        verifier
            .verify(&jwt, "native-client", "challenge-nonce", NOW - 601, NOW)
            .await,
        Err(AuthError::InvalidToken)
    );
    assert_eq!(
        verifier
            .verify(&jwt, "native-client", "challenge-nonce", NOW + 61, NOW)
            .await,
        Err(AuthError::InvalidToken)
    );
}

#[tokio::test]
async fn rejects_duplicate_kid_key_misuse_and_weak_keys() {
    for mutate in 0..6 {
        let transport = Arc::new(FakeTransport::default());
        transport.respond(metadata());
        let mut keys = jwks(Algorithm::ES256, "trusted-key");
        match mutate {
            0 => {
                let key = keys["keys"][0].clone();
                keys["keys"].as_array_mut().unwrap().push(key);
            }
            1 => keys["keys"][0]["d"] = json!("private-material"),
            2 => keys["keys"][0]["use"] = json!("enc"),
            3 => keys["keys"][0]["key_ops"] = json!(["sign"]),
            4 => keys["keys"][0]["alg"] = json!("HS256"),
            _ => keys = json!({"keys":[{"kid":"trusted-key","kty":"RSA","n":"AQID","e":"AQAB"}]}),
        }
        transport.respond(keys);
        let verifier = OidcVerifier::with_transport(config(), transport).unwrap();
        assert_eq!(
            verify(
                &verifier,
                &token(Algorithm::ES256, &claims(), "trusted-key")
            )
            .await,
            Err(AuthError::Unavailable)
        );
    }
}

#[tokio::test]
async fn rejects_untrusted_headers_duplicate_claims_and_bad_signatures() {
    let (verifier, transport) = fixture(Algorithm::ES256);
    for (name, value) in [
        ("alg", json!("HS256")),
        ("jku", json!("https://attacker.example")),
        ("x5u", json!("https://attacker.example")),
        ("jwk", public_jwk(Algorithm::ES256)),
        ("crit", json!(["custom"])),
    ] {
        let mut header = json!({"alg":"ES256","typ":"JWT","kid":"trusted-key"});
        header[name] = value;
        let jwt = sign_raw(&header.to_string(), &claims().to_string(), Algorithm::ES256);
        assert_eq!(verify(&verifier, &jwt).await, Err(AuthError::InvalidToken));
    }
    assert_eq!(transport.count(), 0);
    let header = r#"{"alg":"ES256","typ":"JWT","kid":"trusted-key"}"#;
    let duplicated = claims()
        .to_string()
        .replacen('{', "{\"nonce\":\"second\",", 1);
    assert_eq!(
        verify(&verifier, &sign_raw(header, &duplicated, Algorithm::ES256)).await,
        Err(AuthError::InvalidToken)
    );
    let mut jwt = token(Algorithm::ES256, &claims(), "trusted-key");
    let signature_index = jwt.rfind('.').unwrap() + 1;
    jwt.replace_range(
        signature_index..signature_index + 1,
        if &jwt[signature_index..signature_index + 1] == "A" {
            "B"
        } else {
            "A"
        },
    );
    assert_eq!(verify(&verifier, &jwt).await, Err(AuthError::InvalidToken));
}

#[tokio::test]
async fn unknown_key_refresh_is_rate_limited_and_expired_cache_fails_closed() {
    let (verifier, transport) = fixture(Algorithm::ES256);
    let valid = token(Algorithm::ES256, &claims(), "trusted-key");
    assert!(verify(&verifier, &valid).await.is_ok());
    let unknown = token(Algorithm::ES256, &claims(), "new-key");
    for _ in 0..10 {
        assert_eq!(
            verify(&verifier, &unknown).await,
            Err(AuthError::InvalidToken)
        );
    }
    assert_eq!(transport.count(), 2);
    {
        let mut state = verifier.state.lock().await;
        state.last_keys_attempt = Some(Instant::now() - REFRESH_COOLDOWN - Duration::from_secs(1));
    }
    transport.respond(jwks(Algorithm::ES256, "new-key"));
    assert!(verify(&verifier, &unknown).await.is_ok());
    assert_eq!(transport.count(), 3);
    {
        let mut state = verifier.state.lock().await;
        state.keys.as_mut().unwrap().0 = Instant::now() - CACHE_LIFETIME - Duration::from_secs(1);
        state.last_keys_attempt = Some(Instant::now() - REFRESH_COOLDOWN - Duration::from_secs(1));
    }
    assert_eq!(
        verify(&verifier, &unknown).await,
        Err(AuthError::Unavailable)
    );
    assert_eq!(
        verify(&verifier, &unknown).await,
        Err(AuthError::Unavailable)
    );
    assert_eq!(transport.count(), 4);
}

#[tokio::test]
async fn concurrent_verification_single_flights_discovery_and_keys() {
    let (verifier, transport) = fixture(Algorithm::ES256);
    let jwt = token(Algorithm::ES256, &claims(), "trusted-key");
    let (a, b, c) = tokio::join!(
        verify(&verifier, &jwt),
        verify(&verifier, &jwt),
        verify(&verifier, &jwt)
    );
    assert!(a.is_ok() && b.is_ok() && c.is_ok());
    assert_eq!(transport.count(), 2);
}

#[test]
fn jwks_and_discovery_parsing_are_bounded() {
    assert!(parse_keys(&vec![b' '; MAX_RESPONSE + 1]).is_err());
    let key = jwks(Algorithm::ES256, "trusted-key")["keys"][0].clone();
    assert!(parse_keys(&serde_json::to_vec(&json!({"keys":vec![key;33]})).unwrap()).is_err());
    assert!(parse_keys(br#"{"keys":[],"keys":[]}"#).is_err());
}

#[tokio::test]
async fn production_transport_rejects_cleartext_before_connecting() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = Url::parse(&format!(
        "http://{}/metadata",
        listener.local_addr().unwrap()
    ))
    .unwrap();
    let transport = HttpTransport::new().unwrap();
    assert_eq!(transport.get(url).await, Err(AuthError::Unavailable));
    assert!(
        tokio::time::timeout(Duration::from_millis(50), listener.accept())
            .await
            .is_err()
    );
}

// The production builder is used unchanged except for allowing a loopback-only
// HTTP fixture. No test transport or cleartext override is publicly exported.
async fn http_fixture(response: Vec<u8>) -> (HttpTransport, Url, tokio::task::JoinHandle<usize>) {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let task = tokio::spawn(async move {
        let (mut stream, _) = tokio::time::timeout(Duration::from_secs(2), listener.accept())
            .await
            .unwrap()
            .unwrap();
        let mut buffer = [0u8; 4096];
        assert!(stream.read(&mut buffer).await.unwrap() > 0);
        // A client rejecting a declared size may close before the final chunk.
        let _ = stream.write_all(&response).await;
        let _ = stream.shutdown().await;
        if let Ok(Ok((mut stream, _))) =
            tokio::time::timeout(Duration::from_millis(100), listener.accept()).await
        {
            assert!(stream.read(&mut buffer).await.unwrap() > 0);
            stream
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
                .await
                .unwrap();
            2
        } else {
            1
        }
    });
    let transport = HttpTransport(HttpTransport::builder().https_only(false).build().unwrap());
    (
        transport,
        Url::parse(&format!("http://{address}/metadata")).unwrap(),
        task,
    )
}

#[tokio::test]
async fn metadata_transport_does_not_follow_redirects() {
    let response = b"HTTP/1.1 302 Found\r\nLocation: /attacker-keys\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_vec();
    let (transport, url, server) = http_fixture(response).await;
    assert_eq!(transport.get(url).await, Err(AuthError::Unavailable));
    assert_eq!(server.await.unwrap(), 1);
}

#[tokio::test]
async fn metadata_transport_caps_declared_and_chunked_response_bodies() {
    let body = vec![b'x'; MAX_RESPONSE + 1];
    let mut declared = format!(
        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    )
    .into_bytes();
    declared.extend_from_slice(&body);
    let mut chunked =
        b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n".to_vec();
    chunked.extend_from_slice(format!("{:x}\r\n", body.len()).as_bytes());
    chunked.extend_from_slice(&body);
    chunked.extend_from_slice(b"\r\n0\r\n\r\n");
    for response in [declared, chunked] {
        let (transport, url, server) = http_fixture(response).await;
        assert_eq!(transport.get(url).await, Err(AuthError::Unavailable));
        assert_eq!(server.await.unwrap(), 1);
    }
}
