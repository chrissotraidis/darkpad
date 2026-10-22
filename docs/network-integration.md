# Networking integration experiment

The working solo engine remains pinned to `90c8622e74b35be669d60d177effc6d7d2d7621c`. The reviewed networking candidate is `3ee8ed0cd549b64350848655c43ae1568e449c6d`; neither the pin nor vendor checkout has been changed. Simulator-to-Mac timed bot matches, touch aiming, respawn and background/resume have been exercised. Direct LAN menu joining and cancellation/rejoin have passed; results return and host exit between matches also pass. Menu hosting, setup, start, results return and stop have been exercised. Co-op starts through the menu and abort preserves both peers’ offline saves; completed co-op missions remain unverified. The sections below retain the integration history; use the latest checkpoint and PROGRESS.md for current state.

## Reproduce the compatibility audit

With the candidate commit already fetched in `vendor/dabs-mod`:

```sh
scripts/audit-upstream.sh 3ee8ed0cd549b64350848655c43ae1568e449c6d
```

This creates a fresh ignored `work/upstream-audit.*` directory, archives the exact revision, and tries all overlay patches in order with zero fuzz. `results.tsv` records results; individual logs include offsets and rejected hunks. A failed patch may partially apply, so the resulting tree is diagnostic only. Exit status is nonzero if any patch fails. The command does not fetch, check out a revision, change the pin, or replace the working build tree.

## First audit result

All 55 patches apply to the solo baseline. On the candidate, 39 apply and 16 fail:

- Asset import: 0001, 0046, 0049.
- Input and native menu integration: 0015, 0019, 0020, 0051.
- Audio: 0023, 0028, 0048.
- Frame profiling: 0027.
- Display-list/stereo rendering: 0032, 0033, 0034, 0035.
- HUD safe area: 0061.

A failure does not establish that the feature is absent upstream; inspect each rejected hunk against the candidate before rewriting or dropping it. Later failures can depend on earlier rejected patches. Passing patches also need offset/semantic review.

## Next integration steps

1. Resolve the input/menu seam against candidate input and network session ownership first; retain the current Goldenpad touch behavior and menu pause rules for solo play.
2. Reconcile asset, audio and rendering conflicts; preserve inherited behavior rather than dropping patches to obtain a green build.
3. Build the candidate separately for Mac and simulator, then rerun solo save/input/rendering regressions before replacing the working installation.
4. Inspect direct connection, content-transfer and lobby discovery paths before starting a LAN session. Direct tests must not silently rely on public lobby/relay services or transfer game assets.
5. Test Mac plus one simulator, matching protocol and local assets. Complete bot/player matches and two co-op missions, documenting death/restart and each endpoint's save behavior. This follows the user's simulator-only constraint and cannot qualify physical-device networking/performance.

The candidate's netplay documentation describes protocol32 authoritative-host networking. This is an upstream design statement, not evidence that Apple endpoints interoperate. P1 campaign/effect/lifecycle acceptance remains incomplete and separate from this compatibility preparation.

## Current integration evidence

All55 overlay patches now apply using the replacements in `overlay/network-candidate` (audit `work/upstream-audit.q2CGqw`). An isolated arm64 iOS simulator engine static-library build passes with profiler enabled; source and build logs are recorded in the replacement README. The first compile exposed an incorrectly placed touch latch; it now runs in inputUpdate each frame instead of during controller initialization. The normal solo build remains pinned and untouched.

Simulator app linking and desktop compilation now pass (details below). Next: implement network touch/gyro look through the candidate command path, then run the solo regressions and local-only LAN/co-op sessions. Patch application and a static-library build do not establish runtime compatibility.

## Candidate application and desktop builds

Both builds use the complete reconstructed source in `work/upstream-audit.q2CGqw`, without replacing the solo build outputs.

Simulator app link:

```sh
xcodebuild -project app/perfectdark.xcodeproj -scheme perfectdark \
  -configuration Debug -sdk iphonesimulator \
  -derivedDataPath work/dd-network-candidate CODE_SIGNING_ALLOWED=NO \
  'LIBRARY_SEARCH_PATHS=$(SRCROOT)/../work/network-candidate-build-fixed $(SRCROOT)/../work/deps-$(PLATFORM_NAME)/lib $(SRCROOT)/../work/curl-$(PLATFORM_NAME)/lib' build
```

