# Frame map — Dab's Mod (Perfect Dark PC port), one page

Where a frame comes from, and the exact seams the iOS/visionOS port cuts at.
All line numbers are against vendor pin `bfea0618`. Paths are relative to
`vendor/dabs-mod/`. Upstream's own notes are cited, never copied
(`CLAUDE.md`, `CLAUDE-notes/{xbla,texture-packs,save-format,crash-reports,
updater,recording,ghost-trials,performance}.md`).

## Startup

```
main()                                   port/src/main.c:157
  sysInitArgs(argc, argv)                :159   argv kept for the whole process (system.c:82)
  crashInit()                            :161   unless --no-crash-handler; NO-OP ON APPLE (below)
  sysInit()                              :165   start clock; --log opens ./pd.log or $H/pd.log
  fsInit()                               :166   the two roots (below)                 fs.c:350
  configInit()                           :167   reads $S/pd.ini if present         config.c:365
  modListApplySelection()                :171   before romdata: mod dirs must be mounted first
  videoInit()                            :172   window + GL + fast3d                video.c:77
  inputInit()                            :173
  videoSetCleanTextOutlines/TextureEnhance/VividColours/BlackLevel   :180-183
  screenshotInit/traceInit/recordInit/ghostnetInit/updateInit        :184-188
  crashReportScan()                      :190   offers last run's report in the menu
  audioInit()                            :192   SDL audio device                    audio.c:18
  romdataInit()                          :192   loads the ROM                    romdata.c:484
  modloaderInit()                        :193
  atexit(cleanup)                        :203   cleanup() at :115 — the ONLY pd.ini write
  g_MempHeap = sysMemZeroAlloc(...)      :210   Game.MemorySize MB, default 64 (:48)
  <CLI flags parsed>                     :218-284   see docs/upstream-cli.md
  mainProc()                             :286 -> pdmain.c:286
       mainInit()                        pdmain.c:218
         xblaImportInit()                :259  makes xbla/, finds the package
         assetDumpFromCommandLine()      :260  --dump-assets; exits
         xblaImportFromCommandLine()     :261  --xbla-import; exits
         recordFetchFromCommandLine()    :262  --fetch-ffmpeg; exits
       mainLoop()                        pdmain.c:321  one iteration per stage load
         rngSetSeed(--rng-seed | osGetCount())      :359
         while (stage not changing) { schedStartFrame; mainTick; schedEndFrame }  :607-617
```

**The ROM is a runtime input.** `romName` is `"pd.ntsc-final.z64"`
(`romdata.c:29,72`), resolved through `fsFullPath()` — i.e. `<basedir>/pd.ntsc-final.z64`,
and the default basedir is `$E/data`. `--rom-file` overrides the name
(`romdata.c:486`). Size/header are checked and a mismatch is `sysFatalError`
(`romdata.c:204-238`) — that is the wrong-ROM path the iOS onboarding must
intercept *before* it reaches a message box.

## The two roots (`port/src/fs.c`)

`fsFullPath()` (`fs.c:77`) expands five placeholders; the two that matter are
`$B` (base) and `$S` (save). Per-thread scratch buffer — one path at a time.

| root | how it is picked (`fsInit`, fs.c:350) | holds |
|---|---|---|
| `$E` exe dir | `sysGetExecutablePath()` = `SDL_GetBasePath()` (system.c:354) | — |
| `$H` home | `SDL_GetPrefPath("", "perfectdark")` (system.c:388); `--portable` makes it `$E` | legacy saves |
| `$B` base | `--basedir`, else `./data`, else `$H/data`, else **`$E/data`** (:363-375) | `pd.ntsc-final.z64`, the ROM's overlay files |
| `$S` save | `--savedir`, else `$E` when writable (migrating from `$H`/`.` once, :434-446), else `.`/`$H` | `pd.ini`, `eeprom.bin`, `crashreports/`, `ghosts/`, `exported/`, `mpsetups.bin` |

