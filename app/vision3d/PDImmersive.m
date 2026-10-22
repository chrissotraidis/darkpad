// PDImmersive.m — the CompositorServices render loop for Perfect Dark's 3D mode.
//
// Ported from sm64coopdx's app/vision3d/sm64_immersive.m, which is itself the
// vkQuake → quake3e → q2repro loop. Nothing about the SHAPE of this loop is
// ours to invent: every line of the sequence below wedged an engine somewhere
// in the family before the order was right (VISIONOS-FOVEATION-GUIDE §2.3,
// VISION-PRO-LUS-PLAYBOOK §2.3/§2.8). Do not "simplify" it:
//
//   * frame pacing (cp_frame_predict_timing + cp_time_wait_until) AND a
//     per-frame ARKit device anchor. A frame presented without EITHER is
//     silently never displayed — the "renders but nothing shows" bug, twice.
//   * the drawable's depth MUST be cleared and STORED: the compositor
//     reprojects on depth and rejects a frame whose depth it cannot read.
//   * the command queue MUST come from the DRAWABLE's device, never from
//     MTLCreateSystemDefaultDevice().
//   * a NULL drawable is `continue` WITHOUT end_submission (that aborts).
//   * cp_view_get_tangents traps under mixed immersion — the projection comes
//     from cp_drawable_compute_projection.
//   * this thread has no run-loop autorelease pool; drain per frame.
//
// MILESTONE 2: the panel shows the GAME. The engine renders into an app-owned
// MTLTexture through ANGLE (app/vision3d/PDEyeTargets.mm, D-048) and this loop
// samples it. Three things about that handoff are not negotiable:
//
//   * ANGLE renders on ANGLE's Metal queue and this loop presents on its own.
//     The two have NO ordering, so the presenting command buffer ENCODES a
//     waitForEvent on the (MTLSharedEvent, value) the published frame carries.
//     A CPU-side "it looked finished" is q2repro's R14 defect: the compositor
//     samples a half-written eye, or the slot's previous occupant, and the
//     room gets a duplicate of the world flickering next to itself.
//   * the sample goes through this loop's OWN mipmapped copy, not the engine's
//     texture: the panel is minified (a 3840-wide eye on a quad a couple of
//     metres away), and without mips that is a shimmering mess. The copy also
//     means the engine's next frame can overwrite its ring slot freely.
//   * the copy is sampled through an _sRGB VIEW. The engine's bytes are
//     already display-encoded - that is what the 2D window shows - and the
//     drawable is bgra8Unorm_sRGB, so a plain sample would be re-encoded on
//     write and the panel would come out washed out. Decoding on read and
//     re-encoding on write is a byte passthrough.
//
// MILESTONE 3 adds three things to that: the pair (each view samples its OWN
// eye's copy, and PD_VP3D_SHOWEYE forces which one a mono simulator shows), the
// PACING signal (this loop's cp_time_wait_until is what releases the engine's
// frame, so the engine is phase-locked to the frame that will display it), and
// RECENTER (the frozen head pose is dropped and re-taken).
//
// AND IT FIXES WHAT M2 SHIPPED: the panel was upside down. See pd_fs_tex below
// — the whole reasoning is there, and so is the rule that came out of it.
//
// M1's solid colour is still here as the fallback for the frames before the
// engine has published anything, so "the space opened but the game is not in
// it yet" still looks like something rather than like a failure.
#import "PDVision3D.h"

#if TARGET_OS_VISION

// The pacer, for pdPacingSignalExternal(): in 3D THIS loop is the engine's
// clock, not the display link (plan §2.6, D-050).
#import "PDPacing.h"

#import <CompositorServices/CompositorServices.h>
#import <Metal/Metal.h>
#import <ARKit/ARKit.h>
#import <simd/simd.h>
#import <Foundation/Foundation.h>

#include <math.h>
#include <time.h>

volatile int pdVision3dImmStop = 0;
volatile int pdVision3dImmRunning = 0;
volatile int pdVision3dImmFrames = 0;
volatile int pdVision3dImmNoDrawable = 0;

// D-063: foveation, reported rather than assumed. Written once by Swift at
// layer-config time and once per frame by the loop; read by `3d state`.
volatile int pdVision3dFoveationSupported = 0;
volatile int pdVision3dFoveationConfigured = 0;
volatile int pdVision3dFoveationRateMaps = 0;
volatile int pdVision3dLayoutDedicated = 0;

void pdVision3dNoteCompositorConfig(int supported, int configured, int dedicated)
{
	pdVision3dFoveationSupported = supported;
	pdVision3dFoveationConfigured = configured;
	pdVision3dLayoutDedicated = dedicated;
}
volatile float pdVision3dImmHz = 0.0f;

// ---------------------------------------------------------------------------
// Panel placement. The defaults are the family's, in metres
// (SETTINGS-SPEC-FROM-VKQUAKE: Screen Distance 3.6 m, Width 5.5 m, Height
// 3.1 m). M6 puts sliders on them; M1 hard-codes them so the panel that shows
// up in the room is the one the shipped defaults will place.
// ---------------------------------------------------------------------------
// M6 PUTS THE SLIDERS ON THEM (plan §2.10). Written on the main/game thread by
// pdVisionPanelSet() and read by the compositor thread every frame — `volatile`
// floats, deliberately, and not a lock: each is one word, each is read exactly
// once per frame into a local, and a slider drag that landed between two of
// them for one frame is a panel that was one frame late in one dimension. A
// lock around five words that a render loop reads every 11 ms would cost more
// than the thing it protects.
static volatile float pdPanelDist  = 3.6f;
static volatile float pdPanelHalfW = 2.75f;
static volatile float pdPanelHalfH = 1.55f;
static volatile float pdPanelPosH  = 0.0f;
// Surroundings Dimming, the family default (SETTINGS-SPEC): 80 %, applied as
// 1-(1-d)^2.2 so the slider is perceptually even rather than bunched.
static volatile float pdPanelDim   = 0.80f;