Result: BUILD SUCCEEDED; `scripts/check-apple-platform.py iphonesimulator` passes on the resulting app executable. Its symbol table includes netInputAccumulateMouse and inputIosLatchFrame, confirming the candidate engine was linked. Log: `work/network-candidate-app-build.log`. This unsigned simulator bundle is not installed or runtime-tested yet.

Desktop: the existing `scripts/build-macos.sh` CMake recipe with source set to the same reconstructed candidate tree and output set to `work/network-candidate-macos` passes all805 Ninja steps. Exact local invocation saved as `work/build-network-candidate-macos.sh`; log `work/network-candidate-macos.log`. The resulting pd.arm64 passes the macOS platform/architecture check. Both executables' dynamic dependencies were inspected: system libraries/frameworks and the app's ANGLE framework references, with no Homebrew dylib dependency observed. macOS linking warns about duplicate libc++ and reduced common-section alignment; runtime remains unverified.

## Touch/gyro network integration obligations

Source inspection confirms schedEndFrame calls inputUpdate then netInputAccumulateMouse. net.c accumulates raw mouse counts until netTickEnd, zeros reads on presentation-only passes, and exposes unspent counts to prediction. Apple touch/gyro uses floating-point degrees independent of mouse sensitivity: do not round it into raw mouse counts or inject the current display frame into every pass.

The client command already carries scaled mdx/mdy and NETCMD_MOUSELOCKED; remote simulation and prediction replay consume those fields. A correct integration must accumulate degree deltas across frames, clear them alongside the tick/session reset, expose the accumulated value only to local simulation ticks, and include unspent degrees in presentation prediction. Preserve signed-versus-absolute sensitivity behavior when mixing a real mouse with touch: remote absolute deltas currently multiply the entire command by the mouse sensitivity sign. Verify flags, reset/pause behavior and mixed-input semantics as well as serialization. These are requirements for the next implementation, not implemented features.

Degree accumulation and lifecycle clearing are now implemented in candidate0015 and covered by `tests/candidate_network_motion.py`. They do not yet feed command/gameplay/prediction consumers. Inspection found a protocol constraint that must be resolved before enabling them: one combined signed mdx/mdy pair cannot also reproduce independently signed mouse and unsigned touch contributions in the remote absolute getter when mouse sensitivity is negative. Any wire-format change must be explicit/versioned and carried through command packing, validation, folding/catch-up, replay and both peers; do not silently reinterpret protocol32 or flip touch behavior to avoid the work.

## Touch command integration implemented; runtime gate remains

The separate-degree transport is now implemented in candidate0015. Experimental protocol `0x4431` extends packed commands from36 to44 bytes with two touch components in the same scaled units as mouse deltas. Mouse and touch remain separate through capture, command validation, folding/catch-up and replay. Remote absolute getters apply sensitivity signs only to mouse. Render-only prediction uses pending touch degrees, and tick-end clearing prevents repeated catch-up turns. Native pause/menu behavior and actual paired gameplay still need runtime validation.

Both motion and command sanitizer suites pass against `work/upstream-audit.Y21Gln`; the full simulator engine/app builds and platform check pass. The candidate Mac source syntax-checks, but its previously built executable predates the wire change. Next rebuild that peer, preserve installation data, then validate solo/touch/menu/save behavior and local-only LAN/co-op with the matching pair. The protocol change deliberately prevents accidentally connecting to an unmodified upstream peer; it is experimental, not a claim of upstream compatibility.

## First live loopback evidence

The matching Mac executable is now rebuilt at `work/network-touch-macos/pd.arm64` (805 Ninja steps, arm64/macOS platform check PASS). Recipe `work/build-network-touch-macos.sh`, log `work/network-touch-macos.log`. It uses the same protocol0x4431 source as the simulator candidate.

Ran a dedicated Mac host and rendered Mac client on127.0.0.1:27381, each with a newly created test savedir under work and the local ROM base directory. The test configuration points LobbyServer at127.0.0.1:9; no public room was created, and both used the same original-ROM content. Host arguments: `--dedicated --host 27381 --net-test-host 1 --net-test-stage 0x32 --net-test-sims 2 --endless --rng-seed 12345`. Client arguments: `--connect 127.0.0.1:27381 --net-test-join --exit-frame 700`. Both also used `--skip-intro --no-sound --state-hash 100` with explicit `--basedir` and `--savedir`. Exact orchestration: `work/network-look-merge/loopback.py` (fresh directories and bounded process cleanup).

