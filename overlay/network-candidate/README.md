# Experimental networking replacements

These patches replace same-named solo overlay patches **only** when explicitly passed to the audit tool. The normal build does not use this directory.

Target: `3ee8ed0cd549b64350848655c43ae1568e449c6d`.

**Current state:** touch/gyro command transport and prediction are implemented in the candidate, with deterministic sanitizer tests and a successful simulator app build. Live gameplay/network validation remains pending. Earlier entries below record intermediate incomplete states. The candidate uses experimental protocol `0x4431`; both peers must use this overlay, and upstream protocol32 peers are intentionally incompatible.

```sh
scripts/audit-upstream.sh 3ee8ed0cd549b64350848655c43ae1568e449c6d overlay/network-candidate
```

0015 preserves candidate dedicated-server early return and network raw-mouse handling. Touch buttons/stick merge only into physical controller0; candidate netplayers reads controller0 to construct the local command. Solo look retains absolute-degree injection. Direct look injection is gated to NETMODE_NONE because network simulation must obtain aim through the command/prediction path, not add local frame deltas to every simulated player/pass.

**Incomplete:** network touch/gyro look is not transported by this patch. Implement it through command accumulation, serialization and prediction before calling network controls functional. Do not enable the candidate in the normal build yet. Candidate compilation/runtime regression tests remain pending.

First replacement audit: 0015, 0019 and0020 now apply; remaining13 failures include0051 menu scrolling. Partial application is diagnostic, not acceptance.

0051 rebases touch list clamping around the candidate's `!leave` guard: keyboard Up/Down can leave a flagged list at its ends, while touch wheel movement remains clamped. Entry hit-testing and side navigation remain intact.

0061 adjusts only the initial include context to retain the candidate's net/net.h include alongside the platform HUD inset hook. All six remaining HUD hunks apply unchanged.

Latest replacement audit:44PASS/11FAIL (`work/upstream-audit.u29F0I`). Input/menu/HUD patch application is now clean; compilation, runtime behavior and network look transport remain unverified/incomplete.

0001 keeps direct-folder scan depth4 while preserving upstream's separate unpacked-archive depth6. 0046 rebases package import around upstream's `.extracted15` cache marker and original-helicopter asset inclusion; the dependent0049 package table bounds checks apply unchanged. Latest audit47PASS/8FAIL (`work/upstream-audit.23D3W8`): remaining conflicts are0023/0028/0048 audio,0027 profiling, and0032–0035 rendering. Asset runtime tests remain pending.

0023 now merges iOS queue/rate/gain controls with candidate surround: channel-aware interpolation/fades/silence, six-channel allocation capacity, separate gain buffers, per-device-open priming/history reset, and consumption of surround chunks before drop paths. Output position counts successfully queued resampled frames and silence. Candidate focus gain, recorder downmix and raw output dump are retained.0028/0048 are rebased to the new include layout/history resets; reopening also clears stalled-drop flags.

Latest audit50PASS/5FAIL (`work/upstream-audit.tgvP6I`), with audio patches applying. The merged audio.c passes iOS and desktop syntax compilation. Run `python3 tests/candidate_audio_channels.py <audit>/src/port/src/audio.c` for ASan/UBSan coverage of stereo/surround interpolation, fades, frame counts and repeated channel switches. Full candidate linking, live audio, queue/drop/priming and interruption acceptance remain pending; these tests do not prove playback quality.

0032 preserves the candidate's G_SETRECTSCALE_EXT opcode while adding display-list class tags. Its dependent0033/0035 patches now apply.0034 places the existing world near clamp ahead of the candidate's menu rectangle scaling without deleting that scaling.

0027 retains network tick/presentation branching and network video frame-step accounting. GAME profiling closes even on tick-only passes, and repeated passes accumulate through the profiler's existing accumulator. This is instrumentation integration, not a networking performance result.

Latest audit: **55PASS/0FAIL**, `work/upstream-audit.q2CGqw`. The first simulator compilation found0015 had latched touch input in controller initialization; corrected the patch to call it from inputUpdate after the dedicated-server return. Reconstructed from scratch and built all807 Ninja steps successfully with the normal simulator CMake settings in an isolated output directory. `work/network-candidate-build-fixed/libpd.a` is arm64, with613 Mach-O objects reporting simulator platform7. Build log: `work/network-candidate-build-fixed.log`; exact local invocation: `work/build-network-candidate.sh`. Profiler enabled. Audio helper sanitizer checks pass on this reconstructed source.

This is an engine static-library build only. App linking, desktop build, live rendering/audio/input/save regressions and network touch-look transport remain pending. The working solo pin, vendor and installed app are unchanged.

Application-link follow-up: simulator app BUILD SUCCEEDED with the candidate library path explicitly overridden; candidate network/input symbols present, arm64 simulator platform check PASS. Separate desktop executable also builds and passes macOS platform check. See docs/network-integration.md for invocation and evidence. Neither candidate executable has been runtime-qualified or substituted for the installed solo app.

Touch transport preparation:0015 now exposes the latched touch/gyro degree pair and accumulates it separately from integer mouse counts in netInputAccumulateMouse. Shared motion clearing runs at stage start and tick end. Separate repeatable tick and pending-presentation getters preserve fractional motion and suppress tick reads during presentation-only passes. These new getters are intentionally not yet connected to gameplay/command consumers: command flags, mixed signed sensitivity and presentation prediction still need a consistent integration. Network aiming remains incomplete.

Fresh55/55 audit: `work/upstream-audit.psiBWn`. `python3 tests/candidate_network_motion.py <audit>/src` runs actual extracted input/accumulation functions under ASan/UBSan; passes100 sub-count moves, repeated reads, render-only frames, catch-up clearing, stage reset, multiple shell events and mouse independence. Modified input.c/net.c syntax-compile for simulator and desktop; logs in work/network-look-merge. Latest full app/desktop builds predate this accumulator addition.

Command integration:0015 now extends netcmd by two separate scaled touch components (44-byte packed record), explicitly changes the protocol ID, carries these through validation, folding/catch-up, dry-tick clearing, remote signed/absolute reads, capture and prediction replay. Local frame getters consume accumulated degrees on simulation ticks; presentation prediction reads unspent degrees even without SDL mouse lock. Menu capture clears both mouse and touch. Mouse sensitivity signs apply only to mouse components.

Fresh audit `work/upstream-audit.Y21Gln`:55/55. `tests/candidate_network_commands.py` compiles actual netcmd/netdelta/netbuf and extracted folding/replay/remote getter functions under ASan/UBSan: roundtrip, changed tiny touch fields through delta, guard bytes, truncation, folding, mixed signs and presentation/locked gating pass. Motion accumulation tests still pass. Simulator full engine807 steps and app build PASS, platform7 arm64 verified; artifacts `work/network-touch-build/libpd.a` and `work/dd-network-touch/Build/Products/Debug-iphonesimulator/perfectdark.app`, logs work/network-touch{,-app}-build.log. All five changed C sources syntax-check on desktop. Earlier Mac executable still has the old protocol: rebuild it before paired testing. No candidate install/live match has occurred.

0002 now requires a content-derived `.darkpad-source-id` generated after successful audit reconstruction. This fixes platform builds inheriting different enclosing Git commits and refusing each other. Full source digest is stored; first16hex characters identify the network build. Two fresh reconstructions agreed; rebuilt simulator/Mac connected successfully. See docs/network-integration.md for runtime evidence and the still-unresolved simulator look-drag behavior.