/**
 * The panel's geometry, from the settings sheet. Any thread.
 *
 * CLAMPED HERE and not only in the sheet: the bridge writes the same rows (and
 * so, in principle, does a hand-edited plist), and a zero or negative half-
 * extent degenerates the quad's basis — which is a panel that vanishes with no
 * error anywhere.
 */
void pdVisionPanelSet(float dist, float halfW, float halfH, float posH, float dim)
{
	pdPanelDist  = fmaxf(0.5f, fminf(dist, 12.0f));
	pdPanelHalfW = fmaxf(0.3f, fminf(halfW, 6.0f));
	pdPanelHalfH = fmaxf(0.2f, fminf(halfH, 5.0f));
	pdPanelPosH  = fmaxf(-3.0f, fminf(posH, 12.0f));
	pdPanelDim   = fmaxf(0.0f, fminf(dim, 1.0f));
	// D-058: the eye is sized from the panel, so it has to be told — but LIVE,
	// which re-wraps nothing. pdVisionEyeCommitPanel() is the release.
	pdVisionEyeNotePanelGeometry(pdPanelHalfW, pdPanelHalfH, pdPanelDist);
}

NSString *pdVisionPanelStateLines(void)
{
	const float w = pdPanelHalfW, h = pdPanelHalfH;
	return [NSString stringWithFormat:
		@"panel_dist_m=%.2f\npanel_width_m=%.2f\npanel_height_m=%.2f\n"
		 "panel_posh_m=%.2f\npanel_dim_pct=%.0f\npanel_aspect=%.2f\n",
		(double)pdPanelDist, (double)(w * 2.0f), (double)(h * 2.0f),
		(double)pdPanelPosH, (double)(pdPanelDim * 100.0f),
		(double)(w / (h > 0.01f ? h : 0.01f))];
}

static bool pdHaveAnchor = false;
static simd_float4x4 pdFrozenHead;
static volatile int pdRecenterAsked = 0;
// The frame the last recenter was asked at; the 30-frame convergence gate is
// measured from it, so entry (0) and a recenter use the same rule.
static int pdRecenterAtFrame = 0;

/**
 * Recenter: drop the frozen head pose so the panel is re-placed in front of
 * wherever the player is looking on the next tracked frame.
 *
 * A FLAG, not the work: this is called from the bridge and from the settings
 * sheet, and the anchor belongs to the compositor thread. Re-anchoring waits
 * for the same >= 30-tracked-frame gate as the first placement, because ARKit's
 * pose right after a recenter request is as good as its pose at entry — the
 * request does not restart tracking.
 */
void pdVisionRecenter(void)
{
	pdRecenterAsked = 1;
	NSLog(@"perfectdark: [3d] recenter requested");
}

static simd_float4x4 pdTranslate(float x, float y, float z)
{
	simd_float4x4 m = matrix_identity_float4x4;
	m.columns[3] = simd_make_float4(x, y, z, 1.0f);
	return m;
}

static simd_float4x4 pdScale(float x, float y, float z)
{
	simd_float4x4 m = matrix_identity_float4x4;
	m.columns[0].x = x;
	m.columns[1].y = y;
	m.columns[2].z = z;
	return m;
}

/**
 * The panel's transform, from a head pose that was frozen once.
 *
 * World-LOCKED, never head-driven: the head pose PLACES the screen and then
 * never moves it again (a head-driven camera in a first-person shooter is
 * nauseating, and it is not what any shipped sibling does). Recomputed from the
 * frozen head every frame so that a live slider drag moves the panel.
 */
static simd_float4x4 pdMakeAnchor(simd_float4x4 originFromDevice)
{
	simd_float3 headPos = originFromDevice.columns[3].xyz;
	simd_float3 fwd = -originFromDevice.columns[2].xyz;   // gaze forward
	fwd.y = 0.0f;                                          // level: no pitch, no roll
	float len = simd_length(fwd);
	fwd = (len < 1e-4f) ? simd_make_float3(0, 0, -1) : fwd / len;

	simd_float3 pos = headPos + fwd * pdPanelDist;
	pos.y += pdPanelPosH;
	// Face the head, with 'right' kept horizontal so the panel never rolls and
	// the basis never degenerates.
	simd_float3 normal = simd_normalize(headPos - pos);
	simd_float3 up = simd_make_float3(0, 1, 0);
	simd_float3 right = simd_normalize(simd_cross(up, normal));
	up = simd_cross(normal, right);

	simd_float4x4 m;
	m.columns[0] = simd_make_float4(right, 0.0f);
	m.columns[1] = simd_make_float4(up, 0.0f);
	m.columns[2] = simd_make_float4(normal, 0.0f);
	m.columns[3] = simd_make_float4(pos, 1.0f);
	return m;
}

