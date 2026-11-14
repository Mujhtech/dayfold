#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-distribution}"
if [ "$MODE" != --local ] && [ "$MODE" != distribution ]; then
    echo 'Usage: script/archive.sh [--local]' >&2
    exit 2
fi
if [ "$MODE" != --local ] && { [ -z "${DAYFOLD_DEVELOPMENT_TEAM:-}" ] || [ -z "${DAYFOLD_SIGN_IDENTITY:-}" ] || [ -z "${DAYFOLD_PROVISIONING_PROFILE:-}" ]; }; then
    echo 'Set DAYFOLD_DEVELOPMENT_TEAM, DAYFOLD_SIGN_IDENTITY and DAYFOLD_PROVISIONING_PROFILE to the installed macOS identity/profile for private Keychain access. This script does not publish or notarize.' >&2
    exit 2
fi
mkdir -p .build/evidence dayfold/dayfold/Resources
if [ -f Config/OAuth.local.json ]; then
    cp Config/OAuth.local.json dayfold/dayfold/Resources/OAuth.json
else
    cp Config/OAuth.example.json dayfold/dayfold/Resources/OAuth.json
fi
if [ "$MODE" = --local ]; then
    ARCHIVE_PATH=.build/archives/Dayfold-local.xcarchive
    ARCHIVE_TEAM=""
    ARCHIVE_IDENTITY=-
    ARCHIVE_PROFILE=(PROVISIONING_PROFILE_SPECIFIER=)
else
    ARCHIVE_PATH=dist/Dayfold.xcarchive
    ARCHIVE_TEAM="$DAYFOLD_DEVELOPMENT_TEAM"
    ARCHIVE_IDENTITY="$DAYFOLD_SIGN_IDENTITY"
    ARCHIVE_PROFILE=("PROVISIONING_PROFILE_SPECIFIER=$DAYFOLD_PROVISIONING_PROFILE")
fi
xcodebuild -project dayfold/dayfold.xcodeproj -scheme Dayfold -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath .build/xcode \
    -archivePath "$ARCHIVE_PATH" DEVELOPMENT_TEAM="$ARCHIVE_TEAM" \
    CODE_SIGN_IDENTITY="$ARCHIVE_IDENTITY" CODE_SIGN_STYLE=Manual "${ARCHIVE_PROFILE[@]}" ONLY_ACTIVE_ARCH=NO archive > .build/evidence/archive.log 2>&1 || {
    rg 'error:|ARCHIVE FAILED|failed:' .build/evidence/archive.log | head -n 35
    exit 1
}
codesign --verify --deep --strict "$ARCHIVE_PATH/Products/Applications/Dayfold.app"
if [ "$MODE" != --local ]; then python3 script/verify_push_signing.py "$ARCHIVE_PATH/Products/Applications/Dayfold.app"; fi
echo "Archived $ARCHIVE_PATH"
if [ "$MODE" = --local ]; then echo 'Ad hoc local validation only; this archive is not notarized or approved for distribution.'; fi
