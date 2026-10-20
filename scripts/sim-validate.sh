#!/usr/bin/env bash
# sim-validate.sh — THE GATE. Nothing is published that has not passed this.
#
#   scripts/sim-validate.sh [--udid UDID] [--xbla] [--keep] [--no-build]
#
# It is not a smoke test. It fails, loudly and non-zero, on any of:
#
#   * the build failing, or the wrong build being installed;
#   * the app not reaching a frame (the :8775 bridge answers or it does not);
#   * a drawable that is not the panel's native pixel count;
#   * a screenshot that is blank or nearly monochrome;
#   * a bridge-injected tap that does not land on the touch layer;
#   * the M-001 chicago-solo seeded replay drawing a different gfx stream from
#     the macOS clang oracle, or a frame that differs from the
#     oracle's by more than 1/255 on more than 6% of pixels, or by more than
#     16/255 on more than 0.02% of them or in any group over 16 pixels (D-068);
#   * a crash, an "Unknown GBI" command, or an EGL error anywhere in the log.
#
# Green means green. On success it writes a stamp with the commit it validated,
# which scripts/publish-ota.sh refuses to publish without.
#
# The simulator is shut down at the end WHATEVER happens (trap on EXIT) — the
# program rule, and a disk rule (~/dev/CLAUDE.md §Simulators).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

# Lane 3 (D-002 / charter §Simulator validation). Lane 1 is openQ4/vkQuake/
# RetroArch, lane 2 GoldenEye. Never create a device; never touch another lane.
SIM="${PD_SIM:-$(xcrun simctl list devices available | awk -F'[()]' '/iPhone 17e/{print $2; exit}')}"
BUNDLE=com.rebelancap.perfectdark
# 8775 (D-002), or PD_BRIDGE_PORT — vision-validate.sh has taken its port from
# the environment since Phase 5 and this one had not, which is how a lane-3 run
# and a lane-1 run ended up talking to each other: a simulator's loopback is the
# Mac's, so the second app finds the port taken and the FIRST one answers (the
# symptom is a `state` reporting the wrong screen size). Concurrent sessions
# pass PD_BRIDGE_PORT.
PORT="${PD_BRIDGE_PORT:-8775}"
OUT="$REPO/artifacts/sim"
WORK="$REPO/work/sim-validate"
CONSOLE="$WORK/console.log"
ORACLE_PNG="$REPO/artifacts/oracle/sim-gate/chicago-solo-844x390.png"
ORACLE_GFX="$REPO/artifacts/oracle/sim-gate/chicago-solo-844x390.gfx.gz"
# --xbla compares against the release's own reference, produced by the same
# oracle at the same resolution with all five Mod.Xbla* rows on (docs/oracle.md
# §The XBLA release on the oracle). Different picture, same gate.
ORACLE_XBLA_PNG="$REPO/artifacts/oracle/sim-gate/chicago-xbla-844x390.png"
ORACLE_XBLA_GFX="$REPO/artifacts/oracle/sim-gate/chicago-xbla-844x390.gfx.gz"
ROM="$REPO/work/gamedata/pd.ntsc-final.z64"
XBLA_ARCHIVE="$REPO/work/gamedata/Perfect Dark.rar"

# The pixel gate. M-009 measured 4.41% of pixels differing by at most 7/255
# between this simulator and the oracle at matched resolution — ANGLE-Metal's
# shader compiler, not a port defect. These thresholds sit above that and well
# below anything structural.
MAX_DELTA=16
MAX_PCT=6.0

DO_BUILD=1
DO_XBLA=0
KEEP=0
while [ $# -gt 0 ]; do
	case "$1" in
		--udid) SIM="$2"; shift 2 ;;
		--xbla) DO_XBLA=1; shift ;;
		--keep) KEEP=1; shift ;;
		--no-build) DO_BUILD=0; shift ;;
		*) echo "usage: $0 [--udid UDID] [--xbla] [--keep] [--no-build]" >&2; exit 2 ;;
	esac
done

fail() { echo ""; echo "SIM-VALIDATE FAILED: $*" >&2; exit 1; }
step() { echo ""; echo "=== $* ==="; }

cleanup() {
	local rc=$?
	xcrun simctl terminate "$SIM" "$BUNDLE" >/dev/null 2>&1 || true
	if [ "$KEEP" != "1" ]; then
		xcrun simctl shutdown "$SIM" >/dev/null 2>&1 || true
		echo "simulator $SIM shut down"
	fi
	exit $rc
}
# Registered before anything can fail, so a failed run still shuts the device
# down (the rule that a previous session broke 130 times).
trap cleanup EXIT

mkdir -p "$WORK" "$OUT"
: > "$CONSOLE"

