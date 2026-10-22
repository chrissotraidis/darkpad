# Building — from a fresh clone to an app on the lane-3 simulator

Everything here is deterministic and scripted; a second Mac with Xcode, the
siblings on disk and Homebrew's `cmake ninja xcodegen` can run it top to bottom.
No game data is needed to build.

## One command at a time, from a fresh clone

```sh
git clone <this repo> perfect-dark-ios && cd perfect-dark-ios

scripts/bootstrap.sh              # clone/checkout vendor/dabs-mod at UPSTREAM_PIN
# recreate the work/ symlinks — see work/deps-PROVENANCE.md for the ln lines
scripts/apply-overlay.sh          # vendor + overlay/patches/*.patch -> build/src
scripts/build-ios.sh simulator    # -> build/ios-simulator/libpd.a
scripts/build-ios.sh device       # -> build/ios-device/libpd.a
scripts/gen-app-project.sh        # -> app/perfectdark.xcodeproj (+ xcframeworks)

xcodebuild -project app/perfectdark.xcodeproj -scheme perfectdark \
  -configuration Debug -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17e,OS=27.0' \
  -derivedDataPath build/dd-sim CODE_SIGNING_ALLOWED=NO build

SIM=$(xcrun simctl list devices available | awk -F'[()]' '/iPhone 17e/{print $2; exit}')
xcrun simctl boot "$SIM"
xcrun simctl install "$SIM" \
  build/dd-sim/Build/Products/Debug-iphonesimulator/perfectdark.app
C=$(xcrun simctl get_app_container "$SIM" com.rebelancap.perfectdark data)
cp work/gamedata/pd.ntsc-final.z64 "$C/Documents/"
xcrun simctl launch "$SIM" com.rebelancap.perfectdark --skip-intro
xcrun simctl shutdown "$SIM"      # ALWAYS, including on failure
```

## The pieces

**`scripts/bootstrap.sh`** — clones `DabDavis/perfect-dark-dabs-mod` into
`vendor/dabs-mod` and detaches it at `UPSTREAM_PIN`. That file is the only place
the upstream commit is named. `vendor/` is never edited (ground rule 1).

**`scripts/apply-overlay.sh [dest]`** — `rsync -ac --delete --exclude .git` of
the pinned tree into `build/src`, then every `overlay/patches/*.patch` in order
with `patch -p1 --fuzz=0`. The first reject stops the script and prints it.
Additive files (`app/gfx/gfx_angle_egl.mm`, the iOS shell) are **never copied
into the tree** — CMake takes them by absolute path — so the overlay tree is
exactly upstream plus the numbered patches, and a diff against `vendor/` is
reviewable.

**`scripts/bump-upstream.sh <commit|branch|--dry-run>`** — the drill. Moves the
pin, re-bootstraps, re-applies the overlay into `build/bump-src` with
`PD_OVERLAY_KEEP_GOING=1` so *every* failing patch is reported rather than only
the first, and prints the upstream shortlog across the bump. `--dry-run`
re-tests the current pin; that no-op must be green before anything else.

**`scripts/build-ios.sh [device|simulator]`** — the CMake cross-build. Produces
`build/ios-{device,simulator}/libpd.a` (arm64, `minos 15.0`). What it pins down:

- `-DCMAKE_SYSTEM_NAME=iOS`, which lights up `PD_IOS` in CMake and `PLATFORM_IOS`
  in `platform.h` (patch 0008);
- `-DPD_STATIC_LIB=ON` — the engine is a library, not an executable (D-009);
- the **D-005 parity flags on iOS too**: `-ffp-contract=off -fno-builtin-sinf
  -fno-builtin-cosf`, plus `-I<deps>/include -I<deps>/include/SDL2` because the
  tree mixes `<SDL.h>` and `<SDL2/SDL.h>`;
- `-DPD_CURL_DIR=work/curl-<sdk>` — the static curl 8.11.0 slice (D-028,
  `docs/curl.md`). It is passed rather than searched for because a cross build
  with Homebrew on the machine finds `/opt/homebrew`'s macOS libcurl and links
  it into an iOS binary; patch 0040 gives the PD_IOS path its own arm that never
  calls `find_package(CURL)`, which is why the old
  `-DCMAKE_DISABLE_FIND_PACKAGE_CURL=ON` is gone. Unset it and the build falls
  back to `ghostnet.c`'s stub transport, upstream's own supported configuration;
- SDL2 by explicit cache variables (`SDL2_INCLUDE_DIR`, `SDL2_LIBRARY_TEMP`,
  `SDL2MAIN_LIBRARY`), because upstream's vendored `FindSDL2.cmake` is the
  classic search-the-system module and has nothing to find inside an iOS
  sysroot;
- zlib from the SDK, found by CMake's own `FindZLIB`.

**`scripts/make-angle-xcframeworks.sh`** — wraps the two ANGLE iOS framework
slices into `work/angle-xcframeworks/lib{EGL,GLESv2}.xcframework`. Xcode cannot
pick device vs simulator out of a plain `.framework` path, and a build-setting
variable inside the path is not resolved by the embed phase.

**`scripts/gen-app-project.sh`** — writes `app/ios/build_stamp.h`, stamps
`VERSION`/`DEV_ITERATION` into a generated spec and runs xcodegen. The
`.xcodeproj` is generated and gitignored; never edit it.

## What is symlinked from siblings, and why

`work/deps-PROVENANCE.md` is the authority. In short:

| link | points at | why not a copy |
|---|---|---|
| `work/angle-ios-{device,simulator}`, `work/angle-include` | `~/dev/realrtcw-ios/work/angle` | one 14 GB ANGLE checkout serves every port; rebuilding is hours of gn/ninja |
| `work/angle-mac` | the same checkout's macOS slice | the Phase 0.5 spike's substrate |
| `work/deps-{iphoneos,iphonesimulator}` | `~/dev/dhewm3-ios/work/deps-*` | identical recipe (SDL2 2.32.8, arm64, minos 15.0, verified with `otool -l`); a second build tree for nothing |

Disk hygiene rule: don't duplicate what can be linked. Everything above is
gitignored and re-creatable from the provenance file in one paste.

## The app bundle (D-009: xcodegen)

`app/project.yml` describes one iOS target whose only sources are
`app/ios/pd_ios_main.m` and the asset catalog; everything else comes out of
`libpd.a`. `PD_SLICE` (`device` / `simulator`, selected by
`[sdk=iphonesimulator*]`) is what puts the right `build/ios-*` on
`LIBRARY_SEARCH_PATHS`, and `$(PLATFORM_NAME)` does the same for
`work/deps-*`.

The shell (`app/ios/pd_ios_main.m`) owns `main()`: it publishes
`PD_IOS_DOCUMENTS` / `PD_IOS_CACHES`, writes `Documents/launch-beacon.txt`,
assembles argv from the process arguments plus `Documents/pd.args`, registers
the resign-active hook, and calls `SDL_UIKitRunApp(argc, argv, …)`, which brings
up UIApplication and calls back into `pdEngineMain()` (patch 0010).

## Where the player's files go

Both data roots are the app's **Documents** directory (patch 0009):
`pd.ntsc-final.z64` (or `data/pd.ntsc-final.z64`), `pd.ini`, `eeprom.bin`,
`screenshots/`, `texture-packs/`, `model-packs/`, `xbla/`, `mods/`, `pd.log`.
`cache/` alone goes to **Caches** through the new `$C` placeholder. With
`UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` that folder is the
onboarding surface in the Files app.

## Running the seeded replay on the simulator

```sh
xcrun simctl launch <udid> com.rebelancap.perfectdark \
  --rng-seed 1234 --fixed-step --exit-frame 2000 --screenshot-frame 1500 \
  --skip-intro --no-sound --gfxstats 1 --log --boot-stage 0x1d
```

Launch arguments reach `main()` unchanged (verified). On a device, where there
is no command line, put the same flags in `Documents/pd.args`, one or more per
line. The screenshot lands in `Documents/screenshots/`, the log in
`Documents/pd.log`; `grep -E '^gfx:'` that log for the stream to diff.

To compare against the oracle, run the oracle at the **simulator's** resolution
and with the XBLA rows off — see `artifacts/sim/m1/README.md` for the exact ini
and the numbers this produced.

---

## Traps earned (M1)

- **`SDL_main.h` renames your `main`.** Including `<SDL.h>` on iOS drags in
  `#define main SDL_main`, so a shell that defines its own `main()` links with
  `Undefined symbols: _main, referenced from <initial-undefines>` and no other
  clue. `#define SDL_MAIN_HANDLED 1` before the include, then call
  `SDL_UIKitRunApp()` by hand — that is all SDL2main's iOS `main()` does.
- **Xcode 26's Debug configuration links a stub + a "debug dylib"**, and the
  stub's entry point wants a `main()` that lives in the dylib — the *same*
  `Undefined symbols: _main` error from a completely different cause.
  `ENABLE_DEBUG_DYLIB: "NO"` makes Debug link like Release and produces a `.app`
  that `simctl install` is happy with.
- **A no-libcurl build of upstream does not link.** `ghostnetJsonField()` is
  defined inside `#ifdef PD_GHOST_NET` but `community.c` calls it
  unconditionally. Nobody has hit it because every desktop packager has libcurl.
  Patch 0012; worth sending to Dab.
- **`system()` is `API_UNAVAILABLE(ios)`**, which is what actually stops the
  build on `record.c` — not `fork`/`execvp`, which the SDK still declares.
  Compile the recorder out (patch 0011) rather than chasing the calls.
- **Cross-compiling finds Homebrew.** Without
  `-DCMAKE_DISABLE_FIND_PACKAGE_CURL=ON`, `find_package(CURL)` resolves to
  `/opt/homebrew`'s macOS libcurl inside an iOS configure. The same shape of
  hazard applies to any other `find_package` upstream adds.
- **`simctl io screenshot` captures the panel, not the app.** A landscape-only
  app on a portrait-held simulator produces a portrait PNG with the frame lying
  on its side. Rotate 90° CCW (`sips -r 270`, or PIL `rotate(-90, expand=True)`)
  before judging anything by eye. The game's own `--screenshot-frame` PNG is
  already the right way up and is what pixel diffs should use.
- **`PD_ANGLE_DRAWABLE` does not bite on iOS.** ANGLE's Metal window surface
  recomputes the drawable from the `CAMetalLayer`'s bounds × contentsScale, so a
  forced `layer.drawableSize` is overwritten. To diff against the oracle, run
  the **oracle** at the device's resolution instead. It still works on macOS,
  where the spike used it.
- **Aspect ratio is a determinism input.** `chicago-solo` at 1280×720 against
  844×390 diverges from the fifth `gfx:` line — a wider viewport shows more
  geometry. Match the resolution before calling a gfx-stream diff a regression.
- **The oracle run dir has the XBLA package in it.** `build/oracle-clang/xbla/`
  holds the user's `.rar`, and four of the five `Mod.Xbla*` rows are on by
  default, so a "plain" oracle run is not N64 art. Seed the run's `pd.ini` with
  all five set to 0 when comparing against a container that has no package.
- **`--exit-frame` and the resign-active hook both rewrite `pd.ini`.** Give
  every scripted simulator run a fresh container copy of the ini you meant, and
  read it back afterwards before believing an A/B.
- **`simctl get_app_container` changes after a reinstall** (new Data container
  UUID). Re-resolve it every time rather than caching the path in a variable
  across an install.

---

## Traps earned (M2)

- **The port renders at a ninth of the pixels unless you ask twice.** SDL's
  UIKit Metal view takes `contentScaleFactor` 1.0 without
  `SDL_WINDOW_ALLOW_HIGHDPI` — *and* adding that flag does nothing on its own,
  because `gfx_sdl2.cpp:102-105` sets `SDL_HINT_VIDEO_HIGHDPI_DISABLED` whenever
  `Video.AllowHiDpi` is 0 (the default) and `SDL_CreateWindow` then strips the
  flag (`SDL_video.c:1742`). Both halves are patch 0017. It is invisible in a
  screenshot — the panel capture is upscaled and the game's own capture is of
  the small buffer — so the only way to see it is
  `drawable == points × contentsScale`, which `sim-validate.sh` asserts on every
  run (M-010).
- **`PD_IOS_RENDER_SCALE` is the render-scale lever that works**, and it works
  by setting the layer's `contentsScale` rather than its `drawableSize`, which
  ANGLE recomputes every frame from bounds × scale (the M1 trap, now with a
  usable answer).
- **SDL2 disables drop events by default** (`SDL_events.c:646`), and SDL's
  `application:openURL:` turns a link into exactly that event — so a deep link
  silently does nothing until `SDL_EventState(SDL_DROPFILE, SDL_ENABLE)`.
- **SDL 2.32.8 has no scene support at all** (no `scene:` selector anywhere in
  its UIKit backend), and iOS 26/27 makes the app scene-based regardless: URLs
  are delivered to `-scene:openURLContexts:` on the scene delegate and the app
  delegate's `openURL` is never called. `app/ios/PDDeepLink.m` adds the method
  to whatever object is serving as the scene delegate, at runtime, without
  owning either delegate. (The same absence is why SDL windows are NOT born
  sceneless here the way SDL3's are — SDL 2.32.8 needs no graft, and the
  overlay logs `scene=yes` to prove it each run.)
- **`xcrun simctl openurl` cannot drive a deep link on iOS 27**: it raises an
  "Open in *Perfect Dark*?" confirmation, and nothing can tap it (`idb ui tap`
  is dead, injected events bypass UIKit). That dialog is itself the proof the
  scheme is registered; the scripted half goes through the bridge's `link`
  command instead.
- **The simulator reports a virtual "Gamepad"**, so a touch layer that hides
  itself whenever a pad is connected is invisible exactly where it is tested.
  Hence the auto/always/off mode (D-017) and `touch on` in the gate.
- **`videoSetTextureEnhance()` invalidates the texture cache.** Calling it with
  the value the engine already had re-uploads every texture a couple of frames
  into the run — invisible in play, and a diverging `tex uploads` line in a
  seeded replay's gfx stream. Settings pushes must be no-ops when nothing
  changed, and a replay run must not push settings at all (D-015).
- **Upstream's Enhance Textures default is OFF** (`modoptions.c:72`), not 2×.
  D-011 chose 2× for iOS; that is a real difference from the oracle and has to
  be controlled for in any A/B against it.
- **A background/foreground cycle needs the game thread parked at the present,
  not mid-frame.** `PDPacing` blocks it there and keeps the run loop turning
  while it waits — a plain sleep would mean the `willEnterForeground`
  notification, which arrives on that same thread, never fires (the app would
  hang in the background for ever).
- **Xcode 26's actool rejects a classic single-size app-icon catalog** ("a
  single 1024x1024 image is not a valid iOS app icon set"). The icons are legacy
  `CFBundleIconFiles` PNGs at the bundle root instead (`app/ios/icon/`).
- **The engine already seeds pad binds**; the family's "seed still-unbound
  binds on connect" rule is a no-op here. `inputInit()` calls
  `inputSetDefaultKeyBinds()` for every controller slot (`input.c:906-908`) and
  `inputParseBindString()` keeps those defaults for any key whose pd.ini string
  is empty (`input.c:650-655`). Seeding again would overwrite what the player
  chose.
- **Patch 0002 changed `if(NOT GL_LIBRARY)` to `if(NOT DEFINED GL_LIBRARY)`**
  when it added the ANGLE seam, which treats an explicitly empty
  `-DGL_LIBRARY=` differently from upstream on the *desktop* path (empty is
  falsy but defined, so upstream would fall back and this build does not).
  Noted rather than changed: nothing in this port passes that variable, no iOS
  or visionOS build reaches the line, and re-cutting 0002 to gate the ANGLE case
  separately would churn a patch the review has already read. Fix it the next
  time 0002 is touched for another reason.

---

## Traps earned (XBLA on iOS)

- **The engine unpacks the release on the game thread, before your first frame
  hook.** With a package present and `Mod.XblaMeshes` on, the first model load of
  the front end calls `xblaImportGetStfsPath()`, and that blocks for the whole
  248 MB extraction. On iOS the game thread is the main thread, so nothing can
  be drawn or pumped while it runs — and it happens *before* `schedEndFrame()`
  has called the shell's hook even once, so a shell that plans to pre-empt it
  from the frame hook is already too late. The evidence was a gate run whose
  very first `state` said `frames=0` and `xbla_extracted=1`. The unpack has to
  happen before `pdEngineMain()` (D-020).
- **`archiveExtract()` works with no `fsInit()` behind it**, because
  `fsFullPath()` returns an absolute path unchanged (`fs.c:115`). That is what
  makes a pre-engine unpack possible from the shell at all — and it is worth
  knowing before reaching for an overlay patch to expose one.
- **A warm-up launch can finish the whole unpack.** `sim-validate.sh` launches
  twice (the first after a fresh boot races SpringBoard), and the release's
  archive is barely compressed, so six seconds of warm-up was enough to extract
  all 252 MB — leaving the measured run with nothing to measure and
  `xbla_unpack_secs=0.0`. The cache is wiped between the two launches now.
- **`cache/` must be asserted absent from Documents, not just present in
  Caches.** Patch 0009 routes `fsChooseOutputDir("cache")` through the `$C`
  placeholder; a regression there is invisible except as a quarter of a gigabyte
  appearing in the player's backed-up, Files-visible folder. The gate checks
  both halves.
- **`--log` is not on by default, and three of the XBLA assertions are log
  lines.** `xblamesh: 2616 slots`, `xblatex: 5747 texture records` and
  `xblastage: … from the release` only reach `Documents/pd.log` when the run was
  given `--log`. The gate's `--xbla` launch adds it.
- **`nc -w 8` can come home empty during a level load with the release's meshes
  in it**, and `set -euo pipefail` then turns an empty answer into a silent exit
  with no message at all (the `echo "$STATE" | grep …` in the same line fails).
  Poll into a temporary and keep the last answer that was not empty.
- **The whole-release switch is live one way only.** Off changes the picture at
  once; on does nothing until the level is loaded again (M-016, D-019). Do not
  read a toggle-on screenshot that still shows the ROM's art as a bug.
