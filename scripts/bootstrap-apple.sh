#!/usr/bin/env bash
# Reproducible foundation, sequential heavy builds. Does not boot simulators.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
for tool in git cmake ninja xcodegen python3; do
 command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done
scripts/bootstrap.sh
scripts/apply-overlay.sh
for sdk in iphonesimulator iphoneos macosx; do scripts/build-apple-deps.sh "$sdk"; done
scripts/build-macos.sh
scripts/fetch-angle.sh
for kind in simulator device; do
 scripts/build-angle-ios.sh "$kind"
 scripts/build-ios.sh "$kind"
done
# Repackage both freshly built slices even if an earlier simulator-only run
# already created an XCFramework. gen-app-project only checks for existence.
scripts/make-angle-xcframeworks.sh
scripts/gen-app-project.sh
for sdk in iphonesimulator iphoneos; do
 xcodebuild -project app/perfectdark.xcodeproj -scheme perfectdark \
  -configuration Debug -sdk "$sdk" -derivedDataPath "build/dd-$sdk" \
  ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build
done