# One line per bridge command. `nc` closes on EOF and the bridge answers one
# reply per line, so this is a complete request/response.
bridge() {
	printf '%s\n' "$*" | nc -w 8 localhost "$PORT" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
step "preflight"

[ -f "$ROM" ] || fail "no ROM at $ROM (work/gamedata-PROVENANCE.md)"
[ -f "$ORACLE_PNG" ] || fail "no oracle reference frame at $ORACLE_PNG"
[ -f "$ORACLE_GFX" ] || fail "no oracle reference gfx stream at $ORACLE_GFX"
if [ "$DO_XBLA" = "1" ]; then
	[ -f "$XBLA_ARCHIVE" ] || fail "no XBLA archive at $XBLA_ARCHIVE (work/gamedata-PROVENANCE.md)"
	[ -f "$ORACLE_XBLA_PNG" ] || fail "no oracle XBLA reference frame at $ORACLE_XBLA_PNG"
	[ -f "$ORACLE_XBLA_GFX" ] || fail "no oracle XBLA reference gfx stream at $ORACLE_XBLA_GFX"
	ORACLE_PNG="$ORACLE_XBLA_PNG"
	ORACLE_GFX="$ORACLE_XBLA_GFX"
	OUT="$OUT/xbla"
	mkdir -p "$OUT"
fi
command -v nc >/dev/null || fail "no nc(1)"
python3 -c 'import PIL' 2>/dev/null || fail "python3 Pillow is needed for the pixel gate"

if pgrep -fl 'Developer/usr/bin/xcodebuild|cmake --build|ninja -C' >/dev/null 2>&1; then
	echo "NOTE: another build is running on this machine:"
	pgrep -fl 'Developer/usr/bin/xcodebuild|cmake --build|ninja -C' || true
fi

GITREV="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
echo "commit $GITREV, device $SIM"

# ---------------------------------------------------------------------------
if [ "$DO_BUILD" = "1" ]; then
	step "build"
	scripts/apply-overlay.sh >/dev/null || fail "overlay did not apply"
	scripts/build-ios.sh simulator >/dev/null 2>&1 || fail "engine build failed (run scripts/build-ios.sh simulator to see it)"
	scripts/gen-app-project.sh >/dev/null || fail "xcodegen failed"
	xcodebuild -project app/perfectdark.xcodeproj -scheme perfectdark \
		-configuration Debug -sdk iphonesimulator \
		-destination "platform=iOS Simulator,id=$SIM" \
		-derivedDataPath build/dd-sim CODE_SIGNING_ALLOWED=NO build \
		> "$WORK/xcodebuild.log" 2>&1 || { tail -40 "$WORK/xcodebuild.log"; fail "xcodebuild failed"; }
	echo "built"
fi

# Pinned, not `find | head -1`: a stale product elsewhere in DerivedData is
# exactly how a green run validates yesterday's binary.
APP="build/dd-sim/Build/Products/Debug-iphonesimulator/perfectdark.app"
[ -d "$APP" ] || fail "no app at $APP"
BUILT_VER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Info.plist")"
BUILT_SHORT="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Info.plist")"
echo "app $BUILT_SHORT build $BUILT_VER"

# ---------------------------------------------------------------------------
step "boot + install"

xcrun simctl bootstatus "$SIM" -b >/dev/null 2>&1 || fail "could not boot $SIM"
xcrun simctl terminate "$SIM" "$BUNDLE" >/dev/null 2>&1 || true
xcrun simctl install "$SIM" "$APP" || fail "install failed"

# The Data container UUID changes on every reinstall — re-resolve it, never
# cache it across an install (docs/build.md §Traps).
CONT="$(xcrun simctl get_app_container "$SIM" "$BUNDLE" data)"
[ -d "$CONT" ] || fail "no data container"
DOCS="$CONT/Documents"
mkdir -p "$DOCS"

cp -f "$ROM" "$DOCS/pd.ntsc-final.z64"

if [ "$DO_XBLA" = "1" ]; then
	# The player's own copy, exactly as it came, in exactly the folder the
	# Files app shows them. Not pre-unpacked and not flattened: the whole point
	# of the run is that the app does that itself, through patch 0001's scan
	# depth (the user's .rar stores the package four names deep).
	mkdir -p "$DOCS/added-content"
	cp -f "$XBLA_ARCHIVE" "$DOCS/added-content/"
	echo "  pushed $(basename "$XBLA_ARCHIVE") into Documents/added-content"
fi

# A seeded pd.ini, because a container inherits whatever the last run wrote and
# an A/B against an unknown ini is not an A/B. VSync off (the display link is
# the pacer, docs/pacing.md) and all five XBLA rows off unless an XBLA run was
# asked for — the container has no package, and four of the five default to on.
XBLA_ROWS=0
[ "$DO_XBLA" = "1" ] && XBLA_ROWS=1
cat > "$DOCS/pd.ini" <<EOF
[Video]
VSync=0
FramerateLimit=0
DisplayFPS=0
[Mod]
XblaMeshes=$XBLA_ROWS
XblaMeshTextures=$XBLA_ROWS
XblaStages=$XBLA_ROWS
XblaFont=$XBLA_ROWS
XblaExplosions=$XBLA_ROWS
EOF
rm -f "$DOCS/pd.log" "$DOCS/crash.txt" "$DOCS/pd.args"
rm -rf "$DOCS/screenshots"
# An installed texture pack lives in the DATA container and survives a
# reinstall, and the shell selects one when nothing is selected (D-024). A pack
# left behind by a manual session would have the replay drawing a different
# game than the oracle reference, by design and without saying so.
if [ -d "$DOCS/texture-packs" ] && [ -n "$(ls -A "$DOCS/texture-packs" 2>/dev/null)" ]; then
	echo "  clearing Documents/texture-packs ($(ls -A "$DOCS/texture-packs" | tr '\n' ' '))"
	rm -rf "$DOCS/texture-packs"
fi
echo "container $CONT"

# ---------------------------------------------------------------------------
step "launch (twice — the first after a fresh boot races SpringBoard)"

SIMCTL_CHILD_PD_BRIDGE_PORT="$PORT" xcrun simctl launch "$SIM" "$BUNDLE" --skip-intro >/dev/null 2>&1 || true
sleep 6
xcrun simctl terminate "$SIM" "$BUNDLE" >/dev/null 2>&1 || true
sleep 1

