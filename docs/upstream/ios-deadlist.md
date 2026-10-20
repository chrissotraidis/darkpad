# iOS deadlist — desktop-only paths in Dab's Mod

Every upstream path that cannot exist on iOS/visionOS, why, and what happens to
it. Line numbers against vendor pin `bfea0618`; paths relative to
`vendor/dabs-mod/`. Dispositions are proposals for DECISIONS.md, not decisions.

Four dispositions are used:

- **COMPILE OUT** — `#if !defined(PLATFORM_IOS)` around the implementation, with
  the header keeping a stub, as upstream already does for `PLATFORM_N64`
  (e.g. `xblaswitch.c:114-122`, `assetdump.c:1029-1037`). That pattern exists;
  copy it rather than inventing one.
- **HIDE THE ROW** — the code compiles but the menu item is not offered.
- **SEAM** — the call site stays and a platform implementation replaces the body.
- **KEEP** — works as-is, listed only because it looks dead and is not.

---

## 1. Video recording (ffmpeg) — `port/src/record.c` (78 kB, the biggest one)

**Why dead:** it spawns an external encoder. `fork()` + `execvp()`
(`record.c:1126`, `:1169`), `popen()` (`:1295`), `system()` (`:817`, `:1493`) —
iOS has no `fork`/`exec` of a second binary, no shell, and nothing to spawn.
The macOS row even names `h264_videotoolbox` (`:580-589`), which tempts a
"just use VideoToolbox" rewrite — that is a new feature, not a port.

**Also dead with it:** the ffmpeg *download* (`--fetch-ffmpeg`,
`recordFetchFromCommandLine()` `:2628`, worker `pd-ffmpeg-get` `:2672`,
`ffmpeg/` under `$E`/`$S` `:90`, `:2426-2432`) — libcurl, and a downloaded
executable, both illegal.

**Disposition:** COMPILE OUT the whole translation unit behind `PLATFORM_IOS`,
stubbing `recordInit/recordTick/recordStop/recordPushAudio/recordFetchFromCommandLine`
(callers: `main.c:186`, `main.c:119`, `pdsched.c:310`, `audio.c:76`,
`pdmain.c:262`). HIDE the Recording rows and the `Mod.RecordKey` (**F11**) bind.
See `CLAUDE-notes/recording.md`.

## 2. Check for Updates — `port/src/update.c`, `port/src/updatemenu.c`

**Why dead:** it replaces the running executable. `updateExec()` ends in
`execv(path, sysGetArgv())` (`update.c:879`); staging is two `rename()` calls
over the binary (`:521-534`); the self path comes from `_NSGetExecutablePath`
(`:177`). A sideloaded iOS app cannot rewrite its own signed bundle, and the
bundle is read-only anyway. The download half is libcurl (§7).

**Disposition:** COMPILE OUT (`updateInit` `main.c:188`, `updateShutdown` +
`updateRelaunchIfStaged` `main.c:137,148`, `updateRelaunchSelf` `main.c:153`).
HIDE the "Check for Updates" row — `src/game/mainmenu.c:4995-5002`, which is
already inside a `#ifndef PLATFORM_N64` block (`:4994`), so the gate is one
`&& !PLATFORM_IOS` away. Keep `sysRequestRestart()`'s *state* but make restart a
no-op: `updateRelaunchSelf()` is also how the "restart to mount a mod" flow works
(`main.c:152-154`), and on iOS that has to become "tell the player to relaunch".
See `CLAUDE-notes/updater.md`.

## 3. The crash dialog and "Send report to Dab" — `port/src/system.c`, `crashreport*.c`

**Why dead (three separate reasons):**
- `sysFatalDialog()` (`system.c:242`) puts up an `SDL_ShowMessageBox` with two
  buttons. SDL's iOS message box is a UIAlertController on the main thread — it
  cannot be shown from a crashed process mid-signal and cannot be shown at all
  from a background thread.
- "Send report to Dab" is `crashReportSend()` → `ghostnetSend()` → libcurl (§7);
  `crashReportCanSend()` (`crashreport.c:224`) already returns false without
  `PD_GHOST_NET`, so the button simply disappears when curl is off.
- `crashInit()` (`crash.c:324`) installs handlers only under `PLATFORM_WIN32` or
  `PLATFORM_LINUX` — **on Apple there is no handler at all today**, so there is
  nothing to disable, only something to add.

