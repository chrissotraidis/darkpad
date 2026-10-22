# Perfect Dark Apple — product and engineering requirements

**Status:** implementation-ready brief; product hypotheses still need testing.  
**Research date:** 20 October 2026, Asia/Tokyo.  
**Owner:** Chris. **Execution entry point:** `goal.md`.

No game was built or run during the research that produced this document. Source inspection, public documentation and revision metadata are the evidence base. Performance thresholds below are proposed acceptance targets, not benchmark results.

## 1. Product intent

Make Perfect Dark enjoyable and dependable as a phone game: quick entry into the campaign or a bot match, controllable aiming without mandatory accessories, readable presentation, reliable saves and sustained performance. Preserve the original game's identity. Offer HD art as an option and use existing native source work rather than beginning a new decompilation.

The initial audience is Chris's existing port community and Perfect Dark fans with iPhones/iPads. A controller should work immediately; a person using only touch should still be able to finish missions. The later ambition is playing together across an iPhone and an Apple Silicon Mac.

Success is a demonstrably useful game people can install and keep playing. Audience requests are qualitative demand evidence. Virality, market size, first-ever status and numerical adoption targets are not established.

## 2. Scope and priorities

| Priority | Included | Completion meaning |
|---|---|---|
| P0 — reproducible foundation | Pinned dependencies, clean builds, original-ROM gameplay, desktop reference, diagnostic baseline | Another Mac can reproduce the build without the author's private workspace |
| P1 — polished solo product | Campaign, challenges/bots, good touch/controller play, gyro trial, visual profiles, reliable saves/lifecycle, phone qualification | Physical-device acceptance and documented campaign coverage |
| P2 — network experiment | Updated pinned engine, two-device LAN Combat Simulator and campaign co-op | Actual complete sessions and progression on both devices |
| P3 — extension | Counter-op, then optional Internet connectivity and larger rooms | Separate tests and scope decisions; not required for P1 |

Out of the initial scope: Vision Pro enhancements, Android/Windows support work, GoldenEye/Goldfinger conversion promotion, a new native Metal renderer, ray tracing, frame generation, custom account/lobby services, huge bot counts, achievements infrastructure, mid-mission save-state emulation and a new decompilation. Preserve inherited code where practical; excluding a feature from acceptance is not permission to delete unrelated working functionality.

## 3. Foundation and confirmed prior art

The source lineage is matching N64 decompilation → native PC port → Dab's Mod → existing Apple shell. This is native game code, although the graphics layer still consumes original-style display commands. It does not need a guest CPU JIT. [S1–S4]

The iOS project already documents touch-layout customization, controller support, ROM import, optional Xbox remaster art, texture packs, frame-rate/resolution settings, diagnostics and save flushing on backgrounding. Do not sell these as inventions. Verify how well they work and retain them when sound. [S4]

The selected architecture is the existing engine as a static library with an additive Apple shell, SDL2 and ANGLE GLES-to-Metal. Vulkan is off in the reviewed iOS build. Keep the isolated patch overlay and source pin; defer architectural replacement until measurements identify a specific limitation. [S5–S7]

Source inspection found no implemented handset gyro-to-aim path in the reviewed shell/upstream input file. CoreMotion is linked, which is not equivalent to an aiming feature. This is a candidate improvement to verify, not an exhaustive claim about every Perfect Dark fork. [S8]

The iOS engine pin is `90c8622e74b35be669d60d177effc6d7d2d7621c` (3 October). Reviewed Dab HEAD is `3ee8ed0cd549b64350848655c43ae1568e449c6d` (14 October), 656 commits ahead. The pinned tree lacks the newer `port/src/net/` and `port/include/net/` directories. Current Dab documents authoritative-host networking, online co-op/counter-op, and protocol 32. These facts support P2 research; they do not establish Apple cross-play. [S9–S11]

## 4. P0: build and data requirements

### 4.1 Dependency bootstrap

Produce one documented command that fetches/builds pinned dependencies, with a resumable cache. Record source URLs, full commits/tags, archive checksums, local patches, SDK/compiler versions and license notices. A network connection may be required for initial acquisition; unrelated sibling checkouts must not be required.

