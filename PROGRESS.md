# Darkpad progress

## Current milestone: P0 — running baseline, acceptance incomplete

Implement `docs/goal.md` and `docs/prd.md`, then Goldenpad-inspired controls/three-dot utilities, gyro trial, enhanced art and staged LAN/co-op. At most one booted simulator. No public release authorized. Previous goal turns made implementation and runtime-validation progress.

Branch: `codex/perfect-dark-foundation`. Foundation checkpoint `3eab186`; ANGLE Python fix `4625c23`. User's document relocation preserved.

## Exact sources and environment

- Apple shell: rebelancap/perfect-dark-ios `b88f7cff611d54f7d233ebe3882e2295e5ecca9a`; historical docs under `docs/upstream` are not Darkpad measurements.
- Engine: `90c8622e74b35be669d60d177effc6d7d2d7621c` (`UPSTREAM_PIN`), unmodified vendor; all 49 overlay patches apply.
- Goldenpad: chrissotraidis/goldenpad `52bb67328c2cc4b98b4242ba0539985bd61fc2d3`, downloaded under ignored `work/references`; direct behavior inspection in `docs/goldenpad-reference.md`.
- SDL2 `98d1f3a45aae568ccd6ed5fec179330f47d4d356` (2.32.8); curl 8.11.0 archive SHA-256 `264537d90e58d2b09dddc50944baf3c38e7089151c8986715e2aaeaaf2b8118f`.
- ANGLE `e25e8d8565f7b077002e07c2cbacfc2eec35aec0`; depot_tools `3a8af1e64be01a524f7d1c46daf8c2dcac63ff85`. Transitive actual revisions in `work/evidence/angle-dependency-revisions.txt`; pins in `dependencies/pins.env`.
- Mac14,2 ARM64, 24 GiB RAM; macOS 27.0.1; Xcode 26.6 (17F113), SDKs 26.5; CMake 3.27.1, Ninja 1.13.2, XcodeGen 2.46.0, Python 3.11.2 for ANGLE. Default user Python 3.8 is too old for Dawn's generators; recipe selects 3.11 locally without changing user defaults.
- Initial free disk 396 GiB; ANGLE tree/build about 14 GiB, project build tree about 1.6 GiB. Tool inventory in `work/evidence/toolchain.json`.
- Ref ROM: 33,554,432 bytes, MD5 `e03b088b6ac9e0080440efed07c1e40f`, SHA-256 `4e51142acac686d96861cecc58cf7cb7c3b06b21733b7f8ed609a709dc039a21`. Original preserved. ROM normalization tests passed v64/n64, truncation rejection and original preservation.

## Five statuses

- **Source/build:** PASS baseline Mac, ARM64 simulator and unsigned iOS device apps. Local SDL2/curl/ANGLE recipes require no sibling checkout. `scripts/bootstrap-apple.sh` assembles the proven steps; whole-command empty-project-cache rebuild passed on this Mac (details below); second-Mac reproduction remains untested. No broad engine optimization changes.
- **Package/install:** simulator installed; native Files picker imported the supplied ROM; missing-ROM UI works. Updated installation preserved EEPROM and ROM. Device package built but not installed/signed.
- **Physical gameplay:** NOT RUN — `devicectl list devices` found no connected devices. Simulator reached actual dataDyne Defection via saved agent/mission menus; firing and sustained movement work. Defection and Investigation / Agent completed and their time/unlock progression reloaded in the simulator; full campaign coverage remains incomplete.
- **Performance:** NOT QUALIFIED — no physical-device thermal/frame-time session. Simulator counters are not phone benchmarks.
- **Release readiness:** NOT READY. Private development only; assets/saves/captures/builds ignored. P1/P2 acceptance remains incomplete.

## Reproducible commands and evidence

- `scripts/bootstrap.sh`, `scripts/apply-overlay.sh`: exact engine and clean application of 49 patches (`work/evidence/bootstrap.log`, `overlay.log`).
- `scripts/build-apple-deps.sh {iphonesimulator,iphoneos,macosx}`: SDL2/curl built, every tagged archive object checked ARM64 and correct platform (SDL2 186/186/185, curl 169 per SDK). SecureTransport TLS; optional nghttp2/HTTP3 discovery disabled after finding unintended Homebrew linkage in the first Mac attempt.
- `scripts/fetch-angle.sh`, `scripts/build-angle-ios.sh {simulator,device}`: both native framework pairs built and checked. Use DEPS-provided GN and host Ninja, avoiding depot_tools' stale Python-wrapper requirement. Logs `angle-{simulator,device}.log`.
- `scripts/build-macos.sh`: `build/oracle-clang/pd.arm64`. Chicago 600-frame smoke and eight-simulant 2,000-frame smoke exited 0; screenshots inspected. Mac save/reload kept EEPROM byte-identical. These are partial correctness checks, not mission/match completion.
- `scripts/build-simulator-app.sh`: `build/dd-iphonesimulator/Build/Products/Debug-iphonesimulator/perfectdark.app`; `app-simulator-update.log` confirms build. Project explicitly ARM64; generic simulator builds formerly attempted unsupported x86_64 watchdog code.
- `scripts/build-ios.sh device`, `scripts/make-angle-xcframeworks.sh`, `scripts/gen-app-project.sh`, then `xcodebuild -project app/perfectdark.xcodeproj -scheme perfectdark -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build/dd-iphoneos CODE_SIGNING_ALLOWED=NO build`: PASS. Device binary passes platform check. Logs `engine-device.log`, `app-device-update.log`.
- Simulator first boot services delayed launch; initial simctl request returned no process. Native app launch subsequently worked. No baseline game crash established by that delay.
- Native Files import and touch menus created agent **Dark**, saved to Game Pak, selected Defection/Agent and launched with the proper Falcon 2 loadout. Native touch fired; timed touch stream moved from `14.9,159.0,-20.8` to `449.4,-441.0,-13.2` and released all inputs. Evidence `sim-{first-state,touch-before,touch-after,movement}.txt`, `sim-defection-touch.png`.
- Quit/relaunch visibly retained **Dark** (`sim-saved-agent-reload.png`). Documents/Library backup in `work/evidence/sim-before-update/`. Pre-update EEPROM SHA-256 `97f96398b6740a47e8b4ef89a6fbb1eadf4f057d51a633b3f6ea7f7bb67ec3d9`; installation preserved its bytes.
- Fixed watchdog false hangs before first engine frame. Updated app waited >30 seconds on onboarding with `frames=0`, `hang_dumps=0` (`sim-onboarding-watchdog.txt`), then restored ROM resumed gameplay (`sim-after-update-state.txt`). Private ROM backup was restored; none left renamed.

## Normal match and dropdown checkpoint

