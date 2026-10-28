# DarkPad 0.1.0 release checklist

## Published on 28 October

- [DarkPad 0.1.0](https://github.com/chrissotraidis/darkpad/releases/tag/v0.1.0)
  is a regular Latest release at `09d3f6df008657adac387d6891ae5941d65613a2`.
  Its only attachments are `darkpad-v0.1.0-padmint.json` and `SHA256SUMS`.
- [PadMint 0.5.23](https://github.com/chrissotraidis/padmint/releases/tag/v0.5.23)
  is a regular Latest release at `0e377ca2a191cc3d4063516ba5a03597fef15118`.
  [PR #213](https://github.com/chrissotraidis/padmint/pull/213) is merged. Its three
  platform ZIPs and checksum file include the DarkPad catalog entry, original
  library icon, setup requirements and sideloading/import/update instructions.
- The README has no app icon. Issues and private vulnerability reporting are
  enabled. No DarkPad IPA, ROM, game-derived build output, save or signing file
  was uploaded. Personal build outputs remain private.

## Completed checks

- **Before tagging:** clean DarkPad `c13d20d` passed `scripts/player-check.sh`
  from then-current PadMint main `7e4c44c` (0.5.22), using Apple Python 3.9.6 and
  an empty PadMint folder; 855 seconds. Only documentation changed before the
  release tag; app, recipe, dependency and build-script inputs are unchanged.
- **After publication:** `scripts/player-check.sh darkpad ios -` passed from
  PadMint main `0e377ca` (0.5.23), without a checkout argument, using Apple
  Python 3.9.6 and an empty PadMint folder. It discovered the public recipe,
  checked its checksum, fetched `v0.1.0` and built a personal unsigned IPA in
  432 seconds. The package has the correct bundle ID/version, iOS 15 minimum
  and scene manifest, without ROMs, signing files or the development console.
- Both release gates passed for every attachment. PadMint's ZIPs and checksum
  file match the independent Windows CI build byte for byte. Both Mac Python
  jobs and all 11 platform-package jobs passed for the final catalog commit.
- The live catalog audit passed: **40 entries, zero problems**. GitHub's public
  DarkPad source archive matches all 262 files of the checked release source.
  Public Latest URLs and release downloads were checked without authentication.

Evidence is indexed in `PROGRESS.md`; private logs, records and the personal IPA
are under ignored `work/release-publish-20261028/`. These checks establish build
and packaging behavior. Physical gameplay limitations remain in
[acceptance](acceptance.md).

## For future releases

1. Commit a clean candidate with the intended `VERSION` and `DEV_ITERATION=0`.
   Review source/history for game data, private outputs and signing material.
2. From current PadMint `main`, run
   `scripts/player-check.sh darkpad ios - /path/to/clean/darkpad`.
   A failure blocks release; repeat after build-input changes.
3. Run `scripts/prepare-release.sh` from clean DarkPad. It creates a new
   `dist/darkpad-vVERSION/` with only the recipe and `SHA256SUMS`, and refuses
   an existing directory. Audit each file with PadMint and the private reference
   gate, and check `shasum -a 256 -c SHA256SUMS` in that directory.
4. When publication is authorized, publish the checked tag as a regular Latest
   GitHub release with only those two attachments. PadMint discovers recipes
   through `/releases/latest`; a draft or prerelease-only release is insufficient.
5. Require the live PadMint catalog audit to pass and merge any needed catalog
   update. From current PadMint `main`, run `scripts/player-check.sh darkpad ios -`
   without a checkout. A failure blocks the PadMint update and announcement.
6. If PadMint changes, ship its audited packages through its normal release
   route; existing downloaded copies retain their old catalog. Verify public
   links, downloads and availability copy before announcing.
