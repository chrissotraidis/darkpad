// PDGeometry.m — the picture's size chain, watched and (on iPhone) defended.
// See PDGeometry.h and D-077.
#import "PDGeometry.h"

#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <objc/runtime.h>

#import "PDShell.h"
#import "PDWatchdog.h"

#include <SDL.h>

#if TARGET_OS_VISION

int pdGeoRepairEnabled = 0;
void pdGeoFrame(void) {}
void pdGeoCheckpoint(const char *why) { (void)why; }
int pdGeoRepair(const char *why) { (void)why; return 0; }
NSString *pdGeoStateLines(void) { return @""; }
NSString *pdGeoReport(void) { return @"geo: not on visionOS (windows are freely resizable)\n"; }
void pdGeoSceneCoordinateSpaceChanged(long o, long n) { (void)o; (void)n; }
NSString *pdGeoPresentedReport(void) { return @"presented: not on visionOS\n"; }
NSString *pdGeoPickerFinish(NSString *pathOrNil) { (void)pathOrNil; return @"ERR not on visionOS"; }

#else

// app/gfx/gfx_angle_egl.mm
extern void *pdAngleGetHostView(void);
extern void *pdAngleGetSDLWindow(void);

/** One reading of every link. Integers, so "changed?" is a memcmp. */
typedef struct {
	int orient;            // the window scene's interface orientation
	int scw, sch;          // the scene's coordinate space, points
	int ww, wh, wx, wy;    // SDL's UIWindow bounds / frame origin
	int rw, rh, rrot;      // SDL's root view bounds; 1 if it carries a rotation
	int vw, vh;            // SDL's Metal view bounds
	int lw, lh, lsc;       // its CAMetalLayer bounds; contentsScale x 100
	int dw, dh;            // the layer's drawableSize
	int ew, eh;            // the EGL surface = what the renderer draws at
	int sw, sh;            // SDL's own window size
	int key;               // 1 SDL's window is key, 2 another window, 0 none
	int sbo;               // UIApplication.statusBarOrientation, which SDL reads
} PDGeoSnap;

static PDGeoSnap sLast;
static BOOL sHaveLast;
static unsigned sChanges;
static unsigned sRepairs;
static unsigned sPortraitFrames;    // frames whose EGL surface was w<h on an iPhone
static unsigned sSdlResizes;
static char sLastSdlEvent[96] = "-";
static char sLastTransition[96] = "-";
static char sLastRepair[160] = "-";
static char sLastSceneChange[96] = "-";

// Bounds on what this file writes to lifecycle.txt (review of D-077): a repair
// that never holds, or a size chain that flaps, must not become a line at every
// frame for as long as the app runs. The first lines of each kind are written
// in full; after that one summary line a minute says how many were left out.
// A repair that has not held this many times in a row is given up on, loudly.
#define PD_GEO_FULL_REPAIR_LINES 10
#define PD_GEO_FULL_CHANGE_LINES 200
#define PD_GEO_REPAIR_GIVE_UP    30
static unsigned sRepairLines, sRepairQuiet;
static unsigned sChangeLines, sChangeQuiet;
static CFTimeInterval sQuietSince;
static unsigned sRepairStreak;   // repairs in a row with no good frame between them
static BOOL sRepairGaveUp;

/** One "N left out" line a minute, for whichever kind went quiet. */
static void pdGeoQuietSummary(void)
{
	const CFTimeInterval now = CACurrentMediaTime();
	if (!sRepairQuiet && !sChangeQuiet) {
		sQuietSince = now;
		return;
	}
	if (now - sQuietSince < 60.0) {
		return;
	}
	PDLifecycle("GEO %u repair line(s) and %u size-change line(s) left out in the last %.0f s "
		"(repairs so far %u, changes %u)", sRepairQuiet, sChangeQuiet, now - sQuietSince, sRepairs, sChanges);
	sRepairQuiet = sChangeQuiet = 0;
	sQuietSince = now;
}

static BOOL pdGeoIsPhone(void)
{
	return UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone;
}

static UIWindowScene *pdGeoScene(UIWindow *win)
{
	if (win.windowScene) {
		return win.windowScene;
	}
	for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
		if ([sc isKindOfClass:UIWindowScene.class]) {
			return (UIWindowScene *)sc;
		}
	}
	return nil;
}

