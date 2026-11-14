# Verification record

Recorded 5–6 November 2026 on Apple M2 Pro, 16 GiB RAM, macOS 27.2 (26B123), Xcode 27.1 (27A9275), Apple Swift 6.4 (swiftlang-6.4.0.34.1). Deployment target: macOS 14.0. Dependencies: GRDB 7.12.0, AppAuth 3.0.0, KeyboardShortcuts 3.1.0, pinned in both lockfiles.

## Build and tests

| Command/check | Actual result | Local evidence |
| --- | --- | --- |
| `./script/build_and_run.sh --build` | Passed; real ad hoc signed `Dayfold.app`, bundle `mujhtech.dayfold`. | `.build/evidence/build.log` |
| `./script/test.sh` | Latest run: 64 CalendarCore tests passed in 0.755 s; 5 CalendarPlatform tests passed in 0.572 s. Opt-in benchmark skipped in this normal run. | `.build/evidence/core-tests.log`, `appearance-regression-suite.log` |
| `DAYFOLD_PERFORMANCE=1 swift test --package-path Packages/CalendarCore --scratch-path .build/perf --cache-path .build/xcode/SourcePackages --configuration release --filter largeReferencePerformance` | One release benchmark test passed in 23.088 s. | `.build/evidence/performance-final.log` |
| `./script/test.sh --ui` | Test target compiled; UI runner initialization timed out. Tests did not execute successfully. Developer Mode is disabled; owner elected to retain current permissions. | `.build/evidence/ui-tests.log`, `UITests-1.xcresult` |
| `./script/archive.sh --local` | Passed; universal arm64/x86_64 Release archive. | `.build/evidence/archive.log`, `.build/archives/Dayfold-local.xcarchive` |
| `codesign --verify --deep --strict` on the archived app | Passed. Release signature is ad hoc with runtime flag, no team or debug entitlement. | Archive inspected 6 November; entitlements described in release.md. |
| Fresh local checkout of e166b10; `./script/build_and_run.sh --build` | Passed with fresh products/intermediates. Reused only the downloaded pinned SourcePackages cache; no OAuth override. Checkout stayed clean. This was not a cold-network package download test. | `.build/evidence/clean-checkout.log`, `clean-checkout-build.log` |

Both app-owned English Localizable.strings and dependency resources are packaged. The build has an informational App Intents metadata warning because there is no AppIntents dependency; no app source compile errors remain.

## Rust notification backend — 6 November 2026

The initial optional relay is implemented as six linked Cargo crates under `backend/`, using Rust 1.96.0 and PostgreSQL 17 in a separate local Docker Compose project. The database is bound to `127.0.0.1:55432`; the development HTTP service is bound to `127.0.0.1:8080`. Existing unrelated containers were not modified.

| Check | Actual result | Local evidence |
| --- | --- | --- |
| `cargo fmt --manifest-path backend/Cargo.toml --all --check` | Passed. | Final validation command |
| `DAYFOLD_TEST_DATABASE_URL=... cargo test --manifest-path backend/Cargo.toml --workspace --locked -- --include-ignored` | All 38 tests passed: 29 unit/provider tests and 9 real PostgreSQL integration tests; none skipped. The database tests completed in 0.96 s using isolated temporary schemas. | `.build/evidence/backend-tests-final.log` |
| `cargo clippy --manifest-path backend/Cargo.toml --workspace --all-targets --locked -- -D warnings` | Passed with warnings denied. | `.build/evidence/backend-clippy.log` |
| `cargo build --manifest-path backend/Cargo.toml --locked -p dayfold-server` | Passed; executable built and initial local database migration applied. | `.build/evidence/backend-build.log` |
| Local HTTP/SSE smoke check | Passed authentication, channel ownership, early callback binding, webhook duplicates/reordering, SSE replay, reminder scheduling/idempotence/cancellation, acknowledgements, cursor lookup and revocation. | `.build/evidence/backend-smoke.log` |
| Process restart check | An unacknowledged hint survived a forced process kill, replayed with the same ID over SSE after restart, and was acknowledged. Graceful shutdown also passed. | `.build/evidence/backend-restart-smoke.log` |

Database regressions cover concurrent callback commit order, competing schedulers, cancellation races, lease recovery and fencing, stale APNs responses after token registration, bounded retention, atomic full-inbox rejection/retry, and fairness when one installation's inbox is full. APNs tests verify HTTP/2 request construction, ES256 authentication/rotation, payload privacy, reminder revisions, retry handling and invalid-token classification through a fake transport and public test-only signing keys.

