#!/usr/bin/env bash
# Assess an already-fetched engine revision without changing UPSTREAM_PIN,
# the vendor checkout, build/src, or an existing audit. Failed patches may
# partially apply: this diagnostic tree is NOT a build or acceptance result.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REF="${1:?usage: scripts/audit-upstream.sh <local commit or ref> [replacement patch directory]}"
REPLACEMENTS="${2:-}"
if [ -n "$REPLACEMENTS" ]; then
  [ -d "$REPLACEMENTS" ] || { echo "Missing replacement patch directory" >&2; exit 2; }
  REPLACEMENTS="$(cd "$REPLACEMENTS" && pwd)"
fi
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
while IFS= read -r NAME; do
  PATCH_FILE="$ROOT/overlay/patches/$NAME"
  if [ -n "$REPLACEMENTS" ] && [ -f "$REPLACEMENTS/$NAME" ]; then
    PATCH_FILE="$REPLACEMENTS/$NAME"
    printf 'replacement\t%s\n' "$PATCH_FILE" >> "$AUDIT/results.tsv"
  fi
  TOTAL=$((TOTAL + 1))
  if patch -d "$AUDIT/src" -p1 --fuzz=0 --forward --batch --no-backup-if-mismatch < "$PATCH_FILE" > "$AUDIT/logs/$NAME.log" 2>&1; then
    printf '%s\tPASS\n' "$NAME" >> "$AUDIT/results.tsv"
  else
    printf '%s\tFAIL\n' "$NAME" >> "$AUDIT/results.tsv"
    FAILED=$((FAILED + 1))
  fi
done < <(
  # Candidate-only patches join the same ordered series; matching names
  # still replace solo patches exactly once.
  {
    for PATCH_FILE in "$ROOT"/overlay/patches/*.patch; do basename "$PATCH_FILE"; done
    if [ -n "$REPLACEMENTS" ]; then
      for PATCH_FILE in "$REPLACEMENTS"/*.patch; do
        [ -f "$PATCH_FILE" ] && basename "$PATCH_FILE"
      done
    fi
  } | LC_ALL=C sort -u
)
printf 'Audit: %s\nRevision: %s\nPatches: %d; failed: %d\n' "$AUDIT" "$REV" "$TOTAL" "$FAILED"
printf 'Diagnostic only: inspect failed hunks and offsets before porting.\n'
[ "$FAILED" -eq 0 ]
# A successful archived overlay needs an identity independent of its parent Git
# repository. Hash the reconstructed sources before CMake generates any files.
python3 - "$AUDIT/src" <<'PYID'
import hashlib, pathlib, sys
root = pathlib.Path(sys.argv[1])
h = hashlib.sha256()
for path in sorted(p for p in root.rglob('*') if p.is_file()):
    name = path.relative_to(root).as_posix().encode()
    data = path.read_bytes()
    h.update(len(name).to_bytes(8, 'big')); h.update(name)
    h.update(len(data).to_bytes(8, 'big')); h.update(data)
(root / '.darkpad-source-id').write_text(h.hexdigest() + '\n')
print('Source identity:', h.hexdigest())
PYID