| Component | Reviewed expectation | Work required |
|---|---|---|
| ANGLE | Provenance names revision prefix `e25e8d8565f7`, Metal backend, iOS device/simulator frameworks and EGL/GLES headers | Resolve full revision and transitive dependencies; pin depot_tools; build the required slices and verify framework/XCFramework packaging |
| SDL2 | `release-2.32.8`, static ARM64, iOS 15 deployment target in baseline | Reconstruct a standalone recipe from official SDL source; verify required SDL2/SDL2main artifacts and headers for both SDKs |
| curl | `8.11.0`, static HTTP(S), Apple SecureTransport | Build explicit SDK-specific slices; retain system-trust TLS verification; avoid discovering a macOS Homebrew library while cross-compiling |
| zlib/system frameworks | SDK dependencies | Resolve from the target SDK and verify linkage |
| Engine | Baseline `UPSTREAM_PIN` plus ordered patches | Keep exact snapshot reproducible before updating |

Important findings from the dependency audit:

- `work/deps-PROVENANCE.md` points to sibling `realrtcw-ios`/`dhewm3-ios` paths. Corresponding public `rebelancap` repository endpoints returned 404 during this review; that may mean private, renamed or unavailable, not that the recipes cannot be reconstructed.
- Public `rebelancap/q2repro-ios` at `dfdf758f4aa9a87126d1ed70fa0e0dbe369cab7c` has ANGLE and curl build scripts. Treat them as references, not turnkey dependencies. Its ANGLE script fetches without a fixed engine revision and describes dylib output; Perfect Dark expects frameworks/XCFrameworks. Inspect actual output and adapt packaging rather than renaming a dylib to a framework.
- Old provenance says curl is absent. Current `build-ios.sh` requires SDK-specific curl artifacts. Follow inspected code and record the documentation correction.
- The author reports a large ANGLE source/dependency tree, roughly 14–16 GB. This is not a measured total disk budget for this project. Inventory free space and record actual peak usage; avoid launching several memory-heavy dependency builds together.
- ARM64 architecture alone does not distinguish macOS, iOS device and simulator objects. Inspect Mach-O platform/load commands, deployment targets and bundle linkage. Fail on host-library contamination.

References: [S5–S7, S12–S15]. Do not upgrade all dependencies while repairing reproducibility; establish the known baseline, then make targeted changes if a pinned version is unavailable or incompatible.

### 4.2 User-supplied input

Required ROM: USA Rev 1, 32 MiB, big-endian `.z64`; MD5 `e03b088b6ac9e0080440efed07c1e40f`. MD5 is the upstream compatibility identifier, not an authenticity/security guarantee. Also record a SHA-256 for the private input used in tests. Keep the original intact. [S1, S4, S16]

Import should clearly distinguish wrong revision, wrong byte order, unreadable/truncated input and missing data. Renaming cannot correct a different ROM revision. If adding byte-order conversion, write and validate a separate copy. Do not silently patch the ROM into a different revision.

Builds and no-data launch checks must work without proprietary assets. The app must explain how to import supplied data rather than crash on startup. Optional art is independent of the required ROM; failure to import HD content must leave original-art play usable.

Keep game data, extraction caches, screenshots containing game material, saves, signing information and local paths out of public build artifacts. Keep source licensing notices. No automatic asset download is required for the core product.

### 4.3 P0 acceptance

- Fresh checkout and empty project dependency cache produce simulator and iOS device builds through documented commands; caches may accelerate subsequent builds.
- No dependency on the author's home directory, external private repo or a hidden warm build tree.
- Missing-ROM launch shows actionable import UI; correct supplied ROM reaches gameplay.
- Matching-engine Apple Silicon macOS reference runs a mission and bot match.
- One completed early mission and an eight-simulant match work in the available test environment, with save/reload. Label simulator-only evidence explicitly.
- Logs distinguish build, launch and gameplay results. Do not advance to feature changes with unexplained baseline crashes.

## 5. P1: the phone experience

### 5.1 Player journeys

**First run:** launch → select local ROM → receive a clear validation result → enter the game. HD art is offered later, never required to dismiss onboarding. Preserve the player's import if the app is interrupted.

**Quick play:** continue a campaign or enter Combat Simulator without setup work on every launch. Default to faithful gameplay and ordinary bot limits. Modded movement, persistent bodies and high bot counts remain optional choices.

**Controls:** touch works without a controller; attaching/removing a controller changes the visible controls predictably and never loses input. Reload, use, crouch, aiming, weapon switching, gadgets, secondary fire and menus must remain accessible. Respect safe areas and saved layouts. Test the CamSpy and other alternate control modes, not just walking/shooting.

