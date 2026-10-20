// PDShell.m — shared shell state, the frame hook, and the game-thread queue.
//
// See PDShell.h for the two rules. This file is the only place that decides
// when a block written anywhere else in the shell actually runs against the
// engine.
#import "PDShell.h"
#if !TARGET_OS_VISION
#import "PDSceneDelegate.h"
#endif
#if TARGET_OS_VISION
#import "PDVision3D.h"
#endif

// app/gfx/gfx_angle_egl.mm — the SDL_MetalView the renderer draws into.
extern void *pdAngleGetHostView(void);
#import "PDVision.h"
#import "PDPacing.h"
#import "PDTouchOverlay.h"
#import "PDController.h"
#import "PDDefaults.h"
#import "PDXbla.h"
#import "PDAudio.h"
#import "PDSettingsViewController.h"
#import "PDWatchdog.h"
#import "PDGeometry.h"

#include <stdatomic.h>
#include <mach/mach.h>
#include <sys/utsname.h>

#include "build_stamp.h"

// A queued unit of work plus, when somebody is waiting for it, the semaphore to
// signal once it has run.
@interface PDShellWork : NSObject
@property (nonatomic, copy) dispatch_block_t block;
@property (nonatomic, nullable, strong) dispatch_semaphore_t done;
@end
@implementation PDShellWork
@end

@implementation PDShell {
	NSMutableArray<PDShellWork *> *_queue;
	NSMutableArray<NSURL *> *_deepLinks;
	NSLock *_lock;
	uint64_t _frames;
}

+ (instancetype)shared
{
	static PDShell *shared;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ shared = [PDShell new]; });
	return shared;
}

- (instancetype)init
{
	if ((self = [super init])) {
		_queue = [NSMutableArray array];
		_deepLinks = [NSMutableArray array];
		_lock = [NSLock new];
		NSArray *d = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
		NSArray *c = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
		_documentsPath = d.count ? d[0] : NSTemporaryDirectory();
		_cachesPath = c.count ? c[0] : NSTemporaryDirectory();
	}
	return self;
}

- (uint64_t)frameCount
{
	return _frames;
}

- (void)enqueue:(dispatch_block_t)block
{
	PDShellWork *w = [PDShellWork new];
	w.block = block;
	[_lock lock];
	[_queue addObject:w];
	[_lock unlock];
}

- (BOOL)enqueueAndWait:(dispatch_block_t)block timeout:(NSTimeInterval)timeout
{
	// Called from the game thread itself (a settings row, say) this would
	// deadlock waiting for a frame boundary it is standing on, so run it here.
	if ([NSThread isMainThread]) {
		block();
		return YES;
	}

	PDShellWork *w = [PDShellWork new];
	w.block = block;
	w.done = dispatch_semaphore_create(0);
	[_lock lock];
	[_queue addObject:w];
	[_lock unlock];

	return dispatch_semaphore_wait(w.done,
		dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))) == 0;
}

- (void)queueDeepLink:(NSURL *)url
{
	[_lock lock];
	[_deepLinks addObject:url];
	[_lock unlock];
	NSLog(@"perfectdark: deep link queued %@", url);
}

// ---------------------------------------------------------------------------

/**
 * perfectdark://stage/0x1d and friends.
 *
 * Consumed on the game thread, which is why a link that arrives while the app
 * is launching (the common case - iOS delivers it before the engine exists) is
 * queued rather than acted on: the frame hook is the first moment at which
 * mainChangeToStage() means anything.
 */
- (void)consumeDeepLink:(NSURL *)url
{
	NSString *host = url.host.lowercaseString ?: @"";
	NSArray<NSString *> *parts = url.pathComponents;
	NSString *arg = parts.count > 1 ? parts[1] : nil;

	if ([host isEqualToString:@"stage"] && arg.length) {
		int stage = (int)strtol(arg.UTF8String, NULL, 0);
		NSLog(@"perfectdark: deep link -> stage 0x%x", stage);
		mainChangeToStage(stage);
	} else if ([host isEqualToString:@"screenshot"]) {
		screenshotRequest();
	} else {
		NSLog(@"perfectdark: deep link not understood: %@", url);
	}
}

