//! Run only against a disposable PostgreSQL database:
//! DAYFOLD_TEST_DATABASE_URL=... cargo test -p dayfold-store --test postgres -- --ignored
//! Each test owns a separate random schema. Failed tests retain that schema for inspection.

use chrono::{TimeDelta, Utc};
use dayfold_domain::{NotificationKind, PushEnvironment, hash_secret};
use dayfold_store::{SessionCredentials, SessionKey, Store, StoreError};
use sqlx::{PgPool, postgres::PgPoolOptions};
use std::{
    sync::{Arc, LazyLock},
    time::Duration,
};
use tokio::sync::{Barrier, OwnedSemaphorePermit, Semaphore};
use uuid::Uuid;

struct Fixture {
    admin: PgPool,
    pool: PgPool,
    store: Store,
    schema: String,
    _permit: OwnedSemaphorePermit,
}

static DATABASE_TESTS: LazyLock<Arc<Semaphore>> = LazyLock::new(|| Arc::new(Semaphore::new(4)));

#[tokio::test]
#[ignore = "requires disposable PostgreSQL via DAYFOLD_TEST_DATABASE_URL"]
async fn oidc_enrollment_binds_identity_key_and_single_use_challenge_with_hash_only_credentials() {
    let f = Fixture::new().await;
    let key = "A".repeat(43);
    let challenge = f
        .store
        .create_auth_challenge("native-client", "Personal Mac", &key)
        .await
        .unwrap();
    let identity_token = hash_secret("verified-id-token");
    assert!(matches!(
        f.store
            .enroll_device(
                challenge.id,
                &"B".repeat(43),
                "https://idp.test",
                "owner",
                &identity_token
            )
            .await,
        Err(StoreError::Unauthorized)
    ));
    let first = f
        .store
        .enroll_device(
            challenge.id,
            &key,
            "https://idp.test",
            "owner",
            &identity_token,
        )
        .await
        .unwrap();
    let retry = f
        .store
        .enroll_device(
            challenge.id,
            &key,
            "https://idp.test",
            "owner",
            &identity_token,
        )
        .await
        .unwrap();
    assert_eq!(first.device_id, retry.device_id);
    assert_eq!(first.access_token, retry.access_token);
    assert_eq!(first.refresh_token, retry.refresh_token);
    assert_eq!(first.access_expires_at, retry.access_expires_at);
    assert_eq!(first.refresh_expires_at, retry.refresh_expires_at);
    assert!(matches!(
        f.store
            .enroll_device(
                challenge.id,
                &key,
                "https://idp.test",
                "other",
                &identity_token
            )
            .await,
        Err(StoreError::Unauthorized)
    ));
    assert!(matches!(
        f.store
            .enroll_device(
                challenge.id,
                &key,
                "https://idp.test",
                "owner",
                &hash_secret("different-id-token")
            )
            .await,
        Err(StoreError::Unauthorized)
    ));
    let principal = f
        .store
        .authenticate_access(&hash_secret(&first.access_token))
        .await
        .unwrap();
    assert_eq!(principal.user_id, first.user_id);
    assert_eq!(principal.device_id, first.device_id);
    assert_eq!(principal.key_thumbprint, key);
    assert!(matches!(
        f.store
            .authenticate_access(&hash_secret(&first.refresh_token))
            .await,
        Err(StoreError::Unauthorized)
    ));
    assert!(matches!(
        f.store
            .authenticate(&hash_secret(&first.access_token))
            .await,
        Err(StoreError::Unauthorized)
    ));
    let hashes: (String, String) =
        sqlx::query_as("SELECT access_hash,refresh_hash FROM auth_issuances WHERE family_id=$1")
            .bind(principal.family_id)
            .fetch_one(&f.pool)
            .await
            .unwrap();
    assert_eq!(
        hashes,
        (
            hash_secret(&first.access_token),
            hash_secret(&first.refresh_token)
        )
    );
    let (legacy,): (Option<String>,) =
        sqlx::query_as("SELECT bearer_hash FROM devices WHERE id=$1")
            .bind(first.device_id)
            .fetch_one(&f.pool)
            .await
            .unwrap();
    assert!(legacy.is_none());
    assert!(!format!("{first:?}").contains(&first.access_token));
    let (users,): (i64,) = sqlx::query_as("SELECT count(*) FROM users")
        .fetch_one(&f.pool)
        .await
        .unwrap();
    assert_eq!(users, 1, "failed identity swaps must not create an account");
    let another = f
        .store
        .create_auth_challenge("native-client", "Another Mac", &key)
        .await
        .unwrap();
    let other_issuer = f
        .store
        .enroll_device(
            another.id,
            &key,
            "https://other-idp.test",
            "owner",
            &hash_secret("other-issuer-id-token"),
        )
        .await
        .unwrap();
    assert_ne!(
        first.user_id, other_issuer.user_id,
        "subject equality across issuers never links accounts"
    );
    f.finish().await;
}

#[tokio::test]
#[ignore = "requires disposable PostgreSQL via DAYFOLD_TEST_DATABASE_URL"]
async fn expired_enrollment_is_rejected_and_fresh_same_user_key_authentication_replaces_only_its_family()
 {
    let f = Fixture::new().await;
    let key = "C".repeat(43);
    let challenge = f
        .store
        .create_auth_challenge("native-client", "Mac", &key)
        .await
        .unwrap();
    sqlx::query("UPDATE auth_challenges SET created_at=now()-interval '10 minutes',expires_at=now()-interval '5 minutes' WHERE id=$1")
        .bind(challenge.id).execute(&f.pool).await.unwrap();
    assert!(matches!(
        f.store.auth_challenge(challenge.id, &key).await,
        Err(StoreError::Unauthorized)
    ));
    assert!(matches!(
        f.store
            .enroll_device(
                challenge.id,
                &key,
                "https://idp.test",
                "owner",
                &hash_secret("old")
            )
            .await,
        Err(StoreError::Unauthorized)
    ));
    let first = f.enrolled("same-user", &key).await;
    let notice = f.due_reminder(first.device_id).await;
    let other_device = f.enrolled("same-user", &"D".repeat(43)).await;
    assert_eq!(first.user_id, other_device.user_id);
    assert_ne!(first.device_id, other_device.device_id);
    let replacement = f.enrolled("same-user", &key).await;
    assert_eq!(first.device_id, replacement.device_id);
    assert!(matches!(
        f.store
            .refresh_session(&first.refresh_token, Uuid::new_v4(), &key)
            .await,
        Err(StoreError::RotationSuperseded)
    ));
    assert!(matches!(
        f.store
            .authenticate_access(&hash_secret(&first.access_token))
            .await,
        Err(StoreError::Unauthorized)
    ));
    assert!(
        f.store
            .authenticate_access(&hash_secret(&replacement.access_token))
            .await
            .is_ok()
    );
    assert!(
        f.store
            .authenticate_access(&hash_secret(&other_device.access_token))
            .await
            .is_ok()
    );
    assert_eq!(
        f.store
            .notifications(first.device_id, 0, 100)
            .await
            .unwrap()
            .notifications,
        vec![notice]
    );
    f.finish().await;
}

#[tokio::test]
#[ignore = "requires disposable PostgreSQL via DAYFOLD_TEST_DATABASE_URL"]
async fn concurrent_identical_refreshes_and_process_restart_recover_exactly_one_credential_pair() {
    let f = Fixture::new().await;
    let key = "E".repeat(43);
    let first = f.enrolled("owner", &key).await;
    let request = Uuid::new_v4();
    let barrier = Arc::new(Barrier::new(8));
    let mut tasks = Vec::new();
    for _ in 0..8 {
        let store = f.store.clone();
        let key = key.clone();
        let token = first.refresh_token.clone();
        let barrier = barrier.clone();
        tasks.push(tokio::spawn(async move {
            barrier.wait().await;
            store.refresh_session(&token, request, &key).await.unwrap()
        }));
    }
    let winner = tasks.pop().unwrap().await.unwrap();
    for task in tasks {
        let result = task.await.unwrap();
        assert_eq!(winner.access_token, result.access_token);
        assert_eq!(winner.refresh_token, result.refresh_token);
        assert_eq!(winner.access_expires_at, result.access_expires_at);
    }
    let restarted = Store::new(f.pool.clone()).with_session_key(SessionKey::new([0x3a; 32]));
    let recovered = restarted
        .refresh_session(&first.refresh_token, request, &key)
        .await
        .unwrap();
    assert_eq!(winner.refresh_token, recovered.refresh_token);
    assert_eq!(winner.access_token, recovered.access_token);
    let (generations,): (i64,) = sqlx::query_as("SELECT count(*) FROM auth_issuances")
        .fetch_one(&f.pool)
        .await
        .unwrap();
    assert_eq!(generations, 2);
    assert!(
        f.store
            .authenticate_access(&hash_secret(&winner.access_token))
            .await
            .is_ok()
    );
    f.finish().await;
}

