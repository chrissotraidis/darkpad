# DarkPad 0.1.0 release checklist

The first public release is **source and recipe only**. Preparing this checklist
or its assets does not authorize publication. Keep personal IPAs and all build
outputs private.

## Prepared on 28 October

- The repository is public. [PR #2](https://github.com/chrissotraidis/darkpad/pull/2)
  is merged into `main`; the README has no app icon or temporary branch-clone
  instructions. Issues and private vulnerability reporting are enabled.
- The [DarkPad 0.1.0 draft](https://github.com/chrissotraidis/darkpad/releases/tag/untagged-3f11c22ee81e5036397d)
  contains exactly the recipe and `SHA256SUMS`.
- The [PadMint 0.5.23 draft](https://github.com/chrissotraidis/padmint/releases/tag/untagged-51b816560b31848b3546)
  contains its three platform ZIPs and `SHA256SUMS`. All files passed both release
  gates, and the ZIPs match the independent Windows CI build byte for byte.
  Its catalog change remains in [PR #213](https://github.com/chrissotraidis/padmint/pull/213).
- Both releases are drafts. No public IPA or game data was uploaded. The public
  recipe lookup and post-publication player check still require publication.

## Before tagging

1. Review the [release notes](releases/v0.1.0.md), README and
   [acceptance record](acceptance.md). Record the owner's latest iPad gameplay
   results when available: a Perfect Dark mission, controller movement/aim,
   GoldenEye gameplay and B/BACK/PREVIOUS returning to the Perfect Menu.
   Unverified checks remain disclosed preview limitations; they do not block
   this preparation. Higher refresh rates stay experimental. Do not describe
   Simulator or launch checks as device gameplay acceptance.
2. Commit the intended release on the existing DarkPad branch. Verify the source
   and history contain no ROMs, extracted assets, saves or signing material.
   `VERSION` must be `0.1.0` and `DEV_ITERATION` must be `0`.
3. From **PadMint's current `main`**, run:

   ```sh
   scripts/player-check.sh darkpad ios - /path/to/clean/darkpad
   ```

   This must use Apple's `/usr/bin/python3` and the empty PadMint folder created
   by the script. A failure blocks release. Record the exact game commit,
   PadMint commit/version and log. Re-run after changes to the build inputs.
4. From the clean DarkPad checkout, run `scripts/prepare-release.sh`. It creates
   a new `dist/darkpad-v0.1.0/` containing only:

   - `darkpad-v0.1.0-padmint.json`
   - `SHA256SUMS`

5. From current PadMint, audit **each** staged file with
   `python3 -m padmint audit /path/to/file`; also run the maintainer's private
   release gate while it remains the reference. Every file must pass. Check the
   checksum with `shasum -a 256 -c SHA256SUMS` inside the asset directory.

## Publication order, when the owner releases it

1. Confirm the DarkPad draft targets the intended `main` commit. PR #2 is
   already merged. Reconcile any intervening changes and repeat affected checks
   before tagging.
2. The owner has made the repository public. Update the README's
   preparation notice and the release notes to describe the actual published
   state; remove the prepared-notes notice. The temporary branch instructions
   have already been removed. Confirm Issues and private vulnerability reporting
   remain enabled at publication. Do not announce availability ahead of publication.
3. Tag the checked release commit `v0.1.0` and publish it as a regular GitHub
   release marked Latest, with **only** the recipe and checksum attachments.
   Keep the preview wording in its title/notes. PadMint starts at
   `/releases/latest`, so a draft or prerelease-only first release is not
   discoverable through that route. Do not attach an IPA, a build folder or any
   game-derived artifact. GitHub's source archives come from the tag.
4. Review and merge [PadMint PR #213](https://github.com/chrissotraidis/padmint/pull/213)
   after the public release is readable. Its catalog entry must keep the build Mac-only,
   request the ROM **in the app**, link to `#get-darkpad`, and include sideloading
   and first-launch instructions. Its current live catalog audit reports exactly
   one problem: DarkPad releases/latest returns 404 before its first release.
   Rerun that audit after publication and require it to pass before shipping
   the PadMint update.
5. Recheck from current PadMint `main` **without a checkout argument**:

   ```sh
   scripts/player-check.sh darkpad ios -
   ```

   This must fetch the published recipe, verify its checksum and build the
   tagged source through the player route. A failure blocks announcement.
6. After that check passes, publish PadMint 0.5.23 through its normal release
   route. Its draft targets PR #213's checked commit; reconcile the target and
   assets if that PR changes. Merging a catalog file alone does not update
   already downloaded PadMint copies. Update both projects' preparation notices
   and confirm public README/help links, release attachments and the listing
   are reachable without maintainer authentication. Announce only after the
   post-publication player check passes.

## Evidence

The October 28 clean player check **passed** on DarkPad
`c13d20d3b1a91518583955140868b6dd8f590995` using PadMint main
`7e4c44c22a0c289ccb104ae054dd2f7ae5e6f041` (v0.5.22), Apple Python 3.9.6 and
an empty PadMint folder. It completed in 855 seconds and produced a private
11,140,514-byte IPA. Recipe, checksum and source snapshot passed both release
audits; staged-file discovery and catalog checks passed locally.

Only documentation changed after that build. The recipe and build inputs are
unchanged. Full evidence is indexed in `PROGRESS.md`. Publication, making the
catalog available to players, and the post-publication check remain separate
steps.
