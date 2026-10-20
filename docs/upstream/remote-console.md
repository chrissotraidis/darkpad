# The console bridge — TCP :8775

`app/ios/PDBridge.m`. Port 8775 is this project's, per D-002 (8765–8769
HarbourMasters, 8771 realrtcw, 8772 dhewm3, 8773 GoldenEye, 8774 openQ4, 8776
RetroArch).

**One bridge per port at a time — use `PD_BRIDGE_PORT` for a second
simulator.** A simulator's loopback is the *Mac's* loopback, so an iPhone
simulator and the Vision Pro simulator both running this app both try to bind
:8775; the second one spends fifteen seconds in the bind-retry loop below and
then comes up with no console at all. Set `PD_BRIDGE_PORT` in the app's
environment to move it:

```sh
SIMCTL_CHILD_PD_BRIDGE_PORT=8785 xcrun simctl launch <udid> com.rebelancap.perfectdark
echo state | nc -w 3 localhost 8785
```

**8785 is this port's visionOS number** and is what `scripts/vision-validate.sh`
uses by default (D-027), so the iOS gate on :8775 and the visionOS gate on :8785
can run at the same time on one Mac. An out-of-range or unparseable value is
ignored with a log line and the bridge falls back to 8775.

**It exists so that a claim about this port can be checked instead of believed.**
`scripts/sim-validate.sh` — the gate every OTA passes through — is written
entirely in terms of these commands.

**It is not in public builds.** `PD_PUBLIC=1` (passed to
`scripts/gen-app-project.sh`) defines `PD_PUBLIC` for the shell sources and
`PDBridge.m` then compiles to nothing: no listener, no thread, no commands. OTA
dev builds have it on; the GitHub-release build has it off.

## Talking to it

```sh
echo state | nc -w 3 localhost 8775
printf 'cfg get Mod.EnhanceTextures\nstate\n' | nc -w 5 localhost 8775
```

Line-oriented, one reply per command, plain text. On the simulator `localhost`
is the host's own loopback, because a simulator shares the host's network stack.
On a device, use the device's tailnet name.

Concurrency rules, which are also the reason the bridge is safe:

- The listener runs on its own thread and each client gets another one.
- **No command touches the engine from a socket thread.** Anything that reads or
  writes game state is queued into `PDShell`'s frame-boundary queue (overlay
  patch 0014 calls it once per frame, just before `inputUpdate()`) and the
  socket thread waits up to 5 s for the answer. A command that reports
  `ERR engine did not reach a frame boundary` is telling you the game loop is
  wedged — which is a real result, not a bridge fault.
- UIKit commands (`tap`, `drag`, `settings`) hop to the main queue instead,
  which SDL pumps from inside the game loop.

Binding: `SO_REUSEADDR` plus **30 retries at 0.5 s**. A simulator run that was
killed leaves the port in `TIME_WAIT` for a couple of minutes, and an app that
came up silently without a bridge would fail the next validation run for
entirely the wrong reason. If it truly cannot bind it says
`GAVE UP on :8775 — no console this run` in the log and the app runs on.

## Commands