Directories that are **`$E` first, `$S` if `$E` is not writable** — via
`fsChooseOutputDir()` (`fs.c:696`): `screenshots/` (screenshot.c:22),
`recordings/` and `ffmpeg/` (record.c:52,90), `texture-packs/` (texpack.h:22),
`model-packs/` (modelpack.c:28), `xbla/` (xblaimport.c:46), `cache/xbla/`
(xblaimport.c:58-59). `mods/` is searched at `$E/mods`, `$H/mods`, `./mods`
(mod.c:2991). `xbla/` is additionally searched at `$E`, `$H`, `.`, `$S`
(xblaimport.c:337-342).

> **iOS**: an app bundle is never writable, so unmodified upstream would put
> every one of these in `$S`. The port instead points both `$E`-side and `$S`
> at `NSDocumentDirectory` (charter Phase 1), except `cache/` → Caches.
> `PLATFORM_OSX` is what `__APPLE__` sets today (`src/include/platform.h:15`);
> CMake maps `APPLE` → `osx` (`CMakeLists.txt:64`). Only two places branch on
> `PLATFORM_OSX` in a way that matters: the savedir legacy pick
> (`fs.c:413`) and `update.c:177` (`_NSGetExecutablePath`).

## Render path

```
game logic  -> gfxGetMasterDisplayList(), F3D commands   src/lib/gfxmemory.c, src/game/*
  rdpCreateTask()            pdmain.c:685
  schedSubmitTask()          pdsched.c:239 -> videoSubmitCommands()   video.c:134
    gfx_run(cmds)                                   fast3d/gfx_pc.cpp:4015
      gfx_wapi->start_frame()                       :4021  (gfx_sdl2.cpp:321 = return true)
      gfx_rapi->update_framebuffer_parameters(0,..)  :4027
      gfx_rapi->start_frame() / start_draw_to_framebuffer / clear   :4030-4033
      gfx_run_dl(commands)                          :4038  the RSP/RDP interpreter
      MSAA resolve / framebuffer blit               :4042-4059
      gfx_rapi->end_frame()                         :4061  <- Vivid Colours runs HERE
      gfx_pre_swap_callback()                       :4065  <- screenshot/capture read-back
      gfx_wapi->swap_buffers_begin()                :4069  <- frame limiter + SwapWindow
```

- `struct GfxRenderingAPI` — `gfx_rendering_api.h:18`, **44 fn ptrs**: framebuffers
  with MSAA + resolve + depth extraction (`:43-52`), filter/mipmap/anisotropy
  (`:54-58`), `read_screen_pixels` (`:64`), a streaming PBO capture path
  (`:67-70`). One implementation: `gfx_opengl.cpp` (2.2k lines, glad).
  `struct GfxWindowManagerAPI` — `gfx_window_manager_api.h:20`, 31 fn ptrs, one
  implementation: `gfx_sdl2.cpp` (table at `:431`).
- **The backend switch is two lines**: `video.c:79-80`
  (`wmAPI = &gfx_sdl; renderingAPI = &gfx_opengl_api;`) handed to `gfx_init()`
  at `video.c:107`. Nothing else in the tree names a backend. This is the
  build-time seam the charter's 0.5 decision lands on.
- **Context rows** — `gfx_sdl2.cpp:148-155`: 3.0 compat → 4.1 core → 3.2 core →
  **`{3, 0, SDL_GL_CONTEXT_PROFILE_ES}` "don't really support ES properly, but
  we can try"** → 2.1 compat. `--gl-version` prepends an override row (`:159`).
  Swap interval forced to 1 at `:206`.
- **`gl_es` is a real degrade, not a label.** `gfx_opengl.cpp:1043` sets it from
  the profile mask; then GLSL becomes `#version 300 es` + `precision mediump
  float` (`:1077-1080`, `:254`, `:342`), NV12 capture is refused (`:1793`), and
  **Vivid Colours / Black Level refuse outright** (`:1210` — `if (gl_es || ...)
  return false`, logged as "Vivid Colours needs desktop GL 3.0, off" at `:1288`).
  Extended Options' Picture settings are a Phase 2 acceptance item, so an
  ANGLE-ES substrate owes a fix here.

### Where the XBLA art enters