static long pdSceneOrient(UIWindowScene *scene)
{
	if (@available(iOS 16.0, *)) {
		return (long)scene.effectiveGeometry.interfaceOrientation;
	}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	return (long)scene.interfaceOrientation;
#pragma clang diagnostic pop
}

static const char *pdOrientName(long o)
{
	switch (o) {
	case UIInterfaceOrientationPortrait:           return "portrait";
	case UIInterfaceOrientationPortraitUpsideDown: return "portrait-upside-down";
	case UIInterfaceOrientationLandscapeLeft:      return "landscape-left";
	case UIInterfaceOrientationLandscapeRight:     return "landscape-right";
	default:                                       return "unknown";
	}
}

static NSString *pdMaskName(NSUInteger m)
{
	NSMutableArray *a = [NSMutableArray array];
	if (m & UIInterfaceOrientationMaskPortrait)           [a addObject:@"P"];
	if (m & UIInterfaceOrientationMaskPortraitUpsideDown) [a addObject:@"PUD"];
	if (m & UIInterfaceOrientationMaskLandscapeLeft)      [a addObject:@"LL"];
	if (m & UIInterfaceOrientationMaskLandscapeRight)     [a addObject:@"LR"];
	return a.count ? [a componentsJoinedByString:@"|"] : @"none";
}

static PDGeoSnap pdGeoTake(void)
{
	PDGeoSnap s;
	memset(&s, 0, sizeof s);
	UIView *host = (__bridge UIView *)pdAngleGetHostView();
	UIWindow *win = host.window;
	UIWindowScene *scene = pdGeoScene(win);
	if (scene) {
		s.orient = (int)pdSceneOrient(scene);
		CGSize b = scene.coordinateSpace.bounds.size;
		s.scw = (int)lround(b.width);
		s.sch = (int)lround(b.height);
		UIWindow *key = nil;
		for (UIWindow *w in scene.windows) {
			if (w.isKeyWindow) {
				key = w;
				break;
			}
		}
		if (win.isKeyWindow) {
			s.key = 1;
		} else {
			s.key = key ? 2 : 0;
		}
	}
	if (win) {
		s.ww = (int)lround(win.bounds.size.width);
		s.wh = (int)lround(win.bounds.size.height);
		s.wx = (int)lround(win.frame.origin.x);
		s.wy = (int)lround(win.frame.origin.y);
		UIView *root = win.rootViewController.view;
		if (root) {
			s.rw = (int)lround(root.bounds.size.width);
			s.rh = (int)lround(root.bounds.size.height);
			s.rrot = (root.transform.b != 0 || root.transform.c != 0) ? 1 : 0;
		}
	}
	if (host) {
		s.vw = (int)lround(host.bounds.size.width);
		s.vh = (int)lround(host.bounds.size.height);
		if ([host.layer isKindOfClass:CAMetalLayer.class]) {
			CAMetalLayer *l = (CAMetalLayer *)host.layer;
			s.lw = (int)lround(l.bounds.size.width);
			s.lh = (int)lround(l.bounds.size.height);
			s.lsc = (int)lround(l.contentsScale * 100.0);
			s.dw = (int)lround(l.drawableSize.width);
			s.dh = (int)lround(l.drawableSize.height);
		}
	}
	pdAngleGetDrawableSize(&s.ew, &s.eh);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	// SDL's UIKit_ComputeViewFrame() decides portrait or landscape from this
	// (SDL_uikitvideo.m), so it is part of the chain whether it is right or not.
	s.sbo = (int)UIApplication.sharedApplication.statusBarOrientation;
#pragma clang diagnostic pop
	SDL_Window *sw = (SDL_Window *)pdAngleGetSDLWindow();
	if (sw) {
		SDL_GetWindowSize(sw, &s.sw, &s.sh);
	}
	return s;
}