- **A live game is not a comparison instrument.** Two screenshots of Chicago
  seconds apart differ in 99.7 % of their pixels with nothing changed — the
  camera, the rain and the NPCs all move. An A/B of the XBLA switch is judged by
  eye on the artefacts, or under `--fixed-step` against the oracle; a pixel count
  of two live frames means nothing.
- **`simctl io screenshot` rotates the other way than you remember.** The M1
  trap says "rotate 90° CCW"; in PIL that is `rotate(90, expand=True)`, and
  `rotate(-90)` gives you the frame upside down — which is legible enough to
  waste a minute on before you notice.
- **A `UIViewController` presented by `+present` does not exist yet when the
  next bridge command runs.** `[PDSettingsViewController present]` hops to the
  main queue, so a `scrollToSectionContaining:` issued in the same command finds
  no controller. The second call works; the gate and any scripted capture should
  present first and act second.

---

## Traps earned (visionOS)

Phase 5, 2026-09-13. The build sequence is the one at the top of this file with
two extra steps and two different mode names:

```sh
scripts/build-sdl2-visionos.sh xrsimulator   # once; SDL2 2.32.8 for xrOS
scripts/build-sdl2-visionos.sh xros          # once
scripts/build-ios.sh xrsimulator             # -> build/xrsimulator/libpd.a
scripts/build-ios.sh visionos                # -> build/visionos/libpd.a
scripts/gen-app-project.sh
scripts/vision-validate.sh                   # THE GATE (bridge :8785)
```

- **The engine needed no visionOS patch at all.** Both xrOS slices compiled and
  linked from the existing overlay on the first attempt, because patch 0008 had
  already written the visionOS cases: `PD_IOS` is true for
  `CMAKE_SYSTEM_NAME=visionOS`, and `platform.h` defines `PLATFORM_IOS` (and
  `PLATFORM_VISIONOS`) off `TARGET_OS_IPHONE`, which **is 1 on xrOS**. If you
  are looking for the visionOS branch in engine code, that is why there isn't
  one.
- **Exactly two UIKit APIs are missing on xrOS**, out of a 4 600-line shell:
  `UIScreen` (no screens — a window's size is the user's drag, and its
  points-to-pixels scale is `traitCollection.displayScale`, which is 2.0) and
  `UIImpactFeedbackGenerator` (no haptics). Both live in `app/ios/PDVision.h`.
  Everything else — `UIWindowScene`, `UIWindow`, `UITableView`, the gesture
  recognisers, `GCController`, `AVAudioSession`, the document picker — compiles
  and behaves identically.
- **SDL 2.32 does not build for xrOS at all**, and the failure is dozens of
  "unavailable: not available on visionOS" errors in its UIKit backend.
  `overlay/sdl2/visionos-compat.patch` is the minimal fix (D-026). Do not reach
  for SDL3: the iOS slices are 2.32.8 and a version split across platforms makes
  every behaviour question two questions.
- **`SDL_HIDAPI` must be OFF for xrOS.** `__IPHONEOS__` is defined there, so
  `SDL_hidapi.c` takes its iOS branch and declares `HAVE_PLATFORM_BACKEND` — but
  the implementation of that backend is `src/hidapi/ios/hid.m`, which SDL's
  CMake only adds on the IOS/TVOS platform branch. The library builds happily
  and then the APP fails to link with twenty undefined `_PLATFORM_hid_*`
  symbols. Nothing is lost: pads reach visionOS through GameController/MFi,
  which is a different SDL backend and stays on.
- **The ANGLE xrOS slices are minos 26.0**, so the whole visionOS side of the
  port is: `XROS_DEPLOYMENT_TARGET` 26.0, `CMAKE_OSX_DEPLOYMENT_TARGET` 26.0,
  SDL2 26.0. Chromium links `libclang_rt.xros.a` and that is where the floor
  comes from. Check with `vtool -show-build`, never with `lipo`.
- **`lipo -info` cannot tell an iOS library from a visionOS one** — both say
  `arm64`. Every slice this port builds is now asserted on its Mach-O
  `LC_BUILD_VERSION` platform instead (1 macOS, 2 iOS, 7 iOS-sim, 11 xrOS,
  12 xrOS-sim), in `build-ios.sh`, `build-sdl2-visionos.sh`,
  `vision-validate.sh` and the publish script.
- **`awk '…{print $2; exit}'` inside `$( … | awk … )` fails the script under
  `set -o pipefail`.** The early `exit` SIGPIPEs `otool`, the substitution comes
  back non-zero and `set -e` kills the run — reporting a perfectly good library
  as a failed assert. Use a `!seen` flag instead of `exit`.
- **A non-zero command as the LAST line of an `if` block also kills the
  script.** `build-ios.sh` warns when another build is running by re-running
  `pgrep`; if the other build exits between the two calls, the second `pgrep`
  returns 1 and `set -e` aborts — which surfaced as "visionOS engine build
  failed" with nothing in the log but the warning. `|| true` on the warning.
- **The Vision Pro simulator's window is 1280×720 points at contentsScale 2**,
  so the app draws 2560×1440 with no forcing, and `drawable == points × scale`
  holds (M-020). The replay runs at `PD_IOS_RENDER_SCALE=1` (1280×720) against
  an oracle reference of that size —
  `artifacts/oracle/sim-gate/chicago-solo-1280x720.*`. The iPhone's 844×390
  reference is a different aspect and diverges from the fifth `gfx:` line.
