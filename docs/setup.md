# Setup

Verified development host: Apple M2 Pro, 16 GiB memory, macOS 27.2 (26B123), Xcode 27.1 (27A9275), Apple Swift 6.4 (swiftlang-6.4.0.34.1). Deployment target is macOS 14.0. The Debug app has run on arm64; the local Release archive contains arm64 and x86_64. Minimum-OS and Intel execution are unverified. The development scripts currently select the arm64 destination used on this host.

Open `dayfold/dayfold.xcodeproj`, shared scheme **Dayfold**, or use `./script/build_and_run.sh`. The app bundle is `.build/xcode/Build/Products/Debug/Dayfold.app`. Xcode's normal package services and network access are needed for initial resolution. Versions are exact in `Packages/CalendarCore/Package.swift`; both package and Xcode lockfiles are checked in.

Dependencies: GRDB 7.12.0 (MIT), AppAuth 3.0.0 (Apache 2.0), KeyboardShortcuts 3.1.0 (MIT). Notices are in this directory. No global project generator is required.

## Google Desktop OAuth

1. Create a Google Cloud project and enable Calendar API.
2. Configure the OAuth consent screen and add your disposable test accounts while in Testing mode. Workspace policy may still block the grant.
3. Create an OAuth client of type **Desktop app**.
4. Copy `Config/OAuth.example.json` to `Config/OAuth.local.json` and supply `clientID`, plus the Desktop client's `clientSecret` if Google supplied it. This public-client configuration is not a server credential. Never insert access or refresh tokens.
5. Rebuild. Connect Google Account opens the system browser. The user controls account selection and consent. AppAuth uses PKCE and an ephemeral loopback listener, with a three-minute timeout.
6. Choose calendars and a writable default. Add other accounts separately. Reconnecting the same stable Google subject preserves local identity.

The run script copies the ignored override into the bundle. Both the override and generated resource are ignored by git. An empty configuration leaves Demo available and presents a setup explanation when Connect is selected.

Requested scopes: `openid`, `email`, `calendar.events`, `calendar.calendarlist.readonly`, `calendar.settings.readonly`, `calendar.events.freebusy` under Google's documented namespace. Production consent/verification and scope behavior must be verified with the owner's Google project. Testing-mode refresh tokens can expire; reconnection is not evidence of a retry bug.

Use disposable calendars for live tests. Invitations require owner-approved test recipients. Do not use real meetings to demonstrate development progress.

## Commands

```sh
./script/build_and_run.sh --build
./script/build_and_run.sh --demo
./script/build_and_run.sh --verify
./script/test.sh
./script/test.sh --ui
./script/archive.sh --local
DAYFOLD_PERFORMANCE=1 swift test --package-path Packages/CalendarCore --scratch-path .build/perf --cache-path .build/xcode/SourcePackages --configuration release --filter largeReferencePerformance
```

Build/test logs are stored under `.build/evidence`. The Run button is wired to the project-local run script. Script modes `--debug`, `--logs`, and `--telemetry` are available. It stops only the exact development bundle binary before rebuilding and launching through Launch Services.

UI tests require macOS UI automation permissions. The current host's runner timed out during initialization; the owner chose to leave Developer Mode disabled. Do not count these tests as passed or change permissions automatically. Use the manual evidence in [verification.md](verification.md).

The Google flow follows [desktop OAuth](https://developers.google.com/identity/protocols/oauth2/native-app). Calendar request constraints were checked against the current [events.list](https://developers.google.com/workspace/calendar/api/v3/reference/events/list), [events.patch](https://developers.google.com/workspace/calendar/api/v3/reference/events/patch), and [events.delete](https://developers.google.com/workspace/calendar/api/v3/reference/events/delete) contracts during implementation. This documentation review is distinct from live provider verification.