- **Textures** — `import_texture()` (`gfx_pc.cpp:1482`), after the cache lookup
  (`:1539`), in three ordered branches:
  1. `menuImageLoadReplacement()` `:1556` — community pack cover art.
  2. `xblaTexLoadReplacement()` `:1578-1591` — the meshes' own records, keyed by
     the stand-in tile address, not by texture number.
  3. `texpackLoadReplacement()` / `xblaTexLoadNumbered()` / `xblaFontLoadGlyph()`
     `:1597-1690` — the texture-pack branch; XBLA numbered art is used only
     where `texpackTextureArt(orig_addr) == TEXPACK_ART_ROM` (`:1650`).
  Enhance Textures / Smooth Text multiply on upload: `import_enhance_scale`
  (`:966`, `:1022`) drives `gfx_texscale()` at `:984-989`. Replacement paths set
  it to 1 (`:1562`, `:1584`, `:1664`) — a pack's image is used at its own size.
  Decoded replacements land asynchronously: `gfx_texpack_poll()` runs at the top
  of `gfx_start_frame()` (`:3874`) so a frame never both evicts and re-uploads.
- **Meshes** — no special path. `xblaMeshRenderNode()` is called from
  `src/lib/model.c:3215` and `:3274` (the DL and GUNDL model nodes) and either
  writes 4J's geometry as ordinary F3D commands into `renderdata->gdl` and
  returns true, or declines. So XBLA meshes ride the same display list into
  `gfx_run_dl`. (Relevant to Phase 6: the stereo projection surgery needs no
  XBLA special case.)
- **The whole release on one switch** — `xblaSwitchSetEnabled()`
  (`port/src/xblaswitch.c:35`) flips meshes/textures/stages/font/explosions
  together; polled from `xblaSwitchTick()` (`:90`) on the `Mod.XblaMeshKey`
  key, default **F6** (`:57`). See `CLAUDE-notes/xbla.md`.

### Post-processing

Vivid Colours and Black Level are **backend-side**, not gfx_pc-side:
`video.c:658/668` clamp into the globals `gfx_color_saturation/contrast/
black_level` (`gfx_pc.cpp:339-341`), and `gfx_opengl_grade_frame()`
(`gfx_opengl.cpp:1273`) is called first thing in `gfx_opengl_end_frame()`
(`:1349`). It blits the default framebuffer into an FBO and draws one
full-screen triangle back over it (`:1314-1332`). Any new backend owes this
pass — it is not free from gfx_pc.

## Tick vs frame — two rates, name them precisely

**There is no interpolation and no decoupling: one game tick produces exactly
one rendered frame and one present.** The inner loop is `pdmain.c:607-617`:

```
while (g_MainChangeToStageNum < 0) {
    if (!mininc60 || cycles >= mininc60*CYCLES_PER_FRAME - CYCLES_PER_FRAME/2) {
        schedStartFrame()  -> videoStartFrame()  -> gfx_start_frame()   pdsched.c:248
        mainTick()         -> frametimeCalculate(), builds the DL, gfx_run()  pdmain.c:631
        schedEndFrame()    -> inputUpdate(), the *Tick() pumps, videoEndFrame()  pdsched.c:279
    }
}
```

1. **Tick/present rate** ("fps"): how often that body runs. Governed by the
   gate above plus `frametimeCalculate()`'s busy-wait (`src/game/timing.c:41-54`),
   then by vsync and the frame limiter at present time. Both gates round with a
   half-frame slack (`+ CYCLES_PER_FRAME/2`), so a tick may begin after ~8.3 ms.
2. **Sim rate in 60 Hz units** ("diffframe60"/`lvupdate60`): how much game time
   each tick advances, derived from the wall clock in `timing.c:46` and consumed
   everywhere as `g_Vars.lvupdate60freal`. Normally wall-locked at 60/s.

`--fixed-step` (`main.c:247`) pins `diffframe60 = 1`, `diffframe240 = 4` and
zeroes the lost-time accumulators (`timing.c:57-65`), so rate 2 becomes exactly
rate 1 and the clock stops mattering — that is what makes two runs replay tick
for tick. Upstream measured ~120 fps in that mode on Linux, i.e. the sim running
~2× real time (`CLAUDE-notes/performance.md`, "Measuring"). `Game.TickRateDivisor`
(`g_TickRateDiv`, `main.c:64`, → `g_Vars.mininc60`) divides rate 1; `Game.ExtraSleep`
adds a 100 µs `nanosleep` per spin (`constants.h:5098`).

