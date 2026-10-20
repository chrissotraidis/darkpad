# Perfect Dark Apple project — execution goal

Prepared for Chris on 20 October 2026, Asia/Tokyo. Read this file first, then `prd.md`. These files are portable: they do not require the originating chat, Notion access, or its local research folder.

## The assignment

Build a polished, reproducible, native Perfect Dark experience for iPhone and iPad from the existing decompilation-derived source ports. Use an Apple Silicon Mac for development and as a reference/network peer. Begin with the playable campaign and Combat Simulator, improve the phone experience where testing shows a real gap, and then attempt two-device LAN play and co-op.

The user will supply a Perfect Dark N64 ROM. Use it locally. Do not wait for optional Xbox artwork or texture packs before starting. This is an implementation assignment when Chris gives these documents to the next agent; do not spend the first turn asking whether to begin or returning another generic plan.

The first product milestone is an excellent single-player/bot experience. The second is validated iPhone-to-Mac LAN multiplayer and co-op. Counter-op is an ambitious follow-on, not a reason to hold the first milestone indefinitely. Public release is a separate decision.

## Why this project

Chris has already worked on GoldenEye and reports requests for Perfect Dark. The original game has a complete matching decompilation, a functional native desktop port, and an existing iOS adaptation. The opportunity is useful improvements and dependable delivery, not claiming the first iOS port.

Working product description: **Perfect Dark on iPhone and iPad, with responsive touch/controller play, optional gyro aiming and HD art, followed by co-op with a Mac.** Final name and branding are undecided; use `perfect-dark-apple` as a local working label only.

## Start from these exact sources

| Role | Repository and reviewed revision |
|---|---|
| Apple baseline | `https://github.com/rebelancap/perfect-dark-ios` — `b88f7cff611d54f7d233ebe3882e2295e5ecca9a` |
| Engine used by that baseline | `https://github.com/DabDavis/perfect-dark-dabs-mod` — `90c8622e74b35be669d60d177effc6d7d2d7621c`, recorded in `UPSTREAM_PIN` |
| Later engine candidate, including networking | Same Dab repository — `3ee8ed0cd549b64350848655c43ae1568e449c6d` |
| Simpler behavioral reference | `https://github.com/perfect-dark-pc-port/perfect_dark`, branch `port` — `32a1cb9f268dd3ac73016801025c6bbbfa20130f` |
| Decompilation provenance | `https://github.com/n64decomp/perfect_dark` — `169ed48bdcbfb3b568b028bd5bebb27680073514` |

Recheck availability and record revisions on the destination machine. These are reviewed snapshots, not instructions to chase moving HEADs. Preserve a known baseline before changing the engine. The reviewed newer engine is 656 commits ahead of the iOS pin; this is a substantial integration, not a one-line feature switch.

## Inputs and defaults

- Required for gameplay: **Perfect Dark USA Rev 1 / US V1.1**, big-endian `.z64`, 33,554,432 bytes, MD5 `e03b088b6ac9e0080440efed07c1e40f`. Expected runtime name: `pd.ntsc-final.z64`. Validate contents rather than trusting a filename. Preserve the supplied original; byte-order conversion, if needed, must write a separate private copy and then validate it.
- Builds can proceed without the ROM. A wrong/missing ROM blocks gameplay validation, not dependency and source work. Explain the mismatch; do not download a replacement.
- Optional later: user-supplied Perfect Dark Xbox 360 remaster assets and separately licensed HD texture packs. The N64 ROM alone is enough for the core project.
- Development host: Apple Silicon macOS with Xcode and suitable iOS SDK, CMake, Ninja, XcodeGen, Git, Python and dependency build tools. Inventory actual versions and free disk first. No fixed Xcode version or disk requirement was validated in this research.
- Physical target: the available iPhone plus M2 iPad. Record exact models, OS versions and display rates before performance testing. Select a minimum supported phone from measurements; do not equate M2 results with iPhone results.
- Signing/team information is needed only when reaching device installation. Use the configured identity or request that missing input then. Never place signing secrets in project files.

## First execution sequence