- Fixed an actual touch selection defect: tapping **8** in Number of Simulants committed **1**. Patch `0055` uses the dropdown's rendered bounds and scroll offset to focus the tapped row before selection; outside taps cannot commit the previous value. Native taps now select eight. All 49 patches apply to a fresh vendor copy; vendor remains unmodified. Simulator and device engine/app builds passed after the fix.
- Normal simulator flow: loaded saved agent Dark, configured Skedar / Pistols / eight Normal Sims / one-minute limit, saved setup **8bots**, started a non-spectator game, moved with touch, and reached Game Over naturally. Rankings include NormalSim8 and scoring bots. Saved player **Player18**, quit/relaunched, loaded **8bots** and **Player18** through the menus. Reloaded statistics show Games Played 1, Time 0:00.57, Pain Received 0.6. This verifies a completed short match and player-stat persistence, not saved bot composition, combat usability or a campaign mission. Later byte-level audit found the setup named 8bots actually contains zero enabled bots; saved setup acceptance remains OPEN. Evidence: `sim-normal-match-{game-over,ranking}.png`, `sim-player18-reloaded-stats.png`.
- Earlier direct `--mpsims 8` spectator runs reached Game Over on Mac and simulator. That debug path bypasses loading the single-player agent and produced a missing-agent save error after saving the multiplayer profile; use the normal menu path for save acceptance. No cheat or endless-match flag used for these completion runs.
- Added a native local Mac reference app wrapper (`scripts/package-macos-reference.sh`) around the unchanged upstream ARM64 binary. Native input and postmatch UI verified; ROM and saves are supplied outside the bundle. This is a private reference, not a release artifact.
- Bootstrap now explicitly repackages ANGLE after building both device and simulator slices, preventing an old simulator-only XCFramework from being reused. Both framework manifests contain the required slices.
- Before updating the simulator app, backed up Documents/Library; ROM and EEPROM hashes were unchanged after installation (`dropdown-update-preservation.json`). Existing agents/profiles retained. Boot services again delayed initial process launch; subsequent launches worked.

## Goldenpad utility implementation

- Added persistent 44-point ellipsis → native Utilities hub → Settings, Edit Touch Controls, Diagnostics and Resume. Reuses the existing focus-safe settings window; opening clears held input and preserves the original game START action.
- Native UI and editing now pause simulation at the engine frame boundary, retaining a pre-existing pause. Live simulator checks passed: held input cleared, player position identical across paused observations, Resume restored `engine_paused=0`, editor kept `engine_paused=1` until Done. Evidence `utilities-{held-open,held-later,live-resumed,edit,edit-done}-state.txt`.
- Corrected utility placement when SDL reports portrait safe-area insets on its landscape window; measured bounds `74,12,44,44`. Gameplay button safe areas still need work.
- Simulator and unsigned device builds pass (`app-utilities-final.log`, `app-device-utilities-final.log`). Native destinations inspected. Documents/Library backed up before updates; ROM and all four detected save/data files retained exact hashes.
- P0 mission completion remains incomplete. Proceeded with the directly requested shell utility improvement while preserving the pinned engine/reference baseline; no broader acceptance claim. Current live session was entered through the debug stage command solely to test native pause, so it is not campaign completion evidence.

## Default touch-layout safe areas

- Built-in gameplay controls now translate inward as a group to avoid the display cutout and bottom edge, preserving spacing between the action buttons. START/BACK are inset separately; the temporary left FIRE mirrors the adjusted FIRE position. Explicit custom positions remain unchanged.
- Same iPhone simulator inspected in the layout editor: all default rings clear the cutout. Moved SWAP, closed and reopened the editor, and visually confirmed its exact custom placement. Restored the originally empty layout and 100% scale after the check. No existing custom layout was erased (`layout_entries=0` before this test).
- Simulator/device builds pass (`app-safe-controls.log`, `app-device-safe-controls.log`); ROM/save hashes match before and after installation (`safe-controls-preservation.json`). Other phone sizes, iPad and physical thumb reach remain unqualified.

## Goldenpad controller preset

- Added Settings → Aiming → Use Goldenpad Controller Layout. Explicit confirmation shows RT fire, LT aim, LB crouch, A/Y/RB weapon, B/X interact; PD extras are left-stick-click reload, right-stick-click alternate fire, View/Back weapon wheel. Start and A/B menu controls remain. Keyboard/mouse and D-pad bindings are preserved. Conflicting akimbo-trigger mode is disabled by this preset.
- Preflights every slot before mutation, backs up prior bindings in defaults, and persists engine bindings. Does not overwrite custom configurations automatically or on controller reconnect. First runtime attempt caught public API action-name mismatch without changing bindings; fixed names then applied successfully.
- Verified 56 action assignments across four players, exact keyboard/mouse and D-pad preservation, and all binding sections unchanged after quit/relaunch (`goldenpad-applied.ini`, `goldenpad-bind-validation.json`). Simulator/device builds pass. This proves configuration, not physical controller behavior; gadget/CamSpy acceptance remains open.

## Art profiles

- Added Original (default), Enhanced (existing 2× texture filter plus optional installed packs), and Remaster (optional Xbox assets). Resolution remains independent. Original clears every remaster component through engine setters so live asset caches invalidate; unavailable Remaster assets fall back to N64 art with an explicit status.
- Simulator checks passed for all three profiles, live return to Original, and Enhanced persistence across quit/relaunch. No optional art pack was supplied, so real replacement assets and their memory cost remain unqualified. Fresh roll gestures now default off; explicit existing preferences survive.
- Final simulator and unsigned device builds pass (`app-art-profiles-final.log`, `app-device-art-profiles-final.log`). ROM/save hashes survived updates; Documents/Library backed up. Legacy development `xbla release on/off` now selects Remaster/Original.

## Normal campaign attempt

- Loaded preserved Dark agent through Game Pak → Solo Missions → Defection → Agent → Accept. Touch movement, firing, automatic reload, damage and normal failure/retry screens worked. Attempt ended deceased at 2:48, one kill, 13 shots; **mission completion still fails acceptance** (`defection-normal-attempt-failed.png`, matching state).
- Retried through the normal Retry menu. Retry was paused in native Settings on the lower roof, then ended for the gyro build update. Tool/decision latency left the first attempt exposed to guards; use native pause between observations during route validation. No health/objective cheats or save edits used.

## Experimental gyro trial

- Added opt-in handset gyro through the existing look-degrees interface, aim-only, with sensitivity/inversion and neutral reset on aim release. Stops sensors for menus, editing, inactive app and disabled preference; invalid/stale samples and long gaps cannot produce a catch-up turn. Both landscape orientations mapped; no engine gyro implementation added.
- Portable integration checks pass for 30/60/90/120 Hz, duplicate samples, orientation flips, inversion, sensitivity, aim release, gaps and stale/nonfinite data (`gyro-math-test.log`). Run with `xcrun --sdk macosx clang -isysroot "$(xcrun --sdk macosx --show-sdk-path)" -std=c11 -Wall -Wextra -Werror tests/gyro_math.c -o /tmp/darkpad-gyro-test && /tmp/darkpad-gyro-test`. Explicit SDK avoids this host's mismatched default CLT SDK/linker.
- Simulator/device builds pass. Native toggle persists across relaunch; unavailable sensor reports correctly with zero motion input. Restored off. ROM/save hashes preserved (`gyro-preservation.json`). Physical axis feel, drift, latency and lifecycle sensor shutdown remain **not run**, so this is experimental, not accepted gyro quality.

## Controller reconnect preservation

- Found and removed inherited first-connect R3 unbinding, which contradicted custom-binding preservation. Connection events now only update overlay/gesture state; the explicit Goldenpad preset owns its binding changes.
- Added development-only `pad binds` snapshot of actual engine bindings. Staged reversible custom R3 roll binds for four players, then checked all 512 live slots before/after repeated simulated disconnect/reconnect. Exact match, including all custom R3 slots (`pad-preserve-live-{before,after}.json`). Restored original pd.ini byte-for-byte after testing.
- Simulator/device builds pass (`app-pad-preserve.log`, `app-device-pad-preserve.log`); update preserves ROM/save hashes. This is notification-path evidence, not a physical Bluetooth hot-plug test.