| command | what it does |
|---|---|
| `help` | the list, from the running build |
| `state` | one `key=value` per line; see below |
| `screenshot [path]` | the **game's own** frame capture (`screenshotRequest()`), taken in the pre-swap callback of the frame being drawn (`screenshot.c:174`), so it is the rendered frame, right way up, not the simulator's portrait panel. Without a path it stays in `Documents/screenshots/`; with one it is moved there. Answers `screenshot=<path> bytes=<n>` |
| `stage 0xNN` | `mainChangeToStage()` at the next frame boundary. Stage ids: upstream's `CLAUDE-notes/stage-numbers.md` (`0x26` = the Institute, `0x1d` = chicago) |
| `cfg get <Section.Key>` | one setting, live (overlay patch 0013) |
| `cfg set <Section.Key> <value>` | sets it and **reports the read-back**, because `config.c` clamps silently — "what I set" and "what it became" are different questions |
| `tap X Y` | a synthetic UIKit touch on the overlay at that point, in **points**. Answers `hit=button:FIRE mask=0x2000 …`, `hit=stick`, `hit=look`, `hit=gear`, or `hit=MISS …` |
| `windows` | **where a real touch would actually go** (D-041). Walks every window of every window scene — plus the sceneless one only the renderer can find (D-038) — highest `windowLevel` first, and hit-tests FROM THE WINDOW at the centre of each visible chip, which is the routing UIKit itself does. Prints the scene's key window, every window's level/hidden/key/scene/root, one `route <chip> (x,y) -> <class> in <window> OK\|WRONG` line per probe, and ends in `route_ok=0\|1` and `game_is_key=0\|1`. **This is the only command that can see a routing failure**: `hit` answers from the overlay's own MODEL and is right even when every finger is being delivered to a different window, which is the bug that cost round R. Run it either side of a transition — a settings open/close, a pad connect, the layout editor — and compare `route_ok` |
| `point X Y` | moves the **menu pointer** to that point without pressing it, so a validation run can screenshot the highlight and assert on it before committing. The pointer's button is the click (overlay 0019), so a `tap` both aims and chooses and there is otherwise no way to ask "what is under here?" from outside. Answers `hit=menu norm=x,y` or `MISS no-menu` |
| `drag X Y DX DY` | touch down, drag, lift. Answers with the look degrees or stick value it produced. Started **on the AIM chip** it is the hold-and-drag aim (D-046): R stays down, the drag aims, and the chip releases itself after 1.5 s so a screenshot taken straight after shows aim ENGAGED |
| `stream X Y DX DY N MS` | a continuous synthetic touch: down at X,Y, then walked by DX,DY every MS milliseconds for N steps, **each in its own turn of the run loop** (round C). `drag` walks its eight steps inside one main-queue block, which is exactly what a finger does not do, so it can never show what a per-event cost does to a frame. Routes to the stick, the look zone, the menu pointer or the AIM chip's aim drag by what is under the start point; an aim stream holds R for its whole length and lifts at the end |
| `pacing wait <sem\|runloop>` | HOW the game thread waits for the link (D-045). `runloop` (the default) turns the main run loop while it waits, so UIKit's event dispatch is serviced; `sem` is the old `dispatch_semaphore_wait`, which blocks the main thread for most of every frame and re-breaks touch delivery at the 60 Hz setting. Live, no relaunch: it is the A/B that demonstrates the bug and the fix in one session |
| `pacing` / `pacing reset` / `pacing engine <hz>` | the pacer's report on its own; `reset` zeroes the present-interval histogram so a window measures one thing (the three counters stay cumulative); `engine <hz>` forces the engine's declared tick rate AND `Game.TickRateDivisor` to match it. The last one exists because a simulator reports `maximumFramesPerSecond = 60` for EVERY device, ProMotion included — so the case that matters, a link faster than the engine's gate, can only be reached at 60/30 (D-034, M-031) |
| `touch watchdogtest` | appends one line to `Documents/touch-watchdog.txt` through the watchdog's own reporting path. Its DETECTION path needs a real `UITouch` whose end callback never arrives and cannot be provoked from a script at all |
| `pad <button> <down\|up>` | injects a pad button through the same mask the touch layer uses (overlay 0015). Names: `a b z start l r cu cd cl cr up down left right x y roll crouch`. **`touch off` first**: the overlay calls `inputIosPadSet()` with its own mask every frame and overwrites an injected bit within one frame |
| `touch <auto\|on\|off>` | the on-screen controls' mode — the same setting the settings page writes (D-017). The gate needs it because the simulator reports a virtual "Gamepad" and auto would hide the layer under test |
| `link <url>` | feeds a `perfectdark://` URL into the same queue the system's own delivery uses, so the parse-and-consume half is testable (the delivery half is not: see below) |
| `crash yes-really` | deliberately faults the app, to prove `Documents/crash.txt` gets a usable backtrace. Dev builds only, like everything in this file |
| `settings [close\|<section>]` | show/hide the native settings page. With a word, scrolls to the first section whose title contains it (`settings Xbox`) — note that `present` hops to the main queue, so the scroll lands on the *second* call after the page first comes up |
| `layout <edit\|done\|reset>` | the touch-layout editor (D-031). `edit` closes the settings page and makes every gameplay chip draggable; `drag X Y DX DY` then moves the chip under X,Y and leaves it **held for 1.5 s** so a screenshot taken straight after shows the drag rather than its result; `done` leaves; `reset` forgets every stored position. Every answer also reports `layout_entries=` and which labels are stored |
| `audio` / `audio volume 0-100` / `audio mute on\|off` / `audio mode 0-4` | the Audio rows (D-033). `audio` alone reports every `audio_*` line. `volume` and `mute` move the shell's MASTER GAIN, which overlay 0023 multiplies into the frame's samples; `mode` is the five-mode Other App Audio policy (0 stop other, 1 play both, 2 lower other, 3 lower game, 4 mute game). The game's own Sound / Music / Sound Mode are NOT here - they are the eeprom's, edited in the game's own Audio Options page. Needed because injected events cannot move a `UISlider` and writing the preferences plist from outside is served from cfprefsd's cache |
| `settings row <section> <n>` | press row `n` of the first section whose title contains `<section>`, through the page's own `didSelectRowAtIndexPath:`. `tap` drives the TOUCH OVERLAY, not UIKit, so this is the only way a script opens anything the settings page presents - the Other App Audio sheet among them |
| `gamefile defaults` / `gamefile save [device]` / `gamefile load [device]` | force a game-file load at a frame of the script's choosing. Both rewrite the three audio values from the eeprom (or from the N64 defaults), which is the game's business (D-033); what this is for now is making a slot load happen at a frame of the script's choosing rather than only at boot. Reports the three raw values after the load; `load` also reports the engine's own error number (0 is success). `save` writes a file first — without one `load` has no fileid and returns -1. Device defaults to 4, SAVEDEVICE_GAMEPAK, the eeprom |
| `render <pct>` | the Resolution row (100/75/50). Writes the default and says so — it only takes effect at the next launch, because the drawable's size is fixed when the renderer comes up. Relaunch and read `drawable=` from `state` |
| `rom` | the installed ROM, its md5, and the classifier's verdict in words |
| `xbla` | what is in `Documents/xbla` and whether it has been unpacked into Caches — the `xbla_*` lines of `state`, on their own |
| `xbla wait [N]` | blocks until the one-time unpack has finished (default 600 s), then reports how long it took. This is the gate's hook: the unpack is a quarter of a gigabyte on a background thread **before the engine starts** (D-020), and polling the container path from the host races the app's own writes. Answers at once for a bare package (nothing to unpack) and `ERR` when there is no package at all |
| `texpack` | what is in `Documents/texture-packs`, whether each folder carries the `bottomup.txt` row-order marker, and which pack the engine has selected. The marker is the whole difference between a pack and an upside-down one (D-024) and is invisible in a screenshot of anything symmetrical |
| `xbla release <on\|off>` | flips the whole-release row **through the settings page's own code path** (`PDSettingsViewController setSwitchRow:`), so a scripted check of "does that row do anything" is a check of the row. Reports what was asked for and what `xblaSwitchGetEnabled()` says afterwards |
| `xbla pick <path>` | the Xbox 360 row's (and the onboarding's) importer copy with a file already in the container: copy beside, then rename over (D-075). Answers `xbla_pick=ok dst=…` or `xbla_pick=FAILED why=…` |
| `geplus [scan]` / `geplus pick <rom\|xbla> <path>` | the GoldenEye rows: the cached scan, a fresh one, or the picker's completion (validation, copy, replace, alert) with a file in the container |
| `geplus` lines (1.0.1.3) | besides `ge_*_found/file/ready/row`: `ge_xbla_form=none\|folder\|archive\|package` (package = the Xbox 360 package, bare, in a folder or in a .7z/.zip) and `ge_xbla_need_mb` (MB the last start needed to unpack and did not find; 0 = no refusal). The free-space check can be faked in a dev build with `PD_FAKE_FREE_MB=<n>` in the launch environment (`SIMCTL_CHILD_PD_FAKE_FREE_MB=100 xcrun simctl launch …`); public builds ignore it |
| `audio interrupt begin\|end` | posts the audio session's interruption notification the way the system does for a call or Siri: `begin` makes SDL pause its AudioQueue. Leaving out `end` is the lost-end case: the engine's burst drop then lasts past 2 s and the shell restarts the device itself (overlay 0048). `audio` reports `audio_dropping`, `audio_dropping_ms` and `audio_device_restarts` |
| `adopt fail <copy\|swap\|off>` | the NEXT copy into `added-content/` (either picker) fails at that stage: `copy` leaves half a temporary file and reports ENOSPC, `swap` refuses the rename. The proof that a failed replace leaves the existing file as it was (D-075) |
| `stall <ms>` / `stall every <s> <ms>` / `stall off` | blocks the GAME thread for that long (once, or on a repeat from a helper thread) - a deterministic hitch. The audio measurements of D-078/M-050 are this plus `audio trace`. 1-5000 ms |
| `audio trace on\|off\|dump [name]` | the per-push audio ring (overlay 0023, 16,384 rows ≈ 4.5 min): `push,us,queued,out,rate_milli,integ_e6,flags`, flags 1 underrun, 2 dropped at QueueLimit, 4 re-prime, 8 dropped in a burst resync, 16 fade in, 32 fade out. `dump` writes `Documents/<name>` (default `audio-trace.csv`); `on` empties the ring |
| `geo` / `geo repair on\|off\|now` | the picture's size chain (D-077): scene orientation and bounds, SDL's window/root/Metal view, the layer, the EGL surface the renderer draws at, SDL's size, `statusBarOrientation`, which window is key, and what SDL's controller and the app allow. `repair off` disables the iPhone repair so the fault can be reproduced (also `PD_GEO_REPAIR=0` in the launch environment); `repair now` runs the check at once. Since 1.0.1.3 it also reports `size_repair_streak` (repairs in a row with no good frame between) and `size_repair_gave_up` (1 after 30: no more repairs that session); lifecycle.txt keeps the first 10 repair and 200 size-change lines in full, then one summary line a minute |
| `geo keyboard` | raises a real keyboard from the key window's top page for 3 s - what the Files picker's search field does to every window in the app |
| `geo device <1\|3\|4>` | sets `UIDevice.orientation` by KVC. Kept as a recorded dead end: under UIScene it does NOT rotate anything |
| `presented` | every window of every scene, the controllers presented in each and the orientations each supports |
| `picker cancel` / `picker pick <path>` / `picker dismiss` | finish the REAL document picker (opened with `settings row …`) the way a finger does: it goes away, then its delegate hears cancelled or picked-with-that-file. `dismiss` closes whatever is on top (an alert, as if OK) |
| `quit` | `configSave()` then `exit(0)` — which is also the only way to end a scripted run with its settings written (`atexit(cleanup)`, `main.c:124`) |

