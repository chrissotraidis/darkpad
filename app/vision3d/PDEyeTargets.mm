// PDEyeTargets.mm — the eye render targets: ANGLE draws into app-owned
// MTLTextures, and the compositor pass samples them (Phase 6 M2, D-048).
//
// THE ONE THING THIS FILE EXISTS TO DO. The engine renders through ANGLE, which
// normally presents into the SDL window's CAMetalLayer. In 3D there is no
// window to present into: the picture has to end up on a quad the compositor
// draws, on the compositor's own Metal queue. So the engine's "screen" becomes
// an MTLTexture that WE own, wrapped as a GL framebuffer, and the compositor
// samples that texture.
//
// WHY THE WRAP IS SHAPED EXACTLY LIKE THIS (q2repro paid for every line —
// q2repro-ios/docs/visionos-3d-plan.md :63-110, app/Sources/immersive/xr3_glue.m
// :433-470):
//
//   * eglCreatePbufferFromClientBuffer does NOT accept EGL_METAL_TEXTURE_ANGLE
//     (its buftype switch only knows D3D and IOSurface). The route that works
//     is eglCreateImageKHR(EGL_METAL_TEXTURE_ANGLE) ->
//     glEGLImageTargetTexture2DOES -> glFramebufferTexture2D.
//   * the MTLTexture must belong to ANGLE's OWN MTLDevice. On visionOS ANGLE
//     always uses MTLCreateSystemDefaultDevice() (its registryID selection is
//     #if TARGET_OS_OSX), and that instance is also the compositor's device —
//     so one device serves both sides. We assert it rather than assume it.
//   * depth is a RENDERBUFFER, not a texture: ANGLE-Metal refuses a separate
//     stencil renderbuffer beside a depth TEXTURE, and PD's default-framebuffer
//     path assumes depth24/stencil8 is there (gfx_sdl2 asks SDL for both).
//   * ANGLE renders into the texture on ANGLE's queue, and the compositor reads
//     it on the compositor's queue. The two have NO ordering. So each published
//     frame carries the (MTLSharedEvent, value) ANGLE signals for it, and the
//     presenting command buffer encodes a waitForEvent on them before it copies
//     anything. This cannot deadlock: the value is signalled by ANGLE's own
//     command buffer, which was already submitted when we published.
//   * the ring is 3 deep so the compositor is never sampling the texture the
//     engine is currently drawing into.
//
// M3: THE RING HOLDS PAIRS, AND THE PRODUCER IS BOUNDED. Each of the three
// slots now carries TWO textures, L and R, wrapped as two FBOs over one shared
// depth renderbuffer (the eyes are drawn strictly one after the other and each
// clears depth itself, so one buffer is correct and saves a third of the eye
// memory). pdVisionSetEye() chooses which FBO slot 0 of the backend resolves
// to, so patch 0031 needs no second case.
//
// A pair is published ONCE, at the end of eye R, and carries one
// (MTLSharedEvent, value) for both textures — they were drawn by the same
// ANGLE command stream. Publishing increments an in-flight count that the
// event's own completion listener decrements, and eye L of the next frame
// blocks while that count is above two (plan §2.6). That is the backpressure
// the D-008 consult asked for: without it a producer that outruns the
// compositor queues command buffers without bound and the footprint climbs
// until the OS intervenes.
#import "PDVision3D.h"

#if TARGET_OS_VISION

#import <Metal/Metal.h>
#import <Foundation/Foundation.h>

// ANGLE exports every one of these directly (the dylibs are linked into the
// app), so the prototypes are taken from the headers rather than fished out
// with eglGetProcAddress one at a time.
#define EGL_EGLEXT_PROTOTYPES
#define GL_GLEXT_PROTOTYPES
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <EGL/eglext_angle.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <unistd.h>
#include <time.h>

// ---------------------------------------------------------------------------
// The ring
// ---------------------------------------------------------------------------

#define PD_EYE_RING 3

struct PDEyeBuf {
	void *mtl;            // CFBridgingRetain'd id<MTLTexture>
	EGLImageKHR img;
	GLuint tex;
	GLuint fbo;
};

// [slot][eye]: three slots deep so the compositor is never sampling the pair
// the engine is drawing, two eyes wide so a pair is one frame.
static struct PDEyeBuf s_ring[PD_EYE_RING][2];
static GLuint s_depthRbo;
static int s_ringIndex;
static int s_eye;               // which eye the engine is drawing right now
static int s_active;
static int s_eyeW, s_eyeH;
static int s_fboComplete;       // 1 once every slot reported COMPLETE
static int s_wrapFailed;

// The eye-render counter (plan §2.3): 2 x frames in 3D, 0 in 2D. Three rates,
// one fact — if this is not exactly twice the frame count something is
// rendering one eye twice or not at all.
static uint64_t s_eyeRenders;

// Backpressure. s_inFlight is incremented by the publish and decremented by the
// published event's completion listener, which runs on s_listenerQueue.
static _Atomic(int) s_inFlight;
static _Atomic(int) s_inFlightPeak;
static uint32_t s_stalls;             // times eye L had to wait for a retire
static uint32_t s_stallTimeouts;      // times that wait hit its 200 ms bound
static MTLSharedEventListener *s_listener;
static dispatch_queue_t s_listenerQueue;

// Stereo parameters. Defaults are the plan's: half-separation 3.15 PD units
// (1 unit ~ 1 cm, so a 63 mm IPD) at Stereo Depth 100 %, and a convergence of
// 610 units = 20 ft, the vkQuake/q2repro crosshair distance.
#define PD_STEREO_HALFSEP  3.15f
#define PD_STEREO_CONV     610.0f
static float s_depthPct = 100.0f;
static float s_gunConvOverride;       // 0 = the gun class uses its own znear
// Crosshair Distance (M6): the convergence plane, in PD units. A setting now,
// not a constant — things at this game-distance sit exactly ON the panel.
static float s_conv = PD_STEREO_CONV;

// Render Resolution (M6): a percentage of the eye's BASE size, and a REQUEST.
// The ring is re-wrapped by pdVisionEyeResizeIfPending() on the engine thread
// at a frame boundary, never from the setter — see PDVision3D.h.
static float s_renderPct = 100.0f;
static _Atomic(int) s_resizeAsked;
// The compositor's raw-pointer bracket (PDImmersive.m). Non-zero means a
// compositor frame is between pdVisionEyeAcquire() and its own retain, so the
// ring must not be freed.
static _Atomic(int) s_sampling;

// How many projections of each class the fold has seen (plan §2.4's three-way
// classification). This is the only cheap proof that all three branches are
// actually reached by a real scene — a frame's screenshot cannot show that the
// SKY took the skew-only path, and the seeded replay's frame 1500 has no gun in
// it at all. In a live gameplay session all three must be non-zero.
static uint64_t s_clsWorld, s_clsSky, s_clsGun, s_clsFlat;
// ...and how many of each ONE EYE of the LAST completed frame saw (D-055). The
// totals alone are what hid the misfire: 2.27M against 2.29M over a session is
// hard to read, while "sky 2 per frame against world 1800" is a sentence. The
// gate asserts on these, with the XBLA release ON.
static uint32_t s_clsCur[4], s_clsLast[4];

// The depth the gun class converged at, in PD units (D-055): the |mv[3][2]| of
// the modelview being multiplied in. Reported so the fold's own arithmetic can
// be read back rather than believed - and so `3d gunconv`'s A/B has a number to
// start from.
static float s_gunDepthMin, s_gunDepthMax, s_gunDepthSum;
static uint64_t s_gunDepthN;