Evidence `work/network-loopback.m66g9pbc/{host,client}.log`: client joined, all9 stage hash components matched, GO barrier passed, frame700 reached, client exited0 and host freed slot0. Host exited0 on cleanup. At tick600,302 snapshots received/decoded, zero malformed; at client exit tick699,275 prediction comparisons matched with zero corrections. The client was idle: these figures do not demonstrate moving/touch prediction quality. One reported tick backlog was clamped; no performance claim. macOS GL loader emitted missing legacy-entry-point warnings but rendering initialization and the session proceeded.

A second fresh run advertised protocol32 using `--net-test-protocol 32`. Host explicitly refused the mismatch; client exited3 as intended. Evidence `work/network-loopback.lnbbbocc`. No second simulator was booted; the existing iPad and installed solo app were untouched. Next: simulator-to-Mac runtime checks with touch, then full matches/co-op and lifecycle/save acceptance. This short loopback is not a completed match, LAN-device session or co-op gate.

## Simulator peer and deterministic source identity

First simulator-to-Mac attempt was correctly refused: identical engine sources had VERSION_HASH c551e30 on simulator and e847abd on Mac because CMake's git lookup escaped the archived tree into the enclosing wrapper repository. Candidate0002 now requires `.darkpad-source-id`; successful audit reconstruction hashes sorted relative source paths and bytes, and CMake uses the first16 digest characters. It fails configuration if the identity is missing/invalid rather than borrowing a parent Git commit. Normal solo patches are unchanged.

Two independent fresh reconstructions (`work/upstream-audit.UYxFSR`, `work/upstream-audit.Pg9V3p`) produced identical SHA256 `5332264a84fc65014ca72c1683369916aa1e657e34d4f28d06a614f0ec6c3851`,55/55 patches each. Simulator and Mac rebuilds both report5332264a84fc6501; full engine builds and simulator app link PASS. Artifacts: work/network-identity-build/libpd.a, work/network-identity-macos/pd.arm64 and work/dd-network-touch/Build/Products/Debug-iphonesimulator/perfectdark.app. Scripts/logs use work/build-network-identity{,-macos}.sh and work/network-identity-{build,macos,app-build}.log.

The candidate is installed separately as `com.rebelancap.perfectdark.networkcandidate`, display name Darkpad Network Test, on the existing iPad simulator. Original solo app/data were untouched. Candidate Documents/Library were backed up before its update; post-install comparison matched every backed-up file except5 iOS-managed SplashBoard snapshots removed by installation. Backup retained in work/network-look-merge/candidate-before-identity.

Retry evidence `work/network-simulator-identity.9mg8lfte`: simulator joins Mac dedicated host, loads stage0x32 and passes GO. Through tick5400 it decoded2719 snapshots with zero malformed; prediction2404/2408 comparisons matched,4 position corrections,10 replayed ticks. This is not a completed-match or performance result. Native ellipsis/settings work. Auto touch visibility hid controls after a detected GCController; selected On in candidate settings and controls appeared. Two look drags did not visibly rotate the camera, so input routing/aim remains unresolved. Screenshot controls.png records the test. The optional diagnostic bridge reported port8775 busy with the existing solo process; do not read that port as candidate state. Candidate process terminated, host exited0. Only one simulator remains booted.

Next isolate simulator pointer/touch delivery versus engine command consumption, verify actual aim movement and remote agreement, then run complete sessions and save/lifecycle checks.

## Touch lift movement fixed and verified against Mac host

