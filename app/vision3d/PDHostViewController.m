// PDHostViewController.m — boots the engine under the SwiftUI entry, and owns
// the 2D <-> 3D transition sequencing (visionOS only).
//
// Read PDVision3D.h first: it says why the entry point is SwiftUI and why the
// boot goes through a run-loop timer rather than the main dispatch queue.
//
// THE STRUCTURAL FACT THIS FILE IS SHAPED BY: pdSDLMain() never returns.
// Upstream's main ends in the game loop (overlay 0010's pdEngineMain), so the
// thread that calls it — the MAIN thread — is inside the game loop for the life
// of the process. Two consequences:
//
//   * nothing can be scheduled "after the engine starts" from here; post-boot
//     work goes in pdVision3dFramePoll(), which the engine's own frame hook
//     calls on this same thread (PDShell.h rule 2);
//   * the main run loop keeps turning anyway, because this port's pacer waits
//     by running it (D-045) rather than by sleeping. That is what keeps SwiftUI
//     alive with the engine on the main thread — a strictly better position
//     than sm64coopdx's, which relies on SDL's microsecond pump. Do not
//     "optimise" the pacer's wait back into a semaphore on visionOS.
#import "PDVision3D.h"

#if TARGET_OS_VISION

#import "PDShell.h"
#import "PDTouchOverlay.h"
#import "PDWatchdog.h"
#import "PDAudio.h"

#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// SDL2 is statically linked and this file has no SDL header search path; the
// declaration is the whole of what is needed. SDL_SetMainReady() tells SDL that
// main() has already run, which on visionOS is true in spirit and false in
// fact: there is no main() in this build at all (pd_ios_main.m's is
// #if !TARGET_OS_VISION).
extern void SDL_SetMainReady(void);

// app/gfx/gfx_angle_egl.mm — the GL side of the transition (surfaceless in 3D,
// eye ring wrapped, window surface re-bound first on the way out).
extern int pdAngleSet3DActive(int on);
// The drawable is recomputed from the layer's bounds x contentsScale. The exit
// needs it explicitly: the scene came back to 1280x720 while the context was
// surfaceless, so nothing had asked the layer how big it is since.
extern void pdAngleResyncWindowDrawable(void);
extern void *pdAngleGetHostView(void);
// pd_ios_main.m — inputSaveBinds() + configSave(). A Crown exit is often the
// first half of a swipe-kill, and a swipe-kill is SIGKILL.
extern void pdIosSaveConfigNow(void);
// The engine's own inventory, for PD_VP3D_GIVE_AT below — the same two calls
// the bridge's `give` makes (PDBridge.m:488), on the same thread.
extern int invGiveSingleWeapon(int weaponnum);
extern void bgunEquipWeapon(int weaponnum);

static BOOL pdVisionBooted = NO;
static int pdVision3dOn = 0;
// -1 = nothing pending, 0/1 = a mode the frame hook must still apply.
static int pdVision3dPending = -1;

// ---------------------------------------------------------------------------
// The parked window and the curtain (PDVision3D.h §M4)
// ---------------------------------------------------------------------------

// The pre-3D scene size, captured on the way in as an EXPLICIT state and never
// re-derived from the window: while parked the window IS 480 pt, so a heuristic
// that asks "is this the small size?" answers the same in both states, and the
// restore then restores the card (sm64's own note; plan §2.9).
static CGSize pdPreParkSize = (CGSize){0, 0};
static int pdParked = 0;
static int pdCurtain = 0;
static int pdParkCycles = 0;
static int pdParkArmed = 0;        // a +1.5 s park timer is pending
static UIView *pdCurtainView = nil;
static volatile int pdVision3dSaveAsked = 0;
// Frames left over which the frame hook keeps re-measuring the window drawable
// after an exit (the window's layout can lag the scene's geometry).
static int pdVision3dResyncFrames = 0;

static UIWindow *pdVisionSDLWindow(void)
{
	// The renderer's own view is the handle that always works, exactly as the
	// graft uses it: ANGLE made its surface from SDL_MetalView, so the view's
	// -window is SDL's UIWindow whether UIKit can enumerate it or not.
	UIView *host = (__bridge UIView *)pdAngleGetHostView();
	if (host.window) {
		return host.window;
	}
	PDTouchOverlay *ov = PDTouchOverlay.current;
	return ov.window;
}