## Empty-cache bootstrap acceptance

- `scripts/bootstrap-apple.sh` completed uninterrupted, exit 0, from clean managed worktree `/Users/chrissotraidis/.codex/worktrees/clean-bootstrap/darkpad` at `dc53fa0`, with no pre-existing work/build/vendor directories. Engine, SDL/curl (three SDKs), ANGLE (both iOS slices), Mac reference and both app bundles rebuilt. Both final Xcode builds succeeded. Log: `work/evidence/clean-bootstrap-dc53fa0.log`.
- No working-checkout dependency libraries or game assets copied into the clean tree. This proves an empty **project** cache on this Mac with installed prerequisites; system developer tools/vpython caches remain host dependencies. No claim of a second Mac test.
- Installed the clean-produced simulator app after Documents/Library backup; all four ROM/save hashes match (`clean-build-update.json`). Only the existing dedicated simulator remained booted. Mission/save-reload acceptance proceeds on this clean build.

## Confirmed utility session exit

- Added **End Mission or Match…** to the three-dot Utilities menu, following Goldenpad's confirmation pattern with independent implementation. Explains unfinished mission restart and retained completed progression; Keep Playing cancels.
- Overlay 0056 calls the active port's native abort/end-match path from the shell frame queue. Rejects menu/training, cutscene, dead-player and already-ended states; no forced stage reset. Configuration flush follows a successful request.
- Simulator verified: no-active-session notice at agent selection; cancel then Resume preserves the live mission; confirmation produces normal Aborted / Disavowed results (`work/evidence/utility-end-mission.png`). Full app relaunch retains Defection Agent best time 3m:31s and Investigation unlock (`utility-end-reloaded-time.png`). Multiplayer setup file unchanged. Combat Simulator additionally verified: Keep Playing then Resume preserves the live Skedar match; confirming End Session follows the native new-player save prompt and reaches Game Over / 1st (`work/evidence/utility-end-match.png`). Declined creating a new test profile. Physical-device runtime checks remain pending.
- All overlay patches apply from the pristine pin; simulator/device engine and app builds pass (`overlay-end-session.log`, `engine-end-session-*.log`, `app-end-session-*.log`). One simulator only; private pre-update save/preferences backup in `work/evidence/before-end-session/`.

## Inactive-app pause and input guard

- Found that background presentation stops while occasional engine frames still advance. Extended the existing native pause ownership and touch suppression to inactive iOS application states. Keeps game-owned pauses intact and releases the shell pause only after all native UI/editing/inactivity reasons clear. Vision behavior unchanged.
- Simulator/device builds pass (`app-lifecycle-sim.log`, `app-lifecycle-device.log`). Live Defection test: active pause=0 → background pause=1/presentation=0 → foreground pause=0/presentation=1, same player position and zero published touch input. Settings → background → foreground stays paused until Settings closes, then returns to pause=0. Agent-selection's pre-existing pause remains intact. Evidence under `work/evidence/lifecycle-check/`.
- Documents/Library backed up before update. ROM, configuration and multiplayer setup hashes unchanged across update/tests. Existing agent loaded with Defection best 3m:31s and Investigation unlocked; EEPROM later changes as expected after starting another mission. App left paused in Settings on the roof. Actual held-finger cancellation, screen lock and physical interruptions remain to be exercised.
- Existing audio recovery also passed a synthetic lost-interruption-end test: one device restart, queue drains again, dropping=0 (`audio-lifecycle-lost-end.txt`). Sent explicit end afterward. This is notification-path/queue evidence, not a real phone-call or audible quality test.

## Lock and held-input lifecycle checks

- On the same dedicated simulator, locked the phone during live Defection via Simulator → Device → Lock. Bridge reports engine pause=1, presentation=0, zero published touch input. Unlock returned pause=0/presentation=1 at the identical player position (`work/evidence/lifecycle-check/{locked,unlocked}.txt`). No second simulator was booted.
- Held AIM through the existing diagnostic touch handler for 30 seconds: verified mask=0x10 and aim mode=1 before backgrounding. Home cleared mask to zero and aim mode to zero while paused; foreground retained zero input and resumed. Evidence `held-aim*.txt`. This proves shell input cancellation using a synthetic held touch; physical UIKit multi-touch cancellation remains unqualified.
- Started the gadget-path audit: pinned engine `src/game/bondeyespy.c:688` uses a distinct PC-control path for camera movement/altitude, use, fire and exit. Needs runtime coverage in Investigation; ordinary walking/aim tests cannot qualify it. App remains safely paused in Settings during Defection.

## CamSpy runtime coverage

- Normal Investigation / Agent starts from the existing unlock and supplies CamSpy. Deployed through pause → Inventory. Verified touch yaw/pitch, forward flight, AIM-drag ascent (HUD 0.94 m → 1.42 m, pitch remains 9°), FIRE shutter animation and WHEEL exit to Joanna. Private screenshots `work/evidence/camspy/`; documented the controls in `docs/goldenpad-reference.md`.
- First attempt ended deceased at 0:57 while Joanna stood exposed. Retried normally, then paused between short diagnostic touch sequences. No cheats, loadout mutation or save edits. Investigation objective/mission completion, descent/strafe and physical camera controls remain open. Current run is alive, at the starting lift, back in Joanna view and paused in Settings. Only the dedicated simulator used.

## ROM classifier alignment with engine

- Rejects unknown US revision numbers (previously every nonzero revision passed) and mismatched cartridge titles (the engine later rejects these). Non-regular files now receive an unreadable-file explanation. Retained the existing header-compatible modified-ROM policy; this does not establish strict stock-only validation.
- Added read-only development `rom check PATH` and `tests/rom_classifier.py`. Fourteen synthetic fixture cases pass against the running simulator app: size/magic/byte order/regions/revisions/title/id, modified-content notice, directory and missing path. Fixtures contain no game assets and are removed afterward. Log `work/evidence/rom-classifier-test.log`. Installed ROM separately reports the expected stock MD5.
- Simulator/device builds pass (`app-rom-validation-*.log`). Documents/Library backed up before update; ROM, EEPROM, configuration and multiplayer setup hashes match after install/tests (`rom-validation-preservation.json`). This update ended the unfinished Investigation test run; saved completed progression is preserved. Existing named-ROM startup bypass and loose-ROM adoption behavior remain to be reconciled with first-run validation/preservation requirements.

## Validated ROM startup and original preservation

- Named ROMs now pass classification before startup. Validation and picker imports follow the engine's actual base-directory choice: Documents/data when present, otherwise Documents. Invalid input stays in place and shows its explanation in onboarding.
- Automatic loose-ROM adoption copies atomically rather than moving the supplied original. More than one 32 MiB candidate requires explicit picker selection. Files polling runs once per second instead of hashing on every run-loop iteration.
- Simulator checks passed: invalid root ROM shows actionable error; two loose candidates remain unselected; one candidate copies and retains its source; invalid data/ ROM is rejected even beside a valid root ROM; removing the invalid fixture allows the valid root input to be copied into data/ and starts the engine. Screenshots `work/evidence/rom-startup-invalid{,-data}.png`. Temporary inputs cleaned up and stock ROM restored.
- Simulator and unsigned device builds pass (`app-rom-startup-*.log`). Documents/Library backed up before installation. ROM, EEPROM, configuration and multiplayer setup SHA-256 values match before/after (`rom-startup-preservation.json`). Only the dedicated simulator ran. Physical hardware validation and the inherited modified-ROM policy remain open.

