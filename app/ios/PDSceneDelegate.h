// PDSceneDelegate.h — the UIScene lifecycle, which iOS 27 makes mandatory.
//
// See PDSceneDelegate.m for why this exists at all (D-038); the short version
// is that an app linked against the iOS 27 SDK with no UIApplicationSceneManifest
// is killed at launch by UIKit itself - EXC_BREAKPOINT/SIGTRAP in
// __UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption - on the
// device AND on the simulator. It is the linked SDK that is checked.
#import <UIKit/UIKit.h>

@interface PDSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong, nullable) UIWindow *window;

/**
 * Forwards to pdGraftSDLWindows() (PDShell.h), where both the graft and the
 * `graft off|on` switch live from round V on. Kept because the scene callbacks
 * in this file are still one of the graft's two callers on iOS.
 */
+ (int)graftSDLWindows;

@end
