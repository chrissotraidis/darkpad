// PDPacing.m — the display link, its thread, and the semaphore the game thread
// waits on. Design and verification metric: docs/pacing.md.
#import "PDPacing.h"
#import "PDVision.h"
#import "PDWatchdog.h"

@interface PDPacing ()
- (void)fillSnapshot:(PDPacingSnap *)out;
/** D-050: one compositor frame's worth of "you may draw now". */
- (void)signalExternal;
@end

#import <QuartzCore/QuartzCore.h>

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// Eight seconds of history at 60 Hz, four at 120: long enough that a p95 means
// something, short enough that a stall five minutes ago is not still in it.
#define kHistN 512u

@implementation PDPacing {
	CADisplayLink *_link;
	NSThread *_thread;
	dispatch_semaphore_t _sem;
	BOOL _bypass;

	// The instrument. Written by the link thread, read by anyone; plain 64-bit
	// counters, so a torn read is not possible on arm64 and a lock would only
	// add a way for a report to stall the pacer.
	_Atomic(uint64_t) _links;
	_Atomic(uint64_t) _presents;
	_Atomic(uint64_t) _dropped;
	_Atomic(uint64_t) _waiting;
	// D-050: the compositor as the clock. `_external` is the switch; the link is
	// paused while it is on and `_externalSignals` counts what arrived, so a
	// gate can tell "the loop signalled" from "the engine waited".
	_Atomic(int) _external;
	_Atomic(uint64_t) _externalSignals;
	// D-056: set by `pacing engine <hz>`, which pins the declared rate so the
	// compositor's own cadence stops driving it.
	_Atomic(int) _engineHzPinned;

	double _hzWindowStart;
	uint64_t _hzWindowLinks;
	double _measuredHz;

	// The link divisor (D-034): how many link callbacks make one present. 1
	// normally; 2 when the link is running at twice the rate the engine can
	// tick, which is the ProMotion-panel-with-a-60-Hz-engine case. Written by
	// the link thread only.
	_Atomic(int) _divisor;
	// The range last handed to the link, so it is written once (D-043).
	NSInteger _appliedLinkHz;
	uint64_t _linkSeq;

	// The present-interval histogram. A plain ring of the last kHistN
	// frame-to-frame intervals in milliseconds, written by the game thread in
	// -waitForPresent and read (copied, sorted) by -report. Torn reads are of
	// no consequence: it is an instrument, not a control input.
	float _hist[kHistN];
	uint32_t _histN;
	uint32_t _histWrite;
	double _lastPresentAt;

	// D-045: how the wait waits, and the instrument that says what the choice
	// costs. `_wakeSource` is a no-op CFRunLoopSource on the MAIN run loop: the
	// link thread signals it so a main thread sitting in CFRunLoopRunInMode
	// returns at once instead of at its timeout. (CFRunLoopWakeUp alone does
	// not do that - a wakeup with no source to handle sends the loop straight
	// back to sleep; CFRunLoopStop would, but it stops whatever innermost run
	// loop happens to be turning, including UIKit's own.)
	_Atomic(int) _waitMode;
	_Atomic(CFRunLoopSourceRef) _wakeSource;
	// Mach-time nanoseconds at which the link signalled the waiter, 0 when
	// consumed. The wake latency is now() - this, taken by the waiter.
	_Atomic(uint64_t) _signalNs;
	_Atomic(uint64_t) _wakeSumUs;
	_Atomic(uint64_t) _wakeMaxUs;
	_Atomic(uint64_t) _wakeSamples;
	float _wake[kHistN];
	uint32_t _wakeN;
	uint32_t _wakeWrite;
	BOOL _inRunLoopWait;
}

static inline uint64_t pdNowNs(void)
{
	return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

+ (instancetype)shared
{
	static PDPacing *shared;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ shared = [PDPacing new]; });
	return shared;
}