/**
 * WEAR THE SYSTEM'S ROUNDED CORNERS (dev2; sm64_vision_host.m :160-203).
 *
 * The user, device round 1: "the parked 2d window doesn't have rounded corners
 * when you enter 3d. then when you exit 3d, the resulting 2d window where you
 * can keep playing, it doesn't have rounded corners anymore either."
 *
 * visionOS rounds windows PER WINDOW, and only windows it manages. SDL2
 * predates scenes entirely, so its UIWindow is born sceneless and is ADOPTED
 * into the scene by pdGraftSDLWindows() (D-038) as a SECONDARY window — which
 * the system does not round. It then gets stretched, opaque and Metal-backed,
 * across the full scene bounds including the corners the primary has rounded,
 * and the curtain (a plain black subview of that window, dev2's own addition)
 * squares them harder still. The 480-pt card is where it is impossible to miss
 * because the radius is the same and the card is a ninth of the area.
 *
 * So the radius is READ FROM the primary window and worn, rather than
 * hard-coded: a resize, or an OS that varies the radius with window size, is
 * followed for free. The fallback is for a system that rounds by a mechanism
 * this process cannot read at all — a stand-in is closer than nothing.
 *
 * Main thread. Idempotent and cheap: it walks one scene's windows and assigns
 * two layer properties only when they differ.
 */
#define PD_WIN_CORNER_FALLBACK 46.0

static void pdVisionMirrorWindowCorners(void)
{
	UIWindow *win = pdVisionSDLWindow();
	UIWindowScene *scene = win.windowScene;
	if (!win || !scene) {
		return;
	}
	UIWindow *primary = nil;
	for (UIWindow *w in scene.windows) {
		if (w == win) { continue; }
		primary = w;
		if (w.isKeyWindow) { break; }
	}
	// ONE-SHOT INVENTORY, in the same build as the fix (sm64's own note). It
	// says which branch below is live and why: on the simulator the answer is
	// "primary absent — fallback", and the device session needs to be able to
	// read whether that is also true in the headset or whether a real radius
	// was found there.
	static int inventoried;
	if (!inventoried) {
		inventoried = 1;
		for (UIWindow *w in scene.windows) {
			NSLog(@"perfectdark: [3d] window %s %@ level=%.0f frame=%@ radius=%.1f"
			       " masks=%d", (w == win) ? "[SDL]" : "[other]",
				NSStringFromClass(w.class), (double)w.windowLevel,
				NSStringFromCGRect(w.frame), (double)w.layer.cornerRadius,
				(int)w.layer.masksToBounds);
		}
	}
	CGFloat r = primary ? primary.layer.cornerRadius : 0.0;
	CALayerCornerCurve curve = primary ? primary.layer.cornerCurve : kCACornerCurveContinuous;
	int readFromPrimary = (r > 0.0);
	if (!readFromPrimary) {
		r = PD_WIN_CORNER_FALLBACK;
		curve = kCACornerCurveContinuous;
	}
	if (win.layer.cornerRadius == r && win.layer.masksToBounds) {
		return;
	}
	win.layer.cornerRadius = r;
	win.layer.cornerCurve = curve;
	// masksToBounds is the half that does the work: a radius on its own rounds
	// the layer's OWN background and clips nothing, so the Metal sublayer and
	// the curtain would keep painting square corners over it.
	win.layer.masksToBounds = YES;
	NSLog(@"perfectdark: [3d] window corners radius=%.1f curve=%@ (primary %s)"
	       " window=%@", (double)r, curve,
		readFromPrimary ? "read" : "absent - fallback",
		NSStringFromCGRect(win.bounds));
}

void pdVision3dMirrorWindowCorners(void)
{
	if (NSThread.isMainThread) {
		pdVisionMirrorWindowCorners();
		return;
	}
	dispatch_async(dispatch_get_main_queue(), ^{ pdVisionMirrorWindowCorners(); });
}

CGFloat pdVision3dWindowCornerRadius(void)
{
	return pdVisionSDLWindow().layer.cornerRadius;
}

/**
 * The curtain. Black, with words on it, over SDL's window.
 *
 * Not an alpha fade and not a hidden window: the SDL window has to keep its
 * scene (losing the only regular scene kills audio) and it has to keep
 * laying out (the overlay lives in it), so the frame it last drew is covered
 * rather than removed. The label is what makes a room screenshot readable as
 * "the card is the curtain" rather than "the card went black, why".
 */
