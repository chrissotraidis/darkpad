#!/usr/bin/env bash
# Vendor the pinned upstream. Idempotent. The pin is the ONLY place the
# upstream commit is named; scripts/bump-upstream.sh changes it.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIN="$(cat "$ROOT/UPSTREAM_PIN")"
URL="https://github.com/DabDavis/perfect-dark-dabs-mod.git"
DEST="$ROOT/vendor/dabs-mod"
if [[ ! -d "$DEST/.git" ]]; then
  git clone --branch dabs-mod "$URL" "$DEST"
fi
if [[ -n "$(git -C "$DEST" status --porcelain)" ]]; then
  echo "FATAL: vendor checkout has local changes; preserve them before bootstrapping" >&2
  exit 1
fi
git -C "$DEST" fetch --quiet origin
git -C "$DEST" checkout --quiet --detach "$PIN"
git -C "$DEST" submodule update --init --recursive --quiet
echo "vendor/dabs-mod at $(git -C "$DEST" rev-parse --short HEAD) (pin $PIN)"