#[tokio::test]
#[ignore = "requires disposable PostgreSQL via DAYFOLD_TEST_DATABASE_URL"]
async fn refresh_replay_revokes_all_device_credentials_and_delivery_work_but_not_another_user() {
    let f = Fixture::new().await;
    let key = "F".repeat(43);
    let first = f.enrolled("owner", &key).await;
    let other = f.enrolled("other", &"G".repeat(43)).await;
    let (channel, channel_secret, _) = f.channel(first.device_id).await;
    f.store
        .register_push(first.device_id, &"aa".repeat(32), PushEnvironment::Sandbox)
        .await
        .unwrap();
    let notice = f.due_reminder(first.device_id).await;
    f.make_pushes_ready().await;
    let leased = f
        .store
        .claim_pushes(1, 120, 12)
        .await
        .unwrap()
        .pop()
        .unwrap();
    let rotated = f
        .store
        .refresh_session(&first.refresh_token, Uuid::new_v4(), &key)
        .await
        .unwrap();
    assert!(matches!(
        f.store
            .refresh_session(&first.refresh_token, Uuid::new_v4(), &"H".repeat(43))
            .await,
        Err(StoreError::Unauthorized)
    ));
    assert!(
        f.store
            .authenticate_access(&hash_secret(&rotated.access_token))
            .await
            .is_ok(),
        "wrong-key theft must not revoke a legitimate session"
    );
    assert!(matches!(
        f.store
            .refresh_session(&first.refresh_token, Uuid::new_v4(), &key)
            .await,
        Err(StoreError::ReauthenticationRequired)
    ));
    assert!(matches!(
        f.store
            .refresh_session(&rotated.refresh_token, Uuid::new_v4(), &key)
            .await,
        Err(StoreError::ReauthenticationRequired)
    ));
    assert!(matches!(
        f.store
            .refresh_session(&rotated.refresh_token, Uuid::new_v4(), &"H".repeat(43))
            .await,
        Err(StoreError::Unauthorized)
    ));
    for token in [&first.access_token, &rotated.access_token] {
        assert!(matches!(
            f.store.authenticate_access(&hash_secret(token)).await,
            Err(StoreError::Unauthorized)
        ));
    }
    assert!(matches!(
        f.store.authenticate_channel(channel, &channel_secret).await,
        Err(StoreError::Unauthorized)
    ));
    let state: (bool, bool, bool, String) = sqlx::query_as("SELECT d.revoked_at IS NOT NULL,d.apns_token IS NULL,r.deleted_at IS NOT NULL,p.status FROM devices d JOIN reminders r ON r.device_id=d.id JOIN push_outbox p ON p.device_id=d.id WHERE d.id=$1 AND r.id=$2")
        .bind(first.device_id).bind(notice.subject_id).fetch_one(&f.pool).await.unwrap();
    assert_eq!(state, (true, true, true, "cancelled".into()));
    assert!(
        !f.store
            .complete_push(leased.id, leased.lease_id)
            .await
            .unwrap()
    );
    assert!(
        f.store
            .authenticate_access(&hash_secret(&other.access_token))
            .await
            .is_ok()
    );
    f.finish().await;
}

#[tokio::test]
#[ignore = "requires disposable PostgreSQL via DAYFOLD_TEST_DATABASE_URL"]
async fn competing_different_refresh_requests_fence_the_winner_after_replay_is_detected() {
    let f = Fixture::new().await;
    let key = "I".repeat(43);
    let first = f.enrolled("owner", &key).await;
    let (a, b) = tokio::join!(
        f.store
            .refresh_session(&first.refresh_token, Uuid::new_v4(), &key),
        f.store
            .refresh_session(&first.refresh_token, Uuid::new_v4(), &key)
    );
    let winner = match (a, b) {
        (Ok(a), Err(StoreError::ReauthenticationRequired)) => a,
        (Err(StoreError::ReauthenticationRequired), Ok(b)) => b,
        other => panic!("unexpected rotation outcomes: {other:?}"),
    };
    assert!(matches!(
        f.store
            .authenticate_access(&hash_secret(&winner.access_token))
            .await,
        Err(StoreError::Unauthorized)
    ));
    f.finish().await;
}

#[tokio::test]
#[ignore = "requires disposable PostgreSQL via DAYFOLD_TEST_DATABASE_URL"]
async fn access_expiry_is_refreshable_but_family_expiry_blocks_workers_and_cancels_routing() {
    let f = Fixture::new().await;
    let key = "J".repeat(43);
    let first = f.enrolled("owner", &key).await;
    sqlx::query("UPDATE auth_issuances SET issued_at=now()-interval '1 hour',access_expires_at=now()-interval '1 second' WHERE access_hash=$1")
        .bind(hash_secret(&first.access_token)).execute(&f.pool).await.unwrap();
    assert!(matches!(
        f.store
            .authenticate_access(&hash_secret(&first.access_token))
            .await,
        Err(StoreError::Unauthorized)
    ));
    let rotated = f
        .store
        .refresh_session(&first.refresh_token, Uuid::new_v4(), &key)
        .await
        .unwrap();
    let principal = f
        .store
        .authenticate_access(&hash_secret(&rotated.access_token))
        .await
        .unwrap();
    f.store
        .register_push(first.device_id, &"ab".repeat(32), PushEnvironment::Sandbox)
        .await
        .unwrap();
    let notice = f.due_reminder(first.device_id).await;
    f.store
        .put_reminder(
            first.device_id,
            Uuid::new_v4(),
            1,
            Utc::now() - TimeDelta::seconds(1),
            Utc::now() + TimeDelta::hours(1),
        )
        .await
        .unwrap();
    sqlx::query("UPDATE auth_families SET created_at=now()-interval '1 day',refresh_expires_at=now()-interval '1 second' WHERE id=$1")
        .bind(principal.family_id).execute(&f.pool).await.unwrap();
    f.make_pushes_ready().await;
    assert_eq!(f.store.materialize_due(100).await.unwrap(), 0);
    assert!(f.store.claim_pushes(100, 120, 12).await.unwrap().is_empty());
    assert!(matches!(
        f.store
            .authenticate_access(&hash_secret(&rotated.access_token))
            .await,
        Err(StoreError::Unauthorized)
    ));
    f.store.cleanup_auth(100).await.unwrap();
    let (revoked, cancelled): (bool, bool) = sqlx::query_as("SELECT d.revoked_at IS NOT NULL,n.cancelled_at IS NOT NULL FROM devices d JOIN notifications n ON n.device_id=d.id WHERE n.id=$1")
        .bind(notice.id).fetch_one(&f.pool).await.unwrap();
    assert!(revoked && cancelled);
    f.finish().await;
}

#[tokio::test]
#[ignore = "requires disposable PostgreSQL via DAYFOLD_TEST_DATABASE_URL"]
async fn expired_refresh_commits_revocation_before_returning_reauthentication_required() {
    let f = Fixture::new().await;
    let key = "K".repeat(43);
    let first = f.enrolled("owner", &key).await;
    sqlx::query("UPDATE auth_families SET created_at=now()-interval '2 days',refresh_expires_at=now()-interval '1 second' WHERE device_id=$1")
        .bind(first.device_id).execute(&f.pool).await.unwrap();
    assert!(matches!(
        f.store
            .refresh_session(&first.refresh_token, Uuid::new_v4(), &key)
            .await,
        Err(StoreError::ReauthenticationRequired)
    ));
    let (revoked,): (bool,) =
        sqlx::query_as("SELECT revoked_at IS NOT NULL FROM devices WHERE id=$1")
            .bind(first.device_id)
            .fetch_one(&f.pool)
            .await
            .unwrap();
    assert!(revoked);
    let fresh = f.enrolled("owner", &key).await;
    assert_eq!(first.user_id, fresh.user_id);
    assert_ne!(first.device_id, fresh.device_id);
    f.finish().await;
}

#[tokio::test]
#[ignore = "requires disposable PostgreSQL via DAYFOLD_TEST_DATABASE_URL"]
async fn superseded_retries_leave_the_current_family_valid_but_current_recovery_timeout_revokes_it()
{
    let f = Fixture::new().await;
    let key = "L".repeat(43);
    let challenge = f
        .store
        .create_auth_challenge("native-client", "Mac", &key)
        .await
        .unwrap();
    let id_hash = hash_secret("id-token");
    let first = f
        .store
        .enroll_device(challenge.id, &key, "https://idp.test", "owner", &id_hash)
        .await
        .unwrap();
    let op = Uuid::new_v4();
    let second = f
        .store
        .refresh_session(&first.refresh_token, op, &key)
        .await
        .unwrap();
    let third = f
        .store
        .refresh_session(&second.refresh_token, Uuid::new_v4(), &key)
        .await
        .unwrap();
    assert!(matches!(
        f.store
            .refresh_session(&first.refresh_token, op, &key)
            .await,
        Err(StoreError::RotationSuperseded)
    ));
    assert!(matches!(
        f.store
            .enroll_device(challenge.id, &key, "https://idp.test", "owner", &id_hash)
            .await,
        Err(StoreError::RotationSuperseded)
    ));
    assert!(
        f.store
            .authenticate_access(&hash_secret(&third.access_token))
            .await
            .is_ok()
    );
    let latest_op = Uuid::new_v4();
    let fourth = f
        .store
        .refresh_session(&third.refresh_token, latest_op, &key)
        .await
        .unwrap();
    sqlx::query(
        "UPDATE auth_issuances SET consumed_at=now()-interval '6 minutes' WHERE refresh_hash=$1",
    )
    .bind(hash_secret(&third.refresh_token))
    .execute(&f.pool)
    .await
    .unwrap();
    assert!(matches!(
        f.store
            .refresh_session(&third.refresh_token, latest_op, &key)
            .await,
        Err(StoreError::ReauthenticationRequired)
    ));
    assert!(matches!(
        f.store
            .authenticate_access(&hash_secret(&fourth.access_token))
            .await,
        Err(StoreError::Unauthorized)
    ));
    f.finish().await;
}