- (instancetype)init
{
	if ((self = [super init])) {
		_sem = dispatch_semaphore_create(0);
		_targetHz = 60;
		_engineTickHz = 60;
		atomic_store(&_divisor, 1);
		_presentAllowed = YES;
		// D-040, measured on the user's Air: the wait belongs at the TOP of the
		// frame, not just before the present. With it here the phone holds a
		// clean 120.0 fps with a jitter of 0.00 %; with it before the present
		// it managed 72-79 fps and 48 % jitter, because the drawable
		// acquisition at the start of the next frame was blocking for another
		// 6.9 ms on top of the pacer's own wait.
		_earlyWait = YES;
		// D-045: the run loop is the default wait. A semaphore wait on the main
		// thread starves UIKit's event dispatch for the whole of the pacer's
		// slack - ~16 ms of every 16.7 ms frame at the 60 Hz setting - and the
		// touches queue up undelivered.
		atomic_store(&_waitMode, PDPacingWaitRunLoop);
	}
	return self;
}

- (PDPacingWaitMode)waitMode
{
	return (PDPacingWaitMode)atomic_load(&_waitMode);
}

- (void)setWaitMode:(PDPacingWaitMode)waitMode
{
	PDLifecycle("pacing wait mode -> %s", waitMode == PDPacingWaitRunLoop ? "runloop" : "sem");
	atomic_store(&_waitMode, (int)waitMode);
	[self resetWakeStats];
}

- (void)startWithBypass:(BOOL)bypass
{
	_bypass = bypass;
	if (bypass) {
		NSLog(@"perfectdark: pacing BYPASS (a --fixed-step/--exit-frame run paces itself)");
		return;
	}

	_thread = [[NSThread alloc] initWithTarget:self selector:@selector(linkThread) object:nil];
	_thread.name = @"pd-pacing";
	// Above default so a busy main thread cannot starve the clock; not
	// time-constraint, because all this thread does is signal a semaphore.
	_thread.qualityOfService = NSQualityOfServiceUserInteractive;
	[_thread start];
}