// The compositor's own per-view logical size, learned from the first drawable
// (D-057). 3840x2160 was a GUESS, and on the headset it cost 1086 MB of
// footprint for an eye far larger than any view samples.
#define PD_EYE_FALLBACK_W 3840
#define PD_EYE_FALLBACK_H 2160
static _Atomic(int) s_compW, s_compH;
// The compositor view's horizontal field of view in radians, derived from
// cp_drawable_compute_projection's own tangents (PDImmersive.m). Together with
// s_compW this is the headset's pixels-per-radian, which is the only honest way
// to ask "how many pixels does a panel THIS BIG, THIS FAR AWAY actually eat".
static _Atomic(int) s_compFovMilliRad;

// D-058: THE EYE FOLLOWS THE PANEL.
//
// D-057 made the eye the compositor's per-view size. That is the right number
// for a picture that fills the view, and the panel is not one: it is a quad a
// couple of metres wide hanging at 3.6 m, and its shape is whatever the Screen
// Width / Screen Height rows say. Taking the view's size gave the device a
// 5080x4080 eye — 20.7 Mpx at aspect 1.245, nearly SQUARE — and the panel pass
// then aspect-FIT the quad to it, so the two width/height rows could not change
// the picture's shape at all and the default read as a square. The user's words:
// "the 3d screen settings don't actually change the screen size. and whatever
// default you picked is more of a SQUARE screen which is a silly choice."
//
// So the base is computed FROM the panel: its angular width at its distance,
// times the compositor's pixels-per-radian (that is 1:1 with the headset's own
// sampling of that solid angle), height = width / the panel's aspect. The
// result is clamped by the compositor's view — never render more pixels than
// any view can sample — and by a budget, below.
//
// The COMMITTED geometry, not the live one: a slider drag moves the panel every
// sample (that is the instant feedback the spec asks for) and re-wrapping six
// textures per sample is not on. pdVisionEyeCommitPanel() is called on the
// slider's RELEASE, from the bridge's atomic set, from Reset and at entry.
// volatile, as PDImmersive.m's pdPanelHalfW family is: these six are written on
// the main and bridge threads and read on the ENGINE thread in pdEyeBaseSize().
// The atomic s_resizeAsked store after them gives the release ordering that
// actually makes the hand-off safe, but the qualifier is the established
// pattern here and it costs nothing at this rate (panel-round review).
static volatile float s_panelHalfW = 2.75f;     // live, from pdVisionPanelSet
static volatile float s_panelHalfH = 1.55f;
static volatile float s_panelDist  = 3.6f;
static volatile float s_cmtHalfW   = 2.75f;     // committed: what the eye is sized from
static volatile float s_cmtHalfH   = 1.55f;
static volatile float s_cmtDist    = 3.6f;

// THE BUDGET, and it is the shipped default (deliverable 3 of dev2).
//
// At 1:1 the default panel wants ~3400-3900 px across on both the device and
// the simulator, which is 6-7 Mpx an eye and twelve of them once the ring and
// the panel copies are counted. 2560 across at the 16:9 default is 3.7 Mpx —
// a hair over one 4K-wide picture per eye, ~5.6x fewer pixels than D-057's
// 5080x4080, and still more than the panel's angular size can show on any
// current headset once the ring is honest about it (docs/memory-math.md).
// Render Resolution then scales THIS, so 100 % means "the budget" and the row
// keeps its meaning.
#define PD_EYE_BUDGET_DIM 2560
// D-062: the budget is an AREA, not a width.
//
// The user, after 0.0.0.11: "people should be able to go even wider than that if
// they want. though it will impact their FPS." The Screen Width row now reaches
// 40 ft — and a cap on the LARGER DIMENSION punishes exactly that: a 40 x 12 ft
// panel is 118.9 deg wide, wants 5073 px across, and a 2560 cap hands it
// 2560x768, which is 2.0 Mpx. Half the budget's pixels, for the widest panel on
// the row. Wider would have been BLURRIER and not slower, which is the opposite
// of what the user was told the trade is.
//
// So the clamp is on the pixel COUNT, which is what the footprint and the fill
// rate are actually made of, and the shape is left to the panel. The default
// panel is unchanged to the pixel: 5:3 at 3435x2061 scales by
// sqrt(3932160/7079535) = 0.7453 to exactly 2560x1536. The 40 ft panel gets
// 3619x1086 instead of 2560x768 - the same bill, spent along the panel.
#define PD_EYE_BUDGET_PX  (2560 * 1536)
// A hard ceiling on either dimension all the same: a texture the driver refuses
// is not a trade-off, it is a black screen.
#define PD_EYE_MAX_DIM    4096

// The published slot: what the compositor may sample, and the GPU event it must
// wait on first. Written on the engine thread, read on the compositor thread —
// under a plain lock, because a frame is 16 ms and this is four words.
static NSLock *s_pubLock;
static void *s_pubTex;                  // eye L; unretained: the ring owns it
static void *s_pubTexR;                 // eye R of the same pair
static id<MTLSharedEvent> s_pubEvent;
static uint64_t s_pubValue;
static uint32_t s_pubGen;
static uint32_t s_publishes;
static uint32_t s_pubFresh, s_pubReuse; // counted by the compositor

static id<MTLDevice> s_dev;

/** PD_VP3D_EYE=WxH, parsed. Non-zero if the eye is pinned by the environment. */
static int pdEyePinned(int *w, int *h)
{
	int fw = 0, fh = 0;
	const char *s = getenv("PD_VP3D_EYE");
	if (s && sscanf(s, "%dx%d", &fw, &fh) == 2 && fw > 0 && fh > 0) {
		if (w) *w = fw;
		if (h) *h = fh;
		return 1;
	}
	return 0;
}

int pdVisionEyeIsPinned(void) { return pdEyePinned(NULL, NULL); }

/**
 * PD_VP3D_EYE=WxH forces the eye target size.
 *
 * Otherwise the base is the PANEL's (D-058, above): its angular width at its
 * committed distance times the compositor's pixels-per-radian, at the panel's
 * own aspect, clamped by the view and by PD_EYE_BUDGET_DIM.
 *
 * The override is a test instrument with one real job: the M2 pixel gate diffs
 * the engine's own screenshot of the eye against the committed 1280x720 oracle
 * frame, and that is only a pixel comparison if the eye is 1280x720 — aspect
 * AND size are determinism inputs for this port (docs/build.md §Traps M1). A
 * pinned eye is also the one case where the panel pass still aspect-FITS the
 * quad, because the eye cannot follow the panel and something has to give.
 */