### Why `tap` exists at all

**`simctl`'s injected events bypass UIKit**, and `idb ui tap` is dead on iOS 27
(charter §Simulator validation). So there is no way from outside the process to
press an on-screen button. `tap` presses it from inside, through the same
handler a finger reaches, and — the part that makes it a test rather than a
gesture — reports *what was under the point*. A validation run can therefore
assert that the FIRE button is where it is supposed to be, rather than that
something happened.

Only one synthetic touch may be in flight at a time: a synthetic touch has no
`UITouch` to key on, so the release is by position.

### `state`

```
build=202609130413-585277d        the stamp gen-app-project.sh wrote
version=0.0.0.1                   CFBundleShortVersionString
engine=running|starting
frames=12345                      frame-hook count since launch
stage=0x26                        mainGetStageNum()
fps=59.8                          videoGetAverageFPS()
xbla_available=0|1                a package found in Documents/xbla
xbla_enabled=0|1                  the F6 whole-release switch
xbla_state=<n>  xbla_status=<s>   the importer's own state machine
texpack_enabled=0|1
xbla_found=0|1  xbla_kind=none|archive|package  xbla_file=<name under xbla/>
xbla_extracted=0|1                the .extracted marker AND a package under it
xbla_unpacking=0|1  xbla_unpack_pct=<0-100|-1>  xbla_unpack_secs=<last unpack>
xbla_cache=<Caches/cache/xbla>    where patch 0009's $C sent it
audio_category=...  audio_route=...  audio_rate=...  audio_outchannels=...
audio_rate_min_milli / audio_rate_max_milli   the ratio's excursion since `audio reset` (x10000; D-078 keeps it within 9900-10100)
audio_resync_underrun / audio_resync_burst / audio_dropped_samples   hitches handled as discontinuities (D-078)
size_scene / size_window / size_root / size_view / size_layer / size_layer_drawable / size_egl / size_sdl
size_portrait_frames / size_repairs / size_changes / size_sdl_resizes / size_last_*   the size chain (D-077); iOS only
audio_applied=<n>                 times the .playback category had to be set
drawable=844x390                  what ANGLE is actually rendering
points=844x390  contents_scale=3.00
expect_drawable=2532x1170
native_resolution=OK|MISMATCH     drawable == points x scale
footprint_mb=214.3                phys_footprint, the number Jetsam judges
thermal=nominal|fair|serious|critical
touch_overlay=visible|hidden|none
menu_open=0|1                     a menu dialog is up, so a tap is a pointer
player_pos=x,y,z|none             overlay 0021; "none" outside a level
player_aimmode=0|1                overlay 0021; the ENGINE's insightaimmode —
                                  "is the player aiming", which the AIM chip's
                                  hold-and-drag claim rests on (D-046). Served
                                  from the last published frame, so poll it from
                                  a second connection during a `stream`
touch_aimdrag=0|1                 the shell's half: an AIM press is live
pacing_mode=displaylink|bypass    docs/pacing.md
pacing_links / pacing_presents / pacing_dropped / pacing_hz / pacing_target
pacing_wait_mode=runloop|sem      how the game thread waits for the link (D-045)
pacing_wake_us_p50/p95/max        link signal -> waiter noticing, microseconds
settings_page=0|1
present_allowed=0|1               0 from didEnterBackground to willEnterForeground
notice_drawn / notice_held        GE Plus startup notice frames drawn / calls held
                                  in the background (overlay 0042, D-075)
egl_swaps=<n>                     eglSwapBuffers on the window surface since launch
```

