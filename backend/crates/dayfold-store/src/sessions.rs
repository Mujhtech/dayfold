use crate::{
    Result, Store, StoreError,
    devices::revoke_device_locked,
    store::{validate_hash, write_error},
};
use chrono::{DateTime, TimeDelta, Utc};
use dayfold_domain::{generate_secret, hash_secret};
use hmac::{Hmac, KeyInit, Mac};
use serde::Serialize;
use sha2::Sha256;
use sqlx::{FromRow, Postgres, Transaction};
use std::fmt;
use uuid::Uuid;
use zeroize::{Zeroize, ZeroizeOnDrop};

const CHALLENGE_LIFETIME: TimeDelta = TimeDelta::minutes(5);
const RECOVERY_LIFETIME: TimeDelta = TimeDelta::minutes(5);
const ACCESS_LIFETIME: TimeDelta = TimeDelta::minutes(10);
const REFRESH_LIFETIME: TimeDelta = TimeDelta::days(7);
const FAMILY_LIFETIME: TimeDelta = TimeDelta::days(30);
const MAX_USER_ISSUANCES: i64 = 200_000;

/// Deployment-owned 256-bit key. Keep it stable across process restarts. Replacing
/// it never accepts a different response for an already committed rotation.
#[derive(Zeroize, ZeroizeOnDrop)]
pub struct SessionKey([u8; 32]);

impl SessionKey {
    pub fn new(bytes: [u8; 32]) -> Self {
        Self(bytes)
    }

    fn derive(&self, kind: &[u8], family: Uuid, generation: i64, request: Uuid) -> String {
        let mut mac = Hmac::<Sha256>::new_from_slice(&self.0).expect("32-byte HMAC key");
        mac.update(b"dayfold/relay-credential/v1\0");
        mac.update(kind);
        mac.update(b"\0");
        mac.update(family.as_bytes());
        mac.update(&generation.to_be_bytes());
        mac.update(request.as_bytes());
        hex(&mac.finalize().into_bytes())
    }

    fn fingerprint(&self) -> String {
        self.derive(b"deployment-key-id", Uuid::nil(), 0, Uuid::nil())
    }
}

impl fmt::Debug for SessionKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("SessionKey([REDACTED])")
    }
}

#[derive(Debug, Clone, FromRow)]
pub struct AuthChallenge {
    pub id: Uuid,
    pub nonce: String,
    pub client_id: String,
    pub device_name: String,
    pub key_thumbprint: String,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
}

#[derive(Clone, Serialize)]
pub struct SessionCredentials {
    pub user_id: Uuid,
    pub device_id: Uuid,
    pub access_token: String,
    pub refresh_token: String,
    pub token_type: &'static str,
    pub access_expires_at: DateTime<Utc>,
    pub refresh_expires_at: DateTime<Utc>,
}

impl fmt::Debug for SessionCredentials {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SessionCredentials")
            .field("user_id", &self.user_id)
            .field("device_id", &self.device_id)
            .field("credentials", &"[REDACTED]")
            .finish()
    }
}

impl Drop for SessionCredentials {
    fn drop(&mut self) {
        self.access_token.zeroize();
        self.refresh_token.zeroize();
    }
}

#[derive(Debug, Clone, FromRow)]
pub struct AuthPrincipal {
    pub user_id: Uuid,
    pub device_id: Uuid,
    pub family_id: Uuid,
    pub key_thumbprint: String,
    pub access_expires_at: DateTime<Utc>,
}

#[derive(Debug, Clone, FromRow, Serialize)]
pub struct AccountDevice {
    pub id: Uuid,
    pub device_name: String,
    pub created_at: DateTime<Utc>,
    pub last_seen_at: DateTime<Utc>,
    pub current: bool,
}

#[derive(FromRow)]
struct ChallengeRow {
    device_name: String,
    key_thumbprint: String,
    expires_at: DateTime<Utc>,
    consumed_at: Option<DateTime<Utc>>,
    id_token_hash: Option<String>,
    issuer: Option<String>,
    subject: Option<String>,
    issued_family_id: Option<Uuid>,
}

#[derive(FromRow)]
struct FamilyRow {
    absolute_expires_at: DateTime<Utc>,
    refresh_expires_at: DateTime<Utc>,
    current_generation: i64,
    revoked_at: Option<DateTime<Utc>>,
}

#[derive(FromRow)]
struct EnrollmentReceiptContext {
    user_id: Uuid,
    device_id: Uuid,
    current_generation: i64,
    absolute_expires_at: DateTime<Utc>,
    refresh_expires_at: DateTime<Utc>,
}