static void pdEyeBaseSize(int *w, int *h)
{
	if (pdEyePinned(w, h)) {
		return;
	}
	// The compositor's own per-view logical size, once a drawable has been seen
	// (D-057). Before that — the first frame or two of the very first entry —
	// the fallback stands in. It is the CLAMP now, not the answer.
	int cw = atomic_load(&s_compW), ch = atomic_load(&s_compH);
	if (cw <= 0 || ch <= 0) {
		cw = PD_EYE_FALLBACK_W;
		ch = PD_EYE_FALLBACK_H;
	}

	const float halfW = fmaxf(0.05f, s_cmtHalfW);
	const float halfH = fmaxf(0.05f, s_cmtHalfH);
	const float dist  = fmaxf(0.1f,  s_cmtDist);
	const float aspect = halfW / halfH;

	// Pixels per radian, from the view that is actually sampling the room.
	const float fovX = (float)atomic_load(&s_compFovMilliRad) / 1000.0f;
	float fw;
	if (fovX > 0.1f) {
		// The panel's angular width as seen from the anchor: 2*atan(halfW/dist).
		const float angW = 2.0f * atanf(halfW / dist);
		fw = ((float)cw / fovX) * angW;
	} else {
		// No projection has been read yet. The view's own width is the only
		// number available, and the budget below caps it anyway.
		fw = (float)cw;
	}

	float fh = fw / aspect;
	// The AREA budget (D-062), applied along the panel's own shape so a wide
	// panel spends its pixels on width instead of being cropped to 2560.
	const float area = fw * fh;
	if (area > (float)PD_EYE_BUDGET_PX) {
		const float k = sqrtf((float)PD_EYE_BUDGET_PX / area);
		fw *= k;
		fh *= k;
	}
	if (fw > (float)PD_EYE_MAX_DIM) { fw = (float)PD_EYE_MAX_DIM; fh = fw / aspect; }
	if (fh > (float)PD_EYE_MAX_DIM) { fh = (float)PD_EYE_MAX_DIM; fw = fh * aspect; }
	if (fw > (float)cw) { fw = (float)cw; fh = fw / aspect; }
	if (fh > (float)ch) { fh = (float)ch; fw = fh * aspect; }

	*w = (int)lroundf(fmaxf(64.0f, fw));
	*h = (int)lroundf(fmaxf(64.0f, fh));
}

/** Which of the sources pdEyeBaseSize() answered from. */
static const char *pdEyeBaseSource(void)
{
	if (pdEyePinned(NULL, NULL)) {
		return "env";
	}
	if (atomic_load(&s_compFovMilliRad) > 0) {
		return "panel";
	}
	return (atomic_load(&s_compW) > 0) ? "compositor" : "default";
}

float pdVisionEyePanelAspect(void)
{
	return (s_cmtHalfH > 0.0f) ? (s_cmtHalfW / s_cmtHalfH) : 0.0f;
}

void pdVisionEyeNotePanelGeometry(float halfW, float halfH, float dist)
{
	// Live only: the compositor draws the quad at THIS shape every frame, so a
	// drag stretches the picture and the feedback is instant. Nothing is
	// re-wrapped until the commit below.
	s_panelHalfW = halfW;
	s_panelHalfH = halfH;
	s_panelDist  = dist;
}

void pdVisionEyeCommitPanel(void)
{
	if (s_cmtHalfW == s_panelHalfW && s_cmtHalfH == s_panelHalfH
	    && s_cmtDist == s_panelDist) {
		return;
	}
	s_cmtHalfW = s_panelHalfW;
	s_cmtHalfH = s_panelHalfH;
	s_cmtDist  = s_panelDist;
	if (pdEyePinned(NULL, NULL)) {
		return;
	}
	atomic_store(&s_resizeAsked, 1);
}

void pdVisionEyeNoteCompositorFovX(float radians)
{
	if (!(radians > 0.1f) || radians > 6.0f) {
		return;
	}
	const int mr = (int)lroundf(radians * 1000.0f);
	const int was = atomic_load(&s_compFovMilliRad);
	// A degree of jitter in a projection matrix must not re-wrap the ring.
	if (was > 0 && abs(mr - was) < 10) {
		return;
	}
	atomic_store(&s_compFovMilliRad, mr);
	NSLog(@"perfectdark: [3d] compositor view fov_x %.1f deg", (double)(radians * 57.2957795f));
	if (pdEyePinned(NULL, NULL)) {
		return;
	}
	atomic_store(&s_resizeAsked, 1);
}

void pdVisionEyeNoteCompositorViewSize(int w, int h)
{
	if (w <= 0 || h <= 0) {
		return;
	}
	if (atomic_load(&s_compW) == w && atomic_load(&s_compH) == h) {
		return;
	}
	atomic_store(&s_compW, w);
	atomic_store(&s_compH, h);
	NSLog(@"perfectdark: [3d] compositor per-view size %dx%d", w, h);
	if (getenv("PD_VP3D_EYE")) {
		// A pinned eye is a measurement instrument and the compositor does not
		// get to move it; the panel's own aspect correction already handles an
		// eye that is not the drawable's shape.
		NSLog(@"perfectdark: [3d] PD_VP3D_EYE is set — the eye stays pinned");
		return;
	}
	// The ring is re-wrapped by the engine thread at a frame boundary, through
	// exactly the machinery the Render Resolution row uses (M6).
	atomic_store(&s_resizeAsked, 1);
}

/**
 * The size the ring WANTS: the base, scaled by the Render Resolution row.
 *
 * The percentage multiplies the base rather than replacing it, which is what
 * keeps the row measurable inside a gate that has pinned the eye to the
 * oracle's 1280x720 (50 % of that is 640x360) and leaves every 100 % run — the
 * shipped default, and every M1-M4 artifact — byte-for-byte as it was.
 *
 * Rounded DOWN to a multiple of 8 in both axes: a glReadPixels of the eye and
 * the panel's own mipmap chain are both happier on a multiple of 8, and the
 * couple of pixels it costs are invisible against a percentage slider.
 */
static void pdEyeWantedSize(int *w, int *h)
{
	int bw = 0, bh = 0;
	pdEyeBaseSize(&bw, &bh);
	float pct = s_renderPct;
	if (pct < 40.0f) pct = 40.0f;
	if (pct > 100.0f) pct = 100.0f;
	int nw = (int)((float)bw * pct / 100.0f) & ~7;
	int nh = (int)((float)bh * pct / 100.0f) & ~7;
	if (nw < 64) nw = 64;
	if (nh < 64) nh = 64;
	*w = nw;
	*h = nh;
}

void pdVisionEyeGetSize(int *w, int *h)
{
	if (s_active && s_eyeW > 0) {
		if (w) *w = s_eyeW;
		if (h) *h = s_eyeH;
		return;
	}
	pdEyeWantedSize(w ? w : &s_eyeW, h ? h : &s_eyeH);
}

// ---------------------------------------------------------------------------
// Wrapping. Engine thread only, with the ANGLE context current.
// ---------------------------------------------------------------------------

static void pdEyeFreeSlot(EGLDisplay dpy, int i, int eye)
{
	struct PDEyeBuf *b = &s_ring[i][eye];
	if (b->fbo) { glDeleteFramebuffers(1, &b->fbo); b->fbo = 0; }
	if (b->tex) { glDeleteTextures(1, &b->tex); b->tex = 0; }
	if (b->img && dpy != EGL_NO_DISPLAY) { eglDestroyImageKHR(dpy, b->img); }
	b->img = NULL;
	if (b->mtl) { CFRelease(b->mtl); b->mtl = NULL; }
}