No Google watch was registered and no notification was sent to Apple. APNs is disabled in the local service. The native integration added after this initial backend pass is recorded below. Real APNs signing/device delivery, a public HTTPS endpoint, live Google acceptance, deployment, load/failover and backup recovery remain unverified. See [backend setup and protocol](../backend/README.md).

## Native relay integration — 6 November 2026

The Mac now connects through Settings → Real-time, stores its installation bearer in Keychain, creates/renews Google watches using local OAuth, resumes authenticated SSE from persisted cursors, and handles APNs token callbacks and notification taps. Schema v6 stores pending refresh intent, routing, reminder revisions and delivery ownership. Production handoff requires APNs capability, uploaded token, user preference and notification permission; the integration test explicitly permits SSE-only reminder ownership in its injected test policy.

| Check | Actual result | Local evidence |
| --- | --- | --- |
| `./script/test.sh` | 93 core and 17 platform tests executed successfully. Swift Testing reports 95 core cases, including two deliberately skipped opt-in cases: the large-data benchmark and live loopback relay integration. | `.build/evidence/native-relay-tests.log` |
| Relay protocol regressions | 11 Swift HTTP/SSE tests passed: exact wire fields, dates, error sanitization, redirect rejection, cursor resume, cancellation, parsing and bounded overflow. | Included in the full suite |
| Google watch regressions | 8 tests passed for local authorization, watch request/response binding, stop, expiration validation and ambiguous failures. No Google requests were sent. | Included in the full suite |
| Durable coordinator regressions | 8 tests passed for pending refresh persistence/restart, ACK retry, 410 recovery cursor, reentrant input, activation retry, ambiguous reminder PUT ownership, delivery claims/deduplication and cancellation confirmation. | Included in the full suite |
| Sync/scheduler concurrency regressions | 3 strict relay-sync tests and 2 notification barrier/error tests passed. A busy calendar work gate cannot be acknowledged as refreshed; a coalesced ownership handoff cannot return while an older local notification add remains in flight. | Included in the full suite |
| Real Swift/Rust/Postgres integration | Actual HTTP/SSE transport, authenticated simulated Google callbacks, reminder claim/delivery, SQLite reopen/replay and a subsequent change passed. Disconnect and temporary installation revocation were checked. The notification sink is a test double; Apple/Google delivery is not exercised. | `.build/evidence/native-relay-integration.log` |
| Backend ownership regressions | 30 Rust unit/provider tests and 13 PostgreSQL tests passed; formatting and Clippy passed. Migration 0002 adds atomic local delivery claims. | `.build/evidence/backend-reminder-claim-unit-tests.log`, `backend-reminder-claim-tests.log`, `backend-reminder-claim-clippy.log` |
| Updated backend HTTP smoke | Passed authenticated capabilities, reminder-claim ownership/idempotency, post-ACK claims and cancellation; service reports APNs disabled. | `.build/evidence/backend-native-smoke.log` |
| Native build and UI | Debug app builds through the authoritative script. The running demo's Real-time tab showed disabled connection controls, an off reminder toggle and clear demo/privacy guidance. No UI automation permissions were changed. | `.build/evidence/build.log`; manual native app observation |

The new provisioned build path (`--push-build`/`--push`) checks the app's signed macOS APNs entitlement against its embedded profile. The actual signed path has not been run: no matching profile/key configuration was supplied. Ordinary ad hoc builds do not claim APNs registration. Setup and live acceptance steps are in [relay.md](relay.md). Store-switch and disconnect callbacks capture the original store and verify generation/connection identity; the full AppModel lifecycle still lacks an automated UI harness under the retained host permissions.

## Multi-user security review and hardening — 6 November 2026

The owner made multi-user security an explicit requirement. [security.md](security.md) records the trust boundaries, corrected findings and public-release blockers. At that review stage the server authenticated installations only. The subsequent account/session implementation and its evidence are recorded below.

