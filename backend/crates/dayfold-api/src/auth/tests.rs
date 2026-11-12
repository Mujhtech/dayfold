use super::*;
use axum::{
    body::{Body, to_bytes},
    http::Request as HttpRequest,
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use dayfold_store::SessionKey;
use jsonwebtoken::{Algorithm, EncodingKey, Header, encode};
use sha2::{Digest, Sha256};
use sqlx::{PgPool, postgres::PgPoolOptions};
use tower::ServiceExt;

const ORIGIN: &str = "https://relay.example.test";
const KEY: &[u8] = include_bytes!("../../../dayfold-apns/tests/fixtures/test-signing-key.p8");

fn proof(method: &str, path: &str, token: Option<&str>) -> String {
    let mut header = Header::new(Algorithm::ES256);
    header.typ = Some("dpop+jwt".into());
    header.jwk = Some(
        serde_json::from_value(json!({
            "kty":"EC", "crv":"P-256", "x":"VOLy0sbTbkREgpjE-cgCBbJIltx6xGTURbfVJW9esmo",
            "y":"SS9coFoFYOUxFiPf-ADVwRW0urJVE8DEd01nIefwHlQ"
        }))
        .unwrap(),
    );
    let mut claims = json!({"htm":method,"htu":format!("{ORIGIN}{path}"),"iat":Utc::now().timestamp(),"jti":Uuid::new_v4()});
    if let Some(token) = token {
        claims["ath"] = json!(URL_SAFE_NO_PAD.encode(Sha256::digest(token.as_bytes())));
    }
    encode(&header, &claims, &EncodingKey::from_ec_pem(KEY).unwrap()).unwrap()
}

fn test_configuration() -> SessionConfiguration {
    // Only middleware/rotation are exercised here. OIDC signature verification
    // has its own real-signed-token tests in dayfold-auth; no network is mocked
    // or disabled in the production verifier by this fixture.
    let config = OidcConfig {
        issuer: "https://issuer.example.test".into(),
        client_ids: vec!["native-client".into()],
        jwks_uri: "https://issuer.example.test/jwks".into(),
    };
    SessionConfiguration {
        verifier: OidcVerifier::new(config).unwrap(),
        client_ids: vec!["native-client".into()],
    }
}

#[tokio::test]
async fn public_api_rejects_legacy_credentials_and_duplicate_security_headers_before_database_work()
{
    let pool = PgPoolOptions::new()
        .connect_lazy("postgres://unused:unused@127.0.0.1:1/unused")
        .unwrap();
    let state = ApiState::new(Store::new(pool), ORIGIN).unwrap();
    for duplicate in [false, true] {
        let mut builder = HttpRequest::builder()
            .uri("/v1/account/devices")
            .header("authorization", format!("Bearer {}", "a".repeat(64)));
        if duplicate {
            builder = builder.header("authorization", format!("Bearer {}", "b".repeat(64)));
        }
        let response = crate::router(state.clone())
            .oneshot(builder.body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
        assert_eq!(response.headers()["cache-control"], "no-store");
        assert!(response.headers().contains_key("www-authenticate"));
    }
}

struct Fixture {
    admin: PgPool,
    pool: PgPool,
    store: Store,
    state: ApiState,
    schema: String,
    jkt: String,
}

#[tokio::test]
async fn malformed_authentication_bodies_consume_the_preauthentication_limit() {
    let pool = PgPoolOptions::new()
        .connect_lazy("postgres://unused:unused@127.0.0.1:1/unused")
        .unwrap();
    let state = ApiState::new(Store::new(pool), ORIGIN).unwrap();
    let app = crate::router(state);
    for attempt in 0..=600 {
        let request = HttpRequest::builder()
            .method("POST")
            .uri("/v1/auth/refresh")
            .header("content-type", "application/json")
            .body(Body::from("{"))
            .unwrap();
        let response = app.clone().oneshot(request).await.unwrap();
        assert_eq!(
            response.status(),
            if attempt < 600 {
                StatusCode::BAD_REQUEST
            } else {
                StatusCode::TOO_MANY_REQUESTS
            }
        );
    }
}

impl Fixture {
    async fn new() -> Self {
        let url = std::env::var("DAYFOLD_TEST_DATABASE_URL")
            .expect("set disposable DAYFOLD_TEST_DATABASE_URL");
        let admin = PgPoolOptions::new()
            .max_connections(1)
            .connect(&url)
            .await
            .unwrap();
        let schema = format!("dayfold_api_test_{}", Uuid::new_v4().simple());
        assert!(
            schema
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')
        );
        sqlx::query(sqlx::AssertSqlSafe(format!("CREATE SCHEMA \"{schema}\"")))
            .execute(&admin)
            .await
            .unwrap();
        let search = format!("SET search_path TO \"{schema}\"");
        let pool = PgPoolOptions::new()
            .max_connections(8)
            .after_connect(move |connection, _| {
                let search = search.clone();
                Box::pin(async move {
                    sqlx::query(sqlx::AssertSqlSafe(search))
                        .execute(connection)
                        .await?;
                    Ok(())
                })
            })
            .connect(&url)
            .await
            .unwrap();
        let store = Store::new(pool.clone()).with_session_key(SessionKey::new([73; 32]));
        store.migrate().await.unwrap();
        let state = ApiState::new(store.clone(), ORIGIN)
            .unwrap()
            .with_session_configuration(test_configuration());
        let signed = proof("POST", "/v1/auth/challenges", None);
        let verified = state
            .proof(
                &HeaderMap::from_iter([("dpop".parse().unwrap(), signed.parse().unwrap())]),
                "POST",
                "/v1/auth/challenges",
                None,
            )
            .unwrap();
        Self {
            admin,
            pool,
            store,
            state,
            schema,
            jkt: verified.thumbprint,
        }
    }

    async fn enroll(&self, subject: &str) -> SessionCredentials {
        let challenge = self
            .store
            .create_auth_challenge("native-client", "Test Mac", &self.jkt)
            .await
            .unwrap();
        self.store
            .enroll_device(
                challenge.id,
                &self.jkt,
                "https://issuer.example.test",
                subject,
                &hash_secret(subject),
            )
            .await
            .unwrap()
    }

    async fn call(&self, method: &str, path: &str, token: Option<&str>, body: Value) -> Response {
        self.call_with_proof(method, path, token, body, &proof(method, path, token))
            .await
    }

    async fn call_with_proof(
        &self,
        method: &str,
        path: &str,
        token: Option<&str>,
        body: Value,
        proof: &str,
    ) -> Response {
        let mut request = HttpRequest::builder()
            .method(method)
            .uri(path)
            .header("dpop", proof);
        if let Some(token) = token {
            request = request.header("authorization", format!("DPoP {token}"));
        }
        let body = if body.is_null() {
            Body::empty()
        } else {
            request = request.header("content-type", "application/json");
            Body::from(body.to_string())
        };
        crate::router(self.state.clone())
            .oneshot(request.body(body).unwrap())
            .await
            .unwrap()
    }

    async fn clean(self) {
        self.pool.close().await;
        sqlx::query(sqlx::AssertSqlSafe(format!(
            "DROP SCHEMA \"{}\" CASCADE",
            self.schema
        )))
        .execute(&self.admin)
        .await
        .unwrap();
        self.admin.close().await;
    }
}

async fn value(response: Response) -> Value {
    serde_json::from_slice(&to_bytes(response.into_body(), 65536).await.unwrap()).unwrap()
}

#[tokio::test]
#[ignore = "requires disposable PostgreSQL"]
async fn dpop_ownership_replay_rotation_and_account_revocation_cross_http_boundary() {
    let f = Fixture::new().await;
    let alice = f.enroll("alice").await;
    let bob = f.enroll("bob").await;
    let other_key = "B".repeat(43);
    let challenge = f
        .store
        .create_auth_challenge("native-client", "Another Mac", &other_key)
        .await
        .unwrap();
    let other_key_session = f
        .store
        .enroll_device(
            challenge.id,
            &other_key,
            "https://issuer.example.test",
            "other-key-user",
            &hash_secret("other-key-user"),
        )
        .await
        .unwrap();
    let path = "/v1/account/devices";
    assert_eq!(
        f.call(
            "GET",
            path,
            Some(&other_key_session.access_token),
            Value::Null
        )
        .await
        .status(),
        StatusCode::UNAUTHORIZED
    );
    let signed = proof("GET", path, Some(&alice.access_token));
    let first = f
        .call_with_proof("GET", path, Some(&alice.access_token), Value::Null, &signed)
        .await;
    assert_eq!(first.status(), StatusCode::OK);
    let devices = value(first).await;
    assert_eq!(devices["devices"].as_array().unwrap().len(), 1);
    assert_eq!(devices["devices"][0]["id"], alice.device_id.to_string());
    assert!(!devices.to_string().contains(&alice.access_token));
    assert_eq!(
        f.call_with_proof("GET", path, Some(&alice.access_token), Value::Null, &signed)
            .await
            .status(),
        StatusCode::UNAUTHORIZED
    );
    let wrong_ath = proof("GET", path, Some(&bob.access_token));
    assert_eq!(
        f.call_with_proof(
            "GET",
            path,
            Some(&alice.access_token),
            Value::Null,
            &wrong_ath
        )
        .await
        .status(),
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        f.call(
            "DELETE",
            &format!("/v1/account/devices/{}", bob.device_id),
            Some(&alice.access_token),
            Value::Null
        )
        .await
        .status(),
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        f.call(
            "PUT",
            "/v1/device/push",
            Some(&alice.access_token),
            json!({"token":"ab".repeat(32),"environment":"sandbox"})
        )
        .await
        .status(),
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        f.call(
            "POST",
            "/v1/channels",
            Some(&alice.access_token),
            json!({"oversized":"x".repeat(16*1024)})
        )
        .await
        .status(),
        StatusCode::PAYLOAD_TOO_LARGE
    );
    let request_id = Uuid::new_v4();
    let body = json!({"refresh_token":alice.refresh_token,"request_id":request_id});
    let rotated = f.call("POST", "/v1/auth/refresh", None, body.clone()).await;
    assert_eq!(rotated.status(), StatusCode::OK);
    let rotated = value(rotated).await;
    let recovered = f.call("POST", "/v1/auth/refresh", None, body).await;
    assert_eq!(recovered.status(), StatusCode::OK);
    assert_eq!(value(recovered).await, rotated);
    // A different use of the consumed token is a replay, not another refresh.
    assert_eq!(
        f.call(
            "POST",
            "/v1/auth/refresh",
            None,
            json!({"refresh_token":alice.refresh_token,"request_id":Uuid::new_v4()})
        )
        .await
        .status(),
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        f.call("GET", path, rotated["access_token"].as_str(), Value::Null)
            .await
            .status(),
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        f.call("GET", path, Some(&bob.access_token), Value::Null)
            .await
            .status(),
        StatusCode::OK
    );
    assert_eq!(
        f.call(
            "POST",
            "/v1/account/revoke-all",
            Some(&bob.access_token),
            Value::Null
        )
        .await
        .status(),
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        f.call("GET", path, Some(&bob.access_token), Value::Null)
            .await
            .status(),
        StatusCode::UNAUTHORIZED
    );
    f.clean().await;
}

#[tokio::test]
#[ignore = "requires disposable PostgreSQL"]
async fn expired_access_closes_an_existing_live_stream() {
    use futures_util::StreamExt;
    let f = Fixture::new().await;
    let credentials = f.enroll("stream-user").await;
    let response = f
        .call(
            "GET",
            "/v1/events",
            Some(&credentials.access_token),
            Value::Null,
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    sqlx::query("UPDATE auth_issuances SET issued_at=now()-interval '20 minutes', access_expires_at=now()-interval '10 minutes' WHERE access_hash=$1")
        .bind(hash_secret(&credentials.access_token)).execute(&f.pool).await.unwrap();
    let mut stream = response.into_body().into_data_stream();
    assert!(
        tokio::time::timeout(std::time::Duration::from_secs(2), stream.next())
            .await
            .unwrap()
            .is_none()
    );
    assert_eq!(
        f.call(
            "GET",
            "/v1/capabilities",
            Some(&credentials.access_token),
            Value::Null
        )
        .await
        .status(),
        StatusCode::UNAUTHORIZED
    );
    f.clean().await;
}

#[tokio::test]
#[ignore = "requires disposable PostgreSQL"]
async fn deleted_account_can_confirm_cleanup_after_a_lost_response() {
    let f = Fixture::new().await;
    let credentials = f.enroll("deleted-user").await;
    let response = f
        .call(
            "DELETE",
            "/v1/account",
            Some(&credentials.access_token),
            Value::Null,
        )
        .await;
    assert_eq!(response.status(), StatusCode::NO_CONTENT);
    // Model a client that never received that successful response. The opaque
    // refresh secret and matching key can confirm revocation after identity and
    // routing rows were erased; they cannot authenticate or recreate the user.
    let response = f
        .call(
            "POST",
            "/v1/auth/refresh",
            None,
            json!({"refresh_token":credentials.refresh_token,"request_id":Uuid::new_v4()}),
        )
        .await;
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    assert_eq!(value(response).await["error"], "reauthentication_required");
    assert_eq!(
        f.call(
            "GET",
            "/v1/account/devices",
            Some(&credentials.access_token),
            Value::Null
        )
        .await
        .status(),
        StatusCode::UNAUTHORIZED
    );
    let (users,): (i64,) = sqlx::query_as("SELECT count(*) FROM users")
        .fetch_one(&f.pool)
        .await
        .unwrap();
    let (devices,): (i64,) = sqlx::query_as("SELECT count(*) FROM devices")
        .fetch_one(&f.pool)
        .await
        .unwrap();
    assert_eq!((users, devices), (0, 0));
    f.clean().await;
}
