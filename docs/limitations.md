# Limits and verification gaps

This file distinguishes intended product boundaries from unfinished verification. Consult implementation-status.md for current evidence.

## Intentional Core boundaries

- Google is the only provider. No ACL/calendar administration, tasks, arbitrary ICS import, AI, cloud backend, billing, or updater.
- Offline recurring display covers downloaded windows. Structural series changes require online review. Unrepresentable imported recurrence rules are preserved; structural edits use Google.
- This and following, busy mirroring, push relays, cross-calendar moves, and other M12 extensions are not enabled. Cross-account duplication creates a new personal draft without guests or conference credentials.
- Specialized Google event types are displayed conservatively with a Google fallback.
- Polling and reminder reconciliation require the process to run. Sleep, quit, offline state, Focus, and OS notification policy limit freshness/delivery.
- Demo uses a local fake provider. New repeating demo events expose their first slot only; it does not emulate Google's recurrence engine or generate real Meet URLs.

## Still requiring evidence

- Live authorization, partial grants, two independent real accounts, Workspace policies, invitations/recurring RSVP, Meet generation, and conditional Google writes: owner OAuth configuration and user-authorized disposable test calendars are unavailable.
- macOS automated UI tests compile, but runner initialization timed out with Developer Mode disabled. Tests have not passed merely because their target builds.
- Notification delivery/actions, login-launch behavior, VoiceOver, hotkey collision behavior, actual external-display removal, high contrast/RTL interaction, minimum macOS 14 execution, and Intel execution need explicit platform records. Frame-placement logic has a passing deterministic test; light/dark app appearance was inspected manually.
- Developer ID signing, notarization, Gatekeeper on a quarantined download, and production OAuth verification require the owner's actual configuration.

The [acceptance map](acceptance.md) distinguishes passing deterministic evidence, observed manual behavior, partial coverage, and missing live/platform evidence for every case. No claim of full Core acceptance or beta readiness is made. English is the only application localization; date and time formatting uses the user's locale and selected display zone. Search covers locally downloaded events, with its scope stated in the interface.
