#!/usr/bin/env bash
# package-ipa.sh APP OUTPUT.ipa — check an unsigned iPhoneOS DarkPad app and
# wrap it as an IPA. Refuses simulator builds, ROMs and signing material.
set -euo pipefail
APP="${1:?usage: package-ipa.sh APP OUTPUT.ipa}"
OUT="${2:?usage: package-ipa.sh APP OUTPUT.ipa}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac

test -f "$APP/perfectdark" || { echo "No DarkPad app at $APP" >&2; exit 1; }
python3 "$ROOT/scripts/check-apple-platform.py" iphoneos "$APP/perfectdark"
for f in "$APP"/Frameworks/*.framework; do
 python3 "$ROOT/scripts/check-apple-platform.py" iphoneos "$f/$(basename "$f" .framework)"
done
for pattern in '*.z64' '*.n64' '*.v64' '*.rom' 'eeprom.bin' 'pd.ini' '*.mobileprovision'; do
 hit="$(find "$APP" -type f -iname "$pattern" -print -quit)"
 [ -z "$hit" ] || { echo "Refusing app containing $hit" >&2; exit 1; }
done
[ ! -d "$APP/_CodeSignature" ] || { echo "Refusing signed app; build with CODE_SIGNING_ALLOWED=NO" >&2; exit 1; }
if strings "$APP/perfectdark" | grep -q 'perfectdark: [bridge] listening'; then
 echo "Refusing a development build; generate the project with PD_PUBLIC=1" >&2; exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload"
ditto "$APP" "$STAGE/Payload/$(basename "$APP")"
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
(cd "$STAGE" && ditto -c -k --norsrc --keepParent Payload "$OUT")
echo "IPA: $OUT ($(du -h "$OUT" | cut -f1))"