- **`simctl io screenshot` on visionOS captures the whole simulated ROOM**
  (3840×2160 of living room with the app's window floating in it), not the app.
  It is the right artifact for "does the window look right in the headset" and
  the wrong one for anything pixel-exact; the game's own bridge `screenshot`
  gives you the 2560×1440 drawable.
- **`engine=running` is not "there is something to screenshot".** It is set
  before `pdEngineMain()`, and the Vision Pro simulator takes several seconds of
  black screen to read the ROM and build the front end. The gate waits for
  `frames >= 120`, not for the flag; waiting for the flag produced a
  "blank or near-monochrome" failure on a perfectly good build.
- **The bridge comes home empty under load on this device far more than on the
  iPhone** (20–30 fps, and the bridge only answers from a frame boundary). Every
  assertion in `vision-validate.sh` goes through a `bridge_retry` that treats an
  empty answer as a retry, and the Chicago-load poll keeps the last non-empty
  state over 80 tries.
- **The touch assertions have to run IN GAME.** At the front end the overlay is
  the menu-pointer layer (overlay 0019) and there is no FIRE button, no floating
  stick and no look zone — a tap lands on `button:BACK` and the gate fails for
  the wrong reason.
- **One bridge per port at a time.** The iPhone simulator and the Vision Pro
  simulator share the Mac's loopback, so two sessions running this app both bind
  :8775 and the second spends fifteen seconds in the retry loop and then runs
  with no console. `PD_BRIDGE_PORT` (8785 for visionOS) is the override;
  `simctl` passes it through as `SIMCTL_CHILD_PD_BRIDGE_PORT`.
- **A concurrent session's `git add -A` will sweep up your in-progress files.**
  Two agents in one worktree means a commit from either can carry the other's
  half-finished work. Nothing is lost, but the commit that "added" a file is not
  the commit whose message describes it — check `git log -- <file>` before
  trusting a blame.

---

## Traps earned (curl)

D-010's execution, 2026-09-13. `docs/curl.md` is the operating manual; these are
the things that cost time.

- **The fix for "cross-compiling finds Homebrew" is a branch, not a disable
  flag.** `-DCMAKE_DISABLE_FIND_PACKAGE_CURL=ON` (the M1 trap's answer) buys
  safety by giving up the feature. Patch 0040 gives the PD_IOS path its own arm
  that never calls `find_package` at all, so the flag is gone and the library is
  the slice's own. Any future `find_package` upstream adds wants the same shape.
- **`-destination 'generic/platform=iOS Simulator'` builds x86_64 as well as
  arm64**, and every static dependency this port has — libpd, SDL2, libcurl — is
  arm64-only. The link fails in the x86_64 slice with "building for iOS
  Simulator, but linking in object file built for …", which reads like a
  platform mismatch and is actually an architecture one. Pass `ARCHS=arm64
  VALID_ARCHS=arm64`, or name a real device in the destination.
- **PD's menus do not take the injected pad for "back".** `pad b down`/`up`
  sets 0x4000 in the engine's mask and the gate asserts that it does, but a
  dialog does not close on it — menu navigation in this port goes through the
  absolute pointer (overlay 0019), so a scripted walk taps the **Back row**.
  Every Dab's Mod page has one; the stock PD dialogs (Ghost Account, agent
  select) do not, and the way out of those is to relaunch.
- **The Community Packs page fetches as soon as it opens.** By the time it has
  drawn "v0.09d is the latest release" and "Download and Install (171 MB)" it
  has already done an https GET to api.github.com and a second one for the cover
  art. The page *is* the TLS proof; no extra probe is needed.
- **An in-run texture-pack toggle is not a comparison instrument.**
  `cfg set Mod.LoadTextures 0` reports 0 and `texpack_enabled` goes to 0, but the
  picture after a stage reload inside the same run still looked like the pack
  (the loader's kept store holds decoded pack images — the log says "kept store
  holds 213 images (94 MB)"). The honest A/B is two **seeded replays** with the
  value written into `pd.ini` before launch: same seed, same frame, one process
  each. That pair differs by 26.3% of pixels and by nothing at all in the `gfx:`
  stream except the texture-cache counters (M-025).
- **An installed texture pack lives in the DATA container and outlives a
  reinstall**, so a pack installed during a manual session is still selected the
  next time the gate runs its oracle comparison. Delete
  `Documents/texture-packs/<name>` before `vision-validate.sh`, or the replay is
  drawing a different game than the reference by design.
- **`ghostnetJsonField` (patch 0012) is compiled out once curl is on**, because
  `PD_HAVE_CURL` sets `PD_GHOST_NET` and the stub lives in the `#else`. The
  patch still applies and still matters — it is the no-transport build's link
  fix, and that build is what `PD_CURL_DIR`-unset still produces.

---

## Traps earned (Phase 2: menus by touch, movement, packs)

- **The console bridge could kill the game: SIGPIPE.** A write to a socket whose
  peer has gone raises SIGPIPE, whose default disposition is to terminate the
  process — and the peer is a `nc -w N` that gives up while a command is still
  running. A `tap` that landed on "create this agent file" outran the client's
  ten seconds, the client closed, the reply was written, and the app died with
  **no `crash.txt`** (SIGPIPE is not one of the faults `PDCrash` installs for),
  nothing in `pd.log`, and only runningboardd's `code:SIGPIPE(13)` to say what
  happened. Every unexplained disappearance of a session is worth checking for
  this first. `SO_NOSIGPIPE` per accepted socket plus `signal(SIGPIPE, SIG_IGN)`.
- **The menu pointer's left button is already a select, twice over.**
  `VK_MOUSE_LEFT` is `CK_ZTRIG`'s default bind (`input.c:198`) and `menu.c`
  treats `Z_TRIG` as select exactly as it treats `A`. So the pointer going down
  IS the click; a shell that also pressed A on the lift selected twice, and
  typing an agent's name gave `Darkxzzll` — two characters per tap, because the
  first select opened the keyboard and the second pressed the key its cursor was
  sitting on. It is also why the pointer must be inactive outside menus: the
  same bit fires the gun.
- **Move the pointer one frame, click the next.** `menuProcessInput()` acts on
  `inputs.select` against the focus it already had, so a pointer that moves and
  clicks in the same frame chooses whatever was highlighted a moment ago.
  Tapping "Game Pak" in the save-location dialog reliably selected "Cancel" and
  the agent file was silently never written — the dialog closes either way. The
  touch layer suppresses the button on any frame the pointer moved.
- **`applySettings` rebuilds the chips and forgets which set is up.** The
  settings page (and the bridge's `touch on`) recreates every button view, which
  put the nine gameplay chips back on top of an open dialog — where a tap meant
  for "Solo Missions" lands on RELOAD. Re-apply the menu/gameplay split at the
  end of any rebuild.
- **Two bridge `pad X down` / `pad X up` lines in one `nc` session can land on
  the same frame**, and the engine then never sees a press: both hop to the
  frame-boundary queue and the queue is drained once per frame. Press through
  the touch layer (`tap` on the MENU chip is Start) or put a sleep between two
  separate connections.
- **PD letterboxes its CUTSCENES, and only those.** Q-005 was written from a
  frame of Chicago's opening camera move. In gameplay the picture fills the
  panel — the game's own capture is 2532×1170 with the first non-black row at 0
  — and there is no aspect setting to change (`video.c:791-811` has none,
  `g_ScreenSize` is already `SCREENSIZE_FULL`, and `optionsSetScreenRatio()`
  forces `SCREENRATIO_NORMAL` off the N64).
- **`--boot-stage` into a solo mission lands in its intro cutscene**, and
  `playerIosGetPos()` reports a constant dummy position (`-4, 100, -4`) until
  the player prop exists. dataDyne Defection needs four Start presses to reach
  gameplay. A movement measurement taken before that measures nothing.
- **PD Plus HD v0.09d already ships `bottomup.txt`.** Upstream's
  `texture-packs.md` says the pack downloaded by hand from the v0.09 release
  loads upside down; Retro Foundry has since put the marker in the zip. The
  shell's guard (D-024) is therefore a no-op for this pack and has to be tested
  by deleting the marker. It still matters for older packs and for folders
  assembled by hand.
- **`pd.ini` keys are written without their section prefix.** A scripted edit
  looking for `Mod.XblaMeshes` finds nothing: the file has `[Mod]` and then
  `XblaMeshes=1`. (And `[Mod]` is emitted more than once — edit keys in place,
  never append.)
- **A `--fixed-step` run does not get the shell's settings**, by design (D-015),
  which is exactly what makes it the right instrument for a texture-pack or
  XBLA A/B: write the values into the container's `pd.ini` before launch and
  the two runs differ only in the thing under test.

## Traps earned (first device boot)

- **The simulator does not enforce privacy usage strings; the device does.**
  0.0.0.2 and 0.0.0.3 passed both gates and died on the phone right after
  onboarding: `Abort trap: 6` with CoreBluetooth frames on a libdispatch
  worker. Upstream's `inputInit()` turns on `SDL_HINT_JOYSTICK_HIDAPI_STEAM`,
  SDL's `hidapi/ios/hid.m` then allocates a `CBCentralManager`, and iOS kills
  any app that touches CoreBluetooth without `NSBluetoothAlwaysUsageDescription`.
  Fix (D-030): `pd_ios_main.m` overrides the HIDAPI hints to "0" at
  `SDL_HINT_OVERRIDE` priority before the engine runs, and both plists carry the
  Bluetooth strings as insurance. A crash.txt whose top frames are a system
  framework on a dispatch queue, with the game nowhere in the trace, is a TCC
  abort until proven otherwise: check Info.plist for the framework's usage
  string first.

---

## Traps earned (shell settings parity)

- **`-[UIImage imageWithTintColor:]` does not tint a `CALayer`.** The tint is
  recorded as a rendering instruction that only `UIImageView` honours, so
  `layer.contents = img.CGImage` gets the untinted TEMPLATE — which draws as a
  grey ghost of the glyph beside a bright white label and reads as "the symbol
  half-loaded". Bake it: `UIGraphicsImageRenderer`, `[UIColor.whiteColor set]`,
  then draw the image `imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate`.
- **`defaults write <container>/Library/Preferences/<bundle>.plist` does not
  reach the app.** cfprefsd serves the process its own cached copy, so a value
  written from outside between two launches is silently ignored — a settings
  change "verified" that way has verified nothing. The bridge writes the same
  key through `NSUserDefaults` inside the process instead (`audio`, `render`,
  `layout`, `touch`).
- **`app/gfx/*.mm` is part of the ENGINE build, not the app build.** It goes
  into `libpd.a` through `scripts/build-ios.sh`, so an `xcodebuild` of
  `app/perfectdark.xcodeproj` alone links yesterday's renderer and the change
  appears to have no effect — which cost a full launch-and-measure cycle on the
  render-scale fraction. Any change under `app/gfx/` needs
  `scripts/apply-overlay.sh && scripts/build-ios.sh <mode>` first.
- **A per-frame settings push has to be bounded.** The audio volumes live in the
  eeprom game file and loading one rewrites all three, so a single boot-time
  apply is undone a second later; but re-asserting for ever would stomp the
  in-game Audio Options page under the player's finger. Ten seconds of
  re-assertion (600 frames) is the seam: NSUserDefaults wins the boot, the game
  owns them after.
- **The front end's side TABS are not reachable by the menu pointer or by an
  injected pad.** `tap` on the tab arrow selects whatever list item the pointer
  focused (it chose "Randomizer", and in the pause menu it chose "Abort!"), and
  `pad cr` / `pad r` only move the focus. That is why the in-game Audio Options
  page has no screenshot in this round's artifacts: the value it renders is
  `VOLUME(g_SfxVolume)`, which the bridge's `state` reports directly. A scripted
  walk into a tabbed page needs whatever input `menuProcessInput` reads for
  `leftright`, which nobody has found yet.
- **The injected pad is overwritten by the touch layer every frame.**
  `inputIosPadSetButton()` sets a bit and `PDTouchOverlay -publish` then calls
  `inputIosPadSet(mask, …)` with its own mask, so a `pad X down` issued while the
  overlay is visible lasts less than one frame. `touch off` first, or press the
  matching on-screen chip with `tap`.

## Traps earned (round A: bean parity)

* **A UIView the overlay owns is unreachable whenever the overlay hides.** The
  settings gear was a subview of `PDTouchOverlay`, which hides itself the moment
  a controller connects — so in the headset, where a pad is usually paired,
  there was no way into Settings at all and nothing said why. Anything that must
  outlive the touch layer's own visibility rule goes in the WINDOW beside it, as
  bean's does (`AttachTouchOverlay`).
* **A UITableView section with no rows has no row 0.**
  `-scrollToRowAtIndexPath:` on one raises `NSRangeException`, which is an
  uncaught ObjC exception, which is the app gone. The placeholder "Audio" header
  killed an artifact run mid-capture. Scroll to `rectForHeaderInSection:`
  instead when a section is empty.
* **A table that was presented microseconds ago has no geometry to scroll.**
  `settings xbla` screenshotted the Aiming section until `scrollTo:` forced a
  layout pass first.
* **`[NSUserDefaults synchronize]` in a slider's value-changed handler is sixty
  blocking round trips to cfprefsd per drag.** The setter is already the truth;
  synchronize was removed and the engine push coalesced to 0.4 s after the last
  change (bean's `PersistSettings` shape).
* **A directory walk in a cell's info block runs once per dequeue.**
  `PDXbla.scan` reads `Documents/xbla` recursively and opens an archive header;
  scrolling the settings page re-scanned a 250 MB drop directory once a row.
  Cache it and invalidate on the two events that can move it (an import, a
  redetect).
* **Never put a system blur over the game's CAMetalLayer.** It is a backdrop
  filter over a surface that is still redrawing at 60 Hz, so the compositor
  re-blurs the whole screen every frame. Opaque background, `opaque = YES`.
* **A safe-area clamp is not free parity.** Clamping bean's table into the safe
  area moved CROUCH and SWAP a chip's width from where he put them, and the
  bridge's hit tests reported `look` at their own coordinates. His table already
  sits inside a notched phone's usable area; clamp the EDITOR's drop instead.
* **`tap` cannot answer "where are the chips".** It reports what it hit, but it
  has already pressed it — one of the answers opened a menu and the next four
  chips all reported `menu`. `hit X Y` (this round) reports without acting.
* **Dab's combat roll is OFF upstream.** `Mod.CombatRoll` registers as
  `MODROLL_OFF` (main.c:308, modoptions.c:30), so the ROLL chip shipped in
  0.0.0.5 drove a move the engine had disabled. Whatever offers the roll has to
  turn it on.
* **The roll's direction is read from the STRAFE, not from the button.**
  `bwalkTryRoll()` takes `toleft` from `speedsideways` and `bondmove.c:1765`
  takes the button on its edge, so a synthetic roll has to be a few frames of
  full strafe with the press inside it. A lone button press rolls right, always.
* **`simctl io screenshot` on the 17e needs a 90° rotation, and then a 180°
  one.** The portrait panel capture rotated the "obvious" way puts the
  bottom-right chips at the top-left; check a landmark (the chip cluster, the
  gear) before believing an artifact.

### Traps earned (round B: audio and the keyboard)

- **The gate has never played the intro.** Every launch in `sim-validate.sh`
  and `vision-validate.sh` passes `--skip-intro`, so STAGE_TITLE is a path with
  no coverage at all. The user found a bug there by playing the game. If a report
  is about something that happens before the main menu, launch WITHOUT the flag
  before believing any instrument (M-029).
- **The main thread is the GAME thread.** SDL's UIKit entry runs `pdEngineMain`
  on it and pumps the main run loop from inside the frame, so anything
  scheduled on `NSRunLoop.mainRunLoop` — an `NSTimer`, a notification observer
  on `NSOperationQueue.mainQueue` — executes *inside a frame*. PDAudio's old
  3 s re-apply was doing an `AVAudioSession` round trip there every three
  seconds. Periodic shell work belongs on its own serial queue (D-033 §3).
- **A cushion of silence queued in `audioInit` is gone before it is used.**
  `SDL_PauseAudioDevice(dev, 0)` starts the device draining immediately and the
  engine's first `audioEndFrame()` is a ROM load later. Leave the device paused
  and start it at the first real push (M-030 runs B and C).
- **A FIXED head start cannot survive a clock mismatch.** The engine produces
  22020 Hz; the device consumes at its own rate and they never agree exactly
  (16 % on the simulator, a rounding error on hardware). Any one-shot cushion
  drains; the top-up has to be re-armed whenever the queue falls below one
  device buffer.
- **The simulator's audio clock is not a device's.** It consumes ~16 % faster
  than the engine produces, so `audio_underruns` runs at ~6/s there no matter
  what the app does. Audio numbers from the simulator are a CORRECTNESS signal
  (does the gain apply, are the category options right, does a change lift the
  queue floor) and never a device measurement.
- **`SDL_HINT_RETURN_KEY_HIDES_IME` is the only way down from the software
  keyboard**, and nothing sets it by default
  (`SDL_uikitviewcontroller.m:587-596`). Setting it is half the fix; the other
  half is that upstream's `inputTextHandler()` has no `VK_RETURN` case at all,
  so `menuitem.c:1583`'s accept branch is unreachable from a keyboard (overlay
  0024).
- **The simulator's QuickPath tip covers the software keyboard the first time
  it appears** ("Speed up your typing by sliding your finger…"). It is a system
  overlay, not the app; a Return goes straight past it to the text field, so it
  obscures a screenshot but does not block a test.
- **`tap X Y` does not reach UIKit.** It drives `PDTouchOverlay` only, so it
  can press a touch chip and a PD menu item but never a settings row, a sheet,
  or an alert. `settings row <section> <n>` (round B) is the UIKit half.
- **The Carrington Institute (stage 0x26) hit-tests as a MENU**, and
  `playerIosGetPos()` returns nothing there. A gameplay gesture check needs a
  real mission — `stage 0x1d` (Chicago) is what round A and round B both used.

### Traps earned (round C: 120 Hz, the cadence and the touch layer)

- **The display link is not the only gate on the frame rate.** The engine has
  its own, `g_Vars.mininc60` / `Game.TickRateDivisor` (`src/game/timing.c:41-54`,
  `main.c:64,297`), and at its default 1 it SPINS until a full 60th of a second
  has passed since the last tick. Ask a ProMotion panel for 120 over it and the
  app presents at exactly half the link rate. Anything that changes the panel
  rate has to change the engine's gate to match (D-034).
- **`UIScreen.maximumFramesPerSecond` is 60 on EVERY simulated device**,
  ProMotion included — verified on an iPhone 17 Pro Max simulator, which reports
  60 and gets a 60 Hz link. There is no way to test 120 on a simulator at all.
  The bridge's `pacing engine <hz>` exists so the mechanism can still be
  exercised at 60/30, which is the same arithmetic.
- **A simulator will not show you a cadence problem.** Its game thread has a Mac
  core behind it and never misses a display-link slot: a 2:1 link/engine
  mismatch came out as a perfectly even 33.33 ms with 0.00% jitter (M-031 case
  B). Frame-time evenness measured on a simulator is a "did we break it" check,
  never a "did we fix it" one.
- **Two simulators cannot both run this app.** A simulator's loopback IS the
  Mac's loopback, so the second app to launch finds :8775 taken and the bridge
  answers for the FIRST one. A `state` that reports the wrong screen size is the
  symptom (844x390 from a 17 Pro Max). Terminate the other lane's app before
  launching, not just the other device.
- **`__weak UITouch` is a bug.** A UITouch is owned by the UIEvent that carried
  it and UIKit recycles both; a weak reference can read back nil between
  `touchesBegan:` and `touchesEnded:`, and then an identity compare against the
  tracked touch never matches and the control is held for ever. Hold them
  strongly and nil them on the way out (D-034 §4).
- **A hidden overlay is not a released overlay.** `inputIosPadSet` is a
  persistent store OR'd over the real pad (overlay 0015), so hiding the layer
  while something is held leaves it held in the engine with nothing on screen to
  explain it. Every early return that stops publishing has to release first.
- **`player_pos` is a bad instrument for "is a control stuck".** A body drifts
  on a slope, a guard shoves it, and Chicago opens on a cutscene during which it
  does not walk at all — two attempts at the round C artifact measured nothing
  but that. `touch_sent_mask` / `touch_sent_stick` in `state` (round C) report
  what the shell last handed the engine, which is the thing that can be stuck.
- **`drag X Y DX DY` is not a touch stream.** It walks its eight steps inside
  ONE main-queue block, so it can never show what a per-event cost does to a
  frame. `stream X Y DX DY N MS` (round C) delivers one event per turn of the
  run loop, which is how a finger arrives.
- **The gates' pixel percentage counted any non-zero difference**, and the
  visionOS simulator drifts by 1/255 on 3-8% of its pixels from one run of the
  same binary to the next (M-034). It now counts pixels differing by more than
  1/255; `MAX_DELTA=16` and the exact gfx-stream diff still carry the structural
  half.
- **A pad paired before launch never sends a connect notification.** Whatever
  needs to know about it has to ASK `GCController` when it comes up, not wait to
  be told — `PDController`'s first push lands on a `PDTouchOverlay.current` that
  is still nil, because the overlay cannot exist until SDL has made a window.
  `PD_FAKE_PAD=1` forces a yes for a test; the iOS simulator also reports a
  virtual "Gamepad" of its own, which is why the gate has to say `touch on`.

### Traps earned (round Q: the pad, the gear and Xcode 27)

- **Xcode 27 makes UIScene lifecycle mandatory, and it is not a warning.** It
  landed on this Mac on 2026-09-14 16:10, after the round-C gate, and the first
  simulator build after it died during scene creation with
  `_UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption` →
  "Application failed to launch: UIScene life cycle is required for apps built
  with this SDK" (TN3187). SIGTRAP, caught by our own handler, written to
  `Documents/crash.txt`, before the app delegate runs. The check is on the
  LINKED SDK, not the deployment target, so a device build is affected too. The
  visionOS plist has carried an empty `UIApplicationSceneManifest` since Phase 5
  and was never affected. **"The gate was green yesterday" stopped being
  evidence the moment the toolchain moved underneath it** — check
  `ls -ld /Applications/Xcode.app` when something that has always worked stops.
- **`+[PDTouchOverlay publishInput]` has three early returns, and anything put
  inside `-publish` inherits all three.** The gear's visibility was one of them
  and froze for the whole of a pad session (D-037). Engine-driven chrome —
  anything whose input is the game's state rather than a finger's — belongs in
  `-refreshEngineChrome`, which runs before the returns. Input belongs in
  `-publish`.
- **A hidden overlay is the NORMAL state on a pad**, not an edge case. Anything
  the shell has to keep doing for a pad player (the roll it plays out, the gear,
  the menu split) has to work from the hidden path, and the hidden path's job of
  releasing what it was holding (D-034) must not eat it — `-releaseHeld:` takes
  a `keepRoll` flag for exactly that.
- **PD's pause is wider than `curdialog`.** `menuIosDialogIsOpen()` (overlay
  0019) is NULL for the transitional frames either side of the pause dialog;
  `pausemode` (`PAUSEMODE_PAUSING` 1 / `PAUSED` 3 / `UNPAUSING` 5,
  `constants.h:3702`) covers them. Overlay 0021 exposes it as
  `playerIosIsPaused()`.
- **R3 on the combat roll is upstream's**, not ours: `input.c:239` plus
  `inputMigrateRollBind()`, which moves Third Person off the right stick to make
  room for it on an existing config. Unbinding one slot needs no patch —
  `inputGetContKeyByName("CK_0800")` + `inputGetKeyByName("JOY1_RSTICK")` +
  `inputKeyGetBinds` + `inputKeyBind(..., b, 0)` are all public in
  `port/include/input.h`. Do it ONCE per launch, or a deliberate rebind from
  PD's own options page cannot survive.
- **A flick gesture needs two thresholds, not one.** Out past 0.70 and back
  inside 0.30 is what makes a HELD stick — a player strafing hard — never
  complete a flick and never roll. One threshold would chatter on a stick
  resting near it.
- **Three `nc` round trips cannot land inside a 300 ms window.** The bridge
  reconnects per command, so a gesture with a time limit gets its own command
  (`pad flick <left|right>`) that runs the whole thing inside one enqueued
  block. `pad lx` stays for probing one sample at a time.
- **`sim-validate.sh` was the last script hardcoding 8775.** A simulator's
  loopback is the Mac's, so a second lane's app finds the port taken and the
  FIRST one answers — the symptom is a `state` reporting the wrong screen size
  (a 17 Pro Max's `points=956x440` from a run on the 17e). It takes
  `PD_BRIDGE_PORT` now, as `vision-validate.sh` has since Phase 5; concurrent
  sessions pass one (`SIMCTL_CHILD_PD_BRIDGE_PORT=8786 xcrun simctl launch …`).

### Traps earned (round P: the device, the audio queue and the scene)

**Xcode 27 / SDK 27 makes UIScene adoption mandatory, and adopting it hides
SDL's window.** The first half is D-037 section 4 and round Q's: a binary linked
against the iOS 27 SDK with no `UIApplicationSceneManifest` is killed at launch
by UIKit itself - `EXC_BREAKPOINT` / SIGTRAP in
`__UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption`, on the
FrontBoard scene-creation path, before any of our code runs - on the **device
and on the simulator**. It is the LINKED SDK that is checked, not the
deployment target.

The second half is D-038 and is the expensive one. SDL 2.32.8 has no scene
support at all and builds its `UIWindow` with `-initWithFrame:`. Under a scene
manifest that window has no `windowScene`, and **a sceneless UIWindow appears in
neither `UIApplication.windows` nor any scene's `windows` array** - nothing in
UIKit can find it, so nothing composites it. What that looks like is not a
crash: the engine runs at a clean 60 fps, the bridge answers, and the screen is
black, with the drawable in PORTRAIT (no scene, no orientation) and
`touch_overlay=none`. Measured on lane 1: 4634 frames, `drawable=1320x2868`
against `expect_drawable=2868x1320`.

The handle that works is the renderer's own view: ANGLE built its EGL surface
from SDL's `SDL_MetalView`, so `pdAngleGetHostView()`'s `-window` is SDL's
UIWindow whether UIKit can enumerate it or not.
`+[PDSceneDelegate graftSDLWindows]` puts it on the scene and makes it key and
visible, from the scene callbacks AND from the per-frame hook - the scene
connects long before SDL's window exists.

`scripts/publish-ota.sh` now fails a payload with no scene manifest and prints
the SDK the binary was actually linked with (`vtool -show-build`, `DTSDKName`,
`DTXcode`). A toolchain that moves under a green gate is what happened here.

**A reinstall over USB terminates the app, and this session may not start it
again.** `devicectl device install app` kills the running process, and starting
it from the command line is refused by the permission layer (the user does that on
his own hardware). So every device build costs one "please tap the icon" round
trip: batch the changes.

**`scripts/device-probe.sh` is the way to talk to the phone.** The socket must
stay open about 1.6 s or nothing comes back; only ONE `iproxy` may hold the
local port; and an empty answer means the app is not running rather than that
the command failed.

**The audio queue's top-up condition could never be false.** Round B topped the
cushion up whenever `queued < bufferSize`, but production is one frame's samples
(368) per push and consumption is a whole device buffer (1024) at a time, so the
queue sawtooths across one buffer by construction and is below `bufferSize` on
every pull whatever the cushion is. It fired about four times a second and
inserted 56 ms of silence each time - the stutter the user reported. D-035, M-035.
The general lesson: a self-healing fix whose trigger is a *level* inside a
sawtooth heals continuously, and its cost is invisible unless it is counted. It
was counted only because `audio_silence` existed.

**`audio_prime_samples` is a snapshot, `cfg get Audio.PrimeSamples` is the
truth.** The row is filled in `audioInit()`; a live `cfg set` changes the value
the code uses but not the row. Read the config key when checking a live change.

**The CoreBrightness firehose in the phone's syslog is not ours.** About 1800
lines/s of `Tristimulus values:` / `[Color Mitigation]` from
`backboardd(CoreBrightness)`, and about 55/s of SpringBoard `Forward Event`
scene actions, are present with our app **not running at all** - captured
2026-09-15 with the app dead: 330,859 syslog lines in 12 s, of which 21,455 were
CoreBrightness, and every `Forward Event` in the sample went to
`com.apple.UIKit.remote-keyboard`. It is iOS 27 on this device, it costs
`backboardd` rather than our game thread, and the user sees no brightness
changing. Nothing in `app/ios/` touches brightness, the scene settings or
`preferredFrameRateRange` per frame (the only `idleTimerDisabled` is one
assignment at startup).

### Traps earned (round R: window routing, and two controllers on one queue)

**Never deallocate a window that is key.** `+[PDSettingsViewController dismiss]`
was `sWindow.hidden = YES; sWindow = nil;` — hide the app's key window, then
free it — and on the user's phone that left the scene with no key window and
nothing promoted, which killed touch delivery app-wide until a force-quit. The
order that works is: make the window you are going BACK to key and visible
first, then hide, and keep the object. (D-041.)

**A simulator will not show it.** Every scripted open/close on lane 3 came back
`route_ok=1` and `game_is_key=1`, in both directions, with the broken code. Two
rounds of "could not reproduce" were two rounds of the simulator recovering from
a mistake the device does not recover from. `pad fake on|off`, the layout editor
and a settings row press are all clean there too.

**A hit test from the OVERLAY and a hit test from the WINDOW are different
questions, and only the second one is about touch.** `hit X Y` walks the touch
layer's own chip table: it returns `button:FIRE` for a layer nothing can reach,
which is exactly what it did while the user could not move. The routed test —
every window, highest level first, `[window hitTest:…]` — is what UIKit does,
and it is `windows`/`route_ok` now. Round Q's three checks (interactivity,
window membership, not-covered) are all *inside* SDL's window and a touch
delivered elsewhere fails none of them.

**When the gear is dead too, the overlay is not the suspect.** The gear is a
UIButton sibling in the same window; the pause chip is inside the overlay. Both
being unresponsive at once is an app-wide delivery failure, and that one fact
would have pointed at the window layer two rounds earlier.

**A game that renders is not a UIKit tree that composites.** The engine draws
through a CAMetalLayer and presents its own drawables, so the picture keeps
moving and the fps stays perfect while everything UIKit draws over it is frozen
at the last composited frame — which is how "the gameplay chips were NOT drawn
(only the pause chip and the gear)" and `touch_menu=0` were both true: he was
looking at the MENU chrome from the moment the page went up, minutes after the
engine had left it. `touch on` "fixed" it only because `applySettings` rebuilds
every chip view, and new layers get composited.

**Two controllers on one quantity is a bug even when each is correct.**
`amgrFrame()` renders 184 samples instead of 368 whenever the audio queue holds
more than 1100, and D-039's rate matcher holds it at 1536 (one and a half of the
1024-sample iOS device buffer). The governor's trip point sat below the
controller's setpoint, so it throttled for ever and the PI loop integrated
straight to its clamp. Overlay 0028, D-042, `Audio.EngineThrottleSamples`.

**`audio_push_samples` is the LAST push, not an average**, so a 184/368
alternation is invisible in it — both sides of the D-042 A/B read 368. The
evidence is `audio_rate_milli` pinning at the clamp and `audio_underruns`
climbing.

**A page that is rebuilt on every open is a page that is always cold.** The
settings window was released on dismiss, so "the first open is slow" was every
open (92 ms in round A). Prewarmed at frame 600 and reused: 59 ms, then 28 and
24 (M-039). When a class method answers "is it up", keeping the object means
that question and "does it exist" have come apart — `+presentedController`
returns nil when hidden so `settings row` cannot press an invisible row, but
`+reloadRows` deliberately does not, because a default changed while the page is
closed has to be on the row when it comes back.

**Routing right and no touch delivered are different failures, and this port has
hit both.** Round R fixed the first (D-041: a deallocated key window) and
the user's phone then failed the second way on the fixed build — `route_ok=1`,
`game_is_key=1`, the watchdog silent, and twenty seconds of a held finger
leaving `touch_tracking=000`. `windows` answers both questions now:
`route_ok` for routing, and `ui_hittests` / `ui_touches_began` / `gear_taps` /
`ignoring_interaction` for delivery. **`ui_hittests` counts UIKit's own calls to
`-hitTest:withEvent:`** — our probes pass a nil event, so a non-nil one is proof
UIKit handed a touch over.

**Only 120 → 60 breaks it; 60 → 120 does not.** That direction is the only one
that turns the ENGINE's tick gate back on (`Game.TickRateDivisor` 0 → 1, the
`sysSleep` spin at the top of `frametimeCalculate`) and SHRINKS the display
link's frame-rate range — and `-[PDSettingsViewController commit]`'s 0.4 s
coalescer landed both of them while the settings page's own UIWindow was key.
**Never re-pace the main thread from inside a UIKit transition**: the panel rate
is deferred while the page is up and re-applied by `+dismiss`
(`PDDefaultsPacingIsDeferred()`).

