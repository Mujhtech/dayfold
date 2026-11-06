#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
MODE="${1:-run}"
case "$MODE" in run|--build|--debug|--logs|--telemetry|--verify|--demo) ;; *) echo "Usage: $0 [--build|--debug|--logs|--telemetry|--verify|--demo]" >&2; exit 2;; esac
xcode-select -p >/dev/null || { echo "Install Xcode and select it with xcode-select." >&2; exit 1; }
mkdir -p .build/evidence dayfold/dayfold/Resources
if [ -f Config/OAuth.local.json ]; then
    cp Config/OAuth.local.json dayfold/dayfold/Resources/OAuth.json
else
    cp Config/OAuth.example.json dayfold/dayfold/Resources/OAuth.json
fi
APP="$TASK_ROOT/.build/xcode/Build/Products/Debug/Dayfold.app"
# Match the exact development binary only. Never terminate another installed copy.
if [ "$MODE" != --build ]; then
    /usr/bin/pkill -f "^$APP/Contents/MacOS/Dayfold($| )" 2>/dev/null || true
fi
xcodebuild -project dayfold/dayfold.xcodeproj -scheme Dayfold -configuration Debug \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build >.build/evidence/build.log 2>&1 || {
    rg 'error:|BUILD FAILED|failed:' .build/evidence/build.log | head -n 35 || tail -n 25 .build/evidence/build.log; exit 1;
}
/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist"
codesign --verify --deep --strict "$APP"
if [ "$MODE" = --build ]; then echo "Built $APP"; exit 0; fi
if [ "$MODE" = --demo ]; then /usr/bin/open "$APP" --args --demo; else /usr/bin/open "$APP"; fi
case "$MODE" in
    --verify) sleep 2; pgrep -f "^$APP/Contents/MacOS/Dayfold($| )"; ;;
    --debug) lldb -n Dayfold ;;
    --logs|--telemetry) /usr/bin/log stream --info --style compact --predicate 'subsystem == "mujhtech.dayfold"' ;;
esac
echo "Launched $APP"