- (void)drainQueue
{
	NSArray<PDShellWork *> *work;
	NSArray<NSURL *> *links;

	[_lock lock];
	work = _queue.count ? [_queue copy] : nil;
	links = _deepLinks.count ? [_deepLinks copy] : nil;
	[_queue removeAllObjects];
	[_deepLinks removeAllObjects];
	[_lock unlock];

	for (NSURL *url in links) {
		[self consumeDeepLink:url];
	}

	for (PDShellWork *w in work) {
		w.block();
		if (w.done) {
			dispatch_semaphore_signal(w.done);
		}
	}
}

// ---------------------------------------------------------------------------

/** Real physical footprint, the number Jetsam actually judges. */
static double pdFootprintMB(void)
{
	task_vm_info_data_t info;
	mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
	if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
		return -1.0;
	}
	return (double)info.phys_footprint / (1024.0 * 1024.0);
}

static const char *pdThermalName(void)
{
	switch (NSProcessInfo.processInfo.thermalState) {
	case NSProcessInfoThermalStateNominal:  return "nominal";
	case NSProcessInfoThermalStateFair:     return "fair";
	case NSProcessInfoThermalStateSerious:  return "serious";
	case NSProcessInfoThermalStateCritical: return "critical";
	}
	return "?";
}

- (void)tickFrame
{
	_frames++;
}

// ---------------------------------------------------------------------------
// Is the MAIN RUN LOOP still turning, and in which mode? (D-043.)
//
// The touch failure this round chases leaves everything observable healthy -
// routing, windows, key window, the engine, the bridge - and delivers not one
// touch. The bridge answering is NOT evidence that the run loop is healthy:
// a dispatch_async(main) block arrives through the main-queue source, which
// CFRunLoopRunInMode services on its own, while a HID event needs the run loop
// to actually enter a mode and service a port-based SOURCE. Those are different
// things and nothing in this app could tell them apart.
//
// A CFRunLoopObserver on the main run loop can: it counts entries, source
// passes and waits, per mode. If the counters stop moving after the 120 -> 60
// transition, the run loop is the answer; if they keep moving in
// kCFRunLoopDefaultMode while touches never arrive, it is not, and that is
// worth knowing just as much.

static _Atomic uint64_t sRLEntry, sRLBeforeSources, sRLBeforeWaiting, sRLExit;
static char sRLLastMode[64];

static void pdRunLoopObserved(CFRunLoopObserverRef o, CFRunLoopActivity a, void *ctx)
{
	(void)o; (void)ctx;
	switch (a) {
	case kCFRunLoopEntry:         atomic_fetch_add(&sRLEntry, 1); break;
	case kCFRunLoopBeforeSources: atomic_fetch_add(&sRLBeforeSources, 1); break;
	case kCFRunLoopBeforeWaiting: atomic_fetch_add(&sRLBeforeWaiting, 1); break;
	case kCFRunLoopExit:          atomic_fetch_add(&sRLExit, 1); break;
	default: break;
	}
	CFStringRef mode = CFRunLoopCopyCurrentMode(CFRunLoopGetMain());
	if (mode) {
		CFStringGetCString(mode, sRLLastMode, sizeof sRLLastMode, kCFStringEncodingUTF8);
		CFRelease(mode);
	}
}

void pdInstallRunLoopObserver(void)
{
	static BOOL done = NO;
	if (done) {
		return;
	}
	done = YES;
	CFRunLoopObserverRef obs = CFRunLoopObserverCreate(kCFAllocatorDefault,
		kCFRunLoopEntry | kCFRunLoopBeforeSources | kCFRunLoopBeforeWaiting | kCFRunLoopExit,
		true, 0, pdRunLoopObserved, NULL);
	CFRunLoopAddObserver(CFRunLoopGetMain(), obs, kCFRunLoopCommonModes);
	NSLog(@"perfectdark: [runloop] observer installed on the main run loop");
}