| Check | Actual result | Local evidence |
| --- | --- | --- |
| Final Swift suite | **125 tests executed successfully:** 98 core + 27 platform. Swift Testing reports 100 core cases including two intentionally skipped opt-in checks (large-data benchmark and real loopback integration). | `.build/evidence/native-security-final-tests.log` |
| Google transport isolation | Five new tests cover five redirect status cases, same-origin redirect refusal, unexpected final URL, cookie isolation, concurrent Google accounts/401 refresh and sanitized cancellation. The focused combined Google/relay run passed 19 tests. | `.build/evidence/native-transport-security-tests.log` |
| Credential and AppAuth boundaries | Eight credential regressions cover exact Keychain identities/statuses/accessibility, verified migration/failure preservation, namespace isolation, off-main execution, retired/stale credential work and archived OAuth endpoint rejection. Two AppAuth transport tests cover storage configuration and 307/308 refresh-token POST redirects. | `.build/evidence/oauth-token-transport-security-tests.log`; included in final suite |
| Backend authorization | All **47 Rust tests** passed: 30 unit/provider + 17 PostgreSQL tests. New tests cover foreign-device operations, exclusive APNs registration/concurrency and fail-closed migration of conflicting legacy destinations. | `.build/evidence/backend-security-postgres-tests.log`, `backend-crypto-tests.log`, `backend-crypto-postgres-tests.log` |
| HTTP/API boundary checks | Rebuilt service passed the updated smoke check: duplicate security-header rejection, foreign channel deletion/inbox/ACK/claim rejection, self-only revocation and exclusive push registration. APNs remained disabled. | `.build/evidence/backend-crypto-smoke.log` |
| Dependency audit | Initial RustSec audit found RUSTSEC-2026-0387 (`crypto-bigint` 0.5.5) and RUSTSEC-2023-0071 (`rsa` 0.9.10). Switching jsonwebtoken's supported provider to AWS-LC removed both. A fresh database of 1,422 advisories scanned the resulting 300-package lockfile successfully, with **no ignores/exclusions**. APNs ES256 signing, rotation and wrong-curve tests passed after the change. | `.build/evidence/backend-dependency-audit.log`, `backend-dependency-audit-final.log`, `backend-crypto-tests.log` |
| Native app and filesystem | Final app built and launched in the separate demo store. Its actual store directory reports mode `0700`. OAuth/relay credentials use per-store actors and late-operation barriers. | `.build/evidence/build.log`; filesystem permission inspection |
| Local end-to-end regression | Real Swift HTTP/SSE client and coordinator still work with the rebuilt Rust/PostgreSQL service, including callback ingestion, one reminder claim, restart/replay, disconnect and temporary credential cleanup. Google callbacks and notification display remain test doubles. | `.build/evidence/native-security-integration.log` |
| Repository checks | Rust fmt/Clippy and `git diff --check` pass. Signing shell/Python scripts parse. GitHub workflow YAML, immutable action pins, disabled credential persistence and read-only token permissions validated locally. | `.build/evidence/backend-crypto-clippy.log`; local configuration checks |

CI definitions now run native tests/build, backend database isolation tests and a pinned RustSec audit. Dependabot is configured for Cargo, Swift and Actions. These definitions are local changes; no GitHub workflow run, branch-protection change, secret-scanning activation or push occurred. The audit does not establish absence of undisclosed vulnerabilities or replace code review.

Distribution archives now require a provisioning profile and verify the signed private Keychain identity. A real provisioned build, locked/unlocked migration behavior and Google/APNs delivery remain untested because the needed owner configuration is absent. The existing local archive predates these changes. No OS permissions were broadened, no real Google credentials were accessed, and no Apple notifications were sent.

## Calendar UI refinement — 6 November 2026

The editor/Quick Entry follow-up replaces the 620×760 form with a 640×600 scrolling editor and pinned actions. Title, calendar and scheduling are prominent; time zones, guests, notes and event options expand when needed. Existing event calendars remain readable as static labels. Quick Entry has example inputs, a parsed date/time preview, human-readable repeat labels and one Return/button review path. Its implementation now lives in `QuickEntryView.swift`. Draft assembly, validation and persistence remain unchanged. Manual demo checks covered the create and edit layouts, all-day fields, guest expansion, scrolling with the footer pinned, ambiguous-date guidance, and Return handing a parsed 45-minute event to the editor. Temporary test drafts were discarded and the pre-existing Quick Entry text was restored. The final source passed `git diff --check`, built successfully and relaunched through `./script/build_and_run.sh --demo`.