# --log on an XBLA run: the three "the package was read" assertions are log
# lines (xblamesh/xblatex/xblastage) and upstream writes pd.log only under it.
LAUNCH_FLAGS="--skip-intro"
[ "$DO_XBLA" = "1" ] && LAUNCH_FLAGS="--skip-intro --log"

# The cache is wiped HERE and not before the warm-up launch: the warm-up runs
# for six seconds, and the release's archive is barely compressed, so the
# warm-up was finishing the whole 248 MB unpack and leaving the measured run
# with nothing to measure. Wiped now, the run under test is the one that does
# it — which is also the path the OS purging Caches puts a player on.
if [ "$DO_XBLA" = "1" ]; then
	rm -rf "$CONT/Library/Caches/cache/xbla"
	echo "  Caches/cache/xbla wiped — this run does the unpack"
fi

( SIMCTL_CHILD_PD_BRIDGE_PORT="$PORT" xcrun simctl launch --console-pty "$SIM" "$BUNDLE" $LAUNCH_FLAGS > "$CONSOLE" 2>&1 & )

# ---------------------------------------------------------------------------
if [ "$DO_XBLA" = "1" ]; then
	step "XBLA: the one-time unpack, and the release's own art"

	# Footprint while the extraction is running, which is the number that
	# decides whether a phone survives it (docs/memory-math.md, D-011).
	( for i in $(seq 1 400); do
		bridge state | awk -F= '
			$1=="footprint_mb" {f=$2}
			$1=="xbla_unpacking" {u=$2}
			$1=="xbla_unpack_pct" {p=$2}
			END {if (u != "") print u, f, p}'
		sleep 2
	  done ) > "$WORK/xbla-footprint.txt" 2>/dev/null &
	FOOTPID=$!

	# The bridge comes up inside pdSDLMain, a few seconds after launch and
	# BEFORE the unpack (pd_ios_main.m) - so wait for it to answer at all
	# before asking it to wait for anything.
	for i in $(seq 1 60); do
		[ -n "$(bridge state)" ] && break
		sleep 1
	done

	UNPACK="$(bridge 'xbla wait 900')"
	kill "$FOOTPID" 2>/dev/null || true
	echo "$UNPACK" | sed 's/^/  /'
	echo "$UNPACK" > "$WORK/xbla-unpack.txt"
	case "$UNPACK" in
		*xbla_extracted=1*) ;;
		*) fail "the XBLA package never unpacked: $UNPACK" ;;
	esac

	# Where it landed: Caches, not Documents. Patch 0009 routes the engine's
	# cache/ through the $C placeholder, and the whole reason is that 250 MB of
	# regenerable unpack must not be in the player's backed-up folder.
	CACHE_XBLA="$CONT/Library/Caches/cache/xbla"
	[ -f "$CACHE_XBLA/.extracted" ] || fail "no .extracted marker in $CACHE_XBLA — the unpack did not go to Caches"
	CACHE_MB=$(du -sm "$CACHE_XBLA" | cut -f1)
	echo "  Caches/cache/xbla = ${CACHE_MB} MB, marker present"
	[ "$CACHE_MB" -gt 200 ] || fail "the unpack is only ${CACHE_MB} MB — the package is ~250 MB"
	if [ -d "$DOCS/cache" ]; then
		fail "cache/ appeared in Documents — patch 0009's \$C routing regressed"
	fi

	# The peak footprint the poller saw while xbla_unpacking was 1.
	XBLA_PEAK=$(awk '$1==1 {if ($2+0 > m) m=$2+0} END {printf "%.1f", m+0}' "$WORK/xbla-footprint.txt" 2>/dev/null || echo 0)
	XBLA_SAMPLES=$(wc -l < "$WORK/xbla-footprint.txt" | tr -d ' ')
	echo "  peak footprint during the unpack: ${XBLA_PEAK} MB over ${XBLA_SAMPLES} samples"

fi

# The bridge answering IS the liveness test: it only answers from a frame
# boundary, so a reply means the game loop is turning.
STATE=""
for i in $(seq 1 60); do
	sleep 2
	STATE="$(bridge state)"
	case "$STATE" in *engine=running*) break ;; esac
done
[ -n "$STATE" ] || fail "console bridge :$PORT never answered (is this a PD_PUBLIC build?)"
case "$STATE" in *frames=*) ;; *) fail "bridge answered but the engine never reached a frame: $STATE" ;; esac
echo "$STATE" | sed 's/^/  /'
echo "$STATE" > "$WORK/state-boot.txt"

get() { echo "$STATE" | awk -F= -v k="$1" '$1==k {print $2; exit}'; }

# ---------------------------------------------------------------------------
step "assert: native resolution"

NATIVE="$(get native_resolution)"
[ "$NATIVE" = "OK" ] || fail "drawable is not native: $(get drawable) vs $(get expect_drawable) (points $(get points) x scale $(get contents_scale))"
echo "  drawable $(get drawable) == points $(get points) x scale $(get contents_scale)"

# ---------------------------------------------------------------------------
step "assert: the frame has content"

SHOT="$WORK/content.png"
rm -f "$SHOT"
REPLY="$(bridge "screenshot $DOCS/validate-content.png")"
echo "  $REPLY"
case "$REPLY" in screenshot=*) ;; *) fail "screenshot command failed: $REPLY" ;; esac
cp "$DOCS/validate-content.png" "$SHOT" || fail "no screenshot file"