**`settings row` cannot press a segmented row.** Its action lives on the
`UISegmentedControl`, not on the table row, so `didSelectRowAtIndexPath:` does
nothing at all — which meant there was no scripted path through the Frame rate
row, the exact row this bug lives on, and every "could not reproduce on the
simulator" before this had not in fact driven it. `settings seg <section> <row>
<segment>` does. (It still does not reproduce there.)

**When a bug has never reproduced off one device, number the recoveries.**
`heal 1..6` is six candidate fixes tried one at a time over USB while the user is
IN the broken state, with `ui_hittests` saying whether delivery came back.
Whichever one works names the cause — which is cheaper than another round of
hypotheses, and it costs him one session rather than one build each.

### Traps earned (round R, part 2: the 60 Hz link)

**Never ask for a `CAFrameRateRange` below the panel's maximum on iOS.** A
60 Hz range on a 120 Hz panel stops UIKit delivering touches to this app
entirely — hit-testing, the windows, the key window, the engine and the bridge
all stay perfect and not one `-touchesBegan:` arrives. A/B'd four times on
the user's phone in one session with no relaunch (D-043). Run the link at the
panel's rate for the life of the process and deliver a lower frame rate with the
pacer's divisor instead; `pacing_link_hz` is what the link holds and
`pacing_target` is what the player asked for.

**`CADisplayLink` is not thread-safe, and this app had it wrong.**
`-setTargetHz:` set `preferredFrameRateRange` from the GAME thread on a link
scheduled on the PACING thread's run loop. Configure it on its own thread
(`-performSelector:onThread:`), which after D-043 means once, at creation.

**The bridge answering is NOT evidence the run loop is healthy.** A
`dispatch_async(main)` block arrives through the main-queue source, which
`CFRunLoopRunInMode` services on its own; a HID event needs the loop to enter a
mode and service a port-based SOURCE. Two whole rounds read "the bridge replies,
so the main thread is fine". The CFRunLoopObserver behind `windows`'s
`runloop_*` rows is what tells them apart.

**Count what UIKit actually delivered, not what your model says is reachable.**
`ui_hittests` (incremented in `-hitTest:withEvent:` only when the UIEvent is
non-nil — our probes pass nil) and `ui_touches_began` turn "is the touch layer
healthy" into a fact. `hit X Y` and `route_ok` cannot: both were green
throughout.

**A real finger is never still.** The menu pointer suppressed its click on any
frame the pointer MOVED, comparing with `CGPointEqualToPoint`. A fingertip
jitters a fraction of a point every frame, so the click was suppressed for ever
while the highlight tracked perfectly — and an injected tap holds an identical
point, so every scripted menu test in this port's history took the one branch a
finger can never reach. Half a point of slop. **Any exact float comparison
against touch coordinates is a bug that only real hands can find.**

**A mechanism that explains the evidence is not the cause until the A/B is run
in both directions.** The tick gate parking the main thread in `nanosleep()` is
true, is a good story, and was not it: it got the credit for one unrepeated
restoration, and with the gate already off the bug came straight back. The
explanation that held was alternated four times in one session.

**When the gear is dead too, the overlay is not the suspect.** The gear is a
UIButton sibling in the same window as the chips. Both dead at once is app-wide
delivery, and that one sentence in the user's first report would have skipped a
round.

**Device builds must re-run `scripts/gen-app-project.sh`** or `build_stamp.h`
goes stale and the phone reports a commit it is not running — two device builds
this round both said `ee0b2cf`.

**`isIgnoringInteractionEvents` does not exist on visionOS** (there is no
app-wide ignore gate there at all); guard it with `TARGET_OS_VISION` or the
xrOS build fails.

### Traps earned (round S: instrumenting a process that answers nothing)

**A bridge that will not answer `help` is not a bug in the bridge.** `help` runs
entirely on the socket thread and touches neither the engine nor UIKit, so its
silence means no thread of ours was scheduled — a suspended (or dying) process,
not a wedged one. `state` going quiet while `help` still answers is a different
and much smaller failure. Check `help` first, always.

**Symbolize only after every suspended thread is resumed.** `dladdr()` takes the
dyld lock and the thread just stopped with `thread_suspend()` may be holding it;
symbolizing inside the suspension window deadlocks the dumper against the hang
it was built to report. Collect raw PCs, resume everything, then resolve.

**A watchdog that reads UIKit shares the fate of the thing it is measuring.**
`UIApplication.applicationState`, `connectedScenes` and `keyWindow` are all
main-thread reads; a heartbeat that takes them cannot report on a main thread
that has stopped. The frame hook copies them into a seqlock-guarded struct five
times a second and the watchdog prints the copy — which is also why the heartbeat
survives with `since_frame_s` climbing instead of going silent.

**`NSString` in a heartbeat is a dependency on the allocator.** The pacer's
`-report` builds one; the watchdog gets `pdPacingSnapshot()`, a plain C struct
fill of atomics and scalars, and `snprintf` into a fixed buffer.

**Write a status file through a temp file and `rename(2)`.** `devicectl device
copy from` on a running app will otherwise hand back half a heartbeat, and half a
heartbeat during a wedge is exactly the read that matters.

**Upstream's frame limiter is not in the iOS build at all.** `video_framerate_limit=240`
is `VIDEO_MAX_FPS`, set once inside `videoInit()` and then never consulted:
overlay 0016 replaces `sync_framerate_with_timer()` with the display-link wait on
the iOS branch of `gfx_sdl_swap_buffers_begin()`. So `videoSetFramerateLimit()`
and `wmAPI->set_target_fps()` are inert here, and the number in `state` is a
leftover rather than a control input — do not chase it.

**`configSetValue()` is not the engine's setter.** It writes the registered
variable and stops; anything the setter would also have done (a texture-cache
invalidation, a `set_target_fps`) does not happen. That is deliberate on iOS
(PDDefaults.m calls the setters it wants explicitly), and it is why
`Video.FramerateLimit 0` in `pd.ini` never reaches `videoSetFramerateLimit()`.

**`+[PDSettingsViewController setSegmentInSection:…]` needs a REALIZED cell.**
It goes through `-cellForRowAtIndexPath:`, which answers nil for a row the table
has not laid out, and the failure reads as "no such segmented row (is the page
up?)" on a page that is plainly up. Open with `settings <section>` — which
scrolls — before pressing a segment, not with a bare `settings`.

**`sCurrent` is `__weak`, so ARC will not let a one-line accessor dereference
it.** `return sCurrent ? sCurrent->_uiTouchesBegan : 0;` is a compile error
("dereferencing a __weak pointer is not allowed due to possible null value
caused by race condition"); assign to a strong local first.

**The graft is not theoretical and it is not zero.** `lifecycle.txt` shows
`GRAFT moved a sceneless window 844x390 onto a scene` on **every** launch on iOS
27, a second after `UIWindowDidBecomeKeyNotification` for SDL's window. D-038 is
load-bearing on every boot, which is why `graft off` refuses to bite until the
touch overlay exists.

### Traps earned (round T: the wait that starved UIKit)

**A blocked main thread starves UIKit's event dispatch; touches queue, they do
not drop.** The game thread on this port is the main thread, and UIKit delivers
a HID event to the window from a source on the main run loop. Block that thread
— `dispatch_semaphore_wait`, a `nanosleep`, a mutex — and nothing is dispatched
for as long as the block lasts, but nothing is lost either: the events sit in
the queue and all arrive at once when the loop next turns. Every window-layer
instrument reads healthy throughout, which is why three rounds went past it.
The fix and the proof are D-045 / M-042; the wait now runs the loop.

**`pacing engine 120` (or `pump 8`) flushing a frozen counter is the tell.** If
`ui_touches_began` jumps by several **with no new taps** right after a command
that shortens the main thread's block, the counter was not frozen because
touches stopped arriving — it was frozen because they were never dispatched. Run
that experiment before theorising about windows, routing or key-window state: it
takes one bridge command and it separates "not delivered" from "not generated"
outright.

**`CFRunLoopWakeUp` alone does not return a `CFRunLoopRunInMode`.** A wakeup
with no source to handle sends the loop straight back to sleep until its
timeout, so waking a main thread that is waiting in the loop needs a real
source: create a version-0 `CFRunLoopSource` with a no-op `perform`, add it to
`CFRunLoopGetMain()` in `kCFRunLoopCommonModes`, then `CFRunLoopSourceSignal` +
`CFRunLoopWakeUp`. `CFRunLoopStop` also returns promptly but stops whatever
innermost run loop happens to be turning — including UIKit's own nested ones —
so it is the wrong instrument here. Measured cost of the source: 8-13 µs of
extra wake latency (M-042).

**A device build for a test install does not need the archive/export path.**
`xcodebuild -destination 'generic/platform=iOS' -configuration Release
-derivedDataPath build/dd-device -allowProvisioningUpdates DEVELOPMENT_TEAM=…
build` produces a signed `Release-iphoneos/perfectdark.app` that
`xcrun devicectl device install app` accepts. `scripts/publish-ota.sh` remains
the only path that archives, exports and stages — a build that is going to the
hub goes through it.

### Traps earned (round U: the AIM chip)

- **A held chip does not move the view, by design.** `touchesMoved:` skips
  every touch in `_buttonTouches` — sliding a held finger off FIRE must not
  release it — so a chip that also wants to be a drag surface has to opt in by
  identity, the way `_lookTouch` and `_stickTouch` do (D-046). The symptom
  of forgetting is not a crash or a log line: the button simply works and the
  aiming does nothing.
- **The engine lib is not rebuilt by the Xcode project.** An overlay patch that
  adds an engine symbol (round U added `playerIosGetAimMode()` to patch 0021)
  needs `scripts/build-ios.sh device` before `xcodebuild -destination
  'generic/platform=iOS'`, or the link fails with an undefined symbol against
  the stale `build/ios-device/libpd.a`. `scripts/sim-validate.sh` rebuilds the
  simulator slice itself, which is why the sim goes green while the device
  build is still broken.
- **A hunk header's line counts must be recomputed when a patch is extended by
  hand.** `scripts/apply-overlay.sh` runs `patch --fuzz=0`; the counts in
  `@@ -a,b +c,d @@` are `d` = context+added lines, and a stale `d` is a patch
  that may apply today and fail on the next upstream bump.
- **A `state` read in the same connection as the command that changed something
  is a read of the PREVIOUS frame.** The touch layer publishes its mask on the
  game thread once a frame, so `drag …\nstate\n` down one socket reports the
  old `player_aimmode`. Poll from a second connection while a `stream` runs —
  that is the honest timeline, and the reason round U's artifact has one.
- **The game's own `screenshot` is not proof of a HUD state.** PD's aim reticle
  is a small centre mark; in a dark frame it is invisible at any zoom. Either
  read the engine's own flag (that is what `player_aimmode=` is for) or take
  the panel with `simctl io screenshot` — the panel is portrait, so
  `sips --rotate 270` before judging it.

## Traps earned (Phase 6 M1: the SwiftUI entry)

Round V, 2026-09-17. M1 of `docs/visionos-3d-plan.md`: the visionOS target's
process entry became a SwiftUI `@main` (D-047) so that an `ImmersiveSpace` can
be declared at all, and the compositor loop draws a solid-colour panel. The
2D gate stayed green on the first run, which was not the expectation, so the
list below is short — but every item on it would have been a silent failure.

- **The SwiftUI-vs-SDL "main dance" on xrOS 27 turned out to be a non-event
  for THIS port, and the reason is worth writing down.** The family trap
  (q2repro `NOTES-FROM-VKQUAKE.md`) is that UIKit resolves the window scene's
  delegate to *SDL's* scene delegate instead of SwiftUI's, and SDL then jumps
  through a NULL main pointer. SDL 2.32.8 has no scene delegate at all:
  `src/video/uikit/SDL_uikitappdelegate.h` declares exactly one class,
  `SDLUIKitDelegate : NSObject<UIApplicationDelegate>`, and
  `+sharedAppDelegate` is defined and never referenced anywhere else in the
  tree (`grep -rn sharedAppDelegate work/sdl2-visionos/src/src` = two hits, both
  its own declaration and definition). With SwiftUI owning `UIApplicationMain`
  nothing installs SDL's app delegate, so there is no NULL main to jump
  through. The half of the trap that DOES apply is the persisted session, and
  that is handled by compiling `PDSceneDelegate` out (below).
- **`PDSceneDelegate` must be ABSENT on xrOS, not merely unused.** UIKit
  persists a scene session's configuration name *and delegate class name*
  across installs over the same bundle id, so the user's headset — which has run
  the Phase-5 builds — will try to restore a session naming that class. With
  the class gone the lookup fails and UIKit falls back to the app delegate's
  configuration, which is SwiftUI's. Hence `#if !TARGET_OS_VISION` around the
  whole of `PDSceneDelegate.m` and no `UISceneConfigurations` in
  `Info-visionos.plist`. A fresh simulator never reproduces the problem this
  solves, so the sim being green is not evidence either way — the device is.
- **The engine boot has to go through a run-loop TIMER, never
  `dispatch_async(main)`.** `pdEngineMain()` never returns, so a boot started
  from inside a main-queue block holds the serial main queue for the life of
  the process and every SwiftUI effect (`openImmersiveSpace`, `@Published`, the
  ornament) silently does nothing. sm64coopdx measured exactly that (its M-38):
  0 main-queue ticks in 240 frames. `performSelector:afterDelay:0.0` schedules
  a CFRunLoopTimer instead — same one hop, same thread, opposite consequence.
  This port is in a better position than sm64's on the other side of that
  coin: D-045's pacer waits by RUNNING the main run loop, so the main queue
  drains for the whole slack of every frame and `dispatch_async(main)` from the
  bridge's socket thread works. Do not "optimise" the pacer's wait back into a
  plain semaphore on visionOS.
- **Under the SwiftUI entry there are TWO normal-level windows on the scene**,
  SwiftUI's WindowGroup window (which hosts `PDHostViewController` and the
  ornament) and SDL's, grafted on top. `pdInstallOverlayOnce()`'s scene walk
  picks the FIRST normal-level window it finds, which is SwiftUI's — so the
  touch overlay would be installed in the wrong window and every gate touch
  assertion would miss. On visionOS it now asks for SDL's window by name
  first: `((UIView *)pdAngleGetHostView()).window`, the same handle the graft
  uses. Found by reading, not by failing, but it would have failed.
- **There is nothing left to call the graft on visionOS**, because the scene
  callbacks were one of its two callers and that class is gone. It runs from
  the frame hook instead (`pdVision3dFramePoll`, every 30 frames until it
  moves a window). The graft body itself moved from `PDSceneDelegate.m` to
  `PDShell.m` as `pdGraftSDLWindows()`, with `pdGraftEnabled` (the bridge's
  `graft off|on`) beside it; the iOS class method forwards to it, so the iOS
  behaviour is unchanged and byte-for-byte the same sequence.
- **`.defaultSize(width: 1280, height: 720)` on the WindowGroup is a
  determinism input, not cosmetics.** The visionOS gate's seeded replay runs at
  `PD_IOS_RENDER_SCALE=1` and diffs against a 1280x720 oracle frame, and the
  Vision Pro window has always been 1280x720 points at contentsScale 2
  (M-020). A SwiftUI WindowGroup picks its own default size, so pinning it is
  what keeps `drawable == points x scale` and the oracle diff meaningful.
- **`generic/platform=iOS Simulator` builds x86_64** and `PDWatchdog.m`'s
  arm64 frame-pointer unwinder `#error`s out of it — the same trap M2 recorded,
  hit again while compile-checking the iOS target after a shared-file change.
  `ARCHS=arm64 ONLY_ACTIVE_ARCH=NO` alongside the generic destination is the
  compile-check that does not need a device.
- **`PD_VP3D_AUTOENTER=1` is the only way a scripted run can enter 3D.** The
  ornament's "3D" button needs a gaze-pinch and `simctl` cannot inject one
  (`idb ui tap` is dead on iOS 27 and never existed for gaze). The env flag
  enters at frame 300; absent, it does nothing at all, so it cannot change a
  shipped build. The bridge's `3d on|off|state` is the other half.
