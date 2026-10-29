#!/usr/bin/env bash
# Validate and package a personal Mac Catalyst app. Signing is local/ad-hoc.
set -euo pipefail
APP="${1:?usage: package-macos.sh APP OUTPUT.zip}"
OUT="${2:?usage: package-macos.sh APP OUTPUT.zip}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
BIN="$APP/Contents/MacOS/DarkPad"
test -f "$BIN" || { echo "No DarkPad Mac app at $APP" >&2; exit 1; }
python3 "$ROOT/scripts/check-apple-platform.py" maccatalyst "$BIN"
for lib in libEGL libGLESv2; do
 python3 "$ROOT/scripts/check-apple-platform.py" maccatalyst "$APP/Contents/Frameworks/$lib.framework/$lib"
done
# Imported content belongs in Application Support, never in the app bundle.
# Check names as well as files so a symlink cannot bypass the content guard.
for pattern in '*.z64' '*.n64' '*.v64' '*.rom' 'eeprom.bin' 'pd.ini' \
 '*.mobileprovision' '*.provisionprofile' '*.7z' '*.zip' '*.rar' '*.tar' \
 '*.tar.gz' '*.tgz' '*.tar.xz' '*.txz' '*.tar.bz2' '*.tbz2'; do
 hit="$(find "$APP" -iname "$pattern" -print -quit)"
 [ -z "$hit" ] || { echo "Refusing app containing $hit" >&2; exit 1; }
done
for name in data added-content texture-packs model-packs xbla pdsave saves mods; do
 hit="$(find "$APP" \( -type d -o -type l \) -iname "$name" -print -quit)"
 [ -z "$hit" ] || { echo "Refusing app containing game-data directory $hit" >&2; exit 1; }
done
if LC_ALL=C grep -aF 'perfectdark: [bridge] listening' "$BIN" >/dev/null; then
 echo "Refusing a development build; generate the project with PD_PUBLIC=1" >&2; exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/DarkPad.app"
DEST="$STAGE/DarkPad.app"
RES="$DEST/Contents/Resources"
mkdir -p "$RES/Licenses"
cp "$ROOT/LICENSE" "$RES/Licenses/DarkPad.txt"
cp "$ROOT/vendor/dabs-mod/LICENSE" "$RES/Licenses/Engine.txt"
cp "$ROOT/work/licenses/maccatalyst/SDL.txt" "$RES/Licenses/SDL.txt"
cp "$ROOT/work/licenses/maccatalyst/curl.txt" "$RES/Licenses/curl.txt"
cp "$ROOT/work/angle-build/angle/LICENSE" "$RES/Licenses/ANGLE.txt"

# A desktop icon generated from the same artwork as iPhone/iPad.
ICONSET="$STAGE/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
 sips -z "$size" "$size" "$ROOT/app/ios/icon/AppIcon1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
 double=$((size * 2))
 sips -z "$double" "$double" "$ROOT/app/ios/icon/AppIcon1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"
plutil -replace CFBundleIconFile -string AppIcon "$DEST/Contents/Info.plist"
for lib in libEGL libGLESv2; do
 codesign --force --sign - "$DEST/Contents/Frameworks/$lib.framework"
done
codesign --force --sign - "$DEST"
codesign --verify --deep --strict "$DEST"
mkdir -p "$(dirname "$OUT")"
ditto -c -k --norsrc --keepParent "$DEST" "$OUT"
echo "Mac app: $OUT"