#[derive(FromRow)]
struct IssuanceRow {
    family_id: Uuid,
    generation: i64,
    request_id: Uuid,
    access_hash: String,
    refresh_hash: String,
    key_fingerprint: String,
    access_expires_at: DateTime<Utc>,
    refresh_expires_at: DateTime<Utc>,
    consumed_at: Option<DateTime<Utc>>,
    consumed_request_id: Option<Uuid>,
}

impl Store {
    fn session_key(&self) -> Result<&SessionKey> {
        self.session_key
            .as_deref()
            .ok_or(StoreError::Invalid("user authentication is not configured"))
    }

    pub async fn create_auth_challenge(
        &self,
        client_id: &str,
        device_name: &str,
        jkt: &str,
    ) -> Result<AuthChallenge> {
        self.session_key()?;
        validate_jkt(jkt)?;
        validate_text(client_id, 512)?;
        validate_text(device_name, 80)?;
        let nonce =
            generate_secret().map_err(|_| StoreError::Invalid("secure randomness unavailable"))?;
        let mut tx = self.pool.begin().await?;
        // Serialize the global cap; otherwise many distinct keys could race the
        // count check. The lock is held only for a bounded insert transaction.
        sqlx::query("SELECT pg_advisory_xact_lock(1748253901, 1)")
            .execute(&mut *tx)
            .await?;
        let now = database_now(&mut tx).await?;
        let (total, for_key): (i64, i64) = sqlx::query_as("SELECT count(*), count(*) FILTER (WHERE key_thumbprint = $1) FROM auth_challenges WHERE expires_at > clock_timestamp() AND consumed_at IS NULL")
            .bind(jkt).fetch_one(&mut *tx).await?;
        if total >= 10_000 || for_key >= 5 {
            return Err(StoreError::Capacity);
        }
        let challenge = sqlx::query_as("INSERT INTO auth_challenges (id,nonce,client_id,device_name,key_thumbprint,created_at,expires_at) VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING id,nonce,client_id,device_name,key_thumbprint,created_at,expires_at")
            .bind(Uuid::new_v4()).bind(nonce).bind(client_id).bind(device_name).bind(jkt)
            .bind(now).bind(now + CHALLENGE_LIFETIME).fetch_one(&mut *tx).await?;
        tx.commit().await?;
        Ok(challenge)
    }

    pub async fn auth_challenge(&self, id: Uuid, jkt: &str) -> Result<AuthChallenge> {
        validate_jkt(jkt).map_err(|_| StoreError::Unauthorized)?;
        sqlx::query_as("SELECT id,nonce,client_id,device_name,key_thumbprint,created_at,expires_at FROM auth_challenges WHERE id=$1 AND key_thumbprint=$2 AND (consumed_at IS NOT NULL OR expires_at > clock_timestamp())")
            .bind(id).bind(jkt).fetch_optional(&self.pool).await?.ok_or(StoreError::Unauthorized)
    }

