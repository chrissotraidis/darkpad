#!/usr/bin/env bash
# bump-upstream.sh <commit|branch|--dry-run> — move UPSTREAM_PIN, re-bootstrap,
# re-apply the overlay, and report which patches fail.
#
# The bump drill of the charter's Acceptance section. With --dry-run the pin is
# not touched and the current pin is re-tested (a no-op bump must be green).
#
# On failure the pin is LEFT AT THE NEW COMMIT and the failing patches are
# listed: the point of the drill is to learn what upstream moved under us.
# Revert with `git checkout UPSTREAM_PIN && scripts/bootstrap.sh`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
REF="${1:-}"
[ -n "$REF" ] || { echo "usage: $0 <commit|branch|--dry-run>" >&2; exit 1; }

OLD="$(cat UPSTREAM_PIN)"

if [ "$REF" = "--dry-run" ]; then
  NEW="$OLD"
  echo "dry run: re-testing the current pin $OLD"
else
  git -C vendor/dabs-mod fetch --quiet origin
  NEW="$(git -C vendor/dabs-mod rev-parse "$REF^{commit}" 2>/dev/null || git -C vendor/dabs-mod rev-parse "origin/$REF^{commit}")"
  if [ "$NEW" = "$OLD" ]; then
    echo "pin already at $NEW — nothing to bump, running the drill anyway"
  else
    echo "$NEW" > UPSTREAM_PIN
    echo "pin $OLD -> $NEW"
  fi
fi

scripts/bootstrap.sh

DEST="$ROOT/build/bump-src"
rm -rf "$DEST"
echo "--- applying overlay onto $NEW ---"
if PD_OVERLAY_KEEP_GOING=1 scripts/apply-overlay.sh "$DEST"; then
  echo "BUMP OK: every patch applies onto $NEW"
  if [ "$REF" != "--dry-run" ] && [ "$NEW" != "$OLD" ]; then
    echo "shortlog $OLD..$NEW:"
    git -C vendor/dabs-mod log --oneline "$OLD..$NEW" | sed 's/^/  /' | head -40
  fi
  exit 0
else
  echo "BUMP FAILED: the patches listed above need rebasing onto $NEW" >&2
  exit 1
fi