- **The simulator's immersive compositor runs at 60 Hz** (`imm_hz=60.0`), not
  the headset's 90. It is mono (`views==1`) and reports
  `supportsFoveation=false`, so the `.dedicated`-layout branch and the
  per-eye tints are device-only reads. What the sim CAN prove is the list in
  D-053, and M1's quarter of it is proven.

## Traps earned (Phase 6 M2: the eye render target)

- **A Private-storage eye texture ABORTS the screenshot, and the backtrace
  blames nothing you wrote.** MTLStorageModePrivate is the obvious choice for
  a render target. PD then reads the finished frame back with `glReadPixels`
  (F12, `--screenshot-frame` — the port's whole regression vehicle), and for
  an EGLImage-backed colour attachment ANGLE-Metal serves that read with
  `-[MTLSimTexture getBytes:…]`, which is illegal on a Private texture: the
  simulator driver takes it to XPC and calls `abort()`. The crash is an
  `Abort trap: 6` whose frames are all `MTLSimDriver` and `libGLESv2`, with
  `gfx_opengl_read_screen_pixels` the first line that is ours. The eye
  textures are therefore **MTLStorageModeShared** (`PD_VP3D_EYE_PRIVATE=1`
  flips it back for an A/B). The cost is lossless compression on a 3840x2160
  target, which M5 may want back — the cure is q2repro's shape: keep the eye
  Private and blit into a Shared staging texture only when a screenshot is
  actually taken (`xr3_stage_texture`).
- **The published MTLSharedEvent must come back RETAINED.** Handing the
  compositor thread an unretained event segfaults inside
  `-[MTLCommandBuffer encodeWaitForEvent:value:]`: the engine publishes a new
  pair every frame and each publish drops the previous event's last reference,
  so a consumer that acquired a frame earlier encodes against freed memory.
  It took ~1200 frames to hit. `pdVisionEyeAcquire` now retains inside the
  lock and the caller `__bridge_transfer`s it. The eye TEXTURE is different
  and is deliberately not retained — the ring owns all three for the session
  and is only freed after the loop has been stopped and waited for.
- **The mode switch belongs at the frame boundary, not on the main queue.**
  It now does GL work (surfaceless `eglMakeCurrent`, the ring's allocation),
  and this port drains the main dispatch queue from inside the pacer's wait
  (D-045) — which sits between the frame's last draw and the present. A
  switch there takes the surface away after the eye is drawn and before it is
  published. So `pdVision3dSetMode` only sets a pending flag and
  `pdVision3dFramePoll` (called from `schedEndFrame`, on the game thread,
  frame finished) performs it.
- **`framebuffers[0].fbo` was not the only literal 0 to fix.** Two latent
  upstream bugs only bite once slot 0 has a non-zero name, and patch 0031
  fixes both: `resolve_msaa_color_buffer` restored the binding with the
  framebuffer INDEX where the NAME was wanted, and `copy_framebuffer` plus the
  grade pass asked for `GL_BACK` as slot 0's read buffer, which ES 3.0 rejects
  for anything but the default framebuffer (the same trap patch 0007 hit).
  Both reach iOS, which is why the iOS gate was run for this milestone.
- **The eye is the MORE faithful surface.** Against the committed 1280x720
  clang oracle the eye read 10/921600 pixels and max delta 7/255 — the same
  numbers on three separate runs — while the 2D window's own readback drifted
  between 0.78 % and 1.09 % of pixels at max 13/255. So the ~1 %/13 gap
  between eye and window is `glReadPixels` off ANGLE's CAMetalLayer back
  buffer, not the eye path. Consequence for gates: compare an eye frame to the
  ORACLE, not to a window frame, and never assert eye==window at the ungraded
  thresholds once the grade pass is on (it multiplies contrast, so 13/255
  becomes 20/255 and 6 % is breached by nothing at all).
- **The grade pass needs its own A/B because its default is OFF.**
  `Mod.VividColours` and `Mod.BlackLevel` both default to 0 and
  `gfx_opengl_grade_frame` returns early when saturation, contrast and black
  level are all neutral — so an eye frame matching the oracle proves nothing
  about the grade. The honest assertion is that the grade's FOOTPRINT
  (ungraded vs graded) is the same on the eye as on the window: 81.84 % of
  pixels moved, max 62/255, on both.
- **The data container survives a reinstall, and `crash.txt` is a RING.** A
  crash report left by an earlier session reads exactly like a crash in this
  one — the first record in the file was 20 minutes old and sent an M2 run
  chasing a bug it had already fixed. Every scripted run deletes
  `Documents/crash.txt` before launching, as both gates already did.
- **A competing build fails the visionOS cadence assert.** `vision-validate.sh`
  reported `frame_cadence=UNEVEN` (jitter 3.02 %, max 61.67 ms) while another
  session's `cmake --build` had the cores, and passed with the usual even
  cadence once they were free. The visionOS simulator already runs the engine
  at 30 fps against a 60 Hz link with 19-35 dropped presents when GREEN, so it
  has no headroom to lend. Check
  `pgrep -fl 'Developer/usr/bin/xcodebuild|cmake --build|ninja -C'` before
  believing a cadence failure there.
- **stderr and NSLog have no ordering.** `gfx_angle_egl.mm` logs with
  `fprintf(stderr)` and the shell with `NSLog`, so the console shows "eye
  targets torn down" before "window surface re-bound" even though the code
  re-binds first. Do not read the interleaving as the sequence.

## Traps earned (Phase 6 M3: both eyes, the fold, and the clock)

**The panel was upside down for a whole milestone and every gate was green.**
M2's `pd_fs_tex` flipped V on the reasoning that "GL's origin is bottom-left
and Metal's is top-left". It does not apply to an EGLImage-wrapped MTLTexture:
ANGLE-Metal reconciles the two conventions itself, inside the translated vertex
shader, so the texture's row 0 already holds the GL frame's TOP row. The flip
therefore flipped a picture that was already the right way up.

Nothing in the M2 gate could see it. PD's `read_screen_pixels` returns rows
bottom-up and its one caller walks them in that order (patch 0006), so the
eye's frame 1500 matched the committed oracle to 10 of 921600 pixels while the
PANEL in the room screenshot was inverted - "GAME FILES" mirrored, the gun at
the top. Two consequences, both permanent:

- the fix is one character: no `1.0 -` in the panel shader's `uv.y`;
- **orientation is checked by READING A HUMAN-READABLE FEATURE in the room
  screenshot, never by "it looks sharp".** M3's acceptance says the words
  "GAME FILES" and "Perfect Dark" must read as words and the gun must be at
  the bottom, and `vision3d-m3-verify.sh` ends by telling the operator to open
  the JPEG and do exactly that. A pixel gate against an oracle cannot catch a
  transform that both sides of the comparison share.

**`id<MTLSharedEventListener>` is not a thing.** `MTLSharedEventListener` is a
plain `NSObject` subclass, not a protocol, so the completion listener is
`MTLSharedEventListener *`. The error is `type argument
'MTLSharedEventListener' must be a pointer`, which reads like a generics
problem and is not one.

**`PD_VP3D_AUTOENTER` means a replay carries BOTH halves, and the gate has to
know that.** The flag enters 3D at frame 300, so the first ~301 `gfx:` lines of
a 2000-frame replay are 1x the oracle's and the remaining ~1698 are 2x. The
first version of the M3 gate asserted 2x on every line and failed on the 2D
prefix. Asserting BOTH halves is strictly better: the prefix proves patch 0030
leaves the engine alone until the eyes exist, and the boundary's position
(measured: line 304) proves the autoenter fired where it should.

**At Stereo Depth 0 % the class counters stay at zero,** because the fold
returns before it classifies anything when the offset is zero. That is the
right shape - a zero-offset fold must be the identity, bit for bit, so that an
L/R pair is pixel-identical - but it means `stereo_cls_*` is only meaningful on
a run with a non-zero separation. The gate reads it off the 100 % run.

**The gfx stats are printed once per FRAME, not once per eye.** They come out
of `gfx_start_frame` (`gfx_pc.cpp:3874`), which `videoStartFrame` calls from
`schedStartFrame` - above `gfx_run` entirely. So in 3D the line count does not
change and the counters are the sum over both eyes, which is what makes
"exactly 2x the oracle" the idempotence assertion rather than a line-count
comparison.

**`eye_renders` has to be gated on the ring being live.** `gfx_run_eye` calls
`pdVisionEyeNoteRender()` on every visionOS frame including 2D ones, so without
the `s_active` guard the counter climbs in 2D and the acceptance item
("`0` in 2D and after exit") is unassertable. It is also zeroed on teardown, so
`3d state` after `3d off` reads 0 rather than the last session's total.

**The external clock is switched by the LOOP, not by the mode transition.**
`pdVision3dImmersiveRun` calls `pdPacingSetExternalSource(1)` as its first act
and `(0)` as its last. A Crown or system dismissal leaves through the
`cp_layer_renderer_state_invalidated` branch and never reaches
`pdVision3dApplyMode`, so a transition-side switch would leave the engine
waiting 250 ms per frame for a compositor that had gone. `-resume` also has to
refuse to un-pause the display link while the external source is on, or the
engine gets two clocks - the one thing `docs/pacing.md` forbids.

**A heredoc delimiter inside a heredoc ends the outer one.** Editing this
script with `python3 - <<'PY'` whose body contained a shell function using
`<<'PY'` truncated the outer heredoc at the inner terminator and fed the rest
to zsh. Use a distinct outer delimiter (`PYEOF`) when the text being written
itself contains heredocs.

## Traps earned (Phase 6 M4: the parked window, and the input the layer ate)

**A 600 ms `usleep` on the main thread cannot wait for UIKit.** The exit's
un-park is a `requestGeometryUpdateWithPreferences:` that UIKit services ON THE
MAIN THREAD — which, in this port, is the game thread inside a never-returning
loop. The first version of the exit asked for the geometry back and then slept
600 ms "to let the scene settle", guaranteeing the settle could not happen: the
measured result was `curtain DOWN (window {480, 270})` and
`drawable re-synced to 960x540`. The fix is to PUMP —
`CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true)` in a bounded loop until
the scene's `effectiveGeometry` matches the captured pre-3D size — which is also
how this port's pacer waits (D-045), so it is the established idiom here.

**Asking for a scene back when one was already coming gives you two.** The plan
says "`UISceneDidDisconnect` while 3D -> `requestSceneSessionActivation`"
(losing the only regular scene kills audio). Implemented unconditionally, that
cost a whole verification round: visionOS disconnects and re-connects the window
scene around the immersive dismissal by itself, so the request arrived while a
replacement was in flight and the app ended up with TWO window scenes. Two
scenes means two SwiftUI root views, two `.onChange` observers, and on the next
`3d on` two `openImmersiveSpace` calls — the second of which returns a bare
`.error` that the rollback path then honours by leaving 3D immediately. The
symptom read as "the second entry does not work"; the cause was in the first
exit. Re-activate ONLY when no other window scene remains, and keep the
`spaceBusy` guard in `PDAppModel` so a duplicate view cannot do it again.

**The touch layer eats an injected pad button.** `PDTouchOverlay`'s
`+publishInput` calls `inputIosPadSet()` once a frame with the WHOLE mask, so
while the layer is VISIBLE it overwrites any bit the bridge's `pad <btn> down`
set — on the very next frame. Measured: `pad start down` answered
`mask=0x1000`, the engine's own mask carried it, and `menu_open` stayed `0` for
four seconds and across three press-release cycles. `touch auto` with a pad
connected hides the layer and the dialog then opens on the FIRST press. That is
why `sim-validate.sh:432` says `touch auto` before it touches the pad, and it
applies to any scripted pad work, in 2D or 3D. The same hazard is why
`PD_VP3D_PAUSE_AT` hides the layer five frames before it presses Start.

**PD's pause dialog needs an EDGE, and the front end is already a menu.** Two
separate things that both read as "Start does nothing". A held Start does not
open the dialog (the menu acts on press and release), so the scripted injection
holds it for exactly ONE frame; and in the front end `menu_open` is
permanently 1, so a live session that wants either a pause dialog or the pinch
STICK (a drag in menu mode drives PD's menu mouse instead, D-022) has to be in
a level — `--boot-stage 0x1d` in the M4 script.

**The parked card sits in front of the panel, and that is geometry, not a bug.**
`UIWindowSceneGeometryPreferencesVision` sets a size and nothing else: there is
no position. The 480-pt card therefore lands where the window was, which is
between the player and the world-locked panel, and it occludes about a sixth of
the panel's width in the sim's room capture
(`artifacts/sim/visionos-3d/m4/02-room-3d-parked.jpg`). The curtain is what
keeps it from being a SECOND PICTURE of the game; `3d recenter` is the remedy
for the occlusion (it re-places the panel in front of wherever the player is
looking now). Whether the card should be smaller still is Q-025, for the
headset.

## Traps earned (the 0.0.0.9 publish)

**The iOS gate's look-drag is racy, and the visionOS gate's is not.** The first
`scripts/sim-validate.sh` run of this publish failed on

    drag -> hit=menu norm=0.519,0.249 dragged=120,0 wheel=0 pointer=558,97
    SIM-VALIDATE FAILED: a drag on the look zone produced no look degrees

with `menu_open=0` in the state dump taken seconds earlier, and passed on a
plain re-run (`hit=look look_deg=36.00,0.00`) with **no change to `app/` or
`overlay/` in between**. The cause is D-023 / overlay 0019 — *in a menu the
whole screen is a pointer*, so `PDTouchOverlay`'s look zone routes drags to
`dialogChangeItemFocusWithMouse()` instead of producing view-angle degrees — and
the gate drags in whatever screen PD's boot sequence has reached by then. PD
boots legal -> title -> front-end menu, `_menuOpen` is refreshed once a frame on
the game thread, and the front end is itself a menu. `vision-validate.sh` does
not have this problem because it drives **into Chicago first** and so always
drags in gameplay. The durable fix is to make the iOS gate enter a level before
the look assertion, the way its visionOS sibling does; until then, an iOS gate
that fails on *only* that assertion is a re-run, not a bug hunt.

**The publish gate's staleness guard counts verification harnesses as build
inputs.** `publish-ota.sh` fails if anything under `app/`, `overlay/`,
`scripts/` or the device deps is `-newer` than the green stamp, excluding only
`project.generated.yml` and `build_stamp.h`. An ad-hoc milestone harness such as
`scripts/vision3d-m4-verify.sh` therefore invalidates BOTH stamps the moment it
is edited, even though nothing compiles, links or references it. That is the
guard being conservative rather than wrong, and the cheap-looking fix — widening
its exclusion list — **was refused by the permission classifier as a CI bypass,
correctly**: the way out of a failing publish gate is to re-run the gate, never
to edit the gate. Practical consequence: **edit the mN-verify harnesses BEFORE
the gate runs, not after**, or budget for re-running both gates. If the
exclusion list is ever widened, it must stay narrow enough to keep
`sim-validate.sh` and `vision-validate.sh` themselves checked — changing a gate
changes what its stamp means.

## Traps earned (Phase 6 M6: the settings sheet)

**`CFRunLoopRunInMode(mode, timeout, true)` is not a wait — it is an upper
bound.** The 3D exit closes the settings sheet and waits for it before the
un-park, and the first version of that wait was twenty iterations of a 50 ms
pump, "one second". Measured, it finished in **forty milliseconds**: with
`returnAfterSourceHandled == true` the call returns the moment it has serviced
one source, and with the engine on the main thread there is always a source. The
sheet's own dismissal takes ~450 ms (SwiftUI animates it), so the pump-count
version issued the un-park with the sheet still on screen — the exact ordering
the function exists to prevent, and invisible in every row of `3d state`
(`sheet_open` was already 0, because the REQUEST had gone out). Any wait in this
port that pumps the run loop must be bounded by `CFAbsoluteTimeGetCurrent()`,
never by a count of pumps. The same shape appears in `pdVision3dApplyMode`'s
post-exit scene wait, which was written against the clock from the start.

**A live render-resolution change has to be ordered against the compositor, not
just against the frame.** `pdVisionEyeAcquire()` hands the compositor a ring
texture UNRETAINED on purpose (D-048: the ring owns all six for the session), so
"free the ring and wrap it again" is a use-after-free for any compositor frame
sitting between its acquire and its own ARC retain. The order that is safe:
clear the published slot (under the publish lock — after which no acquire can
return a ring pointer), wait for the compositor's own sample bracket
`eye_sampling` to reach zero, and only then deactivate + activate, on the engine
thread, from the frame hook. The wait is bounded at 200 ms and **frees nothing
if it expires** — a stuck compositor must cost a setting, never the session. The
panel falls back to its solid colour for the frame or two this takes, which is
also how it is visible in a screen recording.

**A room screenshot measures SIZE badly if you measure LIGHT.** "The panel got
smaller when Screen Distance went 2 m -> 5 m" was first asserted as a ratio of
bright pixels in the 3840x2160 room capture, and read **1.49x on one run and
1.10x on the next** — because how much of the room is bright depends on what
Chicago is lit like at that instant as much as on how big the panel is (and, in
the first attempt, on the settings sheet being a second bright glass rectangle
in the same shot). What is content-independent is the panel's BOX: the columns
whose bright-pixel count is at least a quarter of the column maximum. That reads
1.60-1.62x across runs, and the check closes the sheet first.

**The settings sheet's rows cannot be verified from a screenshot alone, so the
table logs them.** The visionOS simulator injects no taps at all, so nothing can
scroll the sheet: a room capture shows only the rows above the fold, and "every
row in §2.10 is present" would be unfalsifiable. `PDVisionSettingsViewController`
logs every row by section, title and bridge name at `viewDidLoad`, and the gate
greps for the fourteen titles; the screenshot then proves they are LEGIBLE,
which is the half a log cannot do. The same reasoning is why `3d settings press
<row>` exists — a UIKit button row has no other scripted path on this platform.

**A milestone harness's `grep` must name the right log.** `pd.log` is the
ENGINE's log (`--log`); every line the shell writes goes through `NSLog` and
lands in the `simctl launch --console-pty` capture instead. An M6 assertion on
"the persisted Stereo Depth reached the fold" looked for the shell's line in
`pd.log` and failed on a run that was otherwise perfect.

**`wc -l` pads, and `tail -n +"   264"` is an illegal offset.** Any line number
taken from `wc -l` into a `tail -n +N` needs `| tr -d ' '`.

## Traps earned (Phase 6 device round 1: what the headset found that the sim could not)

**The bridge on a real Vision Pro is on the DEFAULT port 8775.** 8785 is only
the SIMULATOR's `SIMCTL_CHILD_PD_BRIDGE_PORT` override, and it exists because an
iPhone simulator and the Vision Pro simulator share the Mac's loopback. A device
has its own loopback and binds 8775 like every other build. Over USB:

    iproxy 18785:8775 -u <your device udid>
    printf '3d state\n' | nc -w 8 localhost 18785

**`cp_frame_end_submission` on a frame with NO drawable aborts the process.**
`__BUG_IN_CLIENT__` inside CompositorNonUI, SIGABRT, and a crash.txt whose only
app frame is `pdVision3dImmersiveRun`:

    5  CompositorNonUI  __BUG_IN_CLIENT__ + 188
    6  CompositorNonUI  cp_frame_end_submission + 728
    7  perfectdark      pdVision3dImmersiveRun + 576

`PDImmersive.m`'s own header comment had said "a NULL drawable is `continue`
WITHOUT end_submission (that aborts)" since M1 and the code beneath it did the
opposite, with a comment claiming that was "the proven pairing". M1–M6 never met
it because the compositor only withholds a drawable from an app that is BEHIND,
and every 3D gate before dev1 ran without the XBLA release. The first dev1 run
with the release on died in eleven frames. `imm_no_drawable` in `3d state`
counts it now, so it can never be silent again.

**`--boot-stage` does not run a mission's loadout, so Joanna is UNARMED — and PD
draws no viewmodel when unarmed.** That is why "the gun is invisible in 3D"
could not be reproduced on a simulator at all: there was never a weapon on
screen to be missing, and the gun class counter said 247990 because the
PROJECTION is installed every frame whatever is in her hands. The bridge's
`give <weaponnum>` (2 = Falcon 2, constants.h:4653) is the fix; any gate that
cares about the viewmodel calls it.

**"The branch is taken" and "the picture is right" are different claims.** D-049
proved the gun class was reached with a counter and shipped a fold that put the
weapon 2.7 NDC units off screen. A counter proves a code path; only a picture
proves a picture. Every class the fold treats specially now has a screenshot
beside its counter.

**A 3D gate without the XBLA release is not a 3D gate.** The classifier misfired
only on 4J's art; the NULL drawable appeared only under its load. Both shipped.
`scripts/vision3d-dev1-verify.sh` pushes the release into `Documents/xbla/` and
every future 3D harness must.

**`hang.txt` survives a reinstall, like `crash.txt` and everything else in
`Documents/`.** A dump from an earlier BUILD was copied into dev1's artifacts on
the first green run and read as this round's evidence. Harnesses clear it at
install time alongside `crash.txt`.

**`set -u` and an empty bash array.** `env "${envs[@]}" …` with `envs=()` is an
unbound-variable abort, not an empty expansion. `${envs[@]+"${envs[@]}"}`.

**The divisor was only ever re-derived on the display link's thread.** While the
compositor was the clock `-linkFired:` never ran, so `pacing engine <hz>` set a
number that nothing read and `-signalExternal` released the waiter without
consulting the divisor at all. Both clocks share `-recomputeDivisor` now and
both honour it (D-056).

## Traps earned (Phase 6 dev2: the panel's shape, and the corners nobody owned)

**An aspect-FIT makes a settings row unfalsifiable.** `PDImmersive.m` fitted the
panel quad to the eye texture, and the eye was the compositor's near-square
per-view size (D-057). With `eyeAspect < panelAspect` the fit takes the
`panelHalfW = panelHalfH * eyeAspect` branch — so the Screen **Width** row was
not read at all, and every M6 assertion on it passed anyway because they all
asserted on the STORED value (`set_width`) and on `panel_width_m` (the clamped
live value), never on the quad that was drawn. Both numbers were correct the
whole time; the picture was not. Any row whose whole job is the shape of a
picture is asserted on the picture, measured — `08b-panel-shape-report.txt`.

**The default was never wrong, and that is why nobody found it.** PDDefaults has
registered 2.75 / 1.55 — 5.5 x 3.1 m, 16:9, SETTINGS-SPEC's own number — since
M6, and `3d state` reported it faithfully. "The default is a square" and "the
default is 5.5 x 3.1" were both true, about different things. When a device
report contradicts a stored value, the thing in between is the suspect.

**`cp_view_get_tangents` aborts under mixed immersion, so the FOV comes out of
the projection.** For the Metal perspective matrix `cp_drawable_compute_projection`
returns, `tan(right) = (P[2][0]+1)/P[0][0]` and `tan(left) = (P[2][0]-1)/P[0][0]`,
and `fov_x = atan(tr) - atan(tl)`. The simulator answers 90.0 deg over a
3840x2160 view = 2445 px/rad, which is what turns "5.5 m wide at 3.6 m" into a
pixel count (D-058).

**visionOS rounds windows it MANAGES, and SDL's is not one.** The window is born
sceneless and GRAFTED into the scene (D-038), so it wears no corner mask at all
and paints its corners square — latent since the graft, and visible the moment a
full-bleed opaque subview (dev2's curtain) or a 480-pt card puts the corners
where a person is looking. Wear the primary's radius with
`masksToBounds = YES`; the radius alone rounds the layer's own background and
clips no sublayer. On the simulator the other scene window reports **no radius
of its own**, so the 46 pt fallback is what is worn — the one-shot window
inventory in the log says which branch is live, and the headset may differ.

**A live geometry slider needs two verbs, not one.** `Note` is every drag sample
and re-wraps nothing (the quad stretches — that IS the instant feedback the spec
asks for); `Commit` is the release, and asks for the frame-boundary re-wrap. A
bridge `3d settings set` is atomic and therefore commits on the spot, which is
the only scripted path to the geometry on a simulator that injects no taps.

**Measure a panel's SHAPE from a capture where the whole panel fits.** At 3.6 m
a 5.5 m panel is wider than the room capture's field of view and its box is
clipped by the frame — which measures the frame. dev2 sets Screen Distance to
6 m for the shape comparison and both boxes are then the panel's.

## Traps earned (Phase 6 dev2-stereo: the fold, the rain, and a matrix called what it is not)

**`camGetOrthogonalMtxL()` is NOT an orthographic matrix.** `player.c:5909`
builds it as `mtx4MultMtx4(camGetMtxF1754(), &sp8c, s0)`, and this engine's
`mtx4MultMtx4(a, b, dst)` computes `dst = b * a` in the row-vector convention —
so it is **View * P**, the world's own perspective with the camera baked in.
`guOrthoF` is called NOWHERE in this tree. Before believing a decomp name, grep
for the builder. sm64's `P[3][3] > 0.5` "is it orthographic" test fires on this
matrix whenever `-View[3][2]` happens to be positive, which flattened the entire
world in stereo (D-060).

**`bgRenderScene()` draws the ROOMS through that baked matrix and the PROPS
through the plain one.** Rooms, wall hits and the bg translucent pass load
`camGetOrthogonalMtxL()` with a per-room TRANSLATION as their modelview
(`room.c roomApplyMtx`); props, chrs and doors load `camGetPerspectiveMtxL()`
with a modelview that already carries the view. Anything that treats "the
projection" as one kind of thing is wrong about half the frame.

**The rooms' view space is SCALED and the props' is not.** `mtx00015f04(scale,
&sp8c)` in `playerAllocateMatrices` multiplies the room view's linear part by
`bgGetScaleBg2Gfx()` = `g_Stages[].unk18` x the zoom factor. Invisible in mono
(a uniform view scale is projectively invariant, which is the point — it buys
depth-buffer range), fatal to anything expressed in view UNITS. `unk18` is
**1 everywhere except Villa, Crash Site and Air Base, where it is 0.5**, and a
scope zoom moves it anywhere.

**"PD's lists multiply into the projection" is FALSE.** D-055, patch 0030 and
patch 0032 all say it. `grep G_MTX_PROJECTION` finds only LOADs, and the counter
reads `stereo_p_mul=0` every frame with 4J's meshes drawing. Do not repeat it.

**IT RAINS IN CHICAGO, so a live L/R eye pair cannot be block-matched.** Two
captures seconds apart have every block moving: 4 of 636 textured blocks stood
still. Use two SEEDED replays instead (`--rng-seed 1234 --fixed-step
--screenshot-frame 1500` with `PD_VP3D_SHOWEYE=L|R`) — the same frame twice,
down to the raindrop, 203 of 203 blocks stationary. `scripts/stereo-disparity.py`.

**Three app launches in one simulator session is about the limit.** The fourth
`simctl launch` comes back `Unable to lookup in current state: Shutdown` or
`Mach error -308 (ipc/mig) server died`, and an `install` can die the same way.
Shut the device down and boot it again between batches rather than assuming a
failure means the app.

**`3d on` is not reliably up 30 s later on a cold boot.** Poll `imm_running` and
`eye_active` instead of sleeping, or a slow boot reads as "the immersive space
never came up".

**`pad fake on` + `give 2` does not always produce a viewmodel** — and the
reason is not the arming. **A STAGE OPENS ON A CUTSCENE CAMERA, and no
viewmodel is drawn under it**: `player.c:6136` calls `bgunRender()` only when
`thirdpersondist <= 0`, so during the opening camera `stereo_frame_gun`,
`stereo_cls_gun` and `stereo_gun_verts` are all 0 however armed the player is,
and `give 2` cannot change it. Measured in Chicago under `--fixed-step` with
seed 1234: gun=0 through frame 2619, **gun=6 from frame 2861**. dev1 read 0 at
`imm_frames=1786` and 6 at 2590 — it waited the camera out by accident;
dev2-stereo round 1 read at 286 and recorded the zero as a mystery. **Wait on
`stereo_frame_gun > 0`, never on a sleep**: that row going positive IS the
"first person, behind her eyes" signal. And PD draws bare HANDS for an unarmed
player, which are a gun-classed list too — so a positive counter is not by
itself a weapon on screen; the HUD says UNARMED / PUNCH.

**A scripted weapon needs a FRAME NUMBER, not a bridge command.** A bridge
`give 2` lands at a wall-clock moment, so in two `--fixed-step` replays it
lands on different frames and the eye-L and eye-R captures are not the same
game state. `PD_VP3D_GIVE_AT=<frame>[:<wep>]` (PDHostViewController.m, beside
`PD_VP3D_PAUSE_AT`) is the deterministic form.

**A FIRST-PERSON frame cannot be block-matched whole.** The near wall is under
half a metre away and its disparity is 100+ px, well past
`stereo-disparity.py`'s ±64 px search, so the ±64 populations are saturation
and not measurements. The world field belongs to a WIDE frame (the cutscene
camera at 1500); the gun's own box is all that is read from a first-person one.
Two passes, not one — `scripts/vision3d-stereo-verify.sh --gun`.

**The sign of a block match IS claimable.** The fold saturates — `2*a*e/C` is
about 6.4 px at C = 610 on a 1280 px eye — so any larger magnitude must be
NEARER than the convergence plane, and `pdVisionStereoFold` returning `-e` for
the left eye makes `x_L - x_R = 2*a*e*(1/d - 1/C)`. **Positive dx = nearer than
the panel.** M-045's addendum has the derivation; round 1 hedged on this and
did not need to.

**There is no light in line of sight from Chicago's start position.** A full
sweep of the view reads `stereo_glare_rects=0` and leaves `stereo_glare_total`
frozen — the glares are banked during the opening cutscene, which flies down
the lit street. To FIND a glare frame: slow the engine right down with
`pacing engine 8` and poll `3d state` once a second; the cumulative
`stereo_glare_total` brackets any window the per-frame count misses. In Chicago
the windows are frames 386-430, 736-759 and 1273-1328, and 1295 has three
tagged rects with a wall fixture in clear view.

**To prove a depth-tagged 2D rect really carries depth, SCALE the separation.**
A far light's own shift is about a pixel, which is a weak thing to assert. But a
tagged rect's shift doubles with `PD_VP3D_STEREO_DEPTH=200` while a panel-pinned
one stays at exactly 0 — so the ratio is the measurement and no absolute
precision is needed. Measured 2.00 (`scripts/stereo-glare-check.py`).

## Traps earned (Phase 6 dev3: the near law, the reticle's trace, and a budget that was a width)

- **A "comfort" complaint can be a FUSION failure, and the two want opposite
  fixes.** The user's "disorienting when the gun overlaps the world" reads like a
  preference; the arithmetic says a wall 30 units from Joanna's face carried
  **+402 px of crossed disparity on the shipped eye — twelve degrees**, which is
  not uncomfortable, it is DOUBLE. Compute the disparity at the nearest distance
  the engine actually permits before designing anything: `U*(C/d - 1)` with
  `U = |2*a*e/C|`, and check it against the panel's own px-per-degree
  (`eye_px_w / panel_angular_width_deg`). A number in degrees is the only form
  of this that can be argued about.
- **Paint order is a stereo constraint.** PD clears depth before `bgunRender`
  (player.c:6120), so the viewmodel is painted over everything. Anything painted
  unconditionally over something else must also be stereoscopically nearer than
  it, or the eye is handed a contradiction exactly at the silhouette it is
  looking at. This is what D-060 got half-right (it fixed the gun-vs-HUD order
  and left the gun-vs-world order inverted) and it generalises: **check the
  whole paint order against the whole depth order**, not one pair of it.
- **You cannot have all three of: the HUD nearest, the gun in front of the
  world, and the world in front of the panel.** The gun's own internal spread is
  exactly `U`, so "gun strictly in front of world" plus "HUD at zero disparity
  nearest" forces the world entirely behind the panel, which flattens every PD
  interior (corridors are 150-300 units and the convergence is 762). Pick two,
  deliberately, and write down which one you gave up (D-061 gave up the HUD, and
  Q-029 item 2 is the user auditing that choice).
- **Clamp in 1/d, not in d.** Disparity is linear in `1/d`, so a saturation
  written on `1/d` has a constant-slope knee and one written on `d` does not. The
  soft knee `q' = qm - dq/(1 + (q-q0)/dq)` is C1, monotone, asymptotic (so
  `U*N` is a STRICT bound, which is what lets the gun's plane sit just past it)
  and costs one divide. `expf` would have cost ~2 ms/frame at PD's vertex rate.
- **Give a measurable invariant a measurable margin.** The gun's plane at
  `U*2.25` is perceptually fine (0.13 deg) and unmeasurable: on the gate's
  pinned 1280 px eye it is 1.9 px against a block matcher with one-pixel
  resolution. `U*2.5` makes it 3.9 px. **Choose the constant so the gate can
  see it**, and say so in the code, or the next round re-tunes it by feel.
- **`PD_EYE_BUDGET_DIM` was a width pretending to be a budget.** Capping the
  larger DIMENSION means a wide panel is cropped rather than scaled: 40 x 12 ft
  wanted 5073 px across and got 2560x768 — half the pixels of the default
  panel, so wider was BLURRIER and not slower. A budget on the pixel COUNT
  (`sqrt(budget/area)`, plus a hard per-dimension ceiling for the driver) spends
  the same bill along the panel's own shape and leaves the default identical to
  the pixel. **If a limit is meant to bound cost, write it in the units cost is
  measured in.**
- **ES 3.0 will not read a depth buffer back.** `glReadPixels` with
  `GL_DEPTH_COMPONENT` is desktop-GL only, so "read the depth at the reticle
  pixel" is not available to this port at all. The engine's own collision trace
  is both cheaper and exact — and it is what every sibling did (`CL_VR_AddAimDot`,
  quake3e's aim marker): **trace, do not read back.**
- **`cam0f0b4c3c` returns a VIEW-SPACE direction whose z is exactly `-arg2`.**
  So the hit's fraction along the ray, times `arg2`, is the VIEW DEPTH — not the
  distance. They differ by `cos(theta)` and PD's aim mode drives the crosshair
  well off-centre, where that is an 18 % error. `skyGetWorldPosFromScreenPos`
  (sky.c:54) is the idiom to copy, `mtx4RotateVecInPlace(camGetProjectionMtxF())`
  included.
- **A one-shot tag cannot label a crosshair.** `PD_DLTAG_DEPTH` is consumed by
  ONE rectangle, which is right for a light glare (one per light) and wrong for
  `sight.c`, which draws a dozen. The sticky span `PD_DLSPAN_DEPTH_BEGIN/END`
  was the smaller change than tagging every rectangle, and it keeps the
  one-rectangle lifetime intact for the glares.
- **`stereo_glare_rects` is now "depth-shifted 2D rects", not "glares".** The
  reticle is tagged through the same path, so the per-frame count jumped from
  low single digits to ~8 and the session total climbs far faster. The row is
  still the right evidence that the depth-tag path is alive; it is no longer
  evidence about LIGHTS specifically. A run with the crosshair hidden is.
- **A measurement script's assertion encodes a DECISION, and decisions get
  superseded.** `stereo-disparity.py` asserted D-060's rule ("no gun block may
  be positive") and D-061 reverses it. Update the assertion WITH the decision
  and say so in the docstring — an assertion left behind is a gate that fails
  for being right.
- **Sight the DEFAULTS in feet if the readout is in feet.** 3.048 m and 1.8288 m
  are exactly 10.000 and 6.000 ft, so the rows read `20.0 ft` and `12.0 ft`. The
  old 2.75/1.55 read `18.0`/`10.2`, which looks like a bug in the formatter.
- **A clamp on a persisted value needs a WRITE-BACK.** Lowering Stereo Depth's
  ceiling from 320 to 300 leaves anyone who stored 310 with a value past the end
  of a slider that cannot represent it — invisible, and it survives every later
  apply. Clamp down and write it back on the next apply. (And the engine-side
  setter had its own stale ceiling of **200**, below the shipped row's 320, in
  two places: a range that lives in three files will disagree in at least one.)
- **`TARGET_OS_VISION` is a BUILD, not a MODE.** Engine code compiled into the
  visionOS target runs in 2D as well, and D-064's crosshair trace is exactly the
  kind that must not: `cdExamLos08` touches the collision module's static state,
  so a trace running under a 2D `--fixed-step` replay is a determinism input the
  macOS clang oracle does not have — and the M-001 gate is precisely the
  assertion that no such input exists. The gate said *"the replay never reached
  frame 2000"* and was right. Anything new that touches game state needs a
  RUNTIME gate (`pdVisionStereoIsActive()`) as well as the compile-time one; the
  display-list tags are behind it too, so in 2D the list is byte-identical to
  the one the oracle walks.
- **The shared Apple Vision Pro will be taken out from under a gate run, and it
  looks like a code bug.** The first dev3 gate failed at `cfg set did not take:`
  with an EMPTY reply — no crash.txt, no hang.txt, the heartbeat alive with
  `settings_page=1` — because another session ran `simctl launch … openq4` on
  the same device and backgrounded the app mid-assert. **Before blaming a
  change, run `ps -Ao args | grep 'simctl launch'`**: a bridge that stops
  answering with the process still alive and no crash file is a lane collision
  until proven otherwise. `xcrun simctl list devices booted` does not show it —
  the device stays booted either way.

## Traps earned (crash fix 0.0.0.13: shooting a wall, and how to prove you shot one)

- **`give <weaponnum>` used to hand over an EMPTY gun.** `invGiveSingleWeapon()`
  puts the weapon in the inventory and `bgunEquipWeapon()` equips it, and
  neither gives it a single round — so a scripted burst presses the trigger on
  nothing, silently, and every assertion about liveness passes because the
  process is fine. Two whole runs of `crashfix-verify.sh` fired zero rounds
  before the 3D screenshot's ammo counter, reading **0/0**, gave it away.
  `give` calls `bgunGiveMaxAmmo()` now and reports the quantity, and
  `ammo <weaponnum>` reads it back. `give <wep> noammo` keeps the old behaviour.
- **The engine consumes injected pad buttons ONLY while a fake pad is claimed,
  and the look zone only exists while one is NOT.** Measured both ways: `pad
  fake off` with the trigger held five seconds leaves the ammo untouched; `pad
  fake on`, same hold, thirty rounds gone. But `pad fake on` hides the touch
  overlay, and the overlay is the only aiming instrument the bridge has, so a
  scripted gunfight alternates them once a burst: fake off, drag, fake on, fire.
- **`touch on` breaks that alternation.** A forced-visible overlay stays
  interactive with the fake pad claimed, and the engine keeps taking its input
  from the touch layer — four bursts in a row fired nothing. Use `touch auto`,
  which shows the overlay exactly when the fake pad is off.
- **PD deducts from the RESERVE a clip at a time**, when the clip is refilled —
  so a burst shorter than a magazine fires real rounds that the ammo readout
  cannot see yet, and a per-burst assertion on the drop fails on a burst that
  worked. Five-second bursts (the AR34's thirty rounds), a running total, and a
  baseline re-read after every top-up — the top-up is what silently zeroed the
  count for a whole phase of the first green run.
- **In 3D the touch overlay belongs to the PARKED flat window.** Every injected
  `drag`/`hit` comes back `MISS outside-overlay`, whatever the fake pad is
  doing. Aim in 2D, then switch to 3D for the liveness half.
- **The iOS gate's content-frame check is a coin flip against the intro fade.**
  It screenshots as soon as the bridge answers (`frames=12` in one run), which
  can land in PD's dark opening, and `bright=0..92` fails a threshold of 300.
  Four of five runs died there at 559b7aa on a build whose only change was three
  bounds checks in the game tick. Re-run it; never widen the threshold.

## Traps earned (the upstream pin bump, bfea06186 -> 245eca04c)

168 upstream commits, 227 files, +60 311/−5 401. Eight overlay patches needed
hands; one more was applying to the wrong place and reporting `ok`.

- **`patch` exits 0 when it REVERSE-applies, and `apply-overlay.sh` prints
  "ok".** Patch 0036 carried upstream's own crash guards ahead of the bump
  (D-065). Its prose said the bump would make it FAIL to apply — it did not.
  `patch` recognised the hunks as already present, assumed `-R`, **removed all
  three guards from the tree** and exited 0, so the overlay reported a green
  apply onto a tree that had just lost the fix the user's crash was published
  for. The tell is in the log `apply-overlay.sh` discards on success
  ("Reversed (or previously applied) patch detected!"). A patch that reports
  `ok` is not evidence the tree gained anything — grep the tree for the change
  when a patch is expected to be redundant.
- **A hunk can land ~110 lines away, in the wrong array, and compile.** Patch
  0018 opens `#ifndef PLATFORM_IOS` before *Dump All Assets* on the Texture &
  Model Packs page. Upstream inserted an identically shaped pair of rows
  earlier in `optionsmenu.c` — a `MENUITEMTYPE_SEPARATOR` followed by a
  `MENUITEMTYPE_SELECTABLE` with a `menutext*`/`menuhandler*` pair — and
  `patch` matched THAT, bracketing the XBLA import rows instead and swallowing
  the end of one array and the head of the next. `--fuzz=0` does not stop this:
  fuzz is about *inexact* context, and this context matched exactly, just
  somewhere else. It was caught only because the swallowed identifiers happened
  to break the iOS compile. **After any bump, read `patch --verbose`'s
  "succeeded at N (offset M lines)" lines**: a hunk whose offset disagrees with
  its file's other hunks is the one to go and look at. (Offsets that agree
  across a file — 68 lines through `gfx_opengl.cpp`, 42 through `input.c` —
  are just the file growing above them and are fine.)
- **`sysFatalError` is now `sysFatalSetupError` at the setup sites** (upstream:
  a setup error the player can fix is not offered as a crash report). It is in
  the context of patches 0004 and 0017. Our ANGLE loader's own fatal takes the
  new name too — "no ES 3.0 through ANGLE" is a setup error by upstream's own
  definition.
- **Upstream now has its own Glare Clipping** (`a7796107c`), which wraps both of
  `artifact.c`'s glare rectangles in `gDPSetRectDepthEXT`. That is a depth
  TEST; patch 0033's `PD_DLTAG_DEPTH` is the stereo SHIFT. They are not the same
  thing and both are kept — ours still goes immediately before each
  `func0f0b2740`.
- **`gfx_sp_vertex`'s per-vertex body is now the inlined
  `gfx_sp_load_vertex()`** with a SIMD matrix multiply and the lighting hoisted
  into `gfx_light_vertex()`. Patch 0033's gun-vertex probe and patch 0034's
  near-law shift both live in it; `w` is still the view depth at that point,
  which is all either reads.
- **`gbiex.h` gained three EXT opcodes** (0x47 texgen shift, 0x48 rect depth,
  0x49 depth bias), so the D-055 class-tag block moves down past them. The four
  emission sites in `vi.c` and `menu.c` did not move at all — `vi.c` has not
  been touched upstream since our old pin.
- **A fresh `pd.ini` is not the same game it was.** `main.c` gained
  `Mod.SettingsRevision` and revision 1 turns Level Reflections' follow, the
  Level Metal reflection style and the statue logo ON for any config that has
  not been through it. That is why the N64-art oracle frames moved 1.5–1.7 % of
  pixels while the `gfx:` stream stayed **identical line for line** — shading
  changes that add no draws. Both sides of the gate start from such a config,
  so the comparison is still honest, but a reference PNG taken before the bump
  is not comparable to one taken after.
- **The XBLA references had to be regenerated, and properly so**: 118 → 126
  draws and 6815 → 7836 tris at 1280×720 (upstream's per-pixel XBLA
  reflections, Level Metal, the release's own skies, the glare pass). The N64
  references' `.gfx.gz` were byte-identical and were left alone; only their
  PNGs and both XBLA pairs changed.
- **D-005's three parity flags still hold** 168 commits on: gcc and clang
  produce an identical 8008-line `gfx:` stream and a pixel-identical 1280×720
  frame on the rebuilt oracles. Rebuild BOTH after a bump — the gcc one is the
  only thing that can tell "clang diverged" from "upstream changed".

## Traps earned (the upstream pin bump, 245eca04c -> c18645860, 1.0.1)

1,282 upstream commits. 14 patches failed to apply; all 34 were rebased in one
pass and none needed its intent changed.

- **Rebase with git, not by hand.** Clone `vendor/dabs-mod` with `--shared`
  into a scratch dir, check out the OLD pin, apply each overlay patch as its own
  commit (commit message = patch filename), then `git rebase --onto NEW OLD`.
  The 3-way merge follows upstream's real history instead of matching context,
  so a hunk cannot silently land in an identically shaped array elsewhere. Then
  regenerate each patch body from `git diff c^ c` under its original prose
  header. 20 of 34 merged without a conflict; every hunk now applies at offset 0.
- **Audit the rebase two ways.** (1) Each new patch's +/- lines, sorted, must
  equal the old patch's - any difference is either deliberate or a mistake
  (it caught a hand-resolution of 0035 that had put our span inside GE Plus's
  early return in `sightDraw`). (2) For every changed block compare its six
  nearest non-blank neighbours old vs new; read every block whose neighbours
  moved. Neither found a wrong-place hit this time.
- **`apply-overlay.sh` now passes `--forward`.** BSD patch answers its own
  "Reversed (or previously applied) patch detected! Assume -R? [y]" with yes;
  `--forward` turns that into a reject. `PD_OVERLAY_SHOW_OFFSETS=1` prints any
  hunk that did not land at its own line.
- **Upstream grew a Vulkan renderer** (`gfx_vulkan.cpp`, `PD_VULKAN` ON by
  default, found by `find_path`). Homebrew's vulkan headers are on this Mac and
  only a missing static shaderc keeps it out; `build-ios.sh` and both oracles
  pass `-DPD_VULKAN=OFF`. `gfx_sdl2.cpp` dropped `SDL_WINDOW_OPENGL` from the
  initial flags and adds it after the Vulkan branch: our ANGLE arm adds
  `SDL_WINDOW_METAL` (and the iOS HIGHDPI flag) at that later point.
- **`xbla/` is now `added-content/`, and the engine MOVES the old folder.**
  `fsAddedContentDir()` renames everything in `$E/xbla` into
  `$E/added-content` the first time it looks and removes the empty `xbla/`.
  The shell must scan both (added-content first) or the pre-engine unpack
  (D-020) never fires. The cache is not keyed by the archive's path.
- **The post chain does not run on GL ES.** SMAA/FSR (`gl_es` check) and TAA
  turn themselves off with a log line; 0041 hides their rows.
- **Seam sealing makes single pixels flip between GPUs.** Faces at a T-junction
  are grown exactly half a pixel, which puts their edges on pixel centres;
  ANGLE-Metal and desktop GL break the tie differently, so 24-69 isolated pixels
  per gate frame differ by up to 100/255. The gate now has an outlier budget
  (D-068). Seen first as a red gate with an IDENTICAL gfx stream.
- **The gfx stream gained a line** ("texture cache starts at ..."), and the
  per-frame stats lines changed format: old and new `.gfx.gz` cannot be diffed
  textually, compare the `gfx: N draws, T tris, V verts` tuples instead.
- **Bisecting the oracle is cheap**: an incremental clang build plus a 12-frame
  `--exit-frame` run is under two minutes a step. For an XBLA bisect, put the
  archive in BOTH `xbla/` and `added-content/` of the run dir, or the commits
  before the move find nothing.
- **The bridge's injected pad does not reach front-end menus while the touch
  layer is in menu mode**; `touch off` + `pad fake on` and it does. D-pad down
  (`pad down`) never moves a menu unless Akimbo Triggers is on - upstream's
  rule, not ours; real pads use the stick.
  **Why (verified 2026-10-01): it is the bridge, not the pad.** `pad <btn>` sets
  bits in the touch layer's own mask (`inputIosPadSetButton` -> `iosPadButtons`),
  and a VISIBLE layer calls `inputIosPadSet(mask, 0, 0)` with its whole mask every
  frame, erasing the injected bit (read back as 0 within 300 ms) before the engine
  usually latches it - so it sometimes wins the race, which makes a single run look
  flaky rather than dead. A real controller is read from SDL binds in
  `inputReadController()` and the layer's mask is only OR-ed on top
  (`inputIosMergePad`); auto mode also hides the layer when a pad connects. The
  visionOS gate's "pad reaches the engine" step only sets and reads that bit inside
  one enqueued block - it proves the seam, not engine consumption and not SDL.
- **The 3D `--gun` pass's `GUN_BOX` is a determinism input that upstream can move.**
  At c18645860 the Falcon 2 sits ~15-20 px further right/up and the box's corner
  block is floor (+2 px), so `stereo-disparity.py` reports a D-061 FAIL on a frame
  that obeys D-061. Read the per-block map (every block above the clamp must be on
  the weapon, and nothing else above it) before believing the box;
  `artifacts/sim/visionos-3d/bump-1.0.1/gun/08d`. **Refit 2026-10-01 to
  `816,528,912,624`** (offline re-read of the bump captures: n=4, all +20, D-061 OK).
- **Upstream's glare occlusion queries run once per EYE WALK.** `gfx_run` walks the
  list twice in 3D, `gfx_occlusion_test` reuses one query object per slot, so the
  answer read two frames later is the RIGHT eye's, probed at the mono pixel (the 1-px
  rect is not depth-tagged, so it is not shifted). Both eyes still agree - the game
  decides once per frame - and glares measured identical in L, R and 2D. Only a light
  right at an occluder edge can decide differently from 2D, by half its disparity.
- **The shipped convergence hides a glare's depth.** At C=762 the dev2-stereo glare
  fixture (frame 1295) sits almost on the convergence plane (-0.2 px), so the
  ratio test is noise; pin `vp3d.conv` to 610 (`simctl spawn <sim> defaults write
  com.rebelancap.perfectdark vp3d.conv -float 610`) to repeat it. Isolate a glare by
  subtracting a `Video.GlareBrightness=0` replay of the same frame.
- **Importing a script under `scripts/` from Python writes `scripts/__pycache__`**,
  which is a file under `scripts/` newer than the gate stamps. Use `python3 -B`.
- **`lldb` cannot launch the oracle headlessly** ("cannot get permission to
  debug processes"); to flip a variable, rebuild a scratch oracle with it.
- **Fast-forward `main` without touching the working tree.** `publish-ota.sh`
  rejects a stamp if any file under `app/ overlay/ scripts/` is newer than it;
  `git checkout main && git merge --ff-only` rewrites every changed file. Use
  `git branch -f main <branch>` (or `update-ref`) while on the branch, then
  `git checkout main` - same commit, no file written.

## Traps earned (GE Plus on iOS, 1.0.1.1)

- **A shell window made before the scene connects is never drawn.** The
  onboarding screen and the XBLA "preparing" note are created in `pdSDLMain`
  before UIKit has connected the scene on a cold launch (their own log says
  `scene=no`, the scene's willConnect comes ~5 ms later). Under the UIScene life
  cycle a sceneless window is invisible, and `UIApplication.windows` does not list
  it, so the graft never saw it: the first-launch onboarding was a black screen.
  `PDShell.overlayWindow` is now a graft candidate (D-073). Look for `scene=no`
  plus a `grafted a sceneless window … (root PDOnboardingViewController)` line.
- **GE Plus's startup notices block the main thread by design.** Upstream's
  conversion/unpack loops draw a notice and `SDL_Delay(16)` on the game thread;
  the work is on a worker. Overlay 0042 pumps SDL's events once a notice frame so
  UIKit is serviced. The shell watchdog still writes a "frame hook silent" hang
  dump at 2 s of any such wait - expected, not a hang.
- **`added-content/` holds three kinds of thing now**, and the engine looks
  differently for each: the GoldenEye ROM at the top level only (by size, then
  header), the GoldenEye XBLA release as a folder holding `files/new/char` or a
  `.7z/.zip` with an entry under it, two levels deep (never a `.rar`), and
  Perfect Dark's release four levels deep (overlay 0001) skipping GoldenEye's.
  `PDXbla` mirrors all three; keep them in step at a pin bump.
- **The engine moves a GoldenEye ROM from the base dir into `added-content/`.**
  On iOS the base dir is Documents itself, so a ROM dropped at the top of the
  app's folder is found and moved on the next launch.
- **GE Plus leaves state in `pd.ini`:** `Mod.GexPlusMapsOffered=1` and
  `Mod.MapMods=GoldenEye Arenas`. Removing the GoldenEye files from a simulator
  container does not remove these; reset both (edit in place) before a gate run
  that must look like a fresh install.
- **The container's `tmp/` does not survive `simctl install`** (the data
  container is re-created with a new UUID and Documents migrated). Stage bridge
  test inputs again after every reinstall.
- **`simctl io screenshot` and the game's own capture disagree about what is on
  screen during startup:** the engine's notice is a game frame, so only
  `simctl io` (rotate first) shows it; the bridge's `screenshot` needs a running
  engine.
- **Bridge test path for the GoldenEye rows:** `geplus pick <rom|xbla> <path>`
  runs the real picker's completion (validation, copy, replace, alert) with a
  file in the container; `geplus` prints the cached scan, `geplus scan` refreshes
  it. The Files picker's own UI cannot be driven by injected touches.
- **Never remove the destination before the copy has succeeded (D-075).** A
  same-name replace's destination IS the user's existing file, and a picked file
  can be the very file already in `added-content/`. Every copy into the user's
  folders goes through `+[PDXbla copyFileSafely:to:same:error:]`: same inode →
  nothing touched; else copy to `.pd-adding-<uuid>.partial`, then `rename(2)`.
  Temp files are dot-prefixed so no scan (engine `fsScanDir` or shell) sees
  them, and are swept at launch. Bridge: `xbla pick <path>` drives the Xbox 360
  row's copy; `adopt fail copy|swap` makes the next copy fail (dev builds only).
- **Any loop that draws without the pacer must check `pdIosPresentAllowed()`
  (D-075).** The game loop's presents stop at the pacer while backgrounded; a
  loop calling `videoStartFrame/videoEndFrame` itself (GE Plus's startup
  notices) does not reach the pacer and would keep issuing GL. Overlay 0042 pumps
  events first, then skips the frame while the app is in the background. The
  simulator suspends a backgrounded app about a second later (`ps` state `Ss`),
  which pauses the unpack's worker too; it resumes on return. The bridge does not
  answer `state` while a notice loop runs; use the patch's own
  `gexplus: notice held / drawing again` log lines (frames drawn, presents).

## Traps earned (1.0.1.2: the keyboard that turned the picture portrait, and the stall that played high)

- **Any keyboard notification re-lays-out SDL's view, and under UIScene SDL
  guesses the orientation wrong.** SDL's view controller observes the app-wide
  `UIKeyboardWillShow/WillHide` and recomputes its frame through
  `UIKit_ComputeViewFrame`, which trusts `UIApplication.statusBarOrientation`
  (Unknown under the scene life cycle) unless the window cannot be portrait. A
  RESIZABLE window can, so the view went 390×844 on an 844×390 scene and stayed
  there (D-077). Fixed by `SDL_HINT_ORIENTATIONS` (landscape) in
  `pd_ios_main.m`. Reproduce with the bridge's `geo keyboard` — the simulator's
  hardware keyboard sends only a will-hide, and that alone was enough.
- **The simulator never raises a keyboard on its own**, and the Files picker's
  search field is out of process: a scripted picker round never touched this
  path. `presented` / `picker cancel|pick <path>` drive the REAL picker; `geo`
  shows every size link; lifecycle.txt has a `GEO …` line for every change.
- **`[UIDevice setValue:forKey:@"orientation"]` does nothing to a scene.** It was
  tried as a stand-in for turning the phone; under UIScene, rotation comes from
  FrontBoard and this changes nothing. There is no Simulator.app on this Mac to
  rotate the device either.
- **A stall is followed by a burst.** `schedAudioFrame` runs `amgrFrame`
  `diffframe60` times — uncapped — so the frame after a 2 s hitch renders 2 s of
  audio at once. Anything regulating the queue must treat that as a
  discontinuity, not as clock drift (D-078, M-050).
- **The simulator's audio unit pulls irregularly** (two buffers late, then two at
  once): an honest steady-state queue reaches ~3,460 samples at a 1,536 setpoint.
  A burst threshold at setpoint + 2 buffers fired falsely; + 3 buffers does not.
- **The M-001 replay cannot see audio.** It runs `--no-sound`; audio changes are
  measured with `audio trace` + `stall`, never with the gate.

## Traps earned (1.0.1.3: GoldenEye XBLA in its Xbox 360 package form)

- **`fsScanDir()` skips every name starting with a dot.** A cache wipe written with it
  leaves the marker, a spool and any note behind; and an empty legacy marker that
  survives a wipe makes a half-written cache look finished. `gebeanRemoveTree()` uses
  `opendir`/`readdir` itself.
- **Upstream's zip extractor reads the whole archive into memory** and inflates each
  entry whole (`archiveExtractZip`); a `.zip` holding the 739 MB package would be ~1 GB
  resident. The package form streams zips with zlib instead (`archiveStreamEntry`).
  `archiveExtract7z()` (no filter) is `SzArEx_Extract`, which allocates the whole solid
  block — never point it at a GoldenEye archive.
- **Perfect Dark's importer takes ANY STFS package and any unrecognised .7z/.zip.**
  GoldenEye's package form is both, and sorts first. Overlay 0047 + the shell's
  `looksLikePackage`/`isOtherRelease` skip title 584108A9; keep the two in step at a bump.
- **The cache marker names its source** (`.extracted13` = "<name> <size>"). A test that
  swaps forms by hand must expect a re-unpack; the same package moved from bare to a
  folder keeps its name and size and is (rightly) not re-unpacked.
- **The `geplus` scan is cached from launch**: after the engine's startup unpack the row
  says "unpacked when the app next opens" until settings open or `geplus scan`.
- **Two simulators share the host's loopback:** run the Vision Pro with
  `SIMCTL_CHILD_PD_BRIDGE_PORT=8785` while lane 3 holds 8775, and terminate one app before
  `pgrep`-ing "perfectdark.app/perfectdark" — both sims' processes match.
- **On the Vision Pro simulator GE Plus's startup notices are invisible** (black window,
  though `notice_drawn` and `egl_swaps` count up). Pre-existing; judge visionOS unpack
  progress from the cache, not from screenshots.
- **`footprint -p` prints units** (`52 MB`, `1553 KB`): parse both fields.

## Traps earned (1.0.1.4: the package reader held to its package)

- **A file table read from the user's file sizes nothing on its own say-so** (D-080,
  overlay 0049). 0046 summed the table's block counts in 32 bits; a table can say
  0x8000 × 4 GB. Bound every entry against the package's own length (known from the
  archive reader before the first piece), reject duplicates, sum in 64 bits.
- **`(size + 0xfff) / 0x1000` wraps for a u32 size near 4 GB** — the count came out 0
  and the per-file check was skipped; the sum check caught it only by luck. Widen first.
- **A malformed-package test needs no 740 MB**: `tools/stfs-malformed.py` writes
  60 KB packages in the real archive's folder layout; the streaming path only checks
  the STFS header and the entry name, so a tiny package exercises all of it. The
  bare-package path has a 64 MB floor (`GEBEAN_PKG_MIN_SIZE`) and is not reached.
- **The overlay has no macOS build of its own**: `build/oracle-clang` is pristine
  upstream. `cmake -S build/src -B build/oracle-overlay` with the clang oracle's
  flags (`CMakeCache.txt`) gives one in ~2 min; the cache is `$E/cache` beside the
  binary, `added-content/` beside it is scanned at startup with no GoldenEye ROM.

## Traps earned (GoldenEye XBLA switch, D-081)

- **`Mod.XblaGoldenEye` is read ONCE a run** (overlay 0050, `gebeanSwitchIsOn()`), at
  the first ask after `configInit()` — before the shell's first-frame settings push.
  A changed value only lands if pd.ini holds it at the next start, so the shell saves
  pd.ini the moment it moves. A seeded replay (`--fixed-step`) skips the push: set the
  key in pd.ini for an A/B, as with every other key.
- **The 1.0.0 pin (245eca04c) registered `Mod.XblaGoldenEye` with default 0**, so a
  pd.ini last written by 1.0.0 says `XblaGoldenEye=0`. Pins since 1.0.1 drop the line
  (`configSave` writes registered keys only). Such an ini costs one launch in the N64
  look; the first-frame push writes 1 and saves.
- **`settings <section>` sometimes lands short** (the page is still animating in): send it
  two or three times, 2 s apart, before a screenshot. On this build `simctl io
  screenshot` came back already landscape (2532×1170) — check the size before rotating.
## Traps earned (D-083: menus by finger)

- **Every injected menu test passed through the one path a thumb never takes.** The
  bridge's `drag` makes all eight moves inside one frame, so no frame ever saw the finger
  still and the click-on-down never fired; a real drag starts still and pauses. Use
  `stream X Y DX DY N MS` with `MS` slower than a frame (e.g. `stream 600 330 0 -3 60 25`)
  for anything a finger does over time. `stream` now lifts at its end in a menu (it used
  to leave the pointer down for ever).
- **The wheel keys are a boolean.** `inputKeyPressed(VK_MOUSE_WHEEL_DN)` says "at least
  one"; the latched count reached the engine and was thrown away at `inputs.mousescroll`.
  Anything sized has to read `inputIosPointerWheelTicks()`.
- **A menu LIST is one item.** The pointer's focus walk stops at the list, and a click
  selects the list's current index wherever it lands — check list dialogs (file select,
  Load/Preset Games, Mission Select) separately from row dialogs.
- **Upstream's side-click needs `mousey` inside the dialog's span** — test side taps
  ABOVE and BELOW a short dialog, not level with it, or the old bug passes.
- **A slider needs the button down for two frames** (edit mode on the first, the value on
  the second via `mouseheld`); a one-frame click leaves its value unchanged.
- **`simctl io screenshot` on the 17e came back 2532×1170 (already landscape)** this
  round — check the size before rotating, as the trap says.
- `menu.c` measures dialogs in the native viewport, which is **320×220** here
  (`video.c`), not 240 tall: size anything on screen from `videoGetNativeHeight()`
  (`menuIosRowFraction()`), never from a remembered constant.

## Traps earned (D-084/D-085: the pad report and the two chips)

- **Before chasing a "did not hide with a pad" report, read the phone's
  `pd.touch.mode`.** `xcrun devicectl device copy from … --source
  Library/Preferences/com.rebelancap.perfectdark.plist` (read-only) answered D-084 in
  one pull: 1 = On = always shown. `lifecycle.txt` now carries a `pad connected|absent`
  line with the mode and the overlay state for exactly this.
- **The simulator always has a GCController** (its virtual "Gamepad"):
  `pad absent: 1 GCController(s)` under `pad fake off` is the override working, not a
  bug. `pad fake` resets to `auto` (= connected) on every relaunch.
- **The active menu reads the LEFT stick** (`joyGetStickXOnSample`), which the shell
  otherwise never drives — `inputIosPadSet(mask, x, y)`'s stick arguments were always
  0 until the wheel chip. Any future chip that feeds them must be released with the
  chip, or the next wheel opens already pointing somewhere.
- **The wheel's highlight lags one frame and that is what makes a lift choose**:
  activemenutick.c closes (`amClose()` → `amApply(slotnum)`) BEFORE it reads that
  frame's stick, so dropping bit and stick together keeps the slot. Do not zero the
  stick a frame before the button.
- **The menu's slots are relative to the gun in hand** (the current weapon sits on
  the left slice), so a wheel test picks a direction from a screenshot of the open
  menu, not from a fixed slot table.
- **A hidden chip is still in `_buttons`.** `-buttonAtPoint:` skips hidden ones now
  (the ALT chip on a GoldenEye level); anything new that hides a gameplay chip
  outside the menu split must go through `-applyChipRules` or it re-appears on the
  next `-applyMenuChrome`.
- **New chips need no layout migration**: the saved layout is keyed by label and the
  table is the fallback (D-032), so an old save shows new chips at their defaults.

## Traps earned (D-085 addendum / D-086: the chips fix)

- **A chip press that never spans a publish is invisible to the engine.** The game loop is
  the main thread and the overlay publishes once a frame, so a touch whose began and ended
  land in one UIKit pump used to set and clear its bit unseen. `-liftChip:` latches it now;
  any new lift path must go through it, any new deliberate drop must NOT.
- **A cancelled touch is never a tap** — chips included (D-086 review). `liftChip:latch:NO` for
  touchesCancelled and the watchdog; `tap X Y cancel` is that path's instrument. Any early
  return before `-publish` must release `_latchMask` as well as `_buttonMask`, or a latched
  bit waits for the next publish and fires as a phantom press.
- **`tap X Y 0` is the instrument** (lift in the same delivery as the press); every bridge
  tap with a hold >= 16 ms spans frames and passes either way, which is why 1.0.1.6's
  ALT tests were green. `touch latch off` reproduces the old behaviour on the same build.
- **`pad <button> down` only reaches the engine while the layer is hidden** — the overlay
  rewrites the whole injected mask every publish. Use `touch auto` + `pad fake on` first
  (with `touch on`, as the gate leaves it, the pad bit is overwritten the next frame).
- **The active menu skips an empty slice** (`amGetSlotDetails` text "" → no move): with only
  DY357 + Falcon 2 the LEFT slice is empty and a left drag stays on the centre. Pick the
  drag direction from a screenshot of the open menu.
- **`state` polling is far faster than `stream`'s steps** — sample with a sleep between, or
  a whole drag reads "stick 0.00".
- The bottom row sits on the home-indicator strip and SDL defers all edges for a
  fullscreen window: touches there may reach UIKit late on a device (D-086 hypothesis —
  `Documents/touch-watchdog.txt` LATCH lines are the evidence to pull).

## Traps earned (D-087: the crosshair that was a pistol whip)

- **No sight on a melee function is Perfect Dark, not a bug.** PISTOL WHIP (Falcon 2, DY357)
  and the fists draw no crosshair even with AIM held (`currentPlayerGetSight`,
  `g_ModSightMeleeNone`). The choice is kept per weapon across missions. Before chasing a
  "missing crosshair", read `player_gun` / `player_gunfunc` / `touch_alt_engaged` from `state`.
- **Chicago starts unarmed** (`player_gun=1`, fists → no sight); `give 2` equips a Falcon 2.
- **Combat Sim on the sim can report a pad** (`touch_pad=1`, layer hidden) right after boot;
  `pad fake off` + `touch on` before tapping chips. Simulants also kill an idle player in
  seconds — a red screen with no sight is death, not the bug.
- **The sight can stay off a few seconds after a function swap with a guard in view** (seen
  once, not reproduced) — sample several frames before calling a shot "no sight".

## Traps earned (D-088: hiding chips from the layout editor)

- **Hidden chips use `b.hidden`, the one hide mechanism** (D-085's ALT rule). Anything that
  sets a gameplay chip's `hidden` must OR in `-userHid:` — `-applyMenuChrome`,
  `-applyChipRules`, `-leftFireVisible` do; a new path that forgets brings a hidden chip back.
- **An edge chip's badge, clamped on-screen, lands inside its own ring** (SWAP on the 17e) —
  the body would toggle instead of drag. Check `touch_hide_badge` against the chip centre
  after moving chips near an edge.
- **A selecting tap must not store a position**, or touching a chip to reach its badge pins
  it against future default tables. `-commitDrag` skips an unmoved chip.
- `layout reset` / the red pill clears hidden flags with positions (they share
  `pd.touch.layout`); `defaults` edits by hand must keep `x`/`y` numbers or the chip falls
  back to the table (a `{hidden: 1}`-only entry is valid and means "default spot, hidden").


## Traps earned (D-089/D-090: the free editor and the upside-down pack)

- **"Upside down" in a menu is not automatically a framebuffer.** The Game Pak portrait is a
  ROM texture drawn by a texture rectangle with a negative dtdy; a pack image in the wrong row
  order inverts it like any other texture. Before blaming ANGLE or the pin, pull the phone's
  `pd.ini` and Documents listing (read-only `devicectl device copy from` / `device info files`)
  and look at `texture-packs/*/bottomup.txt` — and read its first line: ours says
  "Written by Perfect Dark for iOS."
- **The row order of a pack is per release, not per family.** PD Plus HD <= v0.09 is in N64
  order (needs the marker); v0.10+ (Ultimate / XBLA / Forever Plus HD) is stored the right way
  up (must NOT have one). Upstream's Community Packs encodes this per catalogue entry; the
  shell's Files-drop installer now matches it by name (`pdNameIsRightWayUpPlusHd`). A new pack
  family with its own convention needs a line there.
- **The oracle front end cannot be screenshotted from the CLI**: the file menus run with no
  level frame advancing, so `--screenshot-frame` never fires there, and `screencapture -l` and
  System Events keystrokes (F12) are TCC-blocked for this shell. Compare pack orientation on a
  level instead (chicago 0x1d, frame 1500: the "BEAN" graffiti is the readable feature).
- **A chip's centre may be off the view (D-089)**: saved units are no longer in [0, 1]. A
  bridge `hit` exactly AT x = width answers `MISS outside-overlay`; probe a point inside.

## Traps earned (the upstream pin bump, c18645860 -> 90c8622e7, 1.0.2.1)

218 upstream commits (release v3.14.0, not the branch head). 11 patches failed `patch`;
the git 3-way rebase (§Traps c18645860) merged 7 of them and four needed hands (D-091).

- **The oracle's GPU vertex path changes the gfx stream wholesale.** Upstream v3.13.0
  draws meshes, rooms and models from GPU copies when `gfx_opengl_mesh_supported()` says
  yes - desktop GL 4.1 does, ES never does. A default oracle run differs from the sim on
  7,998 of 8,009 lines. Every oracle reference and A/B against the sim needs
  `GpuVertices=0` under `[Video]` in the seed ini (or `--cpu-vertices`).
- **zsh does not word-split `set -- $r`.** A seed-ini loop over `"844 390" "1280 720"`
  wrote `DefaultWidth=844 390` and an empty height: the window came up 844x0, the
  screenshot was 844x1 and gcc/clang still agreed (both drew the same nothing). Check the
  PNG's size, not just "IDENTICAL".
- **upstream's xblaimport.c now skips an archive holding a ROM patch** (goldfinger64.zip
  was being unpacked as Perfect Dark's release). 0047's merge keeps both skips; `PDXbla
  isOtherRelease` mirrors it (`pdArchiveHoldsRomPatch`). Keep the three in step.
- **The hack's conversion is "done once per source" by realpath, and an iOS container
  moves on every install.** Without 0053's `$E` naming, every update re-converts (~4 s,
  ~0.5-1 GB). The shell's `pdHackConverted()` builds the same `$E/added-content/<name>`.
- **Goldfinger 64 never draws XBLA art** (upstream: `xblaSwitchStageHeld()`); a hack
  stage with the GoldenEye release present still differs in pixels from one without (the
  PD-side Xbla rows affect lighting), not a bug of ours.
- **Bridge recipe for the hack**: `settings GoldenEye` (twice) -> `settings row GoldenEye 6`
  presents the real picker -> `picker pick <container tmp path>`; `geplus pick hack <path>`
  runs the completion alone. Rows are 0-based: 5 = Goldfinger 64 status, 6 = its button.
  Headless boots: `--boot-ge-variant "Goldfinger 64" --boot-ge-mission 0` (mission),
  `--boot-map Junkyard` (arena; an unknown name prints the list).
- **The touch layer starts hidden on a fresh container** (`hit=MISS overlay=hidden`): send
  `touch on` before menu taps. Menu taps moved since phase 2: the name keyboard's OK is at
  505,243, the Game Pak row at 420,194, the first agent file at 345,225.
- **`pgrep -f perfectdark.app/perfectdark` can match the wrong process** for footprint
  polling; match `Containers/Bundle/Application/.*/perfectdark.app/perfectdark`.
