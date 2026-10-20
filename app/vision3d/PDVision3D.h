// PDVision3D.h — the visionOS 3D mode's seam, in one header.
//
// Phase 6 (docs/visionos-3d-plan.md, D-047…D-053). Everything in this file is
// visionOS-only: the whole header is gated on TARGET_OS_VISION and nothing in
// the iOS target includes it. The Swift side reaches all of it through
// app/vision3d/pd-vision-bridging.h.
//
// WHY THERE IS A SWIFT ENTRY POINT AT ALL (D-047). An ImmersiveSpace can only
// be declared by a SwiftUI `App`. So on visionOS the process entry is
// PDVisionApp.swift, and the engine — which still owns the main thread forever,
// because pdEngineMain() never returns — is booted by PDHostViewController from
// a RUN-LOOP TIMER. Not from dispatch_async(main): the main dispatch queue is
// serial, and a never-returning loop started from inside a main-queue block
// holds that queue for the life of the process, after which every SwiftUI
// effect (openImmersiveSpace, @Published, the ornament) silently does nothing.
// sm64coopdx measured exactly that (its M-38) and the fix is the timer.
//
// MILESTONE 3 SCOPE. The engine renders the display list TWICE per host frame
// at the same game time — eye L then eye R — into the two eye FBOs of one ring
// slot (overlay patch 0030), with the per-eye offset and convergence skew
// folded into the projection at gfx_pc's two MP-product sites. The compositor
// samples each view from its own eye, the panel is world-locked from a frozen
// head pose, and the compositor's own frame timing — not the display link — is
// the engine's clock while 3D is on (pacing_mode=compositor).
#pragma once

#include <TargetConditionals.h>

#ifndef TARGET_OS_VISION
#define TARGET_OS_VISION 0
#endif

#if TARGET_OS_VISION

#import <UIKit/UIKit.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// The engine entry points the host view controller calls (app/ios/pd_ios_main.m)
// ---------------------------------------------------------------------------

/** Everything main() does before SDL. See pd_ios_main.m. */
char **pdShellPrepare(int argc, char *argv[], int *outArgc);
/** The engine, onboarding, bridge, pacer and pad. NEVER RETURNS. */
int pdSDLMain(int argc, char *argv[]);

// ---------------------------------------------------------------------------
// Mode switching. Main thread only.
// ---------------------------------------------------------------------------

/**
 * Enter or leave 3D. Idempotent, and a no-op before the engine has booted.
 *
 * ON:  flips the SwiftUI flag, which opens the ImmersiveSpace; the compositor
 *      loop starts on its own thread and draws the panel.
 * OFF: asks the loop to stop and WAITS for it (<= 2 s) before the space is
 *      dismissed — the loop must never touch a layer renderer SwiftUI is
 *      tearing down — then flips the flag back.
 */
void pdVision3dSetMode(bool on);

/** 1 while 3D is on (the flag, not the loop: see pdVision3dImmersiveRunning). */
int pdVision3dActive(void);

/**
 * Called once a frame from pdIosFrameHook (game thread == main thread).
 *
 * Two jobs in M1: re-run the graft until SDL's window has a scene (there is no
 * scene delegate on visionOS any more, so nothing else would), and honour
 * PD_VP3D_AUTOENTER — the ornament needs a gaze-pinch the simulator cannot
 * inject, so a scripted gate enters 3D at frame 300 instead.
 */
void pdVision3dFramePoll(void);

/** The `3d state` rows, newline-terminated, for the bridge's `state`. */
NSString *pdVision3dStateLines(void);

