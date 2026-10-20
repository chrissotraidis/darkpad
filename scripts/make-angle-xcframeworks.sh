#!/usr/bin/env bash
# make-angle-xcframeworks.sh — fold the per-slice ANGLE frameworks into
# xcframeworks so Xcode picks device vs simulator itself. A plain .framework
# path cannot do that, and a build-setting variable inside the path is not
# resolved by the embed/copy phase (dhewm3-ios earned this one).
#
# Nothing is copied or rebuilt: work/angle-ios-{device,simulator} are symlinks
# into ~/dev/realrtcw-ios/work/angle (see work/deps-PROVENANCE.md). The
# xcframeworks themselves are small wrappers and live in work/, gitignored.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# All four slices in ONE pair of xcframeworks: iOS device/simulator and
# visionOS device/simulator. Xcode picks the slice by the SDK in use, so the
# iOS and visionOS app targets can both name the same framework path.
SLICES="ios-device ios-simulator visionos-device visionos-simulator"

for s in $SLICES; do
  for lib in libEGL libGLESv2; do
    test -d "work/angle-$s/$lib.framework" || {
      echo "FATAL: work/angle-$s/$lib.framework missing." >&2
      echo "       ln -sfn ~/dev/realrtcw-ios/work/angle/out/<platform>-arm64-<slice> work/angle-$s" >&2
      echo "       (ANGLE 2.1.1 e25e8d8565f7, Metal-only; rebuild with ~/dev/q2repro-ios/scripts/build-angle-ios.sh)" >&2
      exit 1; }
  done
done

OUT=work/angle-xcframeworks
rm -rf "$OUT"
mkdir -p "$OUT"
for lib in libEGL libGLESv2; do
  args=()
  for s in $SLICES; do
    args+=(-framework "$ROOT/work/angle-$s/$lib.framework")
  done
  xcodebuild -create-xcframework "${args[@]}" \
    -output "$OUT/$lib.xcframework" > /dev/null
  echo "built $OUT/$lib.xcframework"
done
