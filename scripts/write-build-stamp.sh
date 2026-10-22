#!/usr/bin/env bash
# Run before shell compilation; keep parallel SDK/configuration stamps isolated.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${DERIVED_FILE_DIR:?Xcode must provide DERIVED_FILE_DIR}"
: "${MARKETING_VERSION:?Xcode must provide MARKETING_VERSION}"
[[ "$MARKETING_VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo 'Invalid MARKETING_VERSION' >&2; exit 1; }
REVISION="$(git -C "$ROOT" rev-parse --short=12 HEAD)"
if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]]; then
  REVISION="$REVISION-dirty"
fi
STAMP="$(date -u +%Y%m%d%H%M%S)-$REVISION"
mkdir -p "$DERIVED_FILE_DIR"
cat > "$DERIVED_FILE_DIR/build_stamp.h" <<HEADER
// Generated at build time by scripts/write-build-stamp.sh.
#pragma once
#define PD_IOS_BUILD_STAMP "$STAMP"
#define PD_IOS_MARKETING_VERSION "$MARKETING_VERSION"
HEADER
printf 'Shell build: %s (%s)\n' "$STAMP" "$MARKETING_VERSION"