static int pdEyeWrapSlot(EGLDisplay dpy, int i, int eye, int w, int h)
{
	struct PDEyeBuf *b = &s_ring[i][eye];

	// RGBA8Unorm, not BGRA: GL's RGBA byte order IS this texture's byte order,
	// so read_screen_pixels' ES-3.0 GL_RGBA readback (patch 0006) returns the
	// same bytes off the eye that it returns off the window, and the M2 pixel
	// gate is comparing pictures rather than channel orders. The panel pass
	// samples it through an _sRGB view so the bytes reach the drawable
	// unchanged (see PDImmersive.m).
	MTLTextureDescriptor *td =
		[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
		                                                   width:(NSUInteger)w
		                                                  height:(NSUInteger)h
		                                               mipmapped:NO];
	td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	// SHARED, NOT PRIVATE, AND IT IS THE SCREENSHOT THAT DECIDES IT (M2 trap).
	//
	// Private is the obvious choice for a render target and it ABORTS. PD reads
	// the finished frame back through glReadPixels (F12, --screenshot-frame -
	// this port's whole regression vehicle), and for an EGLImage-backed colour
	// attachment ANGLE-Metal serves that read with
	// MTLSimTexture getBytes:..., which is illegal on a Private texture: the
	// simulator driver takes it to XPC and calls abort(), so the run dies with
	// an Abort trap whose backtrace is all MTLSimDriver and looks nothing like
	// a renderer bug. Shared makes the read legal.
	//
	// The cost is real but not M2's problem: a Shared render target forfeits
	// lossless compression, which is bandwidth on a 3840x2160 eye. The cure, if
	// M5's device numbers ask for one, is q2repro's shape - keep the eye Private
	// and blit it into a Shared staging texture only when a screenshot is
	// actually taken (xr3_stage_texture) - and PD_VP3D_EYE_PRIVATE=1 is here so
	// that A/B needs no rebuild.
	const char *priv = getenv("PD_VP3D_EYE_PRIVATE");
	td.storageMode = (priv && *priv && *priv != '0')
		? MTLStorageModePrivate : MTLStorageModeShared;
	id<MTLTexture> t = [s_dev newTextureWithDescriptor:td];
	if (!t) {
		NSLog(@"perfectdark: [3d] eye %d/%d: no %dx%d MTLTexture", i, eye, w, h);
		return 0;
	}

	EGLImageKHR img = eglCreateImageKHR(dpy, EGL_NO_CONTEXT, EGL_METAL_TEXTURE_ANGLE,
	                                    (EGLClientBuffer)(__bridge void *)t, NULL);
	if (img == EGL_NO_IMAGE_KHR) {
		NSLog(@"perfectdark: [3d] eye %d/%d: eglCreateImageKHR(EGL_METAL_TEXTURE_ANGLE) failed 0x%x",
			i, eye, eglGetError());
		return 0;
	}

	GLuint tex = 0, fbo = 0;
	glGenTextures(1, &tex);
	glBindTexture(GL_TEXTURE_2D, tex);
	glEGLImageTargetTexture2DOES(GL_TEXTURE_2D, (GLeglImageOES)img);
	glGenFramebuffers(1, &fbo);
	glBindFramebuffer(GL_FRAMEBUFFER, fbo);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
	glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER, s_depthRbo);

	GLenum st = glCheckFramebufferStatus(GL_FRAMEBUFFER);
	glBindFramebuffer(GL_FRAMEBUFFER, 0);
	if (st != GL_FRAMEBUFFER_COMPLETE) {
		NSLog(@"perfectdark: [3d] eye %d/%d: FBO INCOMPLETE 0x%x", i, eye, st);
		glDeleteFramebuffers(1, &fbo);
		glDeleteTextures(1, &tex);
		eglDestroyImageKHR(dpy, img);
		return 0;
	}

	b->mtl = (void *)CFBridgingRetain(t);
	b->img = img;
	b->tex = tex;
	b->fbo = fbo;
	return 1;
}

int pdVisionEyeActivate(void)
{
	if (s_active) {
		return 1;
	}
	EGLDisplay dpy = eglGetCurrentDisplay();
	if (dpy == EGL_NO_DISPLAY) {
		NSLog(@"perfectdark: [3d] eye activate: no current EGL display");
		return 0;
	}
	if (!s_pubLock) {
		s_pubLock = [NSLock new];
	}

	// ANGLE's own device. The assert is q2repro's devMatch check: an EGLImage
	// from a texture on a different MTLDevice is rejected by ANGLE's ImageMtl,
	// and on visionOS the system default device is both ANGLE's and the
	// compositor's — so a mismatch here would be a real change in the OS, and
	// it must be loud rather than a black panel.
	s_dev = MTLCreateSystemDefaultDevice();
	if (!s_dev) {
		NSLog(@"perfectdark: [3d] eye activate: no MTLDevice");
		return 0;
	}
	EGLAttrib devAttr = 0;
	int devMatch = -1;
	if (eglQueryDisplayAttribEXT(dpy, EGL_DEVICE_EXT, &devAttr) && devAttr) {
		EGLAttrib mtl = 0;
		if (eglQueryDeviceAttribEXT((EGLDeviceEXT)devAttr, EGL_METAL_DEVICE_ANGLE, &mtl)) {
			devMatch = ((void *)mtl == (__bridge void *)s_dev) ? 1 : 0;
		}
	}

	pdEyeWantedSize(&s_eyeW, &s_eyeH);

	glGenRenderbuffers(1, &s_depthRbo);
	glBindRenderbuffer(GL_RENDERBUFFER, s_depthRbo);
	glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, s_eyeW, s_eyeH);
	glBindRenderbuffer(GL_RENDERBUFFER, 0);

	int ok = 1;
	for (int i = 0; i < PD_EYE_RING && ok; i++) {
		for (int e = 0; e < 2; e++) {
			if (!pdEyeWrapSlot(dpy, i, e, s_eyeW, s_eyeH)) {
				ok = 0;
				break;
			}
		}
	}
	if (!ok) {
		for (int i = 0; i < PD_EYE_RING; i++) {
			for (int e = 0; e < 2; e++) {
				pdEyeFreeSlot(dpy, i, e);
			}
		}
		glDeleteRenderbuffers(1, &s_depthRbo);
		s_depthRbo = 0;
		s_wrapFailed = 1;
		return 0;
	}

	// The completion listener that retires a pair. Its own serial queue, off
	// the engine thread and off the compositor thread: all it does is
	// decrement, and it must never be the thing a frame waits behind.
	if (!s_listener) {
		s_listenerQueue = dispatch_queue_create("com.rebelancap.perfectdark.eyeretire",
			DISPATCH_QUEUE_SERIAL);
		s_listener = [[MTLSharedEventListener alloc] initWithDispatchQueue:s_listenerQueue];
	}
	atomic_store(&s_inFlight, 0);
	atomic_store(&s_inFlightPeak, 0);
	s_stalls = 0;
	s_stallTimeouts = 0;
	s_eyeRenders = 0;
	s_eye = PD_EYE_LEFT;
	s_ringIndex = 0;
	s_fboComplete = 1;
	s_wrapFailed = 0;
	s_active = 1;
	// Said ONCE per entry, and it is the M2 acceptance line: the wrap took, the
	// FBO is complete, and the device the texture lives on is ANGLE's.
	NSLog(@"perfectdark: [3d] eye targets: %dx%d ring=%d eyes=2 FBO COMPLETE devMatch=%d",
		s_eyeW, s_eyeH, PD_EYE_RING, devMatch);
	return 1;
}

