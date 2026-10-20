#!/usr/bin/env bash
# vision-validate.sh — THE GATE, visionOS side. Nothing visionOS is published
# that has not passed this.
#
#   scripts/vision-validate.sh [--udid UDID] [--xbla] [--keep] [--no-build]
#
# A sibling of scripts/sim-validate.sh rather than a flag on it, for two
# reasons: the device, the SDK, the scheme, the bridge port and the oracle
# reference all differ, and the two run CONCURRENTLY on this machine (the iOS
# lane is another session's). Everything the two share in spirit — the assert
# list, the thresholds, the shut-down-on-any-exit trap — is deliberately
# identical, and the iOS gate is left byte-for-byte alone.
#
# It fails, loudly and non-zero, on any of:
#
#   * the build failing, or the wrong build being installed;
#   * the app not reaching a frame (the bridge answers or it does not);
#   * a drawable that is not the window's points x contentsScale;
#   * a screenshot that is blank or nearly monochrome;
#   * a bridge-injected tap that does not land on the touch layer, or a
#     left-half tap that does not raise the floating stick (the PINCH path on
#     visionOS: a pinch anywhere in the left half is the stick, no halo-only
#     targets);
#   * a gamepad button that does not reach the engine's pad mask;
#   * the M-001 chicago-solo seeded replay drawing a different gfx stream from
#     the macOS clang oracle at 1280x720, or a frame that differs from the
#     oracle's by more than 1/255 on more than 6% of pixels, or by more than
#     16/255 on more than 0.02% of them or in any group over 16 pixels (D-068);
#   * a crash, an "Unknown GBI" command, or an EGL error anywhere in the log.
#
# THE DEVICE: there is exactly ONE Apple Vision Pro simulator on this machine
# and it is shared with every other visionOS port. It is never created, and it
# is shut down at the end WHATEVER happens (trap on EXIT).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

# The ONE Apple Vision Pro (visionOS 27.0). Never `simctl create`.
SIM="${PD_VISION_SIM:-$(xcrun simctl list devices available | awk -F'[()]' '/Apple Vision Pro/{print $2; exit}')}"
BUNDLE=com.rebelancap.perfectdark
# NOT 8775: a simulator's loopback is the Mac's loopback, the iOS lane runs the
# same app with the same bridge, and one bridge per port at a time. 8785 is this
# port's visionOS number (docs/remote-console.md).
PORT="${PD_BRIDGE_PORT:-8785}"
OUT="$REPO/artifacts/sim/visionos"
WORK="$REPO/work/vision-validate"
CONSOLE="$WORK/console.log"
# The Vision Pro window is 1280x720 points at contentsScale 2, so the replay —
# run at PD_IOS_RENDER_SCALE=1 — draws 1280x720, which is the oracle's own
# native window size. Aspect and size are determinism inputs (docs/build.md
# §Traps M1), hence a reference of this port's own rather than the iPhone's.
ORACLE_PNG="$REPO/artifacts/oracle/sim-gate/chicago-solo-1280x720.png"
ORACLE_GFX="$REPO/artifacts/oracle/sim-gate/chicago-solo-1280x720.gfx.gz"
ORACLE_XBLA_PNG="$REPO/artifacts/oracle/sim-gate/chicago-xbla-1280x720.png"
ORACLE_XBLA_GFX="$REPO/artifacts/oracle/sim-gate/chicago-xbla-1280x720.gfx.gz"
ROM="$REPO/work/gamedata/pd.ntsc-final.z64"
XBLA_ARCHIVE="$REPO/work/gamedata/Perfect Dark.rar"

# The same thresholds as the iOS gate (M-009: 4.41% of pixels differing by at
# most 7/255 is ANGLE-Metal's shader compiler, not a port defect).
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

fail() { echo ""; echo "VISION-VALIDATE FAILED: $*" >&2; exit 1; }
step() { echo ""; echo "=== $* ==="; }

