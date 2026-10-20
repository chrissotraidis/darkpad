// gfx_angle_egl.mm — the ANGLE/EGL context seam for Perfect Dark.
//
// The port's window manager (port/fast3d/gfx_sdl2.cpp) normally asks SDL for a
// GL context. On Apple platforms that context is either desktop GL 4.1 (macOS,
// deprecated) or EAGL (iOS, deprecated and absent on visionOS), so the port's
// substrate is ANGLE: a real OpenGL ES 3.0 context served by ANGLE's Metal
// backend, which SDL cannot hand us through SDL_GL_*. This file creates it.
//
// The shape is the family's (dhewm3-ios/app/ios/ios_angle.mm,
// realrtcw-ios/app/Sources/ios_egl.m), ported from SDL3 to SDL2:
//
//   SDL_Metal_CreateView(window)  -> SDL_Metal_GetLayer() -> CAMetalLayer*
//   eglGetPlatformDisplayEXT(EGL_PLATFORM_ANGLE_ANGLE, {TYPE_METAL_ANGLE})
//   eglCreateWindowSurface(dpy, cfg, (EGLNativeWindowType)layer, NULL)
//   ES 3.0 context; eglSwapBuffers to present; eglSwapInterval for vsync.
//
// The window must be created with SDL_WINDOW_METAL and WITHOUT
// SDL_WINDOW_OPENGL: SDL must not try to make a GL context of its own.
//
// Everything here is compiled only when PD_GL_ANGLE is on. With it off the
// file is not built at all and the port keeps SDL's own GL path byte for byte.
#import <QuartzCore/CAMetalLayer.h>
#import <Foundation/Foundation.h>

#include <string.h>
#include <stdlib.h>
#include <stdio.h>

#include <SDL.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>

#ifndef EGL_PLATFORM_ANGLE_ANGLE
#define EGL_PLATFORM_ANGLE_ANGLE 0x3202
#endif
#ifndef EGL_PLATFORM_ANGLE_TYPE_ANGLE
#define EGL_PLATFORM_ANGLE_TYPE_ANGLE 0x3203
#endif
#ifndef EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE
#define EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE 0x3489
#endif

#include <TargetConditionals.h>
#ifndef TARGET_OS_VISION
#define TARGET_OS_VISION 0
#endif

#if TARGET_OS_VISION
/*
 * The visionOS 3D mode's half of this file (Phase 6 M2, D-048).
 *
 * Declared here rather than by including app/vision3d/PDVision3D.h: this file
 * is compiled by CMake as the ANGLE glue (PD_ANGLE_GLUE) and has no search
 * path into the shell, while the symbols themselves are linked in from the
 * visionOS app target. On iOS TARGET_OS_VISION is 0 and every line below
 * vanishes at the preprocessor, so the iOS build of this file is byte for byte
 * what it was before M2.
 */
extern "C" int pdVisionEyeActivate(void);
extern "C" void pdVisionEyeDeactivate(void);
extern "C" void pdVisionEyeGetSize(int *w, int *h);
extern "C" void pdVisionEyePublish(void);
static int s_vision3d;
#endif

static EGLDisplay s_dpy = EGL_NO_DISPLAY;
static EGLConfig s_cfg;
static EGLContext s_ctx = EGL_NO_CONTEXT;
static EGLSurface s_surf = EGL_NO_SURFACE;
static SDL_MetalView s_view;
static SDL_Window *s_wnd;
static CAMetalLayer *s_layer;
static int s_interval = 1;
// eglSwapBuffers calls on the window surface, for the bridge's `state`: the
// instrument that shows nothing is presented while the app is in the
// background (D-075). Written on the game thread only; a torn read is harmless.
static volatile unsigned long long s_swaps;

extern "C" unsigned long long pdAngleSwapCount(void)
{
	return s_swaps;
}