### The round-S instruments (D-044)

The failure these exist for makes this very socket go silent, so their real
output is three files in `Documents/` — `heartbeat.txt` (once a second, temp +
rename), `lifecycle.txt` (append + fsync) and `hang.txt`. The commands are how
they are proven on a simulator and driven on a phone that still answers.

```
heartbeat          exactly what Documents/heartbeat.txt holds this second
hang <ms>          block the GAME thread on purpose (default 3000), so the
                   watchdog's 2-second trip and its stack walk can be proven
                   rather than believed; returns at once, the frame is what
                   gets stuck
dump               write Documents/hang.txt now, from the socket thread
graft on|off       D-038's re-graft, live. `off` only bites once the touch
                   overlay exists, so it can never brick a launch
hide60 on|off      take the 60 Hz segment off the Frame rate row on a 120 Hz
                   panel (pd.video.hide60on120; registered NO)
```

`state` gained four rows with them: `tick_rate_div` (the engine's own tick gate,
0 on iOS at every rate since D-043), `video_framerate_limit` (inert — patch 0016
compiles upstream's limiter out of the iOS branch, so 240 is a leftover from
`videoInit()` and is never consulted), `video_vsync` and `graft_enabled`.

**`help` is the first command to send to a phone that seems wedged.** It runs
entirely on the socket thread and touches neither the engine nor UIKit: silence
from `help` means the PROCESS is not being scheduled, while `help` answering and
`state` timing out means only the game thread is stuck. Different bugs.