## Sustained frame-interval measurement

- Added development `pacing samples` with chronological raw intervals, monotonic timestamps, sequence IDs and reset/session identity. Read at engine frame boundaries; normal pacing behavior unchanged.
- `scripts/capture-frame-intervals.py` saves raw JSONL plus footprint/thermal/audio state snapshots and evaluates rolling 30-second windows ending at every frame (57 fps, p95 ≤20 ms, p99 ≤33.4 ms). Rejects ring gaps, resets/restarts, stale and short captures. Preserves long stalls. Clock is pacing-wait return, not GPU completion; physical workload qualification still required. Usage/limitations in `docs/pacing.md`.
- Synthetic acceptance tests pass for empty/short recordings, steady 60 and 30 Hz, a five-second stall and p99-tail failure. Runtime 32-second simulator capture retained 1,909 intervals, 120 complete windows, no gaps (`frame-capture-smoke.jsonl`, `frame-capture-smoke-report.json`). Explicit histogram reset correctly invalidated another in-flight capture (`frame-capture-reset-test.log`). This is measurement-path evidence only.
- Both simulator and unsigned device builds pass (`app-frame-capture-*.log`). Backed up Documents/Library before update; ROM, EEPROM, config and multiplayer setup hashes match afterward (`frame-capture-preservation.json`). Single existing simulator only. Physical 30-minute gameplay, GPU profiling and thermal acceptance remain not run.

## Touch weapon and stance runtime coverage

- Normal Defection / Agent from the saved agent; existing 3m:31s record remains visible. Tested on the dedicated simulator through the actual overlay handlers, with Settings pauses between sequences. No loadout, ammunition, position or save mutation.
- ALT selects Falcon 2 Pistol Whip (gunfunc=1, highlighted ALT), then returns to Single Shot (gunfunc=0). RELOAD restored 7/72 rounds to 8/71. Three separate FIRE taps then reduced magazine to 5 with reserve 71; RELOAD restored 8/68. Screenshots/state in `work/evidence/touch-weapon-controls/`.
- CROUCH cycles camera height 159 →114 →69 →159 at unchanged x/z. SWAP cycles Falcon 2 (weapon 3) → unarmed (1) → Falcon 2 (3). Input immediately after initiating Settings dismissal can remain suppressed during its transition; repeated checks waited 0.7 seconds for dismissal before sending touches.
- These are synthetic touch correctness checks, not human usability or physical controller acceptance. No code change/build required. Current mission remains safely paused on the roof in Settings. Only the existing simulator used.

## Art-profile live switching and missing-asset fallback

- During normal Defection, switched Display → Art profile using the actual segmented-control handler. Enhanced applied EnhanceTextures=1, replacement-pack loading on, Xbox art off. Remaster applied EnhanceTextures=0 and pack loading off; with xbla_available=0, Settings explicitly reports “No remaster assets — using N64 art” and the game continues rendering the original scene. Original restores both optional paths off.
- Screenshots inspected for scene/HUD continuity and retained under `work/evidence/art-profile-runtime/`. Drawable remains 2622×1206 in every profile: art selection does not silently change resolution. Three further complete cycles asserted the engine flags and resolution after each apply; all nine switches passed (`repeated-switches.json`). Simulator footprint ranged 108.4–109.1 MB during this short run, insufficient to establish a memory limit or exclude long-term growth.
- This verifies live switching and missing-asset fallback on a roof scene only. No replacement pack or remaster assets were present; loaded-pack rendering, level transitions, scopes/transparency and physical memory/performance remain unqualified. Original restored, mission paused in Settings. One simulator only; no code changes or rebuild required.

## Stock-ROM requirement enforced

- Reconciled the inherited modified-ROM acceptance with the assignment's explicit supported input: USA Rev 1 with MD5 e03b088b6ac9e0080440efed07c1e40f. Header/size matches with different contents now return a distinct content-mismatch result explaining possible modification/damage and asking for an unmodified input. No silent repair or alteration. This supersedes earlier notes leaving that policy unresolved.
- All 14 classifier fixture cases pass, including rejection of synthetic matching-header content (`stock-rom-classifier-test.log`). Installed stock input passes separately (`stock-rom-accepted.txt`). Startup with the synthetic file displays the actionable mismatch UI (`stock-rom-content-mismatch.png`); restoring the stock ROM atomically automatically resumes startup.
- Simulator and unsigned device builds pass (`app-stock-rom-*.log`). Documents/Library backed up before installation; ROM, EEPROM, configuration and match setup SHA-256 values still match after the complete test (`stock-rom-preservation.json`). Unfinished roof test run ended for update; saved progression preserved. One simulator used.

## Investigation campaign run in progress

- Started normal Investigation / Agent from the existing unlock. Advanced through the starting corridor and two access doors into the first lab encounter using touch controls. Collected the first guard's CMP150 normally; after it depleted the engine switched back to the Falcon 2. Corridor guard and three lab guards cleared; one nearby lab guard remains. Last readback shows full health, paused in Settings.
- Read-only LLDB inspection supplies position/guard and room-connectivity evidence; no health, position, ammunition, objective or save edits. Private route/current-state files under `work/evidence/investigation/`. The diagnostic stream command returns before its gesture finishes; waiting its duration corrected an early script sequencing mistake that had cancelled movement by opening Settings immediately.
- Investigation's isotope and Dr. Caroll objectives remain incomplete. Preserve the live process (PID 25917) for continuation, rather than restarting for unrelated shell changes. Same single simulator. This run has not established another campaign completion or human touch usability.

## Investigation isotope objective verified

- Continued the live normal Agent run: cleared the remaining lab guard and both isotope access guards, collected ammunition, and traversed the offset lab doorway and two Caution doors using normal touch actions.
- Deployed CamSpy through Inventory, flew into the chamber, ascended with AIM-drag, framed the isotope and pressed FIRE. The game visibly reports **Objective 1: Completed** (`work/evidence/investigation/isotope-completed.png`). This is objective-level gadget coverage, not just a shutter animation.
- Exited with WHEEL and withdrew Joanna from the radiation corridor. Last readback: health 0.6875, position approximately (1556,157,-2638), heading 269.97; paused in Settings. Dr. Caroll and mission completion remain pending. Preserve PID 25917. Read-only diagnostics guided the inputs; no game-state mutations.
- Exactly one booted simulator confirmed. Private route notes and current readback are updated for continuation.

## Investigation Sector Two traversal

- Continued the same live run through Sector Two toward Sector Three. Cleared guards 14, 12, 16, 15, 17, 18, 19 and 20 using normal touch firing; crossed the lab corridor and collected ammunition/reloaded normally. Isotope objective remains complete; Dr. Caroll remains pending.
- Current paused live position is approximately (320,157,-8453), heading 269.97, health 0.394, approaching room 72 via room 71. Preserve PID 25917 and the existing container. Private readback, screenshot and route notes updated under `work/evidence/investigation/`.
- This expands simulator campaign traversal evidence but does not establish a second completed mission or physical touch usability. No build/install or save modification during this run.

## Investigation laser-corridor failure