**Gyro trial:** opt-in fine aim while the player is aiming, configurable sensitivity/inversion, neutral recentering and correct landscape orientation. Turning it off fully restores normal control. Do not add gyro movement to both the shell and engine. Measure drift and perceived aiming quality; if it is worse, fix it or leave it experimental rather than enabling it by default.

**Leaving the app:** settings and normal progression survive interruptions, termination and relaunch. Preserve existing background save behavior. Be explicit that flushing progression is not a mid-mission checkpoint system; an interrupted mission may restart unless a separately tested checkpoint feature is added later.

### 5.2 Visual profiles

| Profile | Behavior |
|---|---|
| Original | N64 art, faithful gameplay, suitable internal resolution; mandatory baseline |
| Enhanced | Optional replacement textures with a measured memory limit; no hidden expensive post-processing |
| Remaster art | Optional user-supplied Xbox 360 models/textures/rooms supported by Dab's import path |

Preserve art styles without forcing a giant pack download. Missing or failed packs must fall back safely. Keep saves separate from removable art and purgeable caches. Review each pack's redistribution terms independently. PD Forever Plus and Ultimate/XBLA Plus are candidate packs, not bundled deliverables. [S17]

The checked iOS overlay hides SMAA, FSR, supersampling and TAA controls because the relevant desktop path is unavailable on its GLES renderer. Do not expose ineffective switches. Resolution scaling and texture replacement are separate features. Revisit advanced rendering only after profiling. [S7]

### 5.3 Performance target and measurement

**Target:** sustained 60 fps at a documented internal resolution on the selected baseline iPhone, plus M2 iPad validation. The minimum phone and resolution profile are decided from data. A high-end iPad passing does not qualify older phones. High-refresh play is an optional separately tested profile.

For each physical device, record model, OS, refresh rate, build/engine pin, art pack revision, internal resolution, bot/body settings, brightness, charging state, Low Power Mode and approximate ambient conditions. Match these for comparisons.

Run a 30-minute representative session with an early mission, a demanding later mission and a bot match. Collect frame intervals, long-frame counts, CPU/GPU timing where available, resident memory and thermal-state changes. Record first-load/asset-compilation hitches separately from steady gameplay; do not hide recurring traversal hitches by classifying them as loading.

Initial engineering criteria for the 60 fps profile:

- Steady sections average at least 57 fps in every 30-second window, with p95 frame intervals at most 20 ms and p99 at most 33.4 ms. These are proposed thresholds; revise transparently if measurement limitations require it.
- No crash, memory-pressure termination, sustained input starvation, recurring major audio breakup or increasing memory use across repeated level transitions.
- No claim of “locked 60” from an average counter or simulator run. Inspect slow-frame distribution and the hottest part of the session.
- If a profile fails, reduce optional art/effect cost or resolution based on the identified bottleneck, then rerun the affected test. Do not silently lower the product target to 30 fps.

Preserve the existing pacing work: `PDPacing.m` documents a fix for touch starvation on high-refresh panels by keeping the display link at panel rate while dividing engine ticks. Test changing frame-rate settings and returning from background before rewriting that code. [S18]

Avoid blanket `fast-math` and broad optimization switches. Upstream performance work found compiler-induced behavioral changes and uses seeded replays to detect divergence. Follow those checks for simulation-sensitive optimizations; use ordinary profiling for rendering bottlenecks. [S19]

### 5.4 Reliability and gameplay acceptance

| Area | Required evidence |
|---|---|
| Campaign | Full solo campaign completion coverage before describing it as fully playable; track mission/difficulty, objectives, gadgets, cutscenes, unlocks and save/reload. A focused preview may ship only with explicitly narrower coverage. |
| Bots/challenges | Representative scenarios and eight-simulant matches; challenge progression and saved setup verified. Stress settings are optional, not the baseline. |
| Input | Complete a mission with touch and with a controller; test hot-plug, layout persistence, secondary fire, gadgets and camera tools. Human usability acceptance is separate from scripted input. |
| Lifecycle | Background/foreground, audio interruption, screen locking and relaunch preserve expected state. No repeated app wedging or corrupted settings. |
| Player data | Back up/read back an existing installation's Documents and Library; update without identity/container reset; verify saves and settings afterward. |
| Visuals | Check HUD/readability, transparency, dark scenes, scopes/effects and level transitions in each supported profile. |
| Reproducibility | Rebuild the selected candidate from the recorded pins and clean dependency recipe; no local-only edits required. |

