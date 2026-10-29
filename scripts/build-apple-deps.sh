#!/usr/bin/env bash
# Self-contained pinned SDL2 + curl; shared source cache, separate SDK builds.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/dependencies/pins.env"
cd "$ROOT"
SDK="${1:-iphonesimulator}"
SYSROOT="$SDK"
case "$SDK" in
 iphoneos|iphonesimulator) SYSTEM=iOS; MINOS=15.0 ;;
 macosx) SYSTEM=Darwin; MINOS=12.0 ;;
 maccatalyst) SYSTEM=iOS; SYSROOT=macosx; MINOS=15.0 ;;
 *) echo 'usage: build-apple-deps.sh [iphoneos|iphonesimulator|macosx|maccatalyst]' >&2; exit 1 ;;
esac
if [[ "$SDK" == maccatalyst ]]; then
 cmake -P "$ROOT/scripts/check-catalyst-cmake.cmake"
fi
mkdir -p work/dependencies work/downloads
SRC="$ROOT/work/dependencies/SDL"
if [[ ! -d "$SRC/.git" ]]; then
 git clone --depth 1 --branch release-2.32.8 https://github.com/libsdl-org/SDL.git "$SRC"
fi
[[ "$(git -C "$SRC" rev-parse HEAD)" == "$SDL_COMMIT" ]] || { echo 'SDL pin mismatch' >&2; exit 1; }
[[ -z "$(git -C "$SRC" status --porcelain)" ]] || { echo 'SDL source has local changes' >&2; exit 1; }
COMMON=(-G Ninja -DCMAKE_SYSTEM_NAME="$SYSTEM" -DCMAKE_OSX_SYSROOT="$SYSROOT"
 -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$MINOS" -DCMAKE_BUILD_TYPE=Release)
SDL_OPTIONS=(-DSDL_STATIC=ON -DSDL_SHARED=OFF -DSDL_TEST=OFF -DSDL_TESTS=OFF)
if [[ "$SDK" == maccatalyst ]]; then
 # CMake's iOS + macOS SDK combination emits the Mac Catalyst target triple.
 # UIKit and its companion frameworks live in the SDK's iOSSupport directory.
 SUPPORT="$(xcrun --sdk macosx --show-sdk-path)/System/iOSSupport"
 CATALYST_FLAGS="-isystem $SUPPORT/usr/include -iframework $SUPPORT/System/Library/Frameworks"
 COMMON+=(-DCMAKE_C_FLAGS="$CATALYST_FLAGS" -DCMAKE_CXX_FLAGS="$CATALYST_FLAGS"
  -DCMAKE_OBJC_FLAGS="$CATALYST_FLAGS" -DCMAKE_OBJCXX_FLAGS="$CATALYST_FLAGS"
  -DCMAKE_EXE_LINKER_FLAGS="-F$SUPPORT/System/Library/Frameworks -L$SUPPORT/usr/lib")
 # ANGLE owns GLES on Catalyst. SDL supplies the UIKit CAMetalLayer and input.
 SDL_OPTIONS+=(-DSDL_OPENGL=OFF -DSDL_OPENGLES=OFF -DSDL_HIDAPI=OFF)
fi
cmake -S "$SRC" -B "work/dependencies/sdl-$SDK" "${COMMON[@]}" \
 "${SDL_OPTIONS[@]}" \
 -DCMAKE_INSTALL_PREFIX="$ROOT/work/deps-$SDK"
cmake --build "work/dependencies/sdl-$SDK" -j "${PD_BUILD_JOBS:-6}"
cmake --install "work/dependencies/sdl-$SDK"
ARCHIVE="$ROOT/work/downloads/curl-$CURL_VERSION.tar.gz"
if [[ ! -f "$ARCHIVE" ]]; then
 curl -fL --retry 3 "https://curl.se/download/curl-$CURL_VERSION.tar.gz" -o "$ARCHIVE.part"
 mv "$ARCHIVE.part" "$ARCHIVE"
fi
[[ "$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')" == "$CURL_SHA256" ]] || { echo 'curl checksum mismatch' >&2; exit 1; }
SRC="$ROOT/work/dependencies/curl-$CURL_VERSION"
[[ -d "$SRC" ]] || tar -xf "$ARCHIVE" -C work/dependencies
cmake -S "$SRC" -B "work/dependencies/curl-$SDK" "${COMMON[@]}" \
 -DCMAKE_INSTALL_PREFIX="$ROOT/work/curl-$SDK" \
 -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DBUILD_CURL_EXE=OFF -DBUILD_TESTING=OFF \
 -DUSE_NGHTTP2=OFF -DUSE_NGTCP2=OFF -DUSE_QUICHE=OFF \
 -DHTTP_ONLY=ON -DCURL_USE_SECTRANSP=ON -DCURL_USE_OPENSSL=OFF -DCURL_USE_MBEDTLS=OFF \
 -DCURL_USE_LIBPSL=OFF -DCURL_USE_LIBSSH2=OFF -DUSE_LIBIDN2=OFF \
 -DCURL_ZLIB=OFF -DCURL_BROTLI=OFF -DCURL_ZSTD=OFF -DENABLE_UNIX_SOCKETS=OFF
cmake --build "work/dependencies/curl-$SDK" -j "${PD_BUILD_JOBS:-6}"
cmake --install "work/dependencies/curl-$SDK"
mkdir -p "work/licenses/$SDK"
cp work/dependencies/SDL/LICENSE.txt "work/licenses/$SDK/SDL.txt"
cp "$SRC/COPYING" "work/licenses/$SDK/curl.txt"
python3 scripts/check-apple-platform.py "$SDK" "work/deps-$SDK/lib/libSDL2.a" "work/curl-$SDK/lib/libcurl.a"
echo "Dependencies installed for $SDK; see work/dependencies for build caches."