#[tokio::test]
#[ignore = "requires disposable PostgreSQL via DAYFOLD_TEST_DATABASE_URL"]
async fn deployment_key_change_and_late_enrollment_recovery_fail_closed_with_delivery_cleanup() {
    let f = Fixture::new().await;
    let key = "M".repeat(43);
    let first = f.enrolled("owner", &key).await;
    let op = Uuid::new_v4();
    let rotated = f
        .store
        .refresh_session(&first.refresh_token, op, &key)
        .await
        .unwrap();
    let replaced = Store::new(f.pool.clone()).with_session_key(SessionKey::new([0x3b; 32]));
    assert!(matches!(
        replaced
            .refresh_session(&first.refresh_token, op, &key)
            .await,
        Err(StoreError::ReauthenticationRequired)
    ));
    assert!(matches!(
        f.store
            .authenticate_access(&hash_secret(&rotated.access_token))
            .await,
        Err(StoreError::Unauthorized)
    ));
    let challenge = f
        .store
        .create_auth_challenge("native-client", "Mac", &key)
        .await
        .unwrap();
    let id_hash = hash_secret("another-id-token");
    let session = f
        .store
        .enroll_device(challenge.id, &key, "https://idp.test", "owner", &id_hash)
        .await
        .unwrap();
    sqlx::query("UPDATE auth_challenges SET consumed_at=now()-interval '6 minutes' WHERE id=$1")
        .bind(challenge.id)
        .execute(&f.pool)
        .await
        .unwrap();
    assert!(
        f.store.auth_challenge(challenge.id, &key).await.is_ok(),
        "late consumed challenges must reach terminal cleanup"
    );
    assert!(matches!(
        f.store
            .enroll_device(challenge.id, &key, "https://idp.test", "owner", &id_hash)
            .await,
        Err(StoreError::ReauthenticationRequired)
    ));
    assert!(matches!(
        f.store
            .authenticate_access(&hash_secret(&session.access_token))
            .await,
        Err(StoreError::Unauthorized)
    ));
    f.finish().await;
}

#[tokio::test]
#[ignore = "requires disposable PostgreSQL via DAYFOLD_TEST_DATABASE_URL"]
async fn account_actions_require_current_actor_credentials_and_delete_only_the_owned_identity() {
    let f = Fixture::new().await;
    let key = "N".repeat(43);
    let first = f.enrolled("owner", &key).await;
    let sibling = f.enrolled("owner", &"O".repeat(43)).await;
    let other = f.enrolled("other", &"P".repeat(43)).await;
    let first_hash = hash_secret(&first.access_token);
    let devices = f
        .store
        .list_user_devices(first.user_id, first.device_id, &first_hash)
        .await
        .unwrap();
    assert_eq!(devices.len(), 2);
    assert_eq!(devices.iter().filter(|d| d.current).count(), 1);
    assert!(matches!(
        f.store
            .revoke_user_device(first.user_id, other.device_id, &first_hash)
            .await,
        Err(StoreError::NotFound)
    ));
    assert!(matches!(
        f.store
            .list_user_devices(other.user_id, other.device_id, &first_hash)
            .await,
        Err(StoreError::Unauthorized)
    ));
    let replacement = f.enrolled("owner", &key).await;
    assert!(matches!(
        f.store.delete_user(first.user_id, &first_hash).await,
        Err(StoreError::Unauthorized)
    ));
    assert!(matches!(
        f.store
            .revoke_all_user_devices(first.user_id, &first_hash)
            .await,
        Err(StoreError::Unauthorized)
    ));
    assert!(
        f.store
            .authenticate_access(&hash_secret(&replacement.access_token))
            .await
            .is_ok()
    );
    let replacement_hash = hash_secret(&replacement.access_token);
    f.store
        .revoke_user_device(first.user_id, sibling.device_id, &replacement_hash)
        .await
        .unwrap();
    assert!(matches!(
        f.store
            .authenticate_access(&hash_secret(&sibling.access_token))
            .await,
        Err(StoreError::Unauthorized)
    ));
    f.store
        .delete_user(first.user_id, &replacement_hash)
        .await
        .unwrap();
    let (users,devices,challenges): (i64,i64,i64) = sqlx::query_as("SELECT (SELECT count(*) FROM users WHERE id=$1),(SELECT count(*) FROM devices WHERE user_id=$1),(SELECT count(*) FROM auth_challenges WHERE subject='owner')")
        .bind(first.user_id).fetch_one(&f.pool).await.unwrap();
    assert_eq!((users, devices, challenges), (0, 0, 0));
    assert!(
        matches!(
            f.store
                .refresh_session(&replacement.refresh_token, Uuid::new_v4(), &key)
                .await,
            Err(StoreError::ReauthenticationRequired)
        ),
        "lost account-deletion responses must have a bounded terminal confirmation"
    );
    assert!(matches!(
        f.store
            .refresh_session(&replacement.refresh_token, Uuid::new_v4(), &"Z".repeat(43))
            .await,
        Err(StoreError::Unauthorized)
    ));
    let receipt_columns: Vec<(String,)> = sqlx::query_as("SELECT column_name::text FROM information_schema.columns WHERE table_schema=$1 AND table_name='auth_revocation_receipts' ORDER BY ordinal_position")
        .bind(&f.schema).fetch_all(&f.pool).await.unwrap();
    assert_eq!(
        receipt_columns,
        vec![
            ("refresh_hash".into(),),
            ("key_thumbprint".into(),),
            ("expires_at".into(),)
        ]
    );
    sqlx::query("UPDATE auth_revocation_receipts SET expires_at=now()-interval '1 second'")
        .execute(&f.pool)
        .await
        .unwrap();
    f.store.cleanup_auth(1).await.unwrap();
    assert!(matches!(
        f.store
            .refresh_session(&replacement.refresh_token, Uuid::new_v4(), &key)
            .await,
        Err(StoreError::Unauthorized)
    ));
    assert!(
        f.store
            .authenticate_access(&hash_secret(&other.access_token))
            .await
            .is_ok()
    );
    f.finish().await;
}

#[tokio::test]
#[ignore = "requires disposable PostgreSQL via DAYFOLD_TEST_DATABASE_URL"]
async fn dpop_proofs_are_single_use_across_connections_and_gc_outpaces_the_inbox_batch() {
    let f = Fixture::new().await;
    let key = "Q".repeat(43);
    let jti = Uuid::new_v4().to_string();
    let expires = Utc::now() + TimeDelta::seconds(60);
    let (a, b) = tokio::join!(
        f.store.register_dpop_proof(&key, &jti, expires),
        f.store.register_dpop_proof(&key, &jti, expires)
    );
    assert!(matches!(
        (a, b),
        (Ok(()), Err(StoreError::Unauthorized)) | (Err(StoreError::Unauthorized), Ok(()))
    ));
    let restarted = Store::new(f.pool.clone());
    assert!(matches!(
        restarted.register_dpop_proof(&key, &jti, expires).await,
        Err(StoreError::Unauthorized)
    ));
    f.store
        .register_dpop_proof(&"R".repeat(43), &jti, expires)
        .await
        .unwrap();
    assert!(matches!(
        f.store
            .register_dpop_proof(&key, "expired", Utc::now() - TimeDelta::seconds(1))
            .await,
        Err(StoreError::Unauthorized)
    ));
    assert!(matches!(
        f.store
            .register_dpop_proof(&key, "too-far", Utc::now() + TimeDelta::minutes(10))
            .await,
        Err(StoreError::Unauthorized)
    ));
    sqlx::query("INSERT INTO auth_dpop_replays (key_thumbprint,jti_hash,expires_at) SELECT $1,md5(i::text)||md5(i::text),now()-interval '1 second' FROM generate_series(1,600) AS i")
        .bind(&key).execute(&f.pool).await.unwrap();
    assert_eq!(f.store.cleanup_auth(1).await.unwrap(), 600);
    let (count,): (i64,) = sqlx::query_as("SELECT count(*) FROM auth_dpop_replays")
        .fetch_one(&f.pool)
        .await
        .unwrap();
    assert_eq!(count, 2);
    f.finish().await;
}

#[tokio::test]
#[ignore = "requires disposable PostgreSQL via DAYFOLD_TEST_DATABASE_URL"]
async fn revoked_families_are_pruned_without_revoking_the_reauthenticated_device() {
    let f = Fixture::new().await;
    let key = "S".repeat(43);
    let first = f.enrolled("owner", &key).await;
    let active = f.enrolled("owner", &key).await;
    assert_eq!(first.device_id, active.device_id);
    sqlx::query(
        "UPDATE auth_families SET revoked_at=now()-interval '8 days' WHERE revoked_at IS NOT NULL",
    )
    .execute(&f.pool)
    .await
    .unwrap();
    assert_eq!(f.store.cleanup_auth(1).await.unwrap(), 1);
    let (families, issuances): (i64, i64) = sqlx::query_as(
        "SELECT (SELECT count(*) FROM auth_families),(SELECT count(*) FROM auth_issuances)",
    )
    .fetch_one(&f.pool)
    .await
    .unwrap();
    assert_eq!((families, issuances), (1, 1));
    assert!(
        f.store
            .authenticate_access(&hash_secret(&active.access_token))
            .await
            .is_ok()
    );
    f.finish().await;
}

