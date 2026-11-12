# Dayfold notification relay

This Rust workspace implements an optional notification backend backed by PostgreSQL. It accepts Google Calendar change hints, stores device-uploaded reminder schedules, exposes a replayable live stream, and queues APNs delivery. The macOS app includes an opt-in relay client with OIDC sign-in, a separate signing key for each Mac, expiring/rotating Keychain credentials, Google watch registration, stream recovery and reminder coordination. See the [account/session protocol](../docs/authentication.md). See the [native relay setup guide](../docs/relay.md) for connection and signing requirements. Starting the backend alone does not enable the app's relay connection or push reminders.

The relay stores verified OIDC issuer/subject pairs, user/device IDs and labels, public device-key thumbprints, credential hashes/expiry and bounded authentication receipts, opaque scope/channel/reminder/notification IDs, channel resource IDs, APNs device tokens, due times and delivery metadata. It does not accept Google Calendar access/refresh tokens, calendar titles, descriptions, attendees, or meeting URLs. The Mac remains responsible for fetching calendar data and reconciling it locally. `deny_unknown_fields` on input contracts helps keep accidental calendar content out of this protocol.

## Workspace

| Crate | Responsibility |
| --- | --- |
| `dayfold-auth` | Pinned OIDC discovery/JWKS verification and RFC 9449 device proofs |
| `dayfold-domain` | Wire contracts, validation, opaque secret generation and hashing |
| `dayfold-store` | SQLx/PostgreSQL migrations, installation ownership, inboxes, schedules and leased delivery jobs |
| `dayfold-api` | Authenticated HTTP API, Google webhook ingress and Server-Sent Events |
| `dayfold-apns` | Apple HTTP/2 provider client, token authentication and response classification |
| `dayfold-worker` | Due-reminder materialization, APNs delivery, retry and maintenance |
| `dayfold-server` | Configuration and `migrate`, `provision`, `serve`, `revoke` commands |

PostgreSQL is the durable source of truth. A notification and its queued push are committed together. Device-local sequences serialize inbox insertion so concurrent transactions cannot cause a reconnect cursor to skip a later commit. SSE reads the inbox at short intervals; it does not require process-local messages to preserve delivery across restarts or multiple instances.

## Run locally

Install Rust/Cargo 1.96 or later and Docker. The workspace declares Rust 1.96 as its minimum supported version. From the repository root:

```sh
docker compose -f backend/compose.yaml up -d --wait
set -a
. backend/.env.example
set +a
cargo run --manifest-path backend/Cargo.toml -p dayfold-server -- migrate
cargo run --manifest-path backend/Cargo.toml -p dayfold-server -- provision
cargo run --manifest-path backend/Cargo.toml -p dayfold-server -- serve
```

`provision` prints a JSON object containing `device_id` and a one-time `token`. Keep the token in the client Keychain. Only its SHA-256 hash is stored. Provisioning is a legacy local-test CLI action. Public onboarding uses verified OIDC enrollment and DPoP sessions instead. The local example explicitly enables legacy authentication, which the server permits only with a loopback bind, APNs disabled and no OIDC session configuration. Do not put tokens into query strings or commit them to source control.

The development database listens only on `127.0.0.1:55432`; its bundled password is for local development. Compose retains its data in a named volume. The HTTP service defaults to `127.0.0.1:8080`. `/healthz` checks the process; `/readyz` checks database connectivity. `.env.example` is a shell-compatible example, **not automatically loaded** by the executable.

| Variable | Meaning |
| --- | --- |
| `DATABASE_URL` | PostgreSQL connection string |
| `DAYFOLD_BIND` | HTTP bind address; local default `127.0.0.1:8080` |
| `DAYFOLD_PUBLIC_ORIGIN` | Public HTTPS origin, without path/query/credentials, used to construct Google webhook URLs |
| `DAYFOLD_ALLOW_LEGACY_DEV_AUTH` | Explicit local-test mode; requires loopback bind, APNs disabled and no OIDC configuration |
| `DAYFOLD_OIDC_ISSUER` | Exact trusted Dayfold identity issuer |
| `DAYFOLD_OIDC_CLIENT_IDS` | Comma-separated allowlist of public native client IDs |
| `DAYFOLD_OIDC_JWKS_URI` | Pinned HTTPS JWKS endpoint, also checked against discovery |
| `DAYFOLD_SESSION_KEY_FILE` | Private persistent 256-bit session derivation key; shared by replicas |
| `DAYFOLD_APNS_TEAM_ID` | Apple developer team identifier |
| `DAYFOLD_APNS_KEY_ID` | APNs signing key identifier |
| `DAYFOLD_APNS_TOPIC` | App bundle topic, normally `mujhtech.dayfold` |
| `DAYFOLD_APNS_KEY_FILE` | Absolute path to an APNs `.p8` signing key |