static NSString *pdGeoLine(const PDGeoSnap *s)
{
	return [NSString stringWithFormat:
		@"scene=%s %dx%d win=%dx%d@%d,%d root=%dx%d%s view=%dx%d layer=%dx%d@%.2f "
		 "drawable=%dx%d egl=%dx%d sdl=%dx%d key=%s statusbar=%s",
		pdOrientName(s->orient), s->scw, s->sch, s->ww, s->wh, s->wx, s->wy,
		s->rw, s->rh, s->rrot ? "(rotated)" : "", s->vw, s->vh, s->lw, s->lh, s->lsc / 100.0,
		s->dw, s->dh, s->ew, s->eh, s->sw, s->sh,
		s->key == 1 ? "game" : (s->key == 2 ? "other" : "none"), pdOrientName(s->sbo)];
}

/** SDL's window events, as SDL hands them to the engine's event queue. */
static int pdGeoEventWatch(void *ud, SDL_Event *e)
{
	(void)ud;
	if (e->type != SDL_WINDOWEVENT) {
		return 0;
	}
	const char *what = NULL;
	switch (e->window.event) {
	case SDL_WINDOWEVENT_RESIZED:      what = "RESIZED"; break;
	case SDL_WINDOWEVENT_SIZE_CHANGED: what = "SIZE_CHANGED"; break;
	default: return 0;
	}
	sSdlResizes++;
	snprintf(sLastSdlEvent, sizeof sLastSdlEvent, "%s %dx%d", what, e->window.data1, e->window.data2);
	PDLifecycle("GEO SDL window event %s %dx%d", what, e->window.data1, e->window.data2);
	return 0;
}

/** The keyboard notifications SDL's view controller acts on (D-077). */
static void pdGeoObserveKeyboard(void)
{
	NSNotificationCenter *c = NSNotificationCenter.defaultCenter;
	for (NSString *name in @[ UIKeyboardWillShowNotification, UIKeyboardWillHideNotification ]) {
		[c addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *n) {
			CGRect r = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
			PDLifecycle("GEO %s end=%.0fx%.0f@%.0f,%.0f local=%d",
				[n.name isEqualToString:UIKeyboardWillShowNotification] ? "keyboard WILL SHOW" : "keyboard will hide",
				r.size.width, r.size.height, r.origin.x, r.origin.y,
				[n.userInfo[UIKeyboardIsLocalUserInfoKey] boolValue] ? 1 : 0);
			// SDL's handler runs in the same notification pass; look once the
			// pass is over.
			dispatch_async(dispatch_get_main_queue(), ^{ pdGeoCheckpoint("after keyboard notification"); });
		}];
	}
}

static IMP sOrigWillTransition;

static void pdGeoWillTransition(id self, SEL _cmd, CGSize size, id coord)
{
	UIView *v = ((UIViewController *)self).view;
	snprintf(sLastTransition, sizeof sLastTransition, "%.0fx%.0f (from %.0fx%.0f)",
		size.width, size.height, v.bounds.size.width, v.bounds.size.height);
	PDLifecycle("GEO SDL view controller viewWillTransitionToSize %.0fx%.0f (view was %.0fx%.0f)",
		size.width, size.height, v.bounds.size.width, v.bounds.size.height);
	((void (*)(id, SEL, CGSize, id))sOrigWillTransition)(self, _cmd, size, coord);
}

static void pdGeoInstallOnce(void)
{
	static BOOL done;
	if (done || !pdAngleGetSDLWindow()) {
		return;
	}
	done = YES;
	// PD_GEO_REPAIR=0 in the launch environment starts with the repair off, so
	// the failure can be reproduced from the very first frame.
	const char *env = getenv("PD_GEO_REPAIR");
	if (env && env[0] == '0') {
		pdGeoRepairEnabled = 0;
	}
	SDL_AddEventWatch(pdGeoEventWatch, NULL);
	pdGeoObserveKeyboard();
	Class c = NSClassFromString(@"SDL_uikitviewcontroller");
	Method m = c ? class_getInstanceMethod(c, @selector(viewWillTransitionToSize:withTransitionCoordinator:)) : NULL;
	if (m) {
		sOrigWillTransition = method_setImplementation(m, (IMP)pdGeoWillTransition);
	}
	PDLifecycle("GEO watch installed (sdl event watch, vc transition hook=%d, repair=%d)",
		m ? 1 : 0, pdGeoRepairEnabled);
}

int pdGeoRepairEnabled = 1;

