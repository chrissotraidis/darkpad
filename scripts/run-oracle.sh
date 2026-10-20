#!/usr/bin/env bash
# Run the macOS arm64 oracle with the staged game data.
#
#   scripts/run-oracle.sh [--gcc|--clang|--angle] [--timeout N]
#                         [--savedir NAME] [--ini FILE] -- <game flags...>
#
# Defaults to the clang oracle, which is the port's parity reference (D-004).
# --angle runs the ANGLE-Metal spike build (build/spike-angle/build, Phase 0.5,
# docs/angle-spike.md): the same source through an OpenGL ES 3.0 context served
# by ANGLE instead of macOS's desktop GL. It is the same binary layout, so
# everything below applies to it unchanged.
#
# --savedir NAME gives the run its own save dir under the run dir (default
# pdsave). Every scripted run wants one: --exit-frame exits through
# atexit(cleanup), which rewrites pd.ini, so two scenarios sharing a save dir
# overwrite each other's settings. --ini FILE seeds a new save dir from that
# file instead of from the built-in Video block.
# Everything after -- (or after the recognised options) is handed to the game.
#
# The run dir is the build dir itself: data/pd.ntsc-final.z64 is a symlink to
# work/gamedata, pdsave/ holds pd.ini + eeprom, screenshots/ and xbla/ sit
# beside the binary the way upstream's own runs expect.
#
# TRAP (earned 2026-09-12): the run dir's pd.ini MUST carry Video.VSync=0.
# SDL2's macOS swap-interval path waits on a CVDisplayLink condition inside
# SwapWindow, and a window that is not frontmost never gets signalled, so a
# scripted run blocks for ever in Cocoa_GL_SwapWindow with one frame drawn.
# ensure_ini below writes the file if it is missing.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLAVOUR=clang
TIMEOUT=600
SAVEDIR=pdsave
INI=

while [ $# -gt 0 ]; do
	case "$1" in
		--gcc) FLAVOUR=gcc; shift ;;
		--clang) FLAVOUR=clang; shift ;;
		--angle) FLAVOUR=angle; shift ;;
		--timeout) TIMEOUT="$2"; shift 2 ;;
		--savedir) SAVEDIR="$2"; shift 2 ;;
		--ini) INI="$2"; shift 2 ;;
		--) shift; break ;;
		*) break ;;
	esac
done

if [ "$FLAVOUR" = angle ]; then
	RUNDIR="$REPO/build/spike-angle/build"
else
	RUNDIR="$REPO/build/oracle-$FLAVOUR"
fi
BIN="$RUNDIR/pd.arm64"

[ -x "$BIN" ] || { echo "no oracle binary at $BIN - build it first (see docs/oracle.md)" >&2; exit 1; }
[ -e "$REPO/work/gamedata/pd.ntsc-final.z64" ] || { echo "ROM not staged: work/gamedata/pd.ntsc-final.z64 missing (see work/gamedata-PROVENANCE.md)" >&2; exit 1; }

mkdir -p "$RUNDIR/data" "$RUNDIR/$SAVEDIR"
ln -sf "$REPO/work/gamedata/pd.ntsc-final.z64" "$RUNDIR/data/pd.ntsc-final.z64"

if [ -n "$INI" ]; then
	[ -f "$INI" ] || { echo "no such ini: $INI" >&2; exit 1; }
	cp "$INI" "$RUNDIR/$SAVEDIR/pd.ini"
elif [ ! -f "$RUNDIR/$SAVEDIR/pd.ini" ]; then
	cat > "$RUNDIR/$SAVEDIR/pd.ini" <<'EOF'
[Video]
DefaultFullscreen=0
DefaultMaximize=0
DefaultWidth=1280
DefaultHeight=720
AllowHiDpi=0
CenterWindow=1
VSync=0
FramerateLimit=240
DisplayFPS=0
EOF
fi

cd "$RUNDIR"
"$BIN" --savedir "./$SAVEDIR" "$@" &
pid=$!
( sleep "$TIMEOUT"; kill -9 "$pid" 2>/dev/null ) &
watchdog=$!
set +e
wait "$pid"
rc=$?
set -e
kill "$watchdog" 2>/dev/null || true
exit "$rc"
