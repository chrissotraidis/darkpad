# Acceptance evidence and remaining gates

This is an index of evidence, not a declaration of release readiness. The requirements remain in [goal.md](goal.md) and [prd.md](prd.md). Private logs, screenshots, ROMs and saves stay under ignored `work/`; they are not distributed with source.

## Current status

P0 has an empty-project-cache build on this Mac. P1 is incomplete. P2 has not been accepted and must retain the working solo baseline. No physical device was found by `xcrun devicectl list devices` at this review. Only the dedicated phone simulator is booted.

| Requirement | Evidence and scope | Remaining work |
| --- | --- | --- |
| Reproducible foundation | `work/evidence/clean-bootstrap-dc53fa0.log`: complete bootstrap from an isolated checkout with no project dependency cache, ending in successful app builds. Host developer-tool caches remained present. | This is not a second-Mac reproduction. |
| Current overlay reproducibility | `work/evidence/overlay-current/apply.log`: all 53 patches applied with zero fuzz to engine `90c8622e74b35be669d60d177effc6d7d2d7621c`. Recursive comparison with the current build source has no differences after moving a patch backup out of the source tree. Latest simulator/device engine and bundle build logs: `work/evidence/chevron-touch/`. | Recheck after further source or pin changes. |
| Early mission and save reload | Defection Agent completed in 3:31 on the clean-built app; screenshots `defection-clean-build-completed.png`, `defection-clean-build-reloaded-time.png`, `defection-clean-build-reloaded-unlock.png` under `work/evidence/`. | Does not establish full campaign or physical touch usability. |
| Second mission and save reload | Investigation Agent completion and full-process-restart time 10:06 / Extraction unlock: `work/evidence/investigation/{drcaroll-objective-completed,reloaded-investigation-time,reloaded-extraction-unlock}.png`. | Extraction and subsequent campaign missions remain incomplete. |
| Bots and challenges | Challenge 1 completed and one-player star reloaded (`work/evidence/challenge-one/`). `8sim` stores eight Normal bots and reloads into a nine-character match (`work/evidence/bot-save-recheck/`). | Wider scenarios and physical performance. The older `8bots` preset is empty and is not evidence. |
| Goldenpad UI and controls | Reference revision and adaptation in [goldenpad-reference.md](goldenpad-reference.md). Phone/tablet menu and layout checks in `PROGRESS.md`; per-control style, persistence/reset, firing, reload, secondary function and wheel hold/release tested. | Physical continuous drags, deliberate wheel slice selection, complete controller mission, hot-plug and human usability. Simulator automation lacks touch-move events; do not change app gesture semantics merely to accommodate it. |
| Gadgets | Night Vision toggle and resumed rendering checked. Investigation completion exercised required Holograph/Data Uplink/robot sequence; details in `PROGRESS.md`. | Wider gadgets/camera tools and physical controls. |
| Gyro | `tests/gyro_math.c`, `work/evidence/gyro-math-test.log`: cadence, orientation and invalid/stale-data integration checks pass. | Physical calibration, aiming feel and session testing; remains experimental. |
| Data and lifecycle | Repeated backed-up updates preserve Documents/Library excluding OS launch snapshots. Latest update preserved 773 files (`work/evidence/chevron-touch/before-install`). Saved agent progression remains visible after reload. Existing lifecycle evidence is indexed chronologically in `PROGRESS.md`. | Physical locking, interruptions, controller reconnection and broader long-session reliability. |
| Graphics and optional artwork | Original/Enhanced/Remaster fallback, status/profile selection and decoder-boundary checks exist. No supplied HD or Xbox asset pack in `ref/`. Synthetic pack selection is not rendered-art acceptance. | Loaded replacement art, transparency/scopes/transitions and memory/quality across supported profiles. |
| Phone qualification | Not run; no connected hardware. Simulator FPS is not phone performance evidence. | Exact device inventory and PRD 30-minute early/later mission plus bot session, frame intervals, memory, thermal behavior and profile selection. |
| LAN / co-op | No accepted two-device session. | P1 gate, intentional newer-engine integration, complete iPhone–Mac matches and two co-op missions with progression verification. |

## Next useful checks

Continue campaign coverage with an input path that can actually deliver continuous look. Preserve honest distinctions between ordinary UI play, diagnostic-driven input and human usability. When hardware is available, use the PRD's device conditions and thresholds; do not infer them from simulator timing. Optional art can be tested independently with supplied or appropriately licensed assets, without delaying the original-ROM core.