#[tokio::test]
#[ignore = "requires disposable PostgreSQL via DAYFOLD_TEST_DATABASE_URL"]
async fn retained_user_credential_quota_bounds_all_families_and_fails_refresh_with_cleanup() {
    let f = Fixture::new().await;
    let key = "T".repeat(43);
    let session = f.enrolled("owner", &key).await;
    // Twenty retired families each fit below the per-family limit. Together
    // they exercise the account-wide bound that one-family tests cannot cover.
    sqlx::query("INSERT INTO auth_families (id,device_id,created_at,absolute_expires_at,refresh_expires_at,revoked_at) SELECT md5('quota-family-'||i)::uuid,$1,now(),now()+interval '30 days',now()+interval '7 days',now() FROM generate_series(1,20) i")
        .bind(session.device_id).execute(&f.pool).await.unwrap();
    sqlx::query("INSERT INTO auth_issuances (family_id,generation,request_id,access_hash,refresh_hash,key_fingerprint,issued_at,access_expires_at,refresh_expires_at) SELECT f.id,g,md5('request-'||f.id||'-'||g)::uuid,md5('access-'||f.id||'-'||g)||md5('access2-'||f.id||'-'||g),md5('refresh-'||f.id||'-'||g)||md5('refresh2-'||f.id||'-'||g),repeat('0',64),now(),now()+interval '10 minutes',now()+interval '7 days' FROM auth_families f CROSS JOIN generate_series(0,9999) g WHERE f.device_id=$1 AND f.revoked_at IS NOT NULL AND NOT (f.id=md5('quota-family-20')::uuid AND g=9999)")
        .bind(session.device_id).execute(&f.pool).await.unwrap();
    let (count,): (i64,) = sqlx::query_as("SELECT count(*) FROM auth_issuances")
        .fetch_one(&f.pool)
        .await
        .unwrap();
    assert_eq!(count, 200_000);
    let challenge = f
        .store
        .create_auth_challenge("native-client", "Another Mac", &"U".repeat(43))
        .await
        .unwrap();
    assert!(matches!(
        f.store
            .enroll_device(
                challenge.id,
                &challenge.key_thumbprint,
                "https://identity.example.test",
                "owner",
                &hash_secret("capacity-id-token")
            )
            .await,
        Err(StoreError::Capacity)
    ));
    assert!(matches!(
        f.store
            .refresh_session(&session.refresh_token, Uuid::new_v4(), &key)
            .await,
        Err(StoreError::ReauthenticationRequired)
    ));
    let (revoked,): (bool,) =
        sqlx::query_as("SELECT revoked_at IS NOT NULL FROM devices WHERE id=$1")
            .bind(session.device_id)
            .fetch_one(&f.pool)
            .await
            .unwrap();
    assert!(revoked);
    let (after,): (i64,) = sqlx::query_as("SELECT count(*) FROM auth_issuances")
        .fetch_one(&f.pool)
        .await
        .unwrap();
    assert_eq!(
        after, count,
        "quota rejection cannot append another issuance"
    );
    f.finish().await;
}

impl Fixture {
    async fn new() -> Self {
        let permit = DATABASE_TESTS.clone().acquire_owned().await.unwrap();
        let url = std::env::var("DAYFOLD_TEST_DATABASE_URL")
            .expect("set DAYFOLD_TEST_DATABASE_URL to a disposable PostgreSQL database");
        let admin = PgPoolOptions::new()
            .max_connections(1)
            .connect(&url)
            .await
            .unwrap();
        let schema = format!("dayfold_test_{}", Uuid::new_v4().simple());
        // PostgreSQL identifiers cannot be bind parameters. This name is entirely
        // generated here and checked before using SQLx's dynamic-SQL escape hatch.
        assert!(
            schema
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')
        );
        sqlx::query(sqlx::AssertSqlSafe(format!("CREATE SCHEMA \"{schema}\"")))
            .execute(&admin)
            .await
            .unwrap();
        let search_path = format!("SET search_path TO \"{schema}\"");
        let pool = PgPoolOptions::new()
            .max_connections(16)
            .after_connect(move |connection, _| {
                let search_path = search_path.clone();
                Box::pin(async move {
                    sqlx::query(sqlx::AssertSqlSafe(search_path))
                        .execute(connection)
                        .await?;
                    Ok(())
                })
            })
            .connect(&url)
            .await
            .unwrap();
        let store = Store::new(pool.clone()).with_session_key(SessionKey::new([0x3a; 32]));
        store.migrate().await.unwrap();
        Self {
            admin,
            pool,
            store,
            schema,
            _permit: permit,
        }
    }

    async fn enrolled(&self, subject: &str, key: &str) -> SessionCredentials {
        let challenge = self
            .store
            .create_auth_challenge("native-client", "Test Mac", key)
            .await
            .unwrap();
        self.store
            .enroll_device(
                challenge.id,
                key,
                "https://identity.example.test",
                subject,
                &hash_secret(&challenge.nonce),
            )
            .await
            .unwrap()
    }

    async fn device(&self) -> (Uuid, String) {
        let id = Uuid::new_v4();
        let hash = hash_secret(&Uuid::new_v4().to_string());
        self.store.provision(id, &hash).await.unwrap();
        (id, hash)
    }

    async fn channel(&self, device_id: Uuid) -> (Uuid, String, Uuid) {
        let id = Uuid::new_v4();
        let hash = hash_secret(&Uuid::new_v4().to_string());
        let scope = Uuid::new_v4();
        self.store
            .reserve_channel(
                device_id,
                id,
                &hash,
                scope,
                Utc::now() + TimeDelta::hours(1),
            )
            .await
            .unwrap();
        (id, hash, scope)
    }

    async fn make_pushes_ready(&self) {
        sqlx::query("UPDATE push_outbox SET available_at = now() - interval '1 second' WHERE status = 'pending'")
            .execute(&self.pool).await.unwrap();
    }

    async fn due_reminder(&self, device_id: Uuid) -> dayfold_domain::Notification {
        let reminder_id = Uuid::new_v4();
        self.store
            .put_reminder(
                device_id,
                reminder_id,
                1,
                Utc::now() - TimeDelta::seconds(1),
                Utc::now() + TimeDelta::hours(1),
            )
            .await
            .unwrap();
        assert_eq!(self.store.materialize_due(100).await.unwrap(), 1);
        self.store
            .notifications(device_id, 0, 100)
            .await
            .unwrap()
            .notifications
            .pop()
            .unwrap()
    }

