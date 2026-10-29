#!/usr/bin/env bash
# gen-app-project.sh — stamp the version into a
# generated project.yml and run xcodegen. The .xcodeproj is generated and
# gitignored; never edit it by hand.
#
# Versioning (program convention): VERSION is the public base, DEV_ITERATION an
# integer. CFBundleShortVersionString = VERSION when DEV_ITERATION is 0, else
# VERSION.N. Never derive a version by reading a built app.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

command -v xcodegen >/dev/null || { echo "FATAL: xcodegen not installed (brew install xcodegen)" >&2; exit 1; }

PUBVER="$(tr -d ' \n' < VERSION)"
DEVIT="$(tr -d ' \n' < DEV_ITERATION)"
[ -n "$PUBVER" ] || { echo "FATAL: VERSION is empty" >&2; exit 1; }
[ -n "$DEVIT" ] || { echo "FATAL: DEV_ITERATION is empty" >&2; exit 1; }
if [ "$DEVIT" = "0" ]; then MARKETING="$PUBVER"; else MARKETING="$PUBVER.$DEVIT"; fi
BUILDNUM="$(date -u +%Y%m%d%H%M)"

test -d work/angle-xcframeworks/libEGL.xcframework || scripts/make-angle-xcframeworks.sh
test -f work/deps-iphonesimulator/lib/libSDL2.a || test -f work/deps-iphoneos/lib/libSDL2.a \
  || test -f work/deps-maccatalyst/lib/libSDL2.a \
  || { echo "FATAL: no SDL2 for iOS or Mac Catalyst (scripts/build-apple-deps.sh)" >&2; exit 1; }

# PD_PUBLIC=1 compiles the :8775 console bridge out (charter: "compiled out of
# public builds, on in every OTA build"). It is a preprocessor define on the
# shell sources only - the engine has no bridge code in it.
if [ "${PD_PUBLIC:-0}" = "1" ]; then
  PUBLIC_DEF="PD_PUBLIC=1"
  echo "PD_PUBLIC=1: the console bridge is compiled OUT of this build"
else
  PUBLIC_DEF=""
fi

# PD_MULTICAST=1 signs with com.apple.developer.networking.multicast, which the
# LAN page's room finder needs for its UDP broadcast (Dab's Mod netlan.c).
# Apple grants it per team on request, and a build that asks for it without a
# matching provisioning profile does not sign, so it is off by default: the LAN
# page then finds no rooms, while Direct Connect and Online Lobbies still work.
if [ "${PD_MULTICAST:-0}" = "1" ]; then
  ENTITLEMENTS="ios\/darkpad-multicast.entitlements"
  echo "PD_MULTICAST=1: signing with the multicast entitlement"
else
  ENTITLEMENTS=""
fi

sed -e "s/PD_MARKETING_VERSION/$MARKETING/" -e "s/PD_BUILD_NUMBER/$BUILDNUM/" \
    -e "s/PD_PUBLIC_FLAG/$PUBLIC_DEF/" -e "s/PD_ENTITLEMENTS/$ENTITLEMENTS/" \
  app/project.yml > app/project.generated.yml

( cd app && xcodegen generate --spec project.generated.yml --project . >/dev/null )
echo "generated app/perfectdark.xcodeproj (version $MARKETING build $BUILDNUM; shell identity stamped at build time)"