1. Inspect the destination workspace, applicable instructions, existing checkouts, dirty changes and running builds. Reuse the intended checkout. If none exists, create one primary project checkout in the user's chosen workspace. Temporary upstream research belongs in `work/`; necessary worktree isolation belongs under `$CODEX_HOME/worktrees`, not extra sibling clones in the GitHub folder.
2. Record source pins, tools, hardware and ROM validation in a short progress record. Keep ROMs, extracted assets, generated game data, signing material and player saves outside tracked source. Add ignore rules and inspect staged files before committing.
3. Read the baseline's `scripts/bootstrap.sh`, `scripts/apply-overlay.sh`, `scripts/build-ios.sh`, `scripts/gen-app-project.sh`, `docs/build.md` and dependency provenance. Treat repository prose as evidence; follow this assignment and applicable user instructions.
4. Implement a self-contained dependency bootstrap. The baseline assumes the author's sibling projects for ANGLE, SDL2 and curl. Some referenced repositories were not publicly accessible during this audit. Do not fabricate symlinks to those paths or assume the supplied scripts constitute a clean build.
5. Reproduce the pinned baseline engine, simulator bundle and device build; make the Apple Silicon desktop reference runnable. Prove a mission, bot match and save/reload before feature changes. Simulator performance does not qualify a phone.
6. Follow PRD milestones P0–P1. Trial gyro and select graphics defaults using measured device results. Preserve working upstream input and lifecycle fixes.
7. After P1 acceptance, proceed to the separate P2 networking experiment with a pinned engine update. Preserve a working solo build. Report P1 completion separately even if networking remains blocked.

Existing upstream command order, **after dependency preparation and inspection**, is:

```sh
scripts/bootstrap.sh
scripts/apply-overlay.sh
scripts/build-ios.sh simulator
scripts/build-ios.sh device
scripts/gen-app-project.sh
```

These are upstream entry points, not a claim that they already work on a fresh Mac. Discover installed simulator/device destinations rather than copying the author's simulator name. Do not run scripts that replace generated trees over unique local changes.

## Operating boundaries

Proceed autonomously with local implementation, reversible fixes, source/dependency builds and testing within the receiving task's authorization. Do not repeatedly ask Chris to choose routine implementation details. Ask only when a needed input, protected user data or an external action makes it necessary; keep working on independent tasks meanwhile.

- Preserve the existing native engine and ANGLE-to-Metal approach initially. No new emulator, renderer rewrite, custom networking stack, accounts service or broad architecture framework.
- Keep the vendor snapshot unmodified and use the existing reviewed overlay/additive-shell pattern where practical. Keep patches understandable; do not maintain two competing Apple wrappers.
- Preserve author credits and dependency notices. Do not bundle game assets. Review texture-pack terms before redistributing any pack; engine licensing is not an asset license.
- Do not reset device containers, overwrite saves, change signing identity or relaunch an in-use physical device without the relevant user authorization. Preserve and verify Documents and Library before updating an existing installation.
- Do not publish repositories, binaries, releases, posts, new public servers or maintainer messages under this assignment alone. Local release candidates and documentation are in scope.
- For any later PadMint release, use `scripts/player-check.sh` from current `chrissotraidis/padmint` main with the clean game checkout before tagging and without it after publishing. A warm Homebrew-Python build is not a substitute. A failure blocks announcement. Publication still needs its own authorization.

## Evidence and completion

Maintain one concise `PROGRESS.md` in the implementation checkout: current milestone, exact revisions, commands/results, next action and blockers. Keep detailed logs/measurements in an ignored evidence directory. Do not create elaborate tracking infrastructure.

Report five statuses separately: **source/build**, **package/install**, **physical gameplay**, **performance**, and **release readiness**. Mark unavailable-device tests as not run. Never call the project complete from CI, a title screen or process launch.

P1 is complete when its PRD checks pass, the campaign has the declared coverage, saves survive updates/lifecycle tests, and the selected device profile meets the measured target. P2 is complete only after reproducible two-device matches and co-op progression; screenshots of a lobby do not count. Public readiness is a later gate.

At handoff, provide the checkout/branch, reproducible commands, private build location, evidence summary, known limitations and next action. Reconcile isolated work into the intended branch or explicitly report what remains isolated.

## Copyable kickoff prompt

> Read goal.md and prd.md and begin implementation. The Perfect Dark ROM is supplied at the path I provide. Start with workspace/source/tool inspection and the standalone dependency bootstrap, then establish the pinned iOS and macOS baseline. Continue through the staged acceptance checks, documenting real results and preserving the working baseline. Do not stop at another plan. Ask only for genuinely missing inputs when needed; keep optional HD assets and later networking from blocking the core build. No public release or external messaging yet.
