# Phase 0.5 — the ANGLE-Metal spike on the macOS oracle

What this answers: **does `port/fast3d/gfx_opengl.cpp`, unchanged in substance,
run on an OpenGL ES 3.0 context served by ANGLE's Metal backend, and does it
draw the same picture as the desktop-GL oracle?** That is the substrate iOS and
visionOS would use (neither has desktop GL; visionOS has no EAGL either), and
it is answered here on the Mac, where the oracle already exists (D-004) and a
seeded replay can be diffed frame for frame (M-001).

Everything below was run on 2026-09-12, upstream pin `bfea06186`, AppleClang
21.0.0 with the three D-005 parity flags, macOS 27.0 / Xcode 26.6, M-series Mac.

---

## 1. The ANGLE build

There is one ANGLE checkout in `~/dev` (`realrtcw-ios/work/angle`, ANGLE 2.1.1
`e25e8d8565f7`, 14 GB, with `work/depot_tools`; see its PROVENANCE). It had
iOS and visionOS slices only. A **macOS arm64 slice was added to that same
checkout** — no second checkout, nothing else in the tree touched — and a dated
note appended to `~/dev/realrtcw-ios/work/angle-PROVENANCE.md` saying so.

```sh
export PATH=~/dev/realrtcw-ios/work/depot_tools:$PATH
export DEPOT_TOOLS_UPDATE=0
cd ~/dev/realrtcw-ios/work/angle
mkdir -p out/mac-arm64 && cat > out/mac-arm64/args.gn <<'EOF'
target_os = "mac"
target_cpu = "arm64"
mac_deployment_target = "13.0"
is_debug = false
is_component_build = false
angle_enable_metal = true
angle_enable_gl = false
angle_enable_vulkan = false
angle_enable_d3d11 = false
angle_enable_null = false
angle_enable_swiftshader = false
angle_enable_essl = true
angle_enable_glsl = true
angle_assert_always_on = false
angle_build_tests = false
treat_warnings_as_errors = false
EOF
gn gen out/mac-arm64
ninja -C out/mac-arm64 libEGL libGLESv2      # ~7 minutes, 3004 steps
```

Products: `libEGL.dylib` (117 KB) and `libGLESv2.dylib` (15 MB), `platform
MACOS minos 13.0`. The gn args are the family's iOS/visionOS args with the
three target lines swapped (`~/dev/q2repro-ios/scripts/build-angle-ios.sh`,
`~/dev/realrtcw-ios/scripts/build-angle-visionos.sh`); no patching of ANGLE was
needed for macOS (the ES1-advertise patch that tree carries is inert for us —
we ask for an ES 3 config).

This repo references the slice **by symlink only**: `work/angle-mac ->
…/angle/out/mac-arm64`. Nothing is copied, and nothing ANGLE-shaped is
committed.

> Trap: the dylibs' install name is `./libEGL.dylib` — relative, not
> `@rpath`. The consumer symlinks both dylibs next to its binary (the run dir);
> an `-rpath` alone does not resolve them.

## 2. How the spike was built

From a **copy** of the vendored tree, never the tree itself:

```sh
cp -a vendor/dabs-mod build/spike-angle/src          # pristine tree untouched
cd build/spike-angle/src && patch -p1 --fuzz=0 < ../../../overlay/patches/0001-*.patch
# …then 0002…0007 in order (each was produced from this copy)

ln -sfn ~/dev/realrtcw-ios/work/angle/out/mac-arm64 work/angle-mac   # gitignored

PARITY="-I/opt/homebrew/include -ffp-contract=off -fno-builtin-sinf -fno-builtin-cosf"
cmake -S build/spike-angle/src -B build/spike-angle/build -G Ninja \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
  -DCMAKE_C_FLAGS="$PARITY" -DCMAKE_CXX_FLAGS="$PARITY" -DCMAKE_OBJCXX_FLAGS="$PARITY" \
  -DPD_GL_ANGLE=ON \
  -DPD_ANGLE_DIR=$PWD/work/angle-mac \
  -DPD_ANGLE_INCLUDE_DIR=$HOME/dev/realrtcw-ios/work/angle/include \
  -DPD_ANGLE_GLUE=$PWD/app/gfx/gfx_angle_egl.mm
cmake --build build/spike-angle/build -j10
ln -sf $PWD/work/angle-mac/lib{EGL,GLESv2}.dylib build/spike-angle/build/   # install-name trap
```

`build/spike-angle/build-nativegl` is the **same patched source with
PD_GL_ANGLE off**, built to prove the overlay changes nothing for the desktop
(§5).

## 3. The patches

`overlay/patches/`, numbered after the existing 0001; each applies with
`patch -p1 --fuzz=0` against `vendor/dabs-mod` at the pin, in order.

