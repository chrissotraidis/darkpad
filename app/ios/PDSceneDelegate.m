// PDSceneDelegate.m — the UIScene lifecycle on iOS, and the graft SDL needs.
//
// WHY (D-038). /Applications/Xcode.app became Xcode 27 on 2026-09-14 and every
// build since links against the iOS 27 SDK. iOS 27 refuses to run an app that
// was linked on that SDK and has no UIApplicationSceneManifest: UIKit trips
// __UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption on the
// FrontBoard scene-creation path and the process dies with EXC_BREAKPOINT
// before a single line of ours runs. The user's phone did exactly that with the
// first round-P build, and the concurrent round-Q agent hit the same thing on
// the SIMULATOR the first time it built after the toolchain moved (D-037 §4):
// it is the LINKED SDK that is checked, not the deployment target and not the
// device, so every build of this app on this machine is affected. "The gate was
// green yesterday" stopped being evidence the moment Xcode changed underneath
// it.
//
// WHAT IT IS NOT. It is not a port of the app onto scenes: SDL 2.32.8 has no
// scene support whatsoever (`strings libSDL2.a` has no windowScene, no
// connectedScenes, no scene: selector at all), it owns the
// UIApplicationDelegate, and it creates its UIWindow the pre-scene way with
// -initWithFrame:.
//
// THE GRAFT IS NOT INSURANCE - it is load-bearing, and it was measured. The
// first version of this file assumed UIKit's compatibility attachment would
// keep putting SDL's window on the scene the way PDDeepLink.m had observed it
// doing before the manifest existed. It does not. With the manifest declared,
// on lane 1 (iPhone 17 Pro Max, iOS 27.0): the engine ran at a clean 60 fps
// for 4634 frames, the bridge answered, and the screen was BLACK - drawable
// 1320x2868 where 2868x1320 was expected (no scene, so no orientation), and
// touch_overlay=none. A sceneless UIWindow appears in NEITHER
// UIApplication.windows NOR any scene's windows array, so nothing in UIKit can
// find it and nothing composites it.
//
// The handle that does work is the renderer's: ANGLE built its surface from
// SDL's SDL_MetalView (app/gfx/gfx_angle_egl.mm, pdAngleGetHostView), and that
// view's -window is SDL's UIWindow whether UIKit can enumerate it or not. The
// graft runs from the scene callbacks AND from the per-frame hook (PDShell.m),
// because the scene connects long before SDL's window exists: SDL builds it
// inside videoInit(), which is inside the engine, which starts from
// postFinishLaunch.
//
// So this class does three things:
//
//  1. It exists, and is named by the manifest, so the app has adopted the
//     lifecycle and UIKit's launch-time check passes.
//  2. It grafts SDL's window onto the scene, which is what puts the game on
//     screen at all.
//  3. It catches a deep link that LAUNCHED the app. That URL arrives in the
//     scene's connection options and nowhere else, which is the one deep-link
//     case PDDeepLink.m says it cannot handle. It can now.
//
// Everything else stays where it was. The app-level lifecycle notifications
// (UIApplicationWillResignActive, DidEnterBackground, WillEnterForeground,
// WillTerminate) are still posted to a scene-based app, and pd_ios_main.m's
// pdRegisterLifecycle() still hangs the pd.ini + eeprom save and the pacer
// suspend/resume off them; the scene notifications are observed there too, as
// belt and braces, so the save fires whichever one iOS decides to post first.
//
// VISIONOS (round V, D-047). This whole file is compiled out on xrOS. There,
// SwiftUI declares the scenes (an ImmersiveSpace can only be declared by a
// SwiftUI App) and Info-visionos.plist has no UISceneConfigurations at all —
// and the class must not merely be unused but ABSENT, because UIKit persists a
// scene session's configuration name and delegate CLASS NAME across installs
// of the same bundle id. A headset that has run the Phase-5 builds will try to
// restore a session naming this class; with the class gone the lookup fails and
// UIKit falls back to the app delegate's configuration, which is SwiftUI's.
// That is the family's fix (q2repro NOTES-FROM-VKQUAKE), and a fresh simulator
// never reproduces the problem it solves. The graft itself was never
// scene-delegate work and now lives in PDShell.m; the class method below
// forwards to it.
#import "PDSceneDelegate.h"
#import "PDShell.h"
#import "PDTouchOverlay.h"
#import "PDWatchdog.h"
#import "PDGeometry.h"

#if !TARGET_OS_VISION

@implementation PDSceneDelegate

/** Forwards to pdGraftSDLWindows() in PDShell.m, where the body lives now. */
+ (int)graftSDLWindows
{
	return pdGraftSDLWindows();
}

- (void)scene:(UIScene *)scene
	willConnectToSession:(UISceneSession *)session
	options:(UISceneConnectionOptions *)options
{
	PDLifecycle("scene willConnect %s state=%ld", session.persistentIdentifier.UTF8String,
		(long)scene.activationState);
	NSLog(@"perfectdark: [scene] connected %@ (role %@, state %ld)",
		session.persistentIdentifier, session.role, (long)scene.activationState);

	pdGraftSDLWindows();

	// The cold-launch deep link: PDDeepLink.m's "what is NOT handled". The URL
	// that started the app is in the connection options and is never delivered
	// to -scene:openURLContexts:.
	for (UIOpenURLContext *c in options.URLContexts) {
		NSLog(@"perfectdark: [scene] launch URL %@", c.URL);
		if ([c.URL.scheme.lowercaseString isEqualToString:@"perfectdark"]) {
			[PDShell.shared queueDeepLink:c.URL];
		}
	}
}

- (void)sceneDidBecomeActive:(UIScene *)scene
{
	(void)scene;
	// Cheap, idempotent, and the moment a window that missed the graft at
	// connect time (SDL's, which does not exist yet then) would be visible.
	pdGraftSDLWindows();
	pdGeoCheckpoint("scene active");
}

/**
 * UIKit moved the scene's coordinate space: a rotation, or a presented
 * controller that asked for an orientation the scene then took. Logged with
 * the whole size chain (D-077); on this landscape-only iPhone app it should
 * never say portrait.
 */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
- (void)windowScene:(UIWindowScene *)windowScene
	didUpdateCoordinateSpace:(id<UICoordinateSpace>)previousCoordinateSpace
	interfaceOrientation:(UIInterfaceOrientation)previousInterfaceOrientation
	traitCollection:(UITraitCollection *)previousTraitCollection
{
	(void)previousCoordinateSpace;
	(void)previousTraitCollection;
	pdGeoSceneCoordinateSpaceChanged((long)previousInterfaceOrientation,
		(long)windowScene.interfaceOrientation);
}
#pragma clang diagnostic pop

@end

#endif // !TARGET_OS_VISION