    /// The API verifies the ID token and DPoP signature before calling this
    /// method. The nonce, identity, token fingerprint, key and issuance are then
    /// committed together; callers can never replace a consumed challenge.
    pub async fn enroll_device(
        &self,
        challenge_id: Uuid,
        jkt: &str,
        issuer: &str,
        subject: &str,
        id_token_hash: &str,
    ) -> Result<SessionCredentials> {
        let key = self.session_key()?;
        validate_jkt(jkt)?;
        validate_text(issuer, 2048)?;
        validate_text(subject, 255)?;
        validate_hash(id_token_hash)?;
        let mut tx = self.pool.begin().await?;
        // Account operations use the same user -> challenge -> device order.
        // Any invalid challenge below rolls this tentative user insert back.
        sqlx::query("INSERT INTO users (id,issuer,subject) VALUES ($1,$2,$3) ON CONFLICT (issuer,subject) DO NOTHING")
            .bind(Uuid::new_v4()).bind(issuer).bind(subject).execute(&mut *tx).await?;
        let (user_id,): (Uuid,) =
            sqlx::query_as("SELECT id FROM users WHERE issuer=$1 AND subject=$2 FOR UPDATE")
                .bind(issuer)
                .bind(subject)
                .fetch_one(&mut *tx)
                .await?;
        let challenge = sqlx::query_as::<_, ChallengeRow>("SELECT device_name,key_thumbprint,expires_at,consumed_at,id_token_hash,issuer,subject,issued_family_id FROM auth_challenges WHERE id=$1 FOR UPDATE")
            .bind(challenge_id).fetch_optional(&mut *tx).await?.ok_or(StoreError::Unauthorized)?;
        let now = database_now(&mut tx).await?;
        if challenge.key_thumbprint != jkt {
            return Err(StoreError::Unauthorized);
        }
        if let Some(consumed_at) = challenge.consumed_at {
            if challenge.id_token_hash.as_deref() != Some(id_token_hash)
                || challenge.issuer.as_deref() != Some(issuer)
                || challenge.subject.as_deref() != Some(subject)
            {
                return Err(StoreError::Unauthorized);
            }
            let family_id = challenge.issued_family_id.ok_or(StoreError::Unauthorized)?;
            let context = sqlx::query_as::<_, EnrollmentReceiptContext>("SELECT d.user_id,d.id AS device_id,f.current_generation,f.absolute_expires_at,f.refresh_expires_at FROM auth_families f JOIN devices d ON d.id=f.device_id WHERE f.id=$1 AND f.revoked_at IS NULL AND d.revoked_at IS NULL AND d.key_thumbprint=$2 FOR UPDATE OF d")
                .bind(family_id).bind(jkt).fetch_optional(&mut *tx).await?;
            let EnrollmentReceiptContext {
                user_id: bound_user,
                device_id,
                current_generation: generation,
                absolute_expires_at: absolute,
                refresh_expires_at: refresh_expiry,
            } = context.ok_or(StoreError::Unauthorized)?;
            if bound_user != user_id {
                return Err(StoreError::Unauthorized);
            }
            if generation != 0 {
                return Err(StoreError::RotationSuperseded);
            }
            if consumed_at + RECOVERY_LIFETIME <= now || absolute <= now || refresh_expiry <= now {
                revoke_device_locked(&mut tx, device_id).await?;
                tx.commit().await?;
                return Err(StoreError::ReauthenticationRequired);
            }
            let issuance = load_issuance(&mut tx, family_id, 0).await?;
            let response = match credentials(key, user_id, device_id, &issuance) {
                Ok(response) => response,
                Err(error) => {
                    revoke_device_locked(&mut tx, device_id).await?;
                    tx.commit().await?;
                    return Err(error);
                }
            };
            tx.commit().await?;
            return Ok(response);
        }
        if challenge.expires_at <= now {
            return Err(StoreError::Unauthorized);
        }
        let (family_count,): (i64,) = sqlx::query_as("SELECT count(*) FROM auth_families f JOIN devices d ON d.id=f.device_id WHERE d.user_id=$1")
            .bind(user_id).fetch_one(&mut *tx).await?;
        if family_count >= 1_000 {
            return Err(StoreError::Capacity);
        }
        if retained_issuances(&mut tx, user_id).await? >= MAX_USER_ISSUANCES {
            return Err(StoreError::Capacity);
        }
        let existing: Option<(Uuid,)> = sqlx::query_as("SELECT id FROM devices WHERE user_id=$1 AND key_thumbprint=$2 AND revoked_at IS NULL FOR UPDATE")
            .bind(user_id).bind(jkt).fetch_optional(&mut *tx).await?;
        let device_id = if let Some((id,)) = existing {
            // Fresh OIDC authentication may restore this installation; invalidate
            // its older family while retaining its scoped calendars/reminders.
            sqlx::query(
                "UPDATE auth_families SET revoked_at=COALESCE(revoked_at,$2) WHERE device_id=$1",
            )
            .bind(id)
            .bind(now)
            .execute(&mut *tx)
            .await?;
            sqlx::query("UPDATE devices SET device_name=$2,last_seen_at=$3 WHERE id=$1")
                .bind(id)
                .bind(&challenge.device_name)
                .bind(now)
                .execute(&mut *tx)
                .await?;
            id
        } else {
            let (count,): (i64,) = sqlx::query_as(
                "SELECT count(*) FROM devices WHERE user_id=$1 AND revoked_at IS NULL",
            )
            .bind(user_id)
            .fetch_one(&mut *tx)
            .await?;
            if count >= 20 {
                return Err(StoreError::Capacity);
            }
            let id = Uuid::new_v4();
            sqlx::query("INSERT INTO devices (id,user_id,key_thumbprint,device_name,last_seen_at) VALUES ($1,$2,$3,$4,$5)")
                .bind(id).bind(user_id).bind(jkt).bind(&challenge.device_name).bind(now).execute(&mut *tx).await?;
            id
        };
        let family_id = Uuid::new_v4();
        let absolute = now + FAMILY_LIFETIME;
        sqlx::query("INSERT INTO auth_families (id,device_id,created_at,absolute_expires_at,refresh_expires_at) VALUES ($1,$2,$3,$4,$5)")
            .bind(family_id).bind(device_id).bind(now).bind(absolute).bind(now + REFRESH_LIFETIME).execute(&mut *tx).await?;
        let issuance =
            insert_issuance(&mut tx, key, family_id, 0, challenge_id, now, absolute).await?;
        sqlx::query("UPDATE auth_challenges SET consumed_at=$2,id_token_hash=$3,issuer=$4,subject=$5,issued_family_id=$6 WHERE id=$1")
            .bind(challenge_id).bind(now).bind(id_token_hash).bind(issuer).bind(subject).bind(family_id).execute(&mut *tx).await?;
        let response = credentials(key, user_id, device_id, &issuance)?;
        tx.commit().await?;
        Ok(response)
    }

