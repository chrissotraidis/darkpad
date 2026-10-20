# Upstream CLI and pd.ini — driving the game headlessly

Everything the command line and `pd.ini` offer for scripted, repeatable runs —
the raw material for the seeded replay (charter 0.3/0.4) and for the :8775
console bridge, which should expose these as live commands. Line numbers against
vendor pin `bfea0618`; paths relative to `vendor/dabs-mod/`.

## How arguments are parsed

There is no getopt. `sysInitArgs()` (`port/src/system.c:82`) stores `argc/argv`
and three helpers scan the whole vector on every call, case-insensitively
(`strcasecmp`):

| helper | `system.c` | behaviour |
|---|---|---|
| `sysArgCheck(name)` | `:120` | 1 if the flag appears anywhere |
| `sysArgGetString(name)` | `:142` | the **next** argv element, or NULL |
| `sysArgGetStringN(name, n)` | `:157` | the nth repetition's value (only `--moddir` uses it) |
| `sysArgGetInt(name, def)` | `:175` | `strtol(..., 0)` — so `0x26` works |

Consequences worth knowing: an unknown flag is silently ignored (there is no
validation pass and no `--help`); a flag's value may itself look like a flag; and
flags are read lazily — some are read *every stage load* (`--mpsims`,
`--rng-seed`, `--mp-weapons` in `pdmain.c`) rather than once at startup.

## The determinism set (the regression vehicle)

These are the flags upstream's own method rests on (`CLAUDE-notes/performance.md`,
"Measuring"). Together, two binaries play the same match tick for tick.

| flag | parsed at | what it does |
|---|---|---|
| `--rng-seed N` | `port/src/pdmain.c:359` | `rngSetSeed(N)` at the top of every stage load, instead of `osGetCount()`. `N < 0` means "use the clock". Re-read per stage, so it reseeds on each load |
| `--fixed-step` | `port/src/main.c:247` → `src/game/timing.c:57-65` | pins `diffframe60 = 1`, `diffframe240 = 4`, zeroes the lost-time accumulators. Every rendered frame is exactly one 60 Hz tick whatever the clock says. **Not a 60 fps cap** — it renders as fast as it can and the sim runs that much faster |
| `--exit-frame N` | `main.c:248` → `src/game/lv.c:2340` | `exit(0)` once `g_Vars.lvframenum >= N`. Level frames, not wall time, so a measured run covers the same frames at any speed. `exit(0)` runs `atexit(cleanup)`, so **`pd.ini` is rewritten** — see the pd.ini warning below |
| `--screenshot-frame N` | `main.c:249` → `lv.c:2334` | `screenshotRequest()` at level frame N exactly. The shot is taken in the pre-swap callback of that frame (`screenshot.c:174`) and lands in `screenshots/` |
| `--boot-stage 0xNN` | `main.c:253` | sets `g_StageNum`. Validated at `:258-275`: out of range, or a level id with no stage-table row, falls back to the title screen with a warning. Mod-loader stages count, because `modloaderInit()` has already run. Stage ids: `CLAUDE-notes/stage-numbers.md` |
| `--skip-intro` | `main.c:255` | shorthand for `--boot-stage 0x26` (`STAGE_CITRAINING`). Also settable as `Game.SkipIntro` |
| `--no-sound` | `main.c:218` | sets `g_SndDisabled`; `schedAudioFrame()` (`pdsched.c:257`) then skips `amgrFrame()`/`audioEndFrame()` entirely. The audio device is still opened by `audioInit()` |
| `--log` | `system.c:92` | opens `./pd.log`, falling back to `$H/pd.log` (`system.c:64-80`), truncating it. Without it `sysLogPrintf` still prints to stdout/stderr and still fills the crash ring |
| `--gfxstats N` | `main.c:223` | every N frames, log `gfx: N draws, N tris, N verts, tris/draw` plus flush-reason and texture-cache lines (`gfx_pc.cpp:3878-3900`) and `fps: %.1f` (`video.c:163-167`). **This is the line the replay diff compares** |
| `--profile N` | `main.c:281` | `g_FileAutoSelect` — auto-selects player profile N at the file screen, so a headless run does not sit on it. `-1` = off |

## Paths and data

| flag | parsed at | what it does |
|---|---|---|
| `--basedir PATH` | `port/src/fs.c:363` | `$B`. Default: `./data`, else `$H/data`, else `$E/data` |
| `--savedir PATH` | `fs.c:405` | `$S`. Default: `$E` if writable (with a one-time migration from the old location, `:434-446`), else `.`/`$H` |
| `--portable` | `fs.c:355` | `$H := $E`, and the save dir defaults to `$E` outright. Everything lives beside the executable |
| `--moddir PATH` | `fs.c:383-401` | mount a mod directory; **repeatable** (up to `FS_MAXMODDIRS` = 128). Only the first overlays the general file search (`fs.c:320-325`). Aliases accepted for the All in One launcher: `--gexmoddir`, `--kakarikomoddir`, `--darknoonmoddir`, `--goldfinger64moddir` |
| `--rom-file NAME` | `port/src/romdata.c:486` (also `:440`) | use NAME instead of `pd.ntsc-final.z64`, resolved through `fsFullPath()` |
| `--eeprom-file NAME` | `port/src/libultra.c:261` | use NAME instead of `$S/eeprom.bin`. A bare filename is taken as `$S/NAME`; `$`, absolute and `./` forms are used as-is. **The way to hand a scripted run a prepared save** |
| `--modfiles` | `romdata.c:631` | load file-table entries from mod dirs (see `CLAUDE-notes/mods.md`) |