python3 - "$SHOT" <<'PY' || fail "the frame is blank or near-monochrome"
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB").resize((160, 160))
px = list(im.getdata())
bright = sum(1 for r, g, b in px if r + g + b > 120)
colours = len(set(px))
print(f"  bright={bright}/25600 colours={colours}")
sys.exit(0 if bright >= 300 and colours >= 200 else 1)
PY

# ---------------------------------------------------------------------------
step "assert: the touch layer is reachable"

# simctl's injected events bypass UIKit entirely and `idb ui tap` is dead on
# iOS 27, so this goes through the bridge — which also reports WHAT was under
# the point, so the assertion is "the FIRE button is where it should be", not
# "something happened".
# The simulator reports a virtual "Gamepad", so the overlay's auto mode hides
# itself here. Force it on for the test — the same setting the settings page
# writes.
echo "  $(bridge 'touch on')"

W="$(get points | cut -dx -f1)"
H="$(get points | cut -dx -f2)"
[ -n "$W" ] && [ -n "$H" ] || fail "no points size in state"

# FIRE sits at unit 0.8609, 0.7240 of the FULL view (PDTouchOverlay.m kButtons,
# which is bean's tuned table — D-032). Safe-area insets shift it a little; the
# hit radius is the drawn radius x 1.25, so the nominal point is well inside it
# and a MISS here is a real layout regression.
FIRE_X=$(python3 -c "print(int(0.8609*$W))")
FIRE_Y=$(python3 -c "print(int(0.7240*$H))")
HIT="$(bridge "tap $FIRE_X $FIRE_Y")"
echo "  tap $FIRE_X,$FIRE_Y -> $HIT"
case "$HIT" in
	*MISS*) fail "a tap on the touch layer did not land: $HIT" ;;
	*button:FIRE*) ;;
	*) fail "the tap landed somewhere unexpected: $HIT (wanted button:FIRE)" ;;
esac

# Clear of the stick zone (left 45%) and of the button cluster (right edge,
# lower half): the upper middle of the look zone.
DRAG_X=$(python3 -c "print(int(0.52*$W))")
DRAG_Y=$(python3 -c "print(int(0.25*$H))")
DRAGHIT="$(bridge "drag $DRAG_X $DRAG_Y 120 0")"
echo "  drag -> $DRAGHIT"
case "$DRAGHIT" in
	*look*look_deg=*) ;;
	*) fail "a drag on the look zone produced no look degrees: $DRAGHIT" ;;
esac

# ---------------------------------------------------------------------------
step "assert: the pacer and the engine agree on a rate, and the cadence is even"

# D-034. Two things can be asserted on a simulator and both matter:
#   1. the ENGINE's tick gate matches the rate the pacer is asking the panel
#      for - a 120 Hz link over a 60 Hz-gated engine presents at 60 and burns
#      every other callback, which is what 0.0.0.6 shipped;
#   2. consecutive presents are evenly spaced.
# Absolute rates from a simulator mean nothing (and UIScreen reports
# maximumFramesPerSecond = 60 for EVERY simulated device, ProMotion included),
# so what is asserted is the relationship, not the number.
PACE_TARGET="$(get pacing_target)"
PACE_ENGINE="$(get pacing_engine_hz)"
[ "$PACE_TARGET" = "$PACE_ENGINE" ] \
	|| fail "the pacer wants ${PACE_TARGET} Hz and the engine ticks at ${PACE_ENGINE} Hz"
# D-043 REPLACES D-034's half of this. The gate used to demand divisor 1 at
# 60 Hz, "so the engine's gate matches the panel". It must be 0 at EVERY rate on
# iOS: with it at 1 the engine's tick gate is a wait loop that parks the MAIN
# thread in nanosleep() at the top of the frame - the same thread that is this
# app's UIKit thread - and UIKit stops delivering touches entirely while
# hit-testing, the windows and the bridge all stay perfect. That is the bug
# the user hit three builds running, and it is a second wait on the one clock
# docs/pacing.md allows.
TICKDIV="$(bridge 'cfg get Game.TickRateDivisor')"
case "$TICKDIV" in
	Game.TickRateDivisor=0) ;;
	*) fail "$TICKDIV at ${PACE_ENGINE} Hz — the engine's tick gate must be OFF on iOS (D-043); at 1 it parks the main thread and kills touch delivery" ;;
esac
echo "  pacer ${PACE_TARGET} Hz, engine ${PACE_ENGINE} Hz, $TICKDIV"

bridge "pacing reset" >/dev/null
sleep 10
PACING="$(bridge pacing)"
echo "$PACING" | sed 's/^/  /'
echo "$PACING" > "$WORK/pacing.txt"
pget() { echo "$PACING" | awk -F= -v k="$1" '$1==k {print $2; exit}'; }
[ "$(pget frame_cadence)" = "even" ] \
	|| fail "the present cadence is $(pget frame_cadence): p50 $(pget frame_ms_p50) ms, p95 $(pget frame_ms_p95), jitter $(pget frame_ms_jitter_pct)%"
# More presents than link callbacks means the pacer is not the pacer
# (docs/pacing.md §Verification) - the one assertion that catches a display
# link that has stopped being the clock.
[ "$(pget pacing_presents)" -le "$(pget pacing_links)" ] \
	|| fail "presents $(pget pacing_presents) > links $(pget pacing_links) — the display link is not the pacer"

# ---------------------------------------------------------------------------
step "assert: a deep link is parsed and consumed in the frame hook"

