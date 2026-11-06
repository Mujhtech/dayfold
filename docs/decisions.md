# Engineering decisions

- 2026-11-05: Reuse the existing `dayfold/dayfold.xcodeproj`, target `dayfold`, bundle ID `mujhtech.dayfold`. The product is named Dayfold; NativeCalendar remains the brief's working name. Original starter sources are preserved in commit a0e0c47.
- Use the existing Xcode synchronized source groups, a shared Dayfold scheme, and a local CalendarCore package. No global project generator is required.
- macOS deployment target is 14.0. Swift 6 language mode and explicit concurrency boundaries replace the starter's implicit MainActor isolation.
- Pin GRDB 7.12.0, AppAuth 3.0.0, KeyboardShortcuts 3.1.0. CalendarPlatform contains macOS adapters; deterministic logic remains in CalendarCore.
- Local debug builds use ad hoc signing. No distribution certificate is available; release signing/notarization will need owner configuration.
- 2026-11-06: Retain the owner's existing macOS developer permissions. Automated UI tests compiled but their runner did not initialize; manual app checks supplement deterministic tests without representing the UI suite as passed.
- Use Google expansion for recurrence windows. The demo supplies deterministic existing occurrences and does not attempt to implement an independent recurrence engine. New repeating demo events show the first slot only.
- Use local FTS search over downloaded data; the optional bounded online-search mode is not selected.
- Rate limits are conservative local budgets shared by reads/writes; account Retry-After and persisted backoff are separate from provider quota guarantees.
- A universal ad hoc Release archive supports packaging validation. Public distribution, notarization, and M12 extensions remain outside the enabled scope.
- Confirmed undo uses conditional compensating operations. A deleted event is restored through an explicit new personal draft to avoid silently resending invitations or reusing a cancelled identity.