- (void)linkThread
{
	@autoreleasepool {
		_link = [CADisplayLink displayLinkWithTarget:self selector:@selector(linkFired:)];

		[self applyLinkRate];
		const NSInteger maxHz = PDVisionMaxFPS();
		const NSInteger want = _appliedLinkHz;

		[_link addToRunLoop:NSRunLoop.currentRunLoop forMode:NSRunLoopCommonModes];
		NSLog(@"perfectdark: pacing display link at %ld Hz (panel max %ld) on thread %@, mode %@",
			(long)want, (long)maxHz, NSThread.currentThread.name ?: @"?",
			NSRunLoop.currentRunLoop.currentMode ?: @"(none yet)");

		// Runs for the life of the process. The link is paused, never removed.
		while (!NSThread.currentThread.isCancelled) {
			@autoreleasepool {
				[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
				                       beforeDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
			}
		}
	}
}

- (void)linkFired:(CADisplayLink *)link
{
	atomic_fetch_add(&_links, 1);

	double now = CACurrentMediaTime();
	if (_hzWindowStart <= 0.0) {
		_hzWindowStart = now;
		_hzWindowLinks = 0;
	}
	_hzWindowLinks++;
	if (now - _hzWindowStart >= 1.0) {
		_measuredHz = _hzWindowLinks / (now - _hzWindowStart);
		_hzWindowStart = now;
		_hzWindowLinks = 0;

		[self recomputeDivisor];
	}

	// A divided link drops the in-between callbacks before the waiter is ever
	// considered, so they are not counted as "the game was late".
	_linkSeq++;
	const int div = atomic_load(&_divisor);
	if (div > 1 && (_linkSeq % (uint64_t)div) != 0) {
		return;
	}

	[self releaseWaiter];
}

/**
 * The clock is one thing, the ENGINE's rate is another (D-034).
 *
 * If the clock runs appreciably faster than the engine will tick, signalling
 * every tick does not make the game faster - it makes the cadence UNEVEN,
 * because the frames that cannot be served alternate between waiting one slot
 * and two. Dividing down to an integer multiple of the engine's rate gives an
 * even cadence instead: the same frame rate, evenly spaced.
 *
 * Called from BOTH clocks' one-second windows since D-056. It used to be inline
 * in -linkFired: only, which meant that while the compositor was the clock the
 * divisor was never re-derived at all and `pacing engine <hz>` did nothing -
 * measured by dev1, which asked for 30 Hz under a 60 Hz compositor and got a
 * divisor of 1.
 */
- (void)recomputeDivisor
{
	const double engine = (double)MAX((NSInteger)1, self.engineTickHz);
	int want = 1;
	if (_measuredHz >= engine * 1.5) {
		want = (int)lround(_measuredHz / engine);
		want = MAX(1, MIN(8, want));
	}
	if (want != atomic_load(&_divisor)) {
		PDLifecycle("pacing divisor %d -> %d (clock %.1f Hz, engine %ld Hz)",
			atomic_load(&_divisor), want, _measuredHz, (long)self.engineTickHz);
		atomic_store(&_divisor, want);
	}
}

/**
 * Release whoever is waiting, whichever clock ticked.
 *
 * Credit is never banked: if nobody is waiting, the game thread is late and
 * this frame is simply gone (docs/pacing.md). Signalling anyway would let a
 * hitch turn into a burst of unpaced presents. The external source obeys the
 * same rule for the same reason.
 */
- (void)releaseWaiter
{
	if (atomic_load(&_waiting) > 0) {
		atomic_store(&_signalNs, pdNowNs());
		dispatch_semaphore_signal(_sem);
		[self wakeMainIfWaiting];
	} else {
		atomic_fetch_add(&_dropped, 1);
	}
}

// ---------------------------------------------------------------------------
// The external clock (D-050). PDPacing.h says why; the mechanism is that the
// link is paused and someone else calls -signalExternal once a frame.
// ---------------------------------------------------------------------------

- (BOOL)externalSource
{
	return atomic_load(&_external) != 0;
}

- (void)setExternalSource:(BOOL)on
{
	if ((atomic_load(&_external) != 0) == !!on) {
		return;
	}
	atomic_store(&_external, on ? 1 : 0);
	PDLifecycle("pacing clock -> %s", on ? "compositor" : "displaylink");
	// The link is PAUSED, never removed: it is on another thread's run loop and
	// this port has already paid once for reconfiguring a live CADisplayLink
	// from the wrong thread (D-043). Pausing is the one safe operation.
	CADisplayLink *link = _link;
	if (link) {
		if (_thread && NSThread.currentThread != _thread) {
			[self performSelector:@selector(applyExternalToLink)
			             onThread:_thread withObject:nil waitUntilDone:NO];
		} else {
			[self applyExternalToLink];
		}
	}
	atomic_store(&_divisor, 1);
	[self resetHistogram];
	if (!on) {
		// Whoever is waiting for a compositor frame that will never arrive gets
		// out now; the link's next callback takes over.
		[self releaseWaiter];
	}
}

- (void)applyExternalToLink
{
	_link.paused = atomic_load(&_external) ? YES : NO;
}

- (void)signalExternal
{
	if (!atomic_load(&_external)) {
		return;
	}
	atomic_fetch_add(&_externalSignals, 1);
	atomic_fetch_add(&_links, 1);

	// The same one-second cadence window the link uses, so `pacing_hz` means
	// the same thing under either clock.
	const double now = CACurrentMediaTime();
	if (_hzWindowStart <= 0.0) {
		_hzWindowStart = now;
		_hzWindowLinks = 0;
	}
	_hzWindowLinks++;
	if (now - _hzWindowStart >= 1.0) {
		_measuredHz = _hzWindowLinks / (now - _hzWindowStart);
		_hzWindowStart = now;
		_hzWindowLinks = 0;
		[self adoptCompositorRate];
		[self recomputeDivisor];
	}

	// The divisor applies to THIS clock too, and for the same reason: a pinned
	// engine rate below the compositor's is served evenly or not at all.
	_linkSeq++;
	const int div = atomic_load(&_divisor);
	if (div > 1 && (_linkSeq % (uint64_t)div) != 0) {
		return;
	}

	[self releaseWaiter];
}

/**
 * In 3D the COMPOSITOR's rate is the engine's rate (D-056).
 *
 * The engine's declared tick rate was whatever the 2D Frame rate row asked for,
 * and under the external clock that number is only used for one thing: the
 * divisor that decides how many clock ticks go by per served frame. On a 90 Hz
 * headset with a 60 Hz declared rate that arithmetic reads `90 >= 60 * 1.5` and
 * divides by two — the engine runs at 45 while the compositor runs at 90, which
 * is the worst of both and not what any row asked for.
 *
 * So while the compositor is the clock the declared rate FOLLOWS it, and the
 * divisor settles at 1. Rounded to the nearest 5 Hz so a cadence that measures
 * 89.7 one second and 90.2 the next does not re-derive anything.
 *
 * `pacing engine <hz>` still wins, because it is an instrument: it pins the
 * declared rate so that `pacing engine 30` under a 60 or 90 Hz compositor still
 * reaches the divisor arithmetic, which is the only way to reach it on a
 * simulator whose panel is always 60 Hz.
 */
- (void)adoptCompositorRate
{
	if (!atomic_load(&_external) || atomic_load(&_engineHzPinned)) {
		return;
	}
	if (!(_measuredHz > 1.0)) {
		return;
	}
	const NSInteger want = (NSInteger)(lround(_measuredHz / 5.0) * 5);
	if (want < 20 || want > 240 || want == _engineTickHz) {
		return;
	}
	// Not on this thread: this is the compositor's render thread, and
	// -setEngineTickHz: logs, resets the histogram the pacing thread reads and
	// is the settings page's own setter. One hop a rate CHANGE, never per frame.
	dispatch_async(dispatch_get_main_queue(), ^{
		if (atomic_load(&self->_external) && !atomic_load(&self->_engineHzPinned)) {
			self.engineTickHz = want;
		}
	});
}

- (BOOL)engineHzPinned { return atomic_load(&_engineHzPinned) != 0; }

- (void)setEngineHzPinned:(BOOL)pinned
{
	atomic_store(&_engineHzPinned, pinned ? 1 : 0);
	PDLifecycle("pacing engine hz %s", pinned ? "PINNED (instrument)" : "follows the clock");
}

/**
 * Wake a main thread that is waiting inside the run loop (D-045).
 *
 * The semaphore is still the flag in both modes - this only makes the waiter
 * LOOK at it promptly. Only signalled in run-loop mode, so that the semaphore
 * A/B measures the semaphore and nothing else.
 */
- (void)wakeMainIfWaiting
{
	if (atomic_load(&_waitMode) != PDPacingWaitRunLoop) {
		return;
	}
	CFRunLoopSourceRef src = atomic_load(&_wakeSource);
	if (!src) {
		return;
	}
	CFRunLoopSourceSignal(src);
	CFRunLoopWakeUp(CFRunLoopGetMain());
}

static void pdWakeSourcePerform(void *info)
{
	(void)info;	// Nothing to do: the signal exists to make the loop return.
}

/** Created once, on the main thread, the first time the main thread waits. */
- (void)ensureWakeSource
{
	if (atomic_load(&_wakeSource)) {
		return;
	}
	CFRunLoopSourceContext ctx = {0};
	ctx.perform = pdWakeSourcePerform;
	CFRunLoopSourceRef src = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &ctx);
	CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
	atomic_store(&_wakeSource, src);
	PDLifecycle("pacing wake source installed on the main run loop");
}

