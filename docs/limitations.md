# Limits and verification gaps

This file distinguishes intended product boundaries from unfinished verification. Consult implementation-status.md for current evidence.

## Intentional Core boundaries

- Google is the only calendar provider. No ACL/calendar administration, tasks, arbitrary ICS import, built-in billing, or updater. The optional OpenAI assistant and notification relay have the separate limits below.
- Offline recurring display covers downloaded windows. Structural series changes require online review. Unrepresentable imported recurrence rules are preserved; structural edits use Google.
- This and following, busy mirroring, cross-calendar moves, and other unselected M12 extensions are not enabled. The optional push relay has native integration; real Google/APNs delivery still requires the configuration and live verification described in [relay setup](relay.md). Cross-account duplication creates a new personal draft without guests or conference credentials.
- Specialized Google event types are displayed conservatively with a Google fallback.
- Polling and reminder reconciliation require the process to run. Sleep, quit, offline state, Focus, and OS notification policy limit freshness/delivery.
- Demo uses a local fake provider. New repeating demo events expose their first slot only; it does not emulate Google's recurrence engine or generate real Meet URLs.

## Optional assistant

- Calendar mode remains the default and the full manual calendar remains available in Assistant mode. The current assistant uses OpenAI with a user-supplied API key; it requires network access, compatible model access and available API quota. There is no on-device fallback or included model subscription.
- The assistant can read a downloaded day, calculate free-time windows and propose one new personal timed event for review. It cannot directly save, move or delete events, invite people, respond to invitations, create recurrence, or run unattended background plans. Review opens a normal local draft; the user must save in the editor before a mutation is queued.
- Read tools cover seven days back through 31 days ahead. Proposals cover today through the next 31 days, with durations from 15 to 240 minutes. Ambiguous or nonexistent local times are rejected. Missing details need clarification rather than guessed defaults.
- Planning includes all synchronized calendars, even those hidden in the UI. Calendars with sync turned off are excluded. Tools read the local cache and do not fetch missing dates themselves. Missing/stale coverage, invalid event times or truncated context prevents a reliable free-time result. Schedule answers have bounded event excerpts and disclose omissions; they are not a complete calendar export.
- AI answers can be wrong. Calendar context is minimized but relevant event titles and times leave the Mac when tools are used. See [Privacy](privacy.md). Sending requests in Demo can still incur OpenAI usage and transmit user-entered text.

## Still requiring evidence

- Live authorization, partial grants, two independent real accounts, Workspace policies, invitations/recurring RSVP, Meet generation, and conditional Google writes: owner OAuth configuration and user-authorized disposable test calendars are unavailable.
- macOS automated UI tests compile, but runner initialization timed out with Developer Mode disabled. Tests have not passed merely because their target builds.
- Notification delivery/actions, login-launch behavior, VoiceOver, hotkey collision behavior, actual external-display removal, high contrast/RTL interaction, minimum macOS 14 execution, and Intel execution need explicit platform records. Frame-placement logic has a passing deterministic test; light/dark app appearance was inspected manually.
- Developer ID signing, notarization, Gatekeeper on a quarantined download, and production OAuth verification require the owner's actual configuration.
- Live OpenAI authentication, model responses, billed usage and production provider errors remain unverified because no user API key was configured. Deterministic transport/tool/credential tests do not establish live model behavior or answer quality.

The [acceptance map](acceptance.md) distinguishes passing deterministic evidence, observed manual behavior, partial coverage, and missing live/platform evidence for every case. No claim of full Core acceptance or beta readiness is made. English is the only application localization; date and time formatting uses the user's locale and selected display zone. Search covers locally downloaded events, with its scope stated in the interface.

Dayfold account authentication uses OIDC/DPoP with separate per-device sessions. No real identity-provider client registration or signed-device acceptance was supplied for this work. Public APNs registration is deliberately unavailable until push destination possession is verified; local reminders and live calendar hints remain available. See [authentication](authentication.md).
