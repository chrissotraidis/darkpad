// PDController.h — GCController: look on the degrees seam, overlay hiding.
#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class UIWindow;

@interface PDController : NSObject

@property (class, readonly) PDController *shared;

/** Start watching for pads. Main thread, once. */
- (void)start;

/** Frame hook: integrate the right stick into look degrees, and watch the left
    stick for the double-flick roll (D-037). Game thread. */
- (void)tick;

/**
 * Feed one LEFT-stick x sample to the double-flick roll detector, as if a pad
 * had reported it (the :8775 bridge's `pad lx <value>`).
 *
 * A simulator cannot be handed a controller, so this is the only way a script
 * can drive the gesture - and it drives the real state machine, not a shortcut
 * past it. Returns what the sample did. Main/game thread; dev builds only.
 */
- (NSString *)injectLeftStickX:(float)x;

/** GCControllerDidConnect/Disconnect, by hand (the bridge's `pad fake`). */
- (void)padsChanged;

/** visionOS: claim gamepad events so presses are not turned into gaze-pinch
    events (charter Phase 5). A no-op on iOS. */
+ (void)claimGamepadEventsInWindow:(UIWindow *)window;

@end

NS_ASSUME_NONNULL_END