- (void)resetWakeStats
{
	atomic_store(&_wakeSumUs, 0);
	atomic_store(&_wakeMaxUs, 0);
	atomic_store(&_wakeSamples, 0);
	_wakeN = 0;
	_wakeWrite = 0;
}

/** Charge the time between the link's signal and this waiter noticing it. */
- (void)noteWake
{
	const uint64_t at = atomic_exchange(&_signalNs, 0);
	if (!at) {
		return;
	}
	const uint64_t now = pdNowNs();
	if (now <= at) {
		return;
	}
	const uint64_t us = (now - at) / 1000u;
	atomic_fetch_add(&_wakeSumUs, us);
	atomic_fetch_add(&_wakeSamples, 1);
	if (us > atomic_load(&_wakeMaxUs)) {
		atomic_store(&_wakeMaxUs, us);
	}
	_wake[_wakeWrite % kHistN] = (float)us;
	_wakeWrite++;
	if (_wakeN < kHistN) {
		_wakeN++;
	}
}

/**
 * The panel rate the player asked for.
 *
 * The range is applied ON THE LINK'S OWN THREAD (D-043), and that is a
 * correctness fix rather than tidiness. CADisplayLink is not thread-safe and
 * this one is scheduled on the pacing thread's run loop, but -setTargetHz: is
 * called from the GAME thread - which is the main thread - by the settings
 * page's commit. So every Frame rate change this app has ever made has
 * reconfigured a live display link from the wrong thread, underneath
 * CoreAnimation, while the main thread is also the UIKit thread.
 *
 * That is the shape of the user's dead touch: it survives everything observable
 * (routing, windows, key window, the engine, the bridge), it is not the tick
 * gate (proven: the gate was already off and it still broke), and it happens
 * on a rate CHANGE rather than at a rate.
 */
