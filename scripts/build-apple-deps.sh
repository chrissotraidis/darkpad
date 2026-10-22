#!/usr/bin/env bash
# Self-contained pinned SDL2 + curl; shared source cache, separate SDK builds.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/dependencies/pins.env"
cd "$ROOT"
SDK="${1:-iphonesimulator}"
case "$SDK" in
 iphoneos|iphonesimulator) SYSTEM=iOS; MINOS=15.0 ;;
 macosx) SYSTEM=Darwin; MINOS=12.0 ;;
 *) echo 'usage: build-apple-deps.sh [iphoneos|iphonesimulator|macosx]' >&2; exit 1 ;;
esac
mkdir -p work/dependencies work/downloads
SRC="$ROOT/work/dependencies/SDL"
if [[ ! -d "$SRC/.git" ]]; then
 git clone --depth 1 --branch release-2.32.8 https://github.com/libsdl-org/SDL.git "$SRC"
fi
[[ "$(git -C "$SRC" rev-parse HEAD)" == "$SDL_COMMIT" ]] || { echo 'SDL pin mismatch' >&2; exit 1; }
[[ -z "$(git -C "$SRC" status --porcelain)" ]] || { echo 'SDL source has local changes' >&2; exit 1; }
COMMON=(-G Ninja -DCMAKE_SYSTEM_NAME="$SYSTEM" -DCMAKE_OSX_SYSROOT="$SDK"
 -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$MINOS" -DCMAKE_BUILD_TYPE=Release)
cmake -S "$SRC" -B "work/dependencies/sdl-$SDK" "${COMMON[@]}" \
 -DSDL_STATIC=ON -DSDL_SHARED=OFF -DSDL_TEST=OFF -DSDL_TESTS=OFF \
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
