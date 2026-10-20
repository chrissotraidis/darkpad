#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/dependencies/pins.env"
BASE="$ROOT/work/angle-build"
mkdir -p "$BASE"
checkout() {
 local url="$1" path="$2" pin="$3"
 if [[ ! -d "$path/.git" ]]; then
  git init "$path"
  git -C "$path" remote add origin "$url"
  git -C "$path" fetch --depth 1 origin "$pin"
  git -C "$path" checkout --detach FETCH_HEAD
 fi
 [[ "$(git -C "$path" rev-parse HEAD)" == "$pin" ]] || { echo "Pin mismatch: $path" >&2; exit 1; }
}
checkout https://chromium.googlesource.com/chromium/tools/depot_tools.git "$BASE/depot_tools" "$DEPOT_TOOLS_COMMIT"
checkout https://chromium.googlesource.com/angle/angle "$BASE/angle" "$ANGLE_COMMIT"
export PATH="$BASE/depot_tools:$PATH"
export DEPOT_TOOLS_UPDATE=0
cd "$BASE/angle"
if [[ ! -f .gclient ]]; then
 python3 scripts/bootstrap.py
 printf '\ntarget_os = ["ios", "mac"]\n' >> .gclient
fi
gclient sync --no-history --shallow --jobs=4
mkdir -p "$ROOT/work/licenses"
cp LICENSE "$ROOT/work/licenses/ANGLE.txt"
echo "ANGLE and DEPS synchronized at $ANGLE_COMMIT"
