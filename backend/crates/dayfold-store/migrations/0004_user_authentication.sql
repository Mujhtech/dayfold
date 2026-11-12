-- User identity is established by a verified OIDC issuer/subject pair. Legacy
-- operator installations are deliberately not assigned an invented user.
CREATE TABLE users (
    id uuid PRIMARY KEY,
    issuer text NOT NULL CHECK (length(issuer) BETWEEN 1 AND 2048),
    subject text NOT NULL CHECK (length(subject) BETWEEN 1 AND 255),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (issuer, subject)
);

ALTER TABLE devices
    ALTER COLUMN bearer_hash DROP NOT NULL,
    ADD COLUMN user_id uuid REFERENCES users(id) ON DELETE CASCADE,
    ADD COLUMN key_thumbprint text,
    ADD COLUMN device_name text NOT NULL DEFAULT 'Legacy installation'
        CHECK (length(device_name) BETWEEN 1 AND 80),
    ADD COLUMN last_seen_at timestamptz NOT NULL DEFAULT now(),
    ADD CONSTRAINT device_authentication_kind CHECK (
        (user_id IS NULL AND key_thumbprint IS NULL AND bearer_hash IS NOT NULL)
        OR (user_id IS NOT NULL AND key_thumbprint IS NOT NULL
            AND key_thumbprint ~ '^[A-Za-z0-9_-]{43}$' AND bearer_hash IS NULL)
    );
CREATE INDEX devices_user ON devices(user_id);
CREATE UNIQUE INDEX devices_live_user_key ON devices(user_id, key_thumbprint)
    WHERE revoked_at IS NULL AND user_id IS NOT NULL;

CREATE TABLE auth_families (
    id uuid PRIMARY KEY,
    device_id uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL,
    absolute_expires_at timestamptz NOT NULL,
    refresh_expires_at timestamptz NOT NULL,
    current_generation bigint NOT NULL DEFAULT 0 CHECK (current_generation >= 0),
    revoked_at timestamptz,
    CHECK (absolute_expires_at > created_at),
    CHECK (refresh_expires_at > created_at AND refresh_expires_at <= absolute_expires_at)
);
CREATE UNIQUE INDEX auth_families_live_device ON auth_families(device_id)
    WHERE revoked_at IS NULL;
CREATE INDEX auth_families_expiration ON auth_families(refresh_expires_at)
    WHERE revoked_at IS NULL;

-- Only credential hashes and deterministic issuance context are retained.
-- Consumed refresh credentials remain until their family is removed so that
-- replay detection is not lost when the short response-recovery window ends.
CREATE TABLE auth_issuances (
    family_id uuid NOT NULL REFERENCES auth_families(id) ON DELETE CASCADE,
    generation bigint NOT NULL CHECK (generation >= 0),
    request_id uuid NOT NULL,
    access_hash text NOT NULL UNIQUE CHECK (access_hash ~ '^[0-9a-f]{64}$'),
    refresh_hash text NOT NULL UNIQUE CHECK (refresh_hash ~ '^[0-9a-f]{64}$'),
    key_fingerprint text NOT NULL CHECK (key_fingerprint ~ '^[0-9a-f]{64}$'),
    issued_at timestamptz NOT NULL,
    access_expires_at timestamptz NOT NULL,
    refresh_expires_at timestamptz NOT NULL,
    consumed_at timestamptz,
    consumed_request_id uuid,
    PRIMARY KEY (family_id, generation),
    UNIQUE (family_id, request_id),
    CHECK (access_expires_at > issued_at AND refresh_expires_at > issued_at),
    CHECK ((consumed_at IS NULL) = (consumed_request_id IS NULL))
);

CREATE TABLE auth_challenges (
    id uuid PRIMARY KEY,
    nonce text NOT NULL UNIQUE CHECK (nonce ~ '^[0-9a-f]{64}$'),
    client_id text NOT NULL CHECK (length(client_id) BETWEEN 1 AND 512),
    device_name text NOT NULL CHECK (length(device_name) BETWEEN 1 AND 80),
    key_thumbprint text NOT NULL CHECK (key_thumbprint ~ '^[A-Za-z0-9_-]{43}$'),
    created_at timestamptz NOT NULL,
    expires_at timestamptz NOT NULL CHECK (expires_at > created_at),
    consumed_at timestamptz,
    id_token_hash text CHECK (id_token_hash ~ '^[0-9a-f]{64}$'),
    issuer text,
    subject text,
    -- An expired receipt may outlive its family briefly. Do not add a cascading
    -- FK: account deletion must never acquire a challenge lock after a device
    -- lock while enrollment acquires those locks in the opposite order.
    issued_family_id uuid,
    CHECK (
        (consumed_at IS NULL AND id_token_hash IS NULL AND issuer IS NULL AND subject IS NULL AND issued_family_id IS NULL)
        OR (consumed_at IS NOT NULL AND id_token_hash IS NOT NULL AND issuer IS NOT NULL AND subject IS NOT NULL AND issued_family_id IS NOT NULL)
    )
);
CREATE INDEX auth_challenges_key ON auth_challenges(key_thumbprint, expires_at);

-- A database uniqueness boundary is shared by all API instances. Process-local
-- caches alone cannot prevent a proof being replayed to another instance.
CREATE TABLE auth_dpop_replays (
    key_thumbprint text NOT NULL CHECK (key_thumbprint ~ '^[A-Za-z0-9_-]{43}$'),
    jti_hash text NOT NULL CHECK (jti_hash ~ '^[0-9a-f]{64}$'),
    expires_at timestamptz NOT NULL,
    PRIMARY KEY (key_thumbprint, jti_hash)
);
CREATE INDEX auth_dpop_replays_expiration ON auth_dpop_replays(expires_at);

-- Confirm a committed account deletion when its HTTP response was lost. These
-- short-lived records intentionally carry no account, device or OIDC identity.
CREATE TABLE auth_revocation_receipts (
    refresh_hash text PRIMARY KEY CHECK (refresh_hash ~ '^[0-9a-f]{64}$'),
    key_thumbprint text NOT NULL CHECK (key_thumbprint ~ '^[A-Za-z0-9_-]{43}$'),
    expires_at timestamptz NOT NULL
);
CREATE INDEX auth_revocation_receipts_expiration ON auth_revocation_receipts(expires_at);