APNs is disabled when its configuration is absent. Configure all four APNs values together. Public user sessions currently report APNs unavailable and reject push registration until destination possession is implemented; device-key authentication alone cannot prove an APNs destination. The local example origin is a placeholder: local smoke tests invoke the webhook directly and do not register a Google watch.

Revoke only the intended installation:

```sh
cargo run --manifest-path backend/Cargo.toml -p dayfold-server -- revoke DEVICE_UUID
```

## HTTP protocol

Public auth configuration/challenge/enrollment/refresh endpoints are documented in the [authentication contract](../docs/authentication.md). Protected `/v1` routes require `Authorization: DPoP ACCESS_TOKEN` and a fresh signed `DPoP` proof bound to the HTTP method, public origin/path and access-token hash. The Google webhook uses its separate channel secret. `Authorization: Bearer TOKEN` is accepted only in the explicit legacy local-test mode. Requests with JSON bodies use `Content-Type: application/json`. Input bodies are limited to 16 KiB. Times are RFC 3339 timestamps; UUID fields are opaque identifiers generated by the client unless the endpoint returns them.

| Method and path | Request / response |
| --- | --- |
| `GET /v1/capabilities` | `{"apns_enabled":false}` reports whether this session can use APNs; currently always false for user sessions until destination possession is verified |
| `DELETE /v1/device` | Revoke this installation and its routing/schedules; `204` |
| `PUT /v1/device/push` | `{"token":"APNS_HEX_TOKEN","environment":"sandbox"}`; environment also permits `production`; `204` in legacy tests, `403 push_verification_required` for user sessions |
| `POST /v1/channels` | `{"scope_id":"UUID","expires_at":"TIMESTAMP"}` → `201` with `id`, one-time channel `token`, HTTPS `address`, `expires_at` |
| `PUT /v1/channels/{id}` | `{"resource_id":"GOOGLE_RESOURCE_ID","expires_at":"TIMESTAMP"}` → bound `id`, `scope_id`, `expires_at` |
| `DELETE /v1/channels/{id}` | Disable this installation's channel; `204` |
| `PUT /v1/reminders/{id}` | `{"revision":1,"due_at":"TIMESTAMP","expires_at":"TIMESTAMP"}`; `204` |
| `DELETE /v1/reminders/{id}?revision=2` | Write a cancellation tombstone with a newer revision; `204` |
| `GET /v1/notifications?after=0` | `{"notifications":[...],"cursor_floor":0,"latest_sequence":42}`; at most 100 notifications |
| `GET /v1/notifications/cursor` | `{"floor":0,"current":42}` for resync recovery |
| `POST /v1/notifications/ack` | `{"sequence":42}` acknowledges a contiguous durably handled prefix; `204` |
| `POST /v1/notifications/{id}/claim` | `{"claimed":true}` transfers a live reminder to local presentation before any APNs attempt; otherwise `{"claimed":false}` |
| `GET /v1/events?after=0` | SSE live stream; supports `Last-Event-ID` instead of `after` |
| `POST /v1/webhooks/google` | Empty body and Google's channel/token/resource/state/message-number headers; `204` |

Typical errors are `400` for invalid input, `401` for invalid or revoked credentials, `404` for an absent/not-owned resource, `409` for a revision or identity conflict, `410` when a cursor needs resync, `429` for client rate/concurrency limits, and `503` for database failures or exhausted capacity. Webhook throttling also returns `503` so it remains retryable. Clients should back off on transient failures and honor `Retry-After` when present. Error responses do not echo credentials or calendar content.

### Google watch lifecycle

1. The Mac reserves a relay channel with a locally mapped `scope_id` and future expiration. The relay generates the channel ID and secret.
2. Using its existing on-device Google authorization, the Mac calls the appropriate Google Calendar `watch` endpoint with the returned `id`, `token`, `address`, `type: "web_hook"`, and requested expiration in milliseconds since the epoch.
3. The Mac activates the channel with Google's returned `resourceId` and actual expiration converted to RFC 3339. The relay shortens its expiration as needed. A valid initial `sync` callback may arrive before this response; its authenticated resource binding is retained and must match activation.
4. A callback validates channel identity, secret, resource and state, then atomically deduplicates the message and inserts a change hint. Lower message numbers are accepted when unseen; numbers are not assumed contiguous or arrival-ordered.
5. The Mac consumes the hint and runs its normal incremental Google sync. The relay never performs Google writes or treats webhook headers as authoritative calendar contents.