NSString *pdRunLoopReport(void)
{
	return [NSString stringWithFormat:
		@"runloop_entries=%llu\nrunloop_sources=%llu\nrunloop_waits=%llu\n"
		 "runloop_exits=%llu\nrunloop_mode=%s\nrunloop_pump_ms=%d\n",
		(unsigned long long)atomic_load(&sRLEntry),
		(unsigned long long)atomic_load(&sRLBeforeSources),
		(unsigned long long)atomic_load(&sRLBeforeWaiting),
		(unsigned long long)atomic_load(&sRLExit),
		sRLLastMode[0] ? sRLLastMode : "-",
		pdExtraPumpMs];
}

/**
 * Milliseconds the frame hook spends running the main run loop in the DEFAULT
 * mode, on top of whatever SDL's own pump does. 0 = off (the shipping
 * behaviour). The bridge's `pump <ms>`: if giving the run loop a real turn
 * restores touch delivery on the broken instance, the answer is that SDL's
 * 2-microsecond pump is not enough once the frame is paced the way D-040 paces
 * it, and the fix is ours to make permanent.
 */
int pdExtraPumpMs = 0;

- (NSString *)stateReport
{
	int dw = 0, dh = 0;
	if (self.engineRunning) {
		pdAngleGetDrawableSize(&dw, &dh);
	}

	UIView *overlay = self.touchOverlay;
#if TARGET_OS_VISION
	// No UIScreen on visionOS: a window's size is the user's drag and its
	// points-to-pixels scale lives in the trait collection (2.0 on Vision Pro).
	// With no overlay yet, fall back to the first window of the first window
	// scene, which is SDL's.
	UIWindow *vwin = overlay.window;
	if (!vwin) {
		for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
			if ([sc isKindOfClass:UIWindowScene.class]) {
				vwin = ((UIWindowScene *)sc).windows.firstObject;
				if (vwin) {
					break;
				}
			}
		}
	}
	CGFloat scale = vwin ? vwin.traitCollection.displayScale : 2.0;
	CGSize pts = overlay ? overlay.bounds.size : (vwin ? vwin.bounds.size : CGSizeZero);
#else
	CGFloat scale = overlay ? overlay.window.screen.nativeScale : UIScreen.mainScreen.nativeScale;
	CGSize pts = overlay ? overlay.bounds.size : UIScreen.mainScreen.bounds.size;