- (void)setTargetHz:(NSInteger)targetHz
{
	PDLifecycle("pacing setTargetHz %ld (was %ld, link=%s)", (long)targetHz, (long)_targetHz,
		_link ? "up" : "none");
	_targetHz = targetHz;
	if (!_link) {
		return;
	}
	if (_thread && NSThread.currentThread != _thread) {
		[self performSelector:@selector(applyLinkRate)
		             onThread:_thread withObject:nil waitUntilDone:NO];
		return;
	}
	[self applyLinkRate];
}

/**
 * The link's rate range, which is the PANEL's maximum and nothing else (D-043).
 *
 * It used to be the rate the PLAYER asked for, and a 60 Hz range on the user's
 * 120 Hz panel is what kills UIKit touch delivery to this app. A/B'd live on
 * the phone over USB, with him tapping throughout and no relaunch between the
 * two halves: at a 60 Hz range `ui_touches_began` froze for ten seconds of
 * tapping; the Frame rate row moved to 120 and it climbed again within one
 * transition ("my tapping is working now… because you changed to 120"); back to
 * 60 and it froze again. Repeatable, and independent of the engine's tick gate
 * and of D-040's wait placement, both of which were ruled out by their own A/Bs
 * first.
 *
 * So the link never changes rate at runtime any more. The player's 60 is
 * delivered by the machinery that already existed for it (D-034, M-031): the
 * engine ticks at 60, the link runs at 120, and -linkFired: divides by two and
 * signals every other callback - the same frame rate, evenly spaced, and the
 * touch path sees the same link it sees at 120.
 *
 * Two bugs go with it. The range is applied on the LINK'S OWN THREAD, because
 * CADisplayLink is not thread-safe and this one is scheduled on the pacing
 * thread's run loop while -setTargetHz: is called from the game thread; and
 * because `want` no longer depends on the player's setting, in practice it is
 * applied once, at creation, and never again.
 */
- (void)applyLinkRate
{
	CADisplayLink *link = _link;
	if (!link) {
		return;
	}
	const NSInteger maxHz = PDVisionMaxFPS();
	// D-056: the panel's maximum, whatever it is. `maxHz >= 120 ? 120 : 60` gave
	// this Vision Pro a 60 Hz range on a 90 Hz panel, which is the 2D half of
	// the user's "set to 120, locked at 60".
	const NSInteger want = PDPanelHighHz();
	if (want == _appliedLinkHz) {
		return;
	}
	_appliedLinkHz = want;
	link.preferredFrameRateRange = CAFrameRateRangeMake((float)want, (float)want, (float)want);
	PDLifecycle("pacing applyLinkRate -> %ld Hz (panel max %ld) on thread %s", (long)want,
		(long)maxHz, NSThread.currentThread.name.UTF8String ?: "?");
}

- (void)setEngineTickHz:(NSInteger)engineTickHz
{
	if (engineTickHz < 1) {
		engineTickHz = 60;
	}
	if (_engineTickHz == engineTickHz) {
		return;
	}
	PDLifecycle("pacing setEngineTickHz %ld (divisor forced to 1)", (long)engineTickHz);
	_engineTickHz = engineTickHz;
	// Re-derived on the link thread's next one-second window; forced to 1 now
	// so a rate CHANGE never spends a second dividing by the old answer.
	atomic_store(&_divisor, 1);
	[self resetHistogram];
	NSLog(@"perfectdark: pacing engine tick rate %ld Hz", (long)engineTickHz);
}

- (void)resetHistogram
{
	_histN = 0;
	_histWrite = 0;
	_lastPresentAt = 0.0;
	[self resetWakeStats];
}

