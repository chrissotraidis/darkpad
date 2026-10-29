#!/usr/bin/env bash
# make-angle-xcframeworks.sh — fold the per-slice ANGLE frameworks into
# xcframeworks so Xcode picks device vs simulator itself. A plain .framework
# path cannot do that, and a build-setting variable inside the path is not
# resolved by the embed/copy phase (dhewm3-ios earned this one).
#
# Source frameworks come from the project-local pinned ANGLE build.
# Xcode copies the slices into work/angle-xcframeworks (ignored).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# iOS is the required product. Preserve optional visionOS support without
# requiring unrelated platform builds for an iPhone/iPad checkout.
SLICES="ios-device ios-simulator"
case "${1:-}" in
  --simulator-only) SLICES="ios-simulator" ;;
  --device-only) SLICES="ios-device" ;;
  --catalyst-only) SLICES="ios-catalyst" ;;
  --visionos) SLICES="$SLICES visionos-device visionos-simulator" ;;
  "") ;;
  *) echo "usage: $0 [--visionos|--simulator-only|--device-only|--catalyst-only]" >&2; exit 2 ;;
esac
# Keep a locally built Mac slice available when regenerating the normal iOS
# frameworks. A fresh iPhone checkout never has to build it.
if [ "${1:-}" != --catalyst-only ] && [ -d work/angle-ios-catalyst/libEGL.framework ]; then
  SLICES="$SLICES ios-catalyst"
fi

for s in $SLICES; do
  for lib in libEGL libGLESv2; do
    test -d "work/angle-$s/$lib.framework" || {
      echo "FATAL: work/angle-$s/$lib.framework missing." >&2
      echo "       Build iOS slices with scripts/build-angle-ios.sh device and simulator." >&2
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
