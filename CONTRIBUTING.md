# Contributing to DarkPad

DarkPad welcomes focused fixes to its Apple shell, engine patches, build scripts
and documentation.

## Before opening a change

- Never commit or attach ROMs, extracted game assets, Xbox 360 or GoldenEye
  packages, saves, `pd.ini`, certificates, provisioning profiles, private paths
  or credentials.
- Keep the upstream engine pinned and unmodified. Engine changes belong in
  ordered patches under `overlay/patches/`; `scripts/apply-overlay.sh` must
  apply every patch with zero fuzz.
- Prefer the smallest change that keeps the existing shell and controls
  consistent. The touch layout, ••• menu and controller defaults follow
  GoldenPad and the sibling ports; see `docs/goldenpad-reference.md`.

## Verify the change

Build from the repository root:

```sh
scripts/bootstrap-apple.sh
```

After a shell change, rebuild the app and run the tests that cover the code you
touched, for example:

```sh
python3 tests/texture_upscale.py
python3 tests/image_decoder_limits.py
python3 tests/texture_pack_prepare.py
python3 tests/input_clipboard.py build/src/port/src/input.c
clang -std=c11 -Iapp/ios -fsanitize=address,undefined tests/gyro_math.c -o /tmp/gyro_math && /tmp/gyro_math
python3 tests/network_touch_look.py build/src
python3 tests/network_local_player.py build/src
python3 tests/network_coop_results.py build/src/src/game/endscreen.c
python3 tests/network_weapon_progress.py build/src/src/game/training.c
python3 tests/network_session_exit.py build/src
python3 tests/public_package.py
python3 tests/macos_package.py
python3 tests/macos_input.py
```

For Mac Catalyst changes, build the personal app with
`scripts/build-personal-macos.sh /tmp/DarkPad-Mac.zip` and check first launch,
window resizing/fullscreen, restart, settings and gameplay input on macOS.
The older desktop reference build does not exercise the shared app.

When you move UPSTREAM_PIN, apply the overlay with scripts/apply-overlay.sh and
fix any patch that fails by rebasing it; never drop a fix to make the series
apply. Netplay compares build identities, so keep overlay 0083 and the
PD_VERSION_HASH argument in scripts/build-ios.sh.

Boot one Simulator at a time unless you are testing online play. Simulator checks do not establish touch feel,
controller feel, frame rate, heat or campaign completion on hardware; say which
device you tested on.

## Releases

Follow [the release checklist](docs/RELEASE-CHECKLIST.md). Only source, a PadMint
recipe and its checksum are published. The current-main PadMint player check
must pass before tagging and again through the published release before an
announcement. Personal IPAs never become release attachments.

## Pull requests

Explain the user-visible result, why the change is needed, which checks passed
and what remains untested. Do not include copyrighted game screenshots or
private runtime logs.