static void pdVisionCurtain(int up)
{
	UIWindow *win = pdVisionSDLWindow();
	if (!win) {
		NSLog(@"perfectdark: [3d] curtain %d: no SDL window yet", up);
		return;
	}
	if (up) {
		if (!pdCurtainView) {
			UIView *v = [[UIView alloc] initWithFrame:win.bounds];
			v.backgroundColor = UIColor.blackColor;
			v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
			UILabel *l = [[UILabel alloc] initWithFrame:v.bounds];
			l.autoresizingMask = v.autoresizingMask;
			l.textAlignment = NSTextAlignmentCenter;
			l.textColor = [UIColor colorWithWhite:1.0 alpha:0.75];
			l.font = [UIFont systemFontOfSize:22 weight:UIFontWeightMedium];
			l.text = @"Playing in 3D";
			[v addSubview:l];
			pdCurtainView = v;
		}
		pdCurtainView.frame = win.bounds;
		[win addSubview:pdCurtainView];
		// The touch layer stays ON TOP of the curtain and keeps working: a
		// pinch in the left half of the card is still the floating stick when
		// no pad is paired, which is the only input a pinch user has in 3D.
		PDTouchOverlay *ov = PDTouchOverlay.current;
		if (ov.superview == win) {
			[win bringSubviewToFront:ov];
		}
		pdCurtain = 1;
		// The curtain is a full-bleed opaque subview: without the window's own
		// corner mask it paints the corners square (dev2).
		pdVisionMirrorWindowCorners();
		// The charter's evidence rule: a UIKit placement is proven by the view
		// logging its own frame.
		NSLog(@"perfectdark: [3d] curtain UP frame=%@ window=%@",
			NSStringFromCGRect(pdCurtainView.frame), NSStringFromCGRect(win.bounds));
	} else {
		[pdCurtainView removeFromSuperview];
		pdCurtain = 0;
		pdVisionMirrorWindowCorners();
		NSLog(@"perfectdark: [3d] curtain DOWN (window %@)", NSStringFromCGRect(win.bounds));
	}
}

/** The scene the SDL window is grafted onto, or nil. */
static UIWindowScene *pdVisionScene(void)
{
	UIWindow *win = pdVisionSDLWindow();
	if (win.windowScene) {
		return win.windowScene;
	}
	for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
		if ([sc isKindOfClass:UIWindowScene.class]
				&& sc.activationState != UISceneActivationStateUnattached) {
			return (UIWindowScene *)sc;
		}
	}
	return nil;
}

/**
 * Park (shrink the scene to a card) or un-park (restore the captured size).
 *
 * Main thread. The request is asynchronous and the system may refuse it, so the
 * flag is set from the ERROR HANDLER's absence rather than optimistically: on a
 * refusal the row goes back to 0 and the log says why, which is the difference
 * between "the card is 480 pt" and "we asked for 480 pt".
 */
static void pdVisionParkWindow(int park)
{
	UIWindowScene *scene = pdVisionScene();
	if (!scene) {
		NSLog(@"perfectdark: [3d] park %d: no window scene", park);
		return;
	}
	CGSize want;
	if (park) {
		if (pdPreParkSize.width < 1 || pdPreParkSize.height < 1) {
			NSLog(@"perfectdark: [3d] park refused — no pre-3D size was captured");
			return;
		}
		// 480 pt at the PRE-3D aspect, which is the panel's aspect: the panel
		// quad is sized from the eye, and the eye is the pre-3D window.
		const CGFloat aspect = pdPreParkSize.width / pdPreParkSize.height;
		want = CGSizeMake(480.0, floor(480.0 / aspect));
	} else {
		if (pdPreParkSize.width < 1) {
			return;
		}
		want = pdPreParkSize;
	}
	UIWindowSceneGeometryPreferencesVision *prefs =
		[[UIWindowSceneGeometryPreferencesVision alloc] initWithSize:want];
	NSLog(@"perfectdark: [3d] %s -> requesting %.0fx%.0f pt (was %@)",
		park ? "PARK" : "UN-PARK", want.width, want.height,
		NSStringFromCGSize(scene.effectiveGeometry.coordinateSpace.bounds.size));
	// The card and the restored window both wear the system's corners, and the
	// radius is re-read AFTER the geometry has landed (it may vary with size).
	pdVisionMirrorWindowCorners();
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
		dispatch_get_main_queue(), ^{ pdVisionMirrorWindowCorners(); });
	const int wasParked = pdParked;
	[scene requestGeometryUpdateWithPreferences:prefs errorHandler:^(NSError *err) {
		NSLog(@"perfectdark: [3d] geometry request REFUSED: %@", err.localizedDescription);
		pdParked = park ? 0 : 1;
	}];
	pdParked = park ? 1 : 0;
	// A CYCLE is a park that was undone: that is the sequence the LUS ports
	// shipped broken (playbook §2.12 item 2), and counting un-parks alone would
	// count an exit from a session that never parked at all.
	if (!park && wasParked) {
		pdParkCycles++;
	}
}

static void pdVisionParkFire(void)
{
	pdParkArmed = 0;
	if (!pdVision3dOn) {
		NSLog(@"perfectdark: [3d] the +1.5 s park fired after the exit — ignoring");
		return;
	}
	pdVisionParkWindow(1);
}

void pdVision3dSpaceOpened(void)
{
	// ~1.5 s AFTER the space finished opening, never during the transition: a
	// geometry request mid-transition wedges a sibling animation (sm64/q2repro
	// both landed on the same delay). A run-loop timer, like the boot, because
	// this port's pacer runs the main run loop while it waits (D-045).
	if (pdParkArmed || pdParked) {
		return;
	}
	pdParkArmed = 1;
	NSLog(@"perfectdark: [3d] space opened — parking the 2D window in 1.5 s");
	[NSTimer scheduledTimerWithTimeInterval:1.5 repeats:NO block:^(NSTimer *t) {
		(void)t;
		pdVisionParkFire();
	}];
}