The saved appearance was Dark; it was changed to System to follow the owner's light desktop. Native application appearance alone did not cover every SwiftUI presentation, so the same preference is now explicitly bound at all scene roots and the editor/account-setup sheets through `DayfoldAppearance`. Rendered checks observed Settings change Dark → Light → System, Quick Entry in light/dark, the existing companion preview change dark → light, a light date popover, and the main calendar/editor in System/light. The companion preview hosts the production content; actual native menu-bar panel colors and the status item's label were not directly captured because the system menu-bar surface was unavailable through UI automation. Time/countdown labels now explicitly request title and icon, with “Dayfold” as the no-event/loading fallback; icon-only remains an explicit preference. The 64 core and 5 platform tests passed (`.build/evidence/editor-appearance-tests.log`); those tests do not replace the rendered checks or prove the native tray label.

The companion and motion pass uses a fixed 360×530 content area, a current/next-event focus, aligned schedule rows, and a fixed footer. Details use a short offset and fade; view changes, selection highlights, search, and inspector presence use scoped transitions. Reduced Motion disables the custom animations. The companion now follows the app appearance preference. The calendar column extends its adaptive background behind its own toolbar area, while the full-width toolbar backdrop is hidden so it does not cover the sidebar material. This replaces the initial solid toolbar fill, which the owner screenshot showed was covering the translucent area above the sidebar. Toolbar text is now 13 pt with 30 pt custom control heights, larger trailing symbols, and the native unified toolbar style. The full detail frame also covers loading and empty states.

The final source built and launched with `./script/build_and_run.sh --demo`; `git diff --check` passed. The existing suites passed again: 64 core tests in 0.853 s and 4 platform tests in 0.004 s. These suites do not exercise AppModel's new UI load guards. Manual checks in the debug companion preview (the production `MenuBarView` hosted in a window) covered opening details, returning to the agenda, and three rapid next-day actions ending with the correct date and events. Light and dark companion layouts were observed. The `--reduce-motion` debug launch rendered successfully, but a complete reduced-motion interaction check was not completed. Normal motion was restored afterward.

The model now rejects outdated day/range/zone results, preserves a newer inspector selection during asynchronous lookup, and distinguishes loading, unavailable, and empty companion days. Failure states provide retry. Deterministic out-of-order model-load tests, frame-rate measurements, and the native menu-bar opening animation remain unverified. UI capture repeatedly timed out or returned a Stage Manager thumbnail; the final toolbar color match therefore has build evidence but no reliable full-window visual verification. No new screenshot is claimed for this pass. Debug-only `--companion-preview` and `--reduce-motion` options allow repeatable local checks without changing macOS settings.

The appearance follow-up removes per-scene color-scheme overrides and applies the saved preference through `NSApplication.appearance`. Light and Dark set an app-wide appearance; System clears it to inherit macOS. Applying it at initialization and whenever the preference changes also covers Settings, Quick Entry, sheets, and newly opened windows. The final app built and launched successfully and passed `git diff --check`. Settings accepted Light → Dark → System → Dark, restoring the original Dark preference. UI captures were blank, so rendered colors across every surface and a live macOS appearance change were not visually verified. The temporary companion preview was closed afterward.

The immediate-update regression check now runs the same `PlatformServices.setAppearance` function used by AppModel's synchronous preference observer. It initializes AppKit and real offscreen window devices, cycles six Light/Dark/System selections, and checks the app override immediately plus existing native windows, SwiftUI hosting views, and newly created panels after bounded event-loop delivery. All cases pass, including clearing the System override and leaving window-specific appearances unset. The full suite passes 69 tests. This verifies native appearance inheritance without relying on screenshots; it does not measure frame rendering or replace a visual check of the actual menu-bar popover. Final source built and relaunched normally.

The subsequent compact week-view pass follows the owner's Things/Linear direction. It replaces the large content heading with one native toolbar, caps the source sidebar at 200 pt, reduces weekday headers, and moves search into a dismissible row. Narrow overlap groups expose a summary that opens the agenda. The final source built and launched successfully; manual checks covered search and Escape dismissal, event selection, overlap expansion with the inspector open, and light/dark week rendering. The previous Dark appearance preference was restored. Captures: [compact light week](screenshots/week-compact-light.png), [compact dark week](screenshots/week-compact-dark.png). This pass establishes the week view and shared shell; it is not a completed redesign of the editor and settings. A separate minimum-window-size check was not completed.

