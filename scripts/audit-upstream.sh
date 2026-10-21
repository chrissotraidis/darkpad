#!/usr/bin/env bash
# Assess an already-fetched engine revision without changing UPSTREAM_PIN,
# the vendor checkout, build/src, or an existing audit. Failed patches may
# partially apply: this diagnostic tree is NOT a build or acceptance result.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REF="${1:?usage: scripts/audit-upstream.sh <local commit or ref>}"
VENDOR="$ROOT/vendor/dabs-mod"
REV="$(git -C "$VENDOR" rev-parse --verify "$REF^{commit}")"
mkdir -p "$ROOT/work"
AUDIT="$(mktemp -d "$ROOT/work/upstream-audit.XXXXXX")"
mkdir "$AUDIT/src" "$AUDIT/logs"
printf '%s\n' "$REV" > "$AUDIT/revision.txt"
git -C "$VENDOR" archive "$REV" > "$AUDIT/source.tar"
tar -xf "$AUDIT/source.tar" -C "$AUDIT/src"
rm "$AUDIT/source.tar"
printf 'revision\t%s\npatch\tresult\n' "$REV" > "$AUDIT/results.tsv"
FAILED=0
TOTAL=0
for PATCH_FILE in "$ROOT"/overlay/patches/*.patch; do
  NAME="$(basename "$PATCH_FILE")"
  TOTAL=$((TOTAL + 1))
  if patch -d "$AUDIT/src" -p1 --fuzz=0 --forward --batch --no-backup-if-mismatch < "$PATCH_FILE" > "$AUDIT/logs/$NAME.log" 2>&1; then
    printf '%s\tPASS\n' "$NAME" >> "$AUDIT/results.tsv"
  else
    printf '%s\tFAIL\n' "$NAME" >> "$AUDIT/results.tsv"
    FAILED=$((FAILED + 1))
  fi
done
printf 'Audit: %s\nRevision: %s\nPatches: %d; failed: %d\n' "$AUDIT" "$REV" "$TOTAL" "$FAILED"
printf 'Diagnostic only: inspect failed hunks and offsets before porting.\n'
[ "$FAILED" -eq 0 ]