void pdVision3dParkRequest(int park)
{
	if (NSThread.isMainThread) {
		park ? pdVisionParkWindow(1) : pdVisionParkWindow(0);
		return;
	}
	dispatch_async(dispatch_get_main_queue(), ^{ pdVisionParkWindow(park); });
}

int pdVision3dWindowParked(void) { return pdParked; }
int pdVision3dCurtainUp(void)    { return pdCurtain; }
int pdVision3dParkCycles(void)   { return pdParkCycles; }

// ---------------------------------------------------------------------------
// Mode switching
// ---------------------------------------------------------------------------

int pdVision3dActive(void)
{
	return pdVision3dOn;
}

/**
 * WHY THIS IS A REQUEST AND NOT THE TRANSITION ITSELF (M2).
 *
 * The transition now includes GL work: eglMakeCurrent to a surfaceless context
 * and the eye ring's allocation. That work is only legal on the game thread,
 * which owns the EGL context — and it must not land in the MIDDLE of a frame.
 * Both callers would break that rule:
 *
 *   * the bridge posts to the main QUEUE, which this port drains from inside
 *     the pacer's wait (D-045). That wait sits between gfx_run's last draw and
 *     the present, so a switch there would take the surface away after the eye
 *     was drawn and before it was published — one lost frame per transition,
 *     and a genuinely confusing one to read in a log;
 *   * the SwiftUI ornament runs on the main thread at whatever moment the user
 *     pinches.
 *
 * So both only ask, and pdVision3dFramePoll() — which the engine calls from
 * schedEndFrame, after the frame is finished and before the next one starts —
 * performs it. One thread, one point in the frame, no locks.
 */
void pdVision3dSetMode(bool on)
{
	if (!pdVisionBooted) {
		NSLog(@"perfectdark: [3d] setMode(%d) ignored — the engine has not booted", (int)on);
		return;
	}
	if (on == (bool)pdVision3dOn) {
		return;
	}
	pdVision3dPending = on ? 1 : 0;
	NSLog(@"perfectdark: [3d] mode %d requested — applying at the next frame boundary", (int)on);
}