// ---------------------------------------------------------------------------
// M4: the parked window and the curtain (plan §2.9, D-051)
//
// While 3D is on the 2D window must be neither in front of the panel nor
// showing the game — otherwise the room holds two pictures of the same frame,
// one of them a metre closer than the other. Two separate mechanisms, because
// they fail separately:
//
//   THE CURTAIN is ours: a black view with "Playing in 3D" on it, added to
//   SDL's own UIWindow the moment the engine goes offscreen. It is up before
//   the space opens (so no stale frame is ever on screen) and comes down after
//   the exit has re-bound the window surface and drawn again.
//
//   PARKING is the system's: UIWindowSceneGeometryPreferencesVision shrinks the
//   scene to a 480-pt card at the panel's aspect. It happens ~1.5 s AFTER the
//   space finished opening (parking during the transition wedges a sibling
//   animation) and is UNDONE BEFORE the dismissal, never after — a q2repro
//   device finding that the simulator's instant transitions cannot reproduce.
// ---------------------------------------------------------------------------

/** Swift, after `openImmersiveSpace` returned success: arms the +1.5 s park. */
void pdVision3dSpaceOpened(void);
/** The bridge's `3d park` / `3d unpark`: the same request, without the space. */
void pdVision3dParkRequest(int park);
/** 1 while the scene is shrunk to the card. */
int pdVision3dWindowParked(void);
/** 1 while the curtain is over SDL's window. */
int pdVision3dCurtainUp(void);
/** Completed park -> 3D -> exit cycles this session (the LUS ports' gate). */
int pdVision3dParkCycles(void);

/**
 * Make SDL's grafted window wear the system's rounded corners (dev2).
 *
 * visionOS rounds windows it MANAGES; SDL's is adopted into the scene rather
 * than created by it, so it wears none and paints its corners square — the
 * parked card and, after an exit, the restored window. Any thread; hops to
 * main. The radius is read from the scene's primary window, never hard-coded.
 */
void pdVision3dMirrorWindowCorners(void);
/** SDL's window's live corner radius, for `3d state`'s win_corner_radius. */
CGFloat pdVision3dWindowCornerRadius(void);

/** A perfectdark:// URL that arrived through SwiftUI's .onOpenURL. */
void pdVision3dQueueDeepLink(NSURL *url);

// ---------------------------------------------------------------------------
// M6: the settings sheet (plan §2.10, D-054)
//
// The rows are NSUserDefaults (`vp3d.*`, PDDefaults.h) and PDDefaults is the
// truth exactly as it is for the 2D page. pdVision3dApplySettings() is the ONE
// place those defaults become 3D state — the panel's geometry and dimming, the
// stereo fold's depth and convergence, and the eye target's size — and it is
// called from three places and nowhere else: every row change, the 3D entry
// (plan §2.9 "apply all 3D settings" BEFORE the engine goes offscreen), and
// the boot's own PDDefaultsApplyToEngine().
// ---------------------------------------------------------------------------

/** Push every `vp3d.*` default into the live 3D state. Main/game thread. */
void pdVision3dApplySettings(void);

/**
 * The panel's shape has stopped moving — re-size the eye to it (D-058).
 *
 * Entry, Reset, a bridge set, and every slider RELEASE. Apply is live and
 * re-wraps nothing; this is the commit.
 */
void pdVision3dCommitGeometry(void);
/** Forget the `vp3d.*` keys (Units and Show FPS are deliberately kept), apply. */
void pdVision3dSettingsResetDefaults(void);
/** Open (1) or close (0) the SwiftUI sheet. */
void pdVision3dSettingsSheetRequest(int open);
/** Swift's .onAppear/.onDisappear: the sheet is really up (1) or gone (0). */
void pdVision3dSettingsSheetNote(int up);
/** 1 while the sheet is on screen. */
int pdVision3dSettingsSheetUp(void);
/**
 * Close the sheet and WAIT for it, by pumping the run loop (<= 1 s).
 *
 * Called at the top of the 3D exit, before the un-park. The un-park must be
 * issued before `dismissImmersiveSpace` and must not be issued while a modal
 * the system is also dismantling is on screen — so the sheet is gone FIRST,
 * and provably so (`sheet_open=0` in `3d state`), rather than hopefully.
 */
