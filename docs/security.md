# Security model and release requirements

**Status: development implementation; not approved for public multi-user release.** Security is a release requirement. Passing functional tests, using HTTPS or storing a token in Keychain does not establish that the complete product is secure.

## People, Google accounts and devices are different identities

The current app stores calendar data locally and talks directly to Google. Each Google connection has an account identity derived from Google's authenticated subject, and calendar/event keys include that account. Google Calendar access/refresh tokens never go to the relay. A separate Dayfold ID token is submitted during enrollment, including if Google is configured as the Dayfold identity provider.

The relay authenticates **Dayfold users and their separately enrolled devices**. User identity comes from a verified OIDC `(issuer, subject)` pair; email equality never links or merges accounts. Each Mac creates a P-256 key and uses an expiring, rotating session constrained by DPoP proofs. The caller cannot choose another user or installation by supplying an ID. Channels, reminders, inboxes, acknowledgements and delivery claims remain scoped to the authenticated device.

```
Verified Dayfold user
  └─ separately enrolled Mac / device signing key and session
       └─ device-owned watches, reminders and notification inbox
```

[Authentication setup and protocol](authentication.md) describes the implementation. The native app uses a separate external-browser authorization-code flow with PKCE/state and a one-use server nonce. The server verifies a pinned issuer/JWKS, allowed native audience, signature, authorized party where applicable, expiration, nonce, subject and fresh issuance. It derives ownership from those verified claims. Connecting another Google calendar does not change the Dayfold account.

Access credentials last ten minutes; rotating refresh credentials have a seven-day idle and 30-day absolute session limit. PostgreSQL detects proof and refresh replay across processes. A bounded same-request recovery path handles lost responses without storing plaintext credentials on the server. Per-device/all-device revocation and relay-account deletion use transactional ownership checks; expired/replayed sessions also retire routing and delivery work. The Mac stores credentials, its private signing key and pending recovery intents atomically in Keychain.

The old operator-provisioned bearer is accepted only in explicit loopback development mode with APNs disabled and no OIDC session configuration. It cannot access user-account management. Public service startup requires real OIDC configuration and a persistent private session key. A maintained identity provider owns password/passkey policy and identity recovery; Dayfold does not store passwords or provide a separate password-reset service.

The account lifecycle now has code and local regression coverage, but public release still requires real identity-provider/browser and signed-Mac acceptance, push-destination possession, operational controls and independent review. Manual test credentials and local fixtures do not satisfy those requirements.

## Enforced boundaries

| Boundary | Implementation and limit |
| --- | --- |
| User A vs user B at the relay | OIDC establishes the user; DPoP binds each session to its device key. Resource handlers derive device ownership from authentication. Account operations recheck the exact access credential under database locks, including concurrent logout. There are no shared team resources. |
| Multiple Google connections | Local identities include account + calendar + event. OAuth items are scoped to client ID, canonical store namespace and account. Test/demo stores cannot silently adopt the default store's legacy credentials. |
| Different macOS users | App data and Keychain belong to the macOS login. Store directories are private (`0700`). Separate people sharing a Mac should use separate macOS accounts; the calendar sidebar is not an application lock or a boundary between people sharing one unlocked login. |
| Secrets on the Mac | OAuth and relay credentials use Keychain, serialized off the UI actor, with explicit accessibility and checked errors. Signed identities use the data-protection Keychain; the ad hoc development path is deliberate. Legacy migration verifies the new record before removing the old one. Pending enrollment/rotation and the private device key are saved in the same scoped Keychain record before a new credential is exposed. No secret belongs in preferences, diagnostics or recovery exports. |
| Network endpoints | Production relay traffic requires HTTPS. Authenticated Google and relay API requests reject redirects before following them, reject unexpected response origins and avoid shared cookies/credential storage. System TLS validation stays enabled. Browser OAuth redirects are handled separately by AppAuth with PKCE/state. |
| Relay data minimization | The relay accepts opaque routing IDs, resource bindings, APNs destinations, due/expiry times and revisions. It rejects unknown DTO fields and does not accept event titles, guests, descriptions, meeting links or Google tokens. This metadata is still sensitive. |
| APNs routing | An active `(environment, token)` destination belongs to one installation. A second installation must not overwrite that binding. **Uniqueness does not prove possession** when an unbound token is first registered; public enrolment must confirm that the requesting device can receive the destination challenge before activating it. An APNs token is not a login credential. User sessions report APNs unavailable and reject destination registration until that challenge is implemented. |
| Webhooks and replay | Channel ID, secret, resource binding, expiration and message identity are checked. Initial sync races and duplicate/out-of-order callbacks are covered. A webhook is a hint; the Mac reads authoritative data from Google. |
| Local/remote lifecycle | Reminder ownership and cancellation are durable. Disconnect revokes remote routing before clearing local ownership. Async callbacks capture the original store and verify generation before updating UI or a new connection. |
| Abuse and failures | Pre-authentication middleware runs before body parsing; per-key/process counters, body sizes, paging, SSE buffers/connections, schedule horizons and per-installation quotas are bounded. Database limits bound session/proof retention and issuance. Errors omit credentials and provider payloads. Current in-process limits do not replace edge/global abuse protection. |

## Explicitly outside the current guarantee

SQLite calendar data and recovery exports are not independently encrypted with SQLCipher or end-to-end encryption. FileVault and per-login protection are platform controls, not application-level encryption. Malware running with the user's access, an unlocked shared login or a compromised OS is outside the current app boundary. Do not claim that App Sandbox prevents every process running as the same user from accessing exported or otherwise readable data.