    pub async fn refresh_session(
        &self,
        refresh_token: &str,
        request_id: Uuid,
        jkt: &str,
    ) -> Result<SessionCredentials> {
        let key = self.session_key()?;
        validate_hash(refresh_token).map_err(|_| StoreError::Unauthorized)?;
        validate_jkt(jkt).map_err(|_| StoreError::Unauthorized)?;
        if request_id.is_nil() {
            return Err(StoreError::Invalid("rotation request ID is required"));
        }
        let refresh_hash = hash_secret(refresh_token);
        // Resolve immutable routing before locking, then revalidate under locks.
        let context: Option<(Uuid, Uuid, Uuid, i64)> = sqlx::query_as("SELECT d.user_id,f.device_id,i.family_id,i.generation FROM auth_issuances i JOIN auth_families f ON f.id=i.family_id JOIN devices d ON d.id=f.device_id WHERE i.refresh_hash=$1")
            .bind(&refresh_hash).fetch_optional(&self.pool).await?;
        let Some((expected_user, device_id, family_id, generation)) = context else {
            let (confirmed,): (bool,) = sqlx::query_as("SELECT EXISTS(SELECT 1 FROM auth_revocation_receipts WHERE refresh_hash=$1 AND key_thumbprint=$2 AND expires_at > clock_timestamp())")
                .bind(&refresh_hash).bind(jkt).fetch_one(&self.pool).await?;
            return Err(if confirmed {
                StoreError::ReauthenticationRequired
            } else {
                StoreError::Unauthorized
            });
        };
        let mut tx = self.pool.begin().await?;
        lock_user(&mut tx, expected_user).await?;
        let device: Option<(Uuid, String, Option<DateTime<Utc>>)> = sqlx::query_as("SELECT user_id,key_thumbprint,revoked_at FROM devices WHERE id=$1 AND user_id IS NOT NULL FOR UPDATE")
            .bind(device_id).fetch_optional(&mut *tx).await?;
        let (user_id, bound_key, revoked) = device.ok_or(StoreError::Unauthorized)?;
        // Wrong-key token theft cannot revoke the legitimate installation.
        if user_id != expected_user || bound_key != jkt {
            return Err(StoreError::Unauthorized);
        }
        if revoked.is_some() {
            return Err(StoreError::ReauthenticationRequired);
        }
        let family = load_family(&mut tx, family_id).await?;
        if family.revoked_at.is_some() {
            // Fresh OIDC authentication can replace a family while the same
            // device remains active. An old response must not clear ownership.
            return Err(StoreError::RotationSuperseded);
        }
        let now = database_now(&mut tx).await?;
        if family.absolute_expires_at <= now || family.refresh_expires_at <= now {
            revoke_device_locked(&mut tx, device_id).await?;
            tx.commit().await?;
            return Err(StoreError::ReauthenticationRequired);
        }
        let previous = load_issuance(&mut tx, family_id, generation).await?;
        if previous.refresh_hash != refresh_hash {
            return Err(StoreError::Unauthorized);
        }
        if let Some(consumed_at) = previous.consumed_at {
            if previous.consumed_request_id != Some(request_id) {
                // A valid key with a consumed token and a different operation is
                // credential replay. Commit revocation before reporting failure.
                revoke_device_locked(&mut tx, device_id).await?;
                tx.commit().await?;
                return Err(StoreError::ReauthenticationRequired);
            }
            if family.current_generation != generation + 1 {
                return Err(StoreError::RotationSuperseded);
            }
            if consumed_at + RECOVERY_LIFETIME <= now {
                revoke_device_locked(&mut tx, device_id).await?;
                tx.commit().await?;
                return Err(StoreError::ReauthenticationRequired);
            }
            let successor = load_issuance(&mut tx, family_id, generation + 1).await?;
            let response = match credentials(key, user_id, device_id, &successor) {
                Ok(response) => response,
                Err(error) => {
                    revoke_device_locked(&mut tx, device_id).await?;
                    tx.commit().await?;
                    return Err(error);
                }
            };
            tx.commit().await?;
            return Ok(response);
        }
        if previous.refresh_expires_at <= now || family.current_generation != generation {
            revoke_device_locked(&mut tx, device_id).await?;
            tx.commit().await?;
            return Err(StoreError::ReauthenticationRequired);
        }
        let next_generation = generation.checked_add(1).ok_or(StoreError::Capacity)?;
        let (duplicate_request,): (bool,) = sqlx::query_as(
            "SELECT EXISTS(SELECT 1 FROM auth_issuances WHERE family_id=$1 AND request_id=$2)",
        )
        .bind(family_id)
        .bind(request_id)
        .fetch_one(&mut *tx)
        .await?;
        if duplicate_request {
            return Err(StoreError::Invalid("rotation request ID was already used"));
        }
        // A normal 10-minute refresh cadence creates 4,320 generations in a
        // 30-day family. Bound authenticated write amplification without
        // discarding consumed hashes needed to detect old-token replay.
        if next_generation >= 10_000
            || retained_issuances(&mut tx, user_id).await? >= MAX_USER_ISSUANCES
        {
            revoke_device_locked(&mut tx, device_id).await?;
            tx.commit().await?;
            return Err(StoreError::ReauthenticationRequired);
        }
        let successor = insert_issuance(
            &mut tx,
            key,
            family_id,
            next_generation,
            request_id,
            now,
            family.absolute_expires_at,
        )
        .await?;
        sqlx::query("UPDATE auth_issuances SET consumed_at=$3,consumed_request_id=$4 WHERE family_id=$1 AND generation=$2")
            .bind(family_id).bind(generation).bind(now).bind(request_id).execute(&mut *tx).await?;
        sqlx::query(
            "UPDATE auth_families SET current_generation=$2,refresh_expires_at=$3 WHERE id=$1",
        )
        .bind(family_id)
        .bind(next_generation)
        .bind(successor.refresh_expires_at)
        .execute(&mut *tx)
        .await?;
        sqlx::query("UPDATE devices SET last_seen_at=$2 WHERE id=$1")
            .bind(device_id)
            .bind(now)
            .execute(&mut *tx)
            .await?;
        let response = credentials(key, user_id, device_id, &successor)?;
        tx.commit().await?;
        Ok(response)
    }