#endif

	NSMutableString *s = [NSMutableString string];
	[s appendFormat:@"build=%s\n", PD_IOS_BUILD_STAMP];
	[s appendFormat:@"version=%s\n", PD_IOS_MARKETING_VERSION];
	[s appendFormat:@"engine=%@\n", self.engineRunning ? @"running" : @"starting"];
	[s appendFormat:@"frames=%llu\n", (unsigned long long)_frames];

	if (self.engineRunning) {
		[s appendFormat:@"stage=0x%x\n", mainGetStageNum()];
		[s appendFormat:@"fps=%.1f\n", videoGetAverageFPS()];
		[s appendFormat:@"xbla_available=%d\n", xblaImportIsAvailable()];
		[s appendFormat:@"xbla_enabled=%d\n", xblaSwitchGetEnabled()];
		[s appendFormat:@"xbla_state=%d\n", xblaImportGetState()];
		const char *st = xblaImportGetStatus();
		[s appendFormat:@"xbla_status=%s\n", st && *st ? st : "-"];
		[s appendFormat:@"texpack_enabled=%d\n", texpackLoadEnabled()];
		// The game's own three audio values, raw, so a validation run can assert
		// that a settings change reached the engine rather than inferring it
		// from a log line (D-031). 0x5000 is the top of the range.
		[s appendFormat:@"sfx_volume=%u\n", (unsigned)g_SfxVolume];
		[s appendFormat:@"music_volume=%u\n", (unsigned)optionsGetMusicVolume()];
		[s appendFormat:@"sound_mode=%d\n", g_SoundMode];
	}
	[s appendString:[PDXbla stateLines]];
	[s appendString:[PDAudio stateLines]];

	[s appendFormat:@"drawable=%dx%d\n", dw, dh];
	[s appendFormat:@"points=%.0fx%.0f\n", pts.width, pts.height];
	[s appendFormat:@"contents_scale=%.2f\n", (double)scale];
	[s appendFormat:@"expect_drawable=%.0fx%.0f\n", pts.width * scale, pts.height * scale];
	[s appendFormat:@"native_resolution=%@\n",
		(dw == (int)lround(pts.width * scale) && dh == (int)lround(pts.height * scale)) ? @"OK" : @"MISMATCH"];
	[s appendFormat:@"footprint_mb=%.1f\n", pdFootprintMB()];
	[s appendFormat:@"thermal=%s\n", pdThermalName()];
	[s appendFormat:@"touch_overlay=%@\n", overlay ? (overlay.hidden ? @"hidden" : @"visible") : @"none"];
	if ([overlay isKindOfClass:PDTouchOverlay.class]) {
		[s appendString:[(PDTouchOverlay *)overlay heldReport]];
	}
	// Which chip set is up, and therefore whether a tap is a menu pointer or a
	// gameplay button (overlay 0019). A scripted menu walk asserts on this
	// before it asserts on anything it tapped.
	[s appendFormat:@"menu_open=%d\n", self.engineRunning ? (menuIosDialogIsOpen() ? 1 : 0) : 0];
	if (self.engineRunning) {
		float px = 0, py = 0, pz = 0;
		if (playerIosGetPos(&px, &py, &pz)) {
			[s appendFormat:@"player_pos=%.1f,%.1f,%.1f\n", px, py, pz];
		} else {
			[s appendString:@"player_pos=none\n"];
		}
		// The AIM chip's whole claim, from the engine rather than from the
		// shell's own mask (D-046).
		[s appendFormat:@"player_aimmode=%d\n", playerIosGetAimMode()];
		// The two chips of D-085, from the engine.
		int gunfn = 0, amslot = 0;
		const int gun = playerIosGunState(&gunfn);
		const int amopen = playerIosActiveMenu(&amslot);
		[s appendFormat:@"player_gun=%d\nplayer_gunfunc=%d\nplayer_gunhas2nd=%d\n"
			@"player_ge_level=%d\nplayer_wheel=%d\nplayer_wheel_slot=%d\n",
			gun, gunfn, playerIosGunHasSecondary(), playerIosOnGoldenEyeLevel(), amopen, amslot];
	}
	[s appendString:[PDPacing.shared report]];
	// The 120 -> 60 bisect rows (D-044): what the ENGINE and the window layer
	// think the rate is, beside what the pacer thinks. `graft_enabled` is the
	// live D-038 switch.
	if (self.engineRunning) {
		[s appendFormat:@"tick_rate_div=%d\n", g_TickRateDiv];
		[s appendFormat:@"video_framerate_limit=%d\n", videoGetFramerateLimit()];
		[s appendFormat:@"video_vsync=%d\n", videoGetVsync()];
	}
	[s appendFormat:@"graft_enabled=%d\n", pdGraftEnabled];
	// Every link of the picture's size chain (D-077); empty on visionOS.
	[s appendString:pdGeoStateLines()];
#if TARGET_OS_VISION
	// The 3D mode's own rows (Phase 6): whether the space is open, whether the
	// compositor loop is alive, how many frames it has presented and at what
	// cadence. The gate asserts on imm_frames advancing (docs/visionos-3d-plan.md
	// §4 M1).
	[s appendString:pdVision3dStateLines()];
#endif
	return s;
}

@end

// ---------------------------------------------------------------------------
// D-038's graft, moved out of PDSceneDelegate in round V (D-047).
//
// It was never scene-delegate work. The scene callbacks were one of its two
// callers and the per-frame hook was the other, and on visionOS from now on
// there IS no PDSceneDelegate (SwiftUI owns the scenes), so the function lives
// here and the iOS class method forwards to it. Everything it does, and why it
// is load-bearing rather than insurance, is written down in PDSceneDelegate.m.
// ---------------------------------------------------------------------------

int pdGraftEnabled = 1;

static UIWindowScene *pdForegroundScene(void)
{
	UIWindowScene *any = nil;
	for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
		if (![sc isKindOfClass:UIWindowScene.class]) {
			continue;
		}
		if (sc.activationState == UISceneActivationStateForegroundActive) {
			return (UIWindowScene *)sc;
		}
		if (!any) {
			any = (UIWindowScene *)sc;
		}
	}
	return any;
}