- Previous goal turn verified the continuation job; it made no product progress. Resumed the pending overlay change and read the live candidate bridge on8786, separate from solo8775.
- Diagnosed zero movement callbacks for simulator CUA drags: before the fix, a routed touch produced zero look publications. PDTouchOverlay now consumes the residual real position on normal lift before removing predicted lead; cancellation adds no residual. Existing coalesced samples remain accounted for by _lookLast. Added passive movement/publication counters for diagnosis.
- Candidate app build PASS (work/network-look-lift-build.log). Candidate Documents/Library backups gcfs5bgk and qlgj5r2u retained;17 non-SplashBoard files matched after installation. Original solo installation and engine pin unchanged.
- Live isolated candidate on the sole iPad connected to matching Mac host, stage0x32 with zero bots. Evidence work/network-look-trace.0nuxbk9y: first lift -310.5 points published -93.15 degrees; reverse +310.5 points brought accumulated yaw to zero and visibly restored corridor heading. Vertical lift78 points published23.4 degrees and visibly pitched toward floor. All three had zero touchesMoved callbacks and exactly one publication per gesture. Saved reverse/vertical screenshots and passive state/windows reports.
- Through tick10800,5323/5323 prediction comparisons matched with zero corrections;5551 snapshots decoded with zero malformed at tick11100. These are short gesture/session checks, not full aiming ergonomics, completed matches, co-op or sustained performance acceptance. Small position drift between first/reverse snapshots means no strict zero-translation assertion.
- Candidate explicitly stopped and Mac host exited0. One simulator remains booted. Source/build and candidate installation verified; physical tests excluded by user, performance/release readiness incomplete. Next complete bot-match/network interaction and lifecycle checks, and regress this shared overlay fix in the solo build. Goal remains active.

## Current runtime checks (21 October 2026)

The completed-match checks in this section used matching simulator/Mac candidate identity `f778b98fa3d272ca` (56 applied patches). The candidate-only test-host setup initializes valid bot profiles and names before transmitting rules. Named four-bot timed matches now reach results. Shared shell fixes retain final movement on camera, AIM and menu touches; the normal solo build also passes menu scrolling with preserved saves and HD artwork. See PROGRESS.md for build and preservation manifests.

Background/foreground was exercised for approximately29 seconds against a live Mac host; the client resumed and reached Game Over. This is simulator evidence, not physical LAN or performance qualification.

FIRE release reproduction recipe, using one simulator and a matching dedicated Mac host:

1. Use stage0x32, StartArmed, Falcon2, two-minute limit. With no bots, hold FIRE500ms, release and observe ammunition without further input. Repeat after START/Back and Home/reopen.
2. With4Normal bots, background for about26 seconds until killed; reopen, tap FIRE to respawn, drag look, open START stats, tap outside the dialog, Back, then hold FIRE500ms. Observe ammunition after release and compare host/client shot totals at match end.
3. Check passive candidate bridge8786 masks, not solo8775. Preserve screenshots/logs; stop both test processes.

Observed: zero-bot case produced exactly6 shots from3 presses (`work/network-timed-match.bfl9ro1n`); death/respawn case produced exactly2 shots (`work/network-timed-match.vbjna5e0`). Earlier `k2_1eqqf` reported32 shots after brief presses and remains unexplained. Do not claim it fixed; capture per-shot pad/mouse/command state if it recurs.

Normal lobby join/return, two co-op missions and progression, both host roles, and controlled latency/loss remain incomplete. Keep this engine isolated from the working solo pin.

## Direct LAN menu checkpoint

Candidate0063 adds Direct LAN to the Perfect Menu, with IPv4 address and port editors, validation, connection status, retry and cancellation. It uses the existing transport without an account or public lobby. Address and port changes, a no-host timeout and retry were verified in the simulator. A duplicate queued notice after cancellation was found and corrected in source; that correction still needs a UI regression check.

Latest reconstructed source: `work/upstream-audit.tWjrhY/src`, all57 patches applied. Both new platform builds identify as `8d0f203b8c87579a`. Simulator engine, Mac executable, simulator app link/platform checks and motion/command sanitizer tests pass. The rebuilt candidate is installed; installation preserved all non-SplashBoard Documents/Library files against `work/network-notice-backup.scmu0h_a`.

Private artifacts are `work/network-direct-notice-build/libpd.a`, `work/network-direct-notice-macos/pd.arm64`, and `work/dd-network-touch/Build/Products/Debug-iphonesimulator/perfectdark.app`. Local engine recipes are `work/build-network-direct-notice{,-macos}.sh`; logs use the same prefix. These new binaries have not yet passed paired runtime testing. Never pair the newly installed client with an older host identity.

