#!/usr/bin/env bash
# Native reference from the exact unmodified engine pin; uses project-local SDL2.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[[ "$(git -C vendor/dabs-mod rev-parse HEAD)" == "$(cat UPSTREAM_PIN)" ]] || exit 1
PREFIX="$ROOT/work/deps-macosx"
test -f "$PREFIX/lib/libSDL2.a"
PARITY="-ffp-contract=off -fno-builtin-sinf -fno-builtin-cosf -I$PREFIX/include -I$PREFIX/include/SDL2"
# SDL2's legacy Find module does not carry static transitive Apple frameworks.
FRAMEWORKS="-framework Cocoa -framework IOKit -framework CoreVideo -framework CoreAudio -framework AudioToolbox -framework ForceFeedback -framework Carbon -framework Metal -framework GameController -framework CoreHaptics -framework AVFoundation -framework CoreBluetooth -framework Security -framework SystemConfiguration -liconv"
cmake -S vendor/dabs-mod -B build/oracle-clang -G Ninja \
 -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
 -DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
 -DSDL2_INCLUDE_DIR="$PREFIX/include/SDL2" -DSDL2_LIBRARY_TEMP="$PREFIX/lib/libSDL2.a" \
 -DSDL2MAIN_LIBRARY="$PREFIX/lib/libSDL2main.a" \
 -DPD_VULKAN=OFF -DCMAKE_DISABLE_FIND_PACKAGE_CURL=OFF \
 -DCURL_LIBRARY_RELEASE="$ROOT/work/curl-macosx/lib/libcurl.a" \
 -DCURL_INCLUDE_DIR="$ROOT/work/curl-macosx/include" \
 -DCMAKE_C_FLAGS="$PARITY" -DCMAKE_CXX_FLAGS="$PARITY" \
 -DCMAKE_EXE_LINKER_FLAGS="$FRAMEWORKS"
cmake --build build/oracle-clang -j "${PD_BUILD_JOBS:-6}"
python3 scripts/check-apple-platform.py macosx build/oracle-clang/pd.arm64