// Game thread, at the frame boundary. The only place the mode actually changes.
static void pdVision3dApplyMode(int on)
{
	if (on == pdVision3dOn) {
		return;
	}

	if (on) {
		PDLifecycle("3D ENTER requested");
		// The pre-3D size, captured FIRST and as an explicit state (plan §2.9).
		UIWindowScene *scene = pdVisionScene();
		CGSize pre = scene ? scene.effectiveGeometry.coordinateSpace.bounds.size
		                   : pdVisionSDLWindow().bounds.size;
		if (pre.width >= 1 && pre.height >= 1) {
			pdPreParkSize = pre;
		}
		NSLog(@"perfectdark: [3d] pre-3D scene size captured: %@",
			NSStringFromCGSize(pdPreParkSize));
		// ALL 3D SETTINGS, BEFORE ANYTHING MOVES (plan §2.9, M6). The panel's
		// geometry could be applied later, but the eye's SIZE cannot: Render
		// Resolution is read by pdVisionEyeActivate() through pdEyeWantedSize(),
		// and applying it after the ring is wrapped would mean entering 3D at
		// the wrong resolution and re-wrapping a frame later — a visible hitch
		// on every entry, for nothing.
		pdVision3dApplySettings();
		// ...and the eye is sized from the panel those settings just set (D-058).
		pdVision3dCommitGeometry();
		// ENGINE OFFSCREEN FIRST, then the space. The order is load-bearing:
		// once the window is parked (M4) a drawable requested against it never
		// comes back, which is a hang rather than a glitch — so the context is
		// surfaceless BEFORE anything else moves, and from here on framebuffer
		// 0 is the eye (patch 0031).
		if (!pdAngleSet3DActive(1)) {
			NSLog(@"perfectdark: [3d] ENTER ABORTED — the eye targets did not come up");
			return;
		}
		// CURTAIN BEFORE THE SPACE: from this instant the window's last drawn
		// frame is stale, and it must not be the thing the player sees sitting
		// a metre in front of the panel.
		pdVisionCurtain(1);
		pdVision3dOn = 1;
		PD_SetImmersiveMode(true);
		// Head-tracked spatial audio while the picture is world-locked; the
		// re-apply every ~3 s is PDAudio's own (SDL drops it silently).
		[PDAudio setImmersive:YES];
		NSLog(@"perfectdark: [3d] entry committed (the engine is drawing into the eye)");
	} else {
		PDLifecycle("3D EXIT requested");
		// THE SHEET GOES FIRST, AND THAT IS AN ORDERING RULE, NOT TIDINESS
		// (M6). The un-park below must be issued BEFORE dismissImmersiveSpace
		// — q2repro's device-only "stuck tiny window" — and a geometry request
		// made while a modal the system is also dismantling is on screen is
		// exactly the kind of request that gets dropped. So the sheet is closed
		// and WAITED FOR here, at the top of the exit, where the only thing
		// that has happened yet is that somebody asked to leave 3D. Written
		// this way round, the bad interleaving cannot occur: there is no path
		// to the un-park that does not pass through this line.
		pdVision3dSettingsSheetCloseAndWait();
		// Stop the loop and WAIT for it before the space is torn down: it must
		// never touch a layer renderer SwiftUI is dismantling, and it must not
		// be sampling an eye texture we are about to free.
		pdVision3dImmStop = 1;
		int waited = 0;
		for (; waited < 200 && pdVision3dImmRunning; waited++) {
			usleep(10 * 1000);
		}
		NSLog(@"perfectdark: [3d] loop stopped=%d after %d ms (frames=%d)",
			!pdVision3dImmRunning, waited * 10, pdVision3dImmFrames);
		pdVision3dOn = 0;
		// UN-PARK BEFORE THE DISMISSAL, never after. q2repro issued it after
		// and the request raced the space's transition and was DROPPED on
		// device — the "stuck tiny window" nobody could reproduce on the
		// simulator, whose transitions are too fast to lose the race.
		pdVisionParkWindow(0);
		PD_SetImmersiveMode(false);
		// Window surface back FIRST, ring freed second — that order is inside
		// pdAngleSet3DActive, and it is q2repro's "frozen 2D window" bug.
		pdAngleSet3DActive(0);
		[PDAudio setImmersive:NO];
		// WAIT FOR THE SCENE TO COME BACK, BY PUMPING THE RUN LOOP.
		//
		// The un-park is an asynchronous request UIKit services ON THIS THREAD,
		// which is the main thread — so the first version of this, a 600 ms
		// usleep, guaranteed the thing it was waiting for could not happen: the
		// measured result was a curtain dropped over a window still 480 pt wide
		// and a drawable re-synced to 960x540. Pumping is also how this port's
		// pacer waits (D-045), so it is the established idiom here and not a
		// new one.
		const CGSize want = pdPreParkSize;
		int pumped = 0;
		for (; pumped < 60; pumped++) {     // up to ~3 s
			CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
			CGSize now = pdVisionScene().effectiveGeometry.coordinateSpace.bounds.size;
			if (fabs(now.width - want.width) < 1.0 && fabs(now.height - want.height) < 1.0) {
				break;
			}
		}
		NSLog(@"perfectdark: [3d] the scene came back to %@ after %d ms of pumping",
			NSStringFromCGSize(pdVisionScene().effectiveGeometry.coordinateSpace.bounds.size),
			pumped * 50);
		// Now ask the layer how big it is again. Nothing has, since the
		// context went surfaceless: gfx_start_frame's get_dimensions was
		// answering with the EYE's size for the whole session (the override in
		// pdAngleGetDrawableSize), so without this the first 2D frame draws at
		// the eye's size into a window-sized drawable.
		pdAngleResyncWindowDrawable();
		// ...and again shortly after, because the window's own layout can lag
		// the scene's geometry by a frame or two and this is idempotent. SDL's
		// own size-changed event does the same job when it fires; this is the
		// insurance for when it does not.
		pdVision3dResyncFrames = 120;
		// The curtain comes down LAST, after the window has a correct drawable
		// again — its whole purpose is to cover the frames that are wrong.
		pdVisionCurtain(0);
		PDTouchOverlay *ov = PDTouchOverlay.current;
		[ov reassertTouchability];
		NSLog(@"perfectdark: [3d] exit finalized (parked=%d curtain=%d cycles=%d)",
			pdParked, pdCurtain, pdParkCycles);
	}
}

// A Crown or system dismissal: the loop saw the layer invalidated and has
// already exited. Reconcile the shell and SwiftUI so the next `3d on` is not
// refused as a no-op.
void pdVision3dImmersiveEnded(void)
{
	NSLog(@"perfectdark: [3d] immersive space ended by the system (Crown)");
	// A request, like every other mode change: the GL half of the exit has to
	// run on the game thread at a frame boundary, and this is called from the
	// immersive thread.
	pdVision3dPending = 0;
	// AND SAVE. A Crown exit is very often the first half of a swipe-kill, and
	// a swipe-kill is SIGKILL: nothing runs after it, so the write has to have
	// happened before. configSave() is the engine's and belongs on the game
	// thread, so the frame poll does it — one frame from now, not seconds.
	pdVision3dSaveAsked = 1;
}

// ---------------------------------------------------------------------------
// The per-frame hook's visionOS half
// ---------------------------------------------------------------------------