void pdVision3dSettingsSheetCloseAndWait(void);
/** The `3d settings get` body, and the `set_*` rows of `3d state`. */
NSString *pdVision3dSettingsStateLines(void);
/**
 * The bridge's `3d settings set <row> <value>`. Returns what it set, or nil if
 * the row is not one of ours. Row names are the short `3d state` suffixes
 * (dist, width, height, posh, depth, conv, dim, render, units, fps).
 */
NSString *pdVision3dSettingsSet(NSString *row, NSString *value);

// ---------------------------------------------------------------------------
// The compositor loop (app/vision3d/PDImmersive.m)
// ---------------------------------------------------------------------------

/**
 * The immersive render loop. Runs on its OWN thread, spawned by the
 * CompositorLayer closure in PDVisionApp.swift; `lr` is the layer renderer,
 * passed unretained (SwiftUI owns it).
 */
void pdVision3dImmersiveRun(void *lr);

/** Set to ask the loop to finish at the top of its next iteration. */
extern volatile int pdVision3dImmStop;
/** 1 between the loop's first statement and its last. */
extern volatile int pdVision3dImmRunning;
/** Compositor frames this session. */
extern volatile int pdVision3dImmFrames;
/**
 * Compositor frames that came back with NO drawable this session.
 *
 * The compositor withholds one from an app that is behind. It is a legitimate
 * condition and the loop just skips the frame — but it must be VISIBLE, because
 * mishandling it (calling cp_frame_end_submission anyway) is a SIGABRT inside
 * CompositorNonUI and that is how dev1's first run died.
 */
extern volatile int pdVision3dImmNoDrawable;
/** The compositor's measured cadence, Hz (0 until ~20 frames have landed). */
extern volatile float pdVision3dImmHz;

/**
 * FOVEATION (D-063, and the five-step recipe in ~/dev/VISIONOS-FOVEATION-GUIDE.md).
 *
 * Three facts, because "is foveation on" has three different answers and only
 * reading all three says which one the headset gave us:
 *
 *   pdVision3dFoveationSupported  what LayerRenderer.Capabilities said. The
 *                                 SIMULATOR says NO — it is mono and has no
 *                                 eye tracker — so a 0 here on the sim is the
 *                                 expected reading and not a regression.
 *   pdVision3dFoveationConfigured what we asked for at layer-config time:
 *                                 `isFoveationEnabled`, which is the supported
 *                                 flag unconditionally (family rule: always on
 *                                 where supported, no user toggle).
 *   pdVision3dFoveationRateMaps   what the DRAWABLE actually carries, counted
 *                                 every frame. This is the only one that proves
 *                                 the rate maps reached the render passes, and
 *                                 it is 0 whenever foveation is not live.
 *
 * ...plus the layout, because `.layered` with foveation is the guide's trap 1
 * (a right-eye fisheye that warps with the head) and the row is how a device
 * session can rule it out in one line.
 */
extern volatile int pdVision3dFoveationSupported;
extern volatile int pdVision3dFoveationConfigured;
extern volatile int pdVision3dFoveationRateMaps;
/** 1 = .dedicated, 0 = .layered. */
extern volatile int pdVision3dLayoutDedicated;

/** Swift calls this from makeConfiguration with what it asked the layer for. */
void pdVision3dNoteCompositorConfig(int supported, int configured, int dedicated);

/** The layer went invalid under us: a Crown/system dismissal. Reconciles. */
void pdVision3dImmersiveEnded(void);

// ---------------------------------------------------------------------------
// The eye render targets (app/vision3d/PDEyeTargets.mm, M2, D-048)
//
// Everything above "consume" is ENGINE-THREAD ONLY and requires the ANGLE
// context to be current. pdVisionEyeFBO() is the one symbol the engine itself
// calls: overlay patch 0031 makes gfx_opengl.cpp's framebuffer slot 0 — "the
// screen" — resolve to whatever it returns, so PD's MSAA resolve, the Vivid
// Colours/Black Level grade pass and read_screen_pixels all land on the eye
// with nothing above the backend changed.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// WHICH EYE (M3). The ring holds PAIRS: two MTLTextures per slot, L and R.
// pdVisionSetEye() picks which one pdVisionEyeFBO() answers with, so the whole
// redirect in patch 0031 follows the eye without knowing there are two.
// ---------------------------------------------------------------------------
#define PD_EYE_LEFT  0
#define PD_EYE_RIGHT 1