Watch channels expire and are not automatically renewed. The Mac must replace them while authorized and running, tolerate overlap, and stop retired channels with Google where possible. Deleting a relay channel does not call Google's stop API. Periodic reconciliation remains necessary because Google hints can be delayed or missing. See [Google's push notification guide](https://developers.google.com/workspace/calendar/api/guides/push).

### Replay, acknowledgement and resync

An SSE notification looks like this:

```text
event: notification
id: 42
data: {"sequence":42,"id":"UUID","kind":"calendar_changed","subject_id":"UUID","revision":null,"created_at":"TIMESTAMP","expires_at":"TIMESTAMP"}
```

`kind` is `calendar_changed` or `reminder_due`. Map `subject_id` locally to a watched scope or reminder. Reminder notifications include their schedule `revision`; calendar hints use `null`. Compare the revision against the current local reminder before presenting it, and suppress cancelled or superseded versions. Persist the notification ID, cursor and required local handling before acknowledging its sequence. Reading SSE or a notification page does not acknowledge delivery. Resume with the last **durably handled** sequence through `Last-Event-ID` or `after`; supplying different values for both is rejected. Deduplicate notification IDs because retries and reconnects can deliver the same notification again.

If the API returns `410 resync_required`, or an established stream emits `event: resync_required`, read `/v1/notifications/cursor`, save its `current` value, perform a full local reconciliation, and then resume from that saved value. Capturing the cursor before reconciliation preserves hints committed during the refresh. If that cursor expires during a long reconciliation, repeat the procedure. Retention is bounded; the relay is not a permanent event archive.

### Reminders and APNs

Each reminder has a device-local UUID and increasing positive revision. Retry an identical revision idempotently; use a higher revision when moving or cancelling a reminder. Cancellation tombstones prevent delayed older requests from restoring it. Due times must be within 30 days, with 60 seconds of past-time clock tolerance. Expiration must be after the due time, no more than 24 hours later, and still in the future. The device must periodically upload a fresh scheduling horizon and cancel obsolete reminders.

The worker materializes due reminders into the same durable inbox. APNs calendar hints use a background notification with opaque IDs; reminder pushes use a generic upcoming-event alert carrying the reminder revision. No event title is uploaded. APNs acceptance is not proof that a user saw an alert, and neither APNs nor the live stream guarantees instantaneous delivery. A cancelled or superseded notification already in flight cannot be recalled, including an alert already handed to Apple; local revision checks suppress stale application handling but cannot retract an OS alert already displayed. See [Apple's provider API](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns) and [background notification guidance](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app).

Before presenting an inbox reminder locally, the Mac requests `/v1/notifications/{id}/claim`. A successful claim atomically cancels the untouched APNs job; retries return `true` while that reminder remains live. Once any APNs attempt has been leased, the claim returns `false` and the Mac leaves presentation to APNs. A cursor acknowledgement alone never transfers reminder ownership or cancels an unclaimed APNs reminder. Expired, cancelled, foreign or missing notifications cannot be claimed. The client must persist claimed reminder handling and deduplicate its local notification identifier across retries.

In the legacy local-test path, an APNs token/environment pair can belong to only one non-revoked installation. Registration by another installation returns `409`; the existing binding and the caller's previous registration remain intact. The owner may refresh the token, and explicit installation revocation releases it. Migration `0003` fails if existing live registrations conflict, requiring operator investigation rather than silently choosing an owner. This uniqueness constraint does **not** prove possession during first registration: a bearer holder who knows an unbound APNs token could register it. Production enrollment requires a challenge confirmed through APNs and a device key, or an equivalent verified possession design, before reminder delivery can be trusted to that endpoint. That push-destination protocol is not implemented. User-enrolled sessions therefore cannot register push destinations or transfer reminder ownership to APNs; `PUT /v1/device/push` returns `403 push_verification_required`.

The native client coordinates backend claims with local scheduled reminders and checks server capabilities, APNs registration and notification permission before transferring reminder ownership. Its connection is optional; local calendar use and normal polling remain available when the relay is unavailable. The backend cannot keep a sleeping or quit Mac's event data continuously synchronized. Real delivery requires a public TLS relay, Google watch acceptance and a provisioned app with matching APNs credentials; those live-provider paths are not verified by the local checks described here.

## Verification

```sh
cargo fmt --manifest-path backend/Cargo.toml --all --check
cargo test --manifest-path backend/Cargo.toml --workspace
cargo clippy --manifest-path backend/Cargo.toml --workspace --all-targets -- -D warnings
python3 backend/scripts/smoke.py
python3 backend/scripts/restart_smoke.py
```

Run the explicitly ignored PostgreSQL tests against a disposable database with permission to create schemas:

```sh
DAYFOLD_TEST_DATABASE_URL="$DATABASE_URL" \
  cargo test --manifest-path backend/Cargo.toml -p dayfold-store --test postgres -- --ignored
```

The API also has ignored PostgreSQL tests for DPoP replay, HTTP ownership/rotation and stream expiry; run `cargo test --manifest-path backend/Cargo.toml --workspace -- --include-ignored` with `DAYFOLD_TEST_DATABASE_URL` to include both crates. Each database test creates a UUID-named schema, sets that pool's search path, applies migrations, and removes its schema on success. Failed tests retain their isolated schemas for inspection. These checks cover concurrency, channel identity, reminder cancellation, lease recovery, acknowledgement, registration freshness and retention; they never send to external providers.

The legacy smoke test requires the service to be running with explicit local development authentication and the same `DATABASE_URL` exported in its shell. It provisions two temporary installations, exercises authentication, APNs capability discovery, early Google sync callbacks, ownership, webhook deduplication and reordering, SSE replay, due reminders, cancellation, acknowledgement, explicit reminder claims and revocation, then cleans up its installations. It verifies that an acknowledged reminder remains claimable before APNs starts and that repeated claims are idempotent. It uses only Python's standard library and HTTP loopback connections. By default it registers no push tokens. An optional `--server-binary /absolute/path/dayfold-server` avoids invoking Cargo for provisioning; `--expect-apns-disabled` asserts that provider delivery is disabled before registering fake tokens to verify exclusive ownership and owner refresh. These checks do not contact Google/APNs.

The restart check requires a built executable and a disposable loopback `DATABASE_URL`. It starts its own service on unused port 8081, verifies an unacknowledged hint survives a process kill and replays with the same identity, and checks graceful shutdown. It explicitly disables APNs in the child process and leaves any existing service on that port untouched.

The Rust tests include deterministic protocol/provider tests and database integration tests. Check their documented database prerequisites and actual output; a skipped database test is not evidence of an executed database check. Real Google/APNs acceptance requires separately configured credentials, authorized test devices and a public TLS endpoint.

## Deployment boundaries

- Put the HTTP service behind a trusted HTTPS reverse proxy. Disable response buffering for SSE, keep idle timeouts above the 15-second keepalive interval, and preserve `Last-Event-ID`. Do not expose the development database publicly.
- Use dedicated database credentials, restricted network access, a backup/restore policy and an operator-controlled migration process. The Compose password is not a production secret.
- Configure real OIDC native registration and session-key management according to the [authentication deployment guide](../docs/authentication.md). Keep development legacy authentication disabled.
- Apply edge request and connection limits. Current API limits are process-local: 180 authenticated requests per installation per minute, 600 webhook requests per channel per minute, two SSE connections per installation and 256 streams per process. The API adds bounded process-wide pre-authentication guards, while database uniqueness enforces proof replay across instances. These counters do not provide a global distributed limit or replace ingress abuse protection.
- Keep APNs signing material outside the repository with restricted permissions. A correctly signed native app, matching topic/environment, APNs entitlement, current device token and applicable user permission are required. Test sandbox and production separately.
- Inbox retention is bounded to seven days and notification expiration. Quotas and cleanup protect storage; clients must implement the resync path. Reminder cancellation records retain revision history to reject stale writes.
- Each installation permits 128 live channels, 1,000 live reminders, 10,000 reminder identities including tombstones, and 10,000 retained inbox entries. Each channel permits 100,000 unique callbacks. Full inboxes require acknowledgement or expiry before accepting more hints; rejected callbacks do not commit deduplication receipts. The lifetime reminder-identity limit currently requires operator reprovisioning when exhausted; automatic identity compaction is not implemented.
- Monitor database health, worker failures, retry/dead delivery counts and queue age without logging bearer tokens, APNs tokens, webhook secrets or payload content. APNs retries are bounded by expiry and attempt limits; terminal failures need operational visibility.

The backend and native client are implemented and have local integration coverage. No public relay deployment, live OIDC/browser acceptance or live Google Calendar/APNs acceptance is established by that coverage. Load, failover, backup recovery and real-provider delivery need environment-specific acceptance testing before rollout.