cleanup() {
	local rc=$?
	xcrun simctl terminate "$SIM" "$BUNDLE" >/dev/null 2>&1 || true
	if [ "$KEEP" != "1" ]; then
		xcrun simctl shutdown "$SIM" >/dev/null 2>&1 || true
		echo "Apple Vision Pro $SIM shut down"
	fi
	exit $rc
}
# Registered before anything can fail: a failed run still shuts the one shared
# headset simulator down.
trap cleanup EXIT

mkdir -p "$WORK" "$OUT"
: > "$CONSOLE"

bridge() {
	printf '%s\n' "$*" | nc -w 8 localhost "$PORT" 2>/dev/null || true
}

# `nc -w 8` comes home EMPTY whenever the game thread is busy for longer than
# the timeout — a level load, a big screenshot readback, the Vision Pro
# simulator's 20 fps. An empty answer is not a failure, it is a retry
# (docs/build.md §Traps XBLA). Everything that asserts on a reply goes through
# this; the plain `bridge` stays for fire-and-forget commands.
bridge_retry() {
	local out=""
	for _i in 1 2 3 4 5 6; do
		out="$(bridge "$@")"
		[ -n "$out" ] && { printf '%s' "$out"; return 0; }
		sleep 3
	done
	return 0
}

# ---------------------------------------------------------------------------
step "preflight"

[ -f "$ROM" ] || fail "no ROM at $ROM (work/gamedata-PROVENANCE.md)"
[ -f "$ORACLE_PNG" ] || fail "no oracle reference frame at $ORACLE_PNG"
[ -f "$ORACLE_GFX" ] || fail "no oracle reference gfx stream at $ORACLE_GFX"
if [ "$DO_XBLA" = "1" ]; then
	[ -f "$XBLA_ARCHIVE" ] || fail "no XBLA archive at $XBLA_ARCHIVE (work/gamedata-PROVENANCE.md)"
	[ -f "$ORACLE_XBLA_PNG" ] || fail "no oracle XBLA reference at $ORACLE_XBLA_PNG (docs/oracle.md)"
	[ -f "$ORACLE_XBLA_GFX" ] || fail "no oracle XBLA gfx stream at $ORACLE_XBLA_GFX"
	ORACLE_PNG="$ORACLE_XBLA_PNG"
	ORACLE_GFX="$ORACLE_XBLA_GFX"
	OUT="$OUT/xbla"
	mkdir -p "$OUT"
fi
command -v nc >/dev/null || fail "no nc(1)"
python3 -c 'import PIL' 2>/dev/null || fail "python3 Pillow is needed for the pixel gate"

# There is ONE Vision Pro. If another session has it, this run must not fight
# for it: a second app in the foreground backgrounds the first mid-test.
BOOTED="$(xcrun simctl list devices booted | grep -c "$SIM" || true)"
# Refuse, never assume (2026-10-03: this gate took the device out from under an
# openQ4 round that had booted it between our preflight and our launch). A
# previous --keep run of OURS is re-entered with PD_VISION_REUSE=1.
if [ "$BOOTED" != "0" ] && [ "${PD_VISION_REUSE:-0}" != "1" ]; then
	fail "$SIM is already booted by someone else — wait for it to shut down, or PD_VISION_REUSE=1 if the --keep run was yours"
fi

if pgrep -fl 'Developer/usr/bin/xcodebuild|cmake --build|ninja -C' >/dev/null 2>&1; then
	echo "NOTE: another build is running on this machine:"
	pgrep -fl 'Developer/usr/bin/xcodebuild|cmake --build|ninja -C' || true
fi

GITREV="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
echo "commit $GITREV, device $SIM, bridge :$PORT"