/** Engine thread: draw into this eye from now on. */
void pdVisionSetEye(int eye);
/** The eye the engine is drawing (0 in 2D). */
int pdVisionGetEye(void);
/** 2 while 3D is on, 1 in 2D — the bridge's `eyes_per_frame`. */
int pdVisionEyesPerFrame(void);
/** Eye renders this session: must be 2x frames in 3D, 0 in 2D. */
unsigned long long pdVisionEyeRenders(void);
/** Engine thread: one eye's display-list walk finished. */
void pdVisionEyeNoteRender(void);

/**
 * 1 if THIS eye's readback is the one a screenshot keeps.
 *
 * `--screenshot-frame`, F12 and the bridge's `screenshot` all read framebuffer
 * 0, which in 3D is whichever eye is bound. Running the capture for both eyes
 * would write the file twice and leave whichever ran last, so exactly one eye
 * is the capture eye: R by default, or the one PD_VP3D_SHOWEYE names — which is
 * what makes the L-vs-R diff of the same seeded replay a measurement.
 */
int pdVisionEyeIsCapture(int eye);
/** PD_VP3D_SHOWEYE: 0 = L, 1 = R, -1 = per-view (the default). */
int pdVisionEyeShowEye(void);
/** Bridge `3d showeye`: override the above at runtime; -2 restores the env. */
void pdVisionEyeSetShowEye(int eye);

/**
 * Engine thread, before eye L: block while more than two pairs are in flight.
 *
 * The compositor decrements through the published event's completion listener,
 * so this is a real GPU-side bound and not a guess (plan §2.6). Bounded at
 * 200 ms with a loud log: a stuck listener must cost frames, never the session.
 */
void pdVisionEyeBeginPair(void);
/** Pairs published but not yet retired. Asserted <= 2 by the M3 gate. */
int pdVisionEyeInFlight(void);

/**
 * The stereo fold's parameters, read by overlay patch 0030 (gfx_pc.cpp).
 *
 * Returns 1 when the fold applies — 3D on, the ring live, a non-zero eye
 * offset. `*outOffset` is the SIGNED half-separation for the eye currently
 * being drawn, in PD world units (1 unit ~ 1 cm, constants.h:496), so the
 * default 3.15 is a 63 mm IPD. `*outConvergence` is the crosshair distance in
 * the same units (610 = 20 ft). `*outGunConvergence` is 0 unless the bridge's
 * one-round A/B has overridden it, in which case it replaces the gun class's
 * own znear-derived convergence.
 */
int pdVisionStereoFold(float *outOffset, float *outConvergence, float *outGunConvergence);

/**
 * Count one projection by class: 0 = world, 1 = sky, 2 = gun (plan §2.4).
 *
 * The only cheap proof that all three branches of the classification are
 * reached by a real scene — a screenshot cannot show that the sky took the
 * skew-only path.
 */
void pdVisionStereoNoteClass(int cls);

/**
 * The depth the GUN class converged at, in PD units (D-055).
 *
 * The viewmodel converges at its own |mv[3][2]| rather than at its znear, and
 * this is how that arithmetic is read back: `gun_depth_min/max/avg` in
 * `3d state`, which is also the number `3d gunconv`'s one A/B round starts
 * from. D-049's C_gun = znear = 1.5 shifted the weapon ~2.7 NDC units sideways
 * and drew it entirely off screen, in both eyes, with the class counter
 * cheerfully reporting 247990 hits.
 */
void pdVisionStereoNoteGunDepth(float depth);

