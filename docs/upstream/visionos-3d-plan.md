# Phase 6 plan — visionOS 3D stereo mode with foveated rendering (2026-09-17)

the user, 2026-09-17: *"Let's start on the visionOS 3D stereo mode. Follow what we
did exactly with all the settings and parked window, etc."* This is the FAMILY
recipe (vkQuake → quake3e → q2repro → SoH → sm64coopdx) applied to THIS engine
(Fast3D interpreter, `gfx_pc.cpp`) on THIS substrate (ANGLE-Metal ES 3.0,
D-008). Nothing here is a new design; every choice below cites the sibling
that already shipped it. Written to be executed one milestone
at a time. Line numbers are against the current vendor pin unless stated.

Uncommitted companion: `docs/visionos-3d-plan-decisions.md` (draft D-047…D-053
for the orchestrator to merge into DECISIONS.md).

## 0. Sources this plan is built from (read the cited section before touching the area)

| Topic | Authority |
|---|---|
| Foveation, five steps, two traps, sim caveat | `~/dev/VISIONOS-FOVEATION-GUIDE.md` (whole file) |
| Fast3D stereo: projection fold at the MP product, both eyes in `gfx_run`, eye-render counter | `~/dev/sm64coopdx-ios/docs/frame-map.md` §"Matrices — where Phase 2 injects", §"Two rates"; `overlay/patches/0011-visionos-stereo3d.patch` hunks `@@ -657` (gfx_stereo_projection), `@@ -705`, `@@ -713`, `@@ -2100` (gfx_run); `0012-visionos-3d-frame-limiter.patch` |
| The compositor loop, panel placement, recenter, eye-copy, dim layer, alpha=1 | `~/dev/sm64coopdx-ios/app/vision3d/sm64_immersive.m` :615-971 (loop), :221-242 (anchor), :369-410 (shaders), :580-613 (pacing) |
| SwiftUI entry over an SDL2/ObjC engine; run-loop-timer boot | `~/dev/sm64coopdx-ios/app/vision3d/SM64VisionApp.swift` :112-151 (config), :259-286 (mode switch), :301-377 (App); `sm64_vision_host.m` :1-40, :510-557 (enter/exit), :632-693 (park/finalize), :709-769 (boot) |
| ANGLE → app-owned MTLTexture (the real "ANGLE fixes") | `~/dev/q2repro-ios/docs/visionos-3d-plan.md` :63-110; `app/Sources/immersive/xr3_glue.m` :433-470 (`xr3_wrap`), :2024-2060 (`BeginEye` in-flight gate), :2126-2265 (`EndFrame` publish) |
| Producer backpressure (frames in flight ≤ 2, ring 3, new-pair gate) | `~/dev/q2repro-ios/FOVEATION-PERF-CONSULT.md` :65-98 |
| Settings sheet rows/defaults, parked card, dimming curve, sheet traps | `~/dev/q2repro-ios/SETTINGS-SPEC-FROM-VKQUAKE.md` :13-97; shipped list `VisionShell.swift` :1137-1176 |
| FPS-specific stereo: viewmodel, 2D flush at the eye boundary, gamma in the panel, alpha | `~/dev/quake3e-ios/DECISIONS.md` D-022, D-023, D-027, D-028 |
| Sim vs device lies; bug ledger; parked-window ENTER/EXIT order | `~/dev/harbourmasters/VISION-PRO-LUS-PLAYBOOK.md` §2.8, §2.12, §2.13, §2.1a |
| SDL scene-delegate hijack (persisted sessions) | `~/dev/q2repro-ios/NOTES-FROM-VKQUAKE.md` :15-45 |
| One app, one bundle id, every difference behind `TARGET_OS_VISION` | GoldenEye D-024; this repo D-025 |
| This engine's renderer facts | `vendor/dabs-mod/port/fast3d/gfx_pc.cpp` (cited inline below); `docs/frame-map.md` §"Render path"; upstream `CLAUDE-notes/performance.md` :51-127 |
| This port's shell facts | `app/gfx/gfx_angle_egl.mm`, `app/ios/PDPacing.m`, `docs/pacing.md`, D-038/D-040/D-045, `docs/build.md` §"Traps earned (visionOS)" |

GoldenEye has NO shipped 3D mode (documentation only) — it is a lifecycle
precedent (D-024), not a stereo one.

## 1. What this engine and substrate actually give us (facts, not assumptions)

**Renderer (gfx_pc.cpp).**
- No view matrix and no ortho path. State is `P_matrix` + an 11-deep
  modelview stack (:160-164). MP is formed at exactly two sites:
  `gfx_sp_matrix` :1842 and `gfx_sp_pop_matrix` :1850-1851. Row-vector
  convention (`gfx_sp_load_vertex` :1879-1893: `v * MP`, row 3 = translation,
  columns = x/y/z/w) — identical to sm64's, so the sm64 fold transfers verbatim.
