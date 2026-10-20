// PDPacing.h — CADisplayLink is the only pacer. docs/pacing.md is the design.
#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * How the game thread waits for the link (D-045).
 *
 * `PDPacingWaitSem` is the original: a plain `dispatch_semaphore_wait`. On the
 * MAIN thread — which is this port's game thread — that is what killed the user's
 * touch at the 60 Hz setting, because a blocked main thread is a main run loop
 * that never turns, and UIKit dispatches its queued touches from that loop.
 *
 * `PDPacingWaitRunLoop` (the default) waits by RUNNING the main run loop until
 * the link has signalled, so event dispatch is serviced for the whole of the
 * pacer's slack instead of for SDL's two microseconds.
 *
 * Kept switchable so the two can be A/B'd live on the phone in one session:
 * `pacing wait sem|runloop` on the bridge, `pacing_wait_mode` in `state` and in
 * the heartbeat.
 */
typedef NS_ENUM(int, PDPacingWaitMode) {
	PDPacingWaitSem = 0,
	PDPacingWaitRunLoop = 1,
};

@interface PDPacing : NSObject

@property (class, readonly) PDPacing *shared;

/** How the wait waits (D-045). Default `PDPacingWaitRunLoop`. */
@property (atomic) PDPacingWaitMode waitMode;

/**
 * Start the link on its own thread. Called once, from the shell, before the
 * engine's first frame. `bypass` is the replay path: --fixed-step / --exit-frame
 * runs want no pacing at all (docs/pacing.md §What this does NOT change).
 */
- (void)startWithBypass:(BOOL)bypass;

/** Target rate, 60 or 120. Clamped to what the panel can do. */
@property (nonatomic) NSInteger targetHz;

/**
 * How often the ENGINE will actually tick, which is not always how often the
 * link fires (D-034).
 *
 * The engine has its own tick gate — `g_Vars.mininc60` / `Game.TickRateDivisor`
 * (src/game/timing.c:41-54) — and with the divisor at its default 1 it refuses
 * to begin a frame less than a 60th of a second after the last one, whatever
 * the display link says. A 120 Hz link over a 60 Hz engine is the worst of both
 * worlds: every other callback finds no waiter, and the frames that do land
 * land 8.3 ms and 16.7 ms apart in an uneven mix. That is the judder the user
 * reported on the Air, and it is why the pacer needs to know the engine's rate
 * rather than only the panel's. PDDefaultsApplyToEngine() sets both.
 */
@property (nonatomic) NSInteger engineTickHz;

/** Zero the present-interval histogram (the bridge's `pacing reset`). */
- (void)resetHistogram;

/**
 * THE CLOCK CAN COME FROM OUTSIDE (visionOS 3D, D-050, plan §2.6).
 *
 * "Exactly one pacer, one wait, one present" survives unchanged; only the clock
 * changes. While the immersive space is up there is no CAMetalLayer and no
 * display link worth having: the thing that decides when a frame may be drawn
 * is the COMPOSITOR, whose `cp_time_wait_until(optimal_input_time)` is the one
 * honest "the next frame is due now" on the system. So the link is paused and
 * `pdPacingSignalExternal()` — called once per compositor frame, right after
 * that wait — releases the game thread instead.
 *
 * Everything else about the wait is preserved deliberately: it stays at the TOP
 * of the frame (D-040) and it still waits by running the main run loop (D-045),
 * because the game thread is the main thread and SwiftUI, UIKit and the main
 * dispatch queue all live on it.
 *
 * `pacing_mode` in the report says which clock is live: `compositor` or
 * `displaylink` (or `bypass` for a replay run).
 */
@property (atomic) BOOL externalSource;

/**
 * While the compositor is the clock, the ENGINE's declared rate follows it
 * (D-056) — unless this is set, which is what `pacing engine <hz>` does.
 *
 * The declared rate exists so the pacer can divide a faster clock down to an
 * even cadence. On a 90 Hz headset a declared 60 divides by two and runs the
 * game at 45, which is nobody's setting; so in 3D the declared rate is the
 * compositor's measured cadence and the divisor settles at 1. The bridge's
 * instrument still needs to reach the divisor arithmetic on a simulator whose
 * panel is always 60 Hz, so pinning keeps that door open.
 */
@property (atomic) BOOL engineHzPinned;

/** Presenting is suspended while backgrounded: the drawable is not ours then. */
@property (atomic, readonly) BOOL presentAllowed;

/**
 * Wait for the display link at the TOP of the frame instead of just before the
 * present (D-040).
 *
 * The present is immediately followed by the next frame's drawable
 * acquisition, and under ANGLE-Metal that call blocks while the drawables are
 * all in flight - so the default placement makes the frame wait twice on the
 * same clock at two different phases. Off by default until a device
 * measurement says otherwise; `pacing early on|off` on the bridge flips it live
 * so both can be measured in one session.
 */
@property (nonatomic) BOOL earlyWait;

/** Lifecycle. */
- (void)suspend;
- (void)resume;

/** The instrument, as the bridge's `state` prints it. */
- (NSString *)report;

@end

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Overlay patch 0016's call: block until the display server says the next frame
 * is due. Returns 1 if the caller should present, 0 if it should skip (the app
 * is backgrounded, or the wait timed out with no link running).
 */
int pdIosPacingWaitForPresent(void);

/**
 * The pacer's whole state in a struct, readable from a thread that may not
 * allocate and may not touch UIKit (PDWatchdog.m).
 *
 * -report builds an NSString, which is exactly what a heartbeat written by a
 * plain pthread while the process is wedged must not do. Everything here is an
 * atomic or a word-sized scalar; a torn read is of no consequence, it is an
 * instrument.
 */
typedef struct {
	double measuredHz;
	long targetHz;
	long engineHz;
	long appliedLinkHz;
	int divisor;
	int presentAllowed;
	int earlyWait;
	int bypass;
	/** D-045: 0 = semaphore, 1 = the main run loop. */
	int waitMode;
	/** D-050: 1 while the compositor is the clock instead of the link. */
	int externalSource;
	/** External clock signals delivered (compositor frames that released one). */
	unsigned long long externalSignals;
	/** Signal-to-wake latency of the wait, microseconds: mean, max, samples. */
	double wakeUsMean;
	double wakeUsMax;
	unsigned long long wakeSamples;
	unsigned long long links;
	unsigned long long presents;
	unsigned long long dropped;
	unsigned long long waiting;
} PDPacingSnap;

void pdPacingSnapshot(PDPacingSnap *out);

/**
 * 1 while the app may draw and present; 0 from didEnterBackground until
 * willEnterForeground (-suspend / -resume). For the loops that draw without the
 * pacer's wait - GE Plus's startup notices (overlay 0042, D-075) - which must
 * not start a frame at all while it is 0. Game thread.
 */
int pdIosPresentAllowed(void);

/**
 * One external clock tick: the compositor has reached this frame's optimal
 * input time, so the game thread may draw (D-050).
 *
 * Called from the immersive render thread, and safe to call when the external
 * source is off (it does nothing then, so a loop that is winding down cannot
 * double-drive the link).
 */
void pdPacingSignalExternal(void);

/** Switch the clock. On: the link is paused. Off: the link runs again. */
void pdPacingSetExternalSource(int on);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