# ---------------------------------------------------------------------------
if [ "$DO_BUILD" = "1" ]; then
	step "build"
	scripts/apply-overlay.sh >/dev/null || fail "overlay did not apply"
	scripts/build-ios.sh xrsimulator >/dev/null 2>&1 || fail "engine build failed (run scripts/build-ios.sh xrsimulator to see it)"
	scripts/gen-app-project.sh >/dev/null || fail "xcodegen failed"
	xcodebuild -project app/perfectdark.xcodeproj -scheme perfectdark-visionos \
		-configuration Debug -sdk xrsimulator \
		-destination "platform=visionOS Simulator,id=$SIM" \
		-derivedDataPath build/dd-xrsim CODE_SIGNING_ALLOWED=NO build \
		> "$WORK/xcodebuild.log" 2>&1 || { tail -40 "$WORK/xcodebuild.log"; fail "xcodebuild failed"; }
	echo "built"
fi

APP="build/dd-xrsim/Build/Products/Debug-xrsimulator/perfectdark.app"
[ -d "$APP" ] || fail "no app at $APP"
BUILT_VER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Info.plist")"
BUILT_SHORT="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Info.plist")"
echo "app $BUILT_SHORT build $BUILT_VER"

# The platform of the thing about to be installed, not the flags that built it.
# 12 = XROS_SIMULATOR. (No `exit` in the awk: it would SIGPIPE otool and
# pipefail would turn a good binary into a failed assert.)
APLAT=$(otool -l "$APP/perfectdark" 2>/dev/null | awk '/LC_BUILD_VERSION/{f=1} f&&/ platform /&&!p{print $2;p=1}')
[ "$APLAT" = "12" ] || fail "the app binary reports platform=$APLAT, expected 12 (XROS_SIMULATOR)"

# visionOS-specific bundle asserts. Each of these is a charter Phase 5 trap that
# fails silently at runtime rather than at build time.
PLIST="$APP/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :UIApplicationSceneManifest:UIApplicationSupportsMultipleScenes' "$PLIST" 2>/dev/null \
	| grep -qi true || fail "UIApplicationSupportsMultipleScenes is not true INSIDE UIApplicationSceneManifest"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$PLIST" >/dev/null 2>&1 \
	|| fail "no CFBundleIconName — the visionOS icon will be blank"
[ -f "$APP/Assets.car" ] || fail "no Assets.car — the layered icon did not compile"
echo "  plist OK: scene manifest, CFBundleIconName, Assets.car"

# ---------------------------------------------------------------------------
step "boot + install"

xcrun simctl bootstatus "$SIM" -b >/dev/null 2>&1 || fail "could not boot $SIM"
xcrun simctl terminate "$SIM" "$BUNDLE" >/dev/null 2>&1 || true
xcrun simctl install "$SIM" "$APP" || fail "install failed"

# Re-resolved after every install: the Data container UUID changes.
CONT="$(xcrun simctl get_app_container "$SIM" "$BUNDLE" data)"
[ -d "$CONT" ] || fail "no data container"
DOCS="$CONT/Documents"
mkdir -p "$DOCS"

cp -f "$ROM" "$DOCS/pd.ntsc-final.z64"

if [ "$DO_XBLA" = "1" ]; then
	mkdir -p "$DOCS/added-content"
	cp -f "$XBLA_ARCHIVE" "$DOCS/added-content/"
	echo "  pushed $(basename "$XBLA_ARCHIVE") into Documents/added-content"
fi

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
echo "container $CONT"

# ---------------------------------------------------------------------------
step "launch (twice — the first after a fresh boot races the shell)"

SIMCTL_CHILD_PD_BRIDGE_PORT="$PORT" xcrun simctl launch "$SIM" "$BUNDLE" --skip-intro >/dev/null 2>&1 || true
sleep 8
xcrun simctl terminate "$SIM" "$BUNDLE" >/dev/null 2>&1 || true
sleep 1

LAUNCH_FLAGS="--skip-intro"
[ "$DO_XBLA" = "1" ] && LAUNCH_FLAGS="--skip-intro --log"