void pdVisionEyeDeactivate(void)
{
	if (!s_active) {
		return;
	}
	s_active = 0;
	[s_pubLock lock];
	s_pubTex = NULL;
	s_pubTexR = NULL;
	s_pubEvent = nil;
	s_pubValue = 0;
	[s_pubLock unlock];

	EGLDisplay dpy = eglGetCurrentDisplay();
	// Everything ANGLE has in flight against these textures retires before we
	// free them: the compositor's last sample is already past (the loop is
	// stopped before this is called) but ANGLE's own queue may not be.
	glFinish();
	for (int i = 0; i < PD_EYE_RING; i++) {
		for (int e = 0; e < 2; e++) {
			pdEyeFreeSlot(dpy, i, e);
		}
	}
	if (s_depthRbo) {
		glDeleteRenderbuffers(1, &s_depthRbo);
		s_depthRbo = 0;
	}
	s_fboComplete = 0;
	s_eye = PD_EYE_LEFT;
	const uint64_t renders = s_eyeRenders;
	s_eyeRenders = 0;
	atomic_store(&s_inFlight, 0);
	NSLog(@"perfectdark: [3d] eye targets torn down (publishes=%u eye_renders=%llu"
	       " inflight_peak=%d stalls=%u/%u)",
		s_publishes, (unsigned long long)renders,
		atomic_load(&s_inFlightPeak), s_stalls, s_stallTimeouts);
}

unsigned int pdVisionEyeFBO(int *w, int *h)
{
	if (!s_active) {
		return 0;
	}
	if (w) *w = s_eyeW;
	if (h) *h = s_eyeH;
	return s_ring[s_ringIndex][s_eye].fbo;
}

// ---------------------------------------------------------------------------
// Which eye, the counters, and the in-flight bound. Engine thread.
// ---------------------------------------------------------------------------

void pdVisionSetEye(int eye)
{
	s_eye = (eye == PD_EYE_RIGHT) ? PD_EYE_RIGHT : PD_EYE_LEFT;
}

int pdVisionGetEye(void)
{
	return s_active ? s_eye : PD_EYE_LEFT;
}

int pdVisionEyesPerFrame(void)
{
	return s_active ? 2 : 1;
}

unsigned long long pdVisionEyeRenders(void)
{
	return s_eyeRenders;
}

void pdVisionEyeNoteRender(void)
{
	// Only while the ring is live: gfx_run_eye calls this on every visionOS
	// frame, and `eye_renders` has to be 2 x frames in 3D and 0 in 2D for the
	// number to mean anything (plan §4 M3).
	if (!s_active) {
		return;
	}
	s_eyeRenders++;
	// One EYE's worth of classes, snapshotted at the eye boundary - the only
	// place the numbers describe a whole frame and nothing more.
	for (int i = 0; i < 4; i++) {
		s_clsLast[i] = s_clsCur[i];
		s_clsCur[i] = 0;
	}
	// Said once, 300 frames in: a headless --exit-frame run never tears the
	// ring down (exit(0) skips it), so the class counts would otherwise only
	// ever be visible to a live bridge session.
	if (s_eyeRenders == 600) {
		NSLog(@"perfectdark: [3d] projection classes after 300 frames:"
		       " world=%llu sky=%llu gun=%llu flat=%llu",
			(unsigned long long)s_clsWorld, (unsigned long long)s_clsSky,
			(unsigned long long)s_clsGun, (unsigned long long)s_clsFlat);
	}
}

void pdVisionStereoNoteClass(int cls)
{
	switch (cls) {
		case 1:  s_clsSky++; break;
		case 2:  s_clsGun++; break;
		case 3:  s_clsFlat++; break;
		default: s_clsWorld++; break;
	}
	if (cls >= 0 && cls < 4) {
		s_clsCur[cls]++;
	}
}

void pdVisionStereoNoteGunDepth(float depth)
{
	if (!(depth > 0.0f)) {
		return;
	}
	if (s_gunDepthN == 0 || depth < s_gunDepthMin) s_gunDepthMin = depth;
	if (s_gunDepthN == 0 || depth > s_gunDepthMax) s_gunDepthMax = depth;
	s_gunDepthSum += depth;
	s_gunDepthN++;
}

// ---------------------------------------------------------------------------
// D-060: THE VIEWMODEL'S NEAREST VERTEX, AND THE FRAME'S OWN FACTS
// ---------------------------------------------------------------------------
//
// D-055 converged the gun at its ORIGIN depth, which is the right plane for the
// grip and the wrong one for everything in front of it: the barrel, the sights
// and the muzzle all sat NEARER than the convergence plane, so they carried
// CROSSED disparity and popped out of the panel - in front of an ammo HUD that
// is 2D, at zero disparity, and drawn over them. The user: "the gun goes behind
// the ammo hud, but the gun, depth wise, is much closer to me, so a little
// disorienting. HUD should probably be closest to me?"
//
// quake3e D-028 v2's rule is that the weapon sits AT the panel and never in
// front of it. So the plane is the gun's NEAREST vertex, measured: gfx_pc hands
// every gun-classed vertex's clip w (which is its view depth under every
// projection this engine loads) to pdVisionStereoNoteGunVertex, and the minimum
// over a whole frame becomes the convergence for the NEXT frame's pair. Frozen
// for the pair, never re-read between the two eye walks, because L and R
// disagreeing about the convergence plane is a worse artefact than a frame of
// latency on a plane that moves at walking pace.
static float s_gunNearMeas;           // this frame's running minimum
static float s_gunNearUse;            // frozen for the pair, what the fold reads
static uint32_t s_gunVertN;           // vertices seen this frame
static uint32_t s_gunVertNLast;

// One eye of the last frame's own facts (gfx_pc publishes them at the tail of
// gfx_run). stereo_p_mul settles D-055's unsourced claim that "PD's lists
// MULTIPLY into the projection"; stereo_baked counts the loads that had the
// camera baked in, which is the whole of the bg.
static float s_bgScale = 1.0f;
static uint32_t s_pMul, s_pLoad, s_pBaked, s_depthRects;
// ...and the glare total over the session, because a per-frame count is zero
// whenever the player happens to be facing away from every light in the room,
// which is not the same fact as "the depth tag never arrives".
static uint64_t s_depthRectsTotal;

void pdVisionStereoNoteGunVertex(float depth)
{
	if (!(depth > 1.0f) || depth > 40000.0f) {
		return;
	}
	s_gunVertN++;
	if (s_gunNearMeas <= 0.0f || depth < s_gunNearMeas) {
		s_gunNearMeas = depth;
	}
}

float pdVisionStereoGunNear(void)
{
	return s_gunNearUse;
}

// ---------------------------------------------------------------------------
// D-061: THE NEAR LAW — two numbers, in units of the fold's own far asymptote
// ---------------------------------------------------------------------------
//
// U = |2*a*e/C| is the disparity at infinity: the whole of the depth the scene
// has BEHIND the panel, and the natural unit for the depth it is allowed in
// FRONT of it. Everything below is a multiple of U, so Crosshair Distance and
// Stereo Depth remain the only two knobs and the law rides on them.
//
//   N = 2.0   the world may come two asymptotes out of the panel and no more.
//             D_min = C/3 (254 units = 8.3 ft at the shipped defaults), where
//             the disparity is 33 px on a 2560 px eye - 1.04 deg, which the
//             headset fuses without effort. Before the clamp the same wall at
//             30 units read 402 px. The near field keeps real depth (the
//             panel is at 3.6 m and the clamp plane renders at ~1.8 m); it is
//             only the part that was never fusable that is spent.
//   G = 2.5   the viewmodel's FAR end. Strictly greater than N, and the world
//             only approaches N asymptotically, so the invariant is exact: the
//             gun is nearer than every world pixel it borders. The half-unit of
//             margin is not arbitrary - it is 8.3 px on the shipped 2560 px eye
//             (0.26 deg, about fifteen times stereoacuity, so the ordering is
//             SEEN and not merely true) and 3.9 px on the gate's pinned 1280 px
//             eye, which is what makes it MEASURABLE by a block match whose
//             resolution is one pixel. At 2.25 both of those halve and the
//             measurement stops being able to tell the two apart.
//   knee      the soft knee begins where the unclamped law would read
//             U*N*knee, i.e. at d = C/(1 + N*knee) = C/2 with knee 0.5. From
//             there the law bends smoothly (C1) into its asymptote instead of
//             breaking, so no edge of the picture carries a crease.
#define PD_STEREO_WORLD_N  2.00f
#define PD_STEREO_GUN_N    2.50f
#define PD_STEREO_KNEE     0.50f