Reworked the sidebar, date/view header, timeline event blocks, month grid, agenda, and event inspector. The final source passed `./script/build_and_run.sh --demo` and `git diff --check`. Week, month, agenda, and inspector were inspected in the running demo app; light and dark appearances were reviewed. The final dark week capture includes corrected selected-date and primary-button contrast. The app appearance preference was restored to System.

The header now has a two-row fallback, short event blocks retain pending-state markers, and UI test selectors match the new view buttons. The existing UI runner limitation above remains; this styling pass did not rerun the functional suites.

Updated captures: [week](screenshots/week-redesign.png), [month](screenshots/month-redesign.png), [agenda](screenshots/agenda-redesign.png), [inspector](screenshots/inspector-redesign.png), [dark week](screenshots/week-dark-redesign.png).

The local archive is not notarized, and the x86_64 slice has not been run. Minimum macOS execution, a fresh quarantined install, and Developer ID distribution validation are not claimed.

## Large-data measurements

The deterministic release fixture contains 100,000 events, 5 accounts and 50 calendars. Query/layout/save measurements use 20 samples on the host above.

| Operation | p50 | p95 |
| --- | ---: | ---: |
| Read a visible week from SQLite and build snapshot | 24.054 ms | 49.722 ms |
| Local FTS search | 0.811 ms | 11.460 ms |
| Layout a dense week of 700 timed events | 35.998 ms | 37.526 ms |
| Durably save one draft | 1.071 ms | 1.969 ms |

Staging and publishing all 100,000 records took 20.750 s. Peak process RSS was 296.313 MiB, including the complete in-memory test fixture and harness. This is not the application memory footprint. These measurements do not establish end-to-end frame/menu latency, live network throughput, or startup targets.

A separate companion-only demo sample ran from 05:38:32 to 05:43:20 UTC on 6 November with all windows closed. CPU time increased from 18.66 s to 23.18 s over 288 s (about 1.6% of one core on average), with sampled RSS from 24–68 MiB and 0% instantaneous CPU at the last sample. This is a short observation, not an extended idle/power benchmark. Source records: `idle-start.log`, `idle-end.log`, `idle-final.log`.

## Manual app records

All records below use the actual app bundle and explicitly labeled fictional demo data.

| Record | Observed result |
| --- | --- |
| MAN01 Launch and persistence | Launched through Launch Services; populated week displayed. A created event survived an app restart and remained editable. |
| MAN02 Shared surfaces | A newly saved event appeared in the main window and menu companion's Up Next list. Menu screenshot was not captured. Reverse menu-to-window editing still needs a specific record. |
| MAN03 Edit and text undo | Edited a saved event, used Cmd-Z inside its title field, then saved. Agenda and inspector showed the final title. |
| MAN04 Conflict recovery | Demo conflict showed local/remote differences. Keep Google version resolved it; Pending Changes showed All caught up. No real Google write occurred. |
| MAN05 Views and overflow | Cmd-2/3 selected week/month. A month cell's +4 more action opened agenda with all seven events for that day. |
| MAN06 Quick entry | Ambiguous `Review 03/04 at 2` remained a draft after Keep Draft & Close and reopening; Choose date & time opened explicit editor. No automatic event creation. |
| MAN07 Accounts/settings | Account groups, roles, local labels, calendar sync choices, and missing OAuth configuration guidance were visible. |
| MAN08 Appearance | Dark and light appearance inspected at different times; event text/source accents and hidden segmented-control label corrected. High contrast, RTL, reduced-motion settings and VoiceOver interaction not exercised. |
| MAN09 Resident lifecycle | Closed Settings and the main window. Accessibility reported no windows while app inventory reported Dayfold still running. Dock reopening check did not complete; do not infer that it passed. |
| MAN10 Logging | Observed local store-ready, sync duration, save and mutation-state logs. Format contains categories/counts/timings, no event titles, raw URLs, guests or credentials. Live OAuth/error flows were not logged/tested. |
| MAN11 Final launch | Rebuilt/launched final source with `--demo`; persisted event appeared in week and agenda. Captured agenda, then restored the week view. |

Screenshots: [week](screenshots/week.png), [month](screenshots/month.png), [agenda](screenshots/agenda.png), [editor](screenshots/editor.png), [quick entry](screenshots/quick-entry.png), [accounts](screenshots/accounts.png), [conflict](screenshots/conflict.png). They are unedited app captures containing fictional data. Companion interaction was observed, but its dedicated screenshot is still missing.