void pdVision3dFramePoll(void)
{
	PDShell *shell = PDShell.shared;
	const uint64_t frame = shell.frameCount;

	// The graft, retried while SDL's window is still sceneless. On iOS the
	// scene delegate's own callbacks do this; there is no scene delegate here
	// (D-047), so the frame hook is the only caller. Every 30 frames rather
	// than every frame: it walks connectedScenes and the deprecated windows
	// array, and the answer does not change within half a second.
	static int graftedOnce = 0;
	if (!graftedOnce && (frame % 30) == 0) {
		if (pdGraftSDLWindows() > 0) {
			graftedOnce = 1;
		}
	}

	// The corner mask, re-asserted on the same half-second cadence (dev2). The
	// graft can adopt the window at any time and UIKit re-lays it out on every
	// geometry change, so this is a poll rather than a one-shot — it is two
	// layer property reads when nothing has changed.
	if ((frame % 30) == 15) {
		pdVision3dMirrorWindowCorners();
	}

	// PD_VP3D_AUTOENTER=1 — enter 3D at frame 300. The ornament's "3D" button
	// needs a gaze-pinch, and simctl cannot inject one, so a scripted gate has
	// no other way in. Absent, this does nothing at all, so it cannot change a
	// shipped build's behaviour.
	static int autoEnter = -1;
	if (autoEnter < 0) {
		const char *e = getenv("PD_VP3D_AUTOENTER");
		autoEnter = (e && *e && *e != '0') ? 1 : 0;
		if (autoEnter) {
			NSLog(@"perfectdark: [3d] PD_VP3D_AUTOENTER=1 — will enter 3D at frame 300");
		}
	}
	if (autoEnter == 1 && frame == 300) {
		NSLog(@"perfectdark: [3d] autoenter at frame 300");
		pdVision3dSetMode(true);
	}

	// PD_VP3D_PAUSE_AT=N — hide the touch layer at N-5, press Start at N, and
	// release it 120 frames later.
	//
	// Written to make a HUD/menu-bearing frame deterministically (a bridge
	// command lands at a wall-clock moment, so in a --fixed-step replay it
	// lands on a different frame in the eye-L run and the eye-R run and the two
	// captures are not comparable; a frame number is the same in both). It does
	// not get all the way there: PD does not open its pause dialog in a
	// --fixed-step run however long Start is held — see the log at N+150 — so
	// the pause-menu crop-diff is taken LIVE instead, through `3d showeye`,
	// where the open dialog freezes the game and two captures seconds apart are
	// comparable frame-for-frame. What this instrument did earn is the trap
	// below it (a visible touch layer erases an injected pad button every
	// frame), and it stays as the deterministic way to feed a button to a
	// scripted run. Like PD_VP3D_AUTOENTER, absent it does nothing at all.
	static int pauseAt = -2;
	if (pauseAt == -2) {
		const char *e = getenv("PD_VP3D_PAUSE_AT");
		pauseAt = (e && *e) ? atoi(e) : -1;
		if (pauseAt > 0) {
			NSLog(@"perfectdark: [3d] PD_VP3D_PAUSE_AT=%d — Start at that frame", pauseAt);
		}
	}
	if (pauseAt > 0) {
		if ((int)frame == pauseAt - 5) {
			// HIDE THE TOUCH LAYER FIRST, or the press never reaches the menu.
			// PDTouchOverlay's -publishInput calls inputIosPadSet() once a
			// frame with the WHOLE mask, so a visible layer overwrites an
			// injected button bit on the very next frame; a hidden one returns
			// before it does. This is why the iOS gate says `touch auto`
			// before `pad start` (sim-validate.sh:432) and why four seconds of
			// a held Start read menu_open=0 while the engine's own mask
			// carried 0x1000.
			PDTouchOverlay.current.hidden = YES;
			NSLog(@"perfectdark: [3d] touch layer hidden for the scripted Start");
		} else if ((int)frame == pauseAt) {
			inputIosPadSetButton(PDPadStart, 1);
			NSLog(@"perfectdark: [3d] Start DOWN at frame %d", pauseAt);
		} else if ((int)frame == pauseAt + 120) {
			// FIFTEEN frames of hold, not one. A --fixed-step replay runs its
			// frames as fast as the machine will go (all of 1400 -> 1401 took
			// 9 ms here), and one frame of a held button at that rate does not
			// reach PD's menu: measured, menu_open stayed 0. The live session
			// holds it for a second and the dialog opens on the first press.
			inputIosPadSetButton(PDPadStart, 0);
			NSLog(@"perfectdark: [3d] Start UP at frame %d", pauseAt + 120);
		} else if ((int)frame == pauseAt + 150) {
			// MEASURED, AND IT IS A LIMITATION, NOT A BUG HERE: in a
			// --fixed-step run this stays 0. The engine's own pad mask carries
			// 0x1000 for all 120 frames with the touch layer hidden, and PD
			// still does not open the dialog; the same injection through the
			// bridge in a LIVE session opens it on the first press. So the
			// pause-menu crop-diff is taken live (`3d showeye`), and this
			// instrument stays for the non-fixed-step uses it does serve.
			NSLog(@"perfectdark: [3d] %d frames after Start: menu_open=%d",
				(int)frame - pauseAt, menuIosDialogIsOpen());
		}
	}

	// PD_VP3D_GIVE_AT=<frame>[:<weaponnum>] — put a weapon in Joanna's hands at
	// a FRAME NUMBER, for the same reason PD_VP3D_PAUSE_AT exists: a bridge
	// `give 2` lands at a wall-clock moment, so in a --fixed-step replay it
	// lands on a different frame in the eye-L run and the eye-R run and the two
	// captures are then not the same game state. A frame number is the same in
	// both, which is what makes the VIEWMODEL measurable by the two-seeded-
	// replay method at all (dev2-stereo round 2).
	//
	// It has to be a frame PAST the stage's opening cutscene camera, because
	// `player.c:6136` draws no viewmodel while that camera is up — in Chicago
	// the first gun-classed frame is 2861. Default weapon 2, the Falcon 2.
	// Absent, this does nothing at all, so it cannot change a shipped build.
	static int giveAt = -2, giveWep = 2;
	if (giveAt == -2) {
		const char *e = getenv("PD_VP3D_GIVE_AT");
		giveAt = -1;
		if (e && *e) {
			giveAt = atoi(e);
			const char *colon = strchr(e, ':');
			if (colon && colon[1]) {
				giveWep = atoi(colon + 1);
			}
			if (giveWep < 1 || giveWep > 60) {
				giveWep = 2;
			}
			NSLog(@"perfectdark: [3d] PD_VP3D_GIVE_AT=%d weapon %d", giveAt, giveWep);
		}
	}
	if (giveAt > 0 && (int)frame == giveAt) {
		const int got = invGiveSingleWeapon(giveWep) ? 1 : 0;
		bgunEquipWeapon(giveWep);
		NSLog(@"perfectdark: [3d] gave weapon %d at frame %d (inventory_accepted=%d)",
			giveWep, giveAt, got);
	}

	// The post-exit drawable re-measure, spread over two seconds of frames.
	// Once a frame is cheap (a bounds read and, at most, one assignment) and
	// the alternative is a window that came back at the card's size.
	if (pdVision3dResyncFrames > 0 && !pdVision3dOn) {
		pdVision3dResyncFrames--;
		if ((pdVision3dResyncFrames % 20) == 0) {
			pdAngleResyncWindowDrawable();
		}
	}

	// The Crown/system exit's save, on the game thread where configSave()
	// belongs (pdVision3dImmersiveEnded runs on the immersive thread).
	if (pdVision3dSaveAsked) {
		pdVision3dSaveAsked = 0;
		pdIosSaveConfigNow();
	}

	// The eye ring's re-wrap, if the Render Resolution row moved (M6). Here and
	// nowhere else: it is the only point in the frame where the engine is not
	// inside gfx_run, the ANGLE context is current, and nothing holds a raw
	// pointer into the ring. Costs an atomic load per frame when idle.
	pdVisionEyeResizeIfPending();

	// The transition itself: here, on the game thread, with the frame finished.
	// Last in the hook so anything the bridge asked for this frame has already
	// been queued.
	if (pdVision3dPending >= 0) {
		const int want = pdVision3dPending;
		pdVision3dPending = -1;
		pdVision3dApplyMode(want);
	}
}