/**
 * Is the stereo fold LIVE? Not "is this a visionOS build" — the engine code that
 * asks is compiled into every visionOS build and runs in 2D as well, where it
 * must do nothing at all. D-064's crosshair trace is the case that paid for
 * this: `cdExamLos08` touches the collision module's own static state, so a
 * trace running in a 2D `--fixed-step` replay is a determinism input the macOS
 * oracle does not have, and the M-001 gate is exactly the assertion that there
 * is no such thing.
 */
int pdVisionStereoIsActive(void)
{
	return s_active ? 1 : 0;
}

void pdVisionStereoNearLaw(float *outWorldN, float *outGunN, float *outKnee)
{
	if (outWorldN) *outWorldN = PD_STEREO_WORLD_N;
	if (outGunN)   *outGunN   = PD_STEREO_GUN_N;
	if (outKnee)   *outKnee   = PD_STEREO_KNEE;
}

/** Called once per host frame, from pdVisionEyeBeginPair. */
static void pdVisionStereoFreezeGunNear(void)
{
	s_gunNearUse = s_gunNearMeas;
	s_gunVertNLast = s_gunVertN;
	s_gunNearMeas = 0.0f;
	s_gunVertN = 0;
}

void pdVisionStereoNoteFrameFacts(float bgScale, uint32_t mulP, uint32_t loadP,
                                  uint32_t baked, uint32_t depthRects)
{
	s_bgScale = bgScale;
	s_pMul = mulP;
	s_pLoad = loadP;
	s_pBaked = baked;
	s_depthRects = depthRects;
	s_depthRectsTotal += depthRects;
}

// A runtime override of PD_VP3D_SHOWEYE, set by the bridge's `3d showeye`.
// -2 = no override, use the environment. It exists because the L-vs-R diff of
// PD's PAUSE MENU can only be taken live: a --fixed-step replay will not open
// the dialog at all (the engine's pad mask carries 0x1000 for 120 frames and
// menu_open stays 0 — docs/build.md §Traps earned Phase 6 M4), and while the
// dialog IS open the game is frozen, so two captures a few seconds apart from
// the SAME session are comparable frame-for-frame.
static int s_showEyeOverride = -2;

void pdVisionEyeSetShowEye(int eye)
{
	s_showEyeOverride = (eye == PD_EYE_LEFT || eye == PD_EYE_RIGHT) ? eye : -2;
	NSLog(@"perfectdark: [3d] showeye override -> %s",
		s_showEyeOverride == PD_EYE_LEFT ? "L" :
		s_showEyeOverride == PD_EYE_RIGHT ? "R" : "auto (the environment)");
}

int pdVisionEyeShowEye(void)
{
	if (s_showEyeOverride != -2) {
		return s_showEyeOverride;
	}
	static int cached = -2;
	if (cached == -2) {
		const char *e = getenv("PD_VP3D_SHOWEYE");
		cached = -1;
		if (e && *e) {
			if (*e == 'L' || *e == 'l' || *e == '0') cached = PD_EYE_LEFT;
			else if (*e == 'R' || *e == 'r' || *e == '1') cached = PD_EYE_RIGHT;
		}
		if (cached >= 0) {
			NSLog(@"perfectdark: [3d] PD_VP3D_SHOWEYE=%s — the mono panel and the"
			       " screenshot are eye %s", e, cached ? "R" : "L");
		}
	}
	return cached;
}

int pdVisionEyeIsCapture(int eye)
{
	if (!s_active) {
		return 1;
	}
	const int want = pdVisionEyeShowEye();
	// Default R: it is the LAST eye of the pair, so the capture reads a
	// framebuffer nothing has touched since, exactly as the 2D path does.
	return eye == (want >= 0 ? want : PD_EYE_RIGHT);
}

int pdVisionEyeInFlight(void)
{
	return atomic_load(&s_inFlight);
}

void pdVisionEyeBeginPair(void)
{
	if (!s_active) {
		return;
	}
	s_eye = PD_EYE_LEFT;
	// The gun's convergence plane is frozen HERE, for both eye walks (D-060).
	pdVisionStereoFreezeGunNear();
	if (atomic_load(&s_inFlight) <= 2) {
		return;
	}
	// Bounded, and loud if the bound is reached: a listener that never fires
	// must cost frames, never the session.
	s_stalls++;
	const uint64_t deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 200ull * 1000ull * 1000ull;
	while (atomic_load(&s_inFlight) > 2) {
		if (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) >= deadline) {
			s_stallTimeouts++;
			NSLog(@"perfectdark: [3d] in-flight stuck at %d for 200 ms — going on anyway"
			       " (stalls=%u timeouts=%u)",
				atomic_load(&s_inFlight), s_stalls, s_stallTimeouts);
			atomic_store(&s_inFlight, 0);
			return;
		}
		usleep(200);
	}
}

// ---------------------------------------------------------------------------
// The stereo fold's parameters, read by overlay patch 0030.
// ---------------------------------------------------------------------------

int pdVisionStereoFold(float *outOffset, float *outConvergence, float *outGunConvergence)
{
	if (!s_active) {
		return 0;
	}
	// PD_VP3D_STEREO_DEPTH=<pct> is the gate's instrument, read once. At 0 the
	// fold is the identity and the eye must reproduce the 2D oracle frame
	// EXACTLY — which is how the M3 replay proves the double display-list walk
	// has no side effects without also having to model the disparity.
	static int envRead;
	if (!envRead) {
		envRead = 1;
		const char *e = getenv("PD_VP3D_STEREO_DEPTH");
		if (e && *e) {
			s_depthPct = (float)atof(e);
			if (s_depthPct < 0.0f) s_depthPct = 0.0f;
			if (s_depthPct > 300.0f) s_depthPct = 300.0f;
			NSLog(@"perfectdark: [3d] PD_VP3D_STEREO_DEPTH=%s — stereo depth %.0f %%",
				e, (double)s_depthPct);
		}
	}
	const float e = PD_STEREO_HALFSEP * (s_depthPct / 100.0f);
	if (!(e > 1e-6f) && !(e < -1e-6f)) {
		// Stereo Depth 0 %: both eyes are the mono projection, and the L/R
		// captures must come out pixel-identical. That is an acceptance item,
		// so it is a real answer and not a rounding accident.
		if (outOffset) *outOffset = 0.0f;
		if (outConvergence) *outConvergence = s_conv;
		if (outGunConvergence) *outGunConvergence = s_gunConvOverride;
		return 1;
	}
	if (outOffset) {
		// Signed: +e shifts the camera to the RIGHT, which is eye R.
		*outOffset = (s_eye == PD_EYE_RIGHT) ? e : -e;
	}
	if (outConvergence) *outConvergence = s_conv;
	if (outGunConvergence) *outGunConvergence = s_gunConvOverride;
	return 1;
}

