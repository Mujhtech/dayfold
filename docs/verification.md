# Verification record

Recorded 5–6 November 2026 on Apple M2 Pro, 16 GiB RAM, macOS 27.2 (26B123), Xcode 27.1 (27A9275), Apple Swift 6.4 (swiftlang-6.4.0.34.1). Deployment target: macOS 14.0. Dependencies: GRDB 7.12.0, AppAuth 3.0.0, KeyboardShortcuts 3.1.0, pinned in both lockfiles.

## Build and tests

| Command/check | Actual result | Local evidence |
| --- | --- | --- |
| `./script/build_and_run.sh --build` | Passed; real ad hoc signed `Dayfold.app`, bundle `mujhtech.dayfold`. | `.build/evidence/build.log` |
| `./script/test.sh` | 64 CalendarCore tests passed in 0.827 s; 4 CalendarPlatform tests passed in 0.002 s. Opt-in benchmark skipped in this normal run. | `.build/evidence/core-tests.log` |
| `DAYFOLD_PERFORMANCE=1 swift test --package-path Packages/CalendarCore --scratch-path .build/perf --cache-path .build/xcode/SourcePackages --configuration release --filter largeReferencePerformance` | One release benchmark test passed in 23.088 s. | `.build/evidence/performance-final.log` |
| `./script/test.sh --ui` | Test target compiled; UI runner initialization timed out. Tests did not execute successfully. Developer Mode is disabled; owner elected to retain current permissions. | `.build/evidence/ui-tests.log`, `UITests-1.xcresult` |
| `./script/archive.sh --local` | Passed; universal arm64/x86_64 Release archive. | `.build/evidence/archive.log`, `.build/archives/Dayfold-local.xcarchive` |
| `codesign --verify --deep --strict` on the archived app | Passed. Release signature is ad hoc with runtime flag, no team or debug entitlement. | Archive inspected 6 November; entitlements described in release.md. |
| Fresh local checkout of e166b10; `./script/build_and_run.sh --build` | Passed with fresh products/intermediates. Reused only the downloaded pinned SourcePackages cache; no OAuth override. Checkout stayed clean. This was not a cold-network package download test. | `.build/evidence/clean-checkout.log`, `clean-checkout-build.log` |

Both app-owned English Localizable.strings and dependency resources are packaged. The build has an informational App Intents metadata warning because there is no AppIntents dependency; no app source compile errors remain.

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
