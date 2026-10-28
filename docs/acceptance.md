# Acceptance evidence and remaining gates

This is an index of evidence, not a declaration of release readiness. The requirements remain in [goal.md](goal.md) and [prd.md](prd.md). Private logs, screenshots, ROMs and saves stay under ignored `work/`; they are not distributed with source.

## Current release candidate: 0.1.0 / Dab's Mod v3.15.1

This section supersedes the older engine and candidate status below. DarkPad is
being prepared for its first public preview; it has not been published.

| Area | Verified evidence | Still open |
|---|---|---|
| Engine and builds | Pin `a8c2ab2d7b1c99f6a96a2d9addee1fdf9630e379`; 73 patches applied without fuzz or offsets. Simulator, device Release and native Mac reference built on October 25. | Broader device/OS coverage. |
| PadMint | October 28: Apple Python 3.9.6 / empty PadMint-folder check passed on `c13d20d` with PadMint main `7e4c44c` (0.5.22), 855 seconds, 11.1 MB personal IPA. Evidence is indexed in `PROGRESS.md`. | Post-publication build from the released recipe. |
| Physical iPad | Current engine installed and launched on iPad Pro with 2,911 non-runtime save/settings/content files unchanged; approximately 119.9 Hz measured pacing at launch. Previous-engine Xbox-controller play was accepted by the owner. | Hands-on current-engine mission, GoldenEye and controller-navigation acceptance; launch pacing is not gameplay acceptance. |
| Simulator gameplay | Saved agent loads; Carrington Institute movement, GE Plus Dam and bot matches run. Game clock and walking speed compared at 60/120 Hz. | Full campaign, physical iPhone touch play, hardware timing, thermal and battery behavior. |
| Network | Current protocol 33 hosts/joins desktop Dab's Mod; touch look applied by the host; two Simulator instances joined a lobby. | Real-device Wi-Fi, internet lobbies, completed co-op and broad recovery testing. Ordinary builds omit the multicast entitlement; use Direct Connect. |
| Optional content | HD pack checks and brief US GoldenEye ROM conversion/Dam play on Simulator. | Xbox 360 art, Goldfinger 64 and TND64 with their optional files. |

The [release checklist](RELEASE-CHECKLIST.md) separates preparation from
publication and the mandatory post-publication player check. Private evidence
stays under ignored `work/`.

## Historical evidence through October 22

The notes below describe the older solo engine and retired network candidate.
Their revision pins, simulator-only scope and remaining-work statements are
historical; use the current table above for release claims.

### Earlier status

P0 has an empty-project-cache build on this Mac. P1 is incomplete. P2 has not been accepted and must retain the working solo baseline. The user explicitly requested simulator-only testing on 2026-10-20. Physical tests listed below are unverified limitations, not requests for hardware or blockers to continued work. Only one simulator may be booted at a time.

| Requirement | Evidence and scope | Remaining work |
| --- | --- | --- |
| Reproducible foundation | `work/evidence/clean-bootstrap-dc53fa0.log`: complete bootstrap from an isolated checkout with no project dependency cache, ending in successful app builds. Host developer-tool caches remained present. | This is not a second-Mac reproduction. |
| Current overlay reproducibility | Solo pin `90c8622e`: 57/57 patches, identity `c243acc9c4b14f34`, audit `work/upstream-audit.QGrUaH`. Isolated network candidate `3ee8ed0c`: 67/67, identity `ed9e6415e5fcec30`, audit `work/network-visible-notice-audit.log`. Solo simulator and unsigned device Release builds pass; network simulator and matching Mac builds pass. | Recheck after engine/patch changes; simulator evidence does not qualify device performance. |
| Early mission and save reload | Defection Agent completed in 3:31 on the clean-built app; screenshots `defection-clean-build-completed.png`, `defection-clean-build-reloaded-time.png`, `defection-clean-build-reloaded-unlock.png` under `work/evidence/`. | Does not establish full campaign or physical touch usability. |
| Second mission and save reload | Investigation Agent completion and full-process-restart time 10:06 / Extraction unlock: `work/evidence/investigation/{drcaroll-objective-completed,reloaded-investigation-time,reloaded-extraction-unlock}.png`. | Extraction and subsequent campaign missions remain incomplete. |
| Bots and challenges | Challenge 1 completed and one-player star reloaded (`work/evidence/challenge-one/`). `8sim` stores eight Normal bots and reloads into a nine-character match (`work/evidence/bot-save-recheck/`). | Wider scenarios and physical performance. The older `8bots` preset is empty and is not evidence. |
| Goldenpad UI and controls | Reference revision and adaptation in [goldenpad-reference.md](goldenpad-reference.md). Phone/tablet menu and layout checks in `PROGRESS.md`; per-control style, persistence/reset, firing, reload, secondary function and wheel hold/release tested. | Physical continuous drags, deliberate wheel slice selection, complete controller mission, hot-plug and human usability. Simulator automation generally lacks continuous touch-move events; do not change app gesture semantics merely to accommodate it. |
| Gadgets | Night Vision toggle and resumed rendering checked. Investigation completion exercised required Holograph/Data Uplink/robot sequence; details in `PROGRESS.md`. | Wider gadgets/camera tools and physical controls. |
| Gyro | `tests/gyro_math.c`, `work/evidence/gyro-math-test.log`: cadence, orientation and invalid/stale-data integration checks pass. | Physical calibration, aiming feel and session testing; remains experimental. |
| Data and lifecycle | Latest solo installation checked 3,837 Documents/Library files: only four OS launch snapshots changed; saves and HD assets preserved (`work/solo-clipboard-preservation.json`). Preserved tablet Dark profile loads. Phone mission times/unlocks separately survived prior full relaunches. Lifecycle evidence is indexed in `PROGRESS.md`. | Broader long-session reliability; physical checks excluded by user. Do not combine tablet and phone saves into one progression record. |
| Graphics and optional artwork | PD Forever Plus HD v0.10 installed (3,811 images). Original/Enhanced switching visibly restores/replaces rooftop paving, skyline and signs (`work/evidence/hd-gameplay/`). Updated solo app renders the pack and selects it in Settings (`work/solo-clipboard-regression/hd-settings.png`); interior stairwell rendering also captured. Enhanced filter sanitizer checks pass. | Broader transparency/scopes/effects, level transitions and memory/quality checks. Xbox remaster assets remain unavailable; fallback is not remaster-art acceptance. |
| Phone qualification | Not run; no connected hardware. Simulator FPS is not phone performance evidence. | Exact device inventory and PRD 30-minute early/later mission plus bot session, frame intervals, memory, thermal behavior and profile selection. |
| LAN / co-op | Matching Mac plus one iPad simulator completed timed Combat matches, bot deaths/respawn and configured Pipes/Automatics match. UI host/join/results/stop and occupied-port recovery verified (`work/network-host-edgecases/`, `docs/network-integration.md`). Co-op Defection starts; corrected abort leaves both endpoint EEPROMs unchanged (`work/network-coop-save-check.c8lsxbk2/abort-save-comparison.json`). | Two completed co-op missions including gadget/objective case, successful-mission save isolation, further repeat-match coverage and controlled latency/loss. Host-loss acknowledgement and fresh-match rejoin now verified below. No physical cross-play acceptance. |

