#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
MODE="${1:-run}"
case "$MODE" in run|--build|--debug|--logs|--telemetry|--verify|--demo|--push|--push-build) ;; *) echo "Usage: $0 [--build|--debug|--logs|--telemetry|--verify|--demo|--push|--push-build]" >&2; exit 2;; esac
DERIVED_DATA=.build/xcode
SIGNING=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=)
if [ "$MODE" = --push ] || [ "$MODE" = --push-build ]; then
    : "${DAYFOLD_DEVELOPMENT_TEAM:?Set the Apple Developer team for the installed push profile}"
    : "${DAYFOLD_SIGN_IDENTITY:?Set the installed Apple signing identity}"
    : "${DAYFOLD_APNS_PROFILE:?Set the installed macOS provisioning profile name or UUID}"
    DAYFOLD_APNS_ENVIRONMENT="${DAYFOLD_APNS_ENVIRONMENT:-development}"
    case "$DAYFOLD_APNS_ENVIRONMENT" in development|production) ;; *) echo 'APNs environment must be development or production.' >&2; exit 2;; esac
    DERIVED_DATA=.build/push
    SIGNING=("CODE_SIGN_IDENTITY=$DAYFOLD_SIGN_IDENTITY" CODE_SIGN_STYLE=Manual
        "DEVELOPMENT_TEAM=$DAYFOLD_DEVELOPMENT_TEAM" "PROVISIONING_PROFILE_SPECIFIER=$DAYFOLD_APNS_PROFILE"
        "CODE_SIGN_ENTITLEMENTS=$TASK_ROOT/Config/DayfoldPush.entitlements" "DAYFOLD_APNS_ENVIRONMENT=$DAYFOLD_APNS_ENVIRONMENT")
fi
xcode-select -p >/dev/null || { echo "Install Xcode and select it with xcode-select." >&2; exit 1; }
mkdir -p .build/evidence dayfold/dayfold/Resources
if [ -f Config/OAuth.local.json ]; then
    cp Config/OAuth.local.json dayfold/dayfold/Resources/OAuth.json
else
    cp Config/OAuth.example.json dayfold/dayfold/Resources/OAuth.json
fi
APP="$TASK_ROOT/$DERIVED_DATA/Build/Products/Debug/Dayfold.app"
# Match the exact development binary only. Never terminate another installed copy.
if [ "$MODE" != --build ] && [ "$MODE" != --push-build ]; then
    /usr/bin/pkill -f "^$APP/Contents/MacOS/Dayfold($| )" 2>/dev/null || true
fi
xcodebuild -project dayfold/dayfold.xcodeproj -scheme Dayfold -configuration Debug \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED_DATA" \
    "${SIGNING[@]}" build >.build/evidence/build.log 2>&1 || {
    rg 'error:|BUILD FAILED|failed:' .build/evidence/build.log | head -n 35 || tail -n 25 .build/evidence/build.log; exit 1;
}
/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist"
codesign --verify --deep --strict "$APP"
if [ "$MODE" = --push ] || [ "$MODE" = --push-build ]; then
    python3 script/verify_push_signing.py "$APP" "$DAYFOLD_APNS_ENVIRONMENT"
fi
if [ "$MODE" = --build ] || [ "$MODE" = --push-build ]; then echo "Built $APP"; exit 0; fi
if [ "$MODE" = --demo ]; then /usr/bin/open "$APP" --args --demo; else /usr/bin/open "$APP"; fi
case "$MODE" in
    --verify) sleep 2; pgrep -f "^$APP/Contents/MacOS/Dayfold($| )"; ;;
    --debug) lldb -n Dayfold ;;
    --logs|--telemetry) /usr/bin/log stream --info --style compact --predicate 'subsystem == "mujhtech.dayfold"' ;;
esac
echo "Launched $APP"
