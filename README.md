# Darkpad — Perfect Dark for Apple devices

Work in progress: native Perfect Dark for iPhone/iPad, based on
[rebelancap/perfect-dark-ios](https://github.com/rebelancap/perfect-dark-ios)
and [Dab's Mod](https://github.com/DabDavis/perfect-dark-dabs-mod).
Goldenpad provides the control/menu interaction reference.

No game assets are included. Supply Perfect Dark USA v1.1 locally. This project
is not affiliated with Rare, Microsoft, Nintendo, or 4J Studios.

## Development

Apple Silicon Mac with Xcode, command-line tools, CMake, Ninja, Python 3,
XcodeGen (validated tool inventory in [PROGRESS.md](PROGRESS.md)).

```sh
scripts/bootstrap-apple.sh
```

This fetches the pinned engine and dependencies and builds simulator/device
bundles plus a native Mac reference. Initial ANGLE acquisition is large;
allow tens of GiB and substantial build time. Sources and intermediate builds
are cached under ignored `work/` and `build/`. No sibling checkout is required.
The complete command is under validation; consult progress for proven steps.

```sh
scripts/validate-rom.py '/path/to/your/Perfect Dark.z64' \
  --stage work/gamedata/pd.ntsc-final.z64
scripts/run-oracle.sh -- --skip-intro
```

Validation preserves the original and can normalize byte-swapped copies.
Never commit ROMs, saves, extracted art, signing material, or gameplay captures.
Do not boot a second simulator while one is running.

Source revisions: `UPSTREAM_PIN`, `dependencies/pins.env`, and `PROGRESS.md`.
Original Apple shell history/docs are retained under `docs/upstream`; their
measurements are historical upstream evidence, not validation of this build.
The upstream vendor tree stays unmodified; engine changes go in `overlay/`.

## Acceptance

See [goal](docs/goal.md), [PRD](docs/prd.md), and [progress](PROGRESS.md).
Build success does not establish campaign completion or phone performance.
Public distribution is not yet authorized or qualified. Credits and third-party
notices are in [LICENSE](LICENSE).