## Next useful checks

Continue campaign coverage using the verified keyboard-look fallback for simulator navigation: a 500 ms Right press changed yaw by 105 degrees (`work/evidence/keyboard-look/`). This does not replace physical touch acceptance. Preserve honest distinctions between ordinary UI play, diagnostic-driven input and human usability. Continue only with simulators as requested; do not infer hardware timing, thermal behavior or physical usability from them. Optional art can be tested independently with supplied or appropriately licensed assets, without delaying the original-ROM core.

Latest control redesign: compact Goldenpad-style labels/colors and clearer action grouping, with native Fire/Reload/Start/Back/menu checks on the phone simulator. Build and screenshots: `work/evidence/control-layout-redesign/`. Both installs preserved all 773 Documents/Library files excluding OS launch snapshots. Tablet editor/menu visual recheck passed after correcting Next/Alt leading-edge padding; see `ipad-editor.png` and `ipad-edge-build.log` in the same evidence directory.

Enhanced CPU texture filter: `tests/texture_upscale.py` covers dimensions/output budget, alpha-edge color, cropped padding and constant-color preservation. Overlay 0060 fixes pre-arithmetic dimension overflow. Subsequent rebuilt solo installation and HD rendering are verified above; older notes that those bundles awaited installation are superseded.

Latest tablet campaign attempt reached the interior stairwell but failed (Deceased,18:06). Evidence: `work/solo-clipboard-regression/interior-attempt-failed.png`. This adds interior rendering/door interaction coverage, not a completed mission. Phone Defection/Investigation remain the only recorded completed solo missions.

## Latest verified build and runtime evidence (22 October)

- Current solo simulator package: `build/deliverables/darkpad-simulator-accessibility-20261022/Darkpad-Simulator.zip`; CRC and manifest hashes passed. Simulator and unsigned device Release logs: `work/control-accessibility-build.log`, `work/control-accessibility-device.log`. Build delivery is complete, independently of remaining acceptance.
- Phone HD activation and full-process restart preserve settings/progression (`work/phone-hd-activation/`). In the same Extraction scene, Original→Enhanced visibly changes wall artwork while retaining night vision and scoped Falcon2 HUD (`work/hd-profile-roundtrip/`). This extends scope/effect coverage but does not prove broad performance or campaign completion.
- Latest phone installation compared 4,591 Documents/Library files, with only four OS launch snapshots changed (`work/phone-accessibility-backup.g3y7ywnx`). Named control accessibility semantics and cinematic Start/ellipsis-only chrome verified; full assistive gameplay and simultaneous touch remain unverified.
- Isolated network candidate mid-match host loss now displays a readable reason until OK (`work/network-visible-notice-check.v5eaomkz/visible-reason.png`). The same client process then joined a newly launched matching local Mac host and entered gameplay without restart (`work/network-visible-notice-check.83hjhcgw/rejoined-active.png`, `host.log`). This is restart/rejoin recovery, not seamless resumption of the lost match. Only one iPad simulator was booted; no physical cross-play claim.

- Controlled network impairment: one-minute/four-bot candidate match completed with50ms added delay each direction and deterministic2% datagram loss; input, death/respawn, results and normal disconnect verified. `work/network-impaired-match.tuwmd9gr/` contains screenshots and measured forwarding counts/delays. See [network integration](network-integration.md) for exact scope; broader loss/latency tolerance remains unqualified.

- Co-op save unit coverage: `tests/network_coop_results.py` exercises actual result functions with success/death/abort/incomplete objectives for both slots and host/client/offline modes. Sanitizers pass; mutations removing either completion isolation or save-write isolation fail. This strengthens code-level coverage of0068 but does not replace played successful co-op missions or endpoint save comparisons.