int pdGraftSDLWindows(void)
{
	UIWindowScene *scene = pdForegroundScene();
	int moved = 0;

	if (!scene) {
		return 0;
	}
	// `graft off` (D-044), and never before the overlay exists: see PDShell.h.
	if (!pdGraftEnabled && PDTouchOverlay.current) {
		return 0;
	}
	// UIApplication.windows and scene.windows BOTH omit a window that has no
	// scene, so neither can be used to find the one window that needs this.
	// The renderer's own view is the handle that always works: ANGLE created
	// its surface from SDL's SDL_MetalView, so the view's -window is SDL's
	// UIWindow whether UIKit can enumerate it or not.
	UIView *host = (__bridge UIView *)pdAngleGetHostView();
	NSMutableArray<UIWindow *> *candidates = [NSMutableArray array];
	if (host.window) {
		[candidates addObject:host.window];
	}
	// The shell's own pre-engine windows (the onboarding screen, the "preparing"
	// note) are made before the scene connects on a cold launch - there is no
	// scene to give them yet - and a sceneless window is never drawn under the
	// UIScene life cycle: the first-launch onboarding was a black screen (D-073).
	// The scene's willConnect calls this, so they are grafted the moment it can be.
	UIWindow *overlay = PDShell.shared.overlayWindow;
	if (overlay && ![candidates containsObject:overlay]) {
		[candidates addObject:overlay];
	}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	for (UIWindow *w in UIApplication.sharedApplication.windows) {
		if (![candidates containsObject:w]) {
			[candidates addObject:w];
		}
	}
#pragma clang diagnostic pop

	for (UIWindow *w in candidates) {
		if (w.windowScene) {
			continue;
		}
		w.windowScene = scene;
		[w makeKeyAndVisible];
		moved++;
		PDLifecycle("GRAFT moved a sceneless window %.0fx%.0f onto a scene",
			w.bounds.size.width, w.bounds.size.height);
		NSLog(@"perfectdark: [scene] grafted a sceneless window %@ (root %@) onto %@",
			NSStringFromCGRect(w.bounds), NSStringFromClass(w.rootViewController.class),
			scene.session.persistentIdentifier);
	}
	return moved;
}

/**
 * The touch overlay cannot be installed at launch: SDL creates its UIWindow
 * inside videoInit(), which is inside the engine. The first frame hook is the
 * first moment there is a window to put it over, so that is when it happens -
 * once, and on the main thread, which is where this runs.
 */
static void pdInstallOverlayOnce(void)
{
	static BOOL done = NO;
	if (done) {
		return;
	}

	UIWindow *win = nil;
#if TARGET_OS_VISION
	// visionOS only, and it has to come FIRST here (D-047). Under the SwiftUI
	// entry there are TWO normal-level windows on the scene - SwiftUI's own
	// WindowGroup window, which hosts PDHostViewController and the ornament,
	// and SDL's, grafted on top - and the scene enumeration below would find
	// SwiftUI's first and install the touch overlay in the wrong one. SDL's
	// window is not ambiguous when it is asked for by name: ANGLE built its
	// surface from SDL's SDL_MetalView, so that view's -window is SDL's.
	// (On iOS SDL's is the only normal-level window there has ever been, and
	// this whole branch is compiled out.)
	pdGraftSDLWindows();
	win = ((__bridge UIView *)pdAngleGetHostView()).window;
	if (!win) {
		return;   // SDL has not built its window yet; try again next frame
	}
#endif
	for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
		if (win) {
			break;
		}
		if (![scene isKindOfClass:UIWindowScene.class]) {
			continue;
		}
		for (UIWindow *w in ((UIWindowScene *)scene).windows) {
			if (w.windowLevel == UIWindowLevelNormal) {
				win = w;
				break;
			}
		}
	}
	if (!win) {
		// SDL 2.32.8 builds its window the pre-scene way - it has no idea
		// scenes exist - so the window can be found here and not under a
		// scene. It normally IS under one anyway, because UIKit attaches a
		// window created with -initWithFrame: to the single foreground scene;
		// the graft below is the insurance for the case where it does not,
		// which matters now that the app declares a scene manifest (D-038).
		if (pdGraftSDLWindows() > 0) {
			// It has a scene now: go round again and find it properly.
			return;
		}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
		win = UIApplication.sharedApplication.windows.firstObject;
#pragma clang diagnostic pop
		if (!win) {
			// Neither enumeration can see a sceneless window (D-038). The
			// renderer's own view can.
			win = ((__bridge UIView *)pdAngleGetHostView()).window;
		}
	}
	if (!win) {
		return;   // try again next frame
	}

	done = YES;
	NSLog(@"perfectdark: [touch] SDL window %@ scene=%@ root=%@",
		NSStringFromCGRect(win.bounds), win.windowScene ? @"yes" : @"NO",
		NSStringFromClass(win.rootViewController.class));
	[PDTouchOverlay installInWindow:win];
	// visionOS: without this the pad's buttons become gaze-pinch events and the
	// game never sees them (a no-op on iOS). PDController.m explains.
	[PDController claimGamepadEventsInWindow:win];

	// The settings the player last chose, into the engine, now that there is an
	// engine to put them into - except in a replay, where the ini is the truth.
	// (Our Enhance Textures default is 2x and upstream's is OFF, so applying it
	// here would change what a determinism run draws: measured as a diverging
	// `tex uploads` line against the oracle before this guard existed.)
	if (!PDShell.shared.replayRun) {
		PDDefaultsApplyToEngine();
	} else {
		NSLog(@"perfectdark: replay run — settings NOT applied, pd.ini is the truth");
	}
}