int pdGeoRepair(const char *why)
{
	if (!pdGeoIsPhone() || !pdGeoRepairEnabled || sRepairGaveUp) {
		return 0;
	}
	UIView *host = (__bridge UIView *)pdAngleGetHostView();
	UIWindow *win = host.window;
	UIWindowScene *scene = win.windowScene;
	if (!host || !win || !scene) {
		return 0;
	}
	// The scene is the authority: this app is landscape-only on iPhone
	// (Info.plist), so a landscape scene is the expected case. If the SCENE
	// itself is portrait there is nothing sound to repair towards.
	const CGRect sb = scene.coordinateSpace.bounds;
	if (sb.size.width <= sb.size.height) {
		return 0;
	}
	UIView *root = win.rootViewController.view;
	int fixed = 0;
	const PDGeoSnap before = pdGeoTake();

	if (!CGRectEqualToRect(win.frame, sb)) {
		win.frame = sb;
		fixed++;
	}
	if (root && (root.bounds.size.width < root.bounds.size.height
	             || !CGAffineTransformIsIdentity(root.transform)
	             || !CGRectEqualToRect(root.frame, win.bounds))) {
		root.transform = CGAffineTransformIdentity;
		root.frame = win.bounds;
		fixed++;
	}
	if (host.superview && host.bounds.size.width < host.bounds.size.height) {
		host.frame = host.superview.bounds;
		fixed++;
	}
	if (!fixed) {
		return 0;
	}
	sRepairs++;
	// SDL's view controller turns the new bounds into SDL_WINDOWEVENT_RESIZED
	// (viewDidLayoutSubviews), the engine's event pump turns that into
	// pdAngleResized(), and SDL's Metal view recomputes its drawable in its own
	// layoutSubviews: the same path a real rotation takes.
	[root setNeedsLayout];
	[root layoutIfNeeded];
	[host setNeedsLayout];
	[host layoutIfNeeded];
	const PDGeoSnap after = pdGeoTake();
	snprintf(sLastRepair, sizeof sLastRepair, "%s: %d fixed, view %dx%d -> %dx%d",
		why, fixed, before.vw, before.vh, after.vw, after.vh);
	if (sRepairLines < PD_GEO_FULL_REPAIR_LINES) {
		sRepairLines++;
		PDLifecycle("GEO REPAIR (%s): %d link(s) were portrait-shaped in a landscape scene\n"
			"    before %s\n    after  %s", why, fixed,
			pdGeoLine(&before).UTF8String, pdGeoLine(&after).UTF8String);
	} else {
		sRepairQuiet++;
	}
	if (++sRepairStreak >= PD_GEO_REPAIR_GIVE_UP) {
		sRepairGaveUp = YES;
		PDLifecycle("GEO REPAIR GIVEN UP: %u repairs in a row did not hold (last: %s); "
			"no more repairs this session. %s", sRepairStreak, sLastRepair, pdGeoLine(&after).UTF8String);
	}
	return fixed;
}

static void pdGeoLogIfChanged(const char *why, BOOL force)
{
	const PDGeoSnap s = pdGeoTake();
	if (!force && sHaveLast && !memcmp(&s, &sLast, sizeof s)) {
		return;
	}
	sLast = s;
	sHaveLast = YES;
	sChanges++;
	if (sChangeLines < PD_GEO_FULL_CHANGE_LINES) {
		sChangeLines++;
		PDLifecycle("GEO %s %s", why, pdGeoLine(&s).UTF8String);
	} else {
		sChangeQuiet++;
	}
}

void pdGeoFrame(void)
{
	if (!pdAngleGetSDLWindow()) {
		return;
	}
	pdGeoInstallOnce();
	// The renderer is about to ask the EGL surface for its size. On an iPhone
	// a w<h answer is never right: this app declares landscape only, so it is
	// a window that UIKit (or SDL) has laid out portrait behind the game's back.
	// Put it back BEFORE the frame is drawn rather than draw into it.
	int ew = 0, eh = 0;
	pdAngleGetDrawableSize(&ew, &eh);
	pdGeoQuietSummary();
	if (pdGeoIsPhone() && ew > 0 && eh > 0 && ew < eh) {
		sPortraitFrames++;
		pdGeoLogIfChanged("frame", NO);
		pdGeoRepair("portrait EGL surface at a frame");
	} else {
		// A portrait SDL view whose surface has not caught up yet is the same
		// fault one frame earlier.
		UIView *host = (__bridge UIView *)pdAngleGetHostView();
		if (pdGeoIsPhone() && host.window && host.bounds.size.width < host.bounds.size.height) {
			pdGeoLogIfChanged("frame", NO);
			pdGeoRepair("portrait SDL view at a frame");
		} else {
			sRepairStreak = 0;   // a good frame: the last repair held
		}
	}
	pdGeoLogIfChanged("frame", NO);
}