/**
 * The UIView SDL created for the game, so the shell can reach the UIWindow it
 * lives in.
 *
 * Needed because of D-038: once the app declares a UIScene manifest, a UIWindow
 * that SDL built the pre-scene way (-initWithFrame:, no windowScene) appears in
 * NEITHER UIApplication.windows NOR any scene's windows array. It exists, SDL
 * holds it, the renderer draws into its layer - and nothing in UIKit can find
 * it, so it is never composited and the screen is black. Measured on lane 1:
 * engine running at 60 fps, 4634 frames, a portrait 1320x2868 drawable where
 * 2868x1320 was expected, touch_overlay=none, and a black screenshot.
 *
 * This is the one handle that always works: the view is the SDL_MetalView the
 * ANGLE surface was created from. app/ios/PDSceneDelegate.m grafts from here.
 */
extern "C" void *pdAngleGetHostView(void)
{
	return (void *)s_view;
}

/** SDL's window, for the shell's size watch (app/ios/PDGeometry.m, D-077). */
extern "C" void *pdAngleGetSDLWindow(void)
{
	return (void *)s_wnd;
}

/**
 * PD_ANGLE_DRAWABLE=WxH forces the drawable (and so the render resolution) to a
 * fixed size instead of the window's own.
 *
 * The seeded replay is this port's regression vehicle and it is only a pixel
 * gate if both sides render the same number of pixels with the same aspect. The
 * macOS oracle runs 1280x720; an iPhone's drawable is whatever the panel is
 * (2532x1170 on the lane-3 device), which is a different aspect and therefore a
 * different picture, not a regression. With this set the layer still presents
 * full-screen - the compositor scales it - so the run is otherwise identical.
 *
 * Test instrument only: nothing sets it in normal play.
 */
static int pdAngleForcedSize(int *w, int *h)
{
	const char *s = getenv("PD_ANGLE_DRAWABLE");
	int fw = 0, fh = 0;
	if (!s || sscanf(s, "%dx%d", &fw, &fh) != 2 || fw <= 0 || fh <= 0) {
		return 0;
	}
	*w = fw;
	*h = fh;
	return 1;
}

/**
 * PD_IOS_RENDER_SCALE=N renders at N pixels per point instead of the panel's
 * own scale.
 *
 * Two uses, and only two. (1) The seeded replay: the M-001 gate is only a pixel
 * gate if both sides draw the same number of pixels at the same aspect, and the
 * committed oracle frame is 844x390 (artifacts/oracle/sim-gate/) - so
 * scripts/sim-validate.sh runs the replay at scale 1 and the rest of the run at
 * the panel's scale, where the native-resolution assertion lives. (2) A render
 * scale lever if Phase 3 ever needs one on a device.
 *
 * It works where PD_ANGLE_DRAWABLE does not: ANGLE recomputes the drawable from
 * the layer's bounds x contentsScale every frame, so forcing drawableSize is
 * overwritten, while changing contentsScale is exactly the input it recomputes
 * from (docs/build.md §Traps, M1).
 */
static double pdAngleRenderScale(void)
{
	const char *s = getenv("PD_IOS_RENDER_SCALE");
	if (!s || !*s) {
		return 0.0;
	}
	double scale = atof(s);
	return (scale > 0.0 && scale <= 8.0) ? scale : 0.0;
}

/**
 * PD_IOS_RENDER_FRACTION=F is the settings page's render-scale row: F is a
 * fraction of the PANEL's own scale rather than an absolute pixels-per-point,
 * because "half resolution" is the thing a player chooses and 1.5 is not.
 *
 * It is applied against the layer's native contentsScale, remembered on the
 * first call because after that call the layer's scale is ours and no longer
 * the panel's. PD_IOS_RENDER_SCALE always wins: the gates set it so the replay
 * draws the oracle's own resolution, and a gate must not be at the mercy of a
 * setting a previous run left in NSUserDefaults.
 */
static double pdAngleRenderFraction(void)
{
	const char *s = getenv("PD_IOS_RENDER_FRACTION");
	if (!s || !*s) {
		return 0.0;
	}
	double f = atof(s);
	return (f > 0.0 && f <= 4.0 && f != 1.0) ? f : 0.0;
}