- (void)suspend
{
	PDLifecycle("pacing SUSPEND (link paused, present blocked)");
	_presentAllowed = NO;
	_link.paused = YES;
	// Whoever is blocked in the wait gets out now and skips its present rather
	// than swapping into a drawable the system is about to take away.
	dispatch_semaphore_signal(_sem);
	[self wakeMainIfWaiting];
}

- (void)resume
{
	PDLifecycle("pacing RESUME");
	// NOT while the compositor is the clock: un-pausing the link there would
	// give the engine two clocks, which is the one thing docs/pacing.md forbids.
	if (!atomic_load(&_external)) {
		_link.paused = NO;
	}
	_presentAllowed = YES;
}

/**
 * The wait, at the top of the frame instead of just before the present.
 *
 * D-040. The design (docs/pacing.md) put the one wait immediately before the
 * present, on the reasoning that the present is what must be paced. What that
 * misses is what happens immediately AFTER a present: the next frame's
 * gfx_run() asks ANGLE-Metal for a drawable, and CoreAnimation makes that call
 * block while they are all in flight. So the frame ends up waiting twice on the
 * same clock at different phases - which is exactly the failure docs/pacing.md
 * was written to prevent, arriving through the drawable pool instead of through
 * eglSwapInterval.
 *
 * In early mode the game thread waits HERE, then does its ~3.5 ms of work, then
 * presents with no wait at all - so the drawable acquisition happens a
 * millisecond and a half after the link fires rather than immediately after a
 * present. Same rate, same one wait, different phase.
 *
 * A no-op unless the mode is on; `pacing early on|off` toggles it live so the
 * two can be compared on the same device in the same session.
 */
- (void)waitAtFrameStart
{
	if (!_earlyWait || _bypass) {
		return;
	}
	[self waitForLink];
}

- (int)waitForPresent
{
	if (_bypass) {
		return 1;
	}

	if (_earlyWait) {
		// Already waited at the top of the frame; this is just the present.
		return _presentAllowed ? 1 : 0;
	}

	if (!_presentAllowed) {
		// Backgrounded. The game thread parks HERE - not mid-frame, not in a
		// draw call - which is what stops anything being rendered into a
		// CAMetalLayer whose drawables the system has taken back. It has to
		// keep the run loop turning while it waits, because this is the main
		// thread and the willEnterForeground notification arrives on it: a
		// plain sleep here would deadlock the app in the background.
		NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30.0];
		while (!_presentAllowed && [deadline timeIntervalSinceNow] > 0) {
			@autoreleasepool {
				[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
				                       beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
			}
		}
		// Either we came back (and this frame is stale, so skip its present and
		// let the next one be drawn fresh) or we are still away.
		return 0;
	}

	return [self waitForLink];
}

/**
 * The wait, run on the MAIN run loop rather than blocked on the semaphore.
 *
 * D-045, proven live on the user's phone. The game thread here IS the main
 * thread, and the main thread is UIKit's event-dispatch thread: UIKit hands a
 * HID event to the window from a source on the main run loop, and that loop
 * only ever turned inside SDL's two-microsecond `UIKit_PumpEvents`. With the
 * wait at the top of the frame (D-040) the main thread then sat in
 * `dispatch_semaphore_wait` for ~16 of every 16.7 ms at the 60 Hz setting, so
 * touches were not LOST - they queued in UIKit and were never dispatched. (At
 * 120 the same block is ~8 ms and the loop keeps up, which is the asymmetry
 * three rounds spent hypotheses on.)
 *
 * So the wait turns the loop instead. The semaphore is still the flag: it is
 * polled with a zero timeout each time round, and the link thread wakes the
 * loop with a no-op source so the return is prompt rather than at the timeout.
 *
 * Runs only on the main thread and only in run-loop mode; everything else
 * (the replay path, any non-main caller, a re-entrant wait) falls through to
 * the plain semaphore below.
 */
