-- No calendar content or Google credentials are stored by the relay.
CREATE TABLE devices (
    id uuid PRIMARY KEY,
    bearer_hash text NOT NULL UNIQUE CHECK (bearer_hash ~ '^[0-9a-f]{64}$'),
    created_at timestamptz NOT NULL DEFAULT now(),
    revoked_at timestamptz,
    last_sequence bigint NOT NULL DEFAULT 0 CHECK (last_sequence >= 0),
    acknowledged_sequence bigint NOT NULL DEFAULT 0 CHECK (acknowledged_sequence >= 0 AND acknowledged_sequence <= last_sequence),
    cursor_floor bigint NOT NULL DEFAULT 0 CHECK (cursor_floor >= 0 AND cursor_floor <= last_sequence),
    apns_token text,
    apns_environment text CHECK (apns_environment IN ('sandbox', 'production')),
    push_revision bigint NOT NULL DEFAULT 0,
    push_registered_at timestamptz,
    CHECK ((apns_token IS NULL) = (apns_environment IS NULL)),
    CHECK (apns_token IS NULL OR (length(apns_token) BETWEEN 32 AND 256 AND apns_token ~ '^[0-9a-f]+$' AND length(apns_token) % 2 = 0))
);

CREATE TABLE channels (
    id uuid PRIMARY KEY,
    device_id uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    token_hash text NOT NULL UNIQUE CHECK (token_hash ~ '^[0-9a-f]{64}$'),
    scope_id uuid NOT NULL,
    resource_id text CHECK (resource_id IS NULL OR length(resource_id) BETWEEN 1 AND 512),
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    activated_at timestamptz,
    revoked_at timestamptz,
    accepted_messages bigint NOT NULL DEFAULT 0 CHECK (accepted_messages BETWEEN 0 AND 100000),
    CHECK (expires_at > created_at AND expires_at <= created_at + interval '30 days'),
    CHECK (activated_at IS NULL OR resource_id IS NOT NULL)
);
CREATE INDEX channels_device ON channels(device_id);
CREATE INDEX channels_expiry ON channels(expires_at);

-- The number is a canonical decimal u64, never an ordering watermark.
CREATE TABLE webhook_receipts (
    channel_id uuid NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
    message_number text NOT NULL CHECK (message_number ~ '^(0|[1-9][0-9]{0,19})$'),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (channel_id, message_number)
);

CREATE TABLE reminders (
    device_id uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    id uuid NOT NULL,
    revision bigint NOT NULL CHECK (revision > 0),
    due_at timestamptz,
    expires_at timestamptz,
    deleted_at timestamptz,
    materialized_revision bigint,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (device_id, id),
    CHECK ((deleted_at IS NOT NULL) OR (due_at IS NOT NULL AND expires_at > due_at AND expires_at <= due_at + interval '1 day')),
    CHECK (materialized_revision IS NULL OR materialized_revision <= revision)
);
CREATE INDEX reminders_due ON reminders(due_at, device_id) WHERE deleted_at IS NULL AND materialized_revision IS NULL;

CREATE TABLE notifications (
    device_id uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    sequence bigint NOT NULL CHECK (sequence > 0),
    id uuid NOT NULL UNIQUE,
    kind text NOT NULL CHECK (kind IN ('calendar_changed', 'reminder_due')),
    subject_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    cancelled_at timestamptz,
    reminder_id uuid,
    reminder_revision bigint,
    PRIMARY KEY (device_id, sequence),
    UNIQUE (device_id, id),
    FOREIGN KEY (device_id, reminder_id) REFERENCES reminders(device_id, id),
    CHECK (expires_at > created_at),
    CHECK ((kind = 'reminder_due') = (reminder_id IS NOT NULL AND reminder_revision IS NOT NULL))
);
CREATE INDEX notifications_retention ON notifications(device_id, created_at, sequence);
CREATE INDEX notifications_reminder ON notifications(device_id, reminder_id) WHERE reminder_id IS NOT NULL;

CREATE TABLE push_outbox (
    id uuid PRIMARY KEY,
    device_id uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    notification_id uuid NOT NULL UNIQUE,
    status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'leased', 'sent', 'dead', 'cancelled')),
    attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    available_at timestamptz NOT NULL DEFAULT now(),
    lease_id uuid,
    lease_until timestamptz,
    claimed_token text,
    claimed_environment text,
    claimed_push_revision bigint,
    updated_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (device_id, notification_id) REFERENCES notifications(device_id, id) ON DELETE CASCADE,
    CHECK ((status = 'leased') = (lease_id IS NOT NULL AND lease_until IS NOT NULL))
);
CREATE INDEX push_outbox_ready ON push_outbox(device_id, available_at) WHERE status = 'pending';
CREATE INDEX push_outbox_leases ON push_outbox(device_id, lease_until) WHERE status = 'leased';
