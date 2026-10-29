#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/dependencies/pins.env"
KIND="${1:-simulator}"
case "$KIND" in
 device) SDK=iphoneos ;;
 simulator) SDK=iphonesimulator ;;
 catalyst) SDK=maccatalyst ;;
 *) echo 'usage: build-angle-ios.sh [device|simulator|catalyst]' >&2; exit 1 ;;
esac
BASE="$ROOT/work/angle-build"
ANGLE="$BASE/angle"
[[ -f "$ANGLE/build/config/BUILDCONFIG.gn" ]] || "$ROOT/scripts/fetch-angle.sh"
[[ "$(git -C "$ANGLE" rev-parse HEAD)" == "$ANGLE_COMMIT" ]] || exit 1
PATCH="$ROOT/overlay/angle/maccatalyst-compat.patch"
# The shared pinned checkout may be pristine or carry exactly our Catalyst
# overlay. A temporary index compares source bytes without resetting local work.
CHECK_DIR="$(mktemp -d "$BASE/source-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
GIT_INDEX_FILE="$CHECK_DIR/index" git -C "$ANGLE" read-tree HEAD
if git -C "$ANGLE" apply --reverse --check "$PATCH" >/dev/null 2>&1; then
 GIT_INDEX_FILE="$CHECK_DIR/index" git -C "$ANGLE" apply --cached "$PATCH"
fi
if ! GIT_INDEX_FILE="$CHECK_DIR/index" git -C "$ANGLE" diff --quiet -- \
 || [[ -n "$(git -C "$ANGLE" ls-files --others --exclude-standard)" ]]; then
 echo 'ANGLE source differs from the pin and the supported Catalyst overlay.' >&2
 exit 1
fi
rm -rf "$CHECK_DIR"
trap - EXIT
if [[ "$KIND" == catalyst ]]; then
 if ! git -C "$ANGLE" apply --reverse --check "$PATCH" >/dev/null 2>&1; then
  git -C "$ANGLE" apply --check "$PATCH"
  git -C "$ANGLE" apply "$PATCH"
 fi
fi
NINJA="$(command -v ninja)"
PYTHON="${PD_PYTHON:-$(command -v python3.11 || command -v python3)}"
"$PYTHON" -c 'import sys; assert sys.version_info >= (3, 9), "ANGLE requires Python 3.9+"'
mkdir -p "$BASE/tools"
ln -sfn "$PYTHON" "$BASE/tools/python3"
export PATH="$BASE/tools:$BASE/depot_tools:$PATH"
export DEPOT_TOOLS_UPDATE=0
cd "$ANGLE"
OUT="out/ios-arm64-$KIND"
mkdir -p "$OUT"
cat > "$OUT/args.gn" <<ARGS
target_os = "ios"
target_cpu = "arm64"
target_environment = "$KIND"
ios_deployment_target = "15.0"
ios_enable_code_signing = false
is_debug = false
is_component_build = false
angle_enable_metal = true
angle_enable_gl = false
angle_enable_vulkan = false
angle_enable_d3d11 = false
angle_enable_null = false
angle_enable_swiftshader = false
angle_enable_essl = true
angle_enable_glsl = true
angle_assert_always_on = false
angle_build_tests = false
treat_warnings_as_errors = false
ARGS
# Xcode 27's iPhoneOS SDK stubs list arm64e.x1 targets that ANGLE's pinned lld
# cannot parse ("malformed file"). Apple's linker reads them; the simulator SDK
# does not use that target and keeps the pinned lld.
if [[ "$KIND" == device || "$KIND" == catalyst ]]; then
 echo 'use_lld = false' >> "$OUT/args.gn"
fi
if [[ "$KIND" == catalyst ]]; then
 # DarkPad uses ANGLE's Metal backend directly. The optional WebGPU/Dawn
 # backend probes iOS GPU feature sets that are unavailable on Mac Catalyst.
 echo 'angle_enable_wgpu = false' >> "$OUT/args.gn"
fi
buildtools/mac/gn gen "$OUT"
"$NINJA" -C "$OUT" -j "${PD_BUILD_JOBS:-6}" libEGL libGLESv2
for lib in libEGL libGLESv2; do
 test -f "$OUT/$lib.framework/$lib"
 python3 "$ROOT/scripts/check-apple-platform.py" "$SDK" "$OUT/$lib.framework/$lib"
done
ln -sfn "angle-build/angle/$OUT" "$ROOT/work/angle-ios-$KIND"
ln -sfn angle-build/angle/include "$ROOT/work/angle-include"