# The delivery half cannot be scripted on iOS 27: `simctl openurl` raises an
# "Open in Perfect Dark?" confirmation nothing can tap (idb ui tap is dead,
# injected events bypass UIKit). That dialog IS the proof the scheme resolves to
# this app; what is asserted here is the half that is ours - the queue, the
# parse and the consumption at a frame boundary.
bridge "link perfectdark://stage/0x26" >/dev/null
sleep 6
LSTATE="$(bridge state)"
LSTAGE="$(echo "$LSTATE" | awk -F= '$1=="stage" {print $2}')"
echo "  stage after the link: $LSTAGE"
[ "$LSTAGE" = "0x26" ] || fail "a perfectdark://stage/0x26 link did not change the stage (got $LSTAGE)"

# ---------------------------------------------------------------------------
step "assert (D-037): the gear on a pad pause, the double-flick roll, the pad coming back"

# The deep link above put us in a real stage, so there is a player standing
# somewhere - which is the only state in which any of this can be asserted.
qstate() { QS="$(bridge state)"; }
qget() { echo "$QS" | awk -F= -v k="$1" '$1==k {print $2; exit}'; }

# AUTO, not "on": the bug only exists while the layer is HIDDEN, which with a
# pad connected is a pad player's permanent state. The simulator reports a
# virtual "Gamepad", so auto hides it here exactly as a real controller does.
echo "  $(bridge 'touch auto')"
sleep 1
qstate
[ "$(qget touch_hidden)" = "1" ] \
	|| fail "auto mode did not hide the layer — this step has to run with it hidden"

# PD's front end puts up its own dialog (Choose Your Reality / Game Pak) a few
# seconds after a stage change; A dismisses it. Bounded, and it is not a
# failure if there was nothing to dismiss.
for i in 1 2 3 4 5; do
	qstate
	[ "$(qget menu_open)" = "0" ] && break
	bridge 'pad a down' >/dev/null; sleep 1; bridge 'pad a up' >/dev/null; sleep 2
done
qstate
[ "$(qget menu_open)" = "0" ] || fail "could not get to a menu-free frame after the deep link"
[ "$(qget player_pos)" != "none" ] && [ -n "$(qget player_pos)" ] \
	|| fail "no player after the deep link — the gear assertions need gameplay"

# 1. Hidden in live gameplay (400 ms of hysteresis, so give it a moment).
sleep 2
qstate
[ "$(qget gear_hidden)" = "1" ] || fail "the gear is still up in live gameplay (gear_hidden=$(qget gear_hidden))"
echo "  gameplay: touch_hidden=1, gear_hidden=1, player at $(qget player_pos)"

# 2. Pause on the PAD, which is the user's report: the gear must come back. Before
#    D-037 it could not, because the predicate only ran from -publish and
#    +publishInput returns before -publish whenever the layer is hidden - which
#    with a controller connected is always.
for i in 1 2 3; do
	bridge 'pad start down' >/dev/null
	sleep 1
	bridge 'pad start up' >/dev/null
	sleep 3
	qstate
	[ "$(qget menu_open)" = "1" ] && break
done
[ "$(qget menu_open)" = "1" ] || fail "Start on the pad did not open the pause menu (menu_open=$(qget menu_open))"
[ "$(qget gear_hidden)" = "0" ] || fail "the gear did NOT come back on a pad pause — the user's report, D-037"
echo "  paused on the pad: menu_open=1, gear_hidden=0"
bridge state > "$WORK/q-gear-paused.txt"
xcrun simctl io "$SIM" screenshot "$WORK/q-gear-paused.png" >/dev/null 2>&1 || true

# 3. ...and goes away again when play resumes. B is Cancel at the pause root.
for b in b start b; do
	bridge "pad $b down" >/dev/null; sleep 1; bridge "pad $b up" >/dev/null; sleep 2
	qstate
	[ "$(qget menu_open)" = "0" ] && break
done
[ "$(qget menu_open)" = "0" ] || fail "could not unpause from the pad"
sleep 2
qstate
[ "$(qget gear_hidden)" = "1" ] || fail "the gear stayed up after unpausing (gear_hidden=$(qget gear_hidden))"
echo "  unpaused: menu_open=0, gear_hidden=1"

# 4. The roll. R3 is no longer bound to it; a double FLICK of the left stick is.
#    Position is the instrument, as it was for the touch double-tap (D-032).
px() { echo "$QS" | awk -F= '$1=="player_pos" {split($2,a,","); print a[1]; exit}'; }
qstate; X0="$(px)"
bridge 'pad flick right' > "$WORK/q-flick-right.txt"
sed 's/^/  /' "$WORK/q-flick-right.txt"
grep -q 'ROLL RIGHT' "$WORK/q-flick-right.txt" || fail "a right double flick did not start a roll"
sleep 2
qstate; X1="$(px)"
bridge 'pad flick left' > "$WORK/q-flick-left.txt"
sed 's/^/  /' "$WORK/q-flick-left.txt"
grep -q 'ROLL LEFT' "$WORK/q-flick-left.txt" || fail "a left double flick did not start a roll"
sleep 2
qstate; X2="$(px)"
echo "  player x: $X0 -> $X1 (right) -> $X2 (left)"
python3 - "$X0" "$X1" "$X2" <<'PY' || fail "the double-flick rolls did not move the player both ways"
import sys
x0, x1, x2 = (float(v) for v in sys.argv[1:4])
# Which way "right" moves depends on the facing, so what is asserted is that
# each roll MOVED the player and that the two went opposite ways - which is the
# thing a wrong direction would break.
d1, d2 = x1 - x0, x2 - x1
print(f"  right moved {d1:+.1f}, left moved {d2:+.1f}")
sys.exit(0 if abs(d1) > 20 and abs(d2) > 20 and (d1 * d2) < 0 else 1)
PY