if [ "$DO_XBLA" = "1" ]; then
	rm -rf "$CONT/Library/Caches/cache/xbla"
	echo "  Caches/cache/xbla wiped — this run does the unpack"
fi

( SIMCTL_CHILD_PD_BRIDGE_PORT="$PORT" xcrun simctl launch --console-pty "$SIM" "$BUNDLE" $LAUNCH_FLAGS \
	> "$CONSOLE" 2>&1 & )

# ---------------------------------------------------------------------------
if [ "$DO_XBLA" = "1" ]; then
	step "XBLA: the one-time unpack, and the release's own art"

	for i in $(seq 1 60); do
		[ -n "$(bridge state)" ] && break
		sleep 1
	done

	UNPACK="$(bridge 'xbla wait 900')"
	echo "$UNPACK" | sed 's/^/  /'
	echo "$UNPACK" > "$WORK/xbla-unpack.txt"
	case "$UNPACK" in
		*xbla_extracted=1*) ;;
		*) fail "the XBLA package never unpacked: $UNPACK" ;;
	esac

	CACHE_XBLA="$CONT/Library/Caches/cache/xbla"
	[ -f "$CACHE_XBLA/.extracted" ] || fail "no .extracted marker in $CACHE_XBLA — the unpack did not go to Caches"
	CACHE_MB=$(du -sm "$CACHE_XBLA" | cut -f1)
	echo "  Caches/cache/xbla = ${CACHE_MB} MB, marker present"
	[ "$CACHE_MB" -gt 200 ] || fail "the unpack is only ${CACHE_MB} MB — the package is ~250 MB"
	if [ -d "$DOCS/cache" ]; then
		fail "cache/ appeared in Documents — patch 0009's \$C routing regressed"
	fi
fi

# The bridge answers only from a frame boundary: a reply IS the liveness test.
# `engine=running` alone is NOT enough to screenshot on: it is set before
# pdEngineMain() and the first frames of a fresh container are a black screen
# while the ROM is read and the front end builds itself. The Vision Pro
# simulator draws at ~20 fps, so wait for real frames, not for a flag.
STATE=""
for i in $(seq 1 90); do
	sleep 2
	TRY="$(bridge state)"
	[ -n "$TRY" ] && STATE="$TRY"
	FR="$(echo "$STATE" | awk -F= '$1=="frames"{print $2}')"
	case "$STATE" in *engine=running*) [ "${FR:-0}" -ge 120 ] && break ;; esac
done
[ -n "$STATE" ] || fail "console bridge :$PORT never answered (is this a PD_PUBLIC build?)"
case "$STATE" in *frames=*) ;; *) fail "bridge answered but the engine never reached a frame: $STATE" ;; esac
echo "$STATE" | sed 's/^/  /'
echo "$STATE" > "$WORK/state-boot.txt"

get() { echo "$STATE" | awk -F= -v k="$1" '$1==k {print $2; exit}'; }

# ---------------------------------------------------------------------------
step "assert: the drawable follows the window"

# The M1 trap with a visionOS face: ANGLE recomputes the drawable from the
# CAMetalLayer's bounds x contentsScale every frame, so the only honest
# assertion is that the three agree. On the Vision Pro simulator the window is
# 1280x720 points at scale 2 -> a 2560x1440 drawable.
NATIVE="$(get native_resolution)"
[ "$NATIVE" = "OK" ] || fail "drawable is not the window's pixel count: $(get drawable) vs $(get expect_drawable) (points $(get points) x scale $(get contents_scale))"
echo "  drawable $(get drawable) == points $(get points) x scale $(get contents_scale)"

# ---------------------------------------------------------------------------
step "assert: the audio session is .playback"

# The charter's Phase 5 trap: .playback enforced and re-applied (SDL sets
# .ambient, which the Ring/Silent switch mutes on iOS and which is the wrong
# category for a game on the headset either way).
case "$(get audio_category)" in
	AVAudioSessionCategoryPlayback) echo "  category .playback, applied=$(get audio_applied)" ;;
	*) fail "audio session category is $(get audio_category), expected .playback" ;;