- Continued normal Agent run through Sector Three: guards 21–24 cleared, doorway traversed after correcting lateral alignment. Reached approximately (1212,156,-10232) with health 0.394 and isotope objective complete.
- A subsequent forward movement crossed active lasers and caused fatal damage near z=-10943. Normal results explicitly show **Failed / Deceased**, 4:30, 20 kills, 45.3% accuracy. Evidence: `work/evidence/investigation/laser-failed-results.png`. This supersedes earlier live-run continuation notes: the process remains running but the mission has ended. No Investigation unlock/save completion is claimed.
- Source inspection confirms Agent initializes the purple maintenance robot directly on its laser patrol (`func0412_purplebot_programs`, path10); terminal reprogramming is for higher difficulties. Next attempt must observe and follow its laser opening cycle with shorter movements, rather than cross active beams. No gameplay logic was changed to bypass the hazard.
- Only the existing simulator used. CamSpy objective and traversal evidence remain valid partial coverage; another normal mission attempt is required.

## Investigation normal retry underway

- Accepted Retry through the normal results menu in the same process. The new Agent attempt has cleared guard 0 and all four first-lab guards. Current health 0.890625; paused in Settings at approximately (-1143,157,-2293), heading 179.97. Both objectives are pending again; prior isotope completion belongs to the failed run.
- Shortened the starting route: from lift forward 25×50 ms, turn west, forward 60×50 ms reaches the first guard corridor directly. Collected CMP150 normally; later switched to Falcon 2 after ammunition depletion. One close-range hit during reload; no cheats or state edits.
- Keep PID 25917 for continuation. Next: reach z≈-2688, turn east toward isotope access, clear the two guards, and deploy CamSpy while Joanna remains outside the radiation area. Later, observe the maintenance robot before crossing active lasers. Current readback and notes under `work/evidence/investigation/`.

## Investigation retry: isotope complete

- Cleared both isotope-access guards and completed the CamSpy holograph objective again in the live normal retry. Screenshot `work/evidence/investigation/retry-isotope-completed.png` visibly confirms Objective 1 Completed. Exited camera and returned west; paused at approximately (428,157,-2739), heading 89.97, health 0.84375. Dr. Caroll remains pending.
- First deployment did not remain active: a subsequent movement went to Joanna, caught on screenshot, and she was withdrawn. Re-selected CamSpy and verified its HUD before flight. This is a test-sequencing risk to investigate; do not assume successful activation from a menu tap alone. The second flight/shutter completed normally with no further health loss.
- Preserve PID 25917. Same simulator, no install or state mutation. Private current readback and route notes updated. Continue west through the Caution door, then south through Sector Two; laser timing remains unverified.

## Investigation retry: Sector Two cleared

- Continued the normal retry through Sector Two, clearing guards 14, 13, 16, 15, 12, 17, 18, 19 and 20. Normal movement, weapon fire, ammunition collection and reload; no game-state edits. Isotope remains complete.
- Reached Sector Three entrance with health 0.65625, position approximately (315,157,-8444), heading 269.97. Paused in Settings; preserve PID 25917. This is stronger health margin than the previous attempt at the same point, but mission completion and the laser crossing remain unverified.
- Current private readback and route notes updated. Next clear guards 21–24, approach the lasers, and inspect the robot/opening cycle before crossing. Only the existing simulator used.

## Investigation retry: laser timing failure verified

- Cleared Sector Three guards 21–24 without additional damage and reached laser approach at health 0.65625. The normal retry subsequently failed at the first barrier; results show Failed / Deceased, 3:52, 20 kills, 47.4% accuracy (`work/evidence/investigation/retry-laser-failed.png`). Earlier alive-position notes are superseded. Process remains running at results, paused by native Settings.
- Added private read-only LLDB inspection of tagged doors and maintenance robot. First barrier z=-10975.5 was open while Joanna stood at z=-10636; robot was already at z=-11478, opening the second barrier. During the next movement it advanced to z=-11977 and the first barrier closed. Fatal contact occurred at z=-10943. This is timing failure, not proof of a port defect; no gameplay logic changed.
- Next normal attempt must stop close to the first barrier (before z=-10900), wait for the robot to return, and cross promptly during that local opening. A distant snapshot of an open door does not guarantee safe arrival. Inspect all three barrier groups at z=-10975.5/-11598.5/-12529.5. Diagnostic `lasers.py`/`lasers.json` remain private; reads only, no state mutation.
- Investigation completion remains open. Same single simulator; no save or installation replacement.

## CamSpy launch clearance verified

- Compared two launches from the initial Investigation lift using identical Inventory selection and BACK inputs. Facing the nearby west wall, the game displayed its insufficient-room message; read-only engine inspection showed held=1, active=0, deployed=0. Turning south toward the open corridor allowed launch: held=0, active=1, deployed=1, with the CamSpy HUD visible. No input or gameplay code change was warranted by this test.
- Source `bondeyespy.c::eyespyTryLaunch` tests clearance at a launch point 100 units ahead and rejects obstructed launches. This reproduces a plausible cause of the earlier isotope doorway incident, without proving that incident's exact cause. Updated the control documentation to require clearance and visual activation confirmation.
- WHEEL subsequently returned to Joanna (active=0, deployed=1) without moving her. New normal retry remains paused in native Settings at the initial lift, facing south, PID 25917. Private evidence: `camspy-clearance-rejected.png`, `camspy-clearance-launched.png` under `work/evidence/investigation/`. Same single simulator; no save edits or build/install changes.


## Investigation post-clearance retry: lab traversed

- Continued the normal run after the CamSpy clearance comparison. Cleared guard 0 and lab guards 3, 4 and 5; guard 6 remains alive behind Joanna. The display cases obstructed both shots and westward movement, requiring a route around their north end. No input/gameplay patch was made for these ordinary collision constraints.
- Traversed the lab exit door and reached approximately (-1140,157,-2488), heading 179.97, health 0.625. Both objectives are pending in this new attempt. Paused in native Settings, same PID 25917 and single dedicated simulator; preserve the live run.
- Next approach z≈-2740, turn east through the Caution doors, clear isotope-access guards and verify CamSpy HUD before flight. Laser crossings remain unverified. Read-only diagnostics and ordinary touch inputs only; no save or player-state edits.

## Investigation post-clearance retry: isotope completed

- Cleared isotope-access guards 41/42 and the pursuing lab guard 6. Verified CamSpy active before movement, flew into the chamber and completed the isotope holograph objective; screenshot `work/evidence/investigation/post-clearance-isotope-completed.png` visibly confirms completion. Joanna stayed outside the chamber at (1594,159,-2788); health remained 0.502467 through camera flight and withdrawal.
- Returned west through the Caution doors and south to Sector Two. Selected the collected CMP150 through Inventory and cleared guard 14 at the access door. Current paused position approximately (-512,159,-3872), heading 172.77, pitch -8.4, same health. Dr. Caroll and mission completion remain pending.
- Preserve live PID 25917 and current installation. Same single simulator, ordinary touch actions and read-only diagnostics; no player-state/save edits. Next advance into Sector Two, clear remaining guards, then wait close to each laser barrier for its local opening.

## Investigation: all three laser barriers crossed

- Continued the same normal Agent retry through Sectors Two and Three. Cleared guards 12/13/15–24 and reached the laser approach with health 0.39399007; isotope objective remains complete.
- Successfully crossed all three laser planes without health loss. Stopped at z=-10779 before the first, waited for the robot's return and local opening, then crossed to -11126. Stopped at -11388 before the second, waited for the next outbound robot pass, then crossed to -11760. Advanced to -12278 while the third opened and crossed to -12739. Read-only tagged-door/robot inspections confirmed timing; no gameplay changes or state edits.
- This resolves the earlier test execution failure to traverse the lasers. Current Joanna position approximately (1195,157,-12739), heading 179.97, health unchanged at 0.39399007, paused in native Settings. Guard 25 is ahead around (1464,105,-13693). Dr. Caroll and mission completion still pending. Preserve PID 25917 and installation. Same single simulator.
- Private evidence: `work/evidence/investigation/three-lasers-crossed.png`, `live-at-pause.json`, `lasers.json`. Earlier failed attempts remain recorded separately and are not completion evidence.

