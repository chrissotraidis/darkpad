#!/usr/bin/env bash
# Stage a recipe-only release locally. Does not tag, upload or publish anything.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || {
  echo "Commit or preserve checkout changes before preparing release assets." >&2; exit 1;
}
VERSION="$(tr -d ' \n' < VERSION)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid VERSION' >&2; exit 1; }
[[ "$(tr -d ' \n' < DEV_ITERATION)" = 0 ]] || { echo 'DEV_ITERATION must be 0' >&2; exit 1; }
python3 - <<'PY'
import json
from pathlib import Path
recipe = json.loads(Path('padmint.json').read_text())
assert recipe['id'] == 'darkpad'
assert recipe['publication']['public_binaries'] is False
PY
OUT="$ROOT/dist/darkpad-v$VERSION"
# Refuse an existing directory: an old IPA must never become a release asset.
mkdir -p "$ROOT/dist"
mkdir "$OUT"
NAME="darkpad-v$VERSION-padmint.json"
cp padmint.json "$OUT/$NAME"
(cd "$OUT" && shasum -a 256 "$NAME" > SHA256SUMS && shasum -a 256 -c SHA256SUMS)
echo "Recipe-only assets: $OUT"
echo "Audit both files with current PadMint before publishing (docs/RELEASE-CHECKLIST.md)."