- (long)runLoopWaitSeconds:(double)timeout
{
	[self ensureWakeSource];
	const uint64_t deadline = pdNowNs() + (uint64_t)(timeout * 1e9);
	for (;;) {
		if (dispatch_semaphore_wait(_sem, DISPATCH_TIME_NOW) == 0) {
			[self noteWake];
			return 0;
		}
		const uint64_t now = pdNowNs();
		if (now >= deadline) {
			return 1;
		}
		const double remaining = (double)(deadline - now) / 1e9;
		SInt32 r;
		@autoreleasepool {
			r = CFRunLoopRunInMode(kCFRunLoopDefaultMode, remaining, true);
		}
		if (r == kCFRunLoopRunFinished) {
			// No sources at all in this mode: running it again would be a spin
			// on a hot core. Should not happen on a live UIKit main loop, but
			// the fallback costs nothing and bounds the damage if it does.
			const long timedOut = dispatch_semaphore_wait(_sem,
				dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)));
			if (!timedOut) {
				[self noteWake];
			}
			return timedOut;
		}
	}
}

/** The block itself, plus the cadence instrument. 1 = go, 0 = do not present. */
- (int)waitForLink
{
	atomic_fetch_add(&_waiting, 1);
	// The timeout is a deadlock guard, not a pacing mechanism: if the link is
	// not running (backgrounded, or a run loop that never came up) the game
	// thread must still make progress rather than hang forever.
	long timedOut;
	if (atomic_load(&_waitMode) == PDPacingWaitRunLoop && NSThread.isMainThread && !_inRunLoopWait) {
		_inRunLoopWait = YES;
		timedOut = [self runLoopWaitSeconds:0.25];
		_inRunLoopWait = NO;
	} else {
		timedOut = dispatch_semaphore_wait(_sem,
			dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)));
		if (!timedOut) {
			[self noteWake];
		}
	}
	atomic_fetch_sub(&_waiting, 1);

	if (!_presentAllowed) {
		return 0;
	}
	if (timedOut) {
		// Loud, but not fatal: one line per stall, and the counters show it.
		NSLog(@"perfectdark: pacing wait timed out (link stalled?)");
	}

	atomic_fetch_add(&_presents, 1);

	// The cadence instrument: how far apart consecutive presents actually are.
	// The average is the useless number here - a 120 Hz link over a 60 Hz
	// engine averaged a perfect 16.7 ms while alternating 8.3 and 25.0, which
	// is exactly what a player feels as judder and what an fps counter cannot
	// show. p95 and max against p50 are what say whether the cadence is even.
	{
		const double now = CACurrentMediaTime();
		if (_lastPresentAt > 0.0) {
			const double ms = (now - _lastPresentAt) * 1000.0;
			_hist[_histWrite % kHistN] = (float)ms;
			_histWrite++;
			if (_histN < kHistN) {
				_histN++;
			}
		}
		_lastPresentAt = now;
	}
	return 1;
}

static int pdCmpFloat(const void *a, const void *b)
{
	const float fa = *(const float *)a, fb = *(const float *)b;
	return (fa < fb) ? -1 : (fa > fb) ? 1 : 0;
}

- (void)fillSnapshot:(PDPacingSnap *)o
{
	o->measuredHz = _measuredHz;
	o->targetHz = (long)_targetHz;
	o->engineHz = (long)_engineTickHz;
	o->appliedLinkHz = (long)_appliedLinkHz;
	o->divisor = atomic_load(&_divisor);
	o->presentAllowed = (int)_presentAllowed;
	o->earlyWait = (int)_earlyWait;
	o->bypass = (int)_bypass;
	o->waitMode = atomic_load(&_waitMode);
	o->externalSource = atomic_load(&_external);
	o->externalSignals = atomic_load(&_externalSignals);
	{
		const unsigned long long n = atomic_load(&_wakeSamples);
		o->wakeSamples = n;
		o->wakeUsMean = n ? (double)atomic_load(&_wakeSumUs) / (double)n : 0.0;
		o->wakeUsMax = (double)atomic_load(&_wakeMaxUs);
	}
	o->links = atomic_load(&_links);
	o->presents = atomic_load(&_presents);
	o->dropped = atomic_load(&_dropped);
	o->waiting = atomic_load(&_waiting);
}