    pub async fn authenticate_access(&self, access_hash: &str) -> Result<AuthPrincipal> {
        validate_hash(access_hash).map_err(|_| StoreError::Unauthorized)?;
        sqlx::query_as("SELECT d.user_id,d.id AS device_id,f.id AS family_id,d.key_thumbprint,i.access_expires_at FROM auth_issuances i JOIN auth_families f ON f.id=i.family_id JOIN devices d ON d.id=f.device_id WHERE i.access_hash=$1 AND i.access_expires_at > clock_timestamp() AND f.revoked_at IS NULL AND f.absolute_expires_at > clock_timestamp() AND f.refresh_expires_at > clock_timestamp() AND d.revoked_at IS NULL AND d.user_id IS NOT NULL")
            .bind(access_hash).fetch_optional(&self.pool).await?.ok_or(StoreError::Unauthorized)
    }

    pub async fn register_dpop_proof(
        &self,
        jkt: &str,
        jti: &str,
        valid_until: DateTime<Utc>,
    ) -> Result<()> {
        validate_jkt(jkt).map_err(|_| StoreError::Unauthorized)?;
        if jti.is_empty() || jti.len() > 128 {
            return Err(StoreError::Unauthorized);
        }
        let mut tx = self.pool.begin().await?;
        let now = database_now(&mut tx).await?;
        if valid_until <= now || valid_until > now + TimeDelta::seconds(125) {
            return Err(StoreError::Unauthorized);
        }
        let inserted = sqlx::query("INSERT INTO auth_dpop_replays (key_thumbprint,jti_hash,expires_at) VALUES ($1,$2,$3) ON CONFLICT DO NOTHING")
            .bind(jkt).bind(hash_secret(jti)).bind(valid_until).execute(&mut *tx).await?.rows_affected();
        if inserted != 1 {
            return Err(StoreError::Unauthorized);
        }
        tx.commit().await?;
        Ok(())
    }