Do not automate an in-use physical device without the relevant authorization. If no device is available, continue build, simulator correctness, desktop regression and documentation work; explicitly leave phone acceptance incomplete.

## 6. P2/P3: multiplayer without a new networking project

Use Dab's existing host-authoritative implementation. Do not combine it with `port-net`, murkantor or GoldenPad protocols. Pin the same engine/protocol revision on both endpoints. The desktop peer is a reference/companion build, not a second full UI product.

First dry-run the existing overlay against its current pin. Then assess the newer pinned engine, port conflicts intentionally and rerun P1 regressions. Maintain a recoverable solo baseline. Keep the network experiment separately switchable until accepted.

### P2 sequence

1. Direct LAN connection between one iPhone and one Mac using locally supplied matching assets. Handle local-network permission, IPv4/IPv6 interfaces as applicable, clear connection errors and app backgrounding. Confirm neither endpoint unexpectedly contacts public services for a direct session.
2. Complete Combat Simulator matches with kills, scoring, bots, death/respawn and map transitions. Test both host roles if both are supported; clearly document any client-only restriction.
3. Complete two campaign co-op missions, including a nontrivial objective/gadget case. Verify objectives, both players' views, death/restart and progression on each endpoint. Determine and document host-only versus per-player saves; do not assume automatic shared progress.
4. Exercise disconnect, reconnect/rejoin behavior and background/resume. It is acceptable to return to a clear lobby/restart state if seamless rejoin is unsupported; it is not acceptable to hang, corrupt a save or falsely show a connected player.
5. Introduce controlled latency/loss after LAN works. Record actual conditions and outcomes rather than promising a universal networking tolerance.

Dab documents host-served content for some conversions/mods. For this project's initial LAN mode, both machines supply their own base assets. Inspect content-serving paths and prevent unintended game-data transfer before offering public rooms. Online capability is not permission to deploy or depend on someone else's lobby/relay. [S10]

**P2 exit:** repeated complete matches and co-op missions on actual endpoints, matching protocol documented, solo regression checks still pass, known failures described.

**P3 counter-op:** validate guard possession, eligible bodies, deaths, side assignment, mission outcomes and transitions. Only then consider Internet discovery, NAT traversal or relay and more than two players. Neither a twelve-player upstream claim nor a lobby screenshot qualifies these features on iPhone.

## 7. Delivery, risks and decision rules

Expected implementation outputs: one primary checkout, pinned dependency/build manifests, minimal patches, build/import documentation, test evidence, a known-issues list and private candidate artifacts. Reuse existing diagnostics; add focused tests for input normalization, save handling and any changed network behavior. Do not build a general test framework to begin the port.

| Risk | Response |
|---|---|
| Missing sibling dependency recipes | Reconstruct minimal pinned recipes from official sources; keep the failure explicit until a clean build proves them |
| Large engine update breaks Apple patches | Maintain baseline, inspect conflicts, update in reviewable steps, rerun gameplay/lifecycle checks |
| HD art causes heat or memory pressure | Measure profiles on the phone, reduce optional cost, retain original-art fallback |
| Another port already satisfies the need | Demonstrate improvements; prefer a small credited derivative or upstreamable fixes over a cosmetic fork |
| Gyro feels worse | Keep opt-in, test calibration/filtering, do not make it a launch promise before acceptance |
| Network scope expands | Finish two-device LAN first; keep P1 independent and defer services/large rooms |
| No physical hardware/signing available | Continue independent engineering; request only the missing input and mark device gates not run |

Use existing GoldenEye/PadMint conventions for app UX, import, controls, diagnostics and save preservation where appropriate. Reuse code only after checking the actual implementation and its license. Similar game ancestry does not prove protocol or engine compatibility.

A later public release requires Chris's authorization, asset/content review and PadMint clean-player verification as specified in `goal.md`. Do not claim “first iOS,” “fully playable,” “60 fps,” or cross-play beyond the recorded evidence. No public announcement is part of this handoff task.

## 8. Source register

All sources reviewed as public code/documentation on 20 October 2026. Commit-pinned links define the research snapshot; refresh moving references before implementation decisions. Documentation assertions are not independent device benchmarks.