esac

# ---------------------------------------------------------------------------
step "assert: the pacer and the engine agree on a rate, and the cadence is even"

# D-034, the same assertion the iOS gate makes. On the headset the panel is
# 90 Hz and PDVisionMaxFPS() reports it as such, so the target resolves to 60
# and Game.TickRateDivisor stays at 1; what is being asserted is that the two
# still AGREE, and that presents are evenly spaced.
PACE_TARGET="$(get pacing_target)"
PACE_ENGINE="$(get pacing_engine_hz)"
[ "$PACE_TARGET" = "$PACE_ENGINE" ] \
	|| fail "the pacer wants ${PACE_TARGET} Hz and the engine ticks at ${PACE_ENGINE} Hz"
# D-043: the engine's tick gate is OFF on iOS and visionOS at EVERY rate. It
# used to be asserted as 1 at 60 Hz (D-034); that setting parks the main thread
# in nanosleep() at the top of the frame and is implicated in the touch-delivery
# failure the user hit three builds running.
TICKDIV="$(bridge 'cfg get Game.TickRateDivisor')"
case "$TICKDIV" in
	Game.TickRateDivisor=0) ;;
	*) fail "$TICKDIV at ${PACE_ENGINE} Hz — the engine's tick gate must be OFF (D-043)" ;;
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
[ "$(pget pacing_presents)" -le "$(pget pacing_links)" ] \
	|| fail "presents $(pget pacing_presents) > links $(pget pacing_links) — the display link is not the pacer"

# ---------------------------------------------------------------------------
step "assert: the frame has content"

SHOT="$WORK/content.png"
rm -f "$SHOT"
REPLY="$(bridge_retry "screenshot $DOCS/validate-content.png")"
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

# The headset's own view, which is what a human judges the window by.
xcrun simctl io "$SIM" screenshot "$WORK/window-front.png" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
step "assert: a deep link is parsed and consumed in the frame hook"

bridge "link perfectdark://stage/0x26" >/dev/null
sleep 8
LSTATE="$(bridge state)"
LSTAGE="$(echo "$LSTATE" | awk -F= '$1=="stage" {print $2}')"
echo "  stage after the link: $LSTAGE"
[ "$LSTAGE" = "0x26" ] || fail "a perfectdark://stage/0x26 link did not change the stage (got $LSTAGE)"

# ---------------------------------------------------------------------------
step "assert: settings page comes up and persists a value"

bridge "settings" >/dev/null
sleep 2
SSTATE="$(bridge state)"
case "$SSTATE" in *settings_page=1*) echo "  settings page is up" ;;
	*) fail "the settings page did not present" ;; esac
xcrun simctl io "$SIM" screenshot "$WORK/settings.png" >/dev/null 2>&1 || true
bridge "settings close" >/dev/null

CFG="$(bridge_retry "cfg set Mod.EnhanceTextures 2")"
echo "  $CFG"
case "$CFG" in *Mod.EnhanceTextures=2*) ;; *) fail "cfg set did not take: $CFG" ;; esac
bridge "cfg set Mod.EnhanceTextures 1" >/dev/null

# ---------------------------------------------------------------------------
if [ "$DO_XBLA" = "1" ]; then
	step "XBLA: Chicago with the release drawing"

	bridge "stage 0x1d" >/dev/null 2>&1 || true
	XSTATE=""
	for i in $(seq 1 40); do
		sleep 3
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
	grep -q "xblamesh: 2616 slots" "$DOCS/pd.log" || fail "no 'xblamesh: 2616 slots' in pd.log"
	grep -q "xblatex: 5747 texture records" "$DOCS/pd.log" || fail "no 'xblatex: 5747 texture records' in pd.log"
	bridge "screenshot $DOCS/xbla-chicago.png" >/dev/null
	cp "$DOCS/xbla-chicago.png" "$WORK/xbla-chicago.png" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