// ---------------------------------------------------------------------------
// The panel pipeline. M1's fragment shader is a constant; M2 swaps it for a
// texture sample (and the letterbox/alpha-forcing the family ships).
// ---------------------------------------------------------------------------
static id<MTLRenderPipelineState> pdQuadPipeline;    // the eye, textured
static id<MTLRenderPipelineState> pdSolidPipeline;   // M1's colour, pre-first-frame
static id<MTLRenderPipelineState> pdDimPipeline;     // the surroundings dim layer
static id<MTLDepthStencilState> pdQuadDepthState;
static id<MTLSamplerState> pdPanelSampler;

static NSString *const kPDQuadShader =
	@"#include <metal_stdlib>\n"
	 "using namespace metal;\n"
	 "struct VOut { float4 pos [[position]]; float2 c; };\n"
	 "vertex VOut pd_vs(uint vid [[vertex_id]], constant float4x4& mvp [[buffer(0)]]) {\n"
	 "  const float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };\n"
	 "  VOut o; o.pos = mvp * float4(p[vid], 0.0, 1.0);\n"
	 "  o.c = p[vid];\n"
	 "  return o;\n"
	 "}\n"
	 // The dim layer: a full-screen triangle at the far plane, in clip space,
	 // so it needs no transform and cannot miss the view. Drawn BEFORE the
	 // panel, black with the dimming alpha, and the panel covers it where the
	 // picture is.
	 "vertex VOut pd_vs_dim(uint vid [[vertex_id]]) {\n"
	 "  const float2 p[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };\n"
	 "  VOut o; o.pos = float4(p[vid], 0.9999, 1.0); o.c = p[vid];\n"
	 "  return o;\n"
	 "}\n"
	 "fragment float4 pd_fs_dim(VOut in [[stage_in]], constant float& dim [[buffer(0)]]) {\n"
	 // Premultiplied: rgb is black, so rgb*a is black too and only the alpha
	 // carries the dimming.
	 "  return float4(0.0, 0.0, 0.0, dim);\n"
	 "}\n"
	 // M1's proof colour, plus a lighter border so the panel's EDGES are
	 // visible in a room screenshot (a flat rectangle of one colour is hard to
	 // tell from a compositor artefact; a framed one is not). Alpha is forced
	 // to 1 whatever else happens — under premultiplied mixed immersion any
	 // alpha residue ghosts the room through the panel (quake3e D-027).
	 "fragment float4 pd_fs(VOut in [[stage_in]], constant float4& tint [[buffer(0)]]) {\n"
	 "  float2 a = fabs(in.c);\n"
	 "  float edge = (max(a.x, a.y) > 0.96) ? 1.0 : 0.0;\n"
	 "  float3 c = mix(tint.rgb, float3(0.85, 0.90, 1.00), edge);\n"
	 "  return float4(c, 1.0);\n"
	 "}\n"
	 // The eye. UV straight from the quad's own corners, WITH NO V FLIP — and
	 // that is a fact that was got wrong once and shipped (M2's
	 // 08-room-panel-3d.jpg: the panel upside down, "GAME FILES" mirrored, the
	 // gun at the top).
	 //
	 // The reasoning that put a flip here was "GL's origin is bottom-left and
	 // Metal's is top-left". It does not apply to an EGLImage-wrapped
	 // MTLTexture: ANGLE-Metal reconciles the two conventions ITSELF, inside
	 // the translated vertex shader, so the texture's row 0 already holds the
	 // GL frame's TOP row. Flipping here therefore flips a picture that was
	 // already the right way up.
	 //
	 // Nothing in the M2 gate could see it, which is why it shipped: PD's
	 // glReadPixels readback (patch 0006) un-flips its own rows, so the eye's
	 // frame 1500 matched the oracle to 10 pixels while the PANEL was upside
	 // down. Orientation is checked by READING A HUMAN-READABLE FEATURE in the
	 // room screenshot from now on — "GAME FILES" and "Perfect Dark" must read
	 // as words, with the gun at the bottom — never by "it looks sharp".
	 //
	 // Alpha forced to 1, same reason as above.
	 "fragment float4 pd_fs_tex(VOut in [[stage_in]],\n"
	 "                          texture2d<float> eye [[texture(0)]],\n"
	 "                          sampler smp [[sampler(0)]]) {\n"
	 "  float2 uv = float2((in.c.x + 1.0) * 0.5, (in.c.y + 1.0) * 0.5);\n"
	 "  return float4(eye.sample(smp, uv).rgb, 1.0);\n"
	 "}\n";

static id<MTLRenderPipelineState> pdMakePipeline(id<MTLDevice> dev, id<MTLLibrary> lib,
	NSString *vs, NSString *fs, MTLPixelFormat colorFmt, MTLPixelFormat depthFmt,
	const char *what)
{
	NSError *err = nil;
	MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
	pd.vertexFunction = [lib newFunctionWithName:vs];
	pd.fragmentFunction = [lib newFunctionWithName:fs];
	pd.colorAttachments[0].pixelFormat = colorFmt;
	pd.depthAttachmentPixelFormat = depthFmt;
	id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
	if (!ps) {
		NSLog(@"perfectdark: [3d] %s pipeline FAILED: %@", what, err.localizedDescription);
	}
	return ps;
}