- **All 2D is matrix-free.** HUD, menus, text, fades go through
  `gfx_draw_rectangle` :3265-3340, which writes NDC directly with `z=-1, w=1`
  and never reads MP. Therefore 2D lands at identical NDC in both eyes = **zero
  disparity = on the panel plane, for free.** No ortho predicate is needed
  (sm64 needed one because SM64's HUD is an ortho projection).
- The game loads P freshly every frame from `src/lib/vi.c`: world
  `vi0000ad5c` :594-618 (`guPerspectiveF`, `G_MTX_LOAD|G_MTX_PROJECTION` :610),
  **gun** `vi0000aca4` :558-571 (own projection, **znear 1.5, zfar 1000**) and
  `viSetPerspectiveWithFov` :580-592 (COD-aim zoom, same near/far), teleport
  `vi0000b0e8` :645-659, **sky** `vi0000ab78` :527-556 (P = world→screen
  ROTATION × perspective, MV = identity — the view basis is folded into P for
  the sky only). Everything else folds the view into the modelview on the game
  side (`camGetWorldToScreenMtxf`), sm64-like in effect.
- Frame: `gfx_run` :4015-4070 = `start_frame` → `update_framebuffer_parameters(0,…)`
  :4027 → `start_draw_to_framebuffer(game_fb or 0)` :4031 → `clear` :4033 →
  `gfx_run_dl` :4038 → MSAA resolve to fb 0 :4042-4059 → `end_frame` :4061
  (**the Vivid Colours/Black Level grade pass runs here**, gfx_opengl.cpp:1349) →
  `gfx_pre_swap_callback` :4065 (screenshot readback of fb 0) → `swap_buffers_begin`
  :4069 (iOS: `pdIosPacingWaitForPresent` + `pdAngleSwapBuffers`, patch 0016).
- 44-entry `GfxRenderingAPI`: framebuffers with MSAA + resolve, filter modes,
  `read_screen_pixels`, capture (dead on iOS). **No depth read-back exists**
  (`get_pixel_depth`/`read_framebuffer_to_cpu` do not exist in this tree) — the
  charter's "depth extraction" item is a non-item.
- XBLA meshes are ordinary F3D in the same DL (`docs/frame-map.md` §"Where the
  XBLA art enters") — no special case, as the charter predicted.
- Upstream's cost profile: the interpreter is ~50-60 % of the main thread
  (`performance.md` :51-127). Two eyes = two `gfx_run_dl` walks per frame, so the
  CPU side roughly doubles for the render half. This is the perf risk (§7).

**Substrate (ANGLE xrOS slices, verified by `strings` on
`work/angle-visionos-{device,simulator}/libGLESv2.framework/libGLESv2`).**
Present: `EGL_ANGLE_metal_texture_client_buffer`, `EGL_ANGLE_device_metal`,
`EGL_ANGLE_metal_shared_event_sync`, `EGL_KHR_image_base`, `GL_OES_EGL_image`,
`EGL_KHR_fence_sync`, `EGL_KHR_wait_sync`, `EGL_ANGLE_iosurface_client_buffer`.
Header: `work/angle-include/EGL/eglext_angle.h:256-260` (`EGL_METAL_TEXTURE_ANGLE 0x34A7`).
q2repro's finding (plan :81-88): `eglCreatePbufferFromClientBuffer` REJECTS
`EGL_METAL_TEXTURE_ANGLE`; the working route is
`eglCreateImageKHR(dpy, EGL_NO_CONTEXT, EGL_METAL_TEXTURE_ANGLE, (EGLClientBuffer)mtlTex, NULL)`
→ `glEGLImageTargetTexture2DOES` → FBO colour attachment; the texture MUST be on
ANGLE's own `MTLDevice` (on visionOS ANGLE uses `MTLCreateSystemDefaultDevice()`,
which is the compositor's device). ANGLE's only backpressure is `eglSwapBuffers`,
which 3D skips — so frames in flight must be bounded by us (§2.6).

**Shell.** The game thread IS the main thread; `PDPacing` waits by running the
main run loop (D-045); the wait sits at the top of the frame (D-040,
`pdIosPacingWaitAtFrameStart` from pdsched.c). The visionOS target already
builds and gates green (`scripts/vision-validate.sh`, bridge :8785). Entry is
`pd_ios_main.m main()` → `SDL_UIKitRunApp(…, pdSDLMain)`; scene adoption is
`PDSceneDelegate` (named in `Info-visionos.plist` `UISceneConfigurations`) whose
graft finds SDL's sceneless window through `pdAngleGetHostView()` (D-038).
`PDController.m:107` already claims the pad with `GCEventInteraction`.

## 2. Architecture

### 2.1 App entry on visionOS: SwiftUI `@main`, engine booted from a host VC

An `ImmersiveSpace` can only be declared by a SwiftUI `App`
(quake3e D-019; sm64 `sm64_vision_host.m:1-7`). So, **visionOS target only**:

- New `app/vision3d/PDVisionApp.swift`: `@main struct PDVisionApp: App` with
  `WindowGroup { PDRootView() }` and
  `ImmersiveSpace(id: "PD-3D") { CompositorLayer(configuration: PDCompositorConfiguration()) { lr in Thread { pdImmersiveRun(lr) } (name "PD-Immersive", stackSize 2<<20) } }`
  `.immersionStyle(selection: .constant(.mixed), in: .mixed)` — **mixed only**;
  merely allowing `.progressive` changes the drawable contract and aborts
  `encode_present` (playbook §2.1, sm64 SM64VisionApp.swift:323-327).
  File must not be named `main.swift`.
- `PDRootView` hosts `PDHostViewController` via `UIViewControllerRepresentable`;
  owns `@Environment(\.openImmersiveSpace)/dismissImmersiveSpace` (valid only
  inside a View); bottom ornament
  `.ornament(attachmentAnchor: .scene(.bottom), contentAlignment: .top)` with
  "3D"/"Exit 3D" and a gear; `.sheet` presenting the settings VC (§2.10).
  `@_cdecl` bridges `PD_SetImmersiveMode(Bool)`, `PD_OpenSettingsSheet`, `PD_CloseSettingsSheet`.
- `PDHostViewController.viewDidAppear` boots the engine **via a run-loop timer**
  (`performSelector:afterDelay:0`), never `dispatch_async(main)` — booting a
  never-returning loop from a main-queue block holds the serial main queue for
  the life of the process and every SwiftUI effect silently dies
  (sm64 `sm64_vision_host.m:732-754`, M-38; playbook §1.3). It calls
  `SDL_SetMainReady()` then `pdSDLMain(argc, argv)` directly — everything
  `pd_ios_main.m main()` does before `SDL_UIKitRunApp` moves to a shared
  `pdShellPrepare(argc, argv)` (env roots, crash handler, beacon, watchdog,
  args file, SIGPIPE, lifecycle registration), called by iOS `main()` and by the
  host VC. `main()` itself is `#if !TARGET_OS_VISION`.
- Our D-045 run-loop wait is what keeps SwiftUI alive with the engine on the
  main thread: the main run loop turns for the whole slack of every frame.
  This is a strictly better position than sm64's (which relies on SDL's
  microsecond pump); keep it.
- **Scene manifest**: `Info-visionos.plist` keeps `UIApplicationSceneManifest`
  with `UIApplicationSupportsMultipleScenes=true` INSIDE it, and **drops
  `UISceneConfigurations`** (SwiftUI declares its own scenes; sm64
  `Info-visionos.plist:27-38`, q2repro gen-app-project.sh:301-321). The
  persisted-session trap (NOTES-FROM-VKQUAKE :15-45): UIKit persists
  (configuration name + delegate class) across installs of the same bundle id,
  so the user's headset, which has run Phase-5 builds, will try to restore a
  session pointing at `PDSceneDelegate`. Fix as the family did: on visionOS the
  class must not resolve — compile `PDSceneDelegate` out under `TARGET_OS_VISION`
  (its two jobs move: the graft to a platform-agnostic `pdGraftSDLWindows()` in
  `PDShell.m`, called from `pdIosFrameHook` on visionOS until the SDL window has
  a scene — sm64's retry-every-30-frames shape; the cold-launch deep link to
  SwiftUI `.onOpenURL`). Fresh sims never reproduce this; the device will.
- iOS target: untouched. `PD_VISION_3D` is defined only for the visionOS target
  (project.yml `GCC_PREPROCESSOR_DEFINITIONS`), and `app/vision3d/*` is listed
  only there. `SDL_UIKitRunApp` continues to own the iOS lifecycle.

### 2.2 Eye render targets: ANGLE renders into app-owned MTLTextures

- `app/vision3d/PDEyeTargets.mm` (compiled with the ANGLE headers): a ring of
  **3 eye pairs** (q2repro consult item 2) of `MTLTexture` `bgra8Unorm`
  (`rgba8Unorm_srgb` if the grade pass survives sampling — decide in M2 by
  screenshot vs 2D), `usage RenderTarget|ShaderRead`, `storageMode Private`,
  each wrapped once (cache by pointer) with `eglCreateImageKHR(EGL_METAL_TEXTURE_ANGLE)`
  + `glEGLImageTargetTexture2DOES` + `glFramebufferTexture2D(COLOR0)`, plus ONE
  shared depth24/stencil8 renderbuffer sized to the eye (ANGLE-Metal refuses a
  separate stencil renderbuffer beside a depth TEXTURE — q2repro `xr3_make_depth`
  note; PD needs stencil? `gfx_sdl2` asks for depth24/stencil8, gfx_opengl's
  default-FB path assumes both — keep a renderbuffer for both and stay away from
  depth textures for fb 0). Size = §2.4 render target size, not the window.
- **The seam is "framebuffer 0"**: in `gfx_opengl.cpp` slot 0 is the default FB
  (GL name 0). New overlay patch (0031) makes slot 0's `fbo`, `width`, `height`
  overridable: `pdVisionEyeFBO(&fbo,&w,&h)` returns non-zero while 3D is on and
  the backend uses it at `start_draw_to_framebuffer(0)` :1464, in
  `update_framebuffer_parameters(0,…)` :1394 (do not re-size the default),
  `resolve_msaa_color_buffer(0, …)` :1502, `copy_framebuffer` :1539,
  `read_screen_pixels` :1618 and the grade pass :1273-1347 (its "default FB"
  blit source/target becomes the eye FBO — patch 0007 already reads
  `GL_COLOR_ATTACHMENT0` from a real FBO). Everything above the backend is
  untouched: `game_framebuffer` (MSAA) still resolves "to the screen", which is
  now the eye. **Result: the whole 2D path incl. MSAA + grade + screenshot works
  per eye unchanged.** This is the honest delta vs sm64 (no framebuffers there).
- Window size decoupling: `pdAngleGetDrawableSize()` (gfx_angle_egl.mm) returns
  the eye size while 3D is on, so `gfx_start_frame`'s `get_dimensions` :3939,
  `gfx_current_dimensions`, aspect and viewport all follow the panel, not the
  parked 480-pt card (SETTINGS-SPEC :72-86 "render resolution must be decoupled
  from the window first").
- **Never touch the window surface in 3D.** On entry
  `eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx)` (surfaceless — any
  stray draw to GL fb 0 then fails loudly instead of stalling on a hidden
  layer's `nextDrawable`, sm64 frame-map "load-bearing, not an optimisation");
  `pdAngleSwapBuffers()` becomes the eye PUBLISH (§2.6) instead of
  `eglSwapBuffers`. On exit, **first** re-bind the window surface
  (`eglMakeCurrent(dpy, s_surf, s_surf, ctx)`) — q2repro `VID_iOS_XR3_SetMode`
  OFF path: without it every swap after exit fails and the 2D window is frozen
  forever while audio plays.

### 2.3 Both eyes per host frame at the same game time

Overlay patch 0030 (`gfx_pc.cpp`, the sm64 0011 shape):

```
void gfx_run(Gfx *commands) {
    pdVision3dFramePoll();                 // main-thread shell hook (no dispatch)
    if (pdVision3dActive()) {
        pdVisionSetEye(PD_EYE_LEFT);  gfx_run_eye(commands);   // full :4017-4067 body incl. resolve+end_frame
        pdVisionSetEye(PD_EYE_RIGHT);
    }
    gfx_run_eye(commands);                 // caller's swap_buffers_begin/gfx_end_frame close the pair
}
```
`gfx_run_eye` = the current :4017-4067 body with `gfx_sp_reset()` at its top (the
DL reloads P/MV itself, vi.c). `gfx_wapi->start_frame()` is `return true`. The
`pdProf` rows from patch 0027 wrap the eye body, so `gfxdl` reads per-eye cost.
Eye-render counter `pd_eye_renders` (bridge `state`: `eye_renders=`), which must
equal `2 × frames` in 3D and `0` in 2D (sm64 D-030: three rates, one fact).

The seeded replay (`--fixed-step`) is the idempotence proof: running the DL
twice per frame must not change the game — each eye's `gfx: N draws` line must
equal the 2D line at the same frame. If it does not, something in `gfx_run_dl`
has frame-level side effects and must be found before M3 closes.

### 2.4 Per-eye projection: the fold, and PD's two special projections

`gfx_stereo_projection()` (patch 0030) replaces `rsp.P_matrix` at the two MP
sites :1842 and :1850 — NOT at the P load :1824/:1826 (a rewritten P would
compound on a later `G_MTX_MUL` — sm64 D-026). With half-separation `e`
(signed per eye) and convergence `C`, both in PD world units, and `a = P[0][0]`:

```
eyeP = P;
for i in 0..3: eyeP[3][i] = P[3][i] - e * P[0][i];   // eye offset folded (v*MV*T*P == v*MV*(T*P))
eyeP[2][0] += -a * e / C;                              // off-axis convergence skew
```

PD-specific classification of the incoming P (no ortho, so every P is
perspective — the sm64 `P[3][3] > 0.5` gate is dead here; classify instead):
1. **Pure perspective** (`P[0][1]==P[0][2]==P[1][0]==P[1][2]==P[2][1]==0`, the
   guPerspectiveF shape): full fold above. World, teleport.
2. **Sky** (`vi0000ab78`: rotation folded into P, off-diagonals non-zero):
   **skew only**, no translation — a translation folded before a rotated P would
   be a world-space shift (harbourmasters §2.13 "no depth / doubles… camera-basis
   fold"), and the sky is at 2×zfar where the correct disparity is the skew's
   infinity term anyway (sm64 `bg_layer` branch). Sentinels in `sky.c` are the
   fallback if the shape test proves ambiguous (sm64 used `G_NOOP` tags).
3. **Gun** (`znear == 1.5` recovered from the matrix: `n = P[3][2]/(P[2][2]-1)`,
   tolerance 1e-3; covers `vi0000aca4` and the COD-aim `viSetPerspectiveWithFov`):
   quake3e D-028 v2 — the weapon gets its own convergence `C_gun = znear` so it
   never pops out of the screen; a uniform screen-space shift was REJECTED on
   device (diplopia). No knob (upstream ioq3 parity). Keep a bridge-only
   `3d gunconv <units>` for the one A/B round, then remove it.

The widescreen adjust `gfx_adjust_x_for_aspect_ratio` :1857-1863 multiplies
clip x AFTER the fold; with `aspect_mode 0` its factor is 1 at the panel aspect.
In `G_ASPECT_WIDE_EXT` scenes the skew is scaled symmetrically for both eyes
(a slightly different effective C, still fusable). Verify in M3 with the L/R
diff; if visible, apply the skew after the adjust in `gfx_sp_load_vertex` :1896.

Units: `constants.h:496` — `vv_eyeheight` ≈ 160 for a 1.6-1.7 m Joanna, so
**1 PD unit ≈ 1 cm** (the same scale sm64 has). Defaults: half-sep `e0 = 3.15`
(IPD 63 mm) at "Stereo Depth 100 %"; convergence ("Crosshair Distance")
default **610 units = 20 ft = 6.1 m** (the vkQuake/q2repro default). Slider
semantics per SETTINGS-SPEC :45-84.

`cp_drawable_compute_projection` does NOT enter gfx_pc. As in every shipped
panel port (q2repro VisionShell.swift:1810-1814, sm64_immersive.m:917-925) it is
the projection of the **panel quad** in the compositor pass; the engine's
stereo comes from the fold. (`cp_view_get_tangents` aborts under mixed
immersion — never call it.)

### 2.5 Compositor pass (`app/vision3d/PDImmersive.m`, ported from `sm64_immersive.m`)

Loop per frame, exact order (sm64 :647-966; quake3e D-019; playbook §2.3):
`cp_layer_renderer_get_state` (paused → `wait_until_running`; invalidated →
notify shell, exit) → `query_next_frame` → `predict_timing` → `start_update`/
`end_update` → `cp_time_wait_until(optimal_input_time)` → **signal the engine
pacer (§2.6)** → `start_submission` → `cp_frame_query_drawable` (**NULL →
`continue` WITHOUT `end_submission`, which aborts**) → device anchor from ARKit
`ar_world_tracking_provider_query_device_anchor_at_timestamp(presentation_time)`
→ `cp_drawable_set_device_anchor` → per view: `cp_view_get_view_texture_map` →
texture index / slice / viewport; colour attachment cleared to (0,0,0,0)
(passthrough), depth cleared 1.0 and **stored** (the compositor reprojects on
depth and silently rejects frames without it — q2repro plan :64-68);
`rasterizationRateMap` from `cp_drawable_get_rasterization_rate_map(drawable, texIdx)`
when count>0; `[enc setViewport:vp]`; dim triangle (black, alpha
`1-(1-d)^2.2`, z 0.9999, under the panel) then the panel quad; `mvp = proj(compute_projection, right_up_back, v) * inverse(originFromDevice * cp_view_get_transform) * model` → `encode_present`; commit; `end_submission`.

Panel = flat quad, **world-locked**: anchor computed from a head pose FROZEN
once, after ≥30 tracked frames (ARKit's first frames are near-identity and put
the panel on the floor — sm64 :717-736, quake3e D-019); `fwd.y = 0` (level),
`pos = head + fwd*dist; pos.y += height`, normal toward the head (auto-tilt as
it rises), scale `(halfW, halfH)`. **Recenter = clear the frozen anchor**;
re-anchor on every 3D entry. Recomputed every frame from the frozen head so
slider drags move the panel live.

Eye handoff: compositor waits (GPU, `encodeWaitForEvent`) on the published
pair's shared event, blits both eyes into ITS OWN persistent **mipmapped**
copies on its own queue, `generateMipmaps`, samples
`linear/linear, max_anisotropy 16`, **fragment forces alpha = 1** (quake3e
D-027: engine alpha residue ghosts the room through under premultiplied mixed
immersion). Aspect-fit (pillarbox black). No gamma in the panel: PD's grade
pass already ran on the eye FBO, unlike quake3e's blit-time gamma (D-028 §3).
`PD_VP3D_SHOWEYE=L|R` env forces which eye the mono simulator samples (the
sim has `views==1`), so left/right screenshots can be diffed on the sim.

### 2.6 Pacing in 3D: the compositor is the clock; frames in flight ≤ 2

`docs/pacing.md` rule ("exactly one pacer, one wait, one present") survives;
only the clock changes. `PDPacing` gains an EXTERNAL source: while 3D is on the
display link is paused and `pdPacingSignalExternal()` is called by the
immersive thread once per compositor frame right after `cp_time_wait_until`
(sm64 0012 hunk 2 + `sm64_3d_wait_for_compositor_frame`, M-51: a phase-locked
engine is what made "not buttery" go away; GoldenEye `docs/pacing.md:120` states
the same intent). The wait stays at the top of the frame (D-040) and still runs
the main run loop (D-045). Flag, not counter: a late engine drops signals,
never banks them. 50 ms timeout falls back to the link.

Backpressure (q2repro consult items 1-3, the vkQuake discipline): at
`EndFrame` (our publish) `eglCreateSync(EGL_SYNC_METAL_SHARED_EVENT_ANGLE)` +
`glFlush` + `eglCopyMetalSharedEventANGLE` → `(MTLSharedEvent, value)`; publish
`{ring slot, event, value, pair_gen++}` under a seqlock. Before eye L of the
next frame, wait while `inFlight >= 2` (completion via
`notifyListener:atValue:` decrements; bounded 200 ms self-heal with a loud
log). Eye ring 3 so the compositor's blit source is never the producer's
current target. Compositor blits only when `pair_gen` advanced (quake3e's
new-pair gate) — a reused pair is sampled from the persistent copies.
`Video.VSync`/`FramerateLimit` stay inert (patch 0016). Instruments in `state`:
`imm_frames`, `imm_hz` (optimal-input-time cadence, sm64 `SM64_CADENCE`),
`inflight`, `pair_fresh/pair_reuse`, `eye_renders`.

### 2.7 Audio
Unchanged engine path (game-thread `SDL_QueueAudio`). `PDAudio` already enforces
`.playback` and re-asserts on drift; add under `TARGET_OS_VISION`:
`setIntendedSpatialExperience: .headTracked(soundStageSize: .medium,
anchoringStrategy: .front)` on space open, `.automatic/.automatic` on exit,
**re-applied every ~3 s while immersive** (playbook §2.10 — SDL's session
reconfigure silently drops it; "audio from the parked window's direction").

### 2.8 Input
Pad is primary and already claimed (`PDController.m:107`, GoldenEye D-024
§2, quake3e D-020). PD's menus are pad-driven, so **the full menu system stays
usable in 3D with a pad**, rendered in the 2D pass at zero disparity — better
than the LUS ports' "exit to 2D for the deep menu". The touch/pinch overlay
(D-022 tap-to-select, D-046 aim drag) is hidden while immersive (a pinch on
the 480-pt parked card would drive a 480-pt overlay); no in-panel hit testing
exists in any shipped port (q2repro `xr_boot.m:37`). Exiting 3D restores it.
Menus by pinch = display-only in 3D (charter §Phase 6).

### 2.9 Mode switching, the parked window, and the curtain
ENTER (sm64 `sm64_3d_enter`, q2repro `enterSpace`, playbook §2.8): capture the
pre-3D scene size FIRST (explicit `parked` state flag, never a size heuristic);
apply all 3D settings; **engine offscreen first** (`pdVision3dSetActive(1)`:
surfaceless context, eye ring allocated, `eye_renders` starts) → curtain (black
UIView + "Playing in 3D" on the SDL window) → `openImmersiveSpace`; on `.error`
roll back to 2D. **Park the window ~1.5 s AFTER the space finished opening**
via `UIWindowSceneGeometryPreferencesVision` at 480 pt × panel aspect
("parking during the transition wedges a sibling animation"); the per-frame
graft tracker makes SDL's window follow the scene. Spatial audio on.
EXIT: `imm_stop=1`, wait for `imm_running` to clear (≤2 s, normally <30 ms);
**un-park BEFORE `dismissImmersiveSpace`** (q2repro: issued after, the request
raced the transition and was dropped on device — "stuck tiny window"; sim
transitions are too fast to show it); dismiss; `pdVision3dExitFinalize`: rebind
the window surface, `pdVision3dSetActive(0)`, wait ~0.6 s for the scene to
settle, drop the curtain, push a synthetic SDL size event so `gfx_start_frame`
re-reads the window drawable; audio `.automatic`. Crown/system dismissal →
`pdVision3dImmersiveEnded()` reconciles the same way and **saves pd.ini +
eeprom immediately** (a crown exit is often the first half of a swipe-kill).
`UISceneDidDisconnect` while 3D → `requestSceneSessionActivation` (losing the
only regular scene kills audio).

### 2.10 Settings sheet (the family list — taken from the spec, not invented)
`PDVisionSettingsViewController` (UITableViewController, inset grouped, bean
glyph conventions where they apply) hosted in the SwiftUI `.sheet`; a UIKit
modal presented directly silently fails over an open space. Sheet traps
(SETTINGS-SPEC :13-37): width-only `.frame(minWidth: 900)`, own header bar
(title, **Reset** as a bordered pill, **Done** borderedProminent), never force a
height. Persisted in `NSUserDefaults` under `vp3d.*` keys (playbook §2.2; PD
Defaults are already NSUserDefaults-as-truth); pushed live on every change and
on immersive entry. All lengths stored in metres; Units toggle reloads readouts.

| Row | Control | Range | Default | Effect |
|---|---|---|---|---|
| Screen Distance | slider | 1.0–8.0 m | 3.6 m | panel `dist` |
| Screen Width | slider (stored half 0.6–6.096, shown full) | 1.2–**12.192 m (40 ft)** | **6.096 m (20 ft)** | `halfW`; re-syncs eye size on release (D-062) |
| Screen Height | slider (stored half 0.5–3.0, shown full) | 1.0–6.0 m | **3.658 m (12 ft)** | `halfH`; re-sync on release |
| Screen Position Height | slider, signed readout | −1.5…+10.0 m | 0.0 | panel y offset; auto-tilt |
| Stereo Depth | slider | 0–**300 %** | **150 %** (= e 4.725 units) | half-separation `e` (D-061) |
| **Convergence** (was Crosshair Distance, D-064) | slider, shown as length | 100–1500 units | **762 (25 ft)** | convergence `C` (world depth on the panel plane, where the HUD lives — the RETICLE no longer does) |
| Surroundings Dimming | slider | 0–100 % | 80 % | dim triangle, `1-(1-d)^2.2` |
| Render Resolution | slider | 40–100 % of the panel-derived eye | 100 % (q2repro shipped 60 %; PD decides on device, M5) | eye target size (D-058; the budget is an AREA, D-062) |
| Panel Width / Height / Aspect | info | — | measured | eye px, `x:9` |
| FPS on Panel | switch | — | off | the game's own fps counter (`lv.c:1003`) — lands in the 2D pass, both eyes |
| Units | segmented m/ft | — | ft | readouts |
| Recenter Screen | button | — | — | clears the frozen anchor |

Not carried: a foveation toggle (retired everywhere — guide step 5, quake3e
D-028 directive, q2repro `xr_foveation` ignored); HUD Depth (removed in sm64
comfort batch 2; PD's HUD is on-panel by construction); Hide Weapon (no PD
cvar; quake3e default OFF anyway); Sharpening (q2repro-only, optional later).
`Reset` restores the table's defaults, keeps Units and FPS prefs.

### 2.11 Foveation (compositor pass only — the five steps, verbatim)
`PDCompositorConfiguration.makeConfiguration`: `colorFormat =
supportedColorFormats.first ?? .bgra8Unorm_srgb`, `depthFormat =
supportedDepthFormats.first ?? .depth32Float`, `isFoveationEnabled =
capabilities.supportsFoveation` (unconditional; a bring-up env gate
`PD_VP3D_FOVEATION=0` is removed after M5), **layout `.dedicated` when
foveation is on** (`.layered` + per-slice passes = right-eye fisheye, guide
trap 1), else `.layered` if available else `.dedicated`. **Never touch
`maxRenderQuality`** (aborts at entry on sim AND device, guide trap 2). Pass
targeting from the view texture map, rate map attached, viewport set — already
in §2.5. The fragment shader needs no change. Guide trap 3 is §2.6.

## 3. Honest delta list — what PD needs that sm64coopdx's 3D overlay did not

| Area | sm64coopdx 0011 | PD (this plan) |
|---|---|---|
| Render target | native Metal backend swaps `color_tex` for an eye `MTLTexture` | ANGLE: EGLImage-wrapped FBO, presented to the engine as **framebuffer slot 0** (backend patch 0031) |
| Framebuffers | none in gfx_pc (M-1) | `game_framebuffer` MSAA + `resolve_msaa_color_buffer(0,…)` + `copy_framebuffer` must all see the eye FBO as "0" |
| Post-process | none | grade pass (`gfx_opengl_end_frame`) runs on the eye FBO — must target it, and its result is what the panel samples (patch 0007 groundwork) |
| Screenshot/capture | none | `read_screen_pixels` on fb 0 = current eye (right); capture entry points dead on iOS (patch 0011) |
| Depth read-back | n/a | none exists in PD — non-item |
| 2D layer | ortho HUD needs the `P[3][3]` predicate branch | matrix-free NDC rects: zero disparity for free, no predicate |
| Sky | `G_NOOP` sentinels in skybox.c | P-shape classification (rotation folded into P) → skew-only |
| Viewmodel | none (third person) | gun P detected by `znear 1.5` → `C_gun = znear` (quake3e D-028 v2) |
| Eye handoff | shared `MTLTexture` pointer, pair_gen, no fence (sim serialises queues — playbook §2.12 says unsafe) | shared-event publish + GPU wait, ring 3, in-flight ≤ 2 (q2repro consult) |
| Pacing | 0012 phase-lock via cond var | external signal into `PDPacing` (D-040 top-of-frame + D-045 run-loop wait preserved) |
| Window surface | never acquire the drawable in 3D | same, via surfaceless `eglMakeCurrent`; rebind on exit (q2repro trap) |
| Entry | SwiftUI @main, renamed engine `main` | SwiftUI @main on visionOS only; `pdShellPrepare` split from `main()`; `PDSceneDelegate` compiled out on xrOS (stale-session trap) |
| Texture filter / aniso / XBLA meshes | n/a | no change: same DL, same cache, same backend calls |

## 4. Milestones (build order; each self-contained; sim artifact unless marked DEVICE)

The sim is MONO (`views==1`, `.layered`, `foveation=0`, drawable 3840×2160 —
sm64 VR-R0 §R0.1) and serialises Metal queues (playbook §2.12). It proves:
space opens/closes, engine renders into the eye FBO, panel shows content, park
→ restore cycle, L/R eye content differs by the fold, cadence relationship,
gates. It cannot prove: stereo fusion/IPD, foveation sharpness, the cross-queue
race, real cadence or fps. Every milestone ends with the lane shut down
(`xcrun simctl shutdown "$VISION_SIM"`); the Vision Pro
is shared with a concurrent publish agent — check `simctl list devices booted`
first and wait rather than collide.

Overlay numbering: 0030 gfx_pc stereo, 0031 gfx_opengl fb-0 redirect, 0032
gfx_sdl2/pacing external source (if not expressible in the .mm alone), 0033
sky sentinels (only if the P-shape test fails). New shell files under
`app/vision3d/` (`PDVisionApp.swift`, `PDHostViewController.m`, `PDImmersive.m`,
`PDEyeTargets.mm`, `PDVision3D.h`, `PDVisionSettingsViewController.m`,
`pd-vision-bridging.h`), listed only in the `perfectdark-visionos` target.

**M1 — SwiftUI entry + ImmersiveSpace skeleton, 2D still working** (~1 round)
- Files: `app/vision3d/PDVisionApp.swift`, `PDHostViewController.m`,
  `PDImmersive.m` (loop rendering a solid colour per view, depth stored,
  device anchor set), `pd_ios_main.m` (`pdShellPrepare` split, `main()` iOS-only),
  `PDShell.m` (`pdGraftSDLWindows` moved from `PDSceneDelegate`, called from the
  frame hook on visionOS), `PDSceneDelegate.m` (`#if !TARGET_OS_VISION`),
  `Info-visionos.plist` (drop `UISceneConfigurations`), `app/project.yml`
  (Swift sources, `SWIFT_OBJC_BRIDGING_HEADER`, `PD_VISION_3D`, CompositorServices
  + ARKit frameworks), `scripts/gen-app-project.sh` unchanged.
- Bridge: `3d on|off|state` (`imm_running`, `imm_frames`, `imm_hz`). Env
  `PD_VP3D_AUTOENTER=1` enters at frame 300 (the ornament needs a gaze-pinch
  the sim cannot inject — sm64 host `:361`).
- Accept: `vision-validate.sh` still green unchanged (2D intact under the
  SwiftUI entry, graft counted, touches/pad still reach the engine); `3d on` →
  `imm_frames` advancing ≥ 200 with no abort; `simctl io screenshot` of the room
  showing the coloured panel; `3d off` → window restored, `drawable == window
  px` re-asserted, post-exit bridge `screenshot` non-blank. Artifacts under
  `artifacts/sim/visionos-3d/m1/`. iOS gate untouched (`sim-validate.sh` not run;
  the iOS target's sources did not change — assert with `git diff --stat`).

**M2 — One eye: ANGLE renders into a wrapped MTLTexture, panel shows the game** (~1-2 rounds)
- Files: `PDEyeTargets.mm` (wrap per q2repro `xr3_wrap`), patch 0031 (fb-0
  redirect in gfx_opengl.cpp incl. grade pass and `read_screen_pixels`),
  `gfx_angle_egl.mm` (surfaceless in 3D, `pdAngleGetDrawableSize` override,
  swap → publish stub, rebind on exit), `PDImmersive.m` (blit → mipmapped copy
  → quad, alpha 1, dim layer).
- Accept: with `3d on`, bridge `screenshot` (which reads fb 0 = the eye) equals
  the 2D screenshot of the same scene at the same eye size within the gate's
  16/255, 6 % thresholds (grade pass proven live on the eye); room screenshot
  shows the game on the panel; `glCheckFramebufferStatus` complete logged once;
  `state` shows `acquire` p50 ≈ 0 (no drawable acquisition in 3D — D-040's row
  is the instrument); Enhance Textures/XBLA on → still draws (XBLA gate
  `--xbla` run once in 3D).

**M3 — Both eyes, the fold, gun and sky rules, world-locked panel** (~2 rounds)
- Files: patch 0030 (`gfx_run` → `gfx_run_eye`, `gfx_stereo_projection` with
  the three-way classification, `eye_renders`), `PDEyeTargets.mm` ring 3 +
  shared-event publish, `PDImmersive.m` pair gate + GPU wait, `PDPacing.m`
  external signal + in-flight gate, frozen-head anchor after 30 frames, recenter.
- Accept (sim): `eye_renders == 2 × frames` over a 5 s window in 3D and `0`
  after exit; seeded replay run with `3d on` (bridge `3d on` at frame 60 of a
  `--fixed-step --exit-frame` run) — the per-eye `gfx: N draws` lines equal the
  committed 1280×720 oracle stream (idempotence of the double DL walk);
  `PD_VP3D_SHOWEYE=L` vs `=R` screenshots at `Stereo Depth 100 %` differ (world
  shifts, HUD/reticle pixels identical — crop-diff the HUD region = 0), and at
  `0 %` are pixel-identical; a gun-heavy frame's L/R diff shows the gun
  uncrossed (behind-panel disparity sign) — record the sign convention in
  `docs/frame-map.md`. Cadence: `imm_hz ≈ pacing_presents_hz`, `inflight ≤ 2`
  always, `pair_reuse` small.
- DEVICE later (Q-020): stereo fusion at default, IPD sanity, gun comfort.

**M4 — Menus, HUD, mode-switch hardening, parked card, audio** (~1-2 rounds)
- Files: `PDHostViewController.m`/`PDVisionApp.swift` (park at +1.5 s, un-park
  before dismiss, finalize, crown-exit reconcile, scene-loss reactivation,
  curtain), `PDTouchOverlay` hidden while immersive, `PDAudio.m` spatial
  experience + 3 s re-apply, pd.ini/eeprom save on crown exit.
- Accept: park→3D→exit cycle ×3 via bridge with room screenshots at baseline /
  parked / post-exit and `drawable == window` after each (playbook §2.12 item 2 —
  the gate the LUS ports missed); pad `button` injection opens PD's pause menu
  in 3D and the L/R HUD crop-diff is still 0; `audio_category=playback`
  throughout; after `3d off` the 2D touch tap still lands (`ui_touches_began`
  climbs); an aborted exit (kill the app during 3D) leaves a pd.ini written
  within the last second (`stat`).

**M5 — Foveation + device numbers** (DEVICE, ~1 round + the user)
- Files: `PDCompositorConfiguration` (§2.11), env gate for the A/B, `xr3diag`-
  style one-shot contract log and a 5 s `xr3stat` line in `Documents/logs`.
- Sim: capability-guarded path enters/exits/re-enters cleanly (guide
  §Validation). Device (OTA `0.0.0.N`, Q-021 checklist): both eyes stable, no
  warping coupled to head motion, sharpness at gaze; `imm_hz` 90 (or 100/120 on
  an M5) with `inflight ≤ 2`, thermal in the log, engine `pace` slack > 0;
  Render Resolution default chosen from the measurement (M-0xx), not assumed.
- Remove the foveation env gate after the user's verdict.

**M6 — Settings sheet + persistence + Reset** (~1 round)
- Files: `PDVisionSettingsViewController.m`, `PDVisionApp.swift` (.sheet,
  header), `PDDefaults` (`vp3d.*` keys), bridge `3d set <key> <val>` / `3d get`.
- Accept: every row in §2.10 present with the stated range/default; each slider
  visibly moves the panel/eye size live (room screenshots before/after `3d set
  dist 6`); relaunch persists (bridge `3d get` after relaunch); Reset restores
  defaults but keeps Units/FPS; Screen Width release re-syncs eye px (`state`
  `eye_px=`).

**M7 — Gate + publish** (~1 round)
- `scripts/vision-validate.sh --3d`: M1-M4/M6 assertions scripted (enter, eye
  counters, L/R diff with HUD crop, replay in 3D, park cycle, settings
  persistence, exit restore), room + panel screenshots committed under
  `artifacts/sim/visionos-3d/`. `docs/frame-map.md` §"3D" (eye loop, fold, the
  three P classes, the fb-0 seam, pacing) and `docs/remote-console.md` `3d`
  commands. Publish `0.0.0.N --visionos` per `~/dev/OTA-PUBLISHING.md` only
  after M5's device verdict; notes carry "3D mode (Vision Pro): …".

Rough size: M1 ~600 lines Swift/ObjC + plist/project; M2 ~300 (mm) + patch
0031 ~120; M3 patch 0030 ~200 + ~400 (pacing/publish); M4 ~300; M5 ~60 + logs;
M6 ~400; M7 ~300 script + docs. Review (light) after M3 and M4 only.

## 5. Files that change (existing) — for the orchestrator's briefs
`app/ios/pd_ios_main.m` (split `pdShellPrepare`; `main()` iOS-only),
`app/ios/PDShell.m` (graft function; `pdIosFrameHook` calls `pdVision3dFramePoll`
on xrOS), `app/ios/PDSceneDelegate.m` (xrOS compile-out), `app/ios/PDPacing.m`
(external signal source, in-flight wait hook), `app/ios/PDAudio.m` (spatial),
`app/ios/PDTouchOverlay.m` (hidden while immersive), `app/ios/PDBridge.m` (`3d`
commands), `app/ios/PDDefaults.{h,m}` (`vp3d.*`), `app/gfx/gfx_angle_egl.mm`
(surfaceless/size/publish/rebind), `app/ios/Info-visionos.plist`,
`app/project.yml`, `scripts/vision-validate.sh`, `docs/frame-map.md`,
`docs/remote-console.md`, `docs/pacing.md` (§"3D: the compositor is the clock").
New overlay patches 0030/0031 (+0032/0033 if needed). Vendor untouched.

## 6. Risks and unknowns — each with the check that resolves it

| Risk | Check |
|---|---|
| SwiftUI @main + SDL2's UIKit video without SDL's app delegate | M1: sm64coopdx proves SDL2 2.32 does this (`sharedAppDelegate` is referenced only in SDL's own delegate .h — verified by grep on `work/sdl2-visionos/src`); assert window created + graft count in `state` |
| Stale persisted scene session → `PDSceneDelegate` on the user's headset | M1 device install over the Phase-5 build; the class is absent on xrOS so lookup fails and UIKit falls back (the family fix); log `scene willConnect` from SwiftUI |
| Running `gfx_run_dl` twice per frame has side effects | M3 seeded-replay-in-3D: per-eye `gfx:` lines == oracle |
| `EGL_METAL_TEXTURE_ANGLE` image on this ANGLE build / device mismatch | M2: `eglCreateImageKHR` returns non-NULL, `glCheckFramebufferStatus` complete, `EGL_ANGLE_device_metal` device == `MTLCreateSystemDefaultDevice()` logged |
| Grade pass or MSAA resolve still targets GL fb 0 somewhere | M2 screenshot parity vs 2D (grade visibly on) and a surfaceless context makes any stray fb-0 draw error loudly (`glGetError` polled per eye in debug) |
| Sky classification false positive/negative | M3 L/R diff of a skybox scene: sky shift == skew term only; fallback sentinel patch 0033 |
| Gun convergence comfort | DEVICE (Q-020); bridge A/B `3d gunconv` for one round then removed |
| CPU cost doubles on the render half (interpreter ≈ 50-60 % of main) | M5 `state` `gfxdl` per-eye row + `pace` slack on device; levers in order: Render Resolution, `PD_HOT_O2` already on, texture-sort (upstream's own next item) |
| Unbounded ANGLE command buffers (D-008 §2 hazard; consult) | M3 `inflight ≤ 2` asserted continuously; memory footprint flat over 5 min (`mem-probe.sh`) |
| Sim serialises queues → cross-queue race invisible | Designed out by GPU wait on the shared event (no CPU race); DEVICE confirms HUD present in both eyes (playbook ledger item) |
| Un-park after dismiss dropped on device | Exit order fixed to q2repro's (un-park first); DEVICE cycle ×3 |
| `cp_frame_query_drawable` deprecated (26+ has plural) | Use singular with pragma as sm64/quake3e do; plural is 26.0-only and our floor is 26.0 — either works; pick singular for parity |
| Foveation unverifiable on sim | Guarded path gate on sim; verdict on device (M5) |
| ARKit world tracking needs a usage string? | Device anchor needs none in the siblings' plists; the sim enforces none (D-030) — DEVICE first launch watches for a TCC kill in `crash.txt` |

## 7. Open questions for the user (Q-020…Q-023 drafts; defaults apply if unanswered)

- **Q-020 — stereo defaults on the headset.** Does 100 % Stereo Depth (63 mm
  at 1 unit ≈ 1 cm) and Crosshair Distance 20 ft read right, and is the gun
  comfortable with `C_gun = znear` (quake3e D-028)? Default: ship those; the
  sliders exist.
- **Q-021 — foveation verdict.** Both eyes stable, sharp at gaze, periphery
  shimmer acceptable? Default: foveation stays on unconditionally (family rule).
- **Q-022 — Render Resolution default.** q2repro ships 60 %; PD's frame is
  3.4 ms at 120 Hz on the Air with headroom. Default: 100 % unless the device
  `pace` slack goes to zero at 90 Hz, then the largest value that holds it.
- **Q-023 — menus in 3D.** Pad drives PD's menus fully in 3D; pinch does not.
  Acceptable, or should a pinch on the parked card exit 3D automatically?
  Default: pad-only in 3D, ornament "Exit 3D" for pinch users.