The server can observe the Dayfold identity-provider subject, device labels, routing and reminder timing. A compromised database can expose identity/routing metadata and APNs destinations, although it contains only hashes of high-entropy credentials/channel secrets. The session derivation key is held separately; compromising both that key and issuance state can reconstruct credentials, while DPoP additionally requires the device private key for use. Hashing these random credentials is not an appropriate pattern for human passwords. There are no user passwords in the current system.

APNs already accepted by Apple cannot be recalled. Revocation prevents further authorized server work; it cannot erase an alert already submitted to Apple or remove an exported calendar file from another location.

## Public-release blockers

| Requirement | Acceptance evidence required |
| --- | --- |
| User identity and verified device enrolment | OIDC/DPoP implementation and adversarial fixtures are present. Configure a real native client and execute browser sign-in, provider key rotation/outage and signed-Mac acceptance. |
| Credential lifecycle | Expiry, rotation/replay, interrupted response recovery, device/all-device revocation and account deletion have local coverage. Validate real device loss/reinstallation, signed Keychain continuity and provider recovery; review the session-key rotation/runbook. |
| Push destination ownership | Challenge-confirmed enrolment, token rotation/reinstallation, conflicting binding and revocation tests on actual provisioned Macs. |
| Public infrastructure | TLS termination, private database network, least-privilege runtime DB role separate from migrations, managed signing secrets, encrypted storage/backups and tested restore/deletion procedures. None is established by local Compose. |
| Abuse protection | Pre-authentication/edge rate and connection limits, multi-instance limits, quotas and load tests that show one installation cannot starve others. Current database authentication lookups still need ingress protection. |
| Monitoring and response | Opaque identity/action events cover successful enrollment, rotation/recovery and account revocation/deletion. Deployment alerting, failure/replay metrics, retention, incident response and emergency key-revocation procedures still need operational acceptance. |
| Supply chain | Pinned/reviewed lockfiles, automated secret and vulnerability scanning, protected branches and required checks before merge/release. A fresh RustSec audit now passes after removing two affected cryptography packages; this is not proof of no vulnerabilities. CI definitions cover native tests/build, backend isolation and the Rust audit, and Dependabot covers Cargo/Swift/actions. These definitions have not run on GitHub; branch protection and secret scanning still need repository configuration. |
| Distribution and independent review | Provisioned signing, hardened runtime, notarization/clean-profile installation, live provider tests and an independent security review of the public identity/enrolment service. Local ad hoc builds and this code review do not satisfy these checks. |

Never weaken TLS, accept arbitrary identity claims, share one relay token among customers, log credentials, expose PostgreSQL publicly, or rely on client UI filtering to enforce tenant isolation in order to make a demo work.

## Verification and sources

[Verification records](verification.md) distinguish executed tests from operational and live-provider gaps. New features must preserve these boundaries and add negative tests for the permission they introduce. This document is a threat model and engineering policy, not a compliance certification or a completed penetration test.

The 6 November review found and corrected these issues:

| Severity / scope | Finding | Correction |
| --- | --- | --- |
| HIGH release risk, implementation added; live acceptance open | The relay originally had no verified user enrollment or expiring/rotatable credentials. | Added pinned OIDC verification, device-key DPoP, transactional rotating sessions, bounded response recovery and user/device revocation. Real-provider, signed-device, infrastructure and independent-review acceptance remain required. |
| HIGH conditional credential exposure | AppAuth's default session could follow a token endpoint redirect with a refresh-token POST body. No production leak was observed. | Private ephemeral session refuses token redirects, with explicit 307/308 POST-body tests. Browser sign-in cookies are separate. |
| HIGH local store boundary | Copied/test databases reusing account IDs could reach the same client/account Keychain identity. This concerns stores under the same macOS login, not a demonstrated cross-macOS-user leak. | Canonical store namespace is part of the OAuth credential identity; only the default Google store may migrate the legacy client/account-only identity. |
| MEDIUM transport boundary | Google API sessions did not explicitly refuse API redirects and disable implicit cookies/credentials. | Private sessions, redirect denial before following, response-origin checks, and negative redirect/account-isolation tests. |
| MEDIUM credential handling | Blocking Keychain calls, implicit relay accessibility, and incomplete duplicate/type-error handling; credential work needed isolation during store changes. | Serialized actors, explicit accessibility, checked errors, scoped verified migration and cancellation/generation barriers. |
| MEDIUM routing boundary | Multiple active installations could register the same APNs destination. | Database-enforced exclusive binding and race/ownership tests. First-use possession verification remains open. |
| Published dependency advisories; exploitability not established | `crypto-bigint` 0.5.5 (RUSTSEC-2026-0387) was in the active P-256 path; `rsa` 0.9.10 (RUSTSEC-2023-0071) was enabled by the broad crypto feature although Dayfold uses ES256. | Switched jsonwebtoken's supported crypto provider to AWS-LC, retained ES256/PEM behavior, removed both packages, passed APNs regressions and a fresh audit without ignores. |

- [OWASP API1: Broken Object Level Authorization](https://api-security.owasp.org/editions/2023/en/0xa1-broken-object-level-authorization/): authorize every operation on a requested resource; knowing its ID is insufficient.
- [OAuth 2.0 Security Best Current Practice, RFC 9700](https://www.rfc-editor.org/rfc/rfc9700.html): authorization-code/PKCE protections, token privilege restriction and replay-resistant credential lifecycle.
- [Apple: Restricting keychain item accessibility](https://developer.apple.com/documentation/security/restricting-keychain-item-accessibility): choose explicit availability and device binding for stored secrets.
- [Apple TN3137: On Mac keychains](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains): per-user keychains, data-protection routing and entitlement-authorized access groups.
- [Apple: Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox): sandbox and filesystem controls have separate responsibilities.

Internal review used the Swift Security skill's common anti-patterns and credential-storage references, together with Keychain CRUD, access-control and migration references for the implementation. Platform behavior still requires a signed-build acceptance record.