static void pdBuildPipeline(id<MTLDevice> dev, MTLPixelFormat colorFmt, MTLPixelFormat depthFmt)
{
	NSError *err = nil;
	id<MTLLibrary> lib = [dev newLibraryWithSource:kPDQuadShader options:nil error:&err];
	if (!lib) {
		NSLog(@"perfectdark: [3d] panel shader FAILED: %@", err.localizedDescription);
		return;
	}
	pdQuadPipeline = pdMakePipeline(dev, lib, @"pd_vs", @"pd_fs_tex", colorFmt, depthFmt, "eye");
	pdSolidPipeline = pdMakePipeline(dev, lib, @"pd_vs", @"pd_fs", colorFmt, depthFmt, "solid");
	pdDimPipeline = pdMakePipeline(dev, lib, @"pd_vs_dim", @"pd_fs_dim", colorFmt, depthFmt, "dim");

	MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
	// Always, with draw order doing the work: the dim triangle first at the far
	// plane, the panel over it. Depth is WRITTEN either way because the
	// compositor reprojects on it and rejects a frame it cannot read.
	dd.depthCompareFunction = MTLCompareFunctionAlways;
	dd.depthWriteEnabled = YES;
	pdQuadDepthState = [dev newDepthStencilStateWithDescriptor:dd];

	// Trilinear + 16x aniso: the panel is minified and seen at an angle as soon
	// as the head moves off its normal, which is exactly the case aniso exists
	// for (the family's shipped sampler, sm64_immersive.m).
	MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
	sd.minFilter = MTLSamplerMinMagFilterLinear;
	sd.magFilter = MTLSamplerMinMagFilterLinear;
	sd.mipFilter = MTLSamplerMipFilterLinear;
	sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
	sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
	sd.maxAnisotropy = 16;
	pdPanelSampler = [dev newSamplerStateWithDescriptor:sd];

	NSLog(@"perfectdark: [3d] panel pipelines built (color=%lu depth=%lu)",
		(unsigned long)colorFmt, (unsigned long)depthFmt);
}

// ---------------------------------------------------------------------------
// The eye copy. This loop's own texture, mipmapped, on the DRAWABLE's device.
// ---------------------------------------------------------------------------
// TWO of everything from M3 on: one mipmapped copy per eye, because both are
// sampled in the SAME command buffer (one render pass per view) and a single
// copy would have the second view's blit overwrite the first view's source.
static id<MTLTexture> pdEyeCopy[2];        // what the blit writes and the mips live on
static id<MTLTexture> pdEyeCopySRGB[2];    // the _sRGB view the shader samples
static uint32_t pdEyeCopyGen;              // the publish generation already copied
static int pdEyeCopyW, pdEyeCopyH;

static bool pdEnsureEyeCopy(id<MTLDevice> dev, id<MTLTexture> src)
{
	if (pdEyeCopy[0] && pdEyeCopy[1] &&
			pdEyeCopyW == (int)src.width && pdEyeCopyH == (int)src.height) {
		return true;
	}
	MTLTextureDescriptor *td =
		[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat
		                                                   width:src.width
		                                                  height:src.height
		                                               mipmapped:YES];
	td.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
	td.storageMode = MTLStorageModePrivate;
	// The sRGB view: see the file comment. If the view is refused the panel
	// still works, just brighter than the 2D window — said once, not per frame.
	MTLPixelFormat srgb = (src.pixelFormat == MTLPixelFormatBGRA8Unorm)
		? MTLPixelFormatBGRA8Unorm_sRGB : MTLPixelFormatRGBA8Unorm_sRGB;
	for (int e = 0; e < 2; e++) {
		pdEyeCopy[e] = [dev newTextureWithDescriptor:td];
		if (!pdEyeCopy[e]) {
			NSLog(@"perfectdark: [3d] no %lux%lu panel copy texture for eye %d",
				(unsigned long)src.width, (unsigned long)src.height, e);
			pdEyeCopy[0] = nil;
			pdEyeCopy[1] = nil;
			return false;
		}
		pdEyeCopySRGB[e] = [pdEyeCopy[e] newTextureViewWithPixelFormat:srgb];
		if (!pdEyeCopySRGB[e]) {
			static int said;
			if (!said) {
				said = 1;
				NSLog(@"perfectdark: [3d] no _sRGB view of the panel copy — sampling it raw");
			}
		}
	}
	pdEyeCopyW = (int)src.width;
	pdEyeCopyH = (int)src.height;
	pdEyeCopyGen = 0;
	NSLog(@"perfectdark: [3d] panel copies %dx%d x2 fmt=%lu srgb_view=%d",
		pdEyeCopyW, pdEyeCopyH, (unsigned long)src.pixelFormat,
		(int)(pdEyeCopySRGB[0] != nil));
	return true;
}

// ---------------------------------------------------------------------------
// Cadence. The delta between successive frames' optimal input time IS the
// compositor's frame period, and from M3 on the engine is paced off this loop
// (D-050), so the number the gate reads has to be this one and not a guess.
// ---------------------------------------------------------------------------
static void pdCadenceSample(double optInSec)
{
	static double last = 0.0;
	static double sum = 0.0;
	static int n = 0;

	if (last > 0.0 && optInSec > last) {
		double d = optInSec - last;
		if (d > 0.00005 && d < 1.0) {
			sum += d;
			n++;
			if (n >= 20) {
				pdVision3dImmHz = (float)(n / sum);
				sum = 0.0;
				n = 0;
			}
		}
	}
	last = optInSec;
}

