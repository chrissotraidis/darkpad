#!/usr/bin/env bash
# build-sdl2-visionos.sh [xros|xrsimulator] — static SDL2 2.32.8 for visionOS.
#
# Why this exists at all: nothing on this machine had an SDL2 slice for xrOS.
# dhewm3-ios' work/deps-xros is SDL3 (that port moved to SDL3), and
# sm64coopdx-ios' xros libSDL2.a is 2.32.10 built inside its own CMake tree with
# a supersampling patch of its own. We need 2.32.8 — the exact version the iOS
# slices use (work/deps-PROVENANCE.md) — so the visionOS build is the same app
# with the same SDL, per the charter's "one source tree, every difference behind
# TARGET_OS_VISION".
#
# SDL 2.32 predates visionOS and its UIKit backend does not compile for xros at
# all; overlay/sdl2/visionos-compat.patch is the minimal compat set (see its
# header for provenance and for the two sm64coopdx hunks deliberately dropped).
#
# SDL_OPENGLES/SDL_OPENGL are OFF: GLES does not exist on visionOS (every GL
# entry point in the xrOS SDK is unavailable). The engine's context comes from
# ANGLE-Metal on the window's CAMetalLayer (D-008, app/gfx/gfx_angle_egl.mm), so
# all SDL has to provide is SDL_Metal_CreateView, which is in the Metal backend.
#
# SDL_HIDAPI is OFF for a subtler reason. __IPHONEOS__ is defined on xrOS, so
# SDL_hidapi.c takes its iOS branch and declares HAVE_PLATFORM_BACKEND — but the
# implementation of that backend is src/hidapi/ios/hid.m, and SDL's CMake only
# adds that .m file on the IOS/TVOS platform branch. The library therefore links
# with twenty undefined _PLATFORM_hid_* symbols. Raw HID is not wanted here
# anyway: every pad on visionOS arrives through GameController/MFi, which is a
# different SDL backend entirely and stays on.
#
# Deployment target 26.0, not 2.0: the ANGLE xrOS slices are built minos 26.0
# (Chromium's libclang_rt.xros.a), so nothing in this app can target lower.
#
# Output: work/deps-{xros,xrsimulator}/{lib/libSDL2.a,include/SDL2/*.h}
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

KIND="${1:-xrsimulator}"
case "$KIND" in
  xros)        SYSROOT=xros ;;
  xrsimulator) SYSROOT=xrsimulator ;;
  *) echo "usage: $0 [xros|xrsimulator]" >&2; exit 1 ;;
esac

SDL_TAG=release-2.32.8
SRC=work/sdl2-visionos/src
PREFIX="$ROOT/work/deps-$KIND"
BUILD="work/sdl2-visionos/build-$KIND"

if [ ! -d "$SRC/.git" ]; then
  mkdir -p work/sdl2-visionos
  git clone --depth 1 --branch "$SDL_TAG" https://github.com/libsdl-org/SDL.git "$SRC"
fi
git -C "$SRC" describe --tags | grep -q "$SDL_TAG" || { echo "FATAL: SDL tag mismatch in $SRC" >&2; exit 1; }

# Re-apply the compat patch onto a clean tree every time: the patch is the only
# local change, and a half-applied tree is worse than a slow one.
git -C "$SRC" checkout -q --force "$SDL_TAG"
git -C "$SRC" clean -qfd
patch -d "$SRC" -p1 --fuzz=0 --no-backup-if-mismatch < overlay/sdl2/visionos-compat.patch

cmake -S "$SRC" -B "$BUILD" -G Ninja \
  -DCMAKE_SYSTEM_NAME=visionOS \
  -DCMAKE_OSX_SYSROOT="$SYSROOT" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
  -DCMAKE_BUILD_TYPE=Release \
  -DSDL_STATIC=ON -DSDL_SHARED=OFF -DSDL_TEST=OFF \
  -DSDL_OPENGLES=OFF -DSDL_OPENGL=OFF \
  -DSDL_HIDAPI=OFF \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" > "$BUILD.cfg.log" 2>&1
cmake --build "$BUILD" -j10 > "$BUILD.build.log" 2>&1
cmake --install "$BUILD" >> "$BUILD.build.log" 2>&1

test -f "$PREFIX/lib/libSDL2.a" || { echo "FATAL: no $PREFIX/lib/libSDL2.a (see $BUILD.build.log)" >&2; exit 1; }

# Assert the Mach-O platform rather than trusting the SDK flags: lipo reports
# only arm64 and would happily pass an iOS build (sm64coopdx M-11).
# 11 = XROS, 12 = XROS_SIMULATOR.
WANT=11; [ "$KIND" = "xrsimulator" ] && WANT=12
# No `exit` in the awk: under `set -o pipefail` an early-exiting awk SIGPIPEs
# otool and the whole command substitution comes back non-zero, which `set -e`
# then treats as a failed assert on a perfectly good library.
GOT=$(otool -l "$PREFIX/lib/libSDL2.a" 2>/dev/null | awk '/LC_BUILD_VERSION/{f=1} f&&/ platform /&&!p{print $2;p=1}')
[ "$GOT" = "$WANT" ] || { echo "FATAL: libSDL2.a reports platform=$GOT, expected $WANT ($KIND)" >&2; exit 1; }

lipo -info "$PREFIX/lib/libSDL2.a"
echo "SDL2 $KIND OK -> $PREFIX"