# 5. A SINGLE flick does not roll, and a HELD stick does not roll. Both are the
#    reason the gesture is out-back-out rather than "past a threshold twice".
SINGLE="$(printf 'pad lx 0.9\npad lx 0.0\n' | nc -w 8 localhost "$PORT" 2>/dev/null)"
echo "$SINGLE" | sed 's/^/  single: /'
case "$SINGLE" in *ROLL*) fail "a single flick rolled" ;; esac
# More than the 300 ms window before the next probe, or the single flick above
# IS the first half of the double flick below - which is the gesture working,
# not a held stick rolling. (It failed exactly that way the first time.)
sleep 2
HELD="$(printf 'pad lx 0.9\npad lx 0.95\npad lx 0.9\npad lx 0.99\npad lx 0.0\n' | nc -w 8 localhost "$PORT" 2>/dev/null)"
echo "$HELD" | sed 's/^/  held: /'
case "$HELD" in *ROLL*) fail "a held stick rolled" ;; esac

# 6. The pad going away must give the touch layer back ALIVE, not just visible.
echo "  $(bridge 'touch auto')"
FAKEON="$(bridge 'pad fake on')"
echo "  $FAKEON"
case "$FAKEON" in *overlay_hidden=1*) ;; *) fail "a connected pad did not hide the chips: $FAKEON" ;; esac
FAKEOFF="$(bridge 'pad fake off')"
echo "  $FAKEOFF"
case "$FAKEOFF" in *overlay_hidden=0*) ;; *) fail "removing the pad did not bring the chips back: $FAKEOFF" ;; esac
case "$FAKEOFF" in *overlay_interactive=1*) ;; *) fail "the chips came back with interaction off: $FAKEOFF" ;; esac
case "$FAKEOFF" in *overlay_in_window=1*) ;; *) fail "the chips came back detached from the window: $FAKEOFF" ;; esac

# ...and a press must actually REACH the engine, which is the half the user's
# report was about: "they did come back... but then none of them worked."
# The hold is explicit: `tap` releases after 140 ms by default, which is gone
# before a second `nc` round trip can look at it. touch_sent_mask is the proof -
# it is what the shell last HANDED THE ENGINE, not what it is holding.
BACKHIT="$(bridge "tap $FIRE_X $FIRE_Y 2500")"
echo "  tap after the pad went away -> $BACKHIT"
case "$BACKHIT" in *button:FIRE*) ;; *) fail "a tap after the pad went away did not land on FIRE: $BACKHIT" ;; esac
# One frame of slack: `state` is served from drainQueue, which runs BEFORE
# +publishInput in the frame hook, so touch_sent_mask read in the same turn is
# still the previous frame's.
sleep 1
qstate
[ "$(qget touch_sent_mask)" != "0x0" ] \
	|| fail "FIRE was pressed after the pad went away and nothing reached the engine (touch_sent_mask=$(qget touch_sent_mask))"
echo "  the press reached the engine: touch_sent_mask=$(qget touch_sent_mask)"
sleep 3
bridge 'pad fake auto' >/dev/null
echo "  $(bridge 'touch on')"

# ---------------------------------------------------------------------------
step "assert: settings page comes up and persists a value"

bridge "settings" >/dev/null
sleep 1
SSTATE="$(bridge state)"
case "$SSTATE" in *settings_page=1*) echo "  settings page is up" ;;
	*) fail "the settings page did not present" ;; esac
xcrun simctl io "$SIM" screenshot "$WORK/settings.png" >/dev/null 2>&1 || true
bridge "settings close" >/dev/null
sleep 1

# D-041: a REAL touch has to still reach the chips after the page goes away.
# Everything else this gate asserts about touch goes through the overlay's own
# model (`hit`, `tap`), which is right even when UIKit is delivering every
# finger to another window - which is exactly what the user hit twice. `windows`
# hit-tests FROM THE WINDOW, in the order UIKit consults them, so it is the one
# check that can see the failure that cost this round.
bridge "touch on" >/dev/null
WIN="$(bridge windows)"
case "$WIN" in *route_ok=1*) echo "  touch routing OK after the settings page closed" ;;
	*) printf '%s\n' "$WIN"; fail "touch routing is WRONG after a settings close (D-041)" ;; esac
case "$WIN" in *game_is_key=1*) ;;
	*) printf '%s\n' "$WIN"; fail "the game window is not key after a settings close (D-041)" ;; esac

# cfg set reports the read-back, which is the only honest check: config.c
# clamps silently.
CFG="$(bridge "cfg set Mod.EnhanceTextures 2")"
echo "  $CFG"
case "$CFG" in *Mod.EnhanceTextures=2*) ;; *) fail "cfg set did not take: $CFG" ;; esac
bridge "cfg set Mod.EnhanceTextures 1" >/dev/null