Next: verify timeout/Back no longer produces a duplicate notice, then launch the matching local host and join using the menu without `--connect`. `work/network-look-merge/direct-menu-match.py` is the bounded local host recipe for that test; it does not provide a product hosting UI. Normal hosting, return from a match, native keyboard completion, hostname/IPv6 entry, co-op progression and controlled latency/loss still need work. UI testing was interrupted by a locked Mac; no additional host was started.

## Latest Direct LAN evidence

Build `6901f7d303d97b36` (59 patches) passes menu join, connected cancellation, rejoin and a completed two-minute bot match back to a usable Perfect Menu without the former empty notice. Saved data was preserved on installation. Automatic Direct LAN dialog restoration is still incomplete: the session remains connected but only the main menu appears. Revised0065 defers opening the dialog to the main-menu tick; source `fb4bf2344adf5b5b` audits59/59 and is building, not runtime accepted. See PROGRESS.md for handles/artifacts. Menu hosting and co-op are still open.

The subsequent `fb4bf2344adf5b5b` build passes the deferred-restoration runtime check: UI join, full timed bot match, Game Over → Direct LAN while still connected, graceful host exit displayed inline, then Back to usable Perfect Menu without an extra notice. Evidence: `work/network-timed-match.wi_f7xz2` including host log, restored-direct.png and clean-return.png. Both platform builds and simulator app linking passed; installed saved data is unchanged. This supersedes the restoration gap above, without claiming mid-match host-loss, hosting UI or co-op acceptance.


## Menu hosting and co-op save isolation

Candidate patches0066–0068 add Direct LAN hosting, a Combat/Co-op selector and offline-save isolation. The current reconstructed source is `8f71aee25df001e9b4bee2a03adb165c655517a08cee95d119a71532f83b7ab7` (62 patches, audit `work/upstream-audit.Lhzp4D`). Matching simulator and Mac engines plus the simulator application build successfully. The solo engine pin remains unchanged.

Host menus now expose Combat scenario, arena, weapons, limits and simulants, or Perfect Dark co-op mission, difficulty, radar and friendly fire. A simulator-hosted two-player timed Combat match completed and returned to Host LAN Game; Stop Hosting returned to the main menu. An occupied UDP port produces an inline error, Back works, and freeing the port permits hosting without relaunching.

Co-op Defection was started through the menu with a matching Mac peer. Death/spectating and abort were exercised, but no co-op mission was completed. An abort initially altered offline option/weapon-discovery data. Patch0068 guards the remaining endscreen writes and online weapon discoveries. The actual-function sanitizer test preserves offline discovery behavior while preventing host/client mutations. A rebuilt paired abort test left both EEPROM files byte-for-byte unchanged (`work/network-coop-save-check.c8lsxbk2/abort-save-comparison.json`). This is abort isolation evidence, not successful-mission or full progression acceptance.

Remaining checks include completed co-op missions/objectives, successful-result save isolation, repeat matches, mid-match host loss and controlled latency/loss. Original-art networking tests do not qualify HD multiplayer performance. See PROGRESS.md for current runtime state and artifact paths.

## Controlled delay/loss match (22 October)

The isolated candidate `ed9e6415e5fcec30` completed a one-minute stage0x32/four-bot match between the iPad simulator and matching dedicated Mac host through a localhost-only UDP impairment proxy. Recipe: `work/network-look-merge/impaired-match.py`; evidence: `work/network-impaired-match.tuwmd9gr/`. The proxy bound127.0.0.1:27382, forwarded to27383, delayed each direction by at least50ms and dropped every50th datagram independently in each direction. This is deterministic periodic loss, not random Wi-Fi loss, and adds approximately100ms round-trip delay beyond baseline.

At captured results, upstream had5,095datagrams/101drops and downstream5,382/107drops (about2% each). Actual forwarding delay ranges were50.018–64.931ms upstream and50.014–69.097ms downstream; these are proxy queue delays, not game RTT measurements. `result-conditions.json` preserves counts. UI movement, firing (8→5 rounds), reload (5→8), and death/respawn were observed. `game-over.png` shows4thplace/Falcon2. Back returned to the connected Direct LAN menu; its Back disconnected and returned to Perfect Menu without a hang. Host and proxy stopped normally afterward.

This is one short impaired match with original art and one simulator. It does not establish long-session tolerance, aiming quality, co-op, physical-device performance, random/burst loss, or behavior at higher impairment. No system-wide network settings or player saves were replaced.