    pub async fn list_user_devices(
        &self,
        user_id: Uuid,
        current_device_id: Uuid,
        actor_access_hash: &str,
    ) -> Result<Vec<AccountDevice>> {
        let mut tx = self.pool.begin().await?;
        lock_user(&mut tx, user_id).await?;
        lock_user_devices(&mut tx, user_id).await?;
        let actor = authenticate_account_action(&mut tx, user_id, actor_access_hash).await?;
        if actor != current_device_id {
            return Err(StoreError::Unauthorized);
        }
        let devices = sqlx::query_as("SELECT id,device_name,created_at,last_seen_at,(id=$2) AS current FROM devices WHERE user_id=$1 AND revoked_at IS NULL ORDER BY created_at,id")
            .bind(user_id).bind(current_device_id).fetch_all(&mut *tx).await?;
        tx.commit().await?;
        Ok(devices)
    }

    pub async fn revoke_user_device(
        &self,
        user_id: Uuid,
        device_id: Uuid,
        actor_access_hash: &str,
    ) -> Result<()> {
        let mut tx = self.pool.begin().await?;
        lock_user(&mut tx, user_id).await?;
        let devices = lock_user_devices(&mut tx, user_id).await?;
        authenticate_account_action(&mut tx, user_id, actor_access_hash).await?;
        if !devices.contains(&device_id) {
            return Err(StoreError::NotFound);
        }
        revoke_device_locked(&mut tx, device_id).await?;
        tx.commit().await?;
        Ok(())
    }

    pub async fn revoke_all_user_devices(
        &self,
        user_id: Uuid,
        actor_access_hash: &str,
    ) -> Result<()> {
        let mut tx = self.pool.begin().await?;
        lock_user(&mut tx, user_id).await?;
        let devices = lock_user_devices(&mut tx, user_id).await?;
        authenticate_account_action(&mut tx, user_id, actor_access_hash).await?;
        for id in devices {
            revoke_device_locked(&mut tx, id).await?;
        }
        tx.commit().await?;
        Ok(())
    }

    pub async fn delete_user(&self, user_id: Uuid, actor_access_hash: &str) -> Result<()> {
        let mut tx = self.pool.begin().await?;
        lock_user(&mut tx, user_id).await?;
        // Lock identity-bearing enrollment receipts before any device locks.
        sqlx::query("SELECT c.id FROM auth_challenges c JOIN users u ON u.issuer=c.issuer AND u.subject=c.subject WHERE u.id=$1 ORDER BY c.id FOR UPDATE OF c")
            .bind(user_id).fetch_all(&mut *tx).await?;
        let devices = lock_user_devices(&mut tx, user_id).await?;
        authenticate_account_action(&mut tx, user_id, actor_access_hash).await?;
        // The native client may still hold either side of its most recent
        // rotation. Store only those hashes before cascades erase identities.
        sqlx::query("INSERT INTO auth_revocation_receipts (refresh_hash,key_thumbprint,expires_at) SELECT i.refresh_hash,d.key_thumbprint,clock_timestamp()+interval '7 days' FROM devices d JOIN auth_families f ON f.device_id=d.id JOIN auth_issuances i ON i.family_id=f.id WHERE d.user_id=$1 AND i.generation >= f.current_generation-1 ON CONFLICT (refresh_hash) DO NOTHING")
            .bind(user_id).execute(&mut *tx).await?;
        for id in devices {
            revoke_device_locked(&mut tx, id).await?;
        }
        sqlx::query("DELETE FROM auth_challenges c USING users u WHERE u.id=$1 AND c.issuer=u.issuer AND c.subject=u.subject")
            .bind(user_id).execute(&mut *tx).await?;
        sqlx::query("DELETE FROM users WHERE id=$1")
            .bind(user_id)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        Ok(())
    }