## Multiplayer / Combat Simulator (the 80-simulant benchmark)

| flag | parsed at | what it does |
|---|---|---|
| `--mpsims N` | `port/src/pdmain.c:508` | boot straight into a Combat Sim match against N simulants. Applied to the booted stage **only once** (`mpsimsapplied`, `:507`) — re-arming it on a later stage load hangs the Carrington Institute (`:500-506`). Forces `MPFEATURE_8BOTS` when N > 4 (`:593-595`) because no profile is loaded and nothing is unlocked |
| `--mp-weaponset N` | `pdmain.c:544` | play with the Nth weapon set, as the Weapons menu would pick it. Requires `--mpsims > 0` (`:552`) |
| `--mp-weapons a,b,c,d,e,f` | `pdmain.c:550` | fill the six slots with those Combat Sim weapon indexes (as `--moddata-trace` numbers them). Requires `--mpsims > 0` (`:557`). Out-of-range values become `MPWEAPON_NONE` |
| `--endless` | `main.c:233` | `g_MpEndlessMatch` — the match does not end |
| `--spectate` | `main.c:232` | spectator from the first frame. Deliberately **not** the `Start Spectating` setting, so a headless run does not tick a box permanently |

## Renderer / tuning

| flag | parsed at | what it does |
|---|---|---|
| `--gfxbatch N` | `main.c:224` | `g_GfxMaxBufferedTris` — cap triangles per draw call. Tells a draw-call-bound frame from a vertex-bound one |
| `--gfxtexcache N` | `main.c:225` | `g_GfxTexCacheSize` |
| `--gl-version "3.3 core"` | `port/fast3d/gfx_sdl2.cpp:159` | prepend a context row before the built-in list; accepts `core`, `es`, or neither (compat). **This is how to force the ES 3.0 row for the 0.5 audit on the macOS oracle** |
| `--debug-gl` | `gfx_sdl2.cpp:103`, `gfx_opengl.cpp:1047` | request an `SDL_GL_CONTEXT_DEBUG_FLAG` context and install the KHR_debug callback |
| `--no-fog` | `src/game/env.c:408` | disable fog |

## XBLA, packs and one-shot tools (each exits when it runs)

| flag | parsed at | what it does |
|---|---|---|
| `--xbla-import` | `port/src/xblaimport.c:1051` (called from `pdmain.c:261`) | convert the XBLA package into the `PD XBLA` texture pack and `exit()`. The only way to exercise the conversion headlessly. Logs progress every 10% |
| `--xbla-mesh-verbose` | `main.c:250` | per-mesh logging from `xblamesh.c` |
| `--xbla-stage-verbose` | `main.c:251` | per-room logging from `xblastage.c` |
| `--dump-assets` / `--dump-textures` | `port/src/assetdump.c:1016` (called from `pdmain.c:260`) | dump everything and `exit(0)`. Writes gigabytes — see `docs/ios-deadlist.md` §6 |
| `--dump-texture LIST` | `src/game/lv.c:2195` | dump the named texture numbers, at level frame 300 exactly |
| `--fetch-ffmpeg` | `port/src/record.c:2628` (called from `pdmain.c:262`) | download an ffmpeg build and exit. Dead on iOS |
| `--texpack-trace` | `port/src/texpack.c:3205` | log every pack texture match |

## Traces (diagnostics; all off by default)

`--chr-trace` (`src/game/lv.c:2189` — a chr census at level frame 300 and every
1200 after), `--moddata-trace` (`port/src/moddata.c:2102` — also the source of
the weapon indexes `--mp-weapons` takes), `--setup-trace`
(`port/src/preprocess/filesetup.c:198`), `--random-run` / `--random-mission` /
`--run-autohop N` (`main.c:237,243,246` — Randomizer, see
`CLAUDE-notes/randomizer-run.md`), `--no-crash-handler` (`main.c:161`).

## pd.ini — what matters for a scripted run

Format: `[Section]` / `Key = value`, values optionally quoted; parsed in
`port/src/config.c:310-363`, written by `configSave()` (`:284`). Path is
`$S/pd.ini` (`port/include/config.h:6`). Every key is registered from a
`PD_CONSTRUCTOR` before `configInit()`, with a min/max that **clamps silently**
on load — a value outside the range does not warn, it changes.

