#!/usr/bin/env bash
#
# Phase 0.6 memory probe. Runs the clang oracle binary from a throwaway run dir
# under build/memtest/ and records, for one scenario:
#
#   * peak RSS            — ps(1) polled every 0.5 s (works even when the run is
#                           ended by the watchdog rather than by --exit-frame)
#   * peak footprint      — footprint(1) polled on the same tick; this is the
#                           number that counts the GL driver's own allocations
#                           ("Owned physical footprint (unmapped) (graphics)",
#                           IOSurface, IOAccelerator), which on macOS are NOT in
#                           the process RSS. It is the closest analogue of what
#                           iOS jetsam charges an app.
#   * a steady-frame footprint(1) and vmmap -summary snapshot
#
#   scripts/mem-probe.sh <label> <n64|xbla> <enhance 0|2|4|8> \
#       [--snapat SEC] [--dur SEC] -- <game flags...>
#
# Results land in build/memtest/results/<label>.{peak,footprint,vmmap,time,log}.
#
# Traps (docs/oracle.md): Video.VSync=0 is mandatory or the process blocks for
# ever in Cocoa_GL_SwapWindow; every run gets its own --savedir because
# --exit-frame exits through atexit(cleanup), which rewrites pd.ini.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="$1"; DIRKIND="$2"; ENHANCE="$3"; shift 3
SNAPAT=25; DUR=900
while [ $# -gt 0 ]; do
	case "$1" in
		--snapat) SNAPAT="$2"; shift 2 ;;
		--dur) DUR="$2"; shift 2 ;;
		--) shift; break ;;
		*) break ;;
	esac
done

RUNDIR="$REPO/build/memtest/$DIRKIND"
OUT="$REPO/build/memtest/results"
SAVE="$RUNDIR/save-$LABEL"
[ -x "$RUNDIR/pd.arm64" ] || { echo "no binary at $RUNDIR/pd.arm64" >&2; exit 1; }
mkdir -p "$OUT" "$SAVE"

case "$ENHANCE" in 0) E=0 ;; 2) E=1 ;; 4) E=2 ;; 8) E=3 ;; *) echo "enhance must be 0/2/4/8" >&2; exit 1 ;; esac
case "$DIRKIND" in xbla) X=1 ;; *) X=0 ;; esac

cat > "$SAVE/pd.ini" <<EOF
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

[Mod]
EnhanceTextures=$E
SmoothText=0
XblaMeshes=$X
XblaMeshTextures=$X
XblaStages=$X
XblaFont=$X
XblaExplosions=$X
EOF

cd "$RUNDIR"
rm -f "$OUT/$LABEL.peak" "$OUT/$LABEL.footprint" "$OUT/$LABEL.vmmap"
./pd.arm64 --savedir "./save-$LABEL" "$@" >"$OUT/$LABEL.log" 2>&1 &
pid=$!

(	maxrss=0; peak=""; t=0
	while kill -0 "$pid" 2>/dev/null; do
		r=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' '); [ -n "$r" ] || break
		[ "$r" -gt "$maxrss" ] && maxrss=$r
		if [ $((t % 6)) -eq 2 ]; then
			v=$(vmmap -summary "$pid" 2>/dev/null | awk -F: '/Physical footprint \(peak\)/{gsub(/ /,"",$2); print $2; exit}')
			[ -n "$v" ] && peak="$v"
		fi
		if [ "$t" -eq $((SNAPAT * 2)) ]; then
			footprint -p "$pid" > "$OUT/$LABEL.footprint" 2>&1 || true
			vmmap -summary "$pid" > "$OUT/$LABEL.vmmap" 2>&1 || true
		fi
		t=$((t + 1)); sleep 0.5
	done
	echo "peak_rss_kb=$maxrss phys_footprint_peak=$peak samples=$t" > "$OUT/$LABEL.peak" ) &
poller=$!

( sleep "$DUR"; kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 & watchdog=$!
set +e; wait "$pid"; rc=$?; set -e
wait "$poller" 2>/dev/null || true
kill "$watchdog" 2>/dev/null || true
echo "[$LABEL] rc=$rc  $(cat "$OUT/$LABEL.peak")"
