#!/usr/bin/env bash
# build-personal-ipa.sh OUTPUT.ipa — one command from a fresh checkout to an
# unsigned DarkPad IPA for the player's own device (PadMint's iOS recipe).
#
# Device slices only: pinned engine + overlay, SDL2/curl for iphoneos, ANGLE
# device frameworks, the engine library, then a PD_PUBLIC Release app (no test
# console) wrapped by scripts/package-ipa.sh. No ROM is read: the player picks
# it in the app. Caches live under the ignored vendor/, work/ and build/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="${1:?usage: build-personal-ipa.sh OUTPUT.ipa}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
export PD_BUILD_JOBS="${PD_BUILD_JOBS:-${CMAKE_BUILD_PARALLEL_LEVEL:-6}}"

for tool in git cmake ninja xcodegen xcodebuild python3; do
 command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done

step() { printf '\n== %s\n' "$*"; }
step "engine source";       scripts/bootstrap.sh
step "engine patches";      scripts/apply-overlay.sh
step "SDL2 and curl";       scripts/build-apple-deps.sh iphoneos
step "ANGLE (large first download)"; scripts/fetch-angle.sh
step "ANGLE device build";  scripts/build-angle-ios.sh device
step "engine";              scripts/build-ios.sh device
step "frameworks";          scripts/make-angle-xcframeworks.sh --device-only
step "app project";         PD_PUBLIC=1 scripts/gen-app-project.sh
step "app"
DD="$ROOT/build/dd-personal"
xcodebuild -project app/perfectdark.xcodeproj -scheme perfectdark \
 -configuration Release -sdk iphoneos -derivedDataPath "$DD" \
 ARCHS=arm64 CODE_SIGNING_ALLOWED=NO -jobs "$PD_BUILD_JOBS" build
step "package";             scripts/package-ipa.sh "$DD/Build/Products/Release-iphoneos/perfectdark.app" "$OUT"