> **Two traps upstream records and this port will hit.**
> 1. **The game rewrites pd.ini on exit** (`main.c:124`, via `atexit`) — including
>    after `--exit-frame`. Any key you `sed` in is rewritten from the live value.
>    Edit keys **in place**; a key appended at the end of the file lands in
>    whatever the last section happened to be and is ignored
>    (`CLAUDE-notes/performance.md`).
> 2. The writer emits sections in registration order, so `[Mod]` **appears
>    twice**. Same note.

Keys that matter for headless/benchmark runs (all registered in
`port/src/main.c:291-431` unless noted):

| key | default | why it matters |
|---|---|---|
| `[Video] VSync` | 1 | `video.c:798`. 0 to let the run go as fast as it can |
| `[Video] FramerateLimit` | 0 | `video.c:800`. 0 + VSync 0 is clamped to 240 (`video.c:707`) |
| `[Video] DefaultWidth` / `DefaultHeight` | 0 | `video.c:793-794` |
| `[Video] DefaultFullscreen` | — | `video.c:791` |
| `[Video] MSAA` | 1 | `video.c:803`; clamped to the GPU's max at `gfx_pc.cpp:3838-3843` |
| `[Video] FramebufferEffects` | 1 | `video.c:799` — gates the framebuffer path MSAA needs |
| `[Video] TextureFilter` / `MipmapFilter` / `AnisotropicFilter` | 1 / 2 / 4 | `video.c:804,808,809` — **pin these before any A/B** |
| `[Video] DisplayFPS`, `DisplayFPSInterval` | 0, 1.0 | `video.c:801-802` |
| `[Game] MemorySize` | 64 MB | `main.c:293` — raised from upstream's 16 for 80 simulants + persistent bodies (`main.c:42-48`). **A pd.ini written by an older build still says 16** |
| `[Game] TickRateDivisor` | 1 | `main.c:297` — `g_Vars.mininc60`; divides the tick rate |
| `[Game] ExtraSleep` | 1 | `main.c:298` — a 100 µs sleep per spin in the tick gate |
| `[Game] SkipIntro` | 0 | `main.c:299` — same effect as `--skip-intro` |
| `[Mod] GuardsAlerted`, `AlertedGuards`, `GuardSpawnSpeed`, `StartArmedFor` | 0, …, … | `main.c:324-327,312` — upstream's 80-simulant benchmark settings |
| `[Mod] Bodies`, `BodyTime`, `BodiesDrawn` | — | `main.c:321-323` — the fork's persistent bodies, a load-bearing perf variable |
| `[Mod] EnhanceTextures`, `SmoothText`, `VividColours`, `BlackLevel`, `CleanTextOutlines`, `ModelLod` | — | `main.c:350-354,335` — Extended Options' Picture settings; `EnhanceTextures` at 8× multiplies VRAM ×16 (`docs/memory-math.md`) |
| `[Mod] XblaPackage` | "" | `xblaimport.c:1085` — an explicit path to the XBLA package, tried before any directory scan (`xblaimport.c:348`) |
| `[Mod] XblaMeshKey` | `F6` | `xblaswitch.c:111` — the whole-release toggle |
| `[Mod] ScreenshotKey` | `F12` | `screenshot.c:179` |
| `[Mod] RecordKey`, `TraceKey`, `DumpTexturesKey`, `TexturePackKey`, `TexturePackReloadKey`, `TexturePackCycleKey` | F11, F3, F7, F8, F9, F10 | `record.c:2730`, `trace.c:392`, `texpack.c:5074-5077` |
| `[Mod] GhostServer`, `UpdateServer` | ghost URL / "" | `main.c:410,413` — network endpoints; leave empty on iOS |
| `[Audio] BufferSize`, `QueueLimit` | 512, 8192 | `audio.c:85-86` |
| `[Game] PlayerN.*` | — | `main.c:415-431` — FOV, mouse aim mode and speeds, crosshair, crouch mode, extended controls, per player 1–4 |

Binds live in the same file, written by `inputSaveBinds()` (`input.c:627`) into
the registered strings just before `configSave()`; `$S/gamecontrollerdb.txt` is
loaded if present (`input.c:891`).

Settings table capacity is **512** (`config.c:24`) and upstream has already
overflowed 300 once — a registration past the limit is dropped with a warning and
that setting then silently neither loads nor saves. Any iOS-added key counts
against it.

## Not determined

- Whether `--boot-stage` reaches a Combat Sim arena without `--mpsims` (the
  stage table has MP stages, but `mpsims` is what sets `lvmpbotlevel`).
- Exact `--mp-weapons` index numbering — it is "as `--moddata-trace` numbers
  them" (`pdmain.c:546-549`), which means running that trace once and recording
  the table (a 0.4 task).
- Whether any flag can select difficulty; `mainLoop()` reads `-hard<N>` from the
  N64-era `argSetString` mechanism (`pdmain.c:344-346`), not from `argv`.