# ---------------------------------------------------------------------------
if [ "$DO_XBLA" = "1" ]; then
	step "XBLA: Chicago with the release drawing"

	# Into Chicago with the release on, and the three log lines that say each of
	# the three paths found the package (docs/oracle.md §The XBLA release).
	bridge "stage 0x1d" >/dev/null 2>&1 || true
	XSTATE=""
	for i in $(seq 1 40); do
		sleep 3
		# Keep the last state that actually came back: a level load with the
		# release's meshes in it can make one `nc` come home empty, and
		# overwriting a good answer with that turns a slow load into a failure.
		TRY="$(bridge state)"
		[ -n "$TRY" ] && XSTATE="$TRY"
		case "$XSTATE" in *stage=0x1d*) break ;; esac
	done
	case "$XSTATE" in
		*stage=0x1d*) ;;
		*) fail "never reached Chicago with the release on (last state: $(echo "$XSTATE" | tr '\n' ' '))" ;;
	esac
	printf '%s\n' "$XSTATE" > "$WORK/state-xbla.txt"
	grep -E 'xbla_|footprint|stage=' "$WORK/state-xbla.txt" | sed 's/^/  /' || true
	case "$XSTATE" in *xbla_enabled=1*) ;; *) fail "the whole-release switch is off with a package present: $(echo "$XSTATE" | grep xbla_enabled)" ;; esac
	XBLA_FOOT="$(echo "$XSTATE" | awk -F= '$1=="footprint_mb"{print $2}')"

	grep -q "xblamesh: 2616 slots" "$DOCS/pd.log" || fail "no 'xblamesh: 2616 slots' in pd.log — the mesh loader did not read the package"
	grep -q "xblatex: 5747 texture records" "$DOCS/pd.log" || fail "no 'xblatex: 5747 texture records' in pd.log — the texture path did not read the package"
	grep -q "xblastage: .* from the release" "$DOCS/pd.log" || fail "no 'xblastage: ... from the release' in pd.log — the rooms did not come from the package"
	grep -E "xblamesh: 2616 slots|xblatex: 5747 texture records|xblastage: .* from the release" "$DOCS/pd.log" | sed 's/^/  /' || true

	bridge "screenshot $DOCS/xbla-chicago.png" >/dev/null
	cp "$DOCS/xbla-chicago.png" "$WORK/xbla-chicago.png" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
step "the M-001 seeded replay, against the oracle"

bridge quit >/dev/null 2>&1 || true
sleep 3
xcrun simctl terminate "$SIM" "$BUNDLE" >/dev/null 2>&1 || true

rm -rf "$DOCS/screenshots"
rm -f "$DOCS/pd.log"
cat > "$DOCS/pd.ini" <<EOF
[Video]
VSync=0
FramerateLimit=0
DisplayFPS=0
[Mod]
XblaMeshes=$XBLA_ROWS
XblaMeshTextures=$XBLA_ROWS
XblaStages=$XBLA_ROWS
XblaFont=$XBLA_ROWS
XblaExplosions=$XBLA_ROWS
EOF

REPLAY_LOG="$WORK/replay-console.log"
# PD_IOS_RENDER_SCALE=1 renders at 844x390 instead of the panel's 2532x1170:
# the committed oracle frame is that size, and a pixel diff is only a gate at
# matched resolution (docs/build.md §Traps — aspect and size are determinism
# inputs). The native-resolution assertion above ran on a normal launch, which
# is where it belongs.
( SIMCTL_CHILD_PD_IOS_RENDER_SCALE=1 SIMCTL_CHILD_PD_BRIDGE_PORT="$PORT" xcrun simctl launch --console-pty "$SIM" "$BUNDLE" \
	--rng-seed 1234 --fixed-step --exit-frame 2000 --screenshot-frame 1500 \
	--skip-intro --no-sound --gfxstats 1 --log --boot-stage 0x1d \
	> "$REPLAY_LOG" 2>&1 & )

# --exit-frame 2000 in bypass pacing: seconds, not minutes. Waiting on the log
# is right because the process exits on its own.
for i in $(seq 1 90); do
	sleep 2
	grep -q "exit-frame 2000 reached" "$DOCS/pd.log" 2>/dev/null && break
done
grep -q "exit-frame 2000 reached" "$DOCS/pd.log" 2>/dev/null \
	|| fail "the replay never reached frame 2000 (see $DOCS/pd.log)"

grep -E '^gfx:' "$DOCS/pd.log" > "$WORK/sim.gfx" || fail "no gfx: lines in the replay log"
gunzip -c "$ORACLE_GFX" > "$WORK/oracle.gfx"

SIM_LINES=$(wc -l < "$WORK/sim.gfx")
ORA_LINES=$(wc -l < "$WORK/oracle.gfx")
echo "  gfx lines: sim $SIM_LINES, oracle $ORA_LINES"
if ! diff -q "$WORK/oracle.gfx" "$WORK/sim.gfx" >/dev/null; then
	echo "  first divergence:"
	diff "$WORK/oracle.gfx" "$WORK/sim.gfx" | head -12 | sed 's/^/    /'
	fail "the gfx stream diverged from the oracle — the replay drew a different game"
fi
echo "  gfx stream IDENTICAL to the oracle"

SIMSHOT="$(ls -t "$DOCS/screenshots"/*.png 2>/dev/null | head -1 || true)"
[ -n "$SIMSHOT" ] || fail "the replay produced no --screenshot-frame PNG"
cp "$SIMSHOT" "$WORK/replay-sim.png"

python3 - "$ORACLE_PNG" "$WORK/replay-sim.png" "$WORK/replay-diff.png" "$MAX_DELTA" "$MAX_PCT" <<'PY' || fail "the replay frame does not match the oracle"
import sys
from PIL import Image, ImageChops

a = Image.open(sys.argv[1]).convert("RGB")
b = Image.open(sys.argv[2]).convert("RGB")
if a.size != b.size:
    print(f"  SIZE MISMATCH oracle {a.size} sim {b.size}")
    sys.exit(1)

