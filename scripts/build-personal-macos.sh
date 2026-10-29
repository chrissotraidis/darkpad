#!/usr/bin/env bash
# Build the shared DarkPad app for Apple Silicon Macs. No ROM is read or bundled.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="${1:?usage: build-personal-macos.sh OUTPUT.zip}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
export PD_BUILD_JOBS="${PD_BUILD_JOBS:-${CMAKE_BUILD_PARALLEL_LEVEL:-6}}"
for tool in git cmake ninja xcodegen xcodebuild python3; do
 command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done
cmake -P "$ROOT/scripts/check-catalyst-cmake.cmake"

scripts/bootstrap.sh
scripts/apply-overlay.sh
scripts/build-apple-deps.sh maccatalyst
scripts/fetch-angle.sh
scripts/build-angle-ios.sh catalyst
scripts/build-ios.sh catalyst
scripts/make-angle-xcframeworks.sh --catalyst-only
PD_PUBLIC=1 scripts/gen-app-project.sh
DD="$ROOT/build/dd-macos"
xcodebuild -project app/perfectdark.xcodeproj -scheme perfectdark \
 -configuration Release -destination 'generic/platform=macOS,variant=Mac Catalyst' \
 -derivedDataPath "$DD" ARCHS=arm64 CODE_SIGNING_ALLOWED=NO \
 -jobs "$PD_BUILD_JOBS" build
scripts/package-macos.sh "$DD/Build/Products/Release-maccatalyst/DarkPad.app" "$OUT"
