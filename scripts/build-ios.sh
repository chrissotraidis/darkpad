#!/usr/bin/env bash
# build-ios.sh [device|simulator|visionos|xrsimulator] [-- extra cmake args] —
# cross-build the engine as libpd.a for iOS and visionOS.
#
# CMake owns the engine build; Xcode owns the bundle (D-009). Output:
#   build/ios-device/libpd.a      arm64, iphoneos,        minos 15.0
#   build/ios-simulator/libpd.a   arm64, iphonesimulator, minos 15.0
#   build/visionos/libpd.a        arm64, xros,            minos 26.0
#   build/xrsimulator/libpd.a     arm64, xrsimulator,     minos 26.0
#
# visionOS is the SAME source tree and the SAME overlay (charter Phase 5,
# GoldenEye D-024): CMAKE_SYSTEM_NAME=visionOS lights up the same PD_IOS branch
# patch 0008 added, and platform.h defines PLATFORM_IOS *and* PLATFORM_VISIONOS
# because TARGET_OS_IPHONE is 1 on xrOS. The deployment target is 26.0, not
# 15.0: the ANGLE xrOS slices are built minos 26.0 (Chromium links
# libclang_rt.xros.a), verified with vtool, so nothing here can target lower.
#
# Inputs, all by symlink from siblings (work/deps-PROVENANCE.md):
#   work/angle-ios-{device,simulator}      ANGLE 2.1.1 Metal-only framework slices
#   work/angle-visionos-{device,simulator}  ditto, xrOS
#   work/angle-include                     ANGLE's EGL/GLES headers
#   work/deps-{iphoneos,iphonesimulator}    static SDL2 2.32.8 + headers
#   work/deps-{xros,xrsimulator}            ditto, built by
#                                          scripts/build-sdl2-visionos.sh
#   work/curl-{iphoneos,iphonesimulator,xros,xrsimulator}
#                                          static libcurl 8.11.0, SecureTransport
#                                          (work/curl-PROVENANCE.md)
# zlib comes from the SDK. libcurl is still never *searched* for - a cross build
# picks up Homebrew's macOS dylib if allowed to look (the M1 trap) - but it is
# no longer absent: patch 0040 takes it from PD_CURL_DIR, which is the slice's
# own prefix below, and that is what lights up PD_HAVE_CURL and brings back
# Community Packs and Ghost Trials online (D-010).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

KIND="${1:-simulator}"
shift || true
[ "${1:-}" = "--" ] && shift || true

case "$KIND" in
  device)      SYS=iOS;       SYSROOT=iphoneos;        MINOS=15.0; DEPS=work/deps-iphoneos;        ANGLE=work/angle-ios-device;         BUILD=build/ios-device ;;
  simulator)   SYS=iOS;       SYSROOT=iphonesimulator; MINOS=15.0; DEPS=work/deps-iphonesimulator; ANGLE=work/angle-ios-simulator;      BUILD=build/ios-simulator ;;
  visionos)    SYS=visionOS;  SYSROOT=xros;            MINOS=26.0; DEPS=work/deps-xros;            ANGLE=work/angle-visionos-device;    BUILD=build/visionos ;;
  xrsimulator) SYS=visionOS;  SYSROOT=xrsimulator;     MINOS=26.0; DEPS=work/deps-xrsimulator;     ANGLE=work/angle-visionos-simulator; BUILD=build/xrsimulator ;;
  *) echo "usage: $0 [device|simulator|visionos|xrsimulator]" >&2; exit 1 ;;
esac

# Another session mid-build will fight us for cores and for DerivedData.
# `|| true` on the second pgrep is load-bearing: the process it matched a
# moment ago can be gone by the time it runs again, and a non-zero exit as the
# LAST command of an if-block aborts the whole script under `set -e`. That is
# how a publish dry-run reported "visionOS engine build failed" with nothing in
# the log but the warning itself.
if pgrep -fl 'Developer/usr/bin/xcodebuild|cmake --build|ninja -C' >/dev/null 2>&1; then
  echo "WARNING: another build is running:" >&2
  pgrep -fl 'Developer/usr/bin/xcodebuild|cmake --build|ninja -C' >&2 || true
fi

