#!/usr/bin/env bash
# Bundle a simulator-only development build without waiting for device ANGLE.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
scripts/build-ios.sh simulator
if [[ ! -d work/angle-ios-device/libEGL.framework ]]; then
 scripts/make-angle-xcframeworks.sh --simulator-only
else
 scripts/make-angle-xcframeworks.sh
fi
scripts/gen-app-project.sh
xcodebuild -project app/perfectdark.xcodeproj -scheme perfectdark \
 -configuration Debug -sdk iphonesimulator \
 -destination 'generic/platform=iOS Simulator' \
 -derivedDataPath build/dd-iphonesimulator ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build
