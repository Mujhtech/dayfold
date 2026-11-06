# Dayfold

A native macOS calendar window and menu bar companion for multiple independent Google accounts. The implementation follows [NativeCalendar_Agent_Brief.md](NativeCalendar_Agent_Brief.md), using SwiftUI, a testable CalendarCore package, GRDB/SQLite, AppAuth, and Keychain.

```sh
./script/build_and_run.sh
```

Choose **Explore Demo**, or run `./script/build_and_run.sh --demo`. Demo events are fictional and use a separate database and local fake provider. They are never uploaded to Google.

This is a working development build. The M00–M11 implementation is present, with 64 passing core tests, 4 passing platform tests, a separately exercised large-data benchmark, and manual checks of the real app. Core is **not yet verified for beta**: live Google operations and several platform acceptance checks remain unverified. See [implementation status](docs/implementation-status.md) and the [complete acceptance map](docs/acceptance.md).

Implemented surfaces include day/week/month/agenda, account/calendar visibility, event details/editor, durable drafts and writes, invitations, conflict review, quick entry, local search, recovery export, settings, and the menu bar companion. Google authorization and REST synchronization are implemented; a Desktop OAuth client and user-authorized disposable calendars are required for live verification.

- [Setup](docs/setup.md)
- [Architecture](docs/architecture.md)
- [Limitations](docs/limitations.md)
- [Privacy](docs/privacy.md)
- [Release preparation](docs/release.md)
- [Engineering decisions](docs/decisions.md)
- [Verification, performance, and manual evidence](docs/verification.md)

Run deterministic checks with `./script/test.sh`. A universal ad hoc archive can be built with `./script/archive.sh --local`; it is not notarized. `./script/test.sh --ui` also attempts the macOS UI test target; the current host's Developer Mode is disabled and its UI automation runner has not initialized successfully. The owner chose to retain those permissions and continue manual checks.

## Real app screenshots

These captures contain fictional demo data only.

![Populated week view](docs/screenshots/week.png)

[Month](docs/screenshots/month.png) · [Agenda](docs/screenshots/agenda.png) · [Editor](docs/screenshots/editor.png) · [Quick entry](docs/screenshots/quick-entry.png) · [Account settings](docs/screenshots/accounts.png) · [Conflict review](docs/screenshots/conflict.png)
