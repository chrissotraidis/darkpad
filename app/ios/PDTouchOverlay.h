// PDTouchOverlay.h — touch controls v1. Constants and rationale in the .m.
#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Is a pad connected right now? (GameController's own answer, or PD_FAKE_PAD=1
 * in the environment for the simulator, where a controller cannot be paired.)
 */
BOOL PDTouchOverlayAnyPadConnected(void);

/**
 * Force the answer above, for the :8775 bridge's `pad fake on|off|auto`.
 *
 * 1 = pretend a pad is connected, 0 = pretend none is, -1 = back to the real
 * answer (GameController, or PD_FAKE_PAD in the environment). A simulator
 * cannot pair or unpair a controller, so this is the only way a script can
 * drive the connect/disconnect path the user reported broken (D-037). Dev
 * instrument: nothing in the app ever calls it.
 */
void PDTouchOverlaySetFakePad(int state);

@interface PDTouchOverlay : UIView

/** Create it over the SDL window and keep it there. Main thread. */
+ (instancetype)installInWindow:(UIWindow *)window;

/** The live one, if any. */
@property (class, readonly, nullable) PDTouchOverlay *current;

/**
 * Frame hook: hand this frame's stick, buttons and accumulated look degrees to
 * the engine (overlay patch 0015). Game thread, once per frame, and the only
 * place the engine hears from the touch layer.
 */
+ (void)publishInput;

/**
 * A continuous synthetic touch STREAM, for measuring what the touch layer costs
 * the frame (D-034, M-032). `tap`/`drag` deliver their whole gesture inside one
 * main-queue block, which is exactly what a real finger does not do: a real
 * drag is one UIKit callback per panel sample, spread over seconds. This starts
 * the touch under `p`, then walks it by `perStep` every `ms` milliseconds for
 * `steps` steps, each in its own turn of the run loop - so the measured frame
 * intervals include the per-event cost the way a player pays it.
 *
 * Returns immediately with what the start point hit; the stream runs on.
 */
- (NSString *)injectStreamFrom:(CGPoint)p by:(CGVector)perStep steps:(int)steps intervalMs:(double)ms;

/** What this layer is holding right now, for the bridge's `state`. */
- (NSString *)heldReport;

/**
 * Every window in the order UIKit consults them, plus a hit test taken FROM THE
 * WINDOW at each visible chip — the route a real touch takes (D-041). The
 * bridge's `windows`. Main thread.
 */
+ (NSString *)windowsReport;

/**
 * The two delivery counters on their own, without the report around them.
 *
 * PDWatchdog's heartbeat is written by a plain pthread once a second and must
 * not build an NSString or walk every window to learn one number; the frame
 * hook copies these into its snapshot instead. Safe with no overlay (0).
 */
+ (unsigned)touchesBeganCount;
+ (unsigned)hitTestCount;

/**
 * One recovery experiment, for the bridge's `heal <n>` (D-041 round 2). The
 * broken state has never reproduced off the user's phone, so the candidates are
 * numbered and tried one at a time while he is in it. Main thread.
 */
+ (NSString *)heal:(int)which;

/**
 * Assert that a real finger can still reach this layer, and correct and report
 * what can be corrected (D-037, D-041). Called on every unhide and whenever a
 * window went away over the top of us. Main thread.
 */
- (void)reassertTouchability;

/** D-086: latch a chip press that was lifted before any frame saw it (on by
 *  default; the bridge's `touch latch on|off`). */
+ (void)setTapLatchEnabled:(BOOL)on;
+ (BOOL)tapLatchEnabled;

/** Append one line to Documents/touch-watchdog.txt (the bridge's self-test). */
- (void)noteWatchdog:(NSString *)what;

/** Re-read PDDefaults (opacity, size) and re-lay out. */
- (void)applySettings;

// --- layout editing --------------------------------------------------------
// "Customize Touch Layout…" from the settings page: every gameplay chip becomes
// draggable, and where it is dropped is written to PDDefButtonLayout in the same
// unit coordinates of the full view the built-in table uses - so the table stays
// the reset, and Reset is forgetting the dictionary AND going back to scale 1.0.
// The bar carries a live size slider, so placing and sizing are one pass.
//
// While editing, nothing reaches the engine: no button mask, no stick, no look.

/** Enter edit mode. Main thread. Nothing happens if the layer is off. */
- (void)beginLayoutEditing;

/** Leave edit mode and go back to playing. */
- (void)endLayoutEditing;

/** Forget every dragged position and the size: the built-in table at 1.0. */
- (void)resetLayout;

@property (nonatomic, readonly) BOOL layoutEditing;

/** A pad is connected: the overlay hides itself, and shows again when it goes. */
@property (nonatomic) BOOL padConnected;

/**
 * Play a combat roll to the engine, `dir` being -1 for left and +1 for right.
 *
 * ONE roll implementation, two gestures: the touch layer's double tap in the
 * stick region and PDController's double flick of a pad's left stick (D-037).
 * bwalkTryRoll() takes its direction from speedsideways and bondmove.c takes
 * the button on its edge, so a roll is not a button press - it is a few frames
 * of full strafe with CK_0800 down part-way through, and that frame script
 * lives here, in the thing that publishes frames.
 *
 * Returns NO when the roll is refused (the setting is off, a menu is open, the
 * layout editor is up, or one is already in flight). Main/game thread.
 */
- (BOOL)startRollDirection:(int)dir source:(NSString *)source;

// --- bridge-driven synthetic input (scripts/sim-validate.sh) --------------
// simctl's injected events bypass UIKit entirely, so a validation run cannot
// press an on-screen button from outside the process. These do it from inside:
// the same handlers a finger reaches, plus a hit-test report so the script can
// assert WHAT was hit rather than that something was.

/** What is under this point, as "button:FIRE" / "stick" / "look" / "MISS". */
- (NSString *)hitTestReportAtPoint:(CGPoint)p;

/** Press, hold for `ms`, release. Returns the same report string. */
- (NSString *)injectTapAtPoint:(CGPoint)p holdMilliseconds:(NSInteger)ms;

/** Touch down at p, drag by (dx,dy) over a few steps, lift. */
- (NSString *)injectDragFrom:(CGPoint)p by:(CGVector)d;

/** Two taps at p — the roll gesture, from a script. */
- (NSString *)injectDoubleTapAtPoint:(CGPoint)p;

/**
 * Move the menu pointer WITHOUT pressing it (the bridge's `point`).
 *
 * The pointer's button is the click (overlay 0019), so a tap both moves the
 * highlight and chooses. That makes "which item is under this point" an
 * unanswerable question from outside — the answer has already been acted on.
 * This moves the highlight and stops, so a validation run can screenshot the
 * highlight and assert on it before it commits to anything.
 */
- (NSString *)movePointerOnlyTo:(CGPoint)p;

@end

NS_ASSUME_NONNULL_END
