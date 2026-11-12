# Dayfold accounts and device sessions

Dayfold sign-in and Google Calendar permissions are separate. A Dayfold user is identified by a verified OIDC issuer and subject. Email addresses never determine ownership or link accounts. Each enrolled Mac has its own P-256 signing key, relay session and notification resources. The current key is generated in software and protected by the device-only Keychain; proof of key possession is not hardware attestation. Connecting another Google calendar does not change that ownership.

This implementation requires a configured OIDC provider. It does not implement passwords or replace the provider's account recovery. The native app uses an external browser and authorization code flow with PKCE/state. The relay issues a five-minute, one-use OIDC nonce bound to the Mac's public-key thumbprint, then verifies the returned ID token's signature, issuer, client audience, authorized party when applicable, nonce, subject and timestamps before enrolling the device. Calendar access and refresh tokens remain on the Mac; only the separate Dayfold sign-in ID token is submitted to the relay for verification.

## Deployment configuration

Register a **public native application** at a maintained OIDC provider with authorization code + S256 PKCE and a supported loopback redirect. No client secret belongs in the Mac app. Register the Dayfold native client separately from any Google Calendar OAuth client, even when Google is also the chosen identity provider.

Configure all of these together:

| Setting | Meaning |
| --- | --- |
| `DAYFOLD_PUBLIC_ORIGIN` | Exact public HTTPS origin used by clients and DPoP proof verification; the proxy must preserve the request path. |
| `DAYFOLD_OIDC_ISSUER` | Exact trusted issuer string, including any path/trailing-slash convention. |
| `DAYFOLD_OIDC_CLIENT_IDS` | Comma-separated allowlist of registered native client IDs; the first is advertised to the app. |
| `DAYFOLD_OIDC_JWKS_URI` | Operator-pinned HTTPS JWKS URL; discovery must match it and the exact issuer. |
| `DAYFOLD_SESSION_KEY_FILE` | Private regular file containing 32 random bytes or 64 hexadecimal characters. |

Discovery is fetched only from the configured issuer. Its authorization/token endpoints must be HTTPS without embedded credentials. Discovery and JWKS fetches have bounded response sizes/timeouts, deny redirects, cache for a limited interval and fail closed. The verifier supports RS256 and ES256; arbitrary token-supplied URLs and symmetric JWT algorithms are rejected.

Create the session derivation key with a cryptographic random generator and private permissions. For a local test installation, the ignored `backend/secrets` directory is available:

```sh
mkdir -p backend/secrets
(umask 077; openssl rand -hex 32 > backend/secrets/session-key)
```

Use a secret manager or a private mounted file in production. Every API instance must use the same persistent key. It is not generated at startup and is never stored in PostgreSQL. Unix startup rejects key files readable by group/other users. Replacing this key requires a coordinated rollout: already-issued opaque credentials still depend on their database validity, but outstanding same-request recovery under the previous key fails closed and requires reauthentication. Mixed keys across replicas are unsupported.

A public server refuses to start without identity/session configuration. The old operator `provision` command is only useful with the explicit `--allow-legacy-dev-auth` flag (or `DAYFOLD_ALLOW_LEGACY_DEV_AUTH=true`), a loopback listener, APNs disabled and no OIDC session configuration. Never forward a development listener to the internet. Legacy credentials cannot access account-management routes. The macOS manual-token workflow is also restricted to its explicit local-development mode.

## HTTP contract

JSON request bodies reject unknown fields and remain limited to 16 KiB. Responses use `Cache-Control: no-store`. UUIDs and timestamps use the existing relay JSON conventions.

| Endpoint | Contract |
| --- | --- |
| `GET /v1/auth/config` | Returns `issuer`, `client_id`, `authorization_endpoint`, `token_endpoint` from the server's trusted configuration. |
| `POST /v1/auth/challenges` | DPoP proof; body `{client_id, device_name}`. Returns `{id, nonce, expires_at}`. |
| `POST /v1/auth/enroll` | DPoP proof using the challenge's key; body `{challenge_id, id_token}`. Returns device credentials. |
| `POST /v1/auth/refresh` | DPoP proof using the session's key; body `{refresh_token, request_id}`. Returns rotated credentials. |
| `GET /v1/account/devices` | Authenticated DPoP access; returns `{devices:[{id,device_name,created_at,last_seen_at,current}]}` belonging only to the verified user. |
| `DELETE /v1/account/devices/{id}` | Revokes one of the user's devices and its routing/delivery work. Foreign IDs return `404`. |
| `POST /v1/account/revoke-all` | Revokes every device for the authenticated user, including this session. |
| `DELETE /v1/account` | Deletes the relay account and its device resources; does not delete the provider's identity or Google calendars. |

Credentials contain `user_id`, `device_id`, `access_token`, `refresh_token`, `token_type: "DPoP"`, `access_expires_at` and `refresh_expires_at`. Both tokens are opaque 256-bit values. Access lasts 10 minutes. Refresh has a seven-day idle limit bounded by a 30-day absolute session limit; after that, browser sign-in is required again.