At present time: `Video.VSync` → `SDL_GL_SetSwapInterval` (`video.c:703`);
`Video.FramerateLimit` → `target_fps` (`video.c:713`, `gfx_sdl2.cpp:26`, default
**120**), enforced by `sync_framerate_with_timer()` — `sysSleep` then a
`sysCpuRelax()` spin — immediately before `SDL_GL_SwapWindow()`
(`gfx_sdl2.cpp:329-361`). Limit 0 with vsync off is clamped to `VIDEO_MAX_FPS`
= 240 NTSC (`video.c:707`, `video.h:11`). **That busy-wait spin is a battery and
thermal problem on a phone and must be replaced by CADisplayLink pacing**
(`docs/pacing.md`).

## Audio

`port/src/audio.c` — **queued, no callback thread.** `audioInit()` (`:18`) opens
one device at `freq = 22020`, `AUDIO_S16SYS`, 2 channels, `samples = 512`
(`Audio.BufferSize`), `callback = NULL`. `audioEndFrame()` (`:69`) pushes the
mixer's buffer with `SDL_QueueAudio` from the **game thread**, only while fewer
than `Audio.QueueLimit` = 8192 samples are queued. Called from
`schedAudioFrame()` (`pdsched.c:253`) once per `diffframe60` unit. The mixer
(`port/src/mixer.c`, the sm64-port mixer + minimp3) therefore also runs on the
game thread. No audio callback means no "engine touched from the audio thread"
class of crash — unlike the sibling ports.

## Input

`inputUpdate()` runs once per frame from `schedEndFrame()` (`pdsched.c:299`).
`inputReadController()` (`input.c:958`) fills an `OSContPad` from binds +
`SDL_GameControllerGetAxis` (`:1001-1037`), with deadzone/sens per axis and an
optional stick swap (`:915-917`; note "right stick" here means the *left* stick
on your pad by default).

**The look-input seam is `inputMouseGetScaledDelta()` (`input.c:1419`)** — one
function, gated on `mouseLocked`, returning
`mouseD{X,Y} * (0.022f/3.5f) * mouseSens{X,Y}`. It has exactly three consumers:
`bondmove.c:823` (gameplay freelook), `player.c:5099`, `bondeyespy.c:945`; plus
`inputMouseGetAbsScaledDelta()` (`:1430`) for menus (`activemenutick.c:107`).

The units resolve cleanly to degrees, which is what the charter's
"absolute view-angle degrees" rule needs:

```
movedata.freelookdx                          bondmove.c:823
  -> fVar25 += freelookdx * mlookscale        :2284   (yaw; :2243 for pitch)
     mlookscale = 4 / lvupdate240 = 1/lvupdate60        :762
  -> player->speedtheta
  -> rotateamount = speedtheta * lvupdate60freal * 0.0174505 * 3.5   bondwalk.c:1456
```

so `degrees_this_frame = freelookdx * 3.5` — frame-rate independent by
construction, and with the mouse chain in place one mouse count at sensitivity
1.0 is 0.022°. **The iOS touch/gyro layer should write `freelookdx/dy = deg/3.5`
directly** (a `PLATFORM_IOS` branch in `inputMouseGetScaledDelta`, or a new
`inputLookSetDegrees()` the same call reads), never by synthesising mouse counts
through `mouseSensX/Y`. *Derived by reading the chain, not yet measured on a
running build.*

The pad's right stick is **not** a look axis here: `npad->rstick_x/y`
(`input.c:1028-1037`) go into the N64 pad struct for the game's own control
styles to interpret, and `cfg->stickCButtons` turns it into C-button presses
instead (`:1020-1027`). Touch look belongs on the mouse seam, not the rstick.
`$S/gamecontrollerdb.txt` is loaded if present (`input.c:891`).

## Config

`port/src/config.c`. Format is INI: `[Section]` then `Key = value`, values
optionally quoted (`configLoad`, `:310-363`). Settings register themselves from
`PD_CONSTRUCTOR` functions before `configInit()` (512 slots, `:24`; the table
has overflowed before). Path is `CONFIG_PATH = "$S/pd.ini"` (`include/config.h:6`).

