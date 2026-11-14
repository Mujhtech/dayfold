# Real-time updates and push reminders

Dayfold can connect to the optional [notification relay](../backend/README.md) from **Settings → Real-time**. Public connections use a separate Dayfold account and a revocable session for each Mac. Normal Google synchronization and local reminders remain available without it. Demo mode never connects to the relay.

## Connect the Mac

1. Deploy the relay behind a public HTTPS origin and configure the OIDC native client, pinned issuer/JWKS and private session key as described in [authentication setup](authentication.md).
2. In Dayfold's Google store, open **Settings → Real-time**, enter the service origin and choose **Continue**. Review the identity-provider issuer before choosing **Sign in to Dayfold**. Complete sign-in in your browser; Dayfold uses PKCE/state and the relay's one-use nonce.
3. The Mac stores its private device key, expiring access/refresh credentials and interrupted-request recovery state in Keychain. No Google Calendar credential is sent to the relay. Dayfold account sign-in is separate from calendar authorization.
4. Connect Google accounts through Accounts settings. Dayfold creates calendar-list and event watches using their on-device authorization, replaces expiring watches while running and consumes change hints through its live stream.
5. Keep using local reminders. Public sessions currently report APNs unavailable until a separate push-destination possession challenge is implemented; signing/APNs configuration alone does not enable public push registration.
6. The connected account lists its enrolled Macs. **Revoke**, **Sign out of all devices** and **Delete Dayfold account** manage relay access. Deleting the relay account does not delete your identity-provider account or Google calendars.

Debug builds accept an explicit loopback origin such as `http://127.0.0.1:8080`; release builds require HTTPS. The example public origin is a placeholder and cannot receive real Google callbacks. A local backend can be exercised with the provided stub-provider integration test without contacting Google or Apple.

The native connection persists its replay cursor, pending calendar-sync work, watch identities, reminder revisions and delivery ownership in SQLite. Restarting the app resumes that state. The signing key and access/refresh credentials stay in Keychain. Refresh rotates credentials atomically; retries recover the same response when the network drops. Reauthentication is required after the session limit or revocation. A locked Keychain or unavailable relay shows a recoverable status; it does not erase the stored connection.

## Provisioned macOS APNs build

**These are distribution prerequisites for future verified push enrollment; public account sessions currently cannot register a push destination.**

Enable Push Notifications on the Apple App ID matching `mujhtech.dayfold`. Install a macOS signing identity and provisioning profile containing the macOS `com.apple.developer.aps-environment` entitlement. Apple's environment values are `development` and `production`; the client sends them to the relay as `sandbox` and `production`. See [Apple's macOS entitlement reference](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.aps-environment).

```sh
export DAYFOLD_DEVELOPMENT_TEAM='YOUR_TEAM_ID'
export DAYFOLD_SIGN_IDENTITY='YOUR_INSTALLED_SIGNING_IDENTITY'
export DAYFOLD_APNS_PROFILE='YOUR_INSTALLED_MACOS_PROFILE_NAME_OR_UUID'
export DAYFOLD_APNS_ENVIRONMENT=development
./script/build_and_run.sh --push-build
# Build and launch the provisioned app:
./script/build_and_run.sh --push
```

This uses `.build/push` and [DayfoldPush.entitlements](../Config/DayfoldPush.entitlements). The build verifies the signed app and embedded profile agree on the APNs environment, team and app identity. It does not create Apple certificates/profiles, change account capabilities, publish or notarize the app. The ordinary `--build`/`--demo` paths remain ad hoc local builds and cannot register with APNs.

On the server, configure `DAYFOLD_APNS_TEAM_ID`, `DAYFOLD_APNS_KEY_ID`, `DAYFOLD_APNS_TOPIC=mujhtech.dayfold` and `DAYFOLD_APNS_KEY_FILE` together. Keep the `.p8` key outside source control. The server selects Apple's sandbox or production endpoint from each installation's registered token environment. The app registers through `NSApplication` and uploads every successful token callback; it does not assume a cached token remains valid.

## Reminder ownership and delivery

Dayfold hands future reminders to the relay only after the server reports APNs enabled and this running app has successfully registered its token. Notification permission, both reminder preferences, and the current cached event must also permit scheduling. It persists ownership and removes the corresponding local pending notification before uploading. An ambiguous upload failure retains ownership and retries the same identity/revision. Cancellation is persisted first and local scheduling resumes only after the server confirms cancellation. This favors avoiding duplicate alerts when connectivity is uncertain.

For a due reminder received through SSE, the app explicitly claims local delivery. The server atomically decides whether the Mac or APNs owns it. An ordinary stream acknowledgement does not cancel an unclaimed reminder push. The Mac validates the current revision, deduplicates notification IDs and uses a stable local notification identifier. APNs foreground alerts go through the same current-state checks; a tap resolves the opaque reminder ID to the cached event, including after launch.

APNs reminders carry generic text. Titles, attendees, descriptions, meeting links and Google Calendar access/refresh tokens never leave the Mac for the relay. Local streamed reminders can use the user's notification privacy preference. See [privacy](privacy.md) for metadata retained by the service.

The service cannot fetch Google events or extend the scheduling horizon while the Mac is quit or asleep. Google/APNs delivery can be delayed or omitted; periodic sync and durable inbox replay remain necessary. An already submitted Apple alert cannot be recalled after an event changes. Disabling relay reminders or disconnecting requires reaching the service to confirm remote cancellation before returning ownership to local scheduling.

## Verification boundary

The legacy transport integration check uses the real Swift HTTP/SSE client, Rust service and PostgreSQL, with stub Google callbacks and an in-memory notification sink. New OIDC/DPoP behavior is checked separately with signed-token fixtures, native session tests and database/API tests. They do not prove delivery through Google, APNs, Notification Center, Focus, sleep/wake or a quit app. See [verification](verification.md) for executed checks.

For legacy transport integration only, explicitly start the service with `--allow-legacy-dev-auth` on loopback with APNs disabled and no OIDC configuration. The Debug app exposes manual operator-token entry only with `--allow-development-relay` and an HTTP loopback origin. This is not public onboarding.

With that local service already running and `DATABASE_URL` set to the disposable loopback database, run `python3 script/test_relay_integration.py`. The wrapper provisions a temporary installation, passes its bearer through a private temporary file, invokes the opt-in Swift test, then revokes it. The test refuses an APNs-enabled service. The ordinary `./script/test.sh` leaves this integration check skipped unless explicitly configured.

Real-provider acceptance first requires a public TLS relay and an actual OIDC native-app registration/browser sign-in. Push acceptance additionally requires the destination challenge implementation, configured APNs key, matching provisioned Mac build, Google Desktop OAuth configuration and an authorized test calendar. Verify an external calendar edit, watch renewal, stream reconnection, a foreground reminder, a reminder while the app is closed, and a notification tap after launch. Repeat against the intended APNs environment before release.
