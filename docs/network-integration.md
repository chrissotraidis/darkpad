# Networking integration experiment

The working solo engine remains pinned to `90c8622e74b35be669d60d177effc6d7d2d7621c`. The reviewed networking candidate is `3ee8ed0cd549b64350848655c43ae1568e449c6d`; neither the pin nor vendor checkout has been changed. No network session has been validated.

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
