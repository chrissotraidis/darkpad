# Experimental networking replacements

These patches replace same-named solo overlay patches **only** when explicitly passed to the audit tool. The normal build does not use this directory.

Target: `3ee8ed0cd549b64350848655c43ae1568e449c6d`.

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