void pdGeoCheckpoint(const char *why)
{
	if (!pdAngleGetSDLWindow()) {
		return;
	}
	pdGeoLogIfChanged(why, YES);
	if (pdGeoRepair(why) > 0) {
		pdGeoLogIfChanged(why, YES);
	}
}

void pdGeoSceneCoordinateSpaceChanged(long oldOrientation, long newOrientation)
{
	if (oldOrientation == newOrientation) {
		// UIKit calls this for every geometry pass, most of them no change at
		// all (a dozen at launch): only a size change is worth a line.
		pdGeoLogIfChanged("scene-update", NO);
		return;
	}
	snprintf(sLastSceneChange, sizeof sLastSceneChange, "%s -> %s",
		pdOrientName(oldOrientation), pdOrientName(newOrientation));
	PDLifecycle("GEO scene coordinate space updated: %s -> %s",
		pdOrientName(oldOrientation), pdOrientName(newOrientation));
	pdGeoLogIfChanged("scene-update", YES);
}

NSString *pdGeoStateLines(void)
{
	const PDGeoSnap s = pdGeoTake();
	return [NSString stringWithFormat:
		@"size_scene=%s %dx%d\nsize_window=%dx%d\nsize_root=%dx%d%s\nsize_view=%dx%d\n"
		 "size_layer=%dx%d@%.2f\nsize_layer_drawable=%dx%d\nsize_egl=%dx%d\nsize_sdl=%dx%d\n"
		 "size_portrait_frames=%u\nsize_repairs=%u\nsize_changes=%u\nsize_sdl_resizes=%u\n"
		 "size_repair_streak=%u\nsize_repair_gave_up=%d\n"
		 "size_last_sdl_event=%s\nsize_last_transition=%s\nsize_last_repair=%s\nsize_last_scene_change=%s\n",
		pdOrientName(s.orient), s.scw, s.sch, s.ww, s.wh, s.rw, s.rh, s.rrot ? "(rotated)" : "",
		s.vw, s.vh, s.lw, s.lh, s.lsc / 100.0, s.dw, s.dh, s.ew, s.eh, s.sw, s.sh,
		sPortraitFrames, sRepairs, sChanges, sSdlResizes,
		sRepairStreak, (int)sRepairGaveUp,
		sLastSdlEvent, sLastTransition, sLastRepair, sLastSceneChange];
}

NSString *pdGeoReport(void)
{
	const PDGeoSnap s = pdGeoTake();
	NSMutableString *r = [NSMutableString stringWithFormat:@"geo %@\n", pdGeoLine(&s)];
	UIView *host = (__bridge UIView *)pdAngleGetHostView();
	UIViewController *sdlvc = host.window.rootViewController;
	if (sdlvc) {
		[r appendFormat:@"sdl_vc=%@ supported=%@\n", NSStringFromClass(sdlvc.class),
			pdMaskName(sdlvc.supportedInterfaceOrientations)];
	}
	[r appendFormat:@"app_supported_for_sdl_window=%@\n",
		pdMaskName([UIApplication.sharedApplication supportedInterfaceOrientationsForWindow:host.window])];
	[r appendString:pdGeoStateLines()];
	return r;
}

// ---------------------------------------------------------------------------
// The presented-controller chain, and the Files picker finished from a script
// (D-077 reproduction). The bridge's `settings row` opens the REAL
// UIDocumentPickerViewController; these close it the two ways a finger does.

