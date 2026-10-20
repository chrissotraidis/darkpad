#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/dependencies/pins.env"
KIND="${1:-simulator}"
case "$KIND" in
 device) SDK=iphoneos ;;
 simulator) SDK=iphonesimulator ;;
 *) echo 'usage: build-angle-ios.sh [device|simulator]' >&2; exit 1 ;;
esac
BASE="$ROOT/work/angle-build"
ANGLE="$BASE/angle"
[[ -f "$ANGLE/build/config/BUILDCONFIG.gn" ]] || "$ROOT/scripts/fetch-angle.sh"
[[ "$(git -C "$ANGLE" rev-parse HEAD)" == "$ANGLE_COMMIT" ]] || exit 1
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
buildtools/mac/gn gen "$OUT"
"$NINJA" -C "$OUT" -j "${PD_BUILD_JOBS:-6}" libEGL libGLESv2
for lib in libEGL libGLESv2; do
 test -f "$OUT/$lib.framework/$lib"
 python3 "$ROOT/scripts/check-apple-platform.py" "$SDK" "$OUT/$lib.framework/$lib"
done
ln -sfn "angle-build/angle/$OUT" "$ROOT/work/angle-ios-$KIND"
ln -sfn angle-build/angle/include "$ROOT/work/angle-include"