## Investigation: Data Uplink door unlocked and traversed

- Continued beyond the lasers through the lounge and offset access doors. Cleared guards 25, 26, 28, 29 and finally pursuing guard 27. Health fell to 0.11845687 during these encounters; isotope objective remains complete. No health or gameplay-state edits.
- The security door at approximately (2309,161,-16945) correctly reported locked. Source inspection identified the normal Data Uplink terminal, tag 0x0a at (2314,138,-16696). First connection was interrupted by enemy fire pushing Joanna out of range. After clearing the guard, selected Data Uplink through Inventory, used the terminal and remained nearby; the game displayed “Password located”. Ordinary USE then opened the previously locked door, and Joanna crossed into the descending passage.
- Test correction: Inventory scroll position changes visible row coordinates. An attempted weapon selection initially left Data Uplink equipped; later inspected the current menu and confirmed the weapon before firing. This was test sequencing, not evidence of an input defect. Future menu actions must use the current layout.
- Current paused position approximately (2864,99,-17094), heading 249.87, health 0.11845687. Data Uplink is still equipped; select a weapon before further combat. Dr. Caroll and mission completion remain pending. Preserve PID 25917. Same single simulator. Private screenshot `work/evidence/investigation/uplink-password-found.png` and readback retained.

## Investigation / Agent completed and save reloaded

- Completed the normal Investigation run, including isotope holograph, Data Uplink door, all three robot-controlled laser crossings and locating Dr. Caroll. The final cutscene visibly reported Objective 2 Completed, followed by the Extraction next-mission briefing. No health, ammunition, position, objective or save mutations; diagnostic-guided touch input and read-only LLDB inspection only.
- Traversed the lower labs and cleared guards 30–32. The final corridor caused minor damage; reached Dr. Caroll alive with health 0.0872068703. The central lab partition required retreating to z≈-20644, crossing east to x≈6163, then heading south to its exit. Earlier failed attempts remain separate history.
- Backed up EEPROM/multiplayer setup, fully terminated the app and launched a new process (PID 74642). Loaded existing Dark agent through normal menus: Investigation has its Agent completion star and **10m:06s** best time; **Extraction is unlocked**. Multiplayer setup hash is unchanged; EEPROM bytes changed after loading/navigating the agent, so byte-for-byte EEPROM preservation is not claimed. The visible time and unlock establish persisted mission progression. This is progression evidence, not physical touch usability or full-campaign acceptance.
- Private evidence under `work/evidence/investigation/`: `drcaroll-objective-completed.png`, `extraction-next-mission.png`, `reloaded-extraction-unlock.png`, `reloaded-investigation-time.png`, and `completed-save/`. Current app is at Investigation difficulty selection after reload, no live mission. PID 25917 is no longer active. Same single dedicated simulator; no rebuild/install required.
- Next campaign coverage starts with Extraction; physical device, controller, graphics-pack memory/performance and later networking gates remain open.

## Extraction opening coverage

- Launched Extraction / Agent through the normally unlocked mission menu. Briefing lists foyer elevator, Cassandra’s bodyguards and helipad objectives. Activated Night Vision through the touch Inventory; the dark scene becomes visibly green and readable. Exercised movement, USE, pistol firing and reload; guard 1 is defeated. Mission completion remains pending.
- Current live run is paused by native Settings, PID 74642, health 0.8125, position approximately (-1707,-8442,964), heading 359.89. Dr. Caroll follows normally. The east-facing room at x≈-1278 is a dead end; the route leaves west to x≈-1707, then north through z=221 and z=667. Read-only room/portal inspection guided navigation; no game-state mutations.
- Private evidence: `work/evidence/extraction/opening-checkpoint.json`, room/portal snapshots and Night Vision screenshot. Only the dedicated simulator is booted. Continue the opening foyer route from this paused session.

## Goldenpad menu presentation correction

- User review identified that the native Utilities table did not look like Goldenpad. Direct comparison against `RecompPrototypeApp.swift` confirmed the earlier implementation copied the action concept but missed its compact overlay presentation.
- Replaced the full-screen Utilities table/navigation bar with a 280-point translucent rounded panel below the ellipsis. Goldenpad-derived spacing, 48-point minimum action rows, SF Symbols, material, border/shadow and outside-tap dismissal are implemented independently in UIKit. Ellipsis now matches its white bold symbol, 62% black fill and fine white border. Keeps Darkpad’s separate game START and truthful End Mission or Match / Diagnostics actions.
- Simulator and unsigned device builds PASS (`app-compact-menu-build.log`, `app-compact-menu-device-build.log`). Native UI checks passed: menu appearance, Settings navigation and Done, outside dismissal, direct touch editor, exit confirmation and cancel. Pause/readback confirms menu and editor pause the engine, outside dismissal resumes, and held inputs are zero. Screenshot: `work/evidence/darkpad-compact-menu.png`.
- Backed up Documents/Library before install; ROM, EEPROM and multiplayer setup hashes all preserved across installation. Same single simulator, current process 83526. Extraction attempt ended before this install: Dr. Caroll died and the helipad objective visibly FAILED, so it does not count as completed coverage. Prior Defection/Investigation saved completion remains preserved. Continue campaign with a fresh Extraction attempt after menu work.

## Settings organization follows the Goldenpad reference

- Reorganized the native form around Graphics, Touch Controls, Controller and Motion Aiming, followed by Audio and optional asset sections. Previously controller and gyro rows were mixed with touch sensitivity under Aiming. All existing settings keys, values and actions are retained; the title is now Settings.
- Corrected inherited art help that referred to a removed Xbox switch. Graphics now explains the three art profiles and restart requirement for resolution; asset imports point to Graphics → Art profile. Added concise touch and controller help.
- Simulator and unsigned device builds PASS (`app-settings-groups-build.log`, `app-settings-groups-device-build.log`). Native inspection verified Graphics first, Touch Controls values, separate Controller/Motion Aiming sections, and the controller preset confirmation/cancel from its new location. No controller binding changes made.
- Backed up Documents/Library before updating the same simulator. ROM, EEPROM and multiplayer setup hashes preserved. Current PID 84504, native Settings open, no active campaign attempt. The previous goal turn made implementation and runtime-verification progress; full P1/P2 acceptance remains pending.

## Tablet menu layout and centered Settings

- Shut down Darkpad P0 iPhone before creating/booting the dedicated Darkpad UI iPad (11-inch M5 simulator, iOS 26.5), `9482A2EA-45E6-4E19-A76D-CC5F511609FD`. Only that simulator is currently booted. Phone campaign saves/container remain separate and untouched.
- Native iPad inspection confirmed the compact popover fits. Settings was still stretched across the tablet, unlike the Goldenpad form. Added a containing native host that centers tablet Settings at up to 680×760 points with rounded corners and a dimmed game background; utility overlays retain full-window bounds. Phone Settings stays full-window by design.
- Simulator/device builds PASS (`app-ipad-settings-build.log`, `app-ipad-settings-device-build.log`). iPad native checks passed for centered form, Done dismissal, reopening the correctly anchored popover and returning to Settings. Evidence under `work/evidence/ipad-menu/`. Backed up iPad Documents/Library before installation; EEPROM and ROM hashes match afterward. No existing phone saves copied into this new test container.
- Current iPad process 85731, Settings open. Phone is shutdown and still has the previous installed build; verify the host-container change on phone after shutting down iPad. This is simulator layout evidence, not physical M2 iPad qualification.