**`configSave(CONFIG_PATH)` has exactly one caller: `cleanup()` at `main.c:124`,
an `atexit` handler.** A swipe-kill is SIGKILL, so on iOS `pd.ini` and the binds
would never be written. The scene lifecycle must call, synchronously on
`sceneWillResignActive` and in this order: `inputSaveBinds()` (`input.c:627` —
refreshes the bind strings the config entries point at), then
`configSave(CONFIG_PATH)`.

Saves themselves are safe: `osEepromLongWrite()` writes the whole EEPROM to
`$S/eeprom.bin` on every write (`libultra.c:317-330`), no buffering. See
`CLAUDE-notes/save-format.md`.

## Crash

- `crashInit()` (`port/src/crash.c:324`) installs handlers **only** under
  `PLATFORM_WIN32` or `PLATFORM_LINUX`. On Apple `g_CrashEnabled` stays 0 and
  **no signal handler is installed at all** — same trap as sm64coopdx. The iOS
  shell must bring its own.
- The report ring is live on every platform: `crashReportLogLine()`
  (`crashreport.c:42`) copies every `sysLogPrintf` line (`system.c:225`) into a
  lock-free ring of 200 × 192 bytes (`crashreport.h:42`). `crashReportSave()`
  (`:95`) writes `$S/crashreports/crash-YYYYmmdd-HHMMSS.txt` (version, channel,
  mod, `[Mod]` settings, the ring); `crashReportScan()` (`:184`) finds the
  newest at startup for the menu row.
- `sysFatalError()` (`system.c:309`) → `sysFatalDialog()` (`:242`): saves the
  report, then puts up an `SDL_ShowMessageBox` with **"Send report to Dab"**.
  Dead on iOS (see `docs/ios-deadlist.md`). See `CLAUDE-notes/crash-reports.md`.

## The XBLA import

`CLAUDE-notes/xbla.md` is the authority; the mechanics:

- `xblaImportInit()` runs inside `mainInit()` (`pdmain.c:259`) — it creates
  `xbla/` and detects what is in it (`xblaDetect()`, `xblaimport.c:333`),
  scanning two deep (`XBLAIMPORT_SCAN_DEPTH`, `:51`) for a package or a
  supported archive.
- Triggered by the Xbox 360 options page (`optionsmenu.c:5158`) or, headless, by
  `--xbla-import` (`xblaimport.c:1047`).
- `xblaImportStart()` (`:899`) creates `texture-packs/PD XBLA/textures/` and
  spawns **one SDL worker thread** `"pd-xbla"` (`:936`). `xblaImportTick()`
  (`:961`) is polled from `schedEndFrame()` (`pdsched.c:309`) and publishes
  stage/progress through SDL atomics; `SDL_WaitThread` joins it (`:987`).
  Textures.raw (166 MB) is streamed, never held (file header `:8-10`).
- An archive is unpacked **once** into `cache/xbla/` (`:58-59`, `xblaCacheDir`
  `:438`), trusted only when the marker `.extracted` (`:60`) sits beside a
  package (`xblaFindExtractedIn`, `:462`). Legacy `xbla/.unpacked` and
  `texture-packs/.xbla` are read, never written (`:62-69`).

## Threads (the audit surface)

main/game (everything above), plus SDL worker threads: `pd-xbla`
(xblaimport.c:936), `pd-texpack` (texpack.c:3607), `pd-ghostnet`
(ghostnet.c:1463), `pdcommunity` (community.c:731), `pdupdate` (update.c:629),
`pdcrashreport` (crashreportmenu.c:141), `pd-rec-vid`/`pd-rec-snd`/`pd-rec-probe`/
`pd-ffmpeg-get` (record.c:1731,1733,2246,2672). Of these only `pd-xbla` and
`pd-texpack` survive on iOS; the rest are on the deadlist.

## 3D — the visionOS stereo mode (Phase 6)

The plan is `docs/visionos-3d-plan.md`; this section is the frame map's own
answer to "where does the second eye come from, and what does it change?".

**The frame, in 3D.** Everything above still holds; four things move.