test -f "$DEPS/lib/libSDL2.a"            || { echo "FATAL: no $DEPS/lib/libSDL2.a (see work/deps-PROVENANCE.md; visionOS: scripts/build-sdl2-visionos.sh)" >&2; exit 1; }
test -d "$ANGLE/libEGL.framework"        || { echo "FATAL: no $ANGLE/libEGL.framework" >&2; exit 1; }
test -f work/angle-include/EGL/egl.h     || { echo "FATAL: no ANGLE headers at work/angle-include" >&2; exit 1; }
test -d build/src                        || { echo "FATAL: no overlay tree — run scripts/apply-overlay.sh" >&2; exit 1; }

# The curl slice is named after the SDK, which is why there is no case row for
# it: work/curl-iphoneos, -iphonesimulator, -xros, -xrsimulator.
CURL="work/curl-$SYSROOT"
test -f "$CURL/lib/libcurl.a"            || { echo "FATAL: no $CURL/lib/libcurl.a (see work/curl-PROVENANCE.md)" >&2; exit 1; }
test -f "$CURL/include/curl/curl.h"      || { echo "FATAL: no $CURL/include/curl/curl.h (see work/curl-PROVENANCE.md)" >&2; exit 1; }

# D-005: the three parity flags, on every build including iOS. The include path
# is the deps prefix rather than Homebrew's because the tree mixes <SDL.h> and
# <SDL2/SDL.h> and needs both the prefix and its SDL2/ subdir on the path.
PARITY="-ffp-contract=off -fno-builtin-sinf -fno-builtin-cosf -I$ROOT/$DEPS/include -I$ROOT/$DEPS/include/SDL2"

cmake -S build/src -B "$BUILD" -G Ninja \
  -DCMAKE_SYSTEM_NAME="$SYS" \
  -DCMAKE_OSX_SYSROOT="$SYSROOT" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MINOS" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DPD_STATIC_LIB=ON \
  -DPD_GL_ANGLE=ON \
  -DPD_VULKAN=OFF \
  -DPD_ANGLE_DIR="$ROOT/$ANGLE" \
  -DPD_ANGLE_INCLUDE_DIR="$ROOT/work/angle-include" \
  -DPD_ANGLE_GLUE="$ROOT/app/gfx/gfx_angle_egl.mm" \
  -DPD_IOS_PROF_SRC="$ROOT/app/gfx/pd_frame_prof.c" \
  -DPD_CURL_DIR="$ROOT/$CURL" \
  -DSDL2_INCLUDE_DIR="$ROOT/$DEPS/include/SDL2" \
  -DSDL2_LIBRARY_TEMP="$ROOT/$DEPS/lib/libSDL2.a" \
  -DSDL2MAIN_LIBRARY="$ROOT/$DEPS/lib/libSDL2main.a" \
  -DCMAKE_C_FLAGS="$PARITY" \
  -DCMAKE_CXX_FLAGS="$PARITY" \
  -DCMAKE_OBJCXX_FLAGS="$PARITY" \
  "$@"

cmake --build "$BUILD" -j10

LIB="$BUILD/libpd.a"
test -f "$LIB" || { echo "FATAL: no $LIB" >&2; exit 1; }

# Assert the Mach-O platform rather than trusting the SDK flags: lipo reports
# only arm64 and would happily pass an iOS library built into a visionOS app.
# 1=MACOS 2=IOS 7=IOSSIMULATOR 11=XROS 12=XROSSIMULATOR.
# (No `exit` in the awk: under `set -o pipefail` an early-exiting awk SIGPIPEs
# otool and the substitution comes back non-zero.)
case "$KIND" in
  device) WANT=2 ;; simulator) WANT=7 ;; visionos) WANT=11 ;; xrsimulator) WANT=12 ;;
esac
GOT=$(otool -l "$LIB" 2>/dev/null | awk '/LC_BUILD_VERSION/{f=1} f&&/ platform /&&!p{print $2;p=1}')
[ "$GOT" = "$WANT" ] || { echo "FATAL: $LIB reports platform=$GOT, expected $WANT ($KIND)" >&2; exit 1; }

lipo -info "$LIB"
echo "engine OK -> $LIB (platform $GOT, minos $MINOS)"
