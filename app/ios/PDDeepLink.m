// PDDeepLink.m — perfectdark:// links, on an app whose delegate belongs to SDL.
//
// The problem: SDL2 owns the UIApplicationDelegate (SDL_UIKitRunApp installs
// SDLUIKitDelegate) and knows nothing about scenes - there is no UISceneDelegate
// anywhere in SDL 2.32.8's UIKit backend (grep: no `scene:` selector at all).
// Its application:openURL: turns a link into an SDL_DROPFILE event, which the
// shell can watch for... except that on iOS 26/27 the app is scene-based
// whether it asked to be or not (SDL's own window reports a non-nil
// windowScene), and in a scene-based app UIKit delivers a URL to
// -scene:openURLContexts: on the SCENE delegate and never calls the app
// delegate's openURL at all. Measured, not assumed: with the drop event enabled
// and SDL's handler intact, `xcrun simctl openurl` produced no event and no log
// line.
//
// The fix is to add the method UIKit is looking for to whatever class is
// actually serving as the scene delegate, at runtime, without owning either
// delegate. Both paths are installed - the scene one because that is what iOS
// calls now, the app-delegate one because it costs two lines and is what iOS
// called before.
//
// What is NOT handled: a link that launches the app from cold. That URL is
// delivered in the connection options before this code can exist, and catching
// it would mean owning the delegate, which is SDL's. A link to a running or
// backgrounded app - which is what the sim drills and the hub install page use -
// works.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "PDDeepLink.h"
#import "PDShell.h"

static BOOL pdIsOurs(NSURL *url)
{
	return [url.scheme.lowercaseString isEqualToString:@"perfectdark"];
}

static void pdQueueIfOurs(NSURL *url)
{
	if (url && pdIsOurs(url)) {
		[PDShell.shared queueDeepLink:url];
	} else if (url) {
		NSLog(@"perfectdark: [deeplink] ignoring %@", url.scheme);
	}
}

@implementation PDDeepLink

+ (void)installOnSceneDelegate:(id)delegate
{
	if (!delegate) {
		return;
	}
	Class cls = object_getClass(delegate);
	SEL sel = @selector(scene:openURLContexts:);

	IMP imp = imp_implementationWithBlock(^(id self_, UIScene *scene, NSSet<UIOpenURLContext *> *ctxs) {
		(void)self_; (void)scene;
		for (UIOpenURLContext *c in ctxs) {
			NSLog(@"perfectdark: [deeplink] scene:openURLContexts: %@", c.URL);
			pdQueueIfOurs(c.URL);
		}
	});

	Method existing = class_getInstanceMethod(cls, sel);
	if (existing) {
		method_setImplementation(existing, imp);
	} else {
		class_addMethod(cls, sel, imp, "v@:@@");
	}
	NSLog(@"perfectdark: [deeplink] handler installed on scene delegate %s", class_getName(cls));
}

+ (void)install
{
	// The app-delegate path, for good measure. SDL's own implementation only
	// makes an SDL_DROPFILE event out of it, which nothing else in this app
	// wants, so replacing it loses nothing.
	id appDelegate = UIApplication.sharedApplication.delegate;
	if (appDelegate) {
		Class cls = object_getClass(appDelegate);
		SEL sel = @selector(application:openURL:options:);
		IMP imp = imp_implementationWithBlock(^BOOL(id self_, UIApplication *app, NSURL *url, NSDictionary *opts) {
			(void)self_; (void)app; (void)opts;
			NSLog(@"perfectdark: [deeplink] application:openURL: %@", url);
			pdQueueIfOurs(url);
			return YES;
		});
		Method existing = class_getInstanceMethod(cls, sel);
		if (existing) {
			method_setImplementation(existing, imp);
		} else {
			class_addMethod(cls, sel, imp, "B@:@@@");
		}
		NSLog(@"perfectdark: [deeplink] handler installed on app delegate %s", class_getName(cls));
	}

	// Every scene that exists now...
	for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
		[self installOnSceneDelegate:scene.delegate ?: (id)appDelegate];
	}

	// ...and any that connects later (the app may be launched before a scene
	// exists, and iPad multi-window makes more of them).
	[NSNotificationCenter.defaultCenter addObserverForName:UISceneWillConnectNotification
		object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
			UIScene *scene = note.object;
			[PDDeepLink installOnSceneDelegate:scene.delegate ?: (id)UIApplication.sharedApplication.delegate];
		}];
}

@end