## Remaining prerequisites and evidence

No `Config/OAuth.local.json`, authorized live test accounts, or approved test attendees were supplied. Google auth/partial scopes/policy handling, two-account synchronization, actual mutations/recurrence/invitations and Meet generation therefore have no live acceptance record. Setup steps are in [setup.md](setup.md). Do not use existing real meetings as test fixtures.

Notifications and login items have implementation and deterministic planning evidence, but their OS delivery/actions/approval behavior remain unverified. External-display frame math is tested; physical display removal is not. Accessibility, locale transitions, minimum macOS 14 and Intel runtime checks remain incomplete. No signing identity/notarization credentials or clean-profile installation evidence is available.

Each of the brief's acceptance IDs has an implementation reference and actual evidence or limitation in [acceptance.md](acceptance.md). Passing deterministic tests do not replace the missing live/platform records.


## Dayfold user authentication and device sessions — 7 November 2026

Implemented the [OIDC/DPoP account lifecycle](authentication.md): pinned identity verification, device-key enrollment, ten-minute access credentials, rotating refresh families, persistent replay detection, bounded response recovery, device/all-device revocation and account deletion. Native Keychain writes, pending operations and confirmed-revocation cleanup are serialized; failed writes/deletes remain retryable. Store changes retain captured repository/vault identities and check generations after suspension.

| Check | Actual result | Local evidence |
| --- | --- | --- |
| Complete native suite | **146 executed tests passed: 98 core + 48 platform.** The core runner lists 100 cases including two deliberately skipped opt-in checks. The 21 new platform cases include seven independently checked DPoP signer cases and 14 session/client cases for refresh concurrency, response loss/restart, Keychain write/delete failures, enrollment races, foreign-account cleanup and confirmed revocation. | `.build/evidence/auth-native-tests.log`, `native-account-session-tests.log`, `native-device-proof-tests.log` |
| Complete Rust workspace | **86 tests passed, zero skipped:** 53 unit/provider/API checks and 33 PostgreSQL-backed checks. Coverage includes signed OIDC/DPoP negatives, duplicate claims/keys, transport bounds, cross-user actions, request replay, rotation races/recovery, session expiry, transactional account actions, deletion confirmation and credential quotas. | `.build/evidence/auth-workspace-tests.log` |
| Static checks and dependency audit | Workspace formatting/Clippy passed; server build/Clippy passed again after the final startup fix. Fresh RustSec database: 1,422 advisories, 302 dependencies, no findings or ignored advisories. | `.build/evidence/auth-workspace-clippy.log`, `auth-server-clippy.log`, `auth-dependency-audit.log` |
| Startup boundaries | Missing public authentication, a non-loopback legacy listener, legacy plus partial OIDC and legacy plus complete OIDC all fail before listening/provider discovery. Production sessions and legacy test credentials cannot be enabled together. | `.build/evidence/auth-server-startup-check.log` |
| Migration and HTTP smoke | Migration 0004 applied to the disposable local database. Rebuilt APNs-disabled legacy test service passed authentication, ownership, webhook, SSE, reminder, claim and revocation smoke checks. | `.build/evidence/auth-backend-migrate.log`, `auth-server-smoke.log` |
| Process restart | Isolated loopback process crash/restart preserved notification identity and replay; acknowledgement, revocation and graceful shutdown passed. | `.build/evidence/auth-server-restart.log` |
| Real Swift/Rust/PostgreSQL transport | Opt-in legacy transport integration passed separately in 9.043 seconds, including simulated callbacks, reminder claims, restart/replay, disconnect and temporary installation cleanup. No real Google/APNs traffic or notification presentation occurred. | `.build/evidence/auth-native-integration.log` |
| Native app | Authoritative build and ad hoc signature verification passed; rebuilt app launched in its separate demo store. Accessibility inspection confirmed the Real-time settings show Dayfold sign-in, service address, browser-sign-in explanation, disabled demo controls and privacy guidance. No account, credentials or OS permissions were changed. | `.build/evidence/auth-native-build.log`, `auth-native-launch.log`; manual native observation |

These checks do **not** establish live OIDC browser/provider acceptance or a signed Keychain deployment. No real identity-provider registration, public relay, Apple signing/profile configuration or APNs possession challenge was supplied or deployed. Public user sessions report APNs unavailable and reject push registration until destination possession is implemented. Infrastructure/load/restore acceptance and independent security review remain release requirements. Local server testing explicitly used development mode on loopback, with APNs disabled. No source commits or pushes were made.