void pdIosFrameHook(void)
{
	PDShell *shell = PDShell.shared;
	@autoreleasepool {
		pdInstallRunLoopObserver();
		pdInstallOverlayOnce();
		// The one-time XBLA unpack, off the game thread. Idempotent and cheap
		// when there is nothing to do: after the first call it is one static
		// BOOL, and until then it is a directory scan once a frame for the few
		// frames before the engine is marked running.
		[PDXbla beginUnpackIfNeeded];
		[shell drainQueue];
		// Nothing audio-shaped happens here any more. Two earlier rounds put
		// something in this spot: a 600-frame re-assert of the three eeprom
		// volumes, then the engine callback that replaced it (D-031, overlay
		// 0022). Both existed to defend settings-page rows that mirrored the
		// game's own Audio Options page, and round B removed the rows - the
		// game owns those three values outright now (D-033).
#if TARGET_OS_VISION
		// The 3D mode's per-frame main-thread work: the graft retry (there is
		// no scene delegate on visionOS to do it) and PD_VP3D_AUTOENTER.
		// Deliberately here, not on a queue: this IS the main thread, and the
		// engine's loop never returns, so "later" has no other meaning.
		pdVision3dFramePoll();
#endif
		[PDController.shared tick];
		[PDTouchOverlay publishInput];
		// The picture's size chain (D-077): logged on change, and on an iPhone
		// a portrait-shaped game window is put back before this frame draws.
		pdGeoFrame();
		// The settings page, built once, a few seconds in (BUG 4 / D-041). It
		// used to be built by the first gear tap, on this thread, in that
		// frame: forty-odd cells with their switches, segmented controls and
		// SF Symbols, which is the hitch the user feels the first time he opens
		// it. Here it lands in a frame nobody is waiting on, and because the
		// page now outlives a dismiss it is the only time it is ever paid.
		if (shell.engineRunning && shell.frameCount == 600) {
			[PDSettingsViewController prewarm];
		}
	}
	// Counted after the drain, so a `state` read from a queued block reports
	// the frame it is running in rather than the one before it.
	[shell tickFrame];
	// ...and the heartbeat's "the frame hook ran" stamp, plus the UIKit-side
	// snapshot the watchdog thread is not allowed to take for itself (D-044).
	PDWatchdogNoteFrame(shell.frameCount);
	if (pdExtraPumpMs > 0) {
		@autoreleasepool {
			[NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode
			                    beforeDate:[NSDate dateWithTimeIntervalSinceNow:pdExtraPumpMs / 1000.0]];
		}
	}
}