**Disposition:** SEAM. `sysFatalDialog` gets a `PLATFORM_IOS` body that writes
the report and logs, no message box. The shell installs its own signal handler
and appends to `Documents/crash.txt` (charter Phase 1). KEEP
`crashReportSave()`/`crashReportScan()`/the 200-line ring
(`crashreport.c:32-46,95,184`) — they are pure file I/O and are the most valuable
thing in this family. HIDE the "Send Crash Report" row
(`src/game/mainmenu.c:5003-5010`) until §7 lands. See `CLAUDE-notes/crash-reports.md`.

## 4. Community Packs — `port/src/community.c`, `communitymenu.c`

**Why dead:** libcurl (§7) against `https://api.github.com/repos/%s/releases/latest`
(`community.c:36`) and then a release asset download to `.community-download`
(`:56`, `:564-624`), on worker thread `pdcommunity` (`:731`).

**Disposition:** HIDE the "Community Packs..." row
(`port/src/optionsmenu.c:5417-5427`) for 1.0; COMPILE OUT `communityTick`
(`pdsched.c:308`) / `communityShutdown` (`main.c:141`) only if the stub
`ghostnetSend` (§7) is not linked. This is the feature the charter most wants
back (one-tap PD Plus HD on a phone with no file manager habits), so keep the
call sites intact.

## 5. Ghost Trials online — `port/src/ghostnet.c`, `ghostmenu.c`, `ghostrecovery.c`

**Why dead:** libcurl (§7). The local half (recording and racing your own
ghosts) is file I/O and is **not** dead — only the leaderboard, the account and
the downloads are. `ghostnetIsAvailable()` (`ghostnet.c:1473`) is the existing
gate. See `CLAUDE-notes/ghost-trials.md`.

**Disposition:** build with the stub transport; HIDE the account/leaderboard
rows. KEEP local ghosts.

## 6. Dump All Assets — `port/src/assetdump.c`

**Why dead:** it writes gigabytes into `$E`/`$S`. On iOS that is the user's
Documents container and the app gets killed for disk pressure or the device
fills. `--dump-assets` / `--dump-textures` also `exit(0)` when done
(`assetdump.c:1014-1027`), which is fine headless and pointless on a phone.
`texpack.c:3114,3212` similarly dump PNGs to `$E`.

**Disposition:** HIDE the "Dump All Assets To Disk" row
(`port/src/optionsmenu.c:4724-4751`). The file already has a `#else` stub block
(`:1029-1037`) for `PLATFORM_N64` — extend that gate. Keep the CLI flags working
on the macOS oracle.

## 7. libcurl — the concrete call-site list (input to charter 0.7)

**iOS has no libcurl in the SDK.** The good news, verified by grep: curl appears
in **exactly one file**.

| what | where |
|---|---|
| `#include <curl/curl.h>` | `port/src/ghostnet.c:21`, under `#elif defined(PD_HAVE_CURL)` (`:20`) |
| the one curl implementation of the transport | `ghostnet.c:739` `ghostnetSend()` — `curl_easy_init/setopt×14/perform/getinfo/cleanup`, plus `curl_global_init`/`curl_global_cleanup` in the module's init/shutdown |
| the WinHTTP implementation of the same function | `ghostnet.c:532` |
| the **stub** implementation | `ghostnet.c:1885` — returns false, "this build has no network support" |
| build flag | `find_package(CURL)` → `-DPD_HAVE_CURL` (`CMakeLists.txt:281-287`), which sets `PD_GHOST_NET` (`port/include/ghostnet.h:31-33`). Not found = a loud CMake `WARNING`, not an error (`:293-296`) |

**So there is exactly ONE function to port, not a scattering.** `ghostnetSend()`
is a blocking request/response with an optional file sink and a progress/cancel
callback (`ghostnet.c:735-737`); everything above it is transport-agnostic by
design (`ghostnet.c:33-36`).

Its **ten call sites across five files** (four of them inside `ghostnet.c`
itself), and what thread each runs on:

| # | call site | what it does | thread |
|---|---|---|---|
| 1 | `ghostnet.c:953` | ghost account sign-in / register | `pd-ghostnet` worker (`:1463`) |
| 2 | `ghostnet.c:1003`, `:1218`, `:1312` | board fetch, run upload, run download | same worker |
| 3 | `community.c:444` | GitHub releases JSON for a pack repo | `pdcommunity` worker (`:731`) |
| 4 | `community.c:602` | pack asset download (streams to a `FILE *` sink) | same worker |
| 5 | `update.c:324`, `:476` | version manifest, then the new binary | `pdupdate` worker (`:629`) |
| 6 | `crashreport.c:309` | crash report upload | **main thread, inside the crash** (`system.c:294`) — and also `pdcrashreport` (`crashreportmenu.c:141`) for the menu path |
| 7 | `record.c:2543` | ffmpeg build download | `pd-ffmpeg-get` (`:2672`) |