`native_resolution` is the assertion `sim-validate.sh` makes first: a port that
renders at a different size than the panel is the family's most common silent
regression, and it looks fine in a screenshot.

## Deep links do the same job without a bridge

`perfectdark://stage/0x1d` and `perfectdark://screenshot` are handled for the
cases where there is no bridge (a public build, or a device on someone else's
network). They are queued at any lifecycle point and consumed in the frame hook.

Getting them delivered at all took two findings, both in `docs/build.md`
§Traps (M2): SDL2 **disables drop events by default**, so SDL's own
`application:openURL:` → `SDL_DROPFILE` path is silent until the shell enables
them; and **SDL 2.32.8 has no scene support whatsoever**, while iOS 26/27 makes
the app scene-based anyway and delivers URLs to `-scene:openURLContexts:` on the
scene delegate. `app/ios/PDDeepLink.m` installs that method at runtime on
whatever object is acting as the scene delegate, without owning it.

**`xcrun simctl openurl` cannot be scripted on iOS 27**: it raises an
"Open in *Perfect Dark*?" confirmation, and nothing can tap it (`idb ui tap` is
dead; injected events bypass UIKit). That dialog is itself the proof the scheme
resolves to this app. The scripted assertion uses `link` instead, which exercises
the queue, the parse and the frame-hook consumption — everything that is ours.

## `3d` — the visionOS 3D mode (Phase 6, visionOS builds only)