void pdVisionStereoSetDepthPct(float pct)
{
	if (pct < 0.0f) pct = 0.0f;
	if (pct > 300.0f) pct = 300.0f;   // D-061: the row's ceiling, the user's number
	s_depthPct = pct;
	NSLog(@"perfectdark: [3d] stereo depth %.0f %% (half-sep %.2f units)",
		(double)pct, (double)(PD_STEREO_HALFSEP * pct / 100.0f));
}

float pdVisionStereoDepthPct(void)
{
	return s_depthPct;
}

void pdVisionStereoSetConvergence(float units)
{
	// The row's own range, clamped here as well as in the sheet: a convergence
	// at or below zero puts the whole world behind the viewer's eyes.
	if (units < 10.0f) units = 10.0f;
	if (units > 5000.0f) units = 5000.0f;
	s_conv = units;
}

float pdVisionStereoConvergence(void)
{
	return s_conv;
}

// ---------------------------------------------------------------------------
// Render Resolution: the request, and the frame-boundary re-wrap (M6)
// ---------------------------------------------------------------------------

void pdVisionEyeSetRenderPct(float pct)
{
	if (pct < 40.0f) pct = 40.0f;
	if (pct > 100.0f) pct = 100.0f;
	if (fabsf(pct - s_renderPct) < 0.01f) {
		return;
	}
	s_renderPct = pct;
	atomic_store(&s_resizeAsked, 1);
	NSLog(@"perfectdark: [3d] render resolution %.0f %% asked (applies at the next frame boundary)",
		(double)pct);
}

float pdVisionEyeRenderPct(void)
{
	return s_renderPct;
}

void pdVisionEyeSampleBegin(void) { atomic_fetch_add(&s_sampling, 1); }
void pdVisionEyeSampleEnd(void)   { atomic_fetch_sub(&s_sampling, 1); }

/**
 * Re-wrap the ring at the new size. ENGINE THREAD, at a frame boundary, with
 * the ANGLE context current (pdVision3dFramePoll).
 *
 * THE ORDER IS THE WHOLE POINT, and it is the acquire contract read backwards:
 *
 *   1. UNPUBLISH. With the slot cleared, pdVisionEyeAcquire() can no longer
 *      hand a ring pointer to anybody, so no NEW compositor frame can start
 *      sampling the textures we are about to free. The panel falls back to the
 *      solid colour for the frame or two this takes, which is also the visible
 *      evidence in a screen recording that the row did something.
 *   2. DRAIN. A compositor frame that acquired just BEFORE the clear may still
 *      be between the acquire and its own retain, so wait for the sample
 *      bracket to empty — bounded at 200 ms, loud if it expires, and never
 *      freeing anything if it does (a stuck compositor must cost a setting,
 *      never the session).
 *   3. free and re-wrap, which is exactly deactivate + activate; both already
 *      do the glFinish, the EGLImage teardown and the FBO completeness check.
 *
 * Deactivate zeroes the session counters (publishes, eye_renders, the in-flight
 * peak) and that is deliberate: after a resize they describe a different eye,
 * and a gate comparing eye_renders against frames across the change would be
 * comparing two runs.
 */
void pdVisionEyeResizeIfPending(void)
{
	if (!atomic_load(&s_resizeAsked)) {
		return;
	}
	atomic_store(&s_resizeAsked, 0);
	if (!s_active) {
		// Nothing to re-wrap: the next pdVisionEyeActivate() reads the new
		// percentage through pdEyeWantedSize() by itself.
		return;
	}
	int w = 0, h = 0;
	pdEyeWantedSize(&w, &h);
	if (w == s_eyeW && h == s_eyeH) {
		return;
	}
	NSLog(@"perfectdark: [3d] eye resize %dx%d -> %dx%d (%.0f %%)",
		s_eyeW, s_eyeH, w, h, (double)s_renderPct);

	[s_pubLock lock];
	s_pubTex = NULL;
	s_pubTexR = NULL;
	s_pubEvent = nil;
	s_pubValue = 0;
	[s_pubLock unlock];

	int waited = 0;
	for (; waited < 200 && atomic_load(&s_sampling) > 0; waited++) {
		usleep(1000);
	}
	if (atomic_load(&s_sampling) > 0) {
		NSLog(@"perfectdark: [3d] eye resize ABANDONED — the compositor is still"
		       " sampling after %d ms (sampling=%d)", waited, atomic_load(&s_sampling));
		return;
	}

	pdVisionEyeDeactivate();
	if (!pdVisionEyeActivate()) {
		NSLog(@"perfectdark: [3d] eye resize FAILED to re-wrap at %dx%d —"
		       " the panel will hold its fallback colour", w, h);
	}
}

void pdVisionStereoSetGunConvergence(float units)
{
	s_gunConvOverride = (units > 0.0f) ? units : 0.0f;
	NSLog(@"perfectdark: [3d] gun convergence override %.2f units (0 = znear)",
		(double)s_gunConvOverride);
}

// ---------------------------------------------------------------------------
// Publish. Engine thread, at the point the 2D build would have swapped.
// ---------------------------------------------------------------------------

void pdVisionEyePublish(void)
{
	if (!s_active) {
		return;
	}
	// ONE publish per PAIR, at the end of eye R. Eye L's swap_buffers_begin
	// reaches here too — gfx_run_eye is the whole frame body for both eyes —
	// and must do nothing at all: the compositor may only ever see a slot whose
	// BOTH textures are finished, and the ring must advance once per frame.
	if (s_eye != PD_EYE_RIGHT) {
		return;
	}
	EGLDisplay dpy = eglGetCurrentDisplay();
	if (dpy == EGL_NO_DISPLAY) {
		return;
	}

	// The (event, value) ANGLE will signal once THIS frame's work has retired.
	// glFlush between create and copy is q2repro's order: the sync has to be
	// encoded into a command buffer that already carries the frame's draws.
	id<MTLSharedEvent> event = nil;
	uint64_t value = 0;
	EGLSync sync = eglCreateSync(dpy, EGL_SYNC_METAL_SHARED_EVENT_ANGLE, NULL);
	if (sync != EGL_NO_SYNC) {
		glFlush();
		void *evt = eglCopyMetalSharedEventANGLE(dpy, sync);
		EGLAttrib lo = 0, hi = 0;
		eglGetSyncAttrib(dpy, sync, EGL_SYNC_METAL_SHARED_EVENT_SIGNAL_VALUE_LO_ANGLE, &lo);
		eglGetSyncAttrib(dpy, sync, EGL_SYNC_METAL_SHARED_EVENT_SIGNAL_VALUE_HI_ANGLE, &hi);
		value = ((uint64_t)(uint32_t)hi << 32) | (uint32_t)lo;
		eglDestroySync(dpy, sync);
		event = (__bridge_transfer id<MTLSharedEvent>)evt;
	} else {
		// No shared-event sync on this display: fall back to the producer-side
		// hammer so the compositor cannot sample a half-drawn eye. Slow and
		// loud on purpose — it means the extension went away.
		static int said;
		if (!said) {
			said = 1;
			NSLog(@"perfectdark: [3d] no EGL_SYNC_METAL_SHARED_EVENT_ANGLE — glFinish per frame");
		}
		glFinish();
	}

	[s_pubLock lock];
	s_pubTex = s_ring[s_ringIndex][PD_EYE_LEFT].mtl;
	s_pubTexR = s_ring[s_ringIndex][PD_EYE_RIGHT].mtl;
	s_pubEvent = event;
	s_pubValue = value;
	s_pubGen++;
	[s_pubLock unlock];
	s_publishes++;

	// Backpressure (plan §2.6). The pair is in flight until ANGLE's own command
	// buffer signals the value we just published; the listener decrements, eye
	// L of a later frame waits if more than two are outstanding. Registered
	// AFTER the publish so the compositor can already be sampling it.
	if (event && s_listener) {
		const int n = atomic_fetch_add(&s_inFlight, 1) + 1;
		if (n > atomic_load(&s_inFlightPeak)) {
			atomic_store(&s_inFlightPeak, n);
		}
		[event notifyListener:s_listener
		              atValue:value
		                block:^(id<MTLSharedEvent> e, uint64_t v) {
			(void)e; (void)v;
			if (atomic_load(&s_inFlight) > 0) {
				atomic_fetch_sub(&s_inFlight, 1);
			}
		}];
	}

	// Advance so the next frame draws into a slot the compositor is not
	// sampling. Ring 3, so there are always two slots between producer and
	// consumer even when the consumer is a frame behind.
	s_ringIndex = (s_ringIndex + 1) % PD_EYE_RING;
	s_eye = PD_EYE_LEFT;
}