| # | file | what |
|---|---|---|
| 0002 | `CMakeLists.txt` | `PD_GL_ANGLE` option: asserts `PD_ANGLE_DIR` / `PD_ANGLE_INCLUDE_DIR` / `PD_ANGLE_GLUE`, links libEGL/libGLESv2 + QuartzCore/Metal/Foundation, turns off the system GL library, compiles the glue as ObjC++. Off by default; `if(NOT GL_LIBRARY)` → `if(NOT DEFINED GL_LIBRARY)` is the only change to the OFF path. |
| 0003 | `port/fast3d/gfx_sdl2.cpp` | Under PD_GL_ANGLE: window gets `SDL_WINDOW_METAL` instead of `SDL_WINDOW_OPENGL`, the GL-version ladder (`gfx_sdl2.cpp:148-197`) is skipped whole, and context/present/swap-interval/drawable-size/resize go through the glue. SDL keeps the window, the events and the frame limiter. |
| 0004 | `port/fast3d/gfx_opengl.cpp:1035-1043` | Audit **P1**: `gladLoadGLES2Loader` (not the desktop loader), `gl_es = true` known rather than asked of SDL (which never made the context), proc addresses from `eglGetProcAddress`. |
| 0005 | `gfx_opengl.cpp:254-256, 342-344` | Audit **P2/P3**: `precision highp float;` in both generated shaders instead of `mediump` (fp16 on Apple GPUs). |
| 0006 | `gfx_opengl.cpp:1618-1638` | Audit **P4**: `glReadPixels(GL_RGB)` is illegal in ES 3.0 — read RGBA into a scratch buffer and pack to RGB. Without it `--screenshot-frame` and F12 return false and there is no evidence to diff. |
| 0007 | `gfx_opengl.cpp:1125-1347` | The colour grade pass (Vivid Colours / Black Level) on ES: version line taken from `gl_glsl_version_str` instead of a hard-coded `#version 130`, `precision highp float;` under ES, `glBindFragDataLocation` skipped under ES, and the restore at the end no longer sets `GL_BACK` as the read buffer of a bound FBO (illegal on ES, silently tolerated on desktop). |

Audit items **P5** (guard anisotropy on the extension) and **P6** (guard the
MSAA blit rect) were *not* needed: nothing in the runs below produced a GL
error from either, ANGLE-Metal exposes `EXT_texture_filter_anisotropic`, and
`gfx_pc.cpp` always passes matching rects. **P7** (the `current_framebuffer`
index-for-name bug at `:1514`) is real but latent and substrate-independent —
left for an upstream-facing patch rather than mixed into the ANGLE series.

The glue itself is additive and lives outside the vendored tree, per ground
rule 1: **`app/gfx/gfx_angle_egl.mm`**, ~170 lines —
`SDL_Metal_CreateView` → `SDL_Metal_GetLayer` → `CAMetalLayer*` →
`eglGetPlatformDisplayEXT(EGL_PLATFORM_ANGLE_ANGLE, {TYPE_METAL_ANGLE})` →
ES 3.0 context → `eglCreateWindowSurface` on the layer → `eglSwapBuffers` /
`eglSwapInterval` / `eglGetProcAddress`. Shape copied from
`realrtcw-ios/app/Sources/ios_egl.m` and `dhewm3-ios/app/ios/ios_angle.mm`,
ported from SDL3 to SDL2.

## 4. Results

All runs: `Video.VSync=0`, `AllowHiDpi=0`, 1280x720 windowed, own `--savedir`
per scenario (docs/oracle.md traps), `--rng-seed 1234 --fixed-step`.
`scripts/replay-diff.sh` now takes `--a/--b` (gcc | clang | **angle**) and
`--ini`, and `scripts/run-oracle.sh` takes `--angle`, `--savedir`, `--ini`.

**It reaches the title screen.** `SDL: created GL3.0es context through ANGLE
(Google Inc. (Apple))`, `GL: using GLSL version 300 es`, and the frame-300
title screenshot is **pixel-identical** to the clang oracle's at 1280x720.

**The M-001 regression set, clang oracle vs the ANGLE build:**

| scenario | gfx lines | gfx md5 (both) | screenshot at frame 1500 |
|---|---|---|---|
| `chicago-solo` (0x1d) | 8008 identical | `d55656c1…` (= M-001) | 25 544/921 600 px differ (2.8%), max delta **11** |
| `mp-skedar-8` (0x32, 8 sims) | 8008 identical | `4c29c269…` (= M-001) | **pixel-identical** |
| `mp-skedar-80` (0x32, 80 sims) | 8008 identical | `5948c85c…` (= M-001) | **pixel-identical** |

Every `gfx:` line matches line for line and the md5s equal the ones M-001
recorded for the compiler-parity run — the display-list interpreter is
untouched by the substrate, as it should be, and the ANGLE build is playing
exactly the same game.

**The XBLA pair** (`--boot-stage 0x1d`, frame 600, all five `Mod.Xbla*` on, the
4096-wide records the audit worried about): the release loads from the player's
`.rar` under ANGLE with patch 0001 doing its job (`xblamesh: 2616 slots`,
`xblatex: 5747 texture records`, `xblastage: … 106 rooms`), the gfx stream is
**identical** to the oracle's (`0756ab49…`, 58 draws / 2880 tris / 8035 verts
at the comparison frame, matching M-003), and the screenshot differs on
215 045/921 600 px (23.3%) — but **99.0% of those differ by ≤4/255**, 0.94% by
more, max delta 32. Amplified ×20 the difference is a faint speckle over
textured surfaces and along alpha-tested edges (the chain-link fence, character
silhouettes, the XBLA signage), with no structural difference anywhere: same
geometry, same colours, same text.