static UIViewController *pdTopPresented(UIWindow **inWindow)
{
	UIViewController *best = nil;
	UIWindow *bestWin = nil;
	for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
		if (![sc isKindOfClass:UIWindowScene.class]) {
			continue;
		}
		for (UIWindow *w in ((UIWindowScene *)sc).windows) {
			if (w.hidden || !w.rootViewController.presentedViewController) {
				continue;
			}
			if (bestWin && w.windowLevel < bestWin.windowLevel) {
				continue;
			}
			UIViewController *top = w.rootViewController;
			while (top.presentedViewController) {
				top = top.presentedViewController;
			}
			best = top;
			bestWin = w;
		}
	}
	if (inWindow) {
		*inWindow = bestWin;
	}
	return best;
}

NSString *pdGeoPresentedReport(void)
{
	NSMutableString *r = [NSMutableString string];
	for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
		if (![sc isKindOfClass:UIWindowScene.class]) {
			continue;
		}
		UIWindowScene *ws = (UIWindowScene *)sc;
		[r appendFormat:@"scene orient=%s bounds=%@\n", pdOrientName(pdSceneOrient(ws)),
			NSStringFromCGSize(ws.coordinateSpace.bounds.size)];
		for (UIWindow *w in ws.windows) {
			[r appendFormat:@"window %@ level=%.0f hidden=%d key=%d bounds=%@ root=%@",
				NSStringFromClass(w.class), w.windowLevel, (int)w.hidden, (int)w.isKeyWindow,
				NSStringFromCGSize(w.bounds.size), NSStringFromClass(w.rootViewController.class)];
			if (w.rootViewController) {
				[r appendFormat:@" supported=%@", pdMaskName(w.rootViewController.supportedInterfaceOrientations)];
			}
			[r appendString:@"\n"];
			UIViewController *p = w.rootViewController.presentedViewController;
			while (p) {
				[r appendFormat:@"  presented %@ style=%ld supported=%@ view=%@\n",
					NSStringFromClass(p.class), (long)p.modalPresentationStyle,
					pdMaskName(p.supportedInterfaceOrientations), NSStringFromCGSize(p.view.bounds.size)];
				p = p.presentedViewController;
			}
		}
	}
	UIWindow *tw = nil;
	UIViewController *top = pdTopPresented(&tw);
	[r appendFormat:@"top_presented=%@\n", top ? NSStringFromClass(top.class) : @"none"];
	return r;
}

/**
 * Finish whatever is presented on top the way a finger would: a document picker
 * is dismissed and its delegate told (cancelled when path is nil, picked with
 * that file otherwise — the picker's own order: it goes away first, then the
 * delegate hears); an alert is dismissed as if OK was pressed.
 */
NSString *pdGeoPickerFinish(NSString *pathOrNil)
{
	UIWindow *w = nil;
	UIViewController *top = pdTopPresented(&w);
	if (!top) {
		return @"ERR nothing is presented";
	}
	NSString *cls = NSStringFromClass(top.class);
	if ([top isKindOfClass:UIDocumentPickerViewController.class]) {
		UIDocumentPickerViewController *p = (UIDocumentPickerViewController *)top;
		id<UIDocumentPickerDelegate> d = p.delegate;
		NSURL *url = pathOrNil ? [NSURL fileURLWithPath:pathOrNil] : nil;
		[p dismissViewControllerAnimated:YES completion:^{
			if (url && [d respondsToSelector:@selector(documentPicker:didPickDocumentsAtURLs:)]) {
				[d documentPicker:p didPickDocumentsAtURLs:@[ url ]];
			} else if (!url && [d respondsToSelector:@selector(documentPickerWasCancelled:)]) {
				[d documentPickerWasCancelled:p];
			}
		}];
		PDLifecycle("GEO picker finished from the bridge (%s)", url ? "picked" : "cancelled");
		return [NSString stringWithFormat:@"picker %@ (%@)", url ? @"picked" : @"cancelled", cls];
	}
	if (pathOrNil) {
		return [NSString stringWithFormat:@"ERR the top controller is %@, not a document picker", cls];
	}
	[top.presentingViewController dismissViewControllerAnimated:YES completion:nil];
	PDLifecycle("GEO %s dismissed from the bridge", cls.UTF8String);
	return [NSString stringWithFormat:@"dismissed %@", cls];
}

#endif // TARGET_OS_VISION