All but #6's fatal-dialog path are off-thread, so an **NSURLSession seam behind
`ghostnetSend()` would have to be made synchronous** (semaphore-wait on a data
task) to preserve the contract — which is legal on a worker thread and illegal
on the main thread, i.e. #6's crash path would need to become fire-and-forget or
be dropped. A vendored static curl needs no such care. Sites #5 and #7 are dead
regardless (§1, §2), so a 1.0 that only needs #1–#4 is a coherent target.

Default if unanswered (charter 0.7): build with the `ghostnet.c:1885` stub, which
is upstream's own supported configuration.

## 8. The offscreen perf harness — `tools/perf/*`, `SDL_VIDEODRIVER=offscreen`

**Why dead:** SDL's `offscreen` video driver is Linux/Mesa; `perf stat` /
`perf record` are Linux. Upstream also records that it renders 640×480 whatever
`pd.ini` says (`CLAUDE-notes/performance.md`, "the offscreen driver renders
640x480").

**Disposition:** macOS-oracle-only, as the charter says. The iOS equivalent is
`--fixed-step --rng-seed --exit-frame --screenshot-frame` driven through the
:8775 bridge (`docs/upstream-cli.md`).

## 9. Window management that has no meaning on iOS

| what | where | disposition |
|---|---|---|
| fullscreen toggles, exclusive fullscreen | `gfx_sdl2.cpp:45-62,221-235`; alt-enter at `:296-299`; `Video.DefaultFullscreen`, `Video.ExclusiveFullscreen` (`video.c:791,795`) | SEAM: force fullscreen true, HIDE the rows |
| maximize / window position / centering | `gfx_sdl2.cpp:64-71,249-289`; `Video.DefaultMaximize`, `Video.CenterWindow` | HIDE the rows |
| the display-mode list | `gfx_sdl_get_num_display_modes()` `gfx_sdl2.cpp:426`, `get_display_mode` `:404`, consumed by `videoInitDisplayModes()` (`video.c:402`) | SEAM: one mode = the drawable size. The resolution picker must not offer anything else |
| `set_closest_resolution` | `gfx_sdl2.cpp:265` — `SDL_SetWindowDisplayMode` | SEAM: no-op |
| resize handling | `gfx_sdl2.cpp:301-306` (`SDL_WINDOWEVENT_SIZE_CHANGED`) | **KEEP** — this is exactly how the synthetic size event after the UIScene graft reaches the renderer |
| `exit(0)` on window close / `SDL_QUIT` | `gfx_sdl2.cpp:307-316` | KEEP but audit: `exit()` runs `atexit(cleanup)` and so is the only thing that writes `pd.ini` |
| cursor visibility, relative mouse mode | `gfx_sdl2.cpp:241-247`, `input.c:1395-1398` | COMPILE OUT / no-op |
| "Exit Game" menu row | `src/game/mainmenu.c:5011-5018` | HIDE — iOS apps do not quit themselves |

## 10. Keyboard-only hotkeys (need settings-page equivalents)

Each is a `Mod.*Key` config string resolved to a scancode at first use and polled
once a frame from `schedEndFrame()` (`pdsched.c:303-309`). With no keyboard they
are unreachable, and two of them are *features* on this port:

| key | what | where | iOS equivalent |
|---|---|---|---|
| **F6** | the whole XBLA release on/off | `xblaswitch.c:57` (`Mod.XblaMeshKey`), tick `:90` | **Required** — settings-page toggle calling `xblaSwitchSetEnabled()` (Phase 2 acceptance) |
| **F12** | screenshot | `screenshot.c:24` (`Mod.ScreenshotKey`), tick `:161` | Keep: settings row + write to `Documents/screenshots` and the Photos roll |
| F7 | dump textures | `texpack.c:136` (`Mod.DumpTexturesKey`) | HIDE (see §6) |
| F8 | texture pack on/off | `texpack.c:137` | settings-page toggle |
| F9 | texture pack reload | `texpack.c:138` | settings-page button (useful after a Files drop) |
| F10 | cycle texture pack | `texpack.c:139` | settings-page picker |
| F11 | start/stop recording | `record.c:54` (`Mod.RecordKey`) | HIDE (§1) |
| F3 | trace | `trace.c:33` (`Mod.TraceKey`) | bridge command only |
| ESC | pause | `bondmove.c:832` | pad Start / touch button |

Every one of them can also be driven from the :8775 console bridge, which is how
`scripts/sim-validate.sh` should exercise them.

## 11. Paths relative to the executable / `fopen` that will fail

Not "dead" so much as silently wrong once `$E` is a read-only bundle:

- `sysLogSetPath()` (`system.c:64-80`) tries `./pd.log` then `$H/pd.log` —
  the working directory of an iOS app is `/`. **SEAM**: point `--log` at
  Documents.
- `fsChooseOutputDir()` (`fs.c:696`) tries `$E` first and silently falls back to
  `$S`. It is a fallback, not a failure, but it means `screenshots/`,
  `texture-packs/`, `model-packs/`, `xbla/` and `cache/` all land wherever `$S`
  is — which is why both roots must resolve to Documents (except `cache/`).
- `texpack.c:3114`, `:3212` write `$E/texdump_*.png` / `$E/texmatch_*.png`
  directly, with no `fsChooseOutputDir`. Debug-only; COMPILE OUT or redirect.
- `fsMigrateSaves()` (`fs.c:256`, called `fs.c:443`) copies an old save dir into
  `$E` on first run. Harmless on iOS (both are Documents) but it must not run
  before the shell has decided the roots.
- `sysGetHomePath()` = `SDL_GetPrefPath("", "perfectdark")` (`system.c:391`) →
  `~/Library/Application Support/perfectdark` on Apple: real, writable, and
  **invisible in Files**. Must not be where user data lands.

## 12. Things that look dead and are not (KEEP)

- **SDL audio** — no callback thread; the game thread queues with
  `SDL_QueueAudio` (`audio.c:73`). Only the `AVAudioSession` category is ours.
- **The XBLA unpack worker** (`pd-xbla`, `xblaimport.c:936`) and the **texture
  pack decode worker** (`pd-texpack`, `texpack.c:3607`) — plain file/CPU work,
  both survive.
- **unrar / LZMA SDK / minimp3** — statically linked C/C++, no JIT, fine.
  (The UnRAR licence paragraph must be carried into the README.)
- **`crashReportSave`/`Scan`/the ring** — file I/O only (§3).
- **`--dump-assets` and the perf flags on the macOS oracle** — the oracle is the
  parity reference; nothing here changes it.

---

### Count

**11 dead-or-seamed families** (§1–§11), of which 4 compile out whole
(recording, updater, asset dump, the fatal dialog's message box), 5 are
menu-row hides, and the rest are seams. **libcurl: 1 include, 1 transport
function, 10 call sites in 5 files** — the smallest possible surface for the 0.7
decision.

### Not yet determined

- Whether SDL2's iOS backend will even deliver `SDL_WINDOWEVENT_SIZE_CHANGED`
  for the grafted scene, or whether the shell must push it (family prior says
  push it).
- Whether `optionsmenu.c`'s rows can be hidden by a flag or need the item arrays
  edited (the arrays are static initialisers; `MENUITEMTYPE_END` terminates, so
  a conditional row needs either a runtime filter or a second array).
- Whether `exit(0)` from `gfx_sdl2.cpp:311/315` is reachable on iOS at all — if
  not, `atexit(cleanup)` never runs and `pd.ini` is *only* ever written by the
  resign-active hook.

---

## 13. What the c18645860 bump added (1.0.1, 2026-10-01)

1,282 upstream commits. Searched for new `system`/`popen`/`fork`/`exec*`/
`posix_spawn`/`dlopen` (none: the only ones are still `record.c` and
`update.c:1432`), new `ghostnetSend()` call sites (four more in `update.c`,
all behind `updateIsAvailable()`), new threads (Vulkan's `std::thread`, not
built) and new menu rows (33 new handlers in `optionsmenu.c`).

| what | where | disposition |
|---|---|---|
| **Update notice** — at every launch, asks GitHub for a newer desktop build and opens a "new version" dialog on the main menu | `updatemenu.c` `updatenoticeStart()` (from `main.c`), gated on `updateIsAvailable()` | **COMPILE OUT** by gate: patch **0041** makes `updateIsAvailable()` false on iOS, which also takes every `update.c` network site with it |
| **Patch notes popup** — Dab's desktop changelog, once after an update (all 29 entries to an install whose `pd.ini` predates them) | `patchnotes.c` `patchnotesInit()` | **SEAM** (0041): marked seen on iOS, never opens. The notes page lives under the hidden Check for Updates row |
| **Vulkan renderer** | `gfx_vulkan.cpp`, `CMakeLists.txt` `PD_VULKAN` (found by `find_path`; Homebrew's vulkan headers are on this Mac, only a missing static shaderc keeps it off) | **COMPILE OUT**: `build-ios.sh` passes `-DPD_VULKAN=OFF`. **HIDE** Video > Renderer (0041): one renderer, and it is ANGLE-Metal, not the "OpenGL" the row names |
| Advanced > **HiDPI Window** | `optionsmenu.c` `advancedRestartRows[0]` | **HIDE** (0041): patch 0017 forces the native drawable whatever `Video.AllowHiDpi` says |
| Advanced > **HIDAPI Controllers** | `advancedRestartRows[2]` | **HIDE** (0041): the shell forces HIDAPI off at OVERRIDE priority (D-030) |
| Advanced > Raw Input Controllers | `advancedRestartRows[3]` | already hidden off Windows by upstream |
| **added-content/** — one folder for the XBLA release, the GoldenEye ROM and GoldenEye XBLA; `xbla/` is MOVED into it on first look | `fs.c` `fsAddedContentDir()`, `xblaimport.c` `xblaDetect()` | **KEEP**, and the shell follows it: `PDXbla` scans `added-content/` then `xbla/`, the Files picker copies into `added-content/` (it is a move, nothing is deleted - ground rule 5) |
| **Restart Now** under GoldenEye XBLA: Community Edition | `optionsmenu.c` `menuhandlerGeXblaCeRestart` → `sysRequestRestart()` | **KEEP**, as the Mods page's Restart rows already were: on iOS it quits through `cleanup()` and the player relaunches. Only shown with a GoldenEye XBLA CE zip in `added-content/` |
| Advanced > **Offer to Send Reports** (F3's Report a Problem → pdghostd) | `tracereport.c` | **KEEP**: curl is linked (D-028) and F3 is a hardware-keyboard key; the same question as Q-012 for crash reports, not new |
| SMAA / Upscaling (FSR 1) / Supersampling / TAA | `gfx_post.cpp`, `gfx_opengl.cpp` post chain | **KEEP**, all off by default. FSR needs GL 4.2 and is skipped on ES 3.0 (`gfx_opengl_post_pass_ok`): Upscaling then falls back to a plain scaled blit. Checked on lane 3 - see `artifacts/sim/bump-1.0.1/00-README.txt` |
| Recast/Detour (simulant navmesh, `Mod.SimBrain`) | `port/src/external/recastnavigation`, `simnav*.cpp` | **KEEP**: plain C++, builds for all four slices |
| HDiffPatch (GoldenEye XBLA CE updater the player supplies) | `port/src/external/hdiffpatch` | **KEEP**: file I/O only |
| Language packs | `lang/`, `tools/langpack/build.py` at build time | **KEEP**: embedded at build time by host Python |

## 14. GE Plus on iOS (checked 2026-10-02, 1.0.1.1)

GE Plus (GoldenEye 007 from the player's own ROM, and the GoldenEye XBLA release's
HD art) was run end to end on the lane-3 and Vision Pro simulators. Nothing in it
reaches for a subprocess, a file dialog, a download or a keyboard-only prompt; its
folder screens, intro and watch menu work with the touch pointer (D-022) and the
pad. What changed for iOS:

| what | where | disposition |
|---|---|---|
| Startup conversion / GoldenEye XBLA unpack / CE patch notices | `gexplusrom.c` `gexPlusRomNotice()`, called in a loop on the game (= main) thread | **SEAM** (0042): one `SDL_PumpEvents()` per notice frame so the app answers resign/background during a multi-second wait |
| Converted arenas | `gexplusrom.c` containers, `mod.c` `modListRefresh()` | **SEAM** (0043): `$C/mods` (Caches) first; an older `Documents/mods` copy is still used |
| GE Plus's crosshair in 3D | `sight.c` GE branch returns before the D-064 span | **SEAM** (0044, visionOS 3D only) |
| GE Plus's folder screens in 3D | `menu.c` calls `gexFrontRender()` before the flat span | **SEAM** (0045, visionOS 3D only) |
| "Needs a GoldenEye 007 (US) ROM in added-content/, then restart." | `mainmenu.c` GE Plus status label | **KEEP**: true on iOS too (close and reopen); the settings rows say "the next time you open the app" |
| Asset dump of GoldenEye's models | `assetdump.c` | already hidden with Dump All Assets |