- **S1 — complete decomp and input versions:** https://github.com/n64decomp/perfect_dark/blob/169ed48bdcbfb3b568b028bd5bebb27680073514/README.md
- **S2 — native desktop reference:** https://github.com/perfect-dark-pc-port/perfect_dark/tree/32a1cb9f268dd3ac73016801025c6bbbfa20130f
- **S3 — Dab features/current reviewed engine:** https://github.com/DabDavis/perfect-dark-dabs-mod/tree/3ee8ed0cd549b64350848655c43ae1568e449c6d
- **S4 — existing iOS product/prior art:** https://github.com/rebelancap/perfect-dark-ios/blob/b88f7cff611d54f7d233ebe3882e2295e5ecca9a/README.md
- **S5 — baseline build sequence:** https://github.com/rebelancap/perfect-dark-ios/blob/b88f7cff611d54f7d233ebe3882e2295e5ecca9a/docs/build.md
- **S6 — dependency provenance:** https://github.com/rebelancap/perfect-dark-ios/blob/b88f7cff611d54f7d233ebe3882e2295e5ecca9a/work/deps-PROVENANCE.md
- **S7 — actual iOS flags and hidden effects:** https://github.com/rebelancap/perfect-dark-ios/blob/b88f7cff611d54f7d233ebe3882e2295e5ecca9a/scripts/build-ios.sh and https://github.com/rebelancap/perfect-dark-ios/blob/b88f7cff611d54f7d233ebe3882e2295e5ecca9a/overlay/patches/0041-ios-new-desktop-surface-off.patch
- **S8 — input implementation inspected:** https://github.com/rebelancap/perfect-dark-ios/tree/b88f7cff611d54f7d233ebe3882e2295e5ecca9a/app/ios and https://github.com/DabDavis/perfect-dark-dabs-mod/blob/3ee8ed0cd549b64350848655c43ae1568e449c6d/port/src/input.c
- **S9 — iOS engine pin:** https://github.com/rebelancap/perfect-dark-ios/blob/b88f7cff611d54f7d233ebe3882e2295e5ecca9a/UPSTREAM_PIN
- **S10 — authoritative-host networking and content behavior:** https://github.com/DabDavis/perfect-dark-dabs-mod/blob/3ee8ed0cd549b64350848655c43ae1568e449c6d/CLAUDE-notes/netplay.md
- **S11 — revision comparison:** https://github.com/DabDavis/perfect-dark-dabs-mod/compare/90c8622e74b35be669d60d177effc6d7d2d7621c...3ee8ed0cd549b64350848655c43ae1568e449c6d
- **S12 — curl configuration:** https://github.com/rebelancap/perfect-dark-ios/blob/b88f7cff611d54f7d233ebe3882e2295e5ecca9a/work/curl-PROVENANCE.md
- **S13 — public dependency recipe references:** https://github.com/rebelancap/q2repro-ios/blob/dfdf758f4aa9a87126d1ed70fa0e0dbe369cab7c/scripts/build-angle-ios.sh and https://github.com/rebelancap/q2repro-ios/blob/dfdf758f4aa9a87126d1ed70fa0e0dbe369cab7c/scripts/build-curl-ios.sh
- **S14 — SDL iOS guidance:** https://github.com/libsdl-org/SDL/blob/release-2.32.8/docs/README-ios.md
- **S15 — expected framework assembly:** https://github.com/rebelancap/perfect-dark-ios/blob/b88f7cff611d54f7d233ebe3882e2295e5ecca9a/scripts/make-angle-xcframeworks.sh
- **S16 — input validation implementation:** https://github.com/rebelancap/perfect-dark-ios/blob/b88f7cff611d54f7d233ebe3882e2295e5ecca9a/app/ios/PDOnboarding.m
- **S17 — optional artwork and separate terms:** https://github.com/retro-foundry/Perfect-Dark-Plus-HD-Textures/tree/7be860551c137bc0114cb0e6f49ea808d4e73960
- **S18 — pacing implementation:** https://github.com/rebelancap/perfect-dark-ios/blob/b88f7cff611d54f7d233ebe3882e2295e5ecca9a/app/ios/PDPacing.m
- **S19 — profiling and correctness notes:** https://github.com/DabDavis/perfect-dark-dabs-mod/blob/3ee8ed0cd549b64350848655c43ae1568e449c6d/CLAUDE-notes/performance.md
- **S20 — Apple port license/notices:** https://github.com/rebelancap/perfect-dark-ios/blob/b88f7cff611d54f7d233ebe3882e2295e5ecca9a/LICENSE

Optional context, not required to execute: Chris's Notion tracker at https://app.notion.com/p/3c2ceacc88a581229bf7ed19d1f8cadf. This document and `goal.md` contain the necessary plan without that account access.