```
3d on              enter 3D: opens the "PD-3D" ImmersiveSpace and starts the
                   compositor loop. Answers "3d on requested", not "on" — the
                   space takes a moment to open and `3d state` is how you
                   learn that it did
3d off             leave 3D: stops the loop, WAITS for it (<= 2 s) and then
                   dismisses the space
3d state           imm_mode / imm_running / imm_frames / imm_hz plus the
                   eye_* rows below (also in `state`)
3d recenter        drop the frozen head pose: the world-locked panel is
                   re-placed in front of wherever you are looking, after the
                   same 30-frame tracking-convergence wait entry uses
3d depth [<pct>]   Stereo Depth as a percentage of the default 63 mm (0-300)
                   separation (0-200). With no argument, reads it back.
                   **0 is the gate's instrument**: the fold becomes the
                   identity, so both eyes are the mono projection and an L/R
                   pair must come out pixel-identical
3d gunconv <units> override the gun's convergence (0 = its own znear, 1.5).
                   The ONE A/B round the plan allows (§2.4); this row goes
                   once the user has answered Q-020
3d park            shrink the 2D window to the 480-pt card by hand. The park
3d unpark          normally happens on its own, 1.5 s after the space finishes
                   opening, and is undone BEFORE the dismissal (M4) - these two
                   rows exist so a gate can drive the geometry cycle and read
                   the result, and so a park the SYSTEM refused is visible as a
                   refusal rather than as "the card did not shrink"
3d settings open   open the 3D settings sheet (the ornament's GEAR, in words the
3d settings close  simulator can inject — no tap and no gaze-pinch can be, so
                   this is the sheet's `3d on`). "requested", not "open": SwiftUI
                   presents on its own turn of the run loop and `sheet_open` in
                   `3d state` is how you learn it landed
3d settings get    every row's stored value, plus the compositor's live copy
3d settings set <row> <value>
                   write one row and push it live. Rows: dist (m), width (m,
                   FULL width — the key stores the half), height (m, full),
                   posh (m, signed), depth (%), conv (PD units), dim (%),
                   render (% of the eye's base size), units (m|ft), fps (0|1).
                   Clamped to the sheet's own ranges, and the reply is what was
                   actually stored
3d settings press <row>
                   press a BUTTON row on the open sheet — `recenter` is the only
                   one. Needs the sheet up; a UIKit row has no other scripted
                   path on a platform that injects no taps
3d settings reset  forget the eight geometry/stereo keys so the registered
                   defaults apply again. Units and FPS on Panel are KEPT
                   (SETTINGS-SPEC), and so is everything outside the 3D rows
3d crown           simulate a Crown/system dismissal: runs the loop's own
                   `invalidated` path (stop, then reconcile), which is where
                   the immediate pd.ini + eeprom write lives. A simulator has
                   no Crown and no way to invalidate the layer from outside,
                   so this is the only way to test that path. Dev instrument,
                   like `pad fake`; nothing in the app ever sends it
```

The M4 rows, in `3d state`:

```
window_parked=1     the scene is shrunk to the card
curtain=1           the black "Playing in 3D" view is over SDL's window
park_cycles=3       park -> 3D -> exit cycles COMPLETED this session. This is
                    the counter the LUS ports' bug would have shown
                    (playbook §2.12 item 2): it only advances on an un-park
                    that undid a real park
park_armed=0        1 while the +1.5 s park timer is pending
scene_pt=480x270    the scene's effectiveGeometry right now, in points
pre_park_pt=1280x720  the size captured on the way IN, which the exit restores.
                    An explicit state, never re-derived: while parked the
                    window IS 480 pt, so a "is this the small size?" heuristic
                    answers the same in both states and would restore the card
```

...and in `state`, from PDAudio (visionOS only):

```
audio_spatial_immersive=1   the shell has asked for the head-tracked stage
audio_spatial_experience=0  AVAudioSession's own reading (0 = headTracked)
audio_spatial_applied=2     1 = windowed was applied, 2 = immersive was
```

- **`PD_VP3D_PAUSE_AT=<frame>`** presses Start at that frame of a scripted run
  and releases it one frame later, after hiding the touch layer five frames
  earlier. It exists because the HUD zero-disparity claim needs a frame that HAS
  a HUD, and a bridge command lands at a wall-clock moment — so in a
  `--fixed-step` replay it would land on a different frame in the eye-L run and
  the eye-R run, and the two captures would not be comparable. Like
  `PD_VP3D_AUTOENTER`, absent it does nothing at all. The three reasons it is
  shaped this way (the layer eating the mask, the edge, the front end being a
  menu) are in docs/build.md §Traps earned (Phase 6 M4).

The M6 rows, in `3d state` (D-054) — the stored setting and the value the
COMPOSITOR is actually using, side by side, so "the slider moved" and "the panel
moved" are two separate assertions:

```
sheet_open=1        the settings sheet is on screen (set by the sheet's own
                    .onAppear / .onDisappear, not by the request)
set_dist=3.60       Screen Distance, metres          (1.0-8.0, default 3.6)
set_width=6.10      Screen Width, metres, FULL       (1.2-12.192, default 6.096 = 20 ft)
set_height=3.66     Screen Height, metres, FULL      (1.0-6.0, default 3.658 = 12 ft)
set_posh=0.00       Screen Position Height, metres   (-1.5-+10.0, default 0)
set_depth=150       Stereo Depth, per cent           (0-300, default 150)
set_conv=762        Convergence, PD units            (100-1500, default 762 = 25 ft)
set_dim=80          Surroundings Dimming, per cent   (0-100, default 80)
set_render=100      Render Resolution, per cent      (40-100, default 100)
set_units=ft        the Units row (readouts only; nothing stored changes)
set_fps=0           FPS on Panel — the SAME key as the 2D page's Show FPS
panel_px=1280x720   the eye's size, which is what the Panel Width / Height
panel_px_aspect=16.0:9  / Aspect Ratio info rows show
panel_dist_m=3.60   ...and the compositor's own live copy of the geometry,
panel_width_m=5.50  pushed by pdVision3dApplySettings() at boot, on every row
panel_height_m=3.10 change and at every 3D entry
panel_posh_m=0.00
panel_dim_pct=80
panel_aspect=1.77
stereo_conv=610     the convergence the fold is using (`set_conv`, clamped)
eye_render_pct=100  Render Resolution as the ring has it
eye_base_px=1280x720  the base the percentage multiplies — PD_VP3D_EYE if set,
                    else 3840x2160, which is why a gate that pins the eye to
                    the oracle's size can still measure the row (50 % of
                    1280x720 is 640x360)
eye_sampling=0      compositor frames inside the raw-pointer bracket. A live
                    resize waits for this to reach 0 before it frees the ring
```

- **Render Resolution is applied at a FRAME BOUNDARY, not in the setter.** The
  ring's textures are handed to the compositor unretained (the ring owns them
  for the session), so freeing one while a compositor frame is between its
  acquire and its own retain is a use-after-free. The setter only asks;
  `pdVisionEyeResizeIfPending()`, called from the frame hook, unpublishes,
  waits for `eye_sampling` to reach 0 (200 ms bound, loud and NO free if it
  expires) and then re-wraps. `eye resize 1280x720 -> 640x360 (50 %)` in the
  log is the whole event.
- **The sheet closes BEFORE the un-park, and the exit waits for it.** A
  geometry request issued while a modal is being dismantled is one more way to
  lose the race q2repro lost on device ("stuck tiny window"). The log line
  order is the assertion: `closing it BEFORE the un-park` -> `settings sheet
  gone=1 after N ms` -> `UN-PARK -> requesting`.

The eye rows (M2/M3, D-048/D-049/D-050) — the eye render targets' whole state:

```
eye_active=1            the ring is wrapped and framebuffer 0 IS the eye
eye_px=1280x720         the eye target size, which is also the render
                        resolution in 3D (pdAngleGetDrawableSize reports it)
eye_ring=3              slots in the ring (a constant; 3 per the q2repro consult)
eye_slot=1              which slot the engine is drawing into right now
eye_fb_complete=1       glCheckFramebufferStatus said COMPLETE for every slot
eye_wrap_failed=0       1 if the EGLImage wrap failed and 3D refused to enter
eye_publishes=742       eyes handed to the compositor this session
eye_pair_fresh=738      compositor frames that copied a NEW eye
eye_pair_reuse=740      ... and frames that re-sampled the previous copy
eye_renders=1484        display-list walks: 2 per published pair in 3D, 0 in 2D
eyes_per_frame=2        2 while the ring is live, 1 in 2D
in_flight=1             pairs published whose GPU work has not retired
in_flight_peak=2        the high-water mark. > 2 is a BUG: eye L waits for it
eye_stalls=3            times eye L had to wait for a retire (fine, and rare)
eye_stall_timeouts=0    times that wait hit its 200 ms bound. Never non-zero
stereo_depth_pct=150    Stereo Depth (`3d depth`)
stereo_gun_conv=0.0     the `3d gunconv` override; 0 = C_gun is znear
show_eye=-1             PD_VP3D_SHOWEYE: -1 per-view, 0 = L, 1 = R
stereo_cls_world=41200  projections folded as pure perspective
stereo_cls_sky=2060     ... as sky (rotation folded in: skew only)
stereo_cls_gun=2060     ... as gun (znear 1.5: C_gun = znear)
```

- `eye_active=0` with `imm_mode=1` means the space is open but the engine is
  still on the window — in M2 that combination cannot happen (entry aborts back
  to 2D if the ring fails), so it is a bug if you see it.