```
 schedStartFrame
   pdIosPacingWaitAtFrameStart   <- the wait, at the top of the frame (D-040).
                                    In 3D the thing it waits FOR is the
                                    compositor's cp_time_wait_until, not the
                                    display link (D-050): PDImmersive.m calls
                                    pdPacingSignalExternal() once a frame, the
                                    link is paused, `pacing_mode=compositor`.
                                    Still waits by running the main run loop
                                    (D-045) - SwiftUI and UIKit are on this
                                    thread.
 mainTick -> rdpCreateTask -> videoSubmitCommands -> gfx_run
   pdVisionEyeBeginPair()        <- selects eye L, and blocks while more than
                                    two published pairs are still in flight
   gfx_run_eye(commands)         <- EYE L: the whole of what gfx_run used to be
   pdVisionSetEye(PD_EYE_RIGHT)
   gfx_run_eye(commands)         <- EYE R, same display list, same game time
 schedEndFrame
   pdIosFrameHook -> pdVision3dFramePoll   <- mode changes happen HERE, at the
                                    frame boundary, on the game thread
```

**Where the eye is.** Slot 0 of the backend's framebuffer table - "the screen" -
resolves to `pdVisionEyeFBO()` (overlay patch 0031), which answers the FBO of
`ring[slot][eye]`. So the MSAA resolve, `copy_framebuffer`, the Vivid Colours /
Black Level grade pass and `read_screen_pixels` all follow the eye with nothing
above the backend changed. A pair is published ONCE, at the end of eye R
(`pdAngleSwapBuffers` -> `pdVisionEyePublish`, a no-op for eye L), carrying one
`(MTLSharedEvent, value)` for both textures; the compositor encodes a
`waitForEvent` on it and blits both eyes into its own mipmapped copies.

**Where the stereo is.** In the PROJECTION, folded at the two sites that form
MP - `gfx_sp_matrix`'s tail and `gfx_sp_pop_matrix` - and never into
`rsp.P_matrix` itself (a rewritten P compounds on the next `G_MTX_MUL` with
`G_MTX_PROJECTION`; sm64coopdx D-026). PD's matrices are row-vector, so folding
a view translation is `(T * P)`, whose only changed row is row 3:

```
eyeP[3][i] = P[3][i] - e * P[0][i]        e signed, +e is the RIGHT eye
eyeP[2][0] += -a * e / C                  a = P[0][0], C the convergence
```

**Four rules, from a TAG THE ENGINE EMITS** (D-055). The class used to be
recovered from the shape of P, and that was wrong on device: PD's lists
multiply into the projection (`G_MTX_MUL` with `G_MTX_PROJECTION`) and 4J's
XBLA mesh lists do it constantly, after which the product is no longer
axis-aligned and the shape test called it sky — 2290014 "sky" projections
against 2266415 "world" ones on the user's headset, so half the room drew with no
eye offset at all.

The engine says it instead. A tagged `G_NOOP` (`src/include/gbiex.h`,
`PD_DLTAG_*`, overlay patch 0032) names the class of the NEXT projection LOAD;
`gfx_sp_matrix` latches it; an untagged load is WORLD and a MUL into the
projection keeps the class of the load. Four sites in the whole engine carry a
tag.

| class | who tags it | what is folded |
|---|---|---|
| world | nobody — it is the default | translation + skew, `C` = **Convergence** (762 units = 25 ft, D-061), then a per-vertex **NEAR CLAMP** that saturates the crossed disparity at `U*2` (D-061) |
| sky | `vi.c` `vi0000ab78()`, which multiplies the camera ROTATION into P | **skew only** — a translation folded behind a rotation is a world-space shift, and at 2x zfar the skew's infinity term IS the correct disparity |
| gun | `vi.c` `vi0000aca4()` / `viSetPerspectiveWithFov()` when called with `znear < 5` (`bondgun.c:11426`/`:11441` pass 1.5; `menu.c:2429` passes 10 and is therefore WORLD) | translation + skew at `C_gun` = the viewmodel's measured NEAREST VERTEX (D-060), `e_gun = e * C_gun / conv`, **plus a constant skew that moves the whole weapon rigidly forward to `U*2.5..U*3.5`** so it is nearer than every world pixel it borders (D-061) |
| flat | `menu.c` `menuRender()` brackets itself as a SPAN — and **nothing else**: the `P[3][3] > 0.5` "orthographic" test is GONE (D-060; `guOrthoF` is called nowhere in this engine and `camGetOrthogonalMtxL()` is `View * P`, which is what draws the whole world) | **nothing** — bit-identical in both eyes, exactly ON the panel |