    async fn finish(self) {
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

#[tokio::test]
#[ignore = "requires disposable PostgreSQL via DAYFOLD_TEST_DATABASE_URL"]
async fn claiming_a_reminder_before_apns_is_idempotent_and_suppresses_remote_delivery() {
    let f = Fixture::new().await;
    let (device, _) = f.device().await;
    let (other, _) = f.device().await;
    f.store
        .register_push(device, &"ab".repeat(32), PushEnvironment::Sandbox)
        .await
        .unwrap();
    let notification = f.due_reminder(device).await;
    assert!(
        !f.store
            .claim_reminder(other, notification.id)
            .await
            .unwrap()
    );
    assert!(
        !f.store
            .claim_reminder(device, Uuid::new_v4())
            .await
            .unwrap()
    );
    assert!(
        f.store
            .claim_reminder(device, notification.id)
            .await
            .unwrap()
    );
    assert!(
        f.store
            .claim_reminder(device, notification.id)
            .await
            .unwrap()
    );
    f.make_pushes_ready().await;
    assert!(f.store.claim_pushes(100, 120, 12).await.unwrap().is_empty());
    assert_eq!(
        f.store
            .notifications(device, 0, 100)
            .await
            .unwrap()
            .notifications,
        vec![notification.clone()]
    );
    f.store
        .acknowledge(device, notification.sequence)
        .await
        .unwrap();
    assert_eq!(f.store.cleanup(100).await.unwrap(), 1);
    assert_eq!(
        f.store.cursor_bounds(device).await.unwrap(),
        (notification.sequence, notification.sequence)
    );
    f.finish().await;
}

#[tokio::test]
#[ignore = "requires disposable PostgreSQL via DAYFOLD_TEST_DATABASE_URL"]
async fn acknowledging_an_unclaimed_reminder_keeps_apns_ownership_and_retention() {
    let f = Fixture::new().await;
    let (device, _) = f.device().await;
    f.store
        .register_push(device, &"cd".repeat(32), PushEnvironment::Sandbox)
        .await
        .unwrap();
    let notification = f.due_reminder(device).await;
    f.store
        .acknowledge(device, notification.sequence)
        .await
        .unwrap();
    assert_eq!(
        f.store.cleanup(100).await.unwrap(),
        0,
        "pending APNs work must survive an SSE cursor acknowledgement"
    );
    assert_eq!(
        f.store.cursor_bounds(device).await.unwrap(),
        (0, notification.sequence)
    );
    f.make_pushes_ready().await;
    let leased = f
        .store
        .claim_pushes(1, 120, 12)
        .await
        .unwrap()
        .pop()
        .unwrap();
    assert!(
        !f.store
            .claim_reminder(device, notification.id)
            .await
            .unwrap()
    );
    f.store
        .acknowledge(device, notification.sequence)
        .await
        .unwrap();
    assert!(
        f.store
            .push_is_current(leased.id, leased.lease_id)
            .await
            .unwrap()
    );
    assert_eq!(
        f.store.cleanup(100).await.unwrap(),
        0,
        "an outstanding lease is not proof of presentation"
    );
    assert!(
        f.store
            .retry_push(
                leased.id,
                leased.lease_id,
                Utc::now() + TimeDelta::minutes(1),
                12
            )
            .await
            .unwrap()
    );
    assert!(
        !f.store
            .claim_reminder(device, notification.id)
            .await
            .unwrap(),
        "an ambiguous attempted delivery cannot switch to local presentation"
    );
    assert_eq!(f.store.cleanup(100).await.unwrap(), 0);
    f.make_pushes_ready().await;
    let retry = f
        .store
        .claim_pushes(1, 120, 12)
        .await
        .unwrap()
        .pop()
        .unwrap();
    assert!(
        f.store
            .complete_push(retry.id, retry.lease_id)
            .await
            .unwrap()
    );
    assert!(
        !f.store
            .claim_reminder(device, notification.id)
            .await
            .unwrap()
    );
    assert_eq!(
        f.store.cleanup(100).await.unwrap(),
        1,
        "terminal acknowledged work can now be retained only by its cursor floor"
    );
    f.finish().await;
}

#[tokio::test]
#[ignore = "requires disposable PostgreSQL via DAYFOLD_TEST_DATABASE_URL"]
async fn concurrent_client_claim_and_dispatch_choose_exactly_one_presenter() {
    let f = Fixture::new().await;
    for _ in 0..12 {
        let (device, _) = f.device().await;
        f.store
            .register_push(
                device,
                &device.simple().to_string().repeat(2),
                PushEnvironment::Sandbox,
            )
            .await
            .unwrap();
        let notification = f.due_reminder(device).await;
        f.make_pushes_ready().await;
        let (local, remote) = tokio::join!(
            f.store.claim_reminder(device, notification.id),
            f.store.claim_pushes(1, 120, 12)
        );
        let local = local.unwrap();
        let mut remote = remote.unwrap();
        assert_ne!(
            local,
            !remote.is_empty(),
            "local presentation and an APNs attempt must never both win"
        );
        if let Some(job) = remote.pop() {
            assert_eq!(job.notification.id, notification.id);
            assert!(f.store.push_is_current(job.id, job.lease_id).await.unwrap());
            assert!(f.store.complete_push(job.id, job.lease_id).await.unwrap());
        } else {
            assert!(f.store.claim_pushes(1, 120, 12).await.unwrap().is_empty());
        }
    }
    f.finish().await;
}

#[tokio::test]
#[ignore = "requires disposable PostgreSQL via DAYFOLD_TEST_DATABASE_URL"]
async fn push_registration_cannot_take_another_live_installations_endpoint() {
    let f = Fixture::new().await;
    let (owner, _) = f.device().await;
    let (other, _) = f.device().await;
    let token = "ab".repeat(32);
    let other_token = "cd".repeat(32);
    f.store
        .register_push(owner, &token.to_ascii_uppercase(), PushEnvironment::Sandbox)
        .await
        .unwrap();
    f.store
        .register_push(other, &other_token, PushEnvironment::Sandbox)
        .await
        .unwrap();
    assert!(matches!(
        f.store
            .register_push(other, &token, PushEnvironment::Sandbox)
            .await,
        Err(StoreError::Conflict)
    ));
    let bindings: Vec<(Uuid, String, String, i64)> = sqlx::query_as(
        "SELECT id, apns_token, apns_environment, push_revision FROM devices ORDER BY id",
    )
    .fetch_all(&f.pool)
    .await
    .unwrap();
    assert!(bindings.contains(&(owner, token.clone(), "sandbox".into(), 1)));
    assert!(
        bindings.contains(&(other, other_token, "sandbox".into(), 1)),
        "a rejected registration must preserve the other installation's previous endpoint"
    );
    f.store
        .register_push(owner, &token, PushEnvironment::Sandbox)
        .await
        .unwrap();
    let (revision,): (i64,) = sqlx::query_as("SELECT push_revision FROM devices WHERE id = $1")
        .bind(owner)
        .fetch_one(&f.pool)
        .await
        .unwrap();
    assert_eq!(
        revision, 2,
        "the owner may refresh its endpoint registration"
    );
    f.store
        .register_push(other, &token, PushEnvironment::Production)
        .await
        .unwrap();
    f.store.revoke_device(owner).await.unwrap();
    f.store
        .register_push(other, &token, PushEnvironment::Sandbox)
        .await
        .unwrap();
    f.finish().await;
}

#[tokio::test]
#[ignore = "requires disposable PostgreSQL via DAYFOLD_TEST_DATABASE_URL"]
async fn concurrent_push_registration_has_one_owner() {
    let f = Fixture::new().await;
    let (first, _) = f.device().await;
    let (second, _) = f.device().await;
    let token = "ef".repeat(32);
    let (a, b) = tokio::join!(
        f.store
            .register_push(first, &token, PushEnvironment::Sandbox),
        f.store
            .register_push(second, &token, PushEnvironment::Sandbox)
    );
    assert!(matches!(
        (&a, &b),
        (Ok(()), Err(StoreError::Conflict)) | (Err(StoreError::Conflict), Ok(()))
    ));
    let (count,): (i64,) = sqlx::query_as(
        "SELECT count(*) FROM devices WHERE apns_token = $1 AND apns_environment = 'sandbox'",
    )
    .bind(&token)
    .fetch_one(&f.pool)
    .await
    .unwrap();
    assert_eq!(count, 1);
    f.finish().await;
}

#[tokio::test]
#[ignore = "requires disposable PostgreSQL via DAYFOLD_TEST_DATABASE_URL"]
async fn exclusive_push_migration_rejects_existing_duplicates_without_choosing_an_owner() {
    let f = Fixture::new().await;
    let (first, _) = f.device().await;
    let (second, _) = f.device().await;
    // Recreate a pre-migration database containing two live bindings. The
    // migration must fail rather than silently revoke or reassign either one.
    sqlx::query("DROP INDEX devices_exclusive_push_registration")
        .execute(&f.pool)
        .await
        .unwrap();
    let token = "12".repeat(32);
    for device in [first, second] {
        f.store
            .register_push(device, &token, PushEnvironment::Sandbox)
            .await
            .unwrap();
    }
    let error = sqlx::query(include_str!(
        "../migrations/0003_exclusive_push_registration.sql"
    ))
    .execute(&f.pool)
    .await
    .unwrap_err();
    assert!(
        error
            .as_database_error()
            .is_some_and(|error| error.is_unique_violation())
    );
    let (count,): (i64,) = sqlx::query_as("SELECT count(*) FROM devices WHERE apns_token = $1 AND apns_environment = 'sandbox' AND revoked_at IS NULL")
        .bind(&token).fetch_one(&f.pool).await.unwrap();
    assert_eq!(
        count, 2,
        "failed migration must leave duplicate bindings for operator investigation"
    );
    f.finish().await;
}

#[tokio::test]
#[ignore = "requires disposable PostgreSQL via DAYFOLD_TEST_DATABASE_URL"]
async fn channel_and_notification_operations_remain_scoped_to_the_authenticated_installation() {
    let f = Fixture::new().await;
    let (owner, credential) = f.device().await;
    let (other, _) = f.device().await;
    let (channel, secret, _) = f.channel(owner).await;
    assert!(matches!(
        f.store
            .activate_channel(other, channel, "resource", Utc::now() + TimeDelta::hours(1))
            .await,
        Err(StoreError::NotFound)
    ));
    assert!(matches!(
        f.store.revoke_channel(other, channel).await,
        Err(StoreError::NotFound)
    ));
    f.store
        .authenticate_channel(channel, &secret)
        .await
        .unwrap();

    // Reminder identifiers are device-local. The same UUID names two independent
    // schedules; a valid write or cancellation by one owner cannot affect the other.
    let reminder_id = Uuid::new_v4();
    for device in [owner, other] {
        f.store
            .put_reminder(
                device,
                reminder_id,
                1,
                Utc::now() - TimeDelta::seconds(1),
                Utc::now() + TimeDelta::hours(1),
            )
            .await
            .unwrap();
    }
    assert_eq!(f.store.materialize_due(100).await.unwrap(), 2);
    let owned = f
        .store
        .notifications(owner, 0, 100)
        .await
        .unwrap()
        .notifications
        .pop()
        .unwrap();
    let foreign = f
        .store
        .notifications(other, 0, 100)
        .await
        .unwrap()
        .notifications
        .pop()
        .unwrap();
    assert_ne!(owned.id, foreign.id);
    assert_eq!(owned.subject_id, foreign.subject_id);
    assert_eq!(owned.sequence, foreign.sequence);
    assert!(!f.store.claim_reminder(other, owned.id).await.unwrap());
    f.store.acknowledge(other, owned.sequence).await.unwrap();
    assert_eq!(
        f.store
            .authenticate(&credential)
            .await
            .unwrap()
            .acknowledged_sequence,
        0,
        "a sequence in another inbox must not acknowledge the owner's notification"
    );
    f.store
        .put_reminder(
            other,
            reminder_id,
            2,
            Utc::now() + TimeDelta::hours(1),
            Utc::now() + TimeDelta::hours(2),
        )
        .await
        .unwrap();
    f.store
        .delete_reminder(other, reminder_id, 3)
        .await
        .unwrap();
    assert!(
        f.store
            .notifications(other, 0, 100)
            .await
            .unwrap()
            .notifications
            .is_empty()
    );
    assert_eq!(
        f.store
            .notifications(owner, 0, 100)
            .await
            .unwrap()
            .notifications,
        vec![owned.clone()]
    );
    let status: (String, bool, bool) = sqlx::query_as(
        "SELECT p.status, n.client_claimed, n.cancelled_at IS NOT NULL FROM push_outbox p JOIN notifications n ON p.notification_id = n.id WHERE n.id = $1")
        .bind(owned.id).fetch_one(&f.pool).await.unwrap();
    assert_eq!(status, ("pending".into(), false, false));
    f.store.revoke_device(other).await.unwrap();
    assert_eq!(f.store.authenticate(&credential).await.unwrap().id, owner);
    f.store
        .authenticate_channel(channel, &secret)
        .await
        .unwrap();
    assert!(f.store.claim_reminder(owner, owned.id).await.unwrap());
    f.finish().await;
}

#[tokio::test]
#[ignore = "requires disposable PostgreSQL via DAYFOLD_TEST_DATABASE_URL"]
async fn expired_cancelled_and_failed_reminders_cannot_be_claimed_locally() {
    let f = Fixture::new().await;
    let (device, _) = f.device().await;
    f.store
        .register_push(device, &"12".repeat(32), PushEnvironment::Sandbox)
        .await
        .unwrap();
    let cancelled = f.due_reminder(device).await;
    f.store
        .delete_reminder(device, cancelled.subject_id, 2)
        .await
        .unwrap();
    assert!(!f.store.claim_reminder(device, cancelled.id).await.unwrap());
    let expired = f.due_reminder(device).await;
    sqlx::query("UPDATE notifications SET created_at = now() - interval '2 hours', expires_at = now() - interval '1 hour' WHERE id = $1")
        .bind(expired.id).execute(&f.pool).await.unwrap();
    assert!(!f.store.claim_reminder(device, expired.id).await.unwrap());
    let failed = f.due_reminder(device).await;
    f.make_pushes_ready().await;
    let job = f
        .store
        .claim_pushes(1, 120, 12)
        .await
        .unwrap()
        .pop()
        .unwrap();
    assert_eq!(job.notification.id, failed.id);
    assert!(f.store.dead_push(job.id, job.lease_id).await.unwrap());
    assert!(!f.store.claim_reminder(device, failed.id).await.unwrap());
    f.finish().await;
}

#[tokio::test]
#[ignore = "requires disposable PostgreSQL via DAYFOLD_TEST_DATABASE_URL"]
async fn early_callbacks_bind_identity_and_duplicate_or_old_messages_do_not_lose_hints() {
    let f = Fixture::new().await;
    let (device, credential) = f.device().await;
    let (other, _) = f.device().await;
    let channel = Uuid::new_v4();
    let secret = hash_secret("channel-test-secret");
    let scope = Uuid::new_v4();
    let reserved = f
        .store
        .reserve_channel(
            device,
            channel,
            &secret,
            scope,
            Utc::now() + TimeDelta::hours(1),
        )
        .await
        .unwrap();
    assert_eq!(f.store.authenticate(&credential).await.unwrap().id, device);
    f.store
        .authenticate_channel(channel, &secret)
        .await
        .unwrap();
    assert!(matches!(
        f.store
            .authenticate_channel(channel, &hash_secret("wrong"))
            .await,
        Err(StoreError::Unauthorized)
    ));
    assert!(matches!(
        f.store.authenticate(&hash_secret("wrong")).await,
        Err(StoreError::Unauthorized)
    ));
    assert!(matches!(
        f.store
            .accept_webhook(channel, &hash_secret("wrong"), "resource", "sync", "1")
            .await,
        Err(StoreError::Unauthorized)
    ));

    let first = f
        .store
        .accept_webhook(channel, &secret, "resource", "sync", "1")
        .await
        .unwrap();
    assert!(!first.duplicate);
    assert_eq!(first.notification.unwrap().sequence, 1);
    assert!(matches!(
        f.store
            .accept_webhook(channel, &secret, "other-resource", "sync", "2")
            .await,
        Err(StoreError::Conflict)
    ));
    assert!(matches!(
        f.store
            .activate_channel(other, channel, "resource", reserved.expires_at)
            .await,
        Err(StoreError::NotFound)
    ));
    assert!(matches!(
        f.store
            .activate_channel(device, channel, "other-resource", reserved.expires_at)
            .await,
        Err(StoreError::Conflict)
    ));
    let activated = f
        .store
        .activate_channel(
            device,
            channel,
            "resource",
            reserved.expires_at + TimeDelta::hours(1),
        )
        .await
        .unwrap();
    assert_eq!(
        activated.expires_at, reserved.expires_at,
        "activation must not extend a reservation"
    );
    assert_eq!(activated.resource_id.as_deref(), Some("resource"));
    assert!(activated.activated_at.is_some());
    let shortened = f
        .store
        .activate_channel(
            device,
            channel,
            "resource",
            reserved.expires_at - TimeDelta::minutes(10),
        )
        .await
        .unwrap();
    assert!(shortened.expires_at < reserved.expires_at);

    f.store
        .accept_webhook(channel, &secret, "resource", "exists", "10")
        .await
        .unwrap();
    let duplicate = f
        .store
        .accept_webhook(channel, &secret, "resource", "exists", "00010")
        .await
        .unwrap();
    assert!(duplicate.duplicate);
    assert!(duplicate.notification.is_none());
    f.store
        .accept_webhook(channel, &secret, "resource", "exists", "8")
        .await
        .unwrap();
    let page = f.store.notifications(device, 0, 100).await.unwrap();
    assert_eq!(page.notifications.len(), 3);
    assert_eq!(page.latest_sequence, 3);
    assert!(page.notifications.iter().all(|n| n.subject_id == scope
        && n.kind == NotificationKind::CalendarChanged
        && n.revision.is_none()));
    assert!(
        f.store
            .notifications(other, 0, 100)
            .await
            .unwrap()
            .notifications
            .is_empty()
    );
    f.store.revoke_device(device).await.unwrap();
    assert!(matches!(
        f.store.authenticate_channel(channel, &secret).await,
        Err(StoreError::Unauthorized)
    ));
    assert!(matches!(
        f.store.authenticate(&credential).await,
        Err(StoreError::Unauthorized)
    ));
    assert!(matches!(
        f.store
            .accept_webhook(channel, &secret, "resource", "exists", "11")
            .await,
        Err(StoreError::Unauthorized)
    ));
    f.finish().await;
}

#[tokio::test]
#[ignore = "requires disposable PostgreSQL via DAYFOLD_TEST_DATABASE_URL"]
async fn concurrent_callbacks_can_be_replayed_without_commit_order_gaps() {
    let f = Fixture::new().await;
    let (device, _) = f.device().await;
    let (channel, secret, _) = f.channel(device).await;
    let barrier = Arc::new(Barrier::new(25));
    let mut writers = tokio::task::JoinSet::new();
    for message in 1..=24 {
        let store = f.store.clone();
        let secret = secret.clone();
        let barrier = barrier.clone();
        writers.spawn(async move {
            barrier.wait().await;
            store
                .accept_webhook(
                    channel,
                    &secret,
                    "concurrent-resource",
                    "exists",
                    &message.to_string(),
                )
                .await
        });
    }
    barrier.wait().await;
    let mut cursor = 0;
    tokio::time::timeout(Duration::from_secs(20), async {
        while cursor < 24 {
            let page = f.store.notifications(device, cursor, 3).await.unwrap();
            assert!(!page.reset_required);
            for notification in page.notifications {
                assert_eq!(
                    notification.sequence,
                    cursor + 1,
                    "a cursor must never skip a later-committing transaction"
                );
                cursor = notification.sequence;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("concurrent callbacks did not become visible");
    while let Some(result) = writers.join_next().await {
        let outcome = result.unwrap().unwrap();
        assert!(!outcome.duplicate);
    }
    assert_eq!(f.store.cursor_bounds(device).await.unwrap(), (0, 24));
    f.finish().await;
}

#[tokio::test]
#[ignore = "requires disposable PostgreSQL via DAYFOLD_TEST_DATABASE_URL"]
async fn reminder_updates_and_tombstones_cancel_materialized_and_leased_deliveries() {
    let f = Fixture::new().await;
    let (device, _) = f.device().await;
    f.store
        .register_push(device, &"ab".repeat(32), PushEnvironment::Sandbox)
        .await
        .unwrap();
    let reminder = Uuid::new_v4();
    let due = Utc::now() - TimeDelta::seconds(1);
    let expires = due + TimeDelta::hours(1);
    f.store
        .put_reminder(device, reminder, 1, due, expires)
        .await
        .unwrap();
    f.store
        .put_reminder(device, reminder, 1, due, expires)
        .await
        .unwrap();
    assert_eq!(f.store.materialize_due(100).await.unwrap(), 1);
    assert_eq!(f.store.materialize_due(100).await.unwrap(), 0);
    let page = f.store.notifications(device, 0, 100).await.unwrap();
    assert_eq!(page.notifications.len(), 1);
    assert_eq!(page.notifications[0].revision, Some(1));
    f.make_pushes_ready().await;
    let first = f
        .store
        .claim_pushes(1, 120, 12)
        .await
        .unwrap()
        .pop()
        .unwrap();
    assert!(
        f.store
            .push_is_current(first.id, first.lease_id)
            .await
            .unwrap()
    );

    let future = Utc::now() + TimeDelta::minutes(10);
    f.store
        .put_reminder(device, reminder, 2, future, future + TimeDelta::hours(1))
        .await
        .unwrap();
    assert!(
        !f.store
            .push_is_current(first.id, first.lease_id)
            .await
            .unwrap()
    );
    assert!(
        f.store
            .notifications(device, 0, 100)
            .await
            .unwrap()
            .notifications
            .is_empty()
    );
    assert!(matches!(
        f.store
            .put_reminder(device, reminder, 1, due, expires)
            .await,
        Err(StoreError::Conflict)
    ));
    assert_eq!(f.store.materialize_due(100).await.unwrap(), 0);

    f.store
        .put_reminder(device, reminder, 3, due, expires)
        .await
        .unwrap();
    assert_eq!(f.store.materialize_due(100).await.unwrap(), 1);
    f.make_pushes_ready().await;
    let next = f
        .store
        .claim_pushes(1, 120, 12)
        .await
        .unwrap()
        .pop()
        .unwrap();
    assert_eq!(next.notification.revision, Some(3));
    f.store.delete_reminder(device, reminder, 4).await.unwrap();
    f.store.delete_reminder(device, reminder, 4).await.unwrap();
    assert!(
        !f.store
            .push_is_current(next.id, next.lease_id)
            .await
            .unwrap()
    );
    assert!(!f.store.complete_push(next.id, next.lease_id).await.unwrap());
    assert!(
        f.store
            .notifications(device, 0, 100)
            .await
            .unwrap()
            .notifications
            .is_empty()
    );
    assert!(matches!(
        f.store
            .put_reminder(device, reminder, 3, due, expires)
            .await,
        Err(StoreError::Conflict)
    ));
    assert!(matches!(
        f.store
            .put_reminder(device, reminder, 4, due, expires)
            .await,
        Err(StoreError::Conflict)
    ));
    f.store
        .put_reminder(device, reminder, 5, future, future + TimeDelta::hours(1))
        .await
        .unwrap();
    assert_eq!(f.store.materialize_due(100).await.unwrap(), 0);

    // Either the scheduler commits first and cancellation withdraws its work,
    // or the tombstone wins and there is nothing to materialize.
    let race_due = Utc::now() - TimeDelta::seconds(1);
    f.store
        .put_reminder(
            device,
            reminder,
            6,
            race_due,
            race_due + TimeDelta::hours(1),
        )
        .await
        .unwrap();
    let (scheduled, cancelled) = tokio::time::timeout(Duration::from_secs(10), async {
        tokio::join!(
            f.store.materialize_due(100),
            f.store.delete_reminder(device, reminder, 7)
        )
    })
    .await
    .expect("concurrent scheduler/cancellation deadlocked");
    assert!(scheduled.unwrap() <= 1);
    cancelled.unwrap();
    assert!(
        f.store
            .notifications(device, 0, 100)
            .await
            .unwrap()
            .notifications
            .is_empty()
    );
    f.make_pushes_ready().await;
    assert!(f.store.claim_pushes(100, 120, 12).await.unwrap().is_empty());
    f.finish().await;
}

#[tokio::test]
#[ignore = "requires disposable PostgreSQL via DAYFOLD_TEST_DATABASE_URL"]
async fn competing_schedulers_materialize_each_due_revision_once() {
    let f = Fixture::new().await;
    let (first, _) = f.device().await;
    let (second, _) = f.device().await;
    let due = Utc::now() - TimeDelta::seconds(1);
    for device in [first, second] {
        for _ in 0..8 {
            f.store
                .put_reminder(device, Uuid::new_v4(), 1, due, due + TimeDelta::hours(1))
                .await
                .unwrap();
        }
    }
    let (a, b) = tokio::join!(f.store.materialize_due(100), f.store.materialize_due(100));
    assert_eq!(a.unwrap() + b.unwrap(), 16);
    assert_eq!(f.store.materialize_due(100).await.unwrap(), 0);
    for device in [first, second] {
        let page = f.store.notifications(device, 0, 100).await.unwrap();
        assert_eq!(page.notifications.len(), 8);
        let subjects: std::collections::HashSet<_> =
            page.notifications.iter().map(|n| n.subject_id).collect();
        assert_eq!(subjects.len(), 8);
        assert!(
            page.notifications
                .iter()
                .all(|n| n.kind == NotificationKind::ReminderDue && n.revision == Some(1))
        );
    }
    f.finish().await;
}

#[tokio::test]
#[ignore = "requires disposable PostgreSQL via DAYFOLD_TEST_DATABASE_URL"]
async fn expired_leases_are_reclaimed_and_old_workers_cannot_finish_or_retry_them() {
    let f = Fixture::new().await;
    let (device, _) = f.device().await;
    f.store
        .register_push(device, &"cd".repeat(32), PushEnvironment::Sandbox)
        .await
        .unwrap();
    let (channel, secret, _) = f.channel(device).await;
    f.store
        .accept_webhook(channel, &secret, "resource", "sync", "1")
        .await
        .unwrap();
    f.make_pushes_ready().await;
    let old = f
        .store
        .claim_pushes(1, 120, 12)
        .await
        .unwrap()
        .pop()
        .unwrap();
    assert!(f.store.claim_pushes(1, 120, 12).await.unwrap().is_empty());
    sqlx::query("UPDATE push_outbox SET lease_until = now() - interval '1 second' WHERE id = $1")
        .bind(old.id)
        .execute(&f.pool)
        .await
        .unwrap();
    let current = f
        .store
        .claim_pushes(1, 120, 12)
        .await
        .unwrap()
        .pop()
        .unwrap();
    assert_eq!(current.id, old.id);
    assert_ne!(current.lease_id, old.lease_id);
    assert_eq!(current.attempt, old.attempt + 1);
    assert!(!f.store.complete_push(old.id, old.lease_id).await.unwrap());
    assert!(
        !f.store
            .retry_push(
                old.id,
                old.lease_id,
                Utc::now() + TimeDelta::seconds(30),
                12
            )
            .await
            .unwrap()
    );
    assert!(
        f.store
            .push_is_current(current.id, current.lease_id)
            .await
            .unwrap()
    );
    assert!(
        f.store
            .complete_push(current.id, current.lease_id)
            .await
            .unwrap()
    );
    assert!(
        !f.store
            .complete_push(current.id, current.lease_id)
            .await
            .unwrap()
    );
    assert!(f.store.claim_pushes(1, 120, 12).await.unwrap().is_empty());
    f.finish().await;
}

#[tokio::test]
#[ignore = "requires disposable PostgreSQL via DAYFOLD_TEST_DATABASE_URL"]
async fn only_explicit_acknowledgements_cancel_pending_and_leased_pushes() {
    let f = Fixture::new().await;
    let (device, credential) = f.device().await;
    f.store
        .register_push(device, &"ef".repeat(32), PushEnvironment::Sandbox)
        .await
        .unwrap();
    let (channel, secret, _) = f.channel(device).await;
    for number in ["1", "2"] {
        f.store
            .accept_webhook(channel, &secret, "resource", "exists", number)
            .await
            .unwrap();
    }
    assert_eq!(
        f.store
            .notifications(device, 0, 100)
            .await
            .unwrap()
            .notifications
            .len(),
        2
    );
    assert_eq!(
        f.store
            .authenticate(&credential)
            .await
            .unwrap()
            .acknowledged_sequence,
        0
    );
    f.make_pushes_ready().await;
    let leased = f
        .store
        .claim_pushes(1, 120, 12)
        .await
        .unwrap()
        .pop()
        .unwrap();
    assert!(
        f.store
            .push_is_current(leased.id, leased.lease_id)
            .await
            .unwrap()
    );
    f.store.acknowledge(device, 2).await.unwrap();
    f.store.acknowledge(device, 1).await.unwrap();
    assert_eq!(
        f.store
            .authenticate(&credential)
            .await
            .unwrap()
            .acknowledged_sequence,
        2
    );
    assert!(
        !f.store
            .push_is_current(leased.id, leased.lease_id)
            .await
            .unwrap()
    );
    assert!(f.store.claim_pushes(100, 120, 12).await.unwrap().is_empty());
    assert!(matches!(
        f.store.acknowledge(device, 3).await,
        Err(StoreError::Invalid(_))
    ));
    assert!(matches!(
        f.store.acknowledge(device, -1).await,
        Err(StoreError::Invalid(_))
    ));
    f.finish().await;
}

#[tokio::test]
#[ignore = "requires disposable PostgreSQL via DAYFOLD_TEST_DATABASE_URL"]
async fn stale_apns_rejections_requeue_for_newer_registrations_and_newer_token_timestamps() {
    let f = Fixture::new().await;
    let (device, _) = f.device().await;
    let token = "ab".repeat(32);
    f.store
        .register_push(device, &token, PushEnvironment::Sandbox)
        .await
        .unwrap();
    let (channel, secret, _) = f.channel(device).await;
    f.store
        .accept_webhook(channel, &secret, "resource", "exists", "1")
        .await
        .unwrap();
    f.make_pushes_ready().await;
    let old = f
        .store
        .claim_pushes(1, 120, 12)
        .await
        .unwrap()
        .pop()
        .unwrap();
    f.store
        .register_push(device, &token, PushEnvironment::Sandbox)
        .await
        .unwrap();
    assert!(
        f.store
            .invalidate_push_token(old.id, old.lease_id, None)
            .await
            .unwrap()
    );
    f.make_pushes_ready().await;
    let current = f
        .store
        .claim_pushes(1, 120, 12)
        .await
        .unwrap()
        .pop()
        .unwrap();
    assert_eq!(current.token, token);
    assert_eq!(current.notification.sequence, 1);
    assert_eq!(
        current.id, old.id,
        "a stale rejection must not discard the notification"
    );
    assert_ne!(current.lease_id, old.lease_id);
    assert_eq!(current.attempt, old.attempt + 1);
    assert!(
        f.store
            .invalidate_push_token(
                current.id,
                current.lease_id,
                Some(Utc::now() - TimeDelta::days(1))
            )
            .await
            .unwrap()
    );
    f.make_pushes_ready().await;
    let after_old_timestamp = f
        .store
        .claim_pushes(1, 120, 12)
        .await
        .unwrap()
        .pop()
        .unwrap();
    assert_eq!(after_old_timestamp.token, token);
    assert_eq!(after_old_timestamp.id, current.id);
    assert_eq!(after_old_timestamp.attempt, current.attempt + 1);
    assert!(
        f.store
            .invalidate_push_token(after_old_timestamp.id, after_old_timestamp.lease_id, None)
            .await
            .unwrap()
    );
    f.store
        .accept_webhook(channel, &secret, "resource", "exists", "2")
        .await
        .unwrap();
    f.make_pushes_ready().await;
    assert!(
        f.store.claim_pushes(100, 120, 12).await.unwrap().is_empty(),
        "a current invalid registration must be cleared"
    );
    f.finish().await;
}

#[tokio::test]
#[ignore = "requires disposable PostgreSQL via DAYFOLD_TEST_DATABASE_URL"]
async fn retention_exposes_a_reset_boundary_without_pruning_past_a_live_prefix() {
    let f = Fixture::new().await;
    let (device, _) = f.device().await;
    let (channel, secret, _) = f.channel(device).await;
    for number in ["1", "2", "3"] {
        f.store
            .accept_webhook(channel, &secret, "resource", "exists", number)
            .await
            .unwrap();
    }
    sqlx::query("UPDATE notifications SET created_at = now() - interval '2 hours', expires_at = now() - interval '1 hour' WHERE device_id = $1 AND sequence = 1")
        .bind(device).execute(&f.pool).await.unwrap();
    sqlx::query("UPDATE notifications SET created_at = now() - interval '8 days' WHERE device_id = $1 AND sequence = 3")
        .bind(device).execute(&f.pool).await.unwrap();
    assert_eq!(f.store.cleanup(100).await.unwrap(), 1);
    let stale = f.store.notifications(device, 0, 100).await.unwrap();
    assert!(stale.reset_required);
    assert!(stale.notifications.is_empty());
    assert_eq!((stale.cursor_floor, stale.latest_sequence), (1, 3));
    assert_eq!(f.store.cursor_bounds(device).await.unwrap(), (1, 3));
    let resumed = f.store.notifications(device, 1, 100).await.unwrap();
    assert!(!resumed.reset_required);
    assert_eq!(resumed.notifications.first().unwrap().sequence, 2);
    f.store.acknowledge(device, 2).await.unwrap();
    assert_eq!(f.store.cleanup(100).await.unwrap(), 2);
    assert_eq!(f.store.cursor_bounds(device).await.unwrap(), (3, 3));
    let current = f.store.notifications(device, 3, 100).await.unwrap();
    assert!(!current.reset_required);
    assert!(current.notifications.is_empty());
    f.finish().await;
}

#[tokio::test]
#[ignore = "requires disposable PostgreSQL via DAYFOLD_TEST_DATABASE_URL"]
async fn a_full_inbox_rejects_a_webhook_atomically_and_allows_retry_after_acknowledgement() {
    let f = Fixture::new().await;
    // The full installation sorts first, making LIMIT 1 a regression check for
    // starvation of later installations that still have room in their inboxes.
    let device = Uuid::from_u128(1);
    let other = Uuid::from_u128(2);
    f.store
        .provision(device, &hash_secret("full-inbox-installation"))
        .await
        .unwrap();
    f.store
        .provision(other, &hash_secret("available-inbox-installation"))
        .await
        .unwrap();
    let (channel, secret, scope) = f.channel(device).await;
    sqlx::query(
        "INSERT INTO notifications (device_id, sequence, id, kind, subject_id, expires_at) \
         SELECT $1, n, gen_random_uuid(), 'calendar_changed', $2, now() + interval '1 hour' \
         FROM generate_series(1, 10000) AS series(n)",
    )
    .bind(device)
    .bind(scope)
    .execute(&f.pool)
    .await
    .unwrap();
    sqlx::query("UPDATE devices SET last_sequence = 10000 WHERE id = $1")
        .bind(device)
        .execute(&f.pool)
        .await
        .unwrap();

    assert!(matches!(
        f.store
            .accept_webhook(channel, &secret, "new-resource", "sync", "1")
            .await,
        Err(StoreError::Capacity)
    ));
    let (receipts,): (i64,) =
        sqlx::query_as("SELECT count(*) FROM webhook_receipts WHERE channel_id = $1")
            .bind(channel)
            .fetch_one(&f.pool)
            .await
            .unwrap();
    assert_eq!(
        receipts, 0,
        "a failed delivery must remain eligible for Google retry"
    );
    let (binding,): (Option<String>,) =
        sqlx::query_as("SELECT resource_id FROM channels WHERE id = $1")
            .bind(channel)
            .fetch_one(&f.pool)
            .await
            .unwrap();
    assert!(
        binding.is_none(),
        "the rejected callback must not partially bind a resource"
    );
    assert_eq!(f.store.cursor_bounds(device).await.unwrap(), (0, 10000));

    let blocked_reminder = Uuid::new_v4();
    let other_reminder = Uuid::new_v4();
    let due = Utc::now() - TimeDelta::seconds(1);
    for (owner, reminder) in [(device, blocked_reminder), (other, other_reminder)] {
        f.store
            .put_reminder(owner, reminder, 1, due, due + TimeDelta::hours(1))
            .await
            .unwrap();
    }
    assert_eq!(
        f.store.materialize_due(1).await.unwrap(),
        1,
        "a full first installation must not starve a later one"
    );
    let other_page = f.store.notifications(other, 0, 100).await.unwrap();
    assert_eq!(other_page.notifications.len(), 1);
    assert_eq!(
        other_page.notifications[0].kind,
        NotificationKind::ReminderDue
    );
    assert_eq!(other_page.notifications[0].subject_id, other_reminder);
    assert_eq!(f.store.cursor_bounds(device).await.unwrap(), (0, 10000));

    f.store.acknowledge(device, 10000).await.unwrap();
    // The next enqueue can prune the acknowledged prefix in the same transaction;
    // retry does not need to wait for a separate cleanup worker pass.
    let retried = f
        .store
        .accept_webhook(channel, &secret, "new-resource", "sync", "1")
        .await
        .unwrap();
    assert!(!retried.duplicate);
    assert_eq!(retried.notification.unwrap().sequence, 10001);
    assert_eq!(f.store.cursor_bounds(device).await.unwrap(), (10000, 10001));
    let resumed = f.store.notifications(device, 10000, 100).await.unwrap();
    assert!(!resumed.reset_required);
    assert_eq!(resumed.notifications.len(), 1);
    assert_eq!(resumed.notifications[0].subject_id, scope);
    assert_eq!(
        f.store.materialize_due(1).await.unwrap(),
        1,
        "the previously blocked reminder must remain pending until capacity returns"
    );
    let unblocked = f.store.notifications(device, 10001, 100).await.unwrap();
    assert_eq!(unblocked.notifications.len(), 1);
    assert_eq!(unblocked.notifications[0].subject_id, blocked_reminder);
    assert_eq!(
        unblocked.notifications[0].kind,
        NotificationKind::ReminderDue
    );
    f.finish().await;
}