## Shared scrollbars and brand accent — 7 November 2026

All app scene and sheet roots now inherit `.scrollIndicators(.never)` through `DayfoldAppearance`; the event editor's explicit automatic-indicator override was removed. A source audit covered ScrollView, List, Form, multiline fields, windows, sheets and the inspector. The existing calendar, companion and Settings policies remain in place. Native system file dialogs are unaffected.

The named `AccentColor` asset now uses deep teal (`#2F6B5F`) in light appearance and the icon's mint (`#A7D9C6`) in dark appearance. Shared tint and custom selection/focus highlights use that named asset; the inspector's hardcoded indigo button tint was removed. Calendar-source colors and semantic status colors remain separate.

The authoritative build and `git diff --check` passed. The running demo's pending changes, existing draft editor and event inspector exposed scroll areas without scrollbar controls in accessibility inspection. An existing draft was opened and closed without changing its fields. System → Dark → System was exercised and the original System preference restored. Captures were limited to Stage Manager thumbnails, so this pass does not claim a full-resolution visual contrast audit. No live Google writes were sent.

## Guided introduction — 7 November 2026

Replaced the empty-store calendar shell with a four-step introduction using the app icon and shared teal accent. The onboarding title bar is blank at the owner's request; the calendar retains its range title. Calendar selection is shared with the additional-account sheet, including a writable default and fallback when its calendar is deselected. Reminder permission and launch at login require explicit actions. Demo replay explains these options without requesting either system change. Help can reopen the guide; active progress is stored separately in each store, and legacy preferences skip automatic onboarding.

The authoritative Xcode build, ad hoc signature verification, launch, and whitespace check passed. The focused `onboardingPreferencesPreserveLegacyStateAndResumeActiveStep` test passed, covering old preference decoding and active-step round-trip while preserving reminder settings. Native accessibility inspection exercised the welcome, missing Google configuration alert, direct demo entry, Help replay, calendar selection, reminder skip, companion/shortcut step and Open Calendar. Quitting at the reminders step and reopening resumed that step; quitting after completion and reopening showed the calendar. The app was returned to the empty Google-store welcome, with no title text in the title bar. No calendar choice, draft, notification permission, login item or shortcut was changed during this walkthrough.

A full-size welcome capture confirmed the layout and app icon; subsequent captures were Stage Manager thumbnails, so they are not evidence of a full visual audit for every step. The first live Google-account transition, permission approval/denial, launch-at-login approval and calendar-choice writes still need live/manual acceptance. OAuth configuration is absent and UI automation runner permissions were left unchanged.


## Optional assistant workspace — 7 November 2026

Calendar remains the default experience; onboarding and General settings offer an optional Assistant workspace. The assistant now has a separate planning layout with a request composer, actual day schedule, connection sheet, and one proposed event for review. The existing calendar, event editor, durable drafts and normal save/sync path remain available. Switching the experience back to Calendar cancels and clears assistant work.

The cloud adapter uses the OpenAI Responses API with the user's API key, stored separately for each local store in Keychain. Explicit requests use two bounded read tools (one day's schedule and free-time windows). Replies and proposed dates/times are validated before the editor can open. Fixture checks cover tool replay, refusal and malformed replies, limits, cancellation serialization, redirect rejection, credential storage, and key length. Availability checks include hidden synchronized calendars and reject incomplete, stale or invalid data.

`script/test.sh` passed **178 executed tests: 111 core and 67 platform**, with the existing opt-in performance and local relay integration checks skipped. Evidence: `.build/evidence/cloud-assistant-tests.log`. The Xcode build, ad hoc signature verification and `git diff --check` passed.

Manual checks in the isolated demo confirmed the redesigned workspace at full window size, the separate connection sheet, fill-only examples, preserving a composed request while opening/closing connection settings, next-day/Today navigation, and opening an event from the day preview in the normal Calendar inspector. Returning to Assistant preserved the composed request. The app was left in Assistant with today's schedule and an empty composer. No credentials were entered, no live OpenAI requests were sent, and no Google writes occurred. Live model output quality and the complete model-to-editor save flow remain unverified until an API key is configured; the proposal and tool behavior above has deterministic fixture coverage.