// ---------------------------------------------------------------------------

void pdVision3dImmersiveRun(void *lr)
{
	// __bridge, not a transfer: PDVisionApp.swift hands this over with
	// Unmanaged.passUnretained(...).toOpaque(), so SwiftUI still owns the layer
	// renderer and ARC must not take a reference to something it will tear
	// down. (cp_layer_renderer_t is an ObjC pointer type under ARC, so the cast
	// is required rather than cosmetic.)
	cp_layer_renderer_t layer = (__bridge cp_layer_renderer_t)lr;

	pdVision3dImmStop = 0;
	pdVision3dImmRunning = 1;
	pdVision3dImmFrames = 0;
	pdVision3dImmNoDrawable = 0;
	pdVision3dImmHz = 0.0f;
	pdHaveAnchor = false;          // re-anchor the panel on every entry
	pdRecenterAsked = 0;
	pdRecenterAtFrame = 0;
	int notifyEnded = 0;           // only a system/Crown dismissal reconciles this way
	id<MTLCommandQueue> queue = nil;

	// ARKit world tracking, for the device anchor the compositor reprojects
	// with. No usage string is needed for a device anchor (no sibling's plist
	// has one) — but D-030 says the simulator enforces no privacy string at
	// all, so the first DEVICE launch is the one that tells us, via crash.txt.
	ar_world_tracking_configuration_t wtc = ar_world_tracking_configuration_create();
	ar_world_tracking_provider_t wtp = ar_world_tracking_provider_create(wtc);
	ar_session_t session = ar_session_create();
	ar_data_providers_t providers = ar_data_providers_create_with_data_providers(wtp, NULL);
	ar_session_run(session, providers);

	// THE CLOCK MOVES HERE (D-050). Switched on by the loop itself rather than
	// by the mode transition, so a Crown dismissal — which leaves through the
	// `invalidated` case below and never touches pdVision3dApplyMode — cannot
	// leave the engine waiting for a compositor that is gone.
	pdPacingSetExternalSource(1);

	NSLog(@"perfectdark: [3d] immersive loop started (ARKit world tracking running,"
	       " pacing_mode=compositor)");

	int running = 1;
	while (running) {
		if (pdVision3dImmStop) {
			NSLog(@"perfectdark: [3d] stop requested — leaving cleanly (frames=%d)",
				pdVision3dImmFrames);
			break;
		}
		switch (cp_layer_renderer_get_state(layer)) {
			case cp_layer_renderer_state_paused:
				cp_layer_renderer_wait_until_running(layer);
				continue;
			case cp_layer_renderer_state_invalidated:
				NSLog(@"perfectdark: [3d] layer invalidated — leaving loop (frames=%d)",
					pdVision3dImmFrames);
				notifyEnded = 1;
				running = 0;
				continue;
			case cp_layer_renderer_state_running:
			default:
				break;
		}

		@autoreleasepool {
			cp_frame_t frame = cp_layer_renderer_query_next_frame(layer);
			if (frame == NULL) {
				continue;
			}

			cp_frame_timing_t timing = cp_frame_predict_timing(frame);
			cp_frame_start_update(frame);
			cp_frame_end_update(frame);

			cp_time_t optIn = cp_frame_timing_get_optimal_input_time(timing);
			pdCadenceSample(cp_time_to_cf_time_interval(optIn));
			// PACING. Without this the loop free-runs and the frames it
			// presents are not displayed.
			cp_time_wait_until(optIn);
			// THE COMPOSITOR IS THE ENGINE'S CLOCK IN 3D (plan §2.6, D-050).
			// One signal per compositor frame, right after the wait, so the
			// engine's frame is phase-locked to the frame that will display it
			// — sm64's M-51: a phase-locked engine is what made "not buttery"
			// go away. A flag and not a counter: a late engine drops a signal,
			// it never banks them.
			pdPacingSignalExternal();

			cp_frame_start_submission(frame);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
			// The singular query_drawable, as sm64coopdx and quake3e both ship:
			// the plural form is 26.0-only.
			cp_drawable_t drawable = cp_frame_query_drawable(frame);
#pragma clang diagnostic pop
			if (drawable == NULL) {
				// NO end_submission. This file's own header has said so since
				// M1 ("a NULL drawable is `continue` WITHOUT end_submission —
				// that aborts") and the code did the opposite anyway; dev1
				// cashed the cheque. `cp_frame_end_submission` on a frame with
				// no drawable calls __BUG_IN_CLIENT__ and the process dies with
				// SIGABRT inside CompositorNonUI:
				//
				//   5  CompositorNonUI  __BUG_IN_CLIENT__ + 188
				//   6  CompositorNonUI  cp_frame_end_submission + 728
				//   7  perfectdark      pdVision3dImmersiveRun + 576
				//
				// M1-M6 never met it because the compositor only withholds a
				// drawable from an app that is behind, and every 3D gate before
				// this one ran WITHOUT the XBLA release — the same blind spot
				// that shipped the classifier. Counted, not silent.
				pdVision3dImmNoDrawable++;
				continue;
			}

			if (queue == nil) {
				id<MTLTexture> t0 = cp_drawable_get_color_texture(drawable, 0);
				queue = [t0.device newCommandQueue];
				pdBuildPipeline(t0.device, t0.pixelFormat,
					cp_drawable_get_depth_texture(drawable, 0).pixelFormat);
				NSLog(@"perfectdark: [3d] drawable %lux%lu views=%zu color=%lu rate_maps=%zu",
					(unsigned long)t0.width, (unsigned long)t0.height,
					cp_drawable_get_view_count(drawable),
					(unsigned long)t0.pixelFormat,
					cp_drawable_get_rasterization_rate_map_count(drawable));
			}

			// The head pose at THIS frame's presentation time. The compositor
			// reprojects with it; a frame without one may never be displayed.
			CFTimeInterval presTime = cp_time_to_cf_time_interval(
				cp_frame_timing_get_presentation_time(cp_drawable_get_frame_timing(drawable)));
			ar_device_anchor_t anchor = ar_device_anchor_create();
			ar_device_anchor_query_status_t anchorStatus =
				ar_world_tracking_provider_query_device_anchor_at_timestamp(wtp, presTime, anchor);
			cp_drawable_set_device_anchor(drawable, anchor);

			// Freeze the head pose ONCE tracking has converged. ARKit's first
			// frames return success with a near-identity pose, which would put
			// the panel on the floor — hence the frame gate as well as the
			// status check (sm64 :717-736, quake3e D-019).
			if (pdRecenterAsked) {
				pdRecenterAsked = 0;
				pdHaveAnchor = false;
				pdRecenterAtFrame = pdVision3dImmFrames;
				NSLog(@"perfectdark: [3d] recentring — re-anchoring in 30 frames");
			}
			if (!pdHaveAnchor && anchorStatus == ar_device_anchor_query_status_success &&
					pdVision3dImmFrames > pdRecenterAtFrame + 30) {
				pdFrozenHead = ar_device_anchor_get_origin_from_anchor_transform(anchor);
				pdHaveAnchor = true;
				NSLog(@"perfectdark: [3d] panel anchored at head (%.2f,%.2f,%.2f)",
					pdFrozenHead.columns[3].x, pdFrozenHead.columns[3].y,
					pdFrozenHead.columns[3].z);
			}

			simd_float4x4 placement = pdHaveAnchor
				? pdMakeAnchor(pdFrozenHead)
				: pdTranslate(0.0f, 0.0f, -pdPanelDist);
			simd_float4x4 originFromDevice =
				ar_device_anchor_get_origin_from_anchor_transform(anchor);

			id<MTLCommandBuffer> cmd = [queue commandBuffer];
			size_t views = cp_drawable_get_view_count(drawable);

			// D-057: the eye's base size is the compositor's own per-view
			// LOGICAL size, not a guess. The view texture map's viewport is the
			// right number rather than the texture's dimensions: with foveation
			// the texture is the PHYSICAL allocation and the rate map compresses
			// logical to physical, so the viewport is what the engine should
			// render and the texture size would over-allocate the eye.
			if (views > 0) {
				MTLViewport v0 = cp_view_texture_map_get_viewport(
					cp_view_get_view_texture_map(cp_drawable_get_view(drawable, 0)));
				pdVisionEyeNoteCompositorViewSize((int)v0.width, (int)v0.height);
			}

			// ---- the eye handoff ----------------------------------------
			// Acquire whatever the engine last published, wait for its GPU
			// work ON THIS COMMAND BUFFER, and copy it into this loop's own
			// mipmapped texture. A publish generation that has not moved means
			// the engine is a frame behind, and the previous copy is sampled
			// again rather than the ring being re-read (quake3e's new-pair
			// gate: re-copying a pair the producer may already be overwriting
			// is how the "duplicate of the world" artefact gets in).
			int panelHave = 0;
			float panelHalfW = pdPanelHalfW, panelHalfH = pdPanelHalfH;
			void *pubEvt = NULL;
			unsigned long long pubVal = 0;
			unsigned int pubGen = 0;
			// THE RAW-POINTER WINDOW OPENS HERE (M6). Everything from the
			// acquire to the end of the copy block below holds ring pointers
			// the ring owns, so a live Render Resolution change must not free
			// the ring inside it — pdVisionEyeResizeIfPending() waits for this
			// bracket to close before it re-wraps anything.
			pdVisionEyeSampleBegin();
			// Eye L is the pair's representative for the event and the sizing —
			// both eyes of a pair are the same size and carry the same event.
			void *pub = pdVisionEyeAcquire(PD_EYE_LEFT, &pubEvt, &pubVal, &pubGen);
			void *pubR = pdVisionEyeAcquire(PD_EYE_RIGHT, NULL, NULL, NULL);
			// +1 from the acquire (see pdVisionEyeAcquire's comment: an
			// unretained event is a use-after-free inside encodeWaitForEvent).
			// ARC releases it at the end of this @autoreleasepool iteration,
			// which is after the command buffer has been committed.
			id<MTLSharedEvent> pubEvent = pubEvt
				? (__bridge_transfer id<MTLSharedEvent>)pubEvt : nil;
			if (pub) {
				id<MTLTexture> eye = (__bridge id<MTLTexture>)pub;
				id<MTLTexture> colorTex = cp_drawable_get_color_texture(drawable, 0);
				static int saidDev;
				if (!saidDev) {
					saidDev = 1;
					NSLog(@"perfectdark: [3d] eye %lux%lu fmt=%lu; eye device==drawable device: %d",
						(unsigned long)eye.width, (unsigned long)eye.height,
						(unsigned long)eye.pixelFormat,
						(int)(eye.device == colorTex.device));
				}
				if (pdEnsureEyeCopy(colorTex.device, eye)) {
					if (pubGen != pdEyeCopyGen) {
						// ONE wait for the pair: both textures were drawn by the
						// same ANGLE command stream and published together, so
						// the one (event, value) covers both blits.
						if (pubEvent) {
							[cmd encodeWaitForEvent:pubEvent value:pubVal];
						}
						id<MTLTexture> src[2] = {
							eye,
							pubR ? (__bridge id<MTLTexture>)pubR : eye,
						};
						id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
						for (int e = 0; e < 2; e++) {
							[blit copyFromTexture:src[e]
							          sourceSlice:0
							          sourceLevel:0
							         sourceOrigin:MTLOriginMake(0, 0, 0)
							           sourceSize:MTLSizeMake(src[e].width, src[e].height, 1)
							            toTexture:pdEyeCopy[e]
							     destinationSlice:0
							     destinationLevel:0
							    destinationOrigin:MTLOriginMake(0, 0, 0)];
							[blit generateMipmapsForTexture:pdEyeCopy[e]];
						}
						[blit endEncoding];
						pdEyeCopyGen = pubGen;
						pdVisionEyeCountSample(1);
					} else {
						pdVisionEyeCountSample(0);
					}
					panelHave = 1;

					// D-058: THE PANEL IS THE TRUTH AND THE EYE FOLLOWS IT.
					//
					// This block used to aspect-FIT the quad to the eye
					// unconditionally, and the eye was the compositor's
					// near-square per-view size (D-057) — so the Screen Width
					// row could not change the picture's shape by a single
					// pixel and the default drew as a square. The eye is now
					// re-wrapped at the panel's own aspect on the slider's
					// release, so in steady state the two agree and the quad is
					// simply what the rows asked for. During a drag (and for
					// the one or two frames a re-wrap takes) they disagree and
					// the picture STRETCHES, which is the spec's instant
					// feedback — SETTINGS-SPEC :62, "drag = quad stretches;
					// release = restart at the new aspect, sharp".
					//
					// The fit survives for the one case where the eye CANNOT
					// follow: PD_VP3D_EYE has pinned it (a gate's 1280x720
					// against the oracle). Then something has to give and a
					// pillarbox — undrawn quad, so passthrough room, not a
					// black bar hanging in the air — is the honest answer.
					if (pdVisionEyeIsPinned()) {
						const float eyeAspect = (float)eye.width / (float)eye.height;
						const float panelAspect = pdPanelHalfW / pdPanelHalfH;
						if (eyeAspect > panelAspect) {
							panelHalfH = pdPanelHalfW / eyeAspect;
						} else if (eyeAspect < panelAspect) {
							panelHalfW = pdPanelHalfH * eyeAspect;
						}
					}
				}
			}
			// ...and closes here: past this point the copy's own textures are
			// what the pass samples, and the blit's sources are retained by the
			// command buffer that encoded them.
			pdVisionEyeSampleEnd();
			simd_float4x4 model = simd_mul(placement, pdScale(panelHalfW, panelHalfH, 1.0f));

			for (size_t v = 0; v < views; v++) {
				// Foveation-correct, layout-agnostic targeting through the
				// view's texture map (foveation guide step 2) — never a
				// hard-coded texture 0 / slice v. With the .dedicated layout
				// each eye is its own texture at slice 0 AND carries its own
				// rate map indexed by the view's texture index; attaching the
				// wrong eye's map is the guide's "right eye fisheye that warps
				// with the head". The .layered fallback resolves to texture 0,
				// slice per view, and a nil map, so this path is correct there
				// too — and the simulator, which is mono, takes it with
				// views==1.
				cp_view_t view = cp_drawable_get_view(drawable, v);
				cp_view_texture_map_t tmap = cp_view_get_view_texture_map(view);
				size_t texIdx = cp_view_texture_map_get_texture_index(tmap);
				size_t slice = cp_view_texture_map_get_slice_index(tmap);
				MTLViewport vp = cp_view_texture_map_get_viewport(tmap);

				MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
				pass.colorAttachments[0].texture = cp_drawable_get_color_texture(drawable, texIdx);
				pass.colorAttachments[0].slice = slice;
				pass.colorAttachments[0].loadAction = MTLLoadActionClear;
				pass.colorAttachments[0].storeAction = MTLStoreActionStore;
				// Transparent, so everything this loop does not draw is the
				// passthrough room. The panel is the only opaque thing here.
				pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);

				size_t rmCount = cp_drawable_get_rasterization_rate_map_count(drawable);
				// The only reading that proves foveation is LIVE rather than
				// merely asked for (D-063): a drawable with no rate map is a
				// drawable the compositor is not resampling.
				pdVision3dFoveationRateMaps = (int)rmCount;
				if (rmCount > 0) {
					pass.rasterizationRateMap = cp_drawable_get_rasterization_rate_map(
						drawable, texIdx < rmCount ? texIdx : 0);
				}
				id<MTLTexture> depthTex = cp_drawable_get_depth_texture(drawable, texIdx);
				if (depthTex) {
					// Cleared AND stored: the compositor reprojects on depth
					// and rejects a frame whose depth it cannot read.
					pass.depthAttachment.texture = depthTex;
					pass.depthAttachment.slice = slice;
					pass.depthAttachment.loadAction = MTLLoadActionClear;
					pass.depthAttachment.storeAction = MTLStoreActionStore;
					pass.depthAttachment.clearDepth = 1.0;
				}

				id<MTLRenderCommandEncoder> enc =
					[cmd renderCommandEncoderWithDescriptor:pass];
				// Foveation contract (guide step 4): draw in the view's LOGICAL
				// viewport and let the attached rate map compress logical to
				// physical. Set before every draw in the pass.
				[enc setViewport:vp];

				// The surroundings dim layer, first and underneath: black at
				// the far plane with the dimming alpha, so the room recedes
				// and the panel is the bright thing in it. The curve is the
				// family's (SETTINGS-SPEC): a linear slider reads as even.
				if (pdDimPipeline && pdPanelDim > 0.0f) {
					const float dim = 1.0f - powf(1.0f - pdPanelDim, 2.2f);
					[enc setRenderPipelineState:pdDimPipeline];
					[enc setDepthStencilState:pdQuadDepthState];
					[enc setFragmentBytes:&dim length:sizeof(dim) atIndex:0];
					[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
				}

				if (pdQuadPipeline || pdSolidPipeline) {
					simd_float4x4 deviceFromEye = cp_view_get_transform(view);
					simd_float4x4 eyeFromOrigin =
						simd_inverse(simd_mul(originFromDevice, deviceFromEye));
					simd_float4x4 proj = matrix_identity_float4x4;
					if (__builtin_available(visionOS 2.0, *)) {
						// cp_view_get_tangents ABORTS under mixed immersion.
						proj = cp_drawable_compute_projection(
							drawable, cp_axis_direction_convention_right_up_back, v);
					}
					simd_float4x4 mvp = simd_mul(proj, simd_mul(eyeFromOrigin, model));

					// D-058: the view's horizontal FOV, from the projection's
					// own tangents — the only legal source under mixed
					// immersion (cp_view_get_tangents aborts). With the view's
					// width this is pixels-per-radian, and that is what sizes
					// the eye from the panel's angular width. View 0 only: both
					// eyes are the same shape and the note re-wraps the ring.
					if (v == 0 && proj.columns[0][0] > 0.0001f) {
						const float tr = (proj.columns[2][0] + 1.0f) / proj.columns[0][0];
						const float tl = (proj.columns[2][0] - 1.0f) / proj.columns[0][0];
						pdVisionEyeNoteCompositorFovX(atanf(tr) - atanf(tl));
					}

					if (panelHave && pdQuadPipeline) {
						// WHICH EYE THIS VIEW SAMPLES. On the headset views are
						// [L, R] in order, so the view index IS the eye. The
						// SIMULATOR is mono (views == 1) and would only ever
						// show eye L, which is why PD_VP3D_SHOWEYE exists: it
						// forces the eye so the L-vs-R fold can be diffed from
						// two scripted runs on the sim (plan §2.5).
						const int showEye = pdVisionEyeShowEye();
						const int eyeIdx = (showEye >= 0)
							? showEye : (int)(v & 1);
						id<MTLTexture> panelTex =
							pdEyeCopySRGB[eyeIdx] ?: pdEyeCopy[eyeIdx];
						[enc setRenderPipelineState:pdQuadPipeline];
						[enc setDepthStencilState:pdQuadDepthState];
						[enc setVertexBytes:&mvp length:sizeof(mvp) atIndex:0];
						[enc setFragmentTexture:panelTex atIndex:0];
						[enc setFragmentSamplerState:pdPanelSampler atIndex:0];
						[enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
					} else if (pdSolidPipeline) {
						// Nothing published yet (the space opened before the
						// engine's first eye landed). M1's proof colour, one
						// per eye so a stereo device can tell at a glance that
						// BOTH views are drawn — the simulator is mono and only
						// ever shows view 0's.
						simd_float4 tint = (v == 0)
							? simd_make_float4(0.08f, 0.16f, 0.42f, 1.0f)
							: simd_make_float4(0.42f, 0.10f, 0.12f, 1.0f);
						[enc setRenderPipelineState:pdSolidPipeline];
						[enc setDepthStencilState:pdQuadDepthState];
						[enc setVertexBytes:&mvp length:sizeof(mvp) atIndex:0];
						[enc setFragmentBytes:&tint length:sizeof(tint) atIndex:0];
						[enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
					}
				}
				[enc endEncoding];
			}

			cp_drawable_encode_present(drawable, cmd);
			[cmd commit];

			pdVision3dImmFrames++;
			if (pdVision3dImmFrames == 3 || (pdVision3dImmFrames % 600) == 0) {
				NSLog(@"perfectdark: [3d] frame %d views=%zu anchor=%d %.1f Hz",
					pdVision3dImmFrames, views, (int)pdHaveAnchor,
					(double)pdVision3dImmHz);
			}

			cp_frame_end_submission(frame);
		} // @autoreleasepool
	}

	// The display link is the clock again BEFORE anything else unwinds: the
	// engine is on the main thread and may be inside its wait right now.
	pdPacingSetExternalSource(0);

	if (notifyEnded) {
		pdVision3dImmersiveEnded();
	}
	// Signalled LAST, after everything else is done: pdVision3dSetMode(false)
	// waits on exactly this before letting the space be dismissed.
	pdVision3dImmRunning = 0;
}

#endif // TARGET_OS_VISION