// ---------------------------------------------------------------------------
// Consume. Compositor thread.
// ---------------------------------------------------------------------------

/**
 * THE EVENT COMES BACK RETAINED (+1) AND THE CALLER MUST TRANSFER IT.
 *
 * Paid for once: handing the MTLSharedEvent back unretained segfaults inside
 * `-[MTLCommandBuffer encodeWaitForEvent:value:]`. The engine thread publishes
 * a new pair every frame, and each publish drops the previous event's last
 * reference — so the compositor thread, which acquired a frame earlier and is
 * only now encoding, is encoding against freed memory. It is a narrow window
 * and it hit within two thousand frames.
 *
 * The TEXTURE is different and is deliberately NOT retained: the ring owns all
 * three for the whole session, and the ring is only freed after the loop has
 * been stopped and waited for (pdVision3dApplyMode's exit path). So a raw
 * pointer to a ring slot cannot dangle the way a per-frame event can.
 */
void *pdVisionEyeAcquire(int eye, void **outEvent, unsigned long long *outValue,
                         unsigned int *outGen)
{
	void *tex = NULL;
	if (!s_pubLock) {
		return NULL;
	}
	[s_pubLock lock];
	tex = (eye == PD_EYE_RIGHT) ? s_pubTexR : s_pubTex;
	// Retained INSIDE the lock: outside it the publish may already have run.
	if (outEvent) *outEvent = s_pubEvent ? (void *)CFBridgingRetain(s_pubEvent) : NULL;
	if (outValue) *outValue = s_pubValue;
	if (outGen) *outGen = s_pubGen;
	[s_pubLock unlock];
	return tex;
}

void pdVisionEyeCountSample(int fresh)
{
	if (fresh) {
		s_pubFresh++;
	} else {
		s_pubReuse++;
	}
}

NSString *pdVisionEyeStateLines(void)
{
	int baseW = 0, baseH = 0;
	pdEyeBaseSize(&baseW, &baseH);
	return [NSString stringWithFormat:
		@"eye_active=%d\neye_px=%dx%d\neye_ring=%d\neye_slot=%d\neye_fb_complete=%d\n"
		 "eye_wrap_failed=%d\neye_publishes=%u\neye_pair_fresh=%u\neye_pair_reuse=%u\n"
		 "eye_renders=%llu\neyes_per_frame=%d\nin_flight=%d\nin_flight_peak=%d\n"
		 "eye_stalls=%u\neye_stall_timeouts=%u\nstereo_depth_pct=%.0f\n"
		 "stereo_conv=%.0f\nstereo_gun_conv=%.1f\nshow_eye=%d\n"
		 "eye_render_pct=%.0f\neye_base_px=%dx%d\neye_sampling=%d\n"
		 "stereo_cls_world=%llu\nstereo_cls_sky=%llu\nstereo_cls_gun=%llu\n"
		 "stereo_cls_flat=%llu\nstereo_frame_world=%u\nstereo_frame_sky=%u\n"
		 "stereo_frame_gun=%u\nstereo_frame_flat=%u\n"
		 "gun_depth_min=%.1f\ngun_depth_max=%.1f\ngun_depth_avg=%.1f\n"
		 "eye_base_src=%s\neye_aspect=%.3f\neye_panel_aspect=%.3f\n"
		 "eye_comp_px=%dx%d\neye_comp_fovx_deg=%.1f\nfootprint_mb=%.0f\n"
		 "stereo_bg_scale=%.3f\nstereo_p_load=%u\nstereo_p_mul=%u\n"
		 "stereo_p_baked=%u\nstereo_glare_rects=%u\nstereo_glare_total=%llu\n"
		 "stereo_gun_near=%.1f\n"
		 "stereo_gun_verts=%u\n",
		s_active, s_eyeW, s_eyeH, PD_EYE_RING, s_ringIndex, s_fboComplete,
		s_wrapFailed, s_publishes, s_pubFresh, s_pubReuse,
		(unsigned long long)s_eyeRenders, pdVisionEyesPerFrame(),
		atomic_load(&s_inFlight), atomic_load(&s_inFlightPeak),
		s_stalls, s_stallTimeouts, (double)s_depthPct,
		(double)s_conv, (double)s_gunConvOverride, pdVisionEyeShowEye(),
		(double)s_renderPct, baseW, baseH, atomic_load(&s_sampling),
		(unsigned long long)s_clsWorld, (unsigned long long)s_clsSky,
		(unsigned long long)s_clsGun, (unsigned long long)s_clsFlat,
		s_clsLast[0], s_clsLast[1], s_clsLast[2], s_clsLast[3],
		(double)s_gunDepthMin, (double)s_gunDepthMax,
		(double)(s_gunDepthN ? s_gunDepthSum / (float)s_gunDepthN : 0.0f),
		pdEyeBaseSource(),
		(double)(s_eyeH > 0 ? (float)s_eyeW / (float)s_eyeH : 0.0f),
		(double)pdVisionEyePanelAspect(),
		atomic_load(&s_compW), atomic_load(&s_compH),
		(double)((float)atomic_load(&s_compFovMilliRad) / 1000.0f * 57.2957795f),
		(double)pdVisionEyeFootprintMB(),
		(double)s_bgScale, s_pLoad, s_pMul, s_pBaked, s_depthRects,
		(unsigned long long)s_depthRectsTotal,
		(double)s_gunNearUse, s_gunVertNLast];
}

/**
 * What the eye ring and the panel copies cost in MB, at the size now live.
 *
 * The arithmetic (docs/memory-math.md): PD_EYE_RING pairs x 2 eyes of RGBA8,
 * ONE shared depth24/stencil8 renderbuffer for all of them (pdEyeWrapSlot
 * attaches s_depthRbo to every slot), and the compositor's two mipmapped copy
 * textures at 4/3 of a flat one. This is the number D-057 could not report and
 * the device therefore paid 1086 MB for without anyone seeing it coming.
 */
float pdVisionEyeFootprintMB(void)
{
	int w = s_eyeW, h = s_eyeH;
	if (w <= 0 || h <= 0) {
		pdEyeWantedSize(&w, &h);
	}
	const double px = (double)w * (double)h * 4.0;
	const double bytes = px * (double)(PD_EYE_RING * 2)   // the ring
	                   + px                                // the shared depth RBO
	                   + px * 2.0 * 4.0 / 3.0;             // the two panel copies
	return (float)(bytes / (1024.0 * 1024.0));
}

#endif // TARGET_OS_VISION
