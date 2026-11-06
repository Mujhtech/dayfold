# Implementation status

Updated 6 November 2026. M00–M11 have a working development implementation, a real macOS app, deterministic regression coverage, and local archive evidence. **Core is not yet verified for beta.** The [185-case acceptance map](acceptance.md) records partial and missing evidence explicitly; a compiled feature is not a passed acceptance case.

| Milestone | Implemented behavior and evidence | Remaining acceptance evidence |
| --- | --- | --- |
| M00 | Existing starter preserved in a0e0c47; Xcode project, shared scheme, pinned packages, scripts, Run action, ad hoc build. | Clean-checkout result is recorded in verification.md. |
| M01 | Real bundle launched; populated demo, shared menu data, editing, restart persistence, closing all windows while process stays alive. | Dock activation and login launch need completed manual records. |
| M02 | Schema v5, scoped identities, staged snapshots, transactional drafts/outbox, migration, interrupted work, disk-full rollback, corruption preservation, future-schema refusal. | No previous public beta exists; migration evidence uses the committed v1 fixture. |
| M03 | AppAuth external browser/PKCE, loopback cleanup/timeout, Keychain adapter, subject reconnection, single-flight refresh, grant capabilities. Fake AppAuth/credential tests pass. | Owner Google Desktop OAuth configuration and authorized test accounts are absent. |
| M04 | Complete calendar/resource/window paging, scoped 410 reset, gates/generations, free/busy, metadata refresh, account isolation, shared budgets/backoff, bounded prefetch. | Live provider/account matrix and some lifecycle stress scenarios remain unverified. |
| M05 | Day/week/month/agenda, overlaps/overflow, multi-day spans, source visibility sets, fixed display zone, keyboard navigation, inspector/editor and coverage states. | VoiceOver, high contrast/RTL, external monitor and locale-change interaction records remain. |
| M06 | Durable narrow writes, stable create IDs, uncertain reconciliation, merge/conflict review, rejected-write correction, dependencies, conditional undo/redo. Fake failures and manual conflict resolution pass. | Live conditional mutations, guest effects and full platform shutdown scenarios remain. |
| M07 | Basic recurrence form, master/instance scope, imported-rule preservation/fallback, participant-only RSVP, guest-copy removal distinctions. | Provider-expanded recurrence, real invitations, recurring RSVP and guest removal require live tests. |
| M08 | Global quick-entry command, validated parser/preview, recoverable draft, explicit time fallback, safe meeting links, Meet request states. Manual quick-draft retention passes. | Actual global-hotkey collisions and live Meet lifecycle remain. |
| M09 | Reminder planner/reconciliation, stable one-shot IDs, privacy, snooze, permissions/preferences, SMAppService state, wake handling. Deterministic reminder tests pass. | Notification delivery/actions, login launch and sleep/wake behavior need actual OS records. Demo does not schedule system reminders. |
| M10 | Local FTS, stale-query guard, pending/conflict UI, versioned recovery export, local-data removal, disconnect choices, preserved-store recovery. | Remaining end-to-end platform recovery cases are listed individually in the map. |
| M11 | 64 core + 4 platform tests pass; release benchmark measured; universal local archive and signature verified; real screenshots; setup/privacy/release docs and full acceptance map. | UI runner blocked under retained permissions; live Google, complete accessibility/platform acceptance, minimum OS/Intel execution, Developer ID/notarization/clean-profile installation remain. |

M12 is not selected. Busy mirroring, split-series edits, push relays, other providers, updater and billing are not enabled.

See [verification.md](verification.md) for exact commands, measurements and manual records; [setup.md](setup.md) for OAuth prerequisites; [release.md](release.md) for the local archive and distribution boundary. Logs under `.build/evidence` are local development evidence and are ignored by git. Checked-in screenshots use only fictional data.