    /// Called by worker maintenance even with APNs disabled. Expired session
    /// families lose all routing and delivery work using ordinary device cleanup.
    pub async fn cleanup_auth(&self, limit: i64) -> Result<u64> {
        crate::store::validate_batch(limit)?;
        let mut tx = self.pool.begin().await?;
        let devices: Vec<(Uuid,)> = sqlx::query_as("SELECT d.id FROM devices d WHERE d.revoked_at IS NULL AND EXISTS(SELECT 1 FROM auth_families f WHERE f.device_id=d.id AND f.revoked_at IS NULL AND (f.absolute_expires_at <= clock_timestamp() OR f.refresh_expires_at <= clock_timestamp())) ORDER BY d.id LIMIT $1 FOR UPDATE OF d SKIP LOCKED")
            .bind(limit.min(100)).fetch_all(&mut *tx).await?;
        for (id,) in &devices {
            revoke_device_locked(&mut tx, *id).await?;
        }
        tx.commit().await?;
        // Do not hold device locks while pruning challenge rows; enrollment
        // takes a challenge lock before a device lock.
        let mut tx = self.pool.begin().await?;
        // The API allows up to 30,600 requests/minute/process. Every worker
        // drains up to 50,000 expired proofs/minute independently of the much
        // smaller inbox batch, so bounded retention keeps pace with admission.
        let proofs = sqlx::query("DELETE FROM auth_dpop_replays WHERE (key_thumbprint,jti_hash) IN (SELECT key_thumbprint,jti_hash FROM auth_dpop_replays WHERE expires_at <= clock_timestamp() ORDER BY expires_at LIMIT 50000 FOR UPDATE SKIP LOCKED)")
            .execute(&mut *tx).await?.rows_affected();
        let challenges = sqlx::query("DELETE FROM auth_challenges WHERE id IN (SELECT id FROM auth_challenges WHERE (consumed_at IS NULL AND expires_at <= clock_timestamp()) OR consumed_at + interval '30 days' <= clock_timestamp() ORDER BY expires_at LIMIT 1000 FOR UPDATE SKIP LOCKED)")
            .execute(&mut *tx).await?.rows_affected();
        let families = sqlx::query("DELETE FROM auth_families WHERE id IN (SELECT id FROM auth_families WHERE revoked_at <= clock_timestamp() - interval '7 days' ORDER BY revoked_at LIMIT 1000 FOR UPDATE SKIP LOCKED)")
            .execute(&mut *tx).await?.rows_affected();
        let receipts = sqlx::query("DELETE FROM auth_revocation_receipts WHERE refresh_hash IN (SELECT refresh_hash FROM auth_revocation_receipts WHERE expires_at <= clock_timestamp() ORDER BY expires_at LIMIT 50000 FOR UPDATE SKIP LOCKED)")
            .execute(&mut *tx).await?.rows_affected();
        tx.commit().await?;
        Ok(devices.len() as u64 + proofs + challenges + families + receipts)
    }
}

async fn database_now(tx: &mut Transaction<'_, Postgres>) -> Result<DateTime<Utc>> {
    let (now,): (DateTime<Utc>,) = sqlx::query_as("SELECT clock_timestamp()")
        .fetch_one(&mut **tx)
        .await?;
    Ok(now)
}

async fn load_family(tx: &mut Transaction<'_, Postgres>, id: Uuid) -> Result<FamilyRow> {
    sqlx::query_as("SELECT absolute_expires_at,refresh_expires_at,current_generation,revoked_at FROM auth_families WHERE id=$1 FOR UPDATE")
        .bind(id).fetch_optional(&mut **tx).await?.ok_or(StoreError::Unauthorized)
}

async fn load_issuance(
    tx: &mut Transaction<'_, Postgres>,
    family: Uuid,
    generation: i64,
) -> Result<IssuanceRow> {
    sqlx::query_as("SELECT family_id,generation,request_id,access_hash,refresh_hash,key_fingerprint,access_expires_at,refresh_expires_at,consumed_at,consumed_request_id FROM auth_issuances WHERE family_id=$1 AND generation=$2")
        .bind(family).bind(generation).fetch_optional(&mut **tx).await?.ok_or(StoreError::Unauthorized)
}

async fn insert_issuance(
    tx: &mut Transaction<'_, Postgres>,
    key: &SessionKey,
    family: Uuid,
    generation: i64,
    request: Uuid,
    now: DateTime<Utc>,
    absolute: DateTime<Utc>,
) -> Result<IssuanceRow> {
    let mut access = key.derive(b"access", family, generation, request);
    let mut refresh = key.derive(b"refresh", family, generation, request);
    let access_hash = hash_secret(&access);
    let refresh_hash = hash_secret(&refresh);
    access.zeroize();
    refresh.zeroize();
    sqlx::query("INSERT INTO auth_issuances (family_id,generation,request_id,access_hash,refresh_hash,key_fingerprint,issued_at,access_expires_at,refresh_expires_at) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)")
        .bind(family).bind(generation).bind(request).bind(access_hash).bind(refresh_hash).bind(key.fingerprint())
        .bind(now).bind((now + ACCESS_LIFETIME).min(absolute)).bind((now + REFRESH_LIFETIME).min(absolute))
        .execute(&mut **tx).await.map_err(write_error)?;
    load_issuance(tx, family, generation).await
}