## Phone regression after tablet Settings host change

- Shut down the iPad before booting the dedicated iPhone; only one simulator ran at a time. Installed the latest host-container build after backing up Documents/Library under `work/evidence/before-menu-host-phone/`. ROM, EEPROM and multiplayer setup hashes matched immediately after installation.
- Native phone Settings remains full-width in landscape. Done dismisses it and releases native pause/focus with no held inputs. Loaded the existing Dark agent through ordinary game menus: Investigation retains its Agent star and **10m:06s** best time, and Extraction remains unlocked. Evidence: `work/evidence/phone-menu-host/`. No save or gameplay-state edits.
- Current iPhone process 86659, at Investigation difficulty selection, no active mission. iPad is shut down. The Goldenpad presentation correction and phone/tablet regression checks are complete; full campaign, physical-device qualification and remaining P1/P2 gates remain open.

## Challenge 1 completion and reload; visual issue found

- Previous goal turn made progress by verifying phone menu regression and persisted campaign progression. Continued with normal Combat Simulator Challenge 1, loaded existing Player 18, and completed the five-minute match: game reports **Challenge Completed**, Red 1 / Yellow -1. Fully terminated PID 86659 and relaunched PID 90576; normal menus show Challenge 1's illuminated one-player star. Evidence and private Documents/Library backup under `work/evidence/challenge-one/`. Only the dedicated iPhone simulator was booted.
- Exercised movement, weapon pickup, SWAP, sniper firing/reload, death and START respawn through ordinary touch commands. Read-only LLDB guided navigation; no health/ammo/objective/save edits. The weapon was a Sniper Rifle (HUD-confirmed), not the initially misidentified Magnum. This is scripted simulator progression evidence, not human usability or comprehensive challenge acceptance.
- **Open visual defect:** after respawn near (-2802,-642,-1956), turning north and moving toward (-2876,-585,404) produced a black world with radar/HUD still rendered. Later readback at (-2872,-582,405) showed health 0.75, so this cannot be dismissed as the death fade. Result/menu rendering and restart worked. Preserve screenshot `black-scene-live.png`; reproduce the Skedar lower-area traversal and compare render/camera/room state before changing code. Challenge completion does not waive this visual issue.
- Current process 90576 at Combat Challenges list after reload, no active match. Next action is the black-scene investigation; full campaign, physical acceptance and P2 remain incomplete.

## Skedar black-view investigation: authored dark alcove

- Previous goal turn made progress: Challenge 1 completed and its star survived restart, but a black view required investigation. Reproduced that view in a fresh Challenge 1 run **without any death or respawn**, using normal touch traversal through rooms 60→61→31→2→25→26→27→28. Only the same iPhone simulator ran.
- At (-2927,-639,353), heading ~0, room 28 renders nearly black. Read-only state: health 1, isdead 0, camera/vision mode normal, fade opacity 0. Turning 180 degrees immediately shows the lit corridor and bot; retreating and looking north shows the dark end surfaces and lit floor. This rules out the proposed stuck respawn fade and does not support a renderer-wide blackout.
- Room 28 is a dead-end alcove with one portal to room 27. Runtime source and adjusted color tables are identical: RGB 0,27,67,254, all alpha 255. Brightness multiplier is 1, settled regional brightness 255. All seven vertices at local z=400 (world z=550 end) reference black color offset 0; additional end geometry also uses black. Evidence supports authored dark geometry, so no speculative rendering/lighting patch was made. The prior “open visual defect” classification is superseded by this narrower finding; broader visual-profile qualification remains pending.
- Evidence: `work/evidence/challenge-one/room28-{north-black,south-lit,retreated-north}.png`, `black-room28.json`, `room28-full.log`, `room28-colours.log`, `vertices.json`, and room/portal snapshots. Current process 90576 remains in the second Challenge 1 run, paused in native Settings near room 28 facing north. Preserve the live installation; completion evidence belongs to the previous run. Next resume ordinary gameplay/campaign coverage or qualify remaining independent P1 behavior.

## Bot-match native Settings pause and lock regression

- Previous goal turn made progress by reproducing and explaining the Skedar dark alcove. This turn verified actual simulation pause during the still-live second Challenge 1 run, rather than relying only on the shell's pause flag.
- With native Settings open, two separated read-only LLDB samples both report `g_Vars.lvframe60=3236`, `lvupdate240=0`. Used Simulator Device→Lock and confirmed the lock-screen accessibility tree; presentation then reports 0, held touch mask/stick remain zero, and the simulation stays at frame 3236. The initial Sleep/Wake toolbar click did not visibly lock, so only the subsequently confirmed Device→Lock action counts as lock evidence.
- Home twice returns to Settings, with presentation restored but the game clock still at 3236 and pause=1. Native Done releases pause (0), Settings page=0, inputs zero; the clock advances to 3981 before reopening Settings to preserve the live run. No app rebuild, save edit, or gameplay-state mutation. Logs: `work/evidence/challenge-one/pause-{before,after,locked-confirmed,unlocked,resumed}.log`.
- Same single iPhone simulator and PID 90576; native Settings is open in the active second Challenge 1 run. This extends lifecycle evidence to bot matches and the revised menu host. Physical locks/calls, sustained hardware performance, controller mission completion and full campaign coverage remain unverified. Continue campaign coverage from the existing Extraction unlock after normally ending this diagnostic match.

## Next work

Dedicated simulator: **Darkpad P0 iPhone**, `D8BB419F-91F4-4919-9247-B7985F581ECA`, iPhone 17 Pro / iOS 26.5. Reuse this target; never boot another concurrently. Current container is recorded in ignored `work/evidence/sim-current-container.txt` and must be re-resolved after installs.