/**
 * Engine thread: one gun-classed VERTEX's view depth (D-060), and the frozen
 * minimum the fold converges the viewmodel at. The gun sits AT the panel and
 * never in front of it (quake3e D-028 v2), which is only true if the plane is
 * the gun's nearest vertex rather than its origin — the origin left the whole
 * muzzle end crossed, in front of a HUD drawn over it.
 */
void pdVisionStereoNoteGunVertex(float depth);
float pdVisionStereoGunNear(void);

/**
 * D-061 — THE NEAR LAW. Two pure numbers, both expressed as a multiple of the
 * convergence distance's own reciprocal, so the whole of the stereo geometry
 * scales with Crosshair Distance and Stereo Depth and nothing else.
 *
 * Write U for the disparity the fold gives a point at infinity: |2*a*e/C|, the
 * far asymptote, the deepest anything ever goes BEHIND the panel. Then a world
 * point at view depth d carries U*(C/d - 1) of crossed disparity, which grows
 * without bound as d falls — and PD lets Joanna put her face 30 units from a
 * wall, where at the shipped defaults that is 400 px, twelve degrees, well past
 * fusion. The user: "when you get close to a wall ... your eyes focus on the edges
 * of your gun and how it overlaps with the world around you", and "it's a
 * little disorienting even when it overlaps with the ground".
 *
 *   *outWorldN  the world's crossed disparity is clamped to U * N. The clamp
 *               plane is therefore D_min = C / (1 + N), soft-kneed from
 *               C / (1 + N*PD_STEREO_KNEE) so the law has no corner.
 *   *outGunN    the viewmodel is shifted rigidly forward until its FARTHEST
 *               vertex carries U * G of crossed disparity, G > N. Since the
 *               world never reaches U*N, every vertex of the gun is strictly
 *               nearer than every world pixel it can border — the floor two
 *               metres away included, which is the half a near-wall clamp alone
 *               does not cover.
 */
void pdVisionStereoNearLaw(float *outWorldN, float *outGunN, float *outKnee);

/**
 * 1 while the stereo fold is live (3D is on). Engine code compiled into the
 * visionOS build runs in 2D too, and in 2D it must do NOTHING: see D-064.
 */
int pdVisionStereoIsActive(void);

/**
 * Engine thread, once per host frame at the tail of gfx_run: what one eye's
 * walk saw (D-060). The bg-space scale in force, projection LOADs against
 * projection MULs (which is the only evidence for or against D-055's claim
 * that PD's lists multiply into the projection), how many of those loads had
 * the camera baked into them, and how many light glares got a per-eye shift.
 */
void pdVisionStereoNoteFrameFacts(float bgScale, uint32_t mulP, uint32_t loadP,
                                  uint32_t baked, uint32_t depthRects);

/**
 * Compositor thread: the per-view LOGICAL size of the drawable (D-057).
 *
 * The eye's base size used to be a hard-coded 3840x2160 — the simulator's
 * drawable, assumed to be the headset's. It is not: on device that eye cost
 * 1086 MB of footprint (M-043) for a target no view ever samples at full rate.
 * So the compositor's first drawable reports its view texture map's viewport
 * here, and the ring is re-wrapped at the next frame boundary through exactly
 * the machinery the Render Resolution row uses. PD_VP3D_EYE still wins, because
 * a pinned eye is a measurement instrument.
 */
void pdVisionEyeNoteCompositorViewSize(int w, int h);

/**
 * Compositor thread: the view's horizontal field of view, in radians, taken
 * from cp_drawable_compute_projection's own tangents (D-058).
 *
 * With the view's width this is the headset's pixels-per-radian, which is what
 * turns "the panel is 5.5 m wide at 3.6 m" into a pixel count. cp_view_get_
 * tangents ABORTS under mixed immersion, so the projection matrix is the only
 * legal source: for a Metal perspective matrix P, tan(right) = (P[2][0]+1)/P[0][0]
 * and tan(left) = (P[2][0]-1)/P[0][0].
 */
void pdVisionEyeNoteCompositorFovX(float radians);

