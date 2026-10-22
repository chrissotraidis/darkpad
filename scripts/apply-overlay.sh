#!/usr/bin/env bash
# apply-overlay.sh [dest-dir] — materialise a buildable tree from the pinned
# vendor checkout plus overlay/patches/*.patch, in order.
#
# Ground rule 1 (charter): vendor/dabs-mod is never edited. Every local change
# is a patch here, applied with --fuzz=0 onto a *copy*. Additive files (the
# ANGLE glue, the iOS shell) stay in app/ and are referenced by absolute path
# from CMake — they are NEVER copied into the tree, so `git status` in the
# overlay tree is always exactly the patches and nothing else.
#
# Failures are loud: the first patch that does not apply cleanly stops the
# script with the patch name and the reject output.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${1:-$ROOT/build/src}"
SRC="$ROOT/vendor/dabs-mod"

[ -d "$SRC/.git" ] || { echo "FATAL: no vendor checkout at $SRC — run scripts/bootstrap.sh" >&2; exit 1; }

PIN="$(cat "$ROOT/UPSTREAM_PIN")"
HAVE="$(git -C "$SRC" rev-parse HEAD)"
if [ "$HAVE" != "$PIN" ]; then
  echo "FATAL: vendor/dabs-mod is at $HAVE, pin says $PIN — run scripts/bootstrap.sh" >&2
  exit 1
fi

mkdir -p "$DEST"
# -a preserves everything, -c checksums (mtimes churn across rsyncs and would
# rebuild the world), --delete drops files a previous overlay left behind.
# .git is excluded: the copy is a build artifact, not a checkout.
rsync -ac --delete --exclude '.git' "$SRC/" "$DEST/"

shopt -s nullglob
PATCHES=("$ROOT"/overlay/patches/*.patch)
shopt -u nullglob
if [ ${#PATCHES[@]} -eq 0 ]; then
  echo "no patches in overlay/patches — tree is pristine upstream at $HAVE"
  exit 0
fi

FAILED=()
for p in "${PATCHES[@]}"; do
  name="$(basename "$p")"
  # --forward: a patch whose hunks are already in the tree must FAIL, not be
  # reverse-applied. Without it BSD patch answers its own "Reversed (or
  # previously applied) patch detected! Assume -R? [y]" with yes, removes the
  # change and exits 0 — the 0036 trap of the 245eca04c bump (docs/build.md).
  if patch -d "$DEST" -p1 --fuzz=0 --forward --no-backup-if-mismatch < "$p" > "$DEST/.patch.log" 2>&1; then
    printf '  ok   %s\n' "$name"
    # PD_OVERLAY_SHOW_OFFSETS=1 prints every hunk that did not land at the line
    # the patch names — the wrong-place audit (0018 landed 110 lines early in
    # the same bump and still said ok). --fuzz=0 checks context, not position.
    if [ "${PD_OVERLAY_SHOW_OFFSETS:-0}" = "1" ]; then
      grep -E '^(patching file|Hunk #)' "$DEST/.patch.log" | sed 's/^/         /' || true
    fi
  else
    printf '  FAIL %s\n' "$name"
    sed 's/^/       /' "$DEST/.patch.log"
    FAILED+=("$name")
    if [ "${PD_OVERLAY_KEEP_GOING:-0}" != "1" ]; then
      rm -f "$DEST/.patch.log"
      echo "FATAL: $name did not apply cleanly to $DEST" >&2
      exit 1
    fi
  fi
done
rm -f "$DEST/.patch.log"

if [ ${#FAILED[@]} -ne 0 ]; then
  echo "FAILED PATCHES: ${FAILED[*]}" >&2
  exit 1
fi

echo "overlay applied: ${#PATCHES[@]} patches onto $HAVE -> $DEST"
