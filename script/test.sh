#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/evidence
swift test --package-path Packages/CalendarCore --scratch-path .build/core --cache-path .build/xcode/SourcePackages 2>&1 | tee .build/evidence/core-tests.log
if [ "${1:-}" = --ui ]; then
    xcodebuild -project dayfold/dayfold.xcodeproj -scheme Dayfold -configuration Debug \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode \
        CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= test
fi