/**
 * D-058: THE EYE RENDER TARGET FOLLOWS THE PANEL, NOT THE DRAWABLE.
 *
 * `Note` is live — every sample of a Screen Width / Height / Distance drag —
 * and re-wraps nothing: the compositor stretches the quad for instant feedback.
 * `Commit` is the slider's RELEASE (and the bridge's atomic set, and Reset, and
 * 3D entry): it asks for the ring to be re-wrapped at the next frame boundary,
 * at the panel's aspect and at the pixel count the panel's angular size earns.
 *
 * Before this the eye was the compositor's per-view size and the panel pass
 * aspect-FIT the quad to it, so the two size rows could not change the shape of
 * the picture at all and the shipped default read as a square (the user, device
 * round 1). A pinned PD_VP3D_EYE opts out of both: the gates need a fixed eye.
 */
void pdVisionEyeNotePanelGeometry(float halfW, float halfH, float dist);
void pdVisionEyeCommitPanel(void);
/** The committed panel's aspect (halfW/halfH), which the eye now wears. */
float pdVisionEyePanelAspect(void);
/** Non-zero when PD_VP3D_EYE has pinned the eye; the panel pass then fits. */
int pdVisionEyeIsPinned(void);
/** The ring + shared depth + panel copies, in MB, at the live eye size. */
float pdVisionEyeFootprintMB(void);

/** Stereo Depth, per cent of the default separation. Bridge `3d depth`. */
void pdVisionStereoSetDepthPct(float pct);
float pdVisionStereoDepthPct(void);
/** Bridge-only gun-convergence A/B (plan §2.4); 0 restores znear. */
void pdVisionStereoSetGunConvergence(float units);

/** Clear the frozen head pose: the panel re-anchors on the next tracked frame. */
void pdVisionRecenter(void);

/**
 * The panel's geometry and the surroundings dimming, from the settings sheet.
 *
 * Lengths in METRES and HALF-extents (the sheet shows full width and height,
 * the compositor scales a unit quad) — SETTINGS-SPEC's own storage. The
 * compositor thread reads these every frame, which is what makes a dragged
 * slider move the panel while the finger is still on it.
 */
void pdVisionPanelSet(float dist, float halfW, float halfH, float posH, float dim);
/** The `panel_*` rows of `3d state`: what the COMPOSITOR is actually using. */
NSString *pdVisionPanelStateLines(void);

/** Crosshair Distance: the convergence plane, in PD units (610 = 20 ft). */
void pdVisionStereoSetConvergence(float units);
float pdVisionStereoConvergence(void);

/**
 * Render Resolution, as a percentage of the eye's BASE size.
 *
 * Base is 3840x2160, or whatever PD_VP3D_EYE names — so a gate that pins the
 * eye to the oracle's 1280x720 still measures this row (50 % of it is 640x360)
 * and a 100 % default leaves every existing run byte-for-byte unchanged.
 *
 * The ring cannot be re-wrapped from here: freeing a texture the compositor
 * may be sampling is the one use-after-free the handoff is built to avoid. So
 * this only ASKS; pdVisionEyeResizeIfPending() does it on the engine thread at
 * a frame boundary, from pdVision3dFramePoll().
 */
void pdVisionEyeSetRenderPct(float pct);
float pdVisionEyeRenderPct(void);
/** Engine thread, frame boundary: re-wrap the ring if the size moved. */
void pdVisionEyeResizeIfPending(void);

/**
 * Compositor thread: brackets the window in which it holds a RAW ring pointer.
 *
 * pdVisionEyeAcquire() hands back the texture unretained (the ring owns it for
 * the session), which is safe only as long as nothing frees the ring while the
 * compositor is between the acquire and its own retain. A live Render
 * Resolution change is exactly that, so the resize clears the published slot —
 * after which no acquire can return a ring pointer — and then waits for this
 * counter to reach zero before it frees anything.
 */
void pdVisionEyeSampleBegin(void);
void pdVisionEyeSampleEnd(void);