NSString *pdVision3dStateLines(void)
{
	UIWindowScene *scene = pdVisionScene();
	CGSize now = scene ? scene.effectiveGeometry.coordinateSpace.bounds.size : CGSizeZero;
	return [NSString stringWithFormat:
		@"imm_mode=%d\nimm_running=%d\nimm_frames=%d\nimm_hz=%.1f\n"
		 "imm_no_drawable=%d\n"
		 "imm_foveation=%d/%d\nimm_foveation_maps=%d\nimm_layout=%s\n"
		 "window_parked=%d\ncurtain=%d\npark_cycles=%d\npark_armed=%d\n"
		 "win_corner_radius=%.1f\n"
		 "scene_pt=%.0fx%.0f\npre_park_pt=%.0fx%.0f\n%@%@",
		pdVision3dOn, (int)pdVision3dImmRunning, (int)pdVision3dImmFrames,
		(double)pdVision3dImmHz, (int)pdVision3dImmNoDrawable,
		// supported/configured, then the drawable's own rate-map count, then
		// the layout — guide trap 1 is `.layered` WITH foveation, so the two
		// rows are read together or not at all (D-063).
		(int)pdVision3dFoveationSupported, (int)pdVision3dFoveationConfigured,
		(int)pdVision3dFoveationRateMaps,
		pdVision3dLayoutDedicated ? "dedicated" : "layered",
		pdParked, pdCurtain, pdParkCycles, pdParkArmed,
		(double)pdVision3dWindowCornerRadius(),
		now.width, now.height, pdPreParkSize.width, pdPreParkSize.height,
		// M6: every setting's live value, the sheet's own state, and what the
		// compositor is ACTUALLY using (`panel_*`) — the stored row and the
		// live value side by side, so "the slider moved" and "the panel moved"
		// are two separate assertions a gate can make.
		pdVision3dSettingsStateLines(),
		pdVisionEyeStateLines()];
}