Protected relay and account routes require `Authorization: DPoP ACCESS_TOKEN` and a fresh `DPoP` header. Proofs are ES256 JWTs with a public P-256 JWK, `typ: dpop+jwt`, UUID `jti`, `iat`, `htm` and `htu`; resource proofs also require `ath = base64url(SHA256(ACCESS_TOKEN))`. `htu` covers the public origin and path, excluding query/fragment. Token endpoints use the same proof format without `ath`. The proof key must match the stored enrollment/session key. The OIDC challenge nonce is used in the browser ID token; this version does not require a separate DPoP server nonce.

Proof timestamps have a 60-second tolerance. PostgreSQL consumes proof IDs through a unique key shared across API instances, so replaying a signed request fails even on a different process. The access token is checked again during live streaming; expiry or revocation closes the connection and the client reconnects with a current credential. A copied token alone is insufficient without the Mac's signing key.

## Rotation and interrupted requests

Before refreshing, the Mac atomically persists a pending request UUID with its current credentials in Keychain. Concurrent API requests share one refresh operation. The server locks the device/session and consumes the refresh token in the same transaction that issues its replacement.

A retry with the same consumed token, request UUID and device key can recover exactly the same result for five minutes, provided that result has not itself been rotated. The retry uses a **new DPoP proof ID**, because a repeated proof is always rejected. Reuse with a different request UUID revokes the family/device instead of issuing another credential. PostgreSQL retains consumed refresh hashes to detect reuse. Issuance context and a deployment-secret HMAC reconstruct retry responses; plaintext access/refresh credentials are not stored in the database.

Enrollment uses the challenge UUID as its stable issuance ID. The same challenge, verified identity, ID-token hash and device key can recover the original response within the bounded window; it cannot create a second device or switch users. The native app keeps pending enrollment and refresh intents in Keychain until it has durably saved the response. Secrets and signing keys are excluded from preferences, calendar databases, exports, diagnostics and logs.

Terminal refresh expiry/replay/revocation also retires the installation's watches, reminder schedules and queued delivery work. Access expiry alone does not revoke the device. Already-submitted APNs requests cannot be recalled. Account deletion/revocation cannot erase exported local files or affect calendars at Google. To confirm cleanup after a lost account-deletion response, the server retains bounded receipts containing only refresh-token hashes, public-key thumbprints and expiry for up to seven days, with no user/device/issuer/subject link. A matching refresh token plus key can confirm revocation; it cannot authenticate or recreate the deleted account. Short-lived DPoP replay records also expire independently.

## Authentication metadata retention

The five-minute response-recovery window differs from database retention. Unused challenges expire after five minutes. Consumed enrollment receipts retain the ID-token hash, issuer/subject and key binding for up to 30 days so late/superseded recovery can fail safely; account deletion removes those identity-linked receipts. Revoked families and their issuance hashes are eligible for cleanup after seven days. DPoP replay records expire at the proof's `iat + 60 seconds`. Account deletion leaves only bounded confirmation receipts for the last two refresh generations per family, plus transient proof replay records; confirmation receipts expire after seven days.

Cleanup uses bounded batches and runs periodically, so expired rows become ineligible immediately but physical removal is eventual. There are at most 20 active devices per user, 1,000 retained families per user, 10,000 issuance generations per family and 200,000 retained issuances across a user's families. These storage/admission controls complement deployment-level request/connection quotas and monitoring.

## Verification and remaining boundaries

The test suites exercise signed OIDC/DPoP failures, cross-user ownership, proof replay, concurrent rotation, interrupted-response recovery, expiry, revocation and native persistence. Exact executed evidence belongs in [verification.md](verification.md); tests against fixtures do not establish that an external identity provider or signed Mac has accepted the flow.

**Public APNs registration remains disabled for enrolled user sessions** until a separate destination challenge proves that the Mac can receive the APNs token being registered. `PUT /v1/device/push` returns `403 push_verification_required` for these sessions. User authentication and device-key possession do not prove ownership of an arbitrary push token. Local reminders remain the fallback.

A real provider registration and browser sign-in, signed Keychain behavior, APNs possession/rotation on provisioned Macs, deployment ingress limits, multi-instance load tests, operational monitoring, restore/deletion procedures and an independent security review remain release acceptance requirements. No public service or live identity-provider integration is implied by local tests.

The protocol follows [OIDC ID-token validation](https://openid.net/specs/openid-connect-core-1_0.html#IDTokenValidation), [OAuth for Native Apps (RFC 8252)](https://www.rfc-editor.org/rfc/rfc8252.html), [OAuth security practice (RFC 9700)](https://www.rfc-editor.org/rfc/rfc9700.html) and [DPoP (RFC 9449)](https://www.rfc-editor.org/rfc/rfc9449.html). Dayfold's opaque token issuance/recovery endpoints are application-specific; they are not a general OAuth authorization server.