Turning anisotropy and mipmap filtering off on both sides does **not** remove
the difference (`chicago-solo` then differs on 35 353 px, same max delta 11),
so it is not the sampler's aniso/mip path. The most likely source is the
per-pixel dither/noise hash (`gfx_opengl.cpp:399-402`, `fract(sin(dot(...)))`
of `gl_FragCoord`) evaluating differently on Metal than on Apple's desktop GL
compiler, plus bilinear rounding at texel edges. Stated as a hypothesis, not a
measurement — it was not bisected.

**Vivid Colours / Black Level.** The grade pass **runs on ANGLE-Metal** with
patch 0007 (`VividColours=2 BlackLevel=2`, Chicago frame 600: no warning in the
log and a visibly graded frame — deeper blacks, stronger colour).

And a finding that was not the question: on the **stock** oracle that pass has
never worked on this Mac. macOS gives the port a GL **4.1 core** context, the
pass hard-codes `#version 130`, and the log says
`colour grade shader would not compile: version '130' is not supported` →
`Vivid Colours needs desktop GL 3.0, off`. Patch 0007 takes the version line
from the renderer, which fixes the macOS desktop path too: the same test on
`build-nativegl` (patched source, desktop GL) compiles and grades. So 0007 is
not an ES port of a working feature, it is the fix for a feature that is dead
on **both** Apple substrates upstream. Worth sending to Dab.

## 5. The overlay does not disturb the desktop

`build/spike-angle/build-nativegl` — the patched source, PD_GL_ANGLE off,
desktop GL 4.1 core — run on `chicago-solo`: **8008 gfx lines, md5
`d55656c15952650f757839ead3e075ee`, screenshot pixel-identical to the stock
clang oracle's.** The seven patches are a no-op for the oracle.

## 6. Q-001 — is there a throughput instrument here?

No, and the reason is now known and is not the substrate.

The glue takes `PD_ANGLE_SURFACE=pbuffer`, which builds the ES 3.0 context on an
off-screen `eglCreatePbufferSurface` instead of the window's `CAMetalLayer`:
a genuinely window-less GL path on macOS, which `SDL_VIDEODRIVER=offscreen`
could not give (D-006). It runs the whole game — same gfx stream md5 as the
windowed ANGLE run — and `--screenshot-frame` still works through it.

`mp-skedar-80`, 1200 fixed-step frames, `VSync=0 FramerateLimit=0`:

| build | present path | p50 fps |
|---|---|---|
| clang oracle | desktop GL, window | 117.2 |
| ANGLE | Metal layer, `eglSwapInterval(0)` | 116.8 |
| ANGLE | **pbuffer, nothing presented** | 117.2 |

and `chicago-solo` (a fifth of the triangles) through the pbuffer is **117.2**
as well. With no compositor in the loop at all the number does not move, so
M-002's reading — "the macOS compositor presents at the panel refresh" — is
**not** the cause: something else pins the loop at ~117 whatever the substrate,
the resolution, the workload or the present path.

It is not the frame limiter either, at least not simply. Through the same
pbuffer path, `chicago-solo`:

| `Video.FramerateLimit` | p50 fps |
|---|---|
| 30 | **30.0** (exactly — the limiter works) |
| 240 | 113.8 |
| 0 (which `video.c:713-716` turns into `VIDEO_MAX_FPS` = 240) | 117.2 |

So the limiter obeys a low target and the ~117 ceiling stands whether the
target is 120's worth of pacing or none at all. The remaining candidates are
the port's own per-frame overhead (`sync_framerate_with_timer`'s sleep plus
busy-wait) and the `-Og` decomp's real tick cost; they were not separated here,
and the workload-independence (a 385-triangle title screen and an 80-simulant
match both land on 117) argues against "real work" being the whole answer.

**What the spike does deliver for Q-001**: a window-less, present-free GL path
on macOS that runs the real game and still takes screenshots — the thing
`SDL_VIDEODRIVER=offscreen` could not give (D-006). Whether it becomes a
throughput instrument depends on finding the ~117 ceiling, which is now a
bounded question and not a substrate question. Recorded as M-006; Q-001's
default (a) still stands for this round.

## 7. What remains

- The spike proves ES 3.0 + ANGLE-Metal on **macOS**. It does not prove the
  iOS/visionOS slices, the app shell, or the iOS window/layer lifecycle; that
  is Phase 1 work with the same glue file (the iOS/visionOS slices are already
  on disk).
- The §1.6 hazard of the audit — ANGLE's unbounded command-buffer growth when
  `eglSwapBuffers` is skipped in a CompositorServices stereo path — is
  untouched by this spike and remains the largest known risk for Phase 6.
- The small pixel differences (§4) were not bisected to a cause. If Phase 2
  ever needs bit-exactness against the oracle rather than "the same picture",
  that bisection is the work.
- P5/P6/P7 from the audit remain unwritten; P7 is a real upstream bug.