/** Allocate + wrap the eye ring. 1 on success; loud and 0 on failure. */
int pdVisionEyeActivate(void);
/** Free the ring. Call AFTER the window surface is re-bound (q2repro trap). */
void pdVisionEyeDeactivate(void);
/** The current eye FBO and its size, or 0 when 3D is off. */
unsigned int pdVisionEyeFBO(int *w, int *h);
/** The eye target size, whether or not the ring is live. */
void pdVisionEyeGetSize(int *w, int *h);
/** End of an eye: sync, publish to the compositor, advance the ring. */
void pdVisionEyePublish(void);

/**
 * Compositor thread: the texture for `eye`, plus the GPU event to wait on.
 *
 * Both eyes of a pair carry the SAME event and value — they were drawn into by
 * the same ANGLE command stream and published together — so one
 * encodeWaitForEvent covers the pair however many views sample it.
 */
void *pdVisionEyeAcquire(int eye, void **outEvent, unsigned long long *outValue,
                         unsigned int *outGen);
/** Compositor thread: this frame sampled a new pair (1) or reused one (0). */
void pdVisionEyeCountSample(int fresh);
/** The `eye_*` rows of `3d state`. */
NSString *pdVisionEyeStateLines(void);

// ---------------------------------------------------------------------------
// Implemented in Swift (@_cdecl), called from ObjC
// ---------------------------------------------------------------------------

void PD_SetImmersiveMode(bool on);
void PD_SetSettingsSheet(bool on);

#ifdef __cplusplus
}
#endif

/**
 * The engine's host. Lives in the SwiftUI WindowGroup as a
 * UIViewControllerRepresentable, and boots the engine from -viewDidAppear via
 * a run-loop timer (see the file comment above).
 */
@interface PDHostViewController : UIViewController
@end

#import "PDSettingsViewController.h"

/**
 * The 3D settings rows (M6, plan §2.10) as ONE table section (D-082).
 *
 * The row model, the cells, the controls' handlers and the "3D Settings |
 * Reset" header view. Owned by a PDSettingsViewController, which draws it as
 * its last section under the iOS ones — on every visionOS settings surface.
 */
@interface PDVision3DRows : NSObject
- (instancetype)initWithTableView:(UITableView *)tableView;
/** Redraw the 3D section of every page that has one. Any thread. */
+ (void)reloadAll;
+ (CGFloat)headerHeight;
@property (nonatomic, readonly) NSInteger count;
- (UIView *)headerViewForWidth:(CGFloat)width;
- (UITableViewCell *)cellForRow:(NSInteger)row;
- (void)didSelectRow:(NSInteger)row;
- (BOOL)pressRowNamed:(NSString *)name;
/** This section's row index for a row's short name, or NSNotFound. */
- (NSInteger)rowIndexNamed:(NSString *)name;
/** `3d settings seg <name> <index>`: through the control, as a finger would. */
- (NSString *)setSegmentNamed:(NSString *)name to:(NSInteger)segIndex;
/** One `[3d] settings row: [Group] Title (name)` line per row (the M6 gate). */
- (void)logRows;
@end

/**
 * The settings sheet's table: the WHOLE settings page (D-082), hosted inside
 * the SwiftUI `.sheet` because a UIKit modal presented directly over an open
 * immersive space silently fails (SETTINGS-SPEC :13-37).
 */
@interface PDVisionSettingsViewController : PDSettingsViewController
/** The one on screen, or nil. Main thread. */
+ (PDVisionSettingsViewController *)current;
/** Re-read every row's value from NSUserDefaults. */
+ (void)reloadRows;
/**
 * Press a button row by its short name (`3d settings press recenter`).
 *
 * The visionOS simulator injects no taps at all, so this is the only scripted
 * path through a button row — the gap `settings row` fills on the 2D page.
 */
- (BOOL)pressRowNamed:(NSString *)name;
@end

#endif // TARGET_OS_VISION
