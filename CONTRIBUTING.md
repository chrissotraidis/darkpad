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
```

Boot one Simulator at a time. Simulator checks do not establish touch feel,
controller feel, frame rate, heat or campaign completion on hardware; say which
device you tested on.

## Pull requests

Explain the user-visible result, why the change is needed, which checks passed
and what remains untested. Do not include copyrighted game screenshots or
private runtime logs.
