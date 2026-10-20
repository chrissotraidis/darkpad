# Darkpad progress

## Active milestone: P0 — reproducible foundation

Goal: implement docs/goal.md and docs/prd.md, then Goldenpad-inspired controls/menu polish and optional enhanced art. At most one booted simulator. No public release authorized.

## Sources
- Apple shell: rebelancap/perfect-dark-ios, b88f7cff611d54f7d233ebe3882e2295e5ecca9a; imported app, overlay, scripts, tools and license. Historical docs retained under docs/upstream; their results are not Darkpad test results.
- Engine baseline: 90c8622e74b35be669d60d177effc6d7d2d7621c (UPSTREAM_PIN).
- Goldenpad reference: chrissotraidis/goldenpad, 52bb67328c2cc4b98b4242ba0539985bd61fc2d3, downloaded into ignored work/references/goldenpad.

## Local inventory (2026-10-20)
- Apple Silicon Mac14,2, 24 GiB RAM; macOS 27.0.1; Xcode 26.6 (17F113).
- CMake 3.27.1, Ninja 1.13.2; XcodeGen missing. Initial free disk 396 GiB.
- Supplied ref ROM: 33,554,432 bytes; MD5 e03b088b6ac9e0080440efed07c1e40f (PASS); SHA-256 4e51142acac686d96861cecc58cf7cb7c3b06b21733b7f8ed609a709dc039a21. Original preserved; ref/work/build ignored.
- No simulator booted at start. Existing document moves preserved.

## Status
- Source/build: shell imported; reconstructing self-contained dependencies.
- Package/install: not run.
- Physical gameplay: not run.
- Performance: not run.
- Release readiness: not ready; private development only.

## Next
Resolve pinned ANGLE/depot_tools and build SDL2/curl without sibling dependencies; bootstrap baseline engine and apply overlay. Inspect Goldenpad control schema and overflow menu before adapting the existing shell.

## Foundation evidence
- `scripts/bootstrap.sh`: exact engine pin fetched; `scripts/apply-overlay.sh`: all 48 patches apply cleanly. Vendor remains separate and unmodified.
- `scripts/build-apple-deps.sh {iphonesimulator,iphoneos,macosx}`: SDL2 2.32.8 and curl 8.11.0 built from local pinned source caches for all three targets. `check-apple-platform.py` passes every tagged archive object: SDL2 186/186/185, curl 169 per SDK. TLS uses SecureTransport.
- XcodeGen 2.46.0 installed. ANGLE e25e8d8565f7b077002e07c2cbacfc2eec35aec0 resolved; depot_tools pinned to 3a8af1e64be01a524f7d1c46daf8c2dcac63ff85. DEPS/toolchain sync underway (exec session 23108; work/evidence/angle-fetch.log).
- Native Mac build underway (exec session 45983; work/evidence/build-macos.log). Initial no-curl build exposed upstream unresolved ghostnetJsonField; recipe now explicitly links locally built curl and matching macOS 12 deployment target. No vendor edit.
- ROM validation/staging passes; tests verified v64/n64 normalization, original preservation and truncated-input rejection. Private copy in work/gamedata.
- Goldenpad behavior inspection documented in docs/goldenpad-reference.md; implementation deferred until baseline gameplay passes.
- `xcrun devicectl list devices`: no physical devices connected. All simulators remain shut down.
- Full `scripts/bootstrap-apple.sh` recipe added, not yet validated end-to-end. Build logs in ignored work/evidence. Physical gameplay/performance/release acceptance remain NOT RUN/not ready.
- Mac build now PASS: `build/oracle-clang/pd.arm64`, ARM64/macOS. Disabled curl's opportunistic nghttp2 dependency after the Mac link exposed it; all dependency recipes now explicitly disable HTTP/2/3 extras.
- Mac Chicago smoke PASS: 600 seeded fixed-step frames, exit 0, inspected 1280×720 screenshot at frame 500 (intro cutscene rendered), pd.ini and 2048-byte eeprom.bin written. This is a rendering/lifecycle smoke, not completed-mission evidence. Log: work/evidence/mac-smoke-chicago.log.
- ANGLE sync PASS. Simulator framework build running, session 98166 (work/evidence/angle-simulator.log). Use DEPS-provided buildtools/mac/gn and the pre-resolved host Ninja; depot_tools' wrappers expected an obsolete Python bootstrap marker.
- Eight-bot Mac smoke started (work/evidence/mac-smoke-eight-bots.log). Still zero booted simulators.
- Eight-bot Mac smoke PASS: 2,000 frames, eight simulants, CPU vertex path, exit 0 and screenshot at frame 1,800. Not a completed match/progression acceptance test.
- Foundation checkpoint committed as 3eab186 on codex/perfect-dark-foundation (including preserved document relocation).
- ANGLE first compile reached 250 targets then Dawn generator failed under the user's default Python 3.8 (functools.cache absent). Recipe now selects installed Python 3.11 via a project-local tool shim, with a minimum-version check. Resumed simulator ANGLE build: session 17538; work/evidence/angle-simulator.log.

## Next continuation
1. Check ANGLE session 17538/log, finish simulator frameworks then engine and app; device slice follows sequentially.
2. Mac smoke passes are only partial P0 evidence. Verify save reload, early mission completion and actual bot match; use CPU-vertices for renderer comparisons.
3. Boot at most one discovered simulator, verify missing-ROM UI, import and gameplay, then shut it down before another target.
4. Only after stable baseline apply Goldenpad menu/controls, gyro trial and enhanced-art work. No physical devices currently connected.