- (NSString *)report
{
	float sorted[kHistN];
	const uint32_t n = MIN(_histN, kHistN);
	memcpy(sorted, _hist, n * sizeof(float));
	qsort(sorted, n, sizeof(float), pdCmpFloat);
	const double p50 = n ? sorted[(n * 50) / 100] : 0.0;
	const double p95 = n ? sorted[MIN(n - 1, (n * 95) / 100)] : 0.0;
	const double pmax = n ? sorted[n - 1] : 0.0;
	// p95 is not enough on its own: a cadence that is right nine frames in ten
	// and a frame and a half late on the tenth reads as a clean p95 and feels
	// like judder. What the eye is answering to is how OFTEN an interval is not
	// the usual one, so that is counted directly - every interval more than a
	// quarter away from the median, as a percentage.
	int off = 0;
	for (uint32_t i = 0; i < n; i++) {
		if (sorted[i] < p50 * 0.75 || sorted[i] > p50 * 1.25) {
			off++;
		}
	}
	const double jitterPct = n ? (100.0 * off / (double)n) : 0.0;

	// The verdict in one word, so a gate can grep for it.
	NSString *cadence = (n < 60) ? @"nodata"
		: ((p95 - p50) <= (p50 * 0.5) && jitterPct <= 2.0 ? @"even" : @"UNEVEN");

	// The wake-latency instrument (D-045): signal-to-noticed, in microseconds,
	// for whichever wait mode is live. It is what says the run-loop wait is not
	// paying for its UIKit service with a late frame.
	float wsorted[kHistN];
	const uint32_t wn = MIN(_wakeN, kHistN);
	memcpy(wsorted, _wake, wn * sizeof(float));
	qsort(wsorted, wn, sizeof(float), pdCmpFloat);
	const double w50 = wn ? wsorted[(wn * 50) / 100] : 0.0;
	const double w95 = wn ? wsorted[MIN(wn - 1, (wn * 95) / 100)] : 0.0;
	const double wmax = wn ? wsorted[wn - 1] : 0.0;

	return [NSString stringWithFormat:
		@"pacing_mode=%@\npacing_links=%llu\npacing_presents=%llu\npacing_dropped=%llu\n"
		 "pacing_hz=%.1f\npacing_target=%ld\npacing_engine_hz=%ld\npacing_divisor=%d\n"
		 "pacing_link_hz=%ld\n"
		 "pacing_present_allowed=%d\n"
		 "frame_ms_n=%u\nframe_ms_p50=%.2f\nframe_ms_p95=%.2f\nframe_ms_max=%.2f\n"
		 "frame_ms_jitter_pct=%.2f\nframe_cadence=%@\n"
		 "pacing_wait_mode=%@\npacing_wake_n=%u\npacing_wake_us_p50=%.0f\n"
		 "pacing_wake_us_p95=%.0f\npacing_wake_us_max=%.0f\n"
		 "pacing_external_signals=%llu\n",
		_bypass ? @"bypass"
			: (atomic_load(&_external) ? @"compositor" : @"displaylink"),
		(unsigned long long)atomic_load(&_links),
		(unsigned long long)atomic_load(&_presents),
		(unsigned long long)atomic_load(&_dropped),
		_measuredHz, (long)_targetHz, (long)_engineTickHz, atomic_load(&_divisor),
		(long)_appliedLinkHz,
		(int)_presentAllowed,
		n, p50, p95, pmax, jitterPct, cadence,
		atomic_load(&_waitMode) == PDPacingWaitRunLoop ? @"runloop" : @"sem",
		wn, w50, w95, wmax,
		(unsigned long long)atomic_load(&_externalSignals)];
}

@end

int pdIosPacingWaitForPresent(void)
{
	return [PDPacing.shared waitForPresent];
}

int pdIosPresentAllowed(void)
{
	return PDPacing.shared.presentAllowed ? 1 : 0;
}

void pdPacingSnapshot(PDPacingSnap *out)
{
	if (!out) {
		return;
	}
	memset(out, 0, sizeof *out);
	[PDPacing.shared fillSnapshot:out];
}

void pdIosPacingWaitAtFrameStart(void)
{
	[PDPacing.shared waitAtFrameStart];
}

void pdPacingSignalExternal(void)
{
	[PDPacing.shared signalExternal];
}

void pdPacingSetExternalSource(int on)
{
	PDPacing.shared.externalSource = on ? YES : NO;
}