step "into Chicago, for the content artifact"

if [ "$DO_XBLA" != "1" ]; then
	bridge "stage 0x1d" >/dev/null 2>&1 || true
	# Chicago is the heaviest load in the game and the Vision Pro simulator
	# draws it at ~20 fps; the bridge only answers from a frame boundary, so a
	# run of empty `nc` replies here is the load, not a failure. Keep the last
	# answer that was not empty and give it a real budget.
	CSTATE=""
	for i in $(seq 1 80); do
		sleep 4
		TRY="$(bridge state)"
		[ -n "$TRY" ] && CSTATE="$TRY"
		case "$CSTATE" in *stage=0x1d*) break ;; esac
	done
	case "$CSTATE" in
		*stage=0x1d*) echo "  in Chicago" ;;
		*) fail "never reached Chicago (last state: $(echo "$CSTATE" | tr '\n' ' '))" ;;
	esac
	bridge "screenshot $DOCS/chicago.png" >/dev/null
	cp "$DOCS/chicago.png" "$WORK/chicago.png" 2>/dev/null || true
	xcrun simctl io "$SIM" screenshot "$WORK/window-chicago.png" >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
step "assert: the touch layer is reachable (the PINCH path)"

# On visionOS a pinch is delivered to the app as an ordinary UITouch at the
# gazed point, so the touch overlay IS the pinch handler — which is exactly why
# it must have no halo-only targets: a pinch anywhere in the left half has to
# raise the floating stick. simctl cannot drive a gaze-pinch, so the assertions
# go through the bridge's inject path, which enters the same -beginTouchAt:.
# In Chicago, not at the front end: with a menu up the overlay is the MENU
# layer (the engine's own dialog pointer, overlay 0019) and there is no FIRE
# button, no stick and no look zone to hit. The gate asserts the in-game layer.
echo "  $(bridge_retry 'touch on')"

W="$(get points | cut -dx -f1)"
H="$(get points | cut -dx -f2)"
[ -n "$W" ] && [ -n "$H" ] || fail "no points size in state"

# FIRE at unit 0.8609, 0.7240 of the FULL view (PDTouchOverlay.m kButtons —
# bean's tuned table, D-032); the hit radius is the drawn radius x 1.25.
FIRE_X=$(python3 -c "print(int(0.8609*$W))")
FIRE_Y=$(python3 -c "print(int(0.7240*$H))")
HIT="$(bridge_retry "tap $FIRE_X $FIRE_Y")"
echo "  tap $FIRE_X,$FIRE_Y -> $HIT"
case "$HIT" in
	*MISS*) fail "a tap on the touch layer did not land: $HIT" ;;
	*button:FIRE*) ;;
	*) fail "the tap landed somewhere unexpected: $HIT (wanted button:FIRE)" ;;
esac

# A pinch in the left half, well away from any drawn control: the floating
# stick must appear THERE. This is the "no halo-only targets" assertion.
STICK_X=$(python3 -c "print(int(0.22*$W))")
STICK_Y=$(python3 -c "print(int(0.38*$H))")
STICKHIT="$(bridge_retry "drag $STICK_X $STICK_Y 40 0")"
echo "  pinch-drag in the left half at $STICK_X,$STICK_Y -> $STICKHIT"
case "$STICKHIT" in
	*"hit=stick dragged="*) ;;
	*) fail "a left-half pinch did not raise the floating stick: $STICKHIT" ;;
esac

DRAG_X=$(python3 -c "print(int(0.52*$W))")
DRAG_Y=$(python3 -c "print(int(0.25*$H))")
DRAGHIT="$(bridge_retry "drag $DRAG_X $DRAG_Y 120 0")"
echo "  drag -> $DRAGHIT"
case "$DRAGHIT" in
	*look*look_deg=*) ;;
	*) fail "a drag on the look zone produced no look degrees: $DRAGHIT" ;;
