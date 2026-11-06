# Privacy

Dayfold connects directly from this Mac to Google's authorization, user-info, and Calendar endpoints. Core has no developer-operated backend, analytics, crash uploader, AI service, or billing integration.

Google authorization archives, including refresh tokens, are stored in Keychain under a client/account-specific service. SQLite contains account references and permitted calendar data, drafts, pending changes, conflict baselines, and search text. Cache data is protected by the application sandbox and the user's OS protections. It is not separately encrypted with SQLCipher or end-to-end encryption.

Production and demo data are stored separately in the application's Application Support container. Demo identities use example.com and fictional content. Local HTTP sessions use ephemeral configuration without a URL cache. Ordinary diagnostics contain versions, state categories, counts, and timings; they exclude tokens, descriptions, guest lists, and meeting secrets.

Descriptions render as plain sanitized text. They do not execute scripts or fetch tracking images. Meeting/attachment links open only after a user action and scheme validation. Multiple meeting destinations are presented as choices. Browser sign-in identity is independent of the calendar identity.

Recovery exports intentionally contain personal calendar drafts and pending intent. The export panel explains this; exports contain no OAuth credentials and are not automatically replayed. Disconnect can export before explicitly discarding account-local work, removes credentials/cache/search/reminders, and never deletes Google calendars. Uninstalling the application alone does not guarantee removal of its container or Keychain entries.

Reminders are optional. OS preview policy applies, with an optional stricter Busy event title. macOS can deliver already-scheduled reminders after the app quits; Dayfold cannot update those reminders while quit, asleep, or offline.
