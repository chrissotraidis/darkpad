# The macOS arm64 oracle — build, run, and the parity flags

Phase 0.2/0.3/0.4. The oracle is Dab's Mod built natively on this Mac and is
the thing every iOS/visionOS build is compared against. There are two of them
because upstream builds macOS with Homebrew gcc and iOS has no choice but
AppleClang — proving those two play the *same game* is what 0.3 is for.

Upstream's own notes are the authority for anything here that is upstream's:
`vendor/dabs-mod/CLAUDE.md`, `CLAUDE-notes/performance.md` (the seeded replay,
the bisection method), `CLAUDE-notes/xbla.md` (the release's art).

## Build

Deps (all Homebrew): `cmake`, `ninja`, `sdl2` (which resolves to
**`sdl2-compat` 2.32.72** — SDL2's API over SDL3; Homebrew no longer packages
real SDL2), `gcc` (16.2.0 here), python3. zlib and libcurl come from the macOS
SDK, so `PD_HAVE_CURL` is ON on the oracle. AppleClang is 21.0.0.

```sh
PARITY="-I/opt/homebrew/include -ffp-contract=off -fno-builtin-sinf -fno-builtin-cosf"

# gcc oracle (what upstream ships)
CC=/opt/homebrew/bin/gcc-16 CXX=/opt/homebrew/bin/g++-16 \
cmake -S vendor/dabs-mod -B build/oracle-gcc -G Ninja \
      -DCMAKE_BUILD_TYPE=RelWithDebInfo \
      -DCMAKE_C_FLAGS="$PARITY" -DCMAKE_CXX_FLAGS="$PARITY"
cmake --build build/oracle-gcc -j10

# clang oracle (the parity reference — D-004)
cmake -S vendor/dabs-mod -B build/oracle-clang -G Ninja \
      -DCMAKE_BUILD_TYPE=RelWithDebInfo \
      -DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
      -DCMAKE_C_FLAGS="$PARITY" -DCMAKE_CXX_FLAGS="$PARITY"
cmake --build build/oracle-clang -j10
```

No source change was needed for either compiler: **nothing in `overlay/` is
applied to these builds** (the one patch there, 0001, is the XBLA scan depth
below and is not needed to build or to replay). Both binaries are `pd.arm64`, `RelWithDebInfo`,
`PD_HOT_O2=ON`, decomp at `-Og`, fast3d at `-O2 -finline-functions` — upstream's
defaults untouched.

### The three flags, and why

- **`-I/opt/homebrew/include`** — CMake's `FindSDL2` sets `SDL2_INCLUDE_DIR` to
  `/opt/homebrew/include/SDL2`, but the port mixes `#include <SDL.h>` and
  `#include <SDL2/SDL.h>`, and the second form needs the *parent* on the search
  path. Affects **both** compilers; neither searches `/opt/homebrew/include` by
  default. Not a portability problem in the source — a Homebrew-prefix gap.
- **`-fno-builtin-sinf -fno-builtin-cosf`** — upstream's own trap in its Darwin
  form. The game **defines** `sinf`/`cosf` (N64 tables, `src/lib/modelasm_c.c`)
  and upstream defines `sincosf` beside them so GCC's sin/cos fusion stays on
  the game's tables. AppleClang fuses to **`__sincosf_stret`**, Apple's
  struct-returning variant, which upstream's `sincosf` does not catch: it
  resolves to libsystem_m and differs in the last bits.
  `nm -u build/oracle-clang/pd.arm64 | grep sincos` is the one-line check.
- **`-ffp-contract=off`** — gcc and clang both contract `a*b+c` into `fma` on
  arm64 by default, and they do it in *different places* (160 FMA sites in the
  gcc binary, 3010 in the clang one). That alone moved the course of an
  80-simulant match. Off on both, they agree.

With all three, gcc and clang produce byte-identical replays (M-001). Anything
less does not: see MEASUREMENTS M-001 for what each flag was worth.

## Run

```sh
scripts/run-oracle.sh [--gcc|--clang] [--timeout N] -- <game flags...>
scripts/replay-diff.sh <label> -- <game flags...>     # both oracles, then diff
```

Each build dir *is* its run dir: `data/pd.ntsc-final.z64` is a symlink into
`work/gamedata/`, `pdsave/` holds `pd.ini` + eeprom, `screenshots/` and `xbla/`
sit beside the binary (upstream's `fsChooseOutputDir()` layout).

### Traps earned here (2026-09-12)

- **`SDL_VIDEODRIVER=offscreen` does not work on macOS.** It has no GL, so the
  game dies with "Could not open SDL window with an OpenGL context of any
  supported version". Upstream's headless recipe is Mesa-on-Linux only. Runs
  here open a real 1280x720 window; that is fine and no simulator is involved.
- **`Video.VSync=0` in `pdsave/pd.ini` is mandatory for any scripted run.**
  SDL's macOS swap-interval path waits on a CVDisplayLink condition inside
  `Cocoa_GL_SwapWindow`, and a window that is not frontmost is never signalled —
  the process blocks there for ever having drawn one frame. `sample` shows
  `videoSubmitCommands → Cocoa_GL_SwapWindow → SDL_WaitConditionTimeoutNS`.
  `scripts/run-oracle.sh` writes the ini if it is missing.
- **There is no `timeout(1)` on this Mac** (no coreutils). The scripts carry
  their own watchdog.
- **macOS GL is 4.1 core.** The GL3.0 (compat) row fails and the port falls to
  a core profile, logging a wall of "could not find function: glVertexP2ui"
  style errors for compat-only entry points. Harmless — glad reports every
  name it could not resolve — but it is what the log looks like when healthy.
- `pd.ini` lives in the **save dir** (`CONFIG_PATH` = `$S/pd.ini`), not beside
  the binary, when `--savedir` is given.

## The regression set

M-001 in MEASUREMENTS.md. Three scenarios, all `--rng-seed 1234 --fixed-step
--exit-frame 2000 --screenshot-frame 1500 --skip-intro --no-sound --gfxstats 1`:

| label | flags |
|-------|-------|
| `chicago-solo` | `--boot-stage 0x1d` |
| `mp-skedar-8` | `--boot-stage 0x32 --mpsims 8 --endless` |
| `mp-skedar-80` | `--boot-stage 0x32 --mpsims 80 --endless` |

Chicago (0x1d) is upstream's solo test bed; 0x32 is Skedar (MP), the stage
upstream's own 80-simulant measurements use. `--endless` keeps the match from
ending into the Save Player dialog (performance.md).

What the diff means, in upstream's terms: the **vertex counts** of the
`gfx: N draws` lines are the divergence signal (draw counts carry a ±1 HUD
element), and a `--screenshot-frame` pixel diff is what catches a renderer
change that the counters cannot see.

## The XBLA release on the oracle

The player's copy goes in `xbla/` beside the binary — the archive as it came,
the bare STFS package, or a folder holding either (upstream's xbla.md). It is
unpacked **once** into `cache/xbla/` (248 MB, ~30 s here).

```sh
cp "work/gamedata/Perfect Dark.rar" build/oracle-clang/xbla/     # or symlink it
# then turn the five parts on in the run dir's pd.ini, under [Mod]:
#   XblaMeshes=1 XblaMeshTextures=1 XblaStages=1 XblaFont=1 XblaExplosions=1
# (shipped defaults are meshes OFF and the other four on; F6 in-game is the
#  whole-release toggle, xbla.md "The whole release from one key")
scripts/run-oracle.sh --clang -- --skip-intro --no-sound --log --boot-stage 0x1d
```

Healthy log lines: `xbla: using <path>`, then `xblamesh: 2616 slots`,
`xblatex: 5747 texture records`, `xblastage: bgdata/bg_pete.seg from the
release: 352590 bytes, 106 rooms`. Compare the same seeded frame with the five
flags off: 477 triangles becomes 2880 (M-003).

### The `.rar` IS accepted — and then the package is not found

`archiveIsSupported()` takes `.rar` alongside `.7z`/`.zip`/`.pk3`, and the
unpack of the user's copy works. But that archive stores the package four names
deep (`Perfect Dark/584109C2/000D0000/<content id>`) and
`XBLAIMPORT_SCAN_DEPTH` is **2**, so the scan after the unpack fails with
"xbla: no Xbox 360 package inside ...", latches `unpackFailed`, never writes
the `.extracted` marker, and re-unpacks the same 248 MB on every boot.

`overlay/patches/0001-xbla-import-scan-depth.patch` raises it to 4. Until the
overlay is wired up (Phase 1) the workaround is to flatten the cache by hand:

```sh
cd build/oracle-clang/cache/xbla
mv "Perfect Dark/584109C2/000D0000/"* . && rm -rf "Perfect Dark" && touch .extracted
```

No repack to `.7z` is needed — the `.rar` itself is fine, the depth is the bug.