esac

# ---------------------------------------------------------------------------
step "assert: the gamepad path reaches the engine"

# The pad is PRIMARY on visionOS and is claimed with GCEventInteraction
# (PDController.m) so its presses are not turned into gaze-pinch events. A real
# pad cannot be paired to a simulator, so what is asserted here is the half that
# is ours end to end: a button into the engine's own pad mask at a frame
# boundary, and back out again.
# The assertion is on A's OWN bit (0x8000), not on the whole mask being zero:
# the mask also carries whatever the touch layer is holding, and the FIRE tap
# above can still be down when this runs (its 80 ms hold is released on the
# main queue). "mask is 0 afterwards" passed three runs and then failed a
# fourth for exactly that reason.
padbit() { echo "$1" | sed -n 's/.*mask=0x\([0-9a-fA-F]*\).*/\1/p'; }
PAD_A=0x8000

PADDOWN="$(bridge_retry 'pad a down')"
echo "  $PADDOWN"
MDOWN="$(padbit "$PADDOWN")"
[ -n "$MDOWN" ] || fail "the pad command failed: $PADDOWN"
python3 -c "import sys; sys.exit(0 if (0x$MDOWN & $PAD_A) else 1)" \
	|| fail "pad a down did not set A (0x8000) in the engine's pad mask: $PADDOWN"

PADUP="$(bridge_retry 'pad a up')"
echo "  $PADUP"
MUP="$(padbit "$PADUP")"
[ -n "$MUP" ] || fail "the pad command failed: $PADUP"
python3 -c "import sys; sys.exit(0 if not (0x$MUP & $PAD_A) else 1)" \
	|| fail "pad a up did not clear A (0x8000): $PADUP"
grep -q "GCEventInteraction installed" "$CONSOLE" \
	|| fail "GCEventInteraction was never installed — pad presses will become gaze-pinch events"
echo "  GCEventInteraction installed (gamepad events claimed)"


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
# PD_IOS_RENDER_SCALE=1 renders 1280x720 instead of the window's 2560x1440,
# which is the committed oracle frame's size. The drawable assertion above ran
# on a normal launch, where it belongs.
( SIMCTL_CHILD_PD_IOS_RENDER_SCALE=1 SIMCTL_CHILD_PD_BRIDGE_PORT="$PORT" \
	xcrun simctl launch --console-pty "$SIM" "$BUNDLE" \
	--rng-seed 1234 --fixed-step --exit-frame 2000 --screenshot-frame 1500 \
	--skip-intro --no-sound --gfxstats 1 --log --boot-stage 0x1d \
	> "$REPLAY_LOG" 2>&1 & )

for i in $(seq 1 120); do
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
total = a.size[0] * a.size[1]
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
pct = 100.0 * differing / total
print(f"  pixels differing by >1/255: {differing}/{total} ({pct:.2f}%), max delta {maxd}/255")

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
	echo "device=$SIM (Apple Vision Pro, visionOS 27.0)"
	echo "platform=xrsimulator (Mach-O 12)"
	echo "bridge_port=$PORT"
	echo "app_version=$BUILT_SHORT build=$BUILT_VER"
	echo "gfx_lines=$SIM_LINES (identical to oracle at 1280x720)"
	cat "$WORK/pacing.txt"
	cat "$WORK/state-boot.txt"
} > "$STAMP"
python3 - "$WORK/replay-sim.png" "$OUT/validate-$GITREV$SUFFIX-replay.jpg" <<'PY' || true
import sys
from PIL import Image
Image.open(sys.argv[1]).convert("RGB").save(sys.argv[2], quality=80)
PY

echo "stamp: $STAMP"
echo "artifacts: $WORK/{content,chicago,window-front,window-chicago,replay-sim,replay-diff}.png"
echo ""
echo "VISION-VALIDATE GREEN — open the screenshots and confirm they show CONTENT."
