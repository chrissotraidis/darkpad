/*
 * pd_frame_prof.h — the frame breakdown instrument (app/gfx/pd_frame_prof.c).
 *
 * Included by the overlay patches that place the begin/end pairs in the
 * engine's frame; every call site is on the game thread. On a build without
 * PD_IOS_PROFILER nothing includes this and nothing is compiled.
 */

#ifndef PD_FRAME_PROF_H
#define PD_FRAME_PROF_H

#ifdef __cplusplus
extern "C" {
#endif

enum {
	/* Present-to-present of the ENGINE's frame loop, start to start.
	 * Filled by pdProfFrame(); never begin/end'd by hand. */
	PDPROF_FRAME = 0,
	/* mainTick()'s game logic: the tick, the AI, the display list build.
	 * Ends before rdpCreateTask(), which is where rendering starts. */
	PDPROF_GAME,
	/* gfx_run_dl() plus its final flush: the RSP/RDP interpreter, the
	 * software vertex transform, and the draws handed to ANGLE. */
	PDPROF_GFXDL,
	/* gfx_rapi->end_frame() and the pre-swap callback. */
	PDPROF_GFXEND,
	/* The CADisplayLink wait (docs/pacing.md). This is SLACK: a big number
	 * here means the frame had time to spare. */
	PDPROF_PACE,
	/* eglSwapBuffers through ANGLE-Metal: the present itself, which is also
	 * where the driver blocks if the GPU is behind. */
	PDPROF_SWAP,
	/* gfx_end_frame(): finish_render() and swap_buffers_end(). */
	PDPROF_FINISH,
	/* schedEndFrame() up to videoEndFrame(): input, the per-frame ticks,
	 * the audio push. */
	PDPROF_SCHED,
	/* import_texture(): decode plus upload. Nests inside gfxdl. */
	PDPROF_TEX,
	/* The iOS shell's one call into the frame (pdIosFrameHook): the bridge
	 * drain, the pad poll, and the touch layer's publish - which is UIKit and
	 * CoreAnimation work on the GAME thread. */
	PDPROF_SHELL,
	/* The engine's own outer loop, between the end of one schedEndFrame and
	 * the start of the next schedStartFrame: the tick gate's spin and
	 * Game.ExtraSleep's nanosleep. */
	PDPROF_LOOP,
	/* schedStartFrame -> videoStartFrame -> gfx_start_frame. */
	PDPROF_STARTF,
	/* videoEndFrame: gfx_end_frame plus video.c's fps bookkeeping. FINISH
	 * nests inside this. */
	PDPROF_ENDF,
	/* frametimeCalculate(): the tick gate's do/while, which also carries an
	 * unconditional sysSleep when Game.ExtraSleep is on. Inside mainTick and
	 * BEFORE the game section. */
	PDPROF_TICKGATE,
	/* gfx_run's prologue: everything between the display list being handed
	 * over and gfx_run_dl starting - the backend's start_frame, the
	 * framebuffer bind and the clear. Under ANGLE-Metal this is where the
	 * CAMetalLayer drawable is acquired, and acquiring one BLOCKS when they
	 * are all in flight. */
	PDPROF_ACQUIRE,
	/* An XBLA record's STFS read + LZX inflate + untile. Nests inside tex.
	 * Upstream measures this as a hitch, not a per-frame cost
	 * (CLAUDE-notes/performance.md); this is how we check that on a phone. */
	PDPROF_XBLA,
	PDPROF_COUNT
};

void pdProfBegin(int section);
void pdProfEnd(int section);
/* One event of PDPROF_TEX or PDPROF_XBLA happened this frame. */
void pdProfCount(int section);
/* The engine's frame boundary: roll every accumulator into its ring. */
void pdProfFrame(void);
void pdProfReset(void);
int pdProfReport(char *buf, int len);

#ifdef __cplusplus
}
#endif

#endif