/** Returns 1 if the override took, so the caller skips SDL's own size. */
static int pdAngleApplyRenderScale(void)
{
	static double s_nativeScale = 0.0;
	if (s_layer && s_nativeScale <= 0.0) {
		s_nativeScale = s_layer.contentsScale;
	}

	double scale = pdAngleRenderScale();
	if (scale <= 0.0) {
		const double f = pdAngleRenderFraction();
		if (f > 0.0 && s_nativeScale > 0.0) {
			scale = s_nativeScale * f;
		}
	}
	if (scale <= 0.0 || !s_layer) {
		return 0;
	}
	s_layer.contentsScale = scale;
	s_layer.drawableSize = CGSizeMake(s_layer.bounds.size.width * scale,
	                                  s_layer.bounds.size.height * scale);
	fprintf(stderr, "perfectdark: PD_IOS_RENDER_SCALE=%.2f -> drawable %.0fx%.0f\n",
		scale, s_layer.drawableSize.width, s_layer.drawableSize.height);
	return 1;
}

extern "C" int pdAngleInit(SDL_Window *wnd, char *errbuf, int errlen)
{
#define FAIL(...) do { snprintf(errbuf, errlen, __VA_ARGS__); return 0; } while (0)

	s_wnd = wnd;
	s_view = SDL_Metal_CreateView(wnd);
	if (!s_view) {
		FAIL("SDL_Metal_CreateView: %s", SDL_GetError());
	}

	s_layer = (__bridge CAMetalLayer *)SDL_Metal_GetLayer(s_view);
	if (!s_layer) {
		FAIL("no CAMetalLayer behind the SDL window");
	}

	int pw = 0, ph = 0;
	if (pdAngleApplyRenderScale()) {
		pw = (int)lround(s_layer.drawableSize.width);
		ph = (int)lround(s_layer.drawableSize.height);
	} else {
		SDL_Metal_GetDrawableSize(wnd, &pw, &ph);
		pdAngleForcedSize(&pw, &ph);
		if (pw > 0 && ph > 0) {
			s_layer.drawableSize = CGSizeMake(pw, ph);
		}
	}

	PFNEGLGETPLATFORMDISPLAYEXTPROC getPlatformDisplayEXT =
		(PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
	if (!getPlatformDisplayEXT) {
		FAIL("no eglGetPlatformDisplayEXT (is this ANGLE?)");
	}

	EGLint dattr[] = { EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE };
	s_dpy = getPlatformDisplayEXT(EGL_PLATFORM_ANGLE_ANGLE, (void *)EGL_DEFAULT_DISPLAY, dattr);
	if (s_dpy == EGL_NO_DISPLAY) {
		FAIL("no ANGLE-Metal display");
	}

	EGLint maj = 0, min = 0;
	if (!eglInitialize(s_dpy, &maj, &min)) {
		FAIL("eglInitialize failed: 0x%x", eglGetError());
	}

	// Depth 24 + stencil 8 is what gfx_sdl2 asks SDL for, and gfx_opengl's
	// default-framebuffer path assumes both are there.
	const char *surfkind = getenv("PD_ANGLE_SURFACE");
	const bool want_pbuffer = surfkind && !strcmp(surfkind, "pbuffer");
	EGLint cfga[] = {
		EGL_SURFACE_TYPE, want_pbuffer ? (EGL_WINDOW_BIT | EGL_PBUFFER_BIT) : EGL_WINDOW_BIT,
		EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
		EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
		EGL_DEPTH_SIZE, 24, EGL_STENCIL_SIZE, 8,
		EGL_NONE
	};
	EGLint n = 0;
	if (!eglChooseConfig(s_dpy, cfga, &s_cfg, 1, &n) || n < 1) {
		FAIL("no ES3-renderable window config with depth24/stencil8");
	}

	EGLint ctxa[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
	s_ctx = eglCreateContext(s_dpy, s_cfg, EGL_NO_CONTEXT, ctxa);
	if (s_ctx == EGL_NO_CONTEXT) {
		FAIL("no ES 3.0 context: 0x%x", eglGetError());
	}

	// PD_ANGLE_SURFACE=pbuffer renders into an off-screen surface instead of
	// the window's layer. Nothing is presented, so nothing waits for the
	// compositor - the measurement question of Q-001: the macOS oracle's fps
	// is otherwise pinned to the panel's refresh whatever the workload (M-002).
	// Everything else - the ES 3.0 context, the shaders, the framebuffers, the
	// screenshot readback - is the same code on the same GPU.
	if (want_pbuffer) {
		const EGLint pba[] = { EGL_WIDTH, pw > 0 ? pw : 1280, EGL_HEIGHT, ph > 0 ? ph : 720, EGL_NONE };
		s_surf = eglCreatePbufferSurface(s_dpy, s_cfg, pba);
		if (s_surf == EGL_NO_SURFACE) {
			FAIL("no %dx%d pbuffer surface: 0x%x", pw, ph, eglGetError());
		}
	} else {
		s_surf = eglCreateWindowSurface(s_dpy, s_cfg, (EGLNativeWindowType)(__bridge void *)s_layer, NULL);
		if (s_surf == EGL_NO_SURFACE) {
			FAIL("no window surface on the CAMetalLayer: 0x%x", eglGetError());
		}
	}

	if (!eglMakeCurrent(s_dpy, s_surf, s_surf, s_ctx)) {
		FAIL("eglMakeCurrent failed: 0x%x", eglGetError());
	}

	return 1;
#undef FAIL
}

extern "C" const char *pdAngleGetVendorString(void)
{
	const char *v = eglQueryString(s_dpy, EGL_VENDOR);
	return v ? v : "";
}

#if TARGET_OS_VISION
/**
 * Enter or leave the 3D mode's rendering arrangement. Game thread, at the
 * frame boundary (PDHostViewController's pdVision3dFramePoll), with this
 * context current. Returns 1 if the arrangement is now what was asked for.
 *
 * ON, and the ORDER IS LOAD-BEARING: the context goes SURFACELESS first, so
 * nothing can ask the hidden window's CAMetalLayer for a drawable. That is not
 * an optimisation — a drawable requested against a layer that is off-screen
 * never comes back, and the game thread hangs inside the driver with no error
 * anywhere (sm64coopdx frame-map calls this out; q2repro hit it too). With no
 * surface bound, any stray draw to GL framebuffer 0 fails loudly instead.
 * Then the eye ring is wrapped, and from that moment framebuffer 0 IS the eye
 * (patch 0031).
 *
 * OFF: the window surface is re-bound FIRST and the ring freed second. The
 * other order is q2repro's "stuck frozen window" bug: without the re-bind
 * every later eglSwapBuffers fails, the 2D window never updates again, and
 * the only symptom is that audio keeps playing over a still picture.
 */
extern "C" int pdAngleSet3DActive(int on)
{
	if (s_dpy == EGL_NO_DISPLAY || s_ctx == EGL_NO_CONTEXT) {
		return 0;
	}
	if (!!on == s_vision3d) {
		return 1;
	}

	if (on) {
		if (!eglMakeCurrent(s_dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, s_ctx)) {
			fprintf(stderr, "perfectdark: [3d] surfaceless eglMakeCurrent failed: 0x%x\n",
				eglGetError());
			return 0;
		}
		if (!pdVisionEyeActivate()) {
			// Roll all the way back: a surfaceless context with no eye targets
			// draws nowhere at all.
			eglMakeCurrent(s_dpy, s_surf, s_surf, s_ctx);
			fprintf(stderr, "perfectdark: [3d] eye targets failed — staying in 2D\n");
			return 0;
		}
		s_vision3d = 1;
		fprintf(stderr, "perfectdark: [3d] context is surfaceless, framebuffer 0 is the eye\n");
	} else {
		if (!eglMakeCurrent(s_dpy, s_surf, s_surf, s_ctx)) {
			fprintf(stderr, "perfectdark: [3d] rebinding the window surface FAILED: 0x%x\n",
				eglGetError());
		}
		pdVisionEyeDeactivate();
		s_vision3d = 0;
		fprintf(stderr, "perfectdark: [3d] window surface re-bound, framebuffer 0 is the window\n");
	}
	return 1;
}

extern "C" int pdAngle3DActive(void)
{
	return s_vision3d;
}
#endif // TARGET_OS_VISION

/**
 * Re-measure the window's drawable from the layer, and say so out loud.
 *
 * The 3D exit needs this explicitly (M4). While 3D was on, pdAngleGetDrawableSize
 * answered with the EYE's size, so nothing in the renderer has asked the layer
 * how big it is since the entry - and in between, the scene was parked to a
 * 480-pt card and restored, which changed the layer's bounds twice. Without a
 * re-measure the first 2D frames draw at the wrong size into the right
 * drawable, which on the simulator looks exactly like the M1 aspect trap.
 *
 * Game thread, context current. Cheap: a bounds read and, at most, one
 * drawableSize assignment.
 */
extern "C" void pdAngleResyncWindowDrawable(void)
{
	if (s_dpy == EGL_NO_DISPLAY || !s_layer) {
		return;
	}
	int fw = 0, fh = 0;
	if (pdAngleApplyRenderScale()) {
		fprintf(stderr, "perfectdark: [3d] drawable re-synced by render scale to %.0fx%.0f\n",
			s_layer.drawableSize.width, s_layer.drawableSize.height);
	} else if (pdAngleForcedSize(&fw, &fh)) {
		s_layer.drawableSize = CGSizeMake(fw, fh);
		fprintf(stderr, "perfectdark: [3d] drawable re-synced to the forced %dx%d\n", fw, fh);
	} else {
		CGSize want = CGSizeMake(s_layer.bounds.size.width * s_layer.contentsScale,
		                         s_layer.bounds.size.height * s_layer.contentsScale);
		if (want.width > 0 && want.height > 0) {
			s_layer.drawableSize = want;
		}
		fprintf(stderr, "perfectdark: [3d] drawable re-synced to %.0fx%.0f"
			" (layer %.0fx%.0f pt x %.2f)\n",
			s_layer.drawableSize.width, s_layer.drawableSize.height,
			s_layer.bounds.size.width, s_layer.bounds.size.height, s_layer.contentsScale);
	}
	if (s_surf != EGL_NO_SURFACE && !eglMakeCurrent(s_dpy, s_surf, s_surf, s_ctx)) {
		fprintf(stderr, "perfectdark: [3d] eglMakeCurrent after the re-sync failed: 0x%x\n",
			eglGetError());
	}
}

extern "C" void pdAngleGetDrawableSize(int *w, int *h)
{
#if TARGET_OS_VISION
	// In 3D the render resolution is the EYE's, not the window's: the window is
	// parked to a 480-pt card from M4 on, and the picture has to stay the
	// panel's size. gfx_start_frame's get_dimensions, gfx_current_dimensions,
	// the aspect and the viewport all come through here, so this one override
	// decouples the whole renderer from the window (SETTINGS-SPEC: "render
	// resolution must be decoupled from the window first").
	if (s_vision3d) {
		pdVisionEyeGetSize(w, h);
		return;
	}
#endif
	EGLint sw = 0, sh = 0;
	if (s_dpy != EGL_NO_DISPLAY && s_surf != EGL_NO_SURFACE) {
		eglQuerySurface(s_dpy, s_surf, EGL_WIDTH, &sw);
		eglQuerySurface(s_dpy, s_surf, EGL_HEIGHT, &sh);
	}
	if (w) *w = (int)sw;
	if (h) *h = (int)sh;
}

// The layer does not follow the window on its own; the port resizes on
// SDL_WINDOWEVENT_SIZE_CHANGED and then asks us how big the drawable now is.
extern "C" void pdAngleResized(SDL_Window *wnd)
{
	if (pdAngleApplyRenderScale()) {
		return;
	}
	int pw = 0, ph = 0;
	SDL_Metal_GetDrawableSize(wnd, &pw, &ph);
	pdAngleForcedSize(&pw, &ph);
	if (s_layer && pw > 0 && ph > 0) {
		s_layer.drawableSize = CGSizeMake(pw, ph);
	}
}

/**
 * Backgrounding, which on this substrate is a real hazard and not a formality.
 *
 * While the app is in the background the CAMetalLayer's drawables belong to the
 * system, and an eglSwapBuffers into one is the family's classic "looks like a
 * port bug, is a lifecycle bug" crash. The shell's answer is in two parts and
 * this is the second: PDPacing stops the game thread at the present point
 * (app/ios/PDPacing.m) so nothing is drawn OR presented, and these two make
 * sure that when the app comes back the surface the context is attached to
 * still matches the layer - the bounds can change while we are away (a rotation
 * in the app switcher, a Stage Manager resize on iPad).
 *
 * Both are called on the game thread, which is also the main thread, from the
 * UIApplication notifications - so the EGL context is current on this thread
 * and no handoff is involved.
 */
extern "C" void pdAngleSuspend(void)
{
	if (s_dpy == EGL_NO_DISPLAY) {
		return;
	}
	// Let everything already submitted finish against a drawable that is still
	// ours. The context is deliberately NOT released: the game thread is parked
	// at the present, not running GL, and releasing it would only add a second
	// way for the resume to go wrong.
	eglWaitClient();
}

extern "C" void pdAngleResume(void)
{
	if (s_dpy == EGL_NO_DISPLAY || s_surf == EGL_NO_SURFACE) {
		return;
	}

#if TARGET_OS_VISION
	// Never re-bind the window surface behind the 3D mode's back: every line
	// below makes the context current on s_surf, which is exactly what
	// pdAngleSet3DActive(1) took away on purpose.
	if (s_vision3d) {
		return;
	}
#endif

	if (pdAngleApplyRenderScale()) {
		if (!eglMakeCurrent(s_dpy, s_surf, s_surf, s_ctx)) {
			fprintf(stderr, "perfectdark: eglMakeCurrent on resume failed: 0x%x\n", eglGetError());
		}
		return;
	}

	int fw = 0, fh = 0;
	if (s_layer && !pdAngleForcedSize(&fw, &fh)) {
		CGSize want = CGSizeMake(s_layer.bounds.size.width * s_layer.contentsScale,
		                         s_layer.bounds.size.height * s_layer.contentsScale);
		if (want.width > 0 && want.height > 0 &&
			(want.width != s_layer.drawableSize.width || want.height != s_layer.drawableSize.height)) {
			s_layer.drawableSize = want;
		}
	}

	// Re-assert current: harmless if it already was, and the one thing that
	// would otherwise fail silently for the rest of the session if it was not.
	if (!eglMakeCurrent(s_dpy, s_surf, s_surf, s_ctx)) {
		fprintf(stderr, "perfectdark: eglMakeCurrent on resume failed: 0x%x\n", eglGetError());
	}
}

extern "C" void pdAngleSwapBuffers(void)
{
#if TARGET_OS_VISION
	// In 3D the present IS the publish: there is no surface to swap, and the
	// compositor picks the finished eye up from the ring (D-048/D-050). The
	// display-link pacer above this call (patch 0016) still bounds the engine
	// at the panel rate in M2; M3 replaces it with the compositor's clock.
	if (s_vision3d) {
		pdVisionEyePublish();
		return;
	}
#endif
	if (s_dpy != EGL_NO_DISPLAY && s_surf != EGL_NO_SURFACE) {
		eglSwapBuffers(s_dpy, s_surf);
		s_swaps = s_swaps + 1;
	}
}

extern "C" int pdAngleSetSwapInterval(int interval)
{
	if (s_dpy == EGL_NO_DISPLAY) {
		return 0;
	}
	if (interval < 0) {
		interval = 1; // no adaptive vsync on EGL
	}
	if (!eglSwapInterval(s_dpy, interval)) {
		return 0;
	}
	s_interval = interval;
	return 1;
}

extern "C" int pdAngleGetSwapInterval(void)
{
	return s_interval;
}

extern "C" void *pdAngleGetProcAddress(const char *name)
{
	return (void *)eglGetProcAddress(name);
}