void pdVision3dQueueDeepLink(NSURL *url)
{
	// The cold-launch deep link that PDSceneDelegate used to catch out of the
	// scene's connection options. SwiftUI's .onOpenURL is where it arrives now.
	if (!url) {
		return;
	}
	NSLog(@"perfectdark: [3d] .onOpenURL %@", url);
	if ([url.scheme.lowercaseString isEqualToString:@"perfectdark"]) {
		[PDShell.shared queueDeepLink:url];
	}
}

// ---------------------------------------------------------------------------
// The engine bootstrap
// ---------------------------------------------------------------------------

@implementation PDHostViewController

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.view.backgroundColor = UIColor.blackColor;
}

- (void)viewDidAppear:(BOOL)animated
{
	[super viewDidAppear:animated];
	if (pdVisionBooted) {
		return;
	}
	pdVisionBooted = YES;
	// One run-loop hop, so the window scene is fully active before SDL goes
	// looking for one — but via a RUN LOOP TIMER, not dispatch_async(main).
	// PDVision3D.h's file comment has the whole reason; the short version is
	// that the engine's loop never returns, so a main-QUEUE block that starts
	// it holds the serial main queue forever and SwiftUI dies silently.
	// performSelector:afterDelay: schedules a CFRunLoopTimer instead: same one
	// hop, same thread, completely different consequence.
	[self performSelector:@selector(pdBootEngine) withObject:nil afterDelay:0.0];
}

- (void)pdBootEngine
{
	NSLog(@"perfectdark: [3d] SwiftUI shell — booting the engine");

	// LOSING THE ONLY REGULAR SCENE KILLS AUDIO (plan §2.9). On visionOS the
	// system can disconnect the window scene while an immersive space is open —
	// the player closes the card — and the app is then playing to nothing. Ask
	// for it back; UIKit re-creates it through SwiftUI's WindowGroup and the
	// frame hook's graft puts SDL's window into it, exactly as at launch.
	[NSNotificationCenter.defaultCenter addObserverForName:UISceneDidDisconnectNotification
		object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
			UIScene *sc = note.object;
			if (![sc isKindOfClass:UIWindowScene.class]) {
				return;
			}
			pdIosSaveConfigNow();
			// ONLY IF IT WAS THE LAST ONE. The first version of this asked
			// unconditionally and cost a whole verification round: visionOS
			// disconnects and re-connects the window scene around the
			// immersive dismissal by itself, so the request arrived while a
			// replacement was already coming and the app ended up with TWO
			// window scenes — and therefore two PDRootViews, two
			// openImmersiveSpace calls on the next entry, and the second one
			// failing with a bare .error that rolled the shell back out of 3D.
			// A second scene is much worse than a missing one.
			int others = 0;
			for (UIScene *other in UIApplication.sharedApplication.connectedScenes) {
				if (other != sc && [other isKindOfClass:UIWindowScene.class]
						&& other.activationState != UISceneActivationStateUnattached) {
					others++;
				}
			}
			NSLog(@"perfectdark: [3d] a window scene disconnected (3d=%d, %d other%s left)",
				pdVision3dOn, others, others == 1 ? "" : "s");
			if (others > 0) {
				return;
			}
			NSLog(@"perfectdark: [3d] that was the only window scene — asking for it back"
				" (losing it kills audio)");
			[UIApplication.sharedApplication requestSceneSessionActivation:nil
				userActivity:nil options:nil errorHandler:^(NSError *err) {
					NSLog(@"perfectdark: [3d] scene re-activation refused: %@",
						err.localizedDescription);
				}];
		}];

	// The process arguments, which on visionOS are all we get: there is no
	// main() to be handed argv, and `xcrun simctl launch --args` lands in
	// NSProcessInfo exactly the same way. pdShellPrepare() then appends
	// Documents/pd.args, which is the device's only way to pass a flag.
	NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
	int argc = (int)args.count;
	char **argv = (char **)calloc((size_t)argc + 1, sizeof(char *));
	for (int i = 0; i < argc; i++) {
		argv[i] = strdup(args[i].UTF8String ?: "");
	}
	argv[argc] = NULL;

	int n = 0;
	char **assembled = pdShellPrepare(argc, argv, &n);

	SDL_SetMainReady();
	pdSDLMain(n, assembled);   // DOES NOT RETURN
	NSLog(@"perfectdark: [3d] pdSDLMain RETURNED — that is not supposed to happen");
}

@end

#endif // TARGET_OS_VISION