fn credentials(
    key: &SessionKey,
    user_id: Uuid,
    device_id: Uuid,
    issuance: &IssuanceRow,
) -> Result<SessionCredentials> {
    if key.fingerprint() != issuance.key_fingerprint {
        return Err(StoreError::ReauthenticationRequired);
    }
    let mut access = key.derive(
        b"access",
        issuance.family_id,
        issuance.generation,
        issuance.request_id,
    );
    let mut refresh = key.derive(
        b"refresh",
        issuance.family_id,
        issuance.generation,
        issuance.request_id,
    );
    if hash_secret(&access) != issuance.access_hash
        || hash_secret(&refresh) != issuance.refresh_hash
    {
        access.zeroize();
        refresh.zeroize();
        return Err(StoreError::ReauthenticationRequired);
    }
    Ok(SessionCredentials {
        user_id,
        device_id,
        access_token: access,
        refresh_token: refresh,
        token_type: "DPoP",
        access_expires_at: issuance.access_expires_at,
        refresh_expires_at: issuance.refresh_expires_at,
    })
}

async fn lock_user(tx: &mut Transaction<'_, Postgres>, user_id: Uuid) -> Result<()> {
    let user: Option<(Uuid,)> = sqlx::query_as("SELECT id FROM users WHERE id=$1 FOR UPDATE")
        .bind(user_id)
        .fetch_optional(&mut **tx)
        .await?;
    if user.is_none() {
        return Err(StoreError::Unauthorized);
    }
    Ok(())
}

async fn retained_issuances(tx: &mut Transaction<'_, Postgres>, user_id: Uuid) -> Result<i64> {
    let (count,): (i64,) = sqlx::query_as("SELECT count(*) FROM auth_issuances i JOIN auth_families f ON f.id=i.family_id JOIN devices d ON d.id=f.device_id WHERE d.user_id=$1")
        .bind(user_id).fetch_one(&mut **tx).await?;
    Ok(count)
}

async fn lock_user_devices(tx: &mut Transaction<'_, Postgres>, user_id: Uuid) -> Result<Vec<Uuid>> {
    let devices: Vec<(Uuid,)> =
        sqlx::query_as("SELECT id FROM devices WHERE user_id=$1 ORDER BY id FOR UPDATE")
            .bind(user_id)
            .fetch_all(&mut **tx)
            .await?;
    Ok(devices.into_iter().map(|row| row.0).collect())
}

async fn authenticate_account_action(
    tx: &mut Transaction<'_, Postgres>,
    user_id: Uuid,
    access_hash: &str,
) -> Result<Uuid> {
    validate_hash(access_hash).map_err(|_| StoreError::Unauthorized)?;
    let actor: Option<(Uuid,)> = sqlx::query_as("SELECT d.id FROM auth_issuances i JOIN auth_families f ON f.id=i.family_id JOIN devices d ON d.id=f.device_id WHERE i.access_hash=$1 AND d.user_id=$2 AND d.revoked_at IS NULL AND i.access_expires_at > clock_timestamp() AND f.revoked_at IS NULL AND f.refresh_expires_at > clock_timestamp() AND f.absolute_expires_at > clock_timestamp()")
        .bind(access_hash).bind(user_id).fetch_optional(&mut **tx).await?;
    actor.map(|row| row.0).ok_or(StoreError::Unauthorized)
}

fn validate_jkt(value: &str) -> Result<()> {
    if value.len() != 43
        || !value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    {
        return Err(StoreError::Invalid("invalid device key thumbprint"));
    }
    Ok(())
}

fn validate_text(value: &str, max: usize) -> Result<()> {
    if value.is_empty() || value.len() > max || value.chars().any(char::is_control) {
        return Err(StoreError::Invalid("invalid identity or device label"));
    }
    Ok(())
}

fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut result = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        result.push(DIGITS[(b >> 4) as usize] as char);
        result.push(DIGITS[(b & 15) as usize] as char);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn derived_credentials_are_separated_by_purpose_generation_request_and_deployment_key() {
        let key = SessionKey::new([19; 32]);
        let family = Uuid::from_u128(1);
        let request = Uuid::from_u128(2);
        let token = key.derive(b"access", family, 0, request);
        assert_eq!(token.len(), 64);
        assert_eq!(token, key.derive(b"access", family, 0, request));
        assert_ne!(token, key.derive(b"refresh", family, 0, request));
        assert_ne!(token, key.derive(b"access", family, 1, request));
        assert_ne!(token, key.derive(b"access", family, 0, Uuid::from_u128(3)));
        assert_ne!(
            token,
            SessionKey::new([20; 32]).derive(b"access", family, 0, request)
        );
        assert_eq!(format!("{key:?}"), "SessionKey([REDACTED])");
    }
}
