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

Next: complete app linking and desktop compilation, implement network touch/gyro look through the candidate command path, and then run the solo regressions and local-only LAN/co-op sessions. Patch application and a static-library build do not establish runtime compatibility.
