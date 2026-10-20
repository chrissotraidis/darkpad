#!/usr/bin/env bash
# Run one seeded fixed-step replay on two builds and diff what they drew.
#
#   scripts/replay-diff.sh [--a FLAVOUR] [--b FLAVOUR] [--ini FILE]
#                          <label> -- <game flags...>
#
# FLAVOUR is gcc | clang | angle; the default pair is gcc and clang, which is
# the compiler-parity question 0.3 asked (D-004/D-005). `--a clang --b angle`
# is the substrate question 0.5 asks: the SAME clang binary's source built
# against ANGLE's OpenGL ES 3.0 context instead of macOS desktop GL, so the
# gfx lines must be IDENTICAL (the display list interpreter never changed) and
# only the pixels may differ, by GPU filtering and rounding at most.
#
# --ini FILE seeds both runs' save dirs from one file, so both sides are
# running the same settings; each run gets its own save dir (pdsave-<label>)
# because exiting at --exit-frame rewrites pd.ini.
#
# e.g.  scripts/replay-diff.sh mp-skedar-8 -- \
#           --boot-stage 0x32 --mpsims 8 --rng-seed 1234 \
#           --exit-frame 2000 --screenshot-frame 1500
#
# --fixed-step --skip-intro --no-sound --log --gfxstats 1 are added for you;
# do not pass them again. The comparison is upstream's (CLAUDE-notes/
# performance.md): the `gfx: N draws` lines must match line for line, and the
# --screenshot-frame PNGs must match pixel for pixel. Draw counts carry a
# +/-1 HUD element between otherwise identical runs, so the VERTEX counts are
# the hard signal; the script reports both.
#
# Loud on failure: any divergence exits non-zero and names the first bad line.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
A=gcc
B=clang
INI=
while [ $# -gt 0 ]; do
	case "$1" in
		--a) A="$2"; shift 2 ;;
		--b) B="$2"; shift 2 ;;
		--ini) INI="$2"; shift 2 ;;
		*) break ;;
	esac
done

LABEL="${1:?usage: replay-diff.sh [--a F] [--b F] [--ini FILE] <label> -- <game flags...>}"
shift
[ "${1:-}" = "--" ] && shift

OUT="$REPO/artifacts/oracle/replay/$LABEL"
mkdir -p "$OUT"

COMMON=(--fixed-step --skip-intro --no-sound --log --gfxstats 1)

rundir_of() {
	case "$1" in
		angle) echo "$REPO/build/spike-angle/build" ;;
		*) echo "$REPO/build/oracle-$1" ;;
	esac
}

for f in "$A" "$B"; do
	rundir="$(rundir_of "$f")"
	rm -f "$rundir"/screenshots/*.png 2>/dev/null || true
	echo "== $LABEL: $f build =="
	iniarg=()
	[ -n "$INI" ] && iniarg=(--ini "$INI")
	"$REPO/scripts/run-oracle.sh" "--$f" --savedir "pdsave-$LABEL" "${iniarg[@]}" \
		-- "${COMMON[@]}" "$@" > "$OUT/$f.log" 2>&1
	# The run must have ended at --exit-frame, not at the watchdog: a flag the
	# game did not understand (a quoted "--boot-stage 0x1d" reaching argv as one
	# word, say) silently boots the Carrington Institute instead and renders for
	# ever, which otherwise gets diffed as if it were the scenario asked for.
	grep -q 'exit-frame .* reached' "$OUT/$f.log" || {
		echo "$f run did not reach --exit-frame; last lines:" >&2
		grep -vE '^gfx:|could not find function|loading segment|^fps:' "$OUT/$f.log" | tail -5 >&2
		exit 1
	}
	grep -E '^gfx:' "$OUT/$f.log" > "$OUT/$f.gfx"
	shot=$(ls -t "$rundir"/screenshots/*.png 2>/dev/null | head -1 || true)
	if [ -n "$shot" ]; then cp "$shot" "$OUT/$f.png"; fi
done

status=0

echo "-- draw/vertex lines --"
a=$(wc -l < "$OUT/$A.gfx"); b=$(wc -l < "$OUT/$B.gfx")
echo "$A: $a lines, $B: $b lines"
if diff -q "$OUT/$A.gfx" "$OUT/$B.gfx" > /dev/null; then
	echo "IDENTICAL: every gfx line matches ($a lines)"
else
	echo "DIVERGED: first differing gfx line:"
	diff "$OUT/$A.gfx" "$OUT/$B.gfx" > "$OUT/gfx.diff" || true
	head -8 "$OUT/gfx.diff"
	echo "($(grep -c '^<' "$OUT/gfx.diff") differing lines of $a; full diff in $OUT/gfx.diff)"
	status=1
fi

# Vertex counts alone, which do not carry the HUD's +/-1.
for f in "$A" "$B"; do
	sed -nE 's/^gfx: [0-9]+ draws, ([0-9]+) tris, ([0-9]+) verts.*/\1 \2/p' "$OUT/$f.gfx" > "$OUT/$f.geom"
done
if diff -q "$OUT/$A.geom" "$OUT/$B.geom" > /dev/null; then
	echo "IDENTICAL: tri/vertex counts match line for line"
else
	echo "DIVERGED: tri/vertex counts differ at:"
	diff "$OUT/$A.geom" "$OUT/$B.geom" > "$OUT/geom.diff" || true
	head -8 "$OUT/geom.diff"
	echo "($(grep -c '^<' "$OUT/geom.diff") differing frames of $(wc -l < "$OUT/$A.geom"))"
	status=1
fi

echo "-- screenshot --"
if [ -f "$OUT/$A.png" ] && [ -f "$OUT/$B.png" ]; then
	python3 - "$OUT/$A.png" "$OUT/$B.png" "$OUT/diff.png" <<'PY' || status=1
import sys
from PIL import Image, ImageChops
a = Image.open(sys.argv[1]).convert("RGB")
b = Image.open(sys.argv[2]).convert("RGB")
if a.size != b.size:
    print("DIVERGED: sizes %s vs %s" % (a.size, b.size)); sys.exit(1)
d = ImageChops.difference(a, b)
bbox = d.getbbox()
if bbox is None:
    print("IDENTICAL: %dx%d screenshots are pixel-identical" % a.size); sys.exit(0)
d.save(sys.argv[3])
hist = d.convert("L").histogram()
n = sum(hist[1:])
print("DIVERGED: %d differing pixels, bbox %s, max delta %d (diff written)"
      % (n, bbox, max(i for i, c in enumerate(hist) if c)))
sys.exit(1)
PY
else
	echo "NO SCREENSHOT: pass --screenshot-frame N to compare pixels"
fi

echo "artifacts: $OUT"
exit "$status"