- Eight-bot simulator smoke PASS: 2,000 seeded frames, exit 0; log confirms 9 active character props (player + 8 bots). Frame 1,800 screenshot inspected and retained as `work/evidence/sim-eight-bots.png`. This earlier smoke is distinct from the later completed normal match. Dedicated simulator is currently booted.
- Early mission/save acceptance **PASS on the clean build**: normal `dataDyne Defection` completed on Agent in **3:31**, agent active, 15 kills. Evidence: `work/evidence/defection-clean-build-completed.png`. After full app termination/relaunch and loading the existing Dark agent, mission selection shows Investigation unlocked and Defection's Agent best time **3m:31s** (`defection-clean-build-reloaded-unlock.png`, `defection-clean-build-reloaded-time.png`). Private save backup and hashes: `work/evidence/mission-completed-save/`.
- This was diagnostic-guided scripted touch progression: read-only LLDB inspection guided aiming/navigation, with no health, objective, position, cheat or save mutation. It verifies normal mission completion and persisted progression, **not human touch usability**. Several earlier attempts failed; the successful route cleared lobby guards, collected ammunition and crossed the concealed opening before activating the final lift. Detailed private route notes are under `work/evidence/mission-probe/`. Only the dedicated simulator was booted throughout. Full campaign and physical-device acceptance remain outstanding.
- Fixed first-run status-bar overlap: the iOS ANGLE window is explicitly borderless before creating its Metal view, so SDL hides the bar even after onboarding. Reproduced the missing-ROM → onboarding → restored-ROM transition on the dedicated simulator and verified the saved-agent menu and Utilities resume remain free of the status bar (`work/evidence/onboarding-statusbar-fixed.png`). Simulator/device engine and app builds pass (`engine-statusbar-*.log`, `app-statusbar*-build.log`). Existing save/config bytes matched across installation; ROM restored. Default control overlap with the display cutout is fixed on the tested iPhone; validate other sizes during control/layout work.
- First-run onboarding now focuses on the required Perfect Dark ROM with one explicit import action and a short Files alternative. Optional art/conversion import remains in Settings. Removed onboarding-only package scanning. Simulator screenshot `work/evidence/onboarding-focused-import.png` confirms the landscape screen fits without scrolling; restoring the ROM automatically reaches the existing saved-agent menu. Simulator/device build logs: `app-onboarding-focus-build.log`, `app-device-onboarding-focus-build.log`. Existing save/config bytes matched across installation; private backup in `work/evidence/before-onboarding-focus/`. Stock-ROM content validation is now enforced; see the later validation entry.
- Goldenpad controller preset and confirmed utility exit are implemented and simulator-verified. Continue PD reload/secondary fire/gadgets/CamSpy coverage and physical hot-plug/layout/lifecycle checks. Art profiles are implemented; qualify optional pack memory/performance on hardware. Gyro trial is implemented but stays experimental until physical testing.
- P2 networking follows P1 acceptance; do not update engine prematurely. No physical target currently connected.

## Goldenpad utility placement correction

- User prioritized the misplaced Back arrow. Direct comparison with downloaded Goldenpad `52bb67328c2cc4b98b4242ba0539985bd61fc2d3`, `Sources/RecompPrototypeApp.swift` (utilityMenuX, button y=48, trailing panel) confirmed our previous left-side ellipsis was incorrect. The compact styling alone did not satisfy the reference.
- Ellipsis now stays upper-right at y=48 with landscape safe-area protection; panel shares the same anchor and opens beneath it. Default game START sits below ellipsis; game BACK moves to the leading edge. Existing custom gameplay placements remain preserved.
- Simulator and unsigned device app builds PASS: `work/evidence/menu-right-{simulator,device}.log`. Installed and visually inspected on the sole booted iPhone simulator; native ellipsis opens the trailing panel and outside dismissal resumes. Evidence: `work/evidence/menu-right-verified.png`. iPad placement has not yet been rechecked after this correction.
- Install backup: `work/evidence/before-menu-right/`. All Documents and Library hashes matched except four OS-managed SplashBoard launch snapshots; ROM, saves and preferences unchanged. Current container recorded in `work/evidence/sim-current-container.txt`.
- Prior in-progress end-session patch allows dead players in live Combat Simulator matches to end normally; builds pass but dead-state regression remains unverified, so it remains uncommitted separately. A saved preset named “8bots” loaded with zero bots in the latest inspection; investigate before claiming saved bot configuration acceptance. The earlier completed match and seeded eight-bot smoke remain separate valid evidence.

## iPad trailing-menu regression and editor accessibility

- Previous turn was progress: corrected Goldenpad menu placement. Shut down the phone before booting the sole iPad simulator, then installed the correction. iPad landscape visual inspection confirms upper-right ellipsis, panel beneath it, centered Settings, Done dismissal, and touch-editor entry/exit. Screenshot: `work/evidence/ipad-menu/right-anchor.png`.
- Found editor AX names “undo” and “selected” were misleading. Added explicit Reset touch layout, Done editing touch controls and Touch control size labels; slider now announces its percentage. Simulator/device builds pass (`editor-labels-{build,device}.log`). Reinstalled and inspected actual AX tree: all corrected labels appear and size reads 100%; Done works. No layout changes made during verification.
- Both installs preserved all Documents/Library file hashes excluding OS-managed SplashBoard snapshots; backups `before-menu-right-ipad/` and `before-editor-labels/`. Current sole simulator: iPad `9482A2EA-45E6-4E19-A76D-CC5F511609FD`, process 2555, editor dismissed. Phone remains shutdown. Physical tablet usability, full campaign and P1/P2 gates remain incomplete.

## Saved bot setup evidence audit

- Previous turn made progress through iPad UI validation and accessibility fixes. Investigated the empty “8bots” reload using the actual serializer and read-only parsing of saved files. Version 1 has a three-byte header and 80-byte blocks; setup name uses 18 bytes, followed by count/stage/scenario/scenario-data/options, then eight 25-bit bot records. BOTDIFF_DISABLED is 6.
- All 26 available private backups have the identical SHA-256 and contain stored count 0 with every bot difficulty 6. This includes `sim-before-clean-build/Documents/mpsetups.bin`, so recent installation/menu changes did not remove the bots. Audit output: `work/evidence/saved-bot-audit.json`. The current saved file cannot establish whether the original save workflow was incorrect or serialization had an earlier defect. No engine fix is justified yet.
- Corrected the early acceptance entry to distinguish completed eight-bot match/player-stat persistence from unverified bot configuration persistence. Next: create a separately named setup through normal menus, verify eight enabled bots immediately before saving, inspect the written file, terminate/relaunch, and check the loaded composition and match. Do not overwrite the existing misleading preset as a workaround.
- Sole running simulator remains iPad, process 2555, now at agent selection with no saved agent; its development-only controller override is off to expose touch controls. Phone remains shutdown with existing campaign/player saves. Use phone for the next saved-setup test after shutting down iPad.

## Eight-bot setup reload and dead-player utility exit verified

- Previous turn made progress by correcting the saved-setup evidence. Shut down iPad before booting phone; only phone ran throughout. Normal UI added one NormalSim and copied it seven times; screenshot `work/evidence/bot-save-recheck/before-save.png` shows NormalSim1–8. Saved a separate setup named **8sim**, preserving existing **8bots**.
- Read-only decoding of the written version-1 save proves 8sim has stored count 8 and eight difficulty=2 (Normal) records. Existing 8bots remains count 0/difficulty=6. Private `mpsetups.bin` and `decoded.json` retained in the same evidence directory. No save-byte or gameplay-state edits.
- Fully terminated PID 3669, relaunched PID 4080, loaded Dark then 8sim via normal menus. Read-only LLDB confirms setup name 8sim, first eight g_MpSimSlots enabled, checked endpoint difficulties Normal. Started a non-spectator match: g_MpNumChrs=9, g_BotCount=8, normmplayerisrunning=1. Logs `reloaded-roster.log` and `started-match.log`. This closes the representative eight-bot setup save/reload gap; the old empty preset was not proof of a current serializer defect.
- Player died naturally in the loaded match. Opened utility menu; read-only pre-action sample confirms isdead=2, normmplayerisrunning=1, g_MainIsEndscreen=0. Confirmed End Session; post-action g_MainIsEndscreen=1, aborted=1. Declined creating an extra Player 1 profile; normal Game Over displayed. Evidence `dead-{before,after}-exit.log`, `dead-exit-results.png`. This validates the pending patch permitting a dead Combat Simulator player to end a still-live match.
- Patch overlay and simulator/device engine/app builds already passed (`end-dead-*` logs); latest UI builds also pass. Committing the previously pending end-session guard now that its exact regression is verified. Phone PID 4080 remains at Game Over; iPad shutdown. Full campaign, physical performance/controller/gyro acceptance and P2 remain open.