diff = ImageChops.difference(a, b)
bbox_px = a.size[0] * a.size[1]
px = list(diff.getdata())
# More than ONE LSB, not "not identical" (round C). The visionOS simulator
# redraws the same seeded frame with a 1/255 drift on 3-8% of its pixels from
# one run of the SAME BINARY to the next - 8.26% then 3.17%, gfx stream
# byte-identical both times - so "any difference at all" straddles the
# threshold and the gate flakes. A 1/255 difference is not a picture
# difference; anything structural still has to get past max delta 16 and past
# the gfx stream diff, which is exact.
differing = sum(1 for p in px if max(p) > 1)
maxd = max((max(p) for p in px), default=0)
pct = 100.0 * differing / bbox_px
print(f"  pixels differing by >1/255: {differing}/{bbox_px} ({pct:.2f}%), max delta {maxd}/255")

# x20 so a human can see what the numbers mean.
diff.point(lambda v: min(255, v * 20)).save(sys.argv[3])

# D-068: the outlier budget. Since c18645860 upstream SEALS room seams by
# growing T-junction faces exactly half a pixel (gfx_pc.cpp gfx_seal_seams),
# which puts those edges on pixel centres - a coverage tie that ANGLE-Metal and
# desktop GL break differently, so isolated edge pixels flip between the wall
# and whatever is behind it (measured: 24-50 pixels, <0.008% of the frame,
# no group larger than 4, max 54-100/255; 16 of iOS's 25 sit exactly on a
# pixel the sealing changes, and there the sim matches the UNSEALED oracle).
# A max-delta test cannot tell that from a broken frame, so it no longer
# decides alone: pixels over MAX_DELTA are allowed up to OUTLIER_PCT of the
# frame, and only as specks - any 8-connected group larger than
# OUTLIER_GROUP pixels fails, as does anything over the budget. A missing
# texture, a wrong glyph or a shifted HUD is thousands of pixels in groups of
# hundreds; the gfx stream above stays exact.
OUTLIER_PCT = 0.02
OUTLIER_GROUP = 16
w, h = a.size
over = set()
for i, p in enumerate(px):
    if max(p) > int(sys.argv[4]):
        over.add((i % w, i // w))
seen = set()
largest = 0
for q in over:
    if q in seen:
        continue
    stack = [q]
    seen.add(q)
    n = 0
    while stack:
        x, y = stack.pop()
        n += 1
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                r = (x + dx, y + dy)
                if r in over and r not in seen:
                    seen.add(r)
                    stack.append(r)
    largest = max(largest, n)
over_pct = 100.0 * len(over) / (w * h)
print(f"  pixels over {sys.argv[4]}/255: {len(over)} ({over_pct:.4f}%), largest group {largest} px")

ok = pct <= float(sys.argv[5]) and over_pct <= OUTLIER_PCT and largest <= OUTLIER_GROUP
if not ok:
    print(f"  OVER THRESHOLD (>1/255 on at most {sys.argv[5]}%; over {sys.argv[4]}/255 on at most "
          f"{OUTLIER_PCT}% in groups of at most {OUTLIER_GROUP} px - D-068)")
sys.exit(0 if ok else 1)
PY

# ---------------------------------------------------------------------------
step "error scan"

SCAN="$WORK/scan.txt"
cat "$CONSOLE" "$REPLAY_LOG" "$DOCS/pd.log" > "$SCAN" 2>/dev/null || true
BAD="$(grep -nEi 'unknown gbi|EGL_BAD|egl error|eglMakeCurrent .*failed|Fatal|assertion failed|Could not create an ANGLE|shader (compile|link) (error|failed)' "$SCAN" | head -10 || true)"
if [ -n "$BAD" ]; then
	echo "$BAD" | sed 's/^/  /'
	fail "the log contains errors"
fi
if [ -f "$DOCS/crash.txt" ]; then
	head -20 "$DOCS/crash.txt" | sed 's/^/  /'
	fail "Documents/crash.txt exists — something crashed"
fi
[ -f "$DOCS/launch-beacon.txt" ] || fail "no launch beacon — the shell did not start"
echo "  clean: no GBI/EGL/shader errors, no crash.txt, beacon present"

# ---------------------------------------------------------------------------
step "PASSED"

SUFFIX=""
[ "$DO_XBLA" = "1" ] && SUFFIX="-xbla"
STAMP="$OUT/validate-$GITREV$SUFFIX.txt"
{
	echo "commit=$GITREV"
	echo "when=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "device=$SIM"
	echo "app_version=$BUILT_SHORT build=$BUILT_VER"
	echo "gfx_lines=$SIM_LINES (identical to oracle)"
	if [ "$DO_XBLA" = "1" ]; then
		echo "xbla=1 cache_mb=${CACHE_MB} unpack_peak_mb=${XBLA_PEAK} chicago_footprint_mb=${XBLA_FOOT}"
		grep -E '^xbla_unpack_secs' "$WORK/xbla-unpack.txt" 2>/dev/null || true
	fi
	cat "$WORK/pacing.txt"
	cat "$WORK/state-boot.txt"
} > "$STAMP"
# A JPEG, not the PNG: the committed evidence is "does this frame show the
# right picture", and 460 KB of lossless per run is not what artifacts/ is for.
python3 - "$WORK/replay-sim.png" "$OUT/validate-$GITREV$SUFFIX-replay.jpg" <<'PY' || true
import sys
from PIL import Image
Image.open(sys.argv[1]).convert("RGB").save(sys.argv[2], quality=80)
PY

echo "stamp: $STAMP"
echo "artifacts: $WORK/{content,settings,replay-sim,replay-diff}.png"
echo ""
echo "SIM-VALIDATE GREEN — open the screenshots and confirm they show CONTENT."
