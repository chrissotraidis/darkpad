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

- **Source/build:** PASS baseline Mac, ARM64 simulator and unsigned iOS device apps. Local SDL2/curl/ANGLE recipes require no sibling checkout. `scripts/bootstrap-apple.sh` assembles the proven steps; whole-command empty-cache rerun still not performed. No broad engine optimization changes.
- **Package/install:** simulator installed; native Files picker imported the supplied ROM; missing-ROM UI works. Updated installation preserved EEPROM and ROM. Device package built but not installed/signed.
- **Physical gameplay:** NOT RUN — `devicectl list devices` found no connected devices. Simulator reached actual dataDyne Defection via saved agent/mission menus; firing and sustained movement work. No completed mission or complete campaign coverage yet.
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
- Normal simulator flow: loaded saved agent Dark, configured Skedar / Pistols / eight Normal Sims / one-minute limit, saved setup **8bots**, started a non-spectator game, moved with touch, and reached Game Over naturally. Rankings include NormalSim8 and scoring bots. Saved player **Player18**, quit/relaunched, loaded **8bots** and **Player18** through the menus. Reloaded statistics show Games Played 1, Time 0:00.57, Pain Received 0.6. This verifies a completed short match and persistence, not combat usability or a campaign mission. Evidence: `sim-normal-match-{game-over,ranking}.png`, `sim-player18-reloaded-stats.png`.
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

## Next work

Dedicated simulator: **Darkpad P0 iPhone**, `D8BB419F-91F4-4919-9247-B7985F581ECA`, iPhone 17 Pro / iOS 26.5. Reuse this target; never boot another concurrently. Current container is recorded in ignored `work/evidence/sim-current-container.txt` and must be re-resolved after installs.

- Eight-bot simulator smoke PASS: 2,000 seeded frames, exit 0; log confirms 9 active character props (player + 8 bots). Frame 1,800 screenshot inspected and retained as `work/evidence/sim-eight-bots.png`. This earlier smoke is distinct from the later completed normal match. Dedicated simulator is currently booted.
- Early mission/save acceptance **PASS on the clean build**: normal `dataDyne Defection` completed on Agent in **3:31**, agent active, 15 kills. Evidence: `work/evidence/defection-clean-build-completed.png`. After full app termination/relaunch and loading the existing Dark agent, mission selection shows Investigation unlocked and Defection's Agent best time **3m:31s** (`defection-clean-build-reloaded-unlock.png`, `defection-clean-build-reloaded-time.png`). Private save backup and hashes: `work/evidence/mission-completed-save/`.
- This was diagnostic-guided scripted touch progression: read-only LLDB inspection guided aiming/navigation, with no health, objective, position, cheat or save mutation. It verifies normal mission completion and persisted progression, **not human touch usability**. Several earlier attempts failed; the successful route cleared lobby guards, collected ammunition and crossed the concealed opening before activating the final lift. Detailed private route notes are under `work/evidence/mission-probe/`. Only the dedicated simulator was booted throughout. Full campaign and physical-device acceptance remain outstanding.
- First-run-only status bar overlapped gameplay after onboarding; absent on subsequent relaunch. Default control overlap with the display cutout is fixed on the tested iPhone; validate other sizes during control/layout work.
- First-run onboarding now focuses on the required Perfect Dark ROM with one explicit import action and a short Files alternative. Optional art/conversion import remains in Settings. Removed onboarding-only package scanning. Simulator screenshot `work/evidence/onboarding-focused-import.png` confirms the landscape screen fits without scrolling; restoring the ROM automatically reaches the existing saved-agent menu. Simulator/device build logs: `app-onboarding-focus-build.log`, `app-device-onboarding-focus-build.log`. Existing save/config bytes matched across installation; private backup in `work/evidence/before-onboarding-focus/`. Modified-header-matching ROM compatibility remains inherited and needs reconciliation with strict stock-ROM validation requirements.
- Finish Goldenpad semantic control layout and utility exit/save handling, retain PD reload/secondary fire/gadgets/CamSpy, test hot-plug/layout/lifecycle. Art profiles are implemented; qualify optional pack memory/performance on hardware. Gyro trial is implemented but stays experimental until physical testing.
- P2 networking follows P1 acceptance; do not update engine prematurely. No physical target currently connected.
