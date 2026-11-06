# Release preparation

Current builds are local development builds. The Debug app was exercised on arm64. A universal Release archive was built successfully at `.build/archives/Dayfold-local.xcarchive`; its executable contains arm64 and x86_64. Strict signature validation passes. The Release signature is ad hoc with the hardened-runtime flag, no team identity, and no get-task-allow entitlement. Sandbox, incoming/outgoing network, and user-selected read/write entitlements are present. This does not establish Developer ID signing, notarization, Gatekeeper acceptance, or Intel execution.

`./script/archive.sh --local` reproduces the ad hoc archive for local validation. Distribution mode (`./script/archive.sh`) requires `DAYFOLD_DEVELOPMENT_TEAM` and `DAYFOLD_SIGN_IDENTITY`. No Developer ID identity was found on this host. Supply the owner's real configuration, then review the resulting `dist/Dayfold.xcarchive`. The script does not submit, publish, purchase, or upload anything.

Before public distribution, verify dependency notices, supported OS/architectures, sandboxed loopback authorization, Keychain continuity, login launch, notifications, selected-file exports, production Google consent, migrations including pending operations, privacy/help text, and a real support contact.

Export a correctly signed Developer ID app from the archive. Validate each executable/framework and hardened runtime; do not repair an invalid package with recursive force-signing. With separate owner authorization and actual notarization credentials, use current `notarytool`, inspect the result, then staple and validate the ticket. Test a quarantined downloaded artifact on a clean user profile.

```sh
codesign --verify --deep --strict --verbose=2 dist/Dayfold.app
codesign -dvvv --entitlements :- dist/Dayfold.app
spctl -a -vv -t execute dist/Dayfold.app
xcrun stapler validate dist/Dayfold.app
```

These are validation commands, not evidence that signing/notarization happened.

Schema migrations are forward-only. The app refuses a user_version newer than it understands. Before an upgrade, export pending changes and keep a consistent backup of the app container, including SQLite WAL when applicable. Do not roll an older binary back over a newer incompatible database. Restore a compatible backup or use the newer version to export recoverable intent. An application update must never silently clear the outbox or recreate Google events from an export.