`stereo_cls_world/sky/gun/flat` in `3d state` are the session totals and
`stereo_frame_*` the last completed frame's, per eye. With the XBLA release on
in Chicago a frame reads world 44 / sky 0 / gun 6 / flat 21; sky is 0 there
because `vi0000ab78` is stage-gated and Chicago never calls it.

**Why the gun converges at its own depth and not at its znear.** The NDC x shift
a convergence `C` contributes is `a*e/C`. At `C = znear = 1.5` PD units (a
centimetre and a half) with the default `e = 3.15` that is ~2.7 NDC units —
more than a whole screen width — so the viewmodel drew outside the frustum in
both eyes. Its geometry actually sits at ~14 units (`gun_depth_avg`), so `C_gun`
is taken from the modelview about to be multiplied in (row 3 of a row-vector
modelview is the model origin in view space). Scaling `e_gun` with it makes the
panel-plane skew `a*e_gun/C_gun = a*e/conv` identical to the world's, so the gun
sits ON the panel — quake3e D-028 v2's real requirement — with a small
correctly-signed disparity across the weapon's own length.

**Units and defaults.** `constants.h:496` (`vv_eyeheight` ~ 160 for a 1.6-1.7 m
Joanna) makes **1 PD unit ~ 1 cm**. Half-separation `e = 3.15` units at Stereo
Depth 100 % is a 63 mm IPD; **Convergence 762 units = 25 ft = 7.62 m** and the shipped Stereo Depth is **150 %** (`e = 4.725`), both the user's numbers (D-061).

**2D carries zero disparity for free — except where it is TAGGED with a depth.**
PD's rectangles (`gfx_dp_fill_rectangle`, `gfx_dp_texture_rectangle`) are
computed straight in NDC and never touch `MP_matrix`, so the HUD, the menus and
the letterbox are bit-identical in both eyes without a special case. The M3 gate
asserts it on the letterbox rows of the replay's frame 1500. Two things opt OUT
of that, each by emitting `PD_DLTAG_DEPTH` before its rectangles, and each
shifted by exactly the (clamped) disparity the world fold would have given a
point at that depth:

* **light glares** (`artifact.c`, D-060) — one tag, one rectangle, the depth
  being `-lightscreenpos.z`, the fixture's own;
* **the crosshair** (`sight.c`, D-064) — one `cdExamLos08` trace along the aim
  ray per frame, smoothed 100 ms in `1/d`, held across the reticle's dozen
  rectangles by the sticky span `PD_DLSPAN_DEPTH_BEGIN/END`.

**Sign convention, as measured** (M3, `artifacts/sim/visionos-3d/m3/`): at
Stereo Depth 100 % on the chicago-solo replay's frame 1500 the two eyes differ
by a horizontal shift of a few pixels, and `04-shift-report.txt` records the
measured `shift_best`. Objects beyond the convergence distance are UNCROSSED -
eye R sees them further right than eye L; objects nearer than it are crossed.
The gun, converging at its own depth, is at zero disparity at the weapon's
origin and carries a small correctly-signed disparity across its own length —
"at the panel, never in front".

**What the compositor does with it.** `PDImmersive.m`: pacing, ARKit device
anchor, per-view `cp_view_get_view_texture_map` targeting, depth cleared AND
stored, the dim layer, then the panel quad. Each view samples its OWN eye's
copy (view 0 = L, view 1 = R); `PD_VP3D_SHOWEYE` forces the eye on the MONO
simulator. The panel's UV has **no V flip** - ANGLE-Metal reconciles GL's
bottom-left origin itself, so the wrapped texture's row 0 is already the GL
frame's top row. M2 shipped a flip here and the panel was upside down while
every pixel gate stayed green, because PD's readback un-flips its own rows.