- `eye_publishes` should climb at the ENGINE's frame rate and
  `eye_pair_fresh + eye_pair_reuse` at the COMPOSITOR's. On the simulator the
  engine runs at ~30 fps against a 60 Hz compositor, so reuse and fresh come
  out roughly equal; a `reuse` that dwarfs `fresh` on the device means the
  engine is behind.
- **`prof_acquire` is the companion row.** With the context surfaceless there
  is no CAMetalLayer drawable to acquire, so `prof` must show ~0 there in 3D
  (D-040's instrument). On the simulator 2D is also ~0, so the row only
  discriminates on the device.
- **`PD_VP3D_EYE=WxH`** forces the eye size. It is a test instrument: the M2
  pixel gate needs the eye at 1280x720 to diff it against the committed
  oracle frame. Unset, the eye is 3840x2160 (the plan's Render Resolution row
  is a percentage of that).
- **`PD_VP3D_EYE_PRIVATE=1`** puts the eye texture back on Private storage.
  It exists for one A/B and it BREAKS the screenshot (docs/build.md §Traps
  earned Phase 6 M2) — never set it in a gate.
- **`eye_renders` is the "three rates, one fact" row (M3).** It must be
  exactly `2 x eye_publishes` (a reading one higher is the instant between eye
  L and eye R of the same frame) and it must be `0` in 2D and after `3d off`.
  Anything else means an eye was rendered twice, or not at all.
- **`in_flight_peak > 2` is a bug, not a slow frame.** Eye L of every frame
  waits while more than two pairs are outstanding, and the count is decremented
  by the published `MTLSharedEvent`'s own completion listener — so it is a real
  GPU-side bound on ANGLE's command queue, which is the hazard D-008 §2 flagged.
- **`stereo_cls_*` is the only proof the three-way classification is alive.**
  A screenshot cannot show that the SKY took the skew-only path. In live
  gameplay all three must be non-zero; they stay 0 at `3d depth 0`, because
  the fold returns before it classifies anything when the offset is zero.
- **`PD_VP3D_SHOWEYE=L|R`** forces which eye the compositor samples and which
  eye's readback a screenshot keeps. The simulator is MONO (`views == 1`) and
  would otherwise only ever show eye L, so this is how an L-vs-R disparity diff
  is taken from two scripted replays. Unset, view 0 is L and view 1 is R and
  the capture eye is R.
- **`PD_VP3D_STEREO_DEPTH=<pct>`** is `3d depth` for a headless run, read once
  at the first fold.

- `imm_mode` is the shell's flag; `imm_running` is the compositor loop's own
  liveness. They differ for the moment the space is opening or closing, and a
  pair that stays apart is a bug worth chasing.
- `imm_frames` is compositor frames THIS session (it resets on every entry),
  and "advancing" is the assertion — a loop that presents nothing still reports
  `imm_running=1`.
- `imm_hz` is the compositor's measured cadence from the optimal-input-time
  deltas, not a constant. The Vision Pro **simulator runs it at 60**; the
  headset is 90 (up to 120 on an M5). Since M3 the engine IS paced off this
  clock (D-050), so this row is the one to read when the frame rate is in
  question.
- **FOVEATION (D-063), three rows because "is it on" has three answers.**
  `imm_foveation=<supported>/<configured>` is what `LayerRenderer.Capabilities`
  said and what `isFoveationEnabled` was set to; `imm_foveation_maps=<n>` counts
  the rasterization rate maps on the DRAWABLE, every frame, and is the only one
  of the three that is EVIDENCE — a drawable with no rate map is a drawable the
  compositor is not resampling; `imm_layout` is `dedicated` or `layered`, which
  is the foveation guide's trap 1 in one line (`.layered` WITH foveation is a
  right-eye fisheye that warps with the head). **On the simulator these read
  `0/0`, `0` and `layered` and that is correct** — it is mono and has no eye
  tracker. On the headset expect `1/1`, `2`, `dedicated`.
- **`pacing_mode` (in `state` and `pacing`) says which clock is live**:
  `displaylink` in 2D, `compositor` while the immersive loop is running,
  `bypass` in a `--fixed-step` replay. `pacing_external_signals` counts the
  compositor frames that released an engine frame. The switch is made by the
  LOOP, not by the mode transition, so a Crown dismissal — which never reaches
  the mode transition at all — cannot leave the engine waiting for a compositor
  that has gone.
- **`PD_VP3D_AUTOENTER=1` is the scripted way in.** The window's "3D" ornament
  needs a gaze-pinch and no simulator tool can inject one, so the env flag
  enters 3D at frame 300 instead. Absent, it does nothing.
