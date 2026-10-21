# Experimental networking replacements

These patches replace same-named solo overlay patches **only** when explicitly passed to the audit tool. The normal build does not use this directory.

Target: `3ee8ed0cd549b64350848655c43ae1568e449c6d`.

```sh
scripts/audit-upstream.sh 3ee8ed0cd549b64350848655c43ae1568e449c6d overlay/network-candidate
```

0015 preserves candidate dedicated-server early return and network raw-mouse handling. Touch buttons/stick merge only into physical controller0; candidate netplayers reads controller0 to construct the local command. Solo look retains absolute-degree injection. Direct look injection is gated to NETMODE_NONE because network simulation must obtain aim through the command/prediction path, not add local frame deltas to every simulated player/pass.

**Incomplete:** network touch/gyro look is not transported by this patch. Implement it through command accumulation, serialization and prediction before calling network controls functional. Do not enable the candidate in the normal build yet. Candidate compilation/runtime regression tests remain pending.

First replacement audit: 0015, 0019 and0020 now apply; remaining13 failures include0051 menu scrolling. Partial application is diagnostic, not acceptance.
