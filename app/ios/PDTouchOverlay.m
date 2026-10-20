// PDTouchOverlay.m — touch controls v1 for Perfect Dark.
//
// The constants are the family's, not invented here (dhewm3-ios, GoldenEye and
// the charter's Phase 1 paragraph):
//
//   floating move stick, radius 62pt, radial deadzone 0.15,
//   response 0.4*mag + 0.6*mag^3,
//   drag-look on the right at 0.30 degrees per point (D-032),
//   button opacity 0.28, button scale 1.0 (bean's own numbers).
//
// Two things about this port specifically:
//
// 1. **Look is degrees, straight into the engine's look seam** (overlay 0015).
//    Not mouse counts, not mouseSensX. docs/frame-map.md follows the chain and
//    shows why: a drag's degrees would otherwise depend on a mouse setting a
//    phone player cannot reach.
//
// 2. **The stick is analogue movement on the RIGHT stick** (D-022, Q-003).
//    D-013 sent the four C directions instead, reading "the analog stick is the
//    look axis" off upstream's W/A/S/D binds. That is true of the LEFT stick and
//    only of it: under CONTROLMODE_PC - the port's own default, forced from
//    Game.PlayerN.ExtendedControls on every gamefile load - the RIGHT stick is
//    movedata.analogstrafe/analogwalk (bondmove.c:1281-1283), which is the only
//    path with a walk speed between "still" and "run". The digital C-button
//    mapping is kept for the N64 styles and is the Control Style row's other
//    setting.
//
// 3. **In a menu the whole screen is a pointer** (D-023, overlay 0019). PD's
//    menus take a mouse, and dialogChangeItemFocusWithMouse() walks the open
//    dialog's own columns and rows. So the highlight follows the finger, a TAP
//    clicks on the lift (D-083), and a vertical drag feeds the wheel - sized so
//    the menu follows the finger - and never clicks at all. A tap beside the
//    dialog is LEFT/RIGHT, and a tap on no item is nothing (overlay 0051).
#import <GameController/GameController.h>

#import "PDTouchOverlay.h"
#import "PDVision.h"
#import "PDShell.h"
#import "PDDefaults.h"
#import "PDSettingsViewController.h"

// overlay 0051 — one menu line as a fraction of the screen's height (D-083).
extern float menuIosRowFraction(void);

// overlay 0021 — every paused state, not just an open menu dialog (D-037).
// Declared here rather than in PDShell.h: that header belongs to another seam
// and this is the only file that asks the question.
extern int playerIosIsPaused(void);

// app/gfx/gfx_angle_egl.mm — the SDL_MetalView the renderer draws into. Its
// -window is SDL's UIWindow whether or not UIKit can enumerate it (D-038).
extern void *pdAngleGetHostView(void);

// ---------------------------------------------------------------------------
// Where a real touch would actually go (D-041).
//
// The overlay's own -hitTestReportAtPoint: answers from the layer's MODEL: it
// asks "which chip is at this point", and it is right even when nothing on
// screen can be touched at all. Round Q's -reassertTouchability had the same
// blind spot one level up - it checked the overlay's interactivity, its window
// membership and what was over it INSIDE that window, and all three can be
// perfect while UIKit routes the touch to a different window entirely.
//
// This is the routing UIKit itself does: every window of every window scene,
// highest windowLevel first, skipping the ones that cannot take a touch, and
// the first whose -hitTest: answers wins. If that window is not SDL's, a
// finger on a chip lands somewhere else - which is exactly what the user saw.

/** Every window this process owns, highest level first. */
static NSArray<UIWindow *> *pdAllWindows(void)
{
	NSMutableArray<UIWindow *> *all = [NSMutableArray array];
	for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
		if (![s isKindOfClass:UIWindowScene.class]) {
			continue;
		}
		for (UIWindow *w in ((UIWindowScene *)s).windows) {
			if (![all containsObject:w]) {
				[all addObject:w];
			}
		}
	}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	for (UIWindow *w in UIApplication.sharedApplication.windows) {
		if (![all containsObject:w]) {
			[all addObject:w];
		}
	}
#pragma clang diagnostic pop
	// A sceneless window is in neither enumeration (D-038) and is still on
	// screen as far as the renderer is concerned, so ask the renderer too.
	UIWindow *sdl = ((__bridge UIView *)pdAngleGetHostView()).window;
	if (sdl && ![all containsObject:sdl]) {
		[all addObject:sdl];
	}
	[all sortUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
		if (a.windowLevel == b.windowLevel) { return NSOrderedSame; }
		return a.windowLevel > b.windowLevel ? NSOrderedAscending : NSOrderedDescending;
	}];
	return all;
}

/** SDL's window: the one the game, the chips and the gear all live in. */
static UIWindow *pdGameWindow(void)
{
	return ((__bridge UIView *)pdAngleGetHostView()).window;
}

/**
 * The view a touch at `p` (screen points) would be delivered to, and the window
 * it would arrive through. Either may come back nil.
 */
static UIView *pdRouteHitTest(CGPoint p, UIWindow **outWindow)
{
	for (UIWindow *w in pdAllWindows()) {
		if (w.hidden || w.alpha < 0.01 || !w.userInteractionEnabled) {
			continue;
		}
		UIView *hit = [w hitTest:[w convertPoint:p fromWindow:nil] withEvent:nil];
		if (hit) {
			if (outWindow) { *outWindow = w; }
			return hit;
		}
	}
	if (outWindow) { *outWindow = nil; }
	return nil;
}

// --- the family constants --------------------------------------------------
static const CGFloat kStickRadius     = 62.0;
static const CGFloat kStickKnobRadius = 26.0;
static const CGFloat kStickDeadzone   = 0.15;
static const CGFloat kStickLinear     = 0.4;
static const CGFloat kStickCubic      = 0.6;
// Past this much of the curved magnitude the matching C button is held. Low
// enough that a small push walks, high enough that resting a thumb does not.
static const CGFloat kMoveThreshold   = 0.28;
// The left edge of the look zone, as a fraction of the width. Everything left
// of it belongs to the stick whatever else is going on. bean's kStickRegionFrac.
static const CGFloat kStickZoneFrac   = 0.45;
// A touch that moves less than this and lasts less than that is a tap, which in
// a menu means "confirm" (D-014).
static const CGFloat kTapSlopPoints   = 12.0;
static const NSTimeInterval kTapMaxSeconds = 0.25;
// A menu tap's click, in engine frames after the lift (D-083): one frame with
// the button up to AIM (the highlight moves to the item under the lift point),
// then two with it down - the first is the select (a Z_TRIG edge), the second
// is what lets a slider take the tap's position (menuitemSliderTick() enters
// its edit mode on the first and reads mouseheld on the next).
static const int kMenuClickFrames = 3;
// A chip's touch target is bean's: a quarter larger than the ring that is drawn.
static const CGFloat kHitRadiusFactor = 1.25;
// D-088 (Shipwright D-038): the eye badge's radius, and how a hidden chip
// ghosts in the layout editor.
static const CGFloat kHideBadgeRadius = 14.0;
static const CGFloat kHiddenGhostAlpha = 0.22;

// --- the double-tap roll (D-032) -------------------------------------------
// Two taps in the stick region inside this window, within this distance of each
// other, are a roll. The half of the REGION the taps land in picks the side:
// nearer the screen edge is left.
static const NSTimeInterval kDoubleTapSeconds = 0.30;
static const CGFloat kDoubleTapSlopPoints = 70.0;
// The FIRST tap must have been a tap: down-to-up inside this, without a
// stick excursion. Lifting a held stick and re-planting the thumb (the normal
// re-centre while walking) is not a tap and must never arm a roll.
static const NSTimeInterval kTapMaxHoldSeconds = 0.20;
// How the roll is played to the engine. bwalkTryRoll() (bondwalk.c:386) takes
// its direction from speedsideways - the strafe the roll came out of - so the
// gesture has to BE a strafe for a few frames with the roll button pressed
// inside it, exactly as a thumb on a pad would do it. The press is on the
// button's edge (bondmove.c:1765 reads joyGetButtonsPressedOnSample), so the
// bit goes down once, part-way through, and comes back up before the strafe
// ends.
static const int kRollFrames      = 10;
static const int kRollPressBegin  = 8;   // frames remaining when ROLL goes down
static const int kRollPressEnd    = 5;   // ...and when it comes back up

// --- the buttons -----------------------------------------------------------
// mask bits are CK_ bit positions, which are also the CONT_ values
// (include/PR/os_cont.h, port/include/input.h).
//
// GLYPHS ONLY (D-032, the user 2026-09-14: "NO WORDS LIKE I SAID"). The table,
// the glyphs, the radii and the positions are GoldenEye's - bean's
// touch_overlay_uikit.mm:388-412, which are HIS tuned layout exported off his
// own device after real play, not a guess. Positions are unit coordinates of
// the FULL view, the same representation the layout editor saves, so a baked-in
// layout and a saved one land in the same place.
typedef struct {
	const char *label;
	unsigned mask;
	const char *symbol;
	CGFloat unitX;
	CGFloat unitY;
	CGFloat radius;
} PDButtonSpec;

#define PD_CK_X_RELOAD   0x00000040u  // CK_X  — "Reload"
#define PD_CK_Y_NEXTWEAP 0x00000080u  // CK_Y  — "Next Weapon"
#define PD_CK_ROLL       0x08000000u  // CK_0800 — Dab's "Combat Roll"
#define PD_CK_CROUCH     0x80000000u  // CK_8000 — "Cycle Crouch"
// D-085 (GitHub issue #1): the Xbox 360 pad's RB and LB. The port binds RB to
// CK_LTRIG, "Fire Mode [LT]" = BUTTON_ALTMODE, the gun-function toggle
// (bondmove.c bgunProcessInputAltButton), and LB to CK_DPAD_D, "Radial Menu
// [DD]" = BUTTON_RADIAL, the active menu (input.c pcjoybinds, optionsmenu.c
// menuBinds). Both are bits of the N64 pad word the shell already ORs in.
#define PD_CK_ALTMODE    PDPadL       // CK_LTRIG — "Fire Mode", the secondary function
#define PD_CK_RADIAL     PDPadDown    // CK_DPAD_D — "Radial Menu", the weapon wheel

static const PDButtonSpec kButtons[] = {
	// FIRE raised 0.7548 -> 0.7240 (D-085 addendum, the user, 2026-10-02: "raise the
	// fire button a tiny bit to eliminate overlap") - the smallest lift that
	// leaves ~4 pt between its ring and ALT's on the 17e (4.2) and the Air (4.9).
	{ "FIRE",   PDPadG,           "scope",                       0.8609, 0.7240, 46 },
	// AIM small on purpose (bean): it is a mode toggle, not a held-in-panic
	// button, and only FIRE earns the big target.
	{ "AIM",    PDPadR,           "target",                      0.9315, 0.5484, 28 },
	// USE, ALT and CROUCH share one unitY (D-085 addendum: "horizontally
	// parallel"). 0.9227 was ALT's, the middle of the three old values.
	{ "USE",    PDPadB,           "hand.raised.fill",            0.8030, 0.9227, 28 },
	{ "CROUCH", PD_CK_CROUCH,     "arrow.down",                  0.9443, 0.9227, 28 },
	{ "RELOAD", PD_CK_X_RELOAD,   "arrow.triangle.2.circlepath", 0.8521, 0.5119, 28 },
	// bean's SWAP is the 360 pad's Y, weapon swap. PD's Y is Next Weapon, which
	// is the same thumb doing the same job.
	{ "SWAP",   PD_CK_Y_NEXTWEAP, "arrow.left.arrow.right",      0.9554, 0.7214, 28 },
	// The pause/START button, parked top-right away from the fight. The three-bar
	// glyph, not a pause bar: the same button is START in the front-end menus.
	{ "START",  PDPadStart,       "line.3.horizontal",           0.9400, 0.0992, 20 },
	// D-085, the user's placements. ALT: on the USE-CROUCH line, half way between
	// them. Hidden on a GoldenEye level while the gun in hand has no second
	// function (every GoldenEye gun) - see -applyChipRules.
	{ "ALT",    PD_CK_ALTMODE,    "switch.2",                    0.8737, 0.9227, 28 },
	// WHEEL: centred between RELOAD and AIM, above them (one chip gap above
	// RELOAD's ring). Hold-and-drag like AIM (D-046): press opens the active
	// menu, the drag picks the slice, the lift chooses it. Glyph = vkQuake's
	// wheel (ios_touch.m), the user's ask.
	{ "WHEEL",  PD_CK_RADIAL,     "circle.hexagongrid.fill",     0.8918, 0.3720, 28 },
};
#define PD_NUM_BUTTONS ((int)(sizeof(kButtons) / sizeof(kButtons[0])))

// bean's aim-mode mirror: a second FIRE under the LEFT thumb while AIM is held.
// In aim mode the player is not moving, so the stick's half of the screen is
// idle and the right thumb is busy holding AIM and dragging the crosshair. It
// exists only while AIM is down. Its default position is DERIVED - FIRE's, on
// the other side of the screen - so a custom FIRE placement carries across for
// free; unitX/unitY here are unused.
static const PDButtonSpec kLeftFire =
	{ "FIRE_L", PDPadG, "scope", 0.0, 0.0, 46 };

// In a menu the gameplay chips are in the way - the dialog is centred and they
// sit on top of it - so they are hidden and this one takes their place. PD's
// menus are driven by the pointer itself (a tap picks the item under it, D-022),
// so the only thing a menu needs a CHIP for is backing out of a dialog that has
// no Cancel item of its own. It is NOT part of the layout editor: it is the only
// thing on screen while a dialog is open and the only way out of one.
static const PDButtonSpec kMenuButtons[] = {
	{ "BACK",  PDPadB, "chevron.backward", 0.9400, 0.0992, 26 },
};
#define PD_NUM_MENU_BUTTONS ((int)(sizeof(kMenuButtons) / sizeof(kMenuButtons[0])))

@interface PDTouchButtonView : UIView
@property (nonatomic) unsigned mask;
@property (nonatomic) CGFloat radius;
@property (nonatomic, copy) NSString *label;
@property (nonatomic) BOOL held;
/** A toggle chip's ON state (D-087: ALT while the gun is on its secondary
 *  function): a brighter ring and a faint fill, lighter than held. */
@property (nonatomic) BOOL engaged;
/** Draw at the editor's full-presence yellow instead of the playing look. */
@property (nonatomic) BOOL editing;
@end

@implementation PDTouchButtonView {
	CAShapeLayer *_ring;
	CALayer *_glyph;
	CGFloat _alpha;
	CGFloat _dim;   // 1.0, or bean's 0.5 for the temporary aim-mode mirror
}

/**
 * bean's chip: a thin white ring with an SF Symbol in it and nothing else.
 *
 * The look is his (touch_overlay_uikit.mm:1388-1416): stroke at the opacity
 * setting, a translucent fill only while it is held, and the glyph at rather
 * more than the ring's alpha (min(alpha * 2.2, 1)) so the figure reads at an
 * opacity that would make a filled disc invisible. No label: the glyph is the
 * face (the user, 2026-09-14).
 */
- (instancetype)initWithSpec:(const PDButtonSpec *)spec
                       scale:(CGFloat)scale
                       alpha:(CGFloat)alpha
                         dim:(CGFloat)dim
{
	CGFloat r = spec->radius * scale;
	if ((self = [super initWithFrame:CGRectMake(0, 0, r * 2, r * 2)])) {
		_mask = spec->mask;
		_radius = r;
		_label = @(spec->label);
		_alpha = alpha;
		_dim = dim;
		self.userInteractionEnabled = NO;
		self.backgroundColor = UIColor.clearColor;

		_ring = [CAShapeLayer layer];
		_ring.path = [UIBezierPath bezierPathWithOvalInRect:
			CGRectMake(1.25, 1.25, r * 2 - 2.5, r * 2 - 2.5)].CGPath;
		_ring.fillColor = UIColor.clearColor.CGColor;
		_ring.strokeColor = [UIColor colorWithWhite:1.0 alpha:alpha * dim].CGColor;
		_ring.lineWidth = 2.5;
		[self.layer addSublayer:_ring];

		// The symbol is rasterised once, here, at the size this chip is drawn -
		// a CALayer with a CGImage rather than a UIImageView, so the chip stays
		// one view with no subview to lay out - and rendered with the tint
		// DRAWN rather than asked for. -imageWithTintColor: records the tint as
		// a rendering instruction that only UIImageView honours; reading
		// .CGImage off it hands the layer the untinted template, which came out
		// as a grey ghost (measured, 2026-09-13).
		const CGFloat pt = MAX(r * 0.72, 12.0);
		const CGFloat ga = MIN(alpha * 2.2, 1.0) * dim;
		UIImageSymbolConfiguration *cfg =
			[UIImageSymbolConfiguration configurationWithPointSize:pt
			                                               weight:UIImageSymbolWeightSemibold];
		UIImage *sym = [UIImage systemImageNamed:@(spec->symbol) withConfiguration:cfg];
		if (sym) {
			const CGSize box = CGSizeMake(pt, pt);
			UIGraphicsImageRenderer *rend = [[UIGraphicsImageRenderer alloc] initWithSize:box];
			UIImage *img = [rend imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
				(void)ctx;
				const CGSize sz = sym.size;
				const CGFloat k = MIN(box.width / sz.width, box.height / sz.height);
				const CGRect dst = CGRectMake((box.width - sz.width * k) / 2,
				                              (box.height - sz.height * k) / 2,
				                              sz.width * k, sz.height * k);
				[[UIColor colorWithWhite:1.0 alpha:ga] set];
				[[sym imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] drawInRect:dst];
			}];
			_glyph = [CALayer layer];
			_glyph.contents = (__bridge id)img.CGImage;
			_glyph.contentsGravity = kCAGravityResizeAspect;
			_glyph.contentsScale = img.scale > 0 ? img.scale : PDVisionLayerScale();
			_glyph.frame = CGRectMake(r - pt / 2, r - pt / 2, pt, pt);
			[self.layer addSublayer:_glyph];
		} else {
			NSLog(@"perfectdark: [touch] no SF Symbol \"%s\" for %s", spec->symbol, spec->label);
		}
	}
	return self;
}

- (void)setHeld:(BOOL)held
{
	_held = held;
	[self restyle];
}

- (void)setEngaged:(BOOL)engaged
{
	if (_engaged == engaged) {
		return;
	}
	_engaged = engaged;
	[self restyle];
}

- (void)setEditing:(BOOL)editing
{
	_editing = editing;
	[self restyle];
}

- (void)restyle
{
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	if (_editing) {
		// The family's editor convention: everything grabbable in full-presence
		// yellow, so what can be dragged is unmistakable.
		_ring.strokeColor = [UIColor colorWithRed:1 green:0.85 blue:0.4 alpha:0.95 * _dim].CGColor;
		_ring.fillColor = UIColor.clearColor.CGColor;
	} else {
		_ring.strokeColor =
			[UIColor colorWithWhite:1.0 alpha:MIN(_alpha * ((_held || _engaged) ? 2.0 : 1.0), 1.0) * _dim].CGColor;
		_ring.fillColor = _held
			? [UIColor colorWithWhite:1.0 alpha:_alpha * 0.4 * _dim].CGColor
			: _engaged
			? [UIColor colorWithWhite:1.0 alpha:_alpha * 0.2 * _dim].CGColor
			: UIColor.clearColor.CGColor;
	}
	[CATransaction commit];
}

@end

// ---------------------------------------------------------------------------

@implementation PDTouchOverlay {
	NSMutableArray<PDTouchButtonView *> *_buttons;
	NSMutableArray<PDTouchButtonView *> *_menuButtons;
	PDTouchButtonView *_leftFire;      // bean's aim-mode mirror; hidden unless AIM is held
	CAShapeLayer *_stickBase;
	CAShapeLayer *_stickKnob;

	// Live touch tracking.
	//
	// STRONG, not weak, and that is the fix for the user's stuck stick (D-034).
	// A UITouch is owned by the UIEvent that carried it and UIKit recycles both;
	// nothing promises the object outlives the gesture, so a __weak reference
	// can read back nil at any point between touchesBegan: and touchesEnded:.
	// When it did, `t == _stickTouch` compared a live touch against nil, the
	// lift never ran, and the stick stayed drawn on screen with its last value
	// still being published - a player running forward into a wall with no way
	// to stop (the user, on device, 0.0.0.6). Holding the touch retains one small
	// object per finger for the length of a gesture, every path nils it on the
	// way out, and the per-frame watchdog below catches anything that does not.
	UITouch *_stickTouch;
	UITouch *_lookTouch;
	NSMapTable<UITouch *, PDTouchButtonView *> *_buttonTouches;

	// bean's hold-and-drag AIM (D-046, touch_overlay_uikit.mm:810/864/899): the
	// finger holding the AIM chip doubles as the aim surface, so a press and a
	// drag with ONE thumb is the whole control. The chip stays held wherever
	// the finger wanders (button touches otherwise ignore movement), and the
	// lift releases R, which is what leaves aim mode.
	UITouch *_aimDragTouch;
	CGPoint _aimDragLast;
	BOOL _aimDragArmed;   // an AIM press is live (synthetic touches have no UITouch)

	// The WEAPON WHEEL chip (D-085), hold-and-drag like AIM: the finger that
	// pressed it is a stick whose origin is where it landed, fed to the LEFT
	// stick the active menu reads (activemenutick.c, joyGetStickXOnSample) for
	// as long as the chip is held, and to nothing else - no look, no move.
	UITouch *_wheelTouch;
	CGPoint _wheelOrigin;
	CGVector _wheelStick;     // -1..1, screen axes, after the radial deadzone
	BOOL _wheelArmed;
	__weak PDTouchButtonView *_altChip;
	__weak PDTouchButtonView *_wheelChip;

	CGPoint _stickOrigin;
	CGVector _stickValue;      // curved, -1…1
	CGPoint _lookLast;
	CGVector _lookLead;        // predicted-touch lead already applied
	CGPoint _lookDownPoint;
	NSTimeInterval _lookDownTime;

	// D-086: a chip press the engine has not seen yet. A tap whose began and
	// ended reach this layer between two publishes (UIKit delivers both in one
	// pass when the system's edge-gesture gate held the touch back) would set
	// and clear its bit before any frame read it. Such a lift is LATCHED: the
	// bit goes out on the next publish and drops on the one after, so the engine
	// sees one frame down and one frame up, exactly like a pad press.
	unsigned _unpublishedMask;   // bits pressed since the last publish
	unsigned _latchMask;         // bits lifted before any publish saw them
	unsigned _latchedTaps;       // how many lifts were latched (state)

	// The double-tap roll (D-032).
	NSTimeInterval _lastStickTapTime;
	NSTimeInterval _stickDownTime;
	CGPoint _lastStickTapPoint;
	int _rollFrames;           // counts down; the roll is being played while > 0
	int _rollDir;              // -1 left, +1 right

	// Published to the engine by +publishInput, written by the touch handlers.
	unsigned _buttonMask;
	double _pendingLookX, _pendingLookY;
	int _tapConfirmFrames;

	// Menu mode (overlay 0019). _menuOpen is refreshed once a frame on the game
	// thread by -publish and read by the touch handlers, which run on the same
	// thread (SDL pumps the run loop from inside the game loop).
	BOOL _menuOpen;
	UITouch *_pointerTouch;
	CGPoint _pointerPoint;
	CGPoint _pointerDownPoint;
	NSTimeInterval _pointerDownTime;
	BOOL _pointerDown;
	BOOL _pointerValid;
	BOOL _pointerScrolled;
	CGPoint _pointerPublished;
	CGFloat _scrollResidue;
	int _pendingWheel;
	// The click a lifted tap owes the engine (D-083), played out by -publish
	// at a frozen point so a second finger cannot move it mid-click.
	int _clickFrames;
	CGPoint _clickPoint;
	BOOL _clickQueued;
	CGPoint _clickQueuedPoint;

#if !TARGET_OS_VISION
	// UIImpactFeedbackGenerator is unavailable on visionOS — the headset has no
	// haptics. The Haptics setting row still exists and still persists; it just
	// drives nothing there.
	UIImpactFeedbackGenerator *_haptics;
#endif
	// The settings gear is a SIBLING of this view in the window, not a subview
	// (bean, AttachTouchOverlay). It has to be: this view hides itself when a
	// pad connects or when the controls are turned off, and a hidden view's
	// subviews receive nothing — which is exactly why there was no way to reach
	// Settings in the headset, where a pad is usually paired (the user, 0.0.0.5).
	UIButton *_gear;
	// The corner-geometry log's change detector (D-076).
	NSString *_lastGeo;
	uint32_t _geoTicks;
	CFTimeInterval _gameplaySince;
	CGFloat _scale;

	// Settings, read once and kept, not read per touch event (D-034).
	//
	// -addLookFrom:to: is called once per COALESCED touch - ten or more times a
	// frame during a fast drag at 120 Hz - and it was doing three
	// NSUserDefaults lookups every time. NSUserDefaults is a cached read, but it
	// is still an objc_msgSend into a dictionary and an NSNumber unbox per call,
	// on the GAME thread, inside the frame. Cached here and refreshed by
	// -applySettings (every path that writes one of these calls it) plus a
	// belt-and-braces refresh every 60th publish.
	CGFloat _cLookDegX, _cLookDegY, _cLookInvert;
	BOOL _cDoubleTapRoll;
	NSInteger _cControlStyle;
	uint32_t _publishes;

	// Deferred stick chrome (D-034): where the stick layers WANT to be. A touch
	// stream writes these; -publish moves the layers once a frame. Moving a
	// CALayer opens a CoreAnimation transaction that commits at the end of the
	// current run-loop turn - and SDL pumps that run loop from inside the game
	// frame, so a per-event move was a render-server round trip per touch
	// sample rather than one per frame.
	CGPoint _stickChromeOrigin;
	CGPoint _stickChromeKnob;
	BOOL _stickChromeVisible;
	BOOL _stickChromeDirty;

	// One log line per hide, not one per frame.
	BOOL _releasedWhileHidden;
	// The routing watchdog's latch: one report per episode, not one a second
	// (D-041).
	BOOL _routeWasWrong;
	// D-041 round 2: proof that UIKit is DELIVERING anything at all. The user's
	// second report had route_ok=1 and the watchdog silent - the routing was
	// fine and the touches never arrived - so the next question is not "where
	// would a touch go" but "did one ever come". -hitTest:withEvent: is called
	// by UIKit for every delivery and by our own probes with a nil event, so
	// only the non-nil ones are counted.
	uint32_t _uiHitTests;
	uint32_t _uiTouchesBegan;
	uint32_t _gearTaps;

	// What was last HANDED TO THE ENGINE, which is the only thing that can be
	// stuck. _buttonMask and _stickValue are the layer's own working state and
	// a touch stream rewrites them between frames; these two are written
	// wherever inputIosPadSet* is called and nowhere else.
	unsigned _sentMask;
	CGVector _sentStick;

	// Layout editing.
	BOOL _editing;
	UIView *_editBar;
	UISlider *_editSlider;
	UILabel *_editPct;
	__weak PDTouchButtonView *_dragChip;
	CGVector _dragGrab;                 // finger-to-centre offset at touch-down
	CGPoint _dragUnit;                  // where the drag has got to, unit coords
	CGPoint _dragStartUnit;             // ...and where it started (a tap is not a move)

	// D-088 (Shipwright D-038): chips the player hid. The set is the cache of the
	// `hidden` flags in the layout store, rebuilt with the other cached settings;
	// the eye badge rides the SELECTED chip only (the last one touched).
	NSMutableSet<NSString *> *_userHidden;
	NSString *_editSelected;
	UIView *_hideBadge;
	UIImageView *_hideBadgeIcon;
}

/**
 * Is a pad connected right now?
 *
 * `PD_FAKE_PAD=1` in the environment forces a yes. There is no way to pair a
 * controller with a simulator from a script, so that is the only way to test
 * the auto-hide path from `sim-validate.sh` - except that the iOS simulator
 * already reports a virtual "Gamepad" of its own, which is why the gate has to
 * force the overlay back ON (`touch on`) to test anything else.
 */
/**
 * `PD_TOUCH_UNBATCHED=1`: do it the way 0.0.0.6 did, for the A/B (M-032).
 *
 * The per-event work this round moved off the frame - three NSUserDefaults
 * reads per coalesced look sample, and a CoreAnimation transaction per stick
 * sample - cannot be measured against a build that has no instrument to measure
 * it with. So the old path stays reachable behind an environment variable, and
 * the before-and-after are one binary and one run with the same seed and the
 * same stream. Dev instrument: nothing in the app ever sets it.
 */
static BOOL pdTouchUnbatched(void)
{
	static int on = -1;
	if (on < 0) {
		const char *env = getenv("PD_TOUCH_UNBATCHED");
		on = (env && *env && *env != '0') ? 1 : 0;
		if (on) {
			NSLog(@"perfectdark: [touch] PD_TOUCH_UNBATCHED=1 — 0.0.0.6's per-event path");
		}
	}
	return on ? YES : NO;
}

// -1 = ask the world, 0/1 = the bridge is pretending (PDTouchOverlaySetFakePad).
static int sFakePadOverride = -1;

void PDTouchOverlaySetFakePad(int state)
{
	sFakePadOverride = (state < 0) ? -1 : (state ? 1 : 0);
	NSLog(@"perfectdark: [touch] fake pad override = %d", sFakePadOverride);
}

BOOL PDTouchOverlayAnyPadConnected(void)
{
	if (sFakePadOverride >= 0) {
		return sFakePadOverride ? YES : NO;
	}
	if (GCController.controllers.count > 0) {
		return YES;
	}
	static int fake = -1;
	if (fake < 0) {
		const char *env = getenv("PD_FAKE_PAD");
		fake = (env && *env && *env != '0') ? 1 : 0;
		if (fake) {
			NSLog(@"perfectdark: [touch] PD_FAKE_PAD=1 — pretending a pad is connected");
		}
	}
	return fake ? YES : NO;
}

static __weak PDTouchOverlay *sCurrent;

+ (PDTouchOverlay *)current { return sCurrent; }

+ (instancetype)installInWindow:(UIWindow *)window
{
	PDTouchOverlay *v = [[PDTouchOverlay alloc] initWithFrame:window.bounds];
	v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	// The pad's state is ASKED FOR here rather than waited for (D-034).
	//
	// PDController pushes -padConnected: on every connect/disconnect, but it
	// starts before there is a window and therefore before there is an overlay:
	// its first push lands on `PDTouchOverlay.current`, which is nil, and a pad
	// that was already paired at launch never generates another notification.
	// So the chips stayed on screen through the whole intro with a controller
	// connected and only vanished when something else happened to push the flag
	// (the user, on device, 0.0.0.6). The overlay asks GameController itself the
	// moment it exists, which is also the first moment it could be seen.
	v.padConnected = PDTouchOverlayAnyPadConnected();
	[window addSubview:v];
	[window bringSubviewToFront:v];
	sCurrent = v;
	PDShell.shared.touchOverlay = v;
	[v installGearInWindow:window];
	// The charter's evidence rule: a UIKit placement is only proven by the view
	// logging its own frame.
	// No UIScreen on visionOS: the window's own trait collection is where the
	// points-to-pixels scale lives there (and it is 2.0).
#if TARGET_OS_VISION
	const double installScale = window.traitCollection.displayScale;
#else
	const double installScale = window.screen.nativeScale;
#endif
	NSLog(@"perfectdark: [touch] overlay installed frame=%@ window=%@ scale=%.2f",
		NSStringFromCGRect(v.frame), NSStringFromCGRect(window.bounds), installScale);
	return v;
}

- (instancetype)initWithFrame:(CGRect)frame
{
	if ((self = [super initWithFrame:frame])) {
		self.multipleTouchEnabled = YES;
		self.backgroundColor = UIColor.clearColor;
		self.opaque = NO;
		// Strong keys, same reason as the stick and look touches above: a weak
		// key that zeroes mid-gesture takes the entry with it and leaves the
		// chip's mask bit held with nothing left to release it.
		_buttonTouches = [NSMapTable strongToStrongObjectsMapTable];
		_buttons = [NSMutableArray array];
		_menuButtons = [NSMutableArray array];
		_scale = 1.0;

		_stickBase = [CAShapeLayer layer];
		_stickBase.fillColor = UIColor.clearColor.CGColor;
		_stickBase.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.5].CGColor;
		_stickBase.lineWidth = 2.5;
		_stickBase.hidden = YES;
		[self.layer addSublayer:_stickBase];

		_stickKnob = [CAShapeLayer layer];
		_stickKnob.fillColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
		_stickKnob.hidden = YES;
		[self.layer addSublayer:_stickKnob];

		[self applySettings];
	}
	return self;
}

/**
 * bean's gear (touch_overlay_uikit.mm:1598-1619): 34x34, white at 0.55 on black
 * at 0.30, a sibling of the overlay.
 */
- (void)installGearInWindow:(UIWindow *)window
{
	UIButton *gear = [UIButton buttonWithType:UIButtonTypeSystem];
	[gear setImage:[UIImage systemImageNamed:@"gearshape.fill"] forState:UIControlStateNormal];
	gear.tintColor = [UIColor colorWithWhite:1.0 alpha:0.55];
	gear.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.30];
	gear.layer.cornerRadius = 17.0;
	gear.translatesAutoresizingMaskIntoConstraints = NO;
	[gear addTarget:self action:@selector(openSettings) forControlEvents:UIControlEventTouchUpInside];
	[window addSubview:gear];
	_gear = gear;
	[self pinGearInWindow:window];
	[window layoutIfNeeded];
	NSLog(@"perfectdark: [touch] gear installed frame=%@", NSStringFromCGRect(gear.frame));
}

/**
 * Where the gear sits (D-076).
 *
 * iPhone: PAUSE's default spot MIRRORED - the same unit y of the full window
 * and 1 - its unit x - so the two are level and equally far in from their
 * corners on every iPhone shape. It is derived from the START row of kButtons,
 * the same numbers PAUSE's own default is drawn from, so it cannot drift from
 * it. It used to hang off the window's safe area (+12/+12, bean), which put
 * it level with nothing in particular - and since the UIScene adoption (D-038)
 * SDL's window is born sceneless and grafted onto the scene, and a grafted
 * window reports the PORTRAIT panel's insets while it is laid out landscape
 * (top 47 / left 0 on a 17e in landscape): the gear dropped by the portrait
 * top inset and slid to the edge. A player who moved PAUSE keeps their spot;
 * the gear follows the default, so it stays where the player learned it.
 *
 * visionOS: unchanged, the safe area's top-left at +12/+12 - a window in the
 * shared space has no insets and nothing grafted, and its corner is not
 * shaped by a phone's bezel.
 */
- (void)pinGearInWindow:(UIWindow *)window
{
	UIButton *gear = _gear;
	if (!gear || gear.superview != window) {
		return;
	}
	NSMutableArray<NSLayoutConstraint *> *c = [NSMutableArray arrayWithObjects:
		[gear.widthAnchor constraintEqualToConstant:34],
		[gear.heightAnchor constraintEqualToConstant:34], nil];
#if TARGET_OS_VISION
	UILayoutGuide *safe = window.safeAreaLayoutGuide;
	[c addObject:[gear.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12]];
	[c addObject:[gear.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12]];
#else
	const PDButtonSpec *pause = [self specForLabel:@"START"];
	NSAssert(pause, @"no START row in kButtons");
	const CGFloat ux = pause ? 1.0 - pause->unitX : 0.06;
	const CGFloat uy = pause ? pause->unitY : 0.0992;
	// Multiples of the window's own trailing/bottom edges, i.e. of its width and
	// height (its leading/top are 0) - the same `u * bounds` the chips use.
	[c addObject:[NSLayoutConstraint constraintWithItem:gear attribute:NSLayoutAttributeCenterX
		relatedBy:NSLayoutRelationEqual toItem:window attribute:NSLayoutAttributeTrailing
		multiplier:ux constant:0]];
	[c addObject:[NSLayoutConstraint constraintWithItem:gear attribute:NSLayoutAttributeCenterY
		relatedBy:NSLayoutRelationEqual toItem:window attribute:NSLayoutAttributeBottom
		multiplier:uy constant:0]];
#endif
	[NSLayoutConstraint activateConstraints:c];
}

- (void)openSettings
{
	_gearTaps++;
	NSLog(@"perfectdark: [settings] gear tapped at %.3f", CACurrentMediaTime());
	[PDSettingsViewController present];
}

// ---------------------------------------------------------------------------
// Where each chip sits: the table, unless the player dragged it somewhere else.
//
// bean's representation (touch_overlay_uikit.mm:378-382): unit coordinates of
// the FULL view. The table and the editor's output are the same numbers, so the
// table IS the reset and a layout carried between devices keeps its shape.

/** The stored unit position for one label, or the table's. */
static CGPoint pdUnitForLabel(NSString *label, CGPoint def)
{
	NSDictionary *all = [NSUserDefaults.standardUserDefaults dictionaryForKey:PDDefButtonLayout];
	id entry = all[label];
	if (![entry isKindOfClass:NSDictionary.class]) {
		return def;
	}
	NSNumber *x = ((NSDictionary *)entry)[@"x"];
	NSNumber *y = ((NSDictionary *)entry)[@"y"];
	if (![x isKindOfClass:NSNumber.class] || ![y isKindOfClass:NSNumber.class]) {
		return def;
	}
	// NOT clamped (D-089, the user: "get rid of those entirely ... a reset can
	// always fix it"): the editor may park a chip's centre past an edge, so a
	// saved unit can be below 0 or above 1 and must come back exactly as saved.
	// Only a value that cannot be a position at all falls back to the table.
	// (a hand-edited 1e308 would turn the centre into inf once scaled)
	if (!isfinite(x.doubleValue) || !isfinite(y.doubleValue)
	    || fabs(x.doubleValue) > 100.0 || fabs(y.doubleValue) > 100.0) {
		return def;
	}
	return CGPointMake(x.doubleValue, y.doubleValue);
}

- (void)storeUnit:(CGPoint)u forLabel:(NSString *)label
{
	NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
	NSMutableDictionary *all = [([d dictionaryForKey:PDDefButtonLayout] ?: @{}) mutableCopy];
	NSMutableDictionary *entry = [NSMutableDictionary dictionary];
	if ([all[label] isKindOfClass:NSDictionary.class]) {
		[entry addEntriesFromDictionary:all[label]];   // keep its `hidden` flag (D-088)
	}
	entry[@"x"] = @(u.x);
	entry[@"y"] = @(u.y);
	all[label] = entry;
	[d setObject:all forKey:PDDefButtonLayout];
}

/**
 * D-088: may this chip be hidden? Not START - with no pad it is the only way to
 * pause, and so to reach anything else. The gear and the move stick are not
 * chips and never had a badge. Everything else may go (Shipwright D-038 keeps
 * only its menu button; ours is START).
 */
static BOOL pdLabelHideable(NSString *label)
{
	return label.length && ![label isEqualToString:@"START"];
}

/** The hidden flags, read from the same store as the positions. */
static NSMutableSet<NSString *> *pdHiddenLabels(void)
{
	NSMutableSet<NSString *> *out = [NSMutableSet set];
	NSDictionary *all = [NSUserDefaults.standardUserDefaults dictionaryForKey:PDDefButtonLayout];
	for (NSString *label in all) {
		id entry = all[label];
		if (![label isKindOfClass:NSString.class] || ![entry isKindOfClass:NSDictionary.class]) {
			continue;
		}
		id h = ((NSDictionary *)entry)[@"hidden"];
		if ([h respondsToSelector:@selector(boolValue)] && [h boolValue] && pdLabelHideable(label)) {
			[out addObject:label];
		}
	}
	return out;
}

/** Write one chip's hidden flag; a shown chip with no position loses its entry
 *  altogether, so it keeps following the built-in table. */
- (void)storeHidden:(BOOL)hidden forLabel:(NSString *)label
{
	NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
	NSMutableDictionary *all = [([d dictionaryForKey:PDDefButtonLayout] ?: @{}) mutableCopy];
	NSMutableDictionary *entry = [NSMutableDictionary dictionary];
	if ([all[label] isKindOfClass:NSDictionary.class]) {
		[entry addEntriesFromDictionary:all[label]];
	}
	if (hidden) {
		entry[@"hidden"] = @YES;
	} else {
		[entry removeObjectForKey:@"hidden"];
	}
	if (entry.count) {
		all[label] = entry;
	} else {
		[all removeObjectForKey:label];
	}
	[d setObject:all forKey:PDDefButtonLayout];
}

/** Hidden by the player (D-088) - not the menu split or ALT's GoldenEye rule. */
- (BOOL)userHid:(PDTouchButtonView *)b
{
	return b != nil && [_userHidden containsObject:b.label];
}

/** The spec a live chip was built from, by label. */
- (const PDButtonSpec *)specForLabel:(NSString *)label
{
	for (int i = 0; i < PD_NUM_BUTTONS; i++) {
		if ([label isEqualToString:@(kButtons[i].label)]) {
			return &kButtons[i];
		}
	}
	for (int i = 0; i < PD_NUM_MENU_BUTTONS; i++) {
		if ([label isEqualToString:@(kMenuButtons[i].label)]) {
			return &kMenuButtons[i];
		}
	}
	return [label isEqualToString:@(kLeftFire.label)] ? &kLeftFire : NULL;
}

/** Where a chip's centre goes, in points - wherever the player put it (D-089). */
- (CGPoint)centreForLabel:(NSString *)label radius:(CGFloat)radius
{
	CGPoint def;
	if ([label isEqualToString:@(kLeftFire.label)]) {
		// Derived, not tabled: FIRE mirrored, so a custom FIRE placement carries
		// across for free (bean). An explicit FIRE_L entry still wins.
		CGPoint fire = pdUnitForLabel(@"FIRE", CGPointMake(kButtons[0].unitX, kButtons[0].unitY));
		def = CGPointMake(1.0 - fire.x, fire.y);
	} else {
		const PDButtonSpec *spec = [self specForLabel:label];
		def = spec ? CGPointMake(spec->unitX, spec->unitY) : CGPointMake(0.5, 0.5);
	}
	// Unit x bounds and nothing else, exactly as bean does it
	// (centreForButton). NO safe-area clamp on the way out: his table is
	// already inside the usable area of a notched phone - it was exported from
	// one - and clamping pulled CROUCH and SWAP a chip's width in from where he
	// put them, which is not parity (measured on lane 3, hit tests reported
	// "look" where those two chips should have been). The editor's drop has no
	// clamp either since D-089: the player may park a chip anywhere, under the
	// notch or half off the panel, and Reset brings it back.
	(void)radius;
	CGPoint u = pdUnitForLabel(label, def);
	CGSize sz = self.bounds.size;
	return CGPointMake(u.x * sz.width, u.y * sz.height);
}

/** bean: the mirrored FIRE exists only while AIM is held. */
- (BOOL)leftFireVisible
{
	return !_editing && !_menuOpen && (_buttonMask & PDPadR) != 0 && ![self userHid:_leftFire];
}

/** The AIM chip, by its mask rather than its label (a custom layout moves the
 *  chip, never its bit). PDPadR is what the engine reads as the aim button
 *  under the PC control mode (bondmove.c:1272, `aimbuttons = R_TRIG`). */
- (BOOL)isAimChip:(PDTouchButtonView *)b
{
	return b != nil && b != _leftFire && (b.mask & PDPadR) != 0;
}

/** The AIM finger's drag, fed to the same absolute view-angle path the look
 *  drag uses - which in aim mode is exactly what moves PD's crosshair. */
- (void)addAimDragTo:(CGPoint)p
{
	[self addLookFrom:_aimDragLast to:p];
	_aimDragLast = p;
}

/** Drop the aim drag's tracking (the chip's own release is the mask bit). */
- (void)clearAimDrag
{
	_aimDragTouch = nil;
	_aimDragArmed = NO;
}

// --- a press the engine never saw (D-086) ----------------------------------
// On by default; the bridge's `touch latch off` turns it off so the bug can be
// shown on the same build (artifacts/sim/chips-fix/00-ALT-DIAGNOSIS.txt).
static BOOL sTapLatch = YES;

+ (void)setTapLatchEnabled:(BOOL)on { sTapLatch = on; }
+ (BOOL)tapLatchEnabled { return sTapLatch; }

/**
 * A chip's finger came off: drop its bits, unless no publish has carried them
 * yet - then they are latched for exactly one publish (D-086). Every LIFT goes
 * through here (touchesEnded, the bridge's tap: latch:YES; touchesCancelled and
 * the watchdog's dead touches: latch:NO, dropped at once); the
 * paths that DROP a chip on purpose (the editor, a hidden layer, a chip being
 * hidden) clear _buttonMask directly and are not presses.
 */
- (void)liftChip:(PDTouchButtonView *)b latch:(BOOL)latch
{
	b.held = NO;
	_buttonMask &= ~b.mask;
	const unsigned unseen = b.mask & _unpublishedMask;
	if (!latch) {
		// A CANCELLED touch (a system edge gesture took it, or the watchdog found
		// it dead) is never a tap - the same rule as the menu pointer (D-083).
		// Latching it would be one frame of FIRE (a shot), WHEEL or AIM nobody
		// asked for (D-086 review).
		_latchMask &= ~b.mask;
		_unpublishedMask &= ~b.mask;
		return;
	}
	if (unseen && sTapLatch) {
		_latchMask |= unseen;
		_latchedTaps++;
		NSLog(@"perfectdark: [touch] %@ lifted before any frame saw it - latched for one frame (D-086, #%u)",
			b.label, _latchedTaps);
		if (_latchedTaps <= 20) {
			[self noteWatchdog:[NSString stringWithFormat:@"LATCH %@(began+ended between two frames, #%u) ",
				b.label, _latchedTaps]];
		}
	}
}

// --- the weapon wheel (D-085) ------------------------------------------------
// Full deflection is this far from where the finger landed. The active menu
// only reads a DIRECTION (a slice once |x| or |y| > 20 of 127, eight sectors at
// tan 15 degrees, activemenutick.c), so the radius is how far a thumb travels
// before a slice lights: 32 * 0.15 deadzone = 5 pt of jitter ignored, and the
// slice is chosen ~7 pt out. 48 until the D-085 addendum (the user: "increase
// weapon wheel sensitivity a bit").
static const CGFloat kWheelRadius = 32.0;

/** The WHEEL chip, by its bit (a custom layout moves the chip, never its bit). */
- (BOOL)isWheelChip:(PDTouchButtonView *)b
{
	return b != nil && b != _leftFire && (b.mask & PD_CK_RADIAL) != 0;
}

- (void)moveWheelTo:(CGPoint)p
{
	CGVector raw = CGVectorMake((p.x - _wheelOrigin.x) / kWheelRadius,
	                            (p.y - _wheelOrigin.y) / kWheelRadius);
	const CGFloat mag = sqrt(raw.dx * raw.dx + raw.dy * raw.dy);
	if (mag <= kStickDeadzone) {
		_wheelStick = CGVectorMake(0, 0);
		return;
	}
	// The family's radial deadzone, rescaled so it still reaches 1; linear past
	// it - the menu wants a direction, not a curve.
	const CGFloat unit = MIN(1.0, (mag - kStickDeadzone) / (1.0 - kStickDeadzone));
	_wheelStick = CGVectorMake(raw.dx / mag * unit, raw.dy / mag * unit);
}

/** Drop the wheel's drag (the chip's own release is the mask bit). */
- (void)clearWheel
{
	_wheelTouch = nil;
	_wheelArmed = NO;
	_wheelStick = CGVectorMake(0, 0);
}

/**
 * Per-frame chip rules that depend on the ENGINE (D-085): the secondary-function
 * chip is hidden on a GoldenEye level while the gun in hand has no second
 * function - all of GoldenEye's guns (geguns.c strips the hosts' second
 * functions, geslappers.c the fists') - and shown again the moment a gun that
 * has one is drawn (Mod.GePlusPdGuns can list Perfect Dark's own guns in a GE
 * Plus arena). Everywhere else it is always shown, like every other chip.
 * Called from -refreshEngineChrome, after the menu split, on the game thread.
 */
- (void)applyChipRules
{
	PDTouchButtonView *alt = _altChip;
	if (!alt || _editing) {
		return;
	}
	// D-087: ALT shows which function the gun is on. A melee secondary (the
	// Falcon 2 / DY357 PISTOL WHIP, the fists) draws NO sight in Perfect Dark
	// (currentPlayerGetSight, g_ModSightMeleeNone), and the choice is kept per
	// weapon across missions - an odd number of ALT taps left the user with no
	// crosshair and nothing on screen saying why.
	int gunfunc = 0;
	const BOOL armed = playerIosGunState(&gunfunc) > 0;
	alt.engaged = armed && gunfunc == 1;
	const BOOL suppressed = playerIosOnGoldenEyeLevel() && !playerIosGunHasSecondary();
	const BOOL hide = _menuOpen || suppressed || [self userHid:alt];
	if (alt.hidden == hide) {
		return;
	}
	alt.hidden = hide;
	if (hide && alt.held) {
		alt.held = NO;
		_buttonMask &= ~alt.mask;
		_latchMask &= ~alt.mask;
		_unpublishedMask &= ~alt.mask;
		for (UITouch *t in [[_buttonTouches keyEnumerator] allObjects]) {
			if ([_buttonTouches objectForKey:t] == alt) {
				[_buttonTouches removeObjectForKey:t];
			}
		}
	}
	if (!_menuOpen) {
		NSLog(@"perfectdark: [touch] ALT chip %@ (GoldenEye level %d, gun has a second function %d, hidden by the player %d)",
			hide ? @"hidden" : @"shown", playerIosOnGoldenEyeLevel(), playerIosGunHasSecondary(), (int)[self userHid:alt]);
	}
}

// ---------------------------------------------------------------------------
// Layout editing — bean's bar (touch_overlay_uikit.mm:1006-1090)

- (BOOL)layoutEditing { return _editing; }

- (void)beginLayoutEditing
{
	if (_editing) {
		return;
	}
	_editing = YES;

	// Anything held when the editor opens would be held for ever: the touch
	// that releases it is about to become a drag.
	for (PDTouchButtonView *b in _buttons) {
		if (b.held) { b.held = NO; }
	}
	_buttonMask = 0;
	_stickTouch = nil;
	_lookTouch = nil;
	[self clearAimDrag];
	[self clearWheel];
	_stickValue = CGVectorMake(0, 0);
	_pendingLookX = _pendingLookY = 0;
	_rollFrames = 0;
	[self hideStickChrome];
	inputIosPadSet(0, 0, 0);
	if (inputIosPointerIsActive()) {
		inputIosPointerClear();
	}

	// The layer may be hidden (mode "off", or auto with the simulator's virtual
	// pad connected) - it has to be visible to be edited, and goes back to
	// whatever the setting says when the editor closes.
	self.hidden = NO;
	_gear.hidden = YES;
	_editSelected = nil;   // no badge until a chip is touched (Shipwright D-038)

	[self buildEditChrome];
	[self applyEditChrome];
	[self setNeedsLayout];
	NSLog(@"perfectdark: [touch] layout editor open (%d chips)", PD_NUM_BUTTONS);
}

- (void)endLayoutEditing
{
	if (!_editing) {
		return;
	}
	[self commitDrag];
	_editing = NO;
	_dragChip = nil;
	[_editBar removeFromSuperview];
	_editBar = nil;
	_editSlider = nil;
	_editPct = nil;
	_editSelected = nil;
	[_hideBadge removeFromSuperview];
	_hideBadge = nil;
	_hideBadgeIcon = nil;
	_gear.hidden = NO;
	NSLog(@"perfectdark: [touch] layout editor closed");
	// applySettings puts the opacity, the visibility rule and the menu/gameplay
	// chip split back the way the settings say they should be.
	[self applySettings];
}

/** Reset: the built-in table AND scale 1.0, as bean's red pill does. */
- (void)resetLayout
{
	[NSUserDefaults.standardUserDefaults setObject:@{} forKey:PDDefButtonLayout];
	[NSUserDefaults.standardUserDefaults setFloat:1.0f forKey:PDDefButtonScale];
	NSLog(@"perfectdark: [touch] layout reset to the built-in table at scale 1.0, every chip shown");
	_editSlider.value = 1.0f;
	[self applySettings];
	[self updateScalePct];
}

/** Reset / a live size slider / Done, and no instruction text. */
- (void)buildEditChrome
{
	if (_editBar) {
		[self bringSubviewToFront:_editBar];
		return;
	}

	UIView *bar = [[UIView alloc] initWithFrame:CGRectZero];
	bar.translatesAutoresizingMaskIntoConstraints = NO;
	[self addSubview:bar];
	_editBar = bar;

	UIButton *(^pill)(NSString *, UIColor *, SEL) = ^UIButton *(NSString *sym, UIColor *bg, SEL act) {
		UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
		b.backgroundColor = bg;
		[b setImage:[[UIImage systemImageNamed:sym]
			imageWithConfiguration:[UIImageSymbolConfiguration
				configurationWithPointSize:17 weight:UIImageSymbolWeightBold]]
			forState:UIControlStateNormal];
		b.tintColor = UIColor.whiteColor;
		b.layer.cornerRadius = 21;
		b.translatesAutoresizingMaskIntoConstraints = NO;
		[b addTarget:self action:act forControlEvents:UIControlEventTouchUpInside];
		[bar addSubview:b];
		return b;
	};
	UIButton *reset = pill(@"arrow.uturn.backward",
		[UIColor colorWithRed:0.85 green:0.20 blue:0.22 alpha:0.95], @selector(resetLayout));
	UIButton *done = pill(@"checkmark",
		[UIColor colorWithRed:0.18 green:0.78 blue:0.34 alpha:0.95], @selector(endLayoutEditing));

	UISlider *sl = [UISlider new];
	sl.minimumValue = 0.6f;
	sl.maximumValue = 1.8f;
	sl.value = MIN(1.8f, MAX(0.6f, PDDefFloat(PDDefButtonScale)));
	sl.minimumTrackTintColor = [UIColor colorWithWhite:1 alpha:0.9];
	sl.translatesAutoresizingMaskIntoConstraints = NO;
	[sl addTarget:self action:@selector(editScaleChanged:) forControlEvents:UIControlEventValueChanged];
	[bar addSubview:sl];
	_editSlider = sl;

	UILabel *pct = [UILabel new];
	pct.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightSemibold];
	pct.textColor = [UIColor colorWithWhite:1 alpha:0.9];
	pct.translatesAutoresizingMaskIntoConstraints = NO;
	[bar addSubview:pct];
	_editPct = pct;
	[self updateScalePct];

	UILayoutGuide *safe = self.safeAreaLayoutGuide;
	[NSLayoutConstraint activateConstraints:@[
		[bar.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:14],
		[bar.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-14],
		[bar.heightAnchor constraintEqualToConstant:42],
		[bar.trailingAnchor constraintEqualToAnchor:done.trailingAnchor],
		[reset.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor],
		[reset.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
		[reset.widthAnchor constraintEqualToConstant:42],
		[reset.heightAnchor constraintEqualToConstant:42],
		[sl.leadingAnchor constraintEqualToAnchor:reset.trailingAnchor constant:16],
		[sl.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
		[sl.widthAnchor constraintEqualToConstant:220],
		[pct.centerXAnchor constraintEqualToAnchor:sl.centerXAnchor],
		[pct.bottomAnchor constraintEqualToAnchor:sl.topAnchor constant:-2],
		[done.leadingAnchor constraintEqualToAnchor:sl.trailingAnchor constant:16],
		[done.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
		[done.widthAnchor constraintEqualToConstant:42],
		[done.heightAnchor constraintEqualToConstant:42],
	]];
}

- (void)updateScalePct
{
	_editPct.text = [NSString stringWithFormat:@"%.0f%%", PDDefFloat(PDDefButtonScale) * 100.0];
}

/** The slider scales every chip live, as bean's does. */
- (void)editScaleChanged:(UISlider *)sl
{
	[NSUserDefaults.standardUserDefaults setFloat:sl.value forKey:PDDefButtonScale];
	[self updateScalePct];
	[self applySettings];
}

/** In the editor every gameplay chip is on screen, menu or no menu. */
- (void)applyEditChrome
{
	for (PDTouchButtonView *b in _buttons) {
		b.hidden = NO;
		b.editing = YES;
		b.alpha = [self userHid:b] ? kHiddenGhostAlpha : 1.0;
	}
	_leftFire.hidden = NO;
	_leftFire.editing = YES;
	_leftFire.alpha = [self userHid:_leftFire] ? kHiddenGhostAlpha : 1.0;
	for (PDTouchButtonView *b in _menuButtons) {
		b.hidden = YES;
	}
	[self hideStickChrome];
	[self bringSubviewToFront:_editBar];
}

/** The chip under a finger in edit mode, nearest centre first. */
- (nullable PDTouchButtonView *)editChipAtPoint:(CGPoint)p
{
	PDTouchButtonView *best = nil;
	CGFloat bestD2 = CGFLOAT_MAX;
	NSMutableArray<PDTouchButtonView *> *all = [_buttons mutableCopy];
	if (_leftFire) {
		[all addObject:_leftFire];
	}
	for (PDTouchButtonView *b in all) {
		CGFloat dx = p.x - b.center.x, dy = p.y - b.center.y;
		CGFloat d2 = dx * dx + dy * dy;
		CGFloat r = b.radius + 12.0;
		if (d2 <= r * r && d2 < bestD2) {
			best = b;
			bestD2 = d2;
		}
	}
	return best;
}

/**
 * Drag in progress: move the chip on screen only.
 *
 * Nothing is written until the finger lifts (bean: "drag commits on touch-up"),
 * so a drag that is dragged back where it came from costs one defaults write,
 * not sixty.
 */
- (void)dragChipTo:(CGPoint)p
{
	PDTouchButtonView *b = _dragChip;
	if (!b) {
		return;
	}
	CGSize sz = self.bounds.size;
	// No clamp of any kind (D-089, the user's rule): not the safe area, not the
	// panel's edge, not another chip. The centre follows the finger, so a chip
	// can sit at x = 0, on top of a default, or half off the bottom; Reset is
	// the way back from anywhere.
	const CGFloat cx = p.x + _dragGrab.dx;
	const CGFloat cy = p.y + _dragGrab.dy;
	b.center = CGPointMake(cx, cy);
	if (sz.width > 0 && sz.height > 0) {
		_dragUnit = CGPointMake(cx / sz.width, cy / sz.height);
	}
	[self placeHideBadge];
}

/** The finger lifted: the chip's new place becomes the stored one. */
- (void)commitDrag
{
	PDTouchButtonView *b = _dragChip;
	if (!b) {
		return;
	}
	b.held = NO;
	_dragChip = nil;
	// A touch that only selected the chip (to reach its eye badge, D-088) is not
	// a move: storing it would pin the chip where the table has it today and
	// stop it following a later default (the editor saves only what was moved).
	if (fabs(_dragUnit.x - _dragStartUnit.x) < 0.0005 && fabs(_dragUnit.y - _dragStartUnit.y) < 0.0005) {
		return;
	}
	[self storeUnit:_dragUnit forLabel:b.label];
	NSLog(@"perfectdark: [touch] %@ moved to unit %.3f,%.3f", b.label, _dragUnit.x, _dragUnit.y);
}

// ---------------------------------------------------------------------------
// D-088: hide a chip from the layout editor - Shipwright's eye badge (D-038).
//
// The badge sits just OUTSIDE the selected chip's ring, pointing away from the
// chips within 150 pt (so a tight cluster spreads its badges outward rather
// than onto a neighbour) or, for a lone chip, toward the middle of the screen;
// clamped on-screen. eye.slash.fill = tap to hide; eye.fill = tap to show. The
// badge is hit-tested BEFORE the chip body, and the body stays the drag handle.

- (CGPoint)hideBadgeCentreFor:(PDTouchButtonView *)chip
{
	const CGPoint c = chip.center;
	// The whole view, not the safe area: since D-089 a chip may sit under the
	// notch or past an edge, and its badge must still find a spot on the panel
	// beside the chip's visible part rather than be pushed back into the ring.
	CGRect bounds = self.bounds;
	NSMutableArray<PDTouchButtonView *> *all = [_buttons mutableCopy];
	if (_leftFire) {
		[all addObject:_leftFire];
	}
	CGFloat sx = 0, sy = 0;
	int n = 0;
	for (PDTouchButtonView *o in all) {
		const CGFloat d = hypot(o.center.x - c.x, o.center.y - c.y);
		if (o != chip && d > 1.0 && d < 150.0) {
			sx += o.center.x;
			sy += o.center.y;
			n++;
		}
	}
	CGFloat dx, dy;
	if (n > 0) {
		dx = c.x - sx / n;
		dy = c.y - sy / n;
		const CGFloat len = hypot(dx, dy);
		if (len < 1.0) {
			dx = 0; dy = -1;
		} else {
			dx /= len; dy /= len;
		}
	} else {
		dx = c.x > CGRectGetMidX(bounds) ? -0.7071 : 0.7071;
		dy = c.y > CGRectGetMidY(bounds) ? -0.7071 : 0.7071;
	}
	const CGFloat off = chip.radius + kHideBadgeRadius - 2.0;   // inner edge ~tangent to the ring
	const CGFloat m = kHideBadgeRadius + 4.0;
	const CGRect inner = CGRectInset(bounds, m, m);
	// Shipwright clamps the preferred spot on-screen. Our right-hand chips sit
	// at the edge, where the clamp slid the badge back INTO the ring (SWAP, lane
	// 3) - the body would toggle instead of drag. So walk round the ring from the
	// preferred direction, 15 degrees either way at a time, and take the first
	// on-screen spot clear of every other chip; in a cluster too tight for that
	// (ALT between USE and CROUCH on the bottom edge) the on-screen spot that
	// overlaps its neighbours least. Failing everything, the clamp.
	const CGFloat a0 = atan2(dy, dx);
	CGPoint best = CGPointZero;
	CGFloat bestClear = -CGFLOAT_MAX;
	for (int k = 0; k <= 24; k++) {
		const CGFloat a = a0 + (k % 2 ? 1 : -1) * ((k + 1) / 2) * (M_PI / 12.0);
		const CGPoint b = CGPointMake(c.x + cos(a) * off, c.y + sin(a) * off);
		if (!CGRectContainsPoint(inner, b)) {
			continue;
		}
		CGFloat clear = CGFLOAT_MAX;
		for (PDTouchButtonView *o in all) {
			if (o != chip) {
				clear = MIN(clear, hypot(o.center.x - b.x, o.center.y - b.y) - (o.radius + kHideBadgeRadius));
			}
		}
		if (clear >= 0) {
			return b;
		}
		if (clear > bestClear + 0.5) {   // earlier (nearer the preferred side) wins ties
			bestClear = clear;
			best = b;
		}
	}
	if (bestClear > -CGFLOAT_MAX) {
		return best;
	}
	CGPoint b = CGPointMake(c.x + dx * off, c.y + dy * off);
	b.x = MAX(CGRectGetMinX(inner), MIN(CGRectGetMaxX(inner), b.x));
	b.y = MAX(CGRectGetMinY(inner), MIN(CGRectGetMaxY(inner), b.y));
	return b;
}

- (nullable PDTouchButtonView *)editChipForLabel:(NSString *)label
{
	if (!label) {
		return nil;
	}
	for (PDTouchButtonView *b in _buttons) {
		if ([b.label isEqualToString:label]) {
			return b;
		}
	}
	return [_leftFire.label isEqualToString:label] ? _leftFire : nil;
}

/** Put the badge on the selected chip, or take it away. */
- (void)placeHideBadge
{
	PDTouchButtonView *chip = _editing ? [self editChipForLabel:_editSelected] : nil;
	if (!chip || !pdLabelHideable(chip.label)) {
		_hideBadge.hidden = YES;
		return;
	}
	if (!_hideBadge) {
		const CGFloat r = kHideBadgeRadius;
		UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, r * 2, r * 2)];
		v.userInteractionEnabled = NO;   // the layer hit-tests it itself, first
		v.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.92];
		v.layer.cornerRadius = r;
		v.layer.borderWidth = 1.5;
		v.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.85].CGColor;
		UIImageView *icon = [[UIImageView alloc] initWithFrame:v.bounds];
		icon.contentMode = UIViewContentModeCenter;
		icon.tintColor = UIColor.whiteColor;
		[v addSubview:icon];
		[self addSubview:v];
		_hideBadge = v;
		_hideBadgeIcon = icon;
	}
	const BOOL hidden = [self userHid:chip];
	_hideBadgeIcon.image = [UIImage systemImageNamed:hidden ? @"eye.fill" : @"eye.slash.fill"
		withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:15
		                                                                 weight:UIImageSymbolWeightSemibold]];
	_hideBadge.center = [self hideBadgeCentreFor:chip];
	_hideBadge.hidden = NO;
	[self bringSubviewToFront:_hideBadge];
	if (_editBar) {
		[self bringSubviewToFront:_editBar];
	}
}

- (void)toggleHiddenForChip:(PDTouchButtonView *)chip
{
	if (!chip || !pdLabelHideable(chip.label)) {
		return;
	}
	const BOOL hide = ![self userHid:chip];
	[self storeHidden:hide forLabel:chip.label];
	_userHidden = pdHiddenLabels();
	chip.alpha = hide ? kHiddenGhostAlpha : 1.0;
	NSLog(@"perfectdark: [touch] %@ %@ by the player (D-088)", chip.label, hide ? @"hidden" : @"shown");
	[self placeHideBadge];
}

/**
 * A finger down in the editor: the selected chip's badge first (a toggle, no
 * drag), then a chip body (select it - its badge appears - and start the drag).
 * The real path for touchesBegan AND the bridge's `tap` in the editor.
 */
- (NSString *)editBeganAt:(CGPoint)p
{
	PDTouchButtonView *sel = [self editChipForLabel:_editSelected];
	if (sel && _hideBadge && !_hideBadge.hidden
			&& hypot(p.x - _hideBadge.center.x, p.y - _hideBadge.center.y) <= kHideBadgeRadius + 4.0) {
		[self toggleHiddenForChip:sel];
#if !TARGET_OS_VISION
		[_haptics impactOccurred];
#endif
		return [NSString stringWithFormat:@"badge:%@ hidden=%d", sel.label, (int)[self userHid:sel]];
	}
	PDTouchButtonView *chip = [self editChipAtPoint:p];
	if (!chip || _dragChip) {
		return chip ? @"busy" : @"none";
	}
	_editSelected = chip.label;
	_dragChip = chip;
	_dragGrab = CGVectorMake(chip.center.x - p.x, chip.center.y - p.y);
	_dragUnit = CGPointMake(chip.center.x / MAX(1.0, self.bounds.size.width),
	                        chip.center.y / MAX(1.0, self.bounds.size.height));
	_dragStartUnit = _dragUnit;
	chip.held = YES;
	[self placeHideBadge];
#if !TARGET_OS_VISION
	[_haptics impactOccurred];
#endif
	return [NSString stringWithFormat:@"select:%@ badge=%d", chip.label, (int)(_hideBadge && !_hideBadge.hidden)];
}

/**
 * The handful of settings the per-event and per-frame paths read, pulled out of
 * NSUserDefaults once (D-034). Called by -applySettings - which every path that
 * writes one of them calls - and again every 60th publish as a safety net, so a
 * default written by something that forgot cannot be stale for more than half a
 * second.
 */
- (void)refreshCachedSettings
{
	_cLookDegX = PDDefFloat(PDDefLookDegPerPoint);
	_cLookDegY = PDDefFloat(PDDefLookDegPerPointY);
	if (_cLookDegX <= 0) { _cLookDegX = 0.30; }
	if (_cLookDegY <= 0) { _cLookDegY = _cLookDegX; }
	_cLookInvert = PDDefBool(PDDefInvertY) ? -1.0 : 1.0;
	_cDoubleTapRoll = PDDefBool(PDDefDoubleTapRoll);
	_cControlStyle = PDDefInt(PDDefControlStyle);
	_userHidden = pdHiddenLabels();
}

- (void)applySettings
{
	[self refreshCachedSettings];
	_scale = PDDefFloat(PDDefButtonScale);
	if (_scale < 0.5 || _scale > 2.5) {
		_scale = 1.0;
	}
	CGFloat alpha = PDDefFloat(PDDefButtonOpacity);
	if (alpha < 0.03 || alpha > 1.0) {
		alpha = 0.28;
	}

	for (PDTouchButtonView *b in _buttons) {
		[b removeFromSuperview];
	}
	[_buttons removeAllObjects];
	for (PDTouchButtonView *b in _menuButtons) {
		[b removeFromSuperview];
	}
	[_menuButtons removeAllObjects];
	[_leftFire removeFromSuperview];
	_leftFire = nil;

	for (int i = 0; i < PD_NUM_BUTTONS; i++) {
		PDTouchButtonView *b = [[PDTouchButtonView alloc] initWithSpec:&kButtons[i]
		                                                         scale:_scale alpha:alpha dim:1.0];
		[self addSubview:b];
		[_buttons addObject:b];
		if ([b.label isEqualToString:@"ALT"]) { _altChip = b; }
		if ([b.label isEqualToString:@"WHEEL"]) { _wheelChip = b; }
	}
	// Fainter: placeable and pressable, but temporary (bean).
	_leftFire = [[PDTouchButtonView alloc] initWithSpec:&kLeftFire
	                                              scale:_scale alpha:alpha dim:0.55];
	_leftFire.hidden = YES;
	[self addSubview:_leftFire];
	for (int i = 0; i < PD_NUM_MENU_BUTTONS; i++) {
		PDTouchButtonView *b = [[PDTouchButtonView alloc] initWithSpec:&kMenuButtons[i]
		                                                         scale:_scale alpha:alpha dim:1.0];
		b.hidden = YES;
		[self addSubview:b];
		[_menuButtons addObject:b];
	}

	// The chips carry their own opacity now (bean's look: a ring at the opacity
	// setting with the glyph at more than it), so the VIEW stays fully opaque -
	// dimming the whole layer would take the stick and the editor with it.
	self.alpha = 1.0;
#if !TARGET_OS_VISION
	_haptics = PDDefBool(PDDefHaptics)
		? [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] : nil;
#endif

	if (_editing) {
		// A settings push in the middle of an edit (the size slider, which is
		// exactly the thing a player reaches for while placing buttons) must not
		// hide the layer or dim it back to playing opacity.
		self.hidden = NO;
		[self buildEditChrome];
		[self applyEditChrome];
		[self setNeedsLayout];
		[self layoutIfNeeded];
		return;
	}

	[self updateVisibility];
	// The chips were just rebuilt from scratch, so the menu/gameplay split has
	// to be re-applied: a settings push while a menu is open would otherwise
	// put the gameplay chips back on top of the dialog.
	[self applyMenuChrome];
	[self setNeedsLayout];
}

- (void)setPadConnected:(BOOL)padConnected
{
	_padConnected = padConnected;
	[self updateVisibility];
}

/** auto (hidden with a pad) / always / off — PDDefTouchMode. */
- (void)updateVisibility
{
	NSInteger mode = PDDefInt(PDDefTouchMode);
	BOOL hide = (mode == 2) || (mode == 0 && self.padConnected);
	const BOOL wasHidden = self.hidden;
	self.hidden = hide;
	if (!hide) {
		_releasedWhileHidden = NO;
		if (wasHidden) {
			[self reassertTouchability];
		}
	}
	NSLog(@"perfectdark: [touch] overlay %@ (mode %ld, pad %@)",
		hide ? @"hidden" : @"visible", (long)mode, self.padConnected ? @"connected" : @"absent");
}

/**
 * Coming back from hidden, make sure the layer can be touched at all (D-037).
 *
 * The user, on 0.0.0.7 with a pad: "when I REMOVE the gamepad, touch controls
 * should come back. they did come back after about 5+ seconds, but then none of
 * them worked. I had to force quit and relaunch." A view that is visible but
 * unreachable has exactly three causes, and none of them is visible in a
 * screenshot: it is not in a window, something was put over it, or its
 * userInteractionEnabled is off. All three are asserted here rather than
 * assumed, every time the layer comes back, and any of them being wrong is
 * written to Documents/touch-watchdog.txt - which is the evidence the next
 * report needs whether or not this is what it was.
 *
 * Cheap: three compares and, at most, one -bringSubviewToFront:.
 */
- (void)reassertTouchability
{
	NSMutableString *wrong = nil;
	#define PD_WRONG(fmt, ...) do { \
		if (!wrong) { wrong = [NSMutableString string]; } \
		[wrong appendFormat:fmt, ##__VA_ARGS__]; \
	} while (0)

	if (!self.userInteractionEnabled) {
		PD_WRONG(@"userInteractionEnabled=NO ");
		self.userInteractionEnabled = YES;
	}
	if (self.alpha < 0.01) {
		PD_WRONG(@"alpha=%.2f ", self.alpha);
		self.alpha = 1.0;
	}

	UIWindow *win = self.window;
	if (!win) {
		PD_WRONG(@"window=nil superview=%@ ", NSStringFromClass(self.superview.class));
	} else {
		// Anything added to SDL's window after the overlay was installed sits
		// on top of it and eats every touch. The gear is a sibling by design
		// and is put back above us afterwards.
		UIView *top = win.subviews.lastObject;
		if (top != self && top != _gear) {
			PD_WRONG(@"covered-by=%@ ", NSStringFromClass(top.class));
		}
		[win bringSubviewToFront:self];
		if (_gear) {
			[win bringSubviewToFront:_gear];
		}
	}
	// The ROUTING check (D-041), and the one the three above could never make:
	// all of them are questions about the inside of SDL's window, and a touch
	// that is delivered to some OTHER window fails none of them. Round Q
	// shipped those three, they did not fire, and the user's touch was still
	// dead - because the settings page's own UIWindow had been made key and
	// then deallocated, and what was left took the event.
	if (win && !PDSettingsViewController.isPresented) {
		UIWindow *routeWin = nil;
		const CGPoint probe = [self routeProbePoint];
		UIView *routed = pdRouteHitTest(probe, &routeWin);
		const BOOL ours = routed && (routed == self || [routed isDescendantOfView:self]);
		if (routeWin != win || !ours) {
			PD_WRONG(@"route(%.0f,%.0f)->%@@%@ ", probe.x, probe.y,
				routed ? NSStringFromClass(routed.class) : @"nil",
				routeWin ? [NSString stringWithFormat:@"%@(level %.0f)",
					NSStringFromClass(routeWin.class), (double)routeWin.windowLevel] : @"no-window");
			// Nothing here can force UIKit to route to us, but making the
			// game's window key again is what puts a scene that lost its key
			// window back where it was.
			[win makeKeyAndVisible];
		}
	}

	#undef PD_WRONG

	if (wrong) {
		NSLog(@"perfectdark: [touch] UNREACHABLE on unhide — %@", wrong);
		[self noteWatchdog:[@"unreachable-on-unhide " stringByAppendingString:wrong]];
	}
}

/**
 * Once a second: would a finger on a chip still reach this layer? (D-041.)
 *
 * The check is the routed hit test, which is the only one that can see a touch
 * being delivered to another window. When it says no, the recovery is the
 * cheapest thing that can possibly work and is idempotent - put the layer and
 * the gear back on top inside SDL's window, make SDL's window key and visible
 * (a scene whose key window was hidden or destroyed has none, and that is what
 * a settings page that deallocated itself left behind), and ask for a layout
 * pass, because the same failure leaves the UIKit layer tree composited as it
 * was when the page went up.
 *
 * It reports ONCE per episode, with the whole windows report, into
 * Documents/touch-watchdog.txt. A watchdog that writes a line a second is a
 * watchdog nobody reads.
 */
- (void)routeWatchdogTick
{
	if (self.hidden || _editing || PDSettingsViewController.isPresented) {
		return;
	}
	UIWindow *win = self.window;
	if (!win) {
		return;   // -reassertTouchability's job, and it reports it
	}

	UIWindow *routeWin = nil;
	const CGPoint p = [self routeProbePoint];
	UIView *routed = pdRouteHitTest(p, &routeWin);
	if (routeWin == win && routed && (routed == self || [routed isDescendantOfView:self])) {
		_routeWasWrong = NO;
		return;
	}

	NSString *before = [NSString stringWithFormat:@"route(%.0f,%.0f)->%@ in %@",
		p.x, p.y, routed ? NSStringFromClass(routed.class) : @"nil",
		routeWin ? [NSString stringWithFormat:@"%@(level %.0f)", NSStringFromClass(routeWin.class),
			(double)routeWin.windowLevel] : @"no-window"];

	[win bringSubviewToFront:self];
	if (_gear) {
		[win bringSubviewToFront:_gear];
	}
	[win makeKeyAndVisible];
	[win setNeedsLayout];
	[self setNeedsLayout];
	for (UIView *sub in win.subviews) {
		[sub setNeedsDisplay];
	}

	routeWin = nil;
	routed = pdRouteHitTest(p, &routeWin);
	const BOOL healed = routeWin == win && routed && (routed == self || [routed isDescendantOfView:self]);

	if (!_routeWasWrong) {
		_routeWasWrong = YES;
		NSLog(@"perfectdark: [touch] TOUCH ROUTING WRONG — %@ (healed=%d)", before, (int)healed);
		[self noteWatchdog:[NSString stringWithFormat:@"route-wrong healed=%d %@\n%@",
			(int)healed, before, [PDTouchOverlay windowsReport]]];
	}
	if (healed) {
		_routeWasWrong = NO;
	}
}

/**
 * A point a real finger would press: the FIRE chip's centre if there is one on
 * screen, otherwise the middle of the layer. In window coordinates, because
 * that is the space UIKit routes in.
 */
- (CGPoint)routeProbePoint
{
	for (PDTouchButtonView *b in (_menuOpen ? _menuButtons : _buttons)) {
		if (!b.hidden) {
			return [self convertPoint:b.center toView:nil];
		}
	}
	return [self convertPoint:CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds))
	                   toView:nil];
}

/**
 * The bridge's `windows`: every window, in the order UIKit consults them, and
 * where a touch on a chip would actually land (D-041).
 *
 * This is the instrument the last two rounds lacked. `hit X Y` answers from the
 * overlay's own model and is right even when nothing on screen can be touched;
 * `state` reports the layer's flags, which were all correct while the user's
 * phone ignored every finger. Only a hit test taken from the WINDOW follows the
 * route a real touch takes, across window ordering, hidden windows and a key
 * window that has gone missing - and only that can be compared before and after
 * a transition. Main thread.
 */
+ (unsigned)touchesBeganCount { PDTouchOverlay *v = sCurrent; return v ? v->_uiTouchesBegan : 0; }
+ (unsigned)hitTestCount       { PDTouchOverlay *v = sCurrent; return v ? v->_uiHitTests : 0; }

+ (NSString *)windowsReport
{
	NSMutableString *s = [NSMutableString string];
	UIWindow *game = pdGameWindow();
	PDTouchOverlay *v = sCurrent;

	NSArray<UIScene *> *scenes = UIApplication.sharedApplication.connectedScenes.allObjects;
	[s appendFormat:@"scenes=%lu\n", (unsigned long)scenes.count];
	for (UIScene *sc in scenes) {
		if (![sc isKindOfClass:UIWindowScene.class]) {
			[s appendFormat:@"scene cls=%@ (not a window scene)\n", NSStringFromClass(sc.class)];
			continue;
		}
		UIWindowScene *ws = (UIWindowScene *)sc;
		[s appendFormat:@"scene id=%@ state=%ld windows=%lu key=%@\n",
			ws.session.persistentIdentifier, (long)ws.activationState,
			(unsigned long)ws.windows.count,
			ws.keyWindow ? [NSString stringWithFormat:@"%@:%p", NSStringFromClass(ws.keyWindow.class), ws.keyWindow]
			             : @"NONE"];
	}

	NSArray<UIWindow *> *all = pdAllWindows();
	[s appendFormat:@"windows=%lu\n", (unsigned long)all.count];
	for (UIWindow *w in all) {
		[s appendFormat:@"win %p cls=%@ level=%.0f hidden=%d key=%d uie=%d alpha=%.2f scene=%@ "
			"bounds=%.0fx%.0f root=%@ subviews=%lu%@\n",
			w, NSStringFromClass(w.class), (double)w.windowLevel, (int)w.hidden,
			(int)w.isKeyWindow, (int)w.userInteractionEnabled, w.alpha,
			w.windowScene ? @"yes" : @"NO",
			w.bounds.size.width, w.bounds.size.height,
			NSStringFromClass(w.rootViewController.class),
			(unsigned long)w.subviews.count,
			w == game ? @" <- SDL/game" : @""];
	}
	[s appendFormat:@"game_window=%@\n", game ? [NSString stringWithFormat:@"%p", game] : @"NONE"];
	[s appendFormat:@"game_is_key=%d\n", (int)(game && game.isKeyWindow)];
	[s appendFormat:@"settings_page=%d\n", (int)PDSettingsViewController.isPresented];
	[s appendFormat:@"overlay=%@ window=%p hidden=%d uie=%d alpha=%.2f\n",
		v ? [NSString stringWithFormat:@"%p", v] : @"NONE", v.window,
		(int)v.hidden, (int)v.userInteractionEnabled, v.alpha];
	if (v && v.window) {
		UIView *top = v.window.subviews.lastObject;
		[s appendFormat:@"topmost_subview=%@\n", NSStringFromClass(top.class)];
	}

	// The routed hit tests: what a finger at each of these points would reach.
	// `route_ok=1` means every probe landed inside the overlay, through SDL's
	// window - which is the whole question this command exists to answer.
	BOOL ok = (v != nil) && !v.hidden;
	if (v) {
		NSMutableArray<NSArray *> *probes = [NSMutableArray array];
		for (PDTouchButtonView *b in (v->_menuOpen ? v->_menuButtons : v->_buttons)) {
			if (!b.hidden) {
				[probes addObject:@[b.label, [NSValue valueWithCGPoint:[v convertPoint:b.center toView:nil]]]];
			}
		}
		[probes addObject:@[@"centre", [NSValue valueWithCGPoint:
			[v convertPoint:CGPointMake(CGRectGetMidX(v.bounds), CGRectGetMidY(v.bounds)) toView:nil]]]];
		for (NSArray *pr in probes) {
			CGPoint p = [(NSValue *)pr[1] CGPointValue];
			UIWindow *rw = nil;
			UIView *hit = pdRouteHitTest(p, &rw);
			const BOOL mine = hit && (hit == v || [hit isDescendantOfView:v]);
			if (!mine || rw != v.window) {
				ok = NO;
			}
			[s appendFormat:@"route %@ (%.0f,%.0f) -> %@ in %@%@\n", pr[0], p.x, p.y,
				hit ? NSStringFromClass(hit.class) : @"nil",
				rw ? [NSString stringWithFormat:@"%p level=%.0f", rw, (double)rw.windowLevel] : @"no-window",
				mine && rw == v.window ? @" OK" : @" WRONG"];
		}
	}
	// The gear is a sibling of the overlay, not a subview: its own probe.
	if (v && v->_gear && !v->_gear.hidden) {
		CGPoint gp = [v->_gear.superview convertPoint:v->_gear.center toView:nil];
		UIWindow *rw = nil;
		UIView *hit = pdRouteHitTest(gp, &rw);
		const BOOL mine = hit && (hit == v->_gear || [hit isDescendantOfView:v->_gear]);
		if (!mine) { ok = NO; }
		[s appendFormat:@"route gear (%.0f,%.0f) -> %@ in %@%@\n", gp.x, gp.y,
			hit ? NSStringFromClass(hit.class) : @"nil",
			rw ? [NSString stringWithFormat:@"%p level=%.0f", rw, (double)rw.windowLevel] : @"no-window",
			mine ? @" OK" : @" WRONG"];
	}
	[s appendFormat:@"route_ok=%d\n", (int)ok];

	// Delivery, which is a different question from routing (D-041 round 2).
	// The user's second report: route_ok=1, the watchdog silent, and not one
	// touch reaching the game. So these are the counters that say whether
	// UIKit handed anything over at all, and the app-wide gate that can stop
	// it doing so.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	// visionOS has no such API at all - there is no app-wide ignore gate there,
	// which is one fewer thing that can go wrong in the headset.
#if TARGET_OS_VISION
	[s appendString:@"ignoring_interaction=n/a\n"];
#else
	[s appendFormat:@"ignoring_interaction=%d\n",
		(int)UIApplication.sharedApplication.isIgnoringInteractionEvents];
#endif
	[s appendFormat:@"app_state=%ld\n", (long)UIApplication.sharedApplication.applicationState];
#pragma clang diagnostic pop
	[s appendFormat:@"ui_hittests=%u\n", v ? v->_uiHitTests : 0];
	[s appendFormat:@"ui_touches_began=%u\n", v ? v->_uiTouchesBegan : 0];
	[s appendFormat:@"gear_taps=%u\n", v ? v->_gearTaps : 0];
	[s appendString:pdRunLoopReport()];
	for (UIWindow *w in all) {
		UIViewController *root = w.rootViewController;
		UIViewController *top = root;
		int depth = 0;
		while (top.presentedViewController && depth < 8) {
			top = top.presentedViewController;
			depth++;
		}
		[s appendFormat:@"vc %p root=%@ presented=%@ depth=%d appearing=%d transition=%@\n",
			w, NSStringFromClass(root.class),
			top == root ? @"-" : NSStringFromClass(top.class), depth,
			(int)root.isBeingPresented,
			root.transitionCoordinator ? @"IN-FLIGHT" : @"-"];
	}
	return s;
}

/**
 * The recovery experiments, for the bridge's `heal <n>` (D-041 round 2).
 *
 * The user's phone gets into a state where the routing is provably right and no
 * touch is ever delivered, and it did not reproduce on a simulator in three
 * rounds of trying. So rather than guess which recovery is the right one, each
 * candidate is a number: when he is IN the broken state, over USB, we try them
 * one at a time and ask him to tap between them. `ui_hittests` going up is the
 * answer. Whichever one restores delivery names the cause.
 */
+ (NSString *)heal:(int)which
{
	PDTouchOverlay *v = sCurrent;
	UIWindow *win = pdGameWindow();
	NSMutableString *out = [NSMutableString stringWithFormat:@"heal=%d ", which];

	switch (which) {
	case 1: {
		// The app-wide ignore gate. There is no way to clear it but the
		// matching end call, and UIKit's own begins are supposed to be
		// balanced - an unbalanced one is exactly the bug this is testing for,
		// so it is drained rather than called once, and bounded.
#if TARGET_OS_VISION
		[out appendString:@"no ignore-interaction gate on visionOS"];
#else
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
		int n = 0;
		while (UIApplication.sharedApplication.isIgnoringInteractionEvents && n < 16) {
			[UIApplication.sharedApplication endIgnoringInteractionEvents];
			n++;
		}
		[out appendFormat:@"endIgnoringInteractionEvents x%d -> ignoring=%d",
			n, (int)UIApplication.sharedApplication.isIgnoringInteractionEvents];
#pragma clang diagnostic pop
#endif
		break;
	}
	case 2:
		[win makeKeyAndVisible];
		[out appendString:@"re-keyed the game window"];
		break;
	case 3: {
		// Re-bind the window to its scene. SDL's window was created sceneless
		// and grafted on afterwards (D-038); a binding that survives being
		// composited need not have survived being registered for touch.
		UIWindowScene *sc = win.windowScene;
		win.windowScene = nil;
		win.windowScene = sc;
		[win makeKeyAndVisible];
		[out appendFormat:@"re-grafted onto %@", sc.session.persistentIdentifier];
		break;
	}
	case 4:
		// The heavier version of 3: UIKit tears the window's context down and
		// builds a new one. Expect one black frame.
		win.hidden = YES;
		win.hidden = NO;
		[win makeKeyAndVisible];
		[out appendString:@"hidden toggled on the game window"];
		break;
	case 5: {
		// The overlay and the gear taken out of the window and put back.
		UIView *gear = v->_gear;
		[v removeFromSuperview];
		[gear removeFromSuperview];
		[win addSubview:v];
		if (gear) { [win addSubview:gear]; [v pinGearInWindow:win]; }
		[out appendString:@"overlay and gear re-added to the window"];
		break;
	}
	case 6:
		[PDSettingsViewController destroy];
		[out appendString:@"the settings window destroyed outright"];
		break;
	default:
		return @"usage: heal 1..6  (1 endIgnoringInteractionEvents, 2 re-key, "
		        "3 re-graft the scene, 4 hidden toggle, 5 re-add the overlay, "
		        "6 destroy the settings window)";
	}
	[out appendString:@"\n"];
	[out appendString:[self windowsReport]];
	return out;
}

/**
 * The gear is shown in menus, on the title screen, in the pause screen and the
 * briefing, and HIDDEN while the player is actually playing (bean,
 * touch_overlay_uikit.mm:1142-1167).
 *
 * The predicate is the engine's, asked once a frame on the game thread: there
 * is a player standing somewhere (playerIosGetPos, overlay 0021, which answers
 * 0 in a menu or a load), no dialog is open (menuIosDialogIsOpen, overlay 0019,
 * which is what PD's pause menu and every options page is) and the player is
 * not paused (playerIosIsPaused, overlay 0021 - the two transitional frames
 * either side of the dialog, where a pad player has pressed Start and is
 * looking for the gear). Every failure mode here reports "not gameplay" and
 * SHOWS the gear: it is the only route to Settings, and bean lost his for good
 * by getting this the other way round.
 *
 * Hysteresis one way only: showing is immediate, hiding waits for 400 ms of
 * continuous gameplay so a quick pause and unpause cannot flicker it.
 *
 * D-037: this runs on EVERY frame, including the frames where the touch layer
 * is hidden because a pad is connected. It used to be a line in -publish, and
 * +publishInput returns before -publish whenever the layer is hidden - so the
 * gear froze at whatever it was the instant the controller connected, which on
 * a pad player mid-mission is "hidden", for ever. That is the user's "when I
 * pause the game on gamepad, the iOS settings button does not show": the
 * predicate was right and was simply never asked again.
 */
- (void)updateGearVisibility
{
	if (!_gear) {
		return;
	}
	float px = 0, py = 0, pz = 0;
	const BOOL playing = !_menuOpen && !playerIosIsPaused()
		&& playerIosGetPos(&px, &py, &pz) != 0;
	if (!playing) {
		_gameplaySince = 0.0;
	} else if (_gameplaySince == 0.0) {
		_gameplaySince = CACurrentMediaTime();
	}
	const BOOL settled = playing && (CACurrentMediaTime() - _gameplaySince) >= 0.4;
	const BOOL hide = _editing || settled;
	if (_gear.hidden != hide) {
		_gear.hidden = hide;
		NSLog(@"perfectdark: [touch] gear %@ (%@)", hide ? @"hidden" : @"shown",
			playing ? @"gameplay" : @"menu/title");
	}
	// The corner geometry, logged when it changes (checked twice a second).
	if (++_geoTicks % 30 == 0) {
		NSString *geo = [self cornerGeometryReport];
		if (![geo isEqualToString:_lastGeo]) {
			_lastGeo = geo;
			NSLog(@"perfectdark: [touch] corner geometry\n%@", geo);
		}
	}
}

- (void)layoutSubviews
{
	[super layoutSubviews];
	CGSize sz = self.bounds.size;

	NSMutableArray<PDTouchButtonView *> *all =
		[[_buttons arrayByAddingObjectsFromArray:_menuButtons] mutableCopy];
	if (_leftFire) {
		[all addObject:_leftFire];
	}
	for (PDTouchButtonView *b in all) {
		if (b == _dragChip) {
			continue;   // a chip under a finger is where the finger put it
		}
		b.center = [self centreForLabel:b.label radius:b.radius];
	}

	CGFloat r = kStickRadius;
	_stickBase.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(-r, -r, r * 2, r * 2)].CGPath;
	_stickKnob.path = [UIBezierPath bezierPathWithOvalInRect:
		CGRectMake(-kStickKnobRadius, -kStickKnobRadius, kStickKnobRadius * 2, kStickKnobRadius * 2)].CGPath;
	(void)sz;
	if (_editing) {
		[self placeHideBadge];
	}
}

// ---------------------------------------------------------------------------
// Touch handling

- (PDTouchButtonView *)buttonAtPoint:(CGPoint)p
{
	// The aim-mode mirror first: it sits over the stick's half of the screen and
	// must take precedence over the floating stick while it is there (bean).
	if ([self leftFireVisible]) {
		CGFloat dx = p.x - _leftFire.center.x, dy = p.y - _leftFire.center.y;
		CGFloat r = _leftFire.radius * kHitRadiusFactor;
		if (dx * dx + dy * dy <= r * r) {
			return _leftFire;
		}
	}
	for (PDTouchButtonView *b in (_menuOpen ? _menuButtons : _buttons)) {
		if (b.hidden) {
			continue;   // the ALT chip on a GoldenEye level (D-085)
		}
		CGFloat dx = p.x - b.center.x, dy = p.y - b.center.y;
		// bean's target: a quarter larger than the ring that is drawn. A
		// fingertip is 40pt wide and the ring is the mark, not the target.
		CGFloat r = b.radius * kHitRadiusFactor;
		if (dx * dx + dy * dy <= r * r) {
			return b;
		}
	}
	return nil;
}

- (void)beginTouchAt:(CGPoint)p touch:(nullable UITouch *)touch
{
	PDTouchButtonView *b = [self buttonAtPoint:p];
	if (b) {
		b.held = YES;
		_buttonMask |= b.mask;
		_unpublishedMask |= b.mask;
		if (touch) {
			[_buttonTouches setObject:b forKey:touch];
		}
		// bean's hold-and-drag AIM: the pressing finger becomes the aim
		// surface. Armed even for a synthetic press (touch == nil) so the
		// bridge drives the same path a thumb does.
		if ([self isAimChip:b] && !_aimDragArmed) {
			_aimDragArmed = YES;
			_aimDragTouch = touch;
			_aimDragLast = p;
		}
		// The weapon wheel (D-085): the same, but the drag is a stick for the
		// active menu rather than a look. The press is the menu's button, so
		// the wheel opens on touch-down with the stick at rest.
		if ([self isWheelChip:b] && !_wheelArmed) {
			_wheelArmed = YES;
			_wheelTouch = touch;
			_wheelOrigin = p;
			_wheelStick = CGVectorMake(0, 0);
		}
#if !TARGET_OS_VISION
		[_haptics impactOccurred];
#endif
		return;
	}

	if (_menuOpen) {
		// The whole screen is the menu's pointer. Focus follows the finger
		// through the engine's own dialogChangeItemFocusWithMouse(); the
		// button is NOT down while the finger is (D-083) - a lift that did not
		// travel is the click, played out by -publish.
		if (!_pointerTouch || !touch) {
			_pointerTouch = touch;
			_pointerPoint = p;
			_pointerDownPoint = p;
			_pointerDownTime = NSDate.timeIntervalSinceReferenceDate;
			_pointerDown = YES;
			_pointerValid = YES;
			_pointerScrolled = NO;
			_scrollResidue = 0;
		}
		return;
	}

	if (p.x < self.bounds.size.width * kStickZoneFrac) {
		[self noteStickTapAt:p];
		if (!_stickTouch) {
			_stickDownTime = NSDate.timeIntervalSinceReferenceDate;
			// ALWAYS floating (D-032): the stick appears where the thumb lands.
			// A fixed origin is a thing a thumb has to find, and a thumb in a
			// firefight is not looking.
			_stickTouch = touch;
			_stickOrigin = p;
			[self showStickAt:_stickOrigin knob:p];
		}
		return;
	}

	if (!_lookTouch) {
		_lookTouch = touch;
		_lookLast = p;
		_lookLead = CGVectorMake(0, 0);
		_lookDownPoint = p;
		_lookDownTime = NSDate.timeIntervalSinceReferenceDate;
	}
}

/** The stick's touch ended at `up`: drop the stick, and arm a double tap only
 *  if this was a real tap (short hold, no excursion from where it landed). */
- (void)liftStickTouchAt:(CGPoint)up
{
	const NSTimeInterval held = NSDate.timeIntervalSinceReferenceDate - _stickDownTime;
	if (held <= kTapMaxHoldSeconds
		&& hypot(up.x - _stickOrigin.x, up.y - _stickOrigin.y) <= kDoubleTapSlopPoints) {
		_lastStickTapTime = NSDate.timeIntervalSinceReferenceDate;
		_lastStickTapPoint = up;
	} else {
		_lastStickTapTime = 0;
	}
	_stickTouch = nil;
	_stickValue = CGVectorMake(0, 0);
	[self hideStickChrome];
}

/**
 * Two taps in the stick region are a combat roll (D-032).
 *
 * Which way: the half of the REGION the taps landed in - nearer the screen edge
 * is left - not the half of the screen, so the answer does not change with the
 * region's width. The roll itself is played to the engine over the next few
 * frames by -publish, because bwalkTryRoll() takes its direction from
 * speedsideways (bondwalk.c:393): the gesture has to BE a strafe with the roll
 * button pressed inside it, exactly as a thumb on a pad would do it.
 */
- (void)noteStickTapAt:(CGPoint)p
{
	// _lastStickTapTime is armed only by a completed short tap (see the stick
	// touch-end path), so a re-planted thumb after a walk never doubles.
	const NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
	const BOOL doubled = _cDoubleTapRoll
		&& _lastStickTapTime > 0
		&& (now - _lastStickTapTime) <= kDoubleTapSeconds
		&& hypot(p.x - _lastStickTapPoint.x, p.y - _lastStickTapPoint.y) <= kDoubleTapSlopPoints;
	_lastStickTapTime = 0;   // consumed either way; three taps are one roll, not two
	if (!doubled) {
		return;
	}
	const CGFloat region = self.bounds.size.width * kStickZoneFrac;
	[self startRollDirection:(p.x < region * 0.5) ? -1 : +1
	                  source:[NSString stringWithFormat:@"double tap, x=%.0f of region %.0f",
	                          p.x, region]];
}

/**
 * Where the stick layers should be. NOT where they are put: -publish does that,
 * once a frame (D-034). A drag delivers touch samples faster than the frame
 * rate and each layer write would otherwise be its own CoreAnimation commit,
 * inside the game frame, on the game thread.
 */
- (void)showStickAt:(CGPoint)origin knob:(CGPoint)knob
{
	_stickChromeOrigin = origin;
	_stickChromeKnob = knob;
	_stickChromeVisible = YES;
	_stickChromeDirty = YES;
	if (pdTouchUnbatched()) {
		[self applyStickChrome];
	}
}

/**
 * The other half. Hiding is NOT deferred: it happens at most once per gesture,
 * never per event, and a deferred hide would have to survive every early return
 * in -publish (the editor, a settings page, a hidden layer) to be correct.
 */
- (void)hideStickChrome
{
	_stickChromeVisible = NO;
	_stickChromeDirty = NO;
	if (_stickBase.hidden && _stickKnob.hidden) {
		return;
	}
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	_stickBase.hidden = YES;
	_stickKnob.hidden = YES;
	[CATransaction commit];
}

/** One CATransaction per frame, and only when something moved. */
- (void)applyStickChrome
{
	if (!_stickChromeDirty) {
		return;
	}
	_stickChromeDirty = NO;
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	if (_stickChromeVisible) {
		_stickBase.position = _stickChromeOrigin;
		_stickKnob.position = _stickChromeKnob;
		_stickBase.hidden = NO;
		_stickKnob.hidden = NO;
	} else {
		_stickBase.hidden = YES;
		_stickKnob.hidden = YES;
	}
	[CATransaction commit];
}

/** The family curve: 0.4 linear + 0.6 cubic, after a radial deadzone. */
static CGVector pdStickCurve(CGVector raw)
{
	CGFloat mag = sqrt(raw.dx * raw.dx + raw.dy * raw.dy);
	if (mag <= kStickDeadzone) {
		return CGVectorMake(0, 0);
	}
	CGFloat unit = MIN(1.0, (mag - kStickDeadzone) / (1.0 - kStickDeadzone));
	CGFloat curved = kStickLinear * unit + kStickCubic * unit * unit * unit;
	return CGVectorMake(raw.dx / mag * curved, raw.dy / mag * curved);
}

- (void)moveStickTo:(CGPoint)p
{
	CGFloat dx = p.x - _stickOrigin.x;
	CGFloat dy = p.y - _stickOrigin.y;
	CGFloat mag = sqrt(dx * dx + dy * dy);
	CGFloat clamped = MIN(mag, kStickRadius);
	CGPoint knob = mag > 0 ? CGPointMake(_stickOrigin.x + dx / mag * clamped,
	                                     _stickOrigin.y + dy / mag * clamped)
	                       : _stickOrigin;
	[self showStickAt:_stickOrigin knob:knob];
	_stickValue = pdStickCurve(CGVectorMake(dx / kStickRadius, dy / kStickRadius));
}

/**
 * Called once per COALESCED touch sample, so this is the hottest thing the
 * touch layer does: three cached scalars and two multiply-adds, no
 * NSUserDefaults, no allocation, no layer write (D-034).
 */
- (void)addLookFrom:(CGPoint)from to:(CGPoint)to
{
	if (pdTouchUnbatched()) {
		CGFloat degX = PDDefFloat(PDDefLookDegPerPoint);
		CGFloat degY = PDDefFloat(PDDefLookDegPerPointY);
		if (degX <= 0) degX = 0.30;
		if (degY <= 0) degY = degX;
		CGFloat invert = PDDefBool(PDDefInvertY) ? -1.0 : 1.0;
		_pendingLookX += (to.x - from.x) * degX;
		_pendingLookY += (to.y - from.y) * degY * invert;
		return;
	}
	_pendingLookX += (to.x - from.x) * _cLookDegX;
	_pendingLookY += (to.y - from.y) * _cLookDegY * _cLookInvert;
}

/**
 * Swap the chip set when a menu opens or closes.
 *
 * The buttons are UIViews, so this has to happen on the main thread - which is
 * the game thread here, so the call from -publish is already on it. Anything
 * held when the set changes is released, or a mask bit would be stuck down
 * with no view left to lift it.
 */
- (void)applyMenuChrome
{
	for (PDTouchButtonView *b in _buttons) {
		if (b.held) { b.held = NO; _buttonMask &= ~b.mask; }
		_latchMask &= ~b.mask; _unpublishedMask &= ~b.mask;   // D-086: a drop, not a tap
		b.hidden = _menuOpen || [self userHid:b];   // D-088: hidden by the player
	}
	if (_leftFire.held) { _leftFire.held = NO; _buttonMask &= ~_leftFire.mask; }
	_latchMask &= ~_leftFire.mask; _unpublishedMask &= ~_leftFire.mask;
	_leftFire.hidden = YES;
	[self clearAimDrag];
	[self clearWheel];
	for (PDTouchButtonView *b in _menuButtons) {
		if (b.held) { b.held = NO; _buttonMask &= ~b.mask; }
		_latchMask &= ~b.mask; _unpublishedMask &= ~b.mask;   // D-086: a drop, not a tap
		b.hidden = !_menuOpen;
	}
	[self hideStickChrome];
	_stickTouch = nil;
	_stickValue = CGVectorMake(0, 0);
	NSLog(@"perfectdark: [touch] %@ chrome", _menuOpen ? @"menu" : @"gameplay");
}

/** Menu pointer: focus follows the finger, and a vertical drag scrolls. */
- (void)movePointerTo:(CGPoint)p
{
	CGFloat dy = p.y - _pointerPoint.y;
	_pointerPoint = p;

	if (!_pointerScrolled) {
		if (hypot(p.x - _pointerDownPoint.x, p.y - _pointerDownPoint.y) < kTapSlopPoints) {
			// Still a tap: a fingertip's jitter scrolls nothing.
			return;
		}
		// Now a drag, for the rest of this touch, and never a click. The travel
		// so far counts, so the list does not lag the finger by the slop.
		_pointerScrolled = YES;
		dy = p.y - _pointerDownPoint.y;
	}

	// Drag up = look further down the list, which is a wheel-down tick. A tick
	// is one LINEHEIGHT on screen (overlay 0051), so the menu moves with the
	// finger rather than at a rate someone picked.
	const CGFloat tick = MAX(4.0, self.bounds.size.height * menuIosRowFraction());
	_scrollResidue -= dy;
	while (_scrollResidue >= tick) { _scrollResidue -= tick; _pendingWheel += 1; }
	while (_scrollResidue <= -tick) { _scrollResidue += tick; _pendingWheel -= 1; }
}

- (void)liftPointerAt:(CGPoint)p
{
	const BOOL tapped = !_pointerScrolled
		&& hypot(p.x - _pointerDownPoint.x, p.y - _pointerDownPoint.y) < kTapSlopPoints;
	_pointerPoint = p;
	_pointerDown = NO;
	_pointerTouch = nil;

	// The click is HERE, on the lift of a touch that did not travel (D-083).
	// It used to be the finger going down: the button was held for as long as
	// the finger was, so a drag chose the item it started on, and chose again
	// on every frame a slow drag paused - a thumb trying to scroll the Perfect
	// Menu ended up in a combat match. It is still the pointer's own button
	// (VK_MOUSE_LEFT, CK_ZTRIG's bind), never a pressed A as well: that made
	// every tap select twice ("Darkxzzll", D-022). One tap, one select.
	if (tapped) {
		if (_clickFrames > 0) {
			// A second tap inside the first one's three frames: it waits its
			// turn rather than moving the first click off its item.
			_clickQueued = YES;
			_clickQueuedPoint = p;
		} else {
			_clickFrames = kMenuClickFrames;
			_clickPoint = p;
		}
	}
	_pointerScrolled = NO;
}

/** UIKit's own hit test, counted. A nil event is one of our probes. */
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
	if (event) {
		_uiHitTests++;
	}
	return [super hitTest:point withEvent:event];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	_uiTouchesBegan++;
	if (_editing) {
		// One chip at a time: a two-finger "drag two buttons at once" is not a
		// thing anyone wants and doubles the state to get wrong.
		for (UITouch *t in touches) {
			if (!_dragChip) {
				[self editBeganAt:[t locationInView:self]];
			}
		}
		return;
	}
	for (UITouch *t in touches) {
		[self beginTouchAt:[t locationInView:self] touch:t];
	}
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	if (_editing) {
		[self dragChipTo:[touches.anyObject locationInView:self]];
		return;
	}
	for (UITouch *t in touches) {
		if (_menuOpen && t == _pointerTouch) {
			[self movePointerTo:[t locationInView:self]];
			continue;
		}
		if (t == _stickTouch) {
			[self moveStickTo:[t locationInView:self]];
			continue;
		}
		if (_wheelTouch && t == _wheelTouch) {
			[self moveWheelTo:[t locationInView:self]];
			continue;
		}
		if (_aimDragTouch && t == _aimDragTouch) {
			// The AIM finger aims. Coalesced samples for the same reason the
			// look drag uses them (the panel samples faster than the frame);
			// no predicted lead, because an aim drag is a slow deliberate
			// movement and the lead exists for fast flicks.
			NSArray<UITouch *> *coalesced = [event coalescedTouchesForTouch:t] ?: @[t];
			for (UITouch *c in coalesced) {
				[self addAimDragTo:[c locationInView:self]];
			}
			continue;
		}
		if (t != _lookTouch) {
			continue;
		}

		// Coalesced touches first: the panel samples faster than the frame, and
		// using only the event's own location throws those samples away, which
		// is what makes a fast flick under-turn.
		NSArray<UITouch *> *coalesced = [event coalescedTouchesForTouch:t] ?: @[t];
		CGPoint from = _lookLast;
		for (UITouch *c in coalesced) {
			CGPoint to = [c locationInView:self];
			[self addLookFrom:from to:to];
			from = to;
		}
		_lookLast = from;

		// Predicted touches, applied as a self-correcting LEAD rather than as
		// extra movement: what was added last time is taken back before this
		// time's is added, so prediction can never accumulate error - it only
		// ever shifts the view forward by at most one event's worth and is
		// exactly undone when the real samples arrive.
		NSArray<UITouch *> *predicted = [event predictedTouchesForTouch:t];
		CGVector lead = CGVectorMake(0, 0);
		if (predicted.count) {
			CGPoint p = [predicted.lastObject locationInView:self];
			lead = CGVectorMake(p.x - _lookLast.x, p.y - _lookLast.y);
		}
		CGPoint zero = CGPointZero;
		[self addLookFrom:CGPointMake(zero.x + _lookLead.dx, zero.y + _lookLead.dy)
		               to:CGPointMake(zero.x + lead.dx, zero.y + lead.dy)];
		_lookLead = lead;
	}
}

- (void)endTouches:(NSSet<UITouch *> *)touches cancelled:(BOOL)cancelled
{
	if (_editing) {
		if (_dragChip) {
			[self dragChipTo:[touches.anyObject locationInView:self]];
			[self commitDrag];
		}
		return;
	}
	for (UITouch *t in touches) {
		PDTouchButtonView *b = [_buttonTouches objectForKey:t];
		if (b) {
			[self liftChip:b latch:!cancelled];
			[_buttonTouches removeObjectForKey:t];
			// The lift leaves aim mode: PD's aim button is HOLD by default
			// (AIMCONTROL_HOLD, bondmove.c:951), so dropping R is all it takes.
			if ([self isAimChip:b] || (_aimDragTouch && t == _aimDragTouch)) {
				[self clearAimDrag];
			}
			// The lift is the choice: the button and the stick go together, so
			// the slice the engine highlighted last frame is the one amClose()
			// applies (activemenutick.c closes before it reads this frame's).
			if ([self isWheelChip:b] || (_wheelTouch && t == _wheelTouch)) {
				[self clearWheel];
			}
			continue;
		}
		if (_menuOpen && t == _pointerTouch) {
			[self liftPointerAt:[t locationInView:self]];
			continue;
		}
		if (t == _stickTouch) {
			[self liftStickTouchAt:[t locationInView:self]];
			continue;
		}
		if (t == _lookTouch) {
			CGPoint p = [t locationInView:self];
			NSTimeInterval held = NSDate.timeIntervalSinceReferenceDate - _lookDownTime;
			CGFloat moved = hypot(p.x - _lookDownPoint.x, p.y - _lookDownPoint.y);
			if (moved < kTapSlopPoints && held < kTapMaxSeconds) {
				// A tap on the view, not a drag: in a menu that means confirm.
				// PD's menus take a mouse cursor driven by the same look delta
				// the drag feeds (activemenutick.c:107), so "drag to move the
				// highlight, tap to choose" is the whole navigation model (D-014).
				_tapConfirmFrames = 3;
			}
			// Undo any outstanding predicted lead so lifting a finger never
			// leaves the view a few degrees past where it was pointed.
			_pendingLookX -= _lookLead.dx * _cLookDegX;
			_pendingLookY -= _lookLead.dy * _cLookDegY * _cLookInvert;
			_lookLead = CGVectorMake(0, 0);
			_lookTouch = nil;
		}
	}
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self endTouches:touches cancelled:NO]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	// A cancelled menu touch (a system edge gesture took it) is never a tap:
	// marked as travelled, so its lift does not click (D-083).
	if (_pointerTouch && [touches containsObject:_pointerTouch]) {
		_pointerScrolled = YES;
	}
	[self endTouches:touches cancelled:YES];
}

// ---------------------------------------------------------------------------
// The engine side: once per frame, on the game thread.

+ (void)publishInput
{
	PDTouchOverlay *v = sCurrent;

	// Engine-driven chrome first, and unconditionally (D-037). Everything
	// below this line can return early - the settings page is up, the layer is
	// hidden behind a pad - and the gear's predicate and the menu/gameplay
	// split are not the touch layer's own state: they are the ENGINE's, and
	// they have to keep being asked whether or not a finger can reach anything.
	[v refreshEngineChrome];

	if (v && PDSettingsViewController.isPresented) {
		// Nothing here has to run while the settings page is up (bean's tick
		// returns the same way), and whatever the player was holding must not
		// stay held behind the page - that is walking into a wall under a sheet.
		if (v->_buttonMask || v->_latchMask || v->_rollFrames || v->_stickTouch || v->_lookTouch
			|| v->_stickValue.dx != 0 || v->_stickValue.dy != 0) {
			[v releaseEverything];
		}
		if (inputIosPointerIsActive()) {
			inputIosPointerClear();
		}
		return;
	}
	if (!v || v.hidden) {
		// A hidden layer must not leave a pointer live: VK_MOUSE_LEFT is also
		// CK_ZTRIG's bind (overlay 0019).
		if (inputIosPointerIsActive()) {
			inputIosPointerClear();
		}
		// ...nor anything else it was holding when it vanished (D-034). The
		// shell's mask is OR'd over the real pad's and its stick is used
		// whenever the real stick is centred (overlay 0015), so a touch stick
		// held at the instant a controller connects - the overlay hides itself
		// on that notification - was a full-speed walk the engine never stopped
		// seeing and nothing on screen to explain it.
		if (v && (v->_buttonMask || v->_latchMask || v->_stickTouch || v->_lookTouch
				|| v->_stickValue.dx != 0.0 || v->_stickValue.dy != 0.0)) {
			if (!v->_releasedWhileHidden) {
				v->_releasedWhileHidden = YES;
				NSLog(@"perfectdark: [touch] layer hidden while holding — releasing");
			}
			[v releaseHeld:YES];
		}
		// ...but a roll IS published while hidden, because with a pad connected
		// hidden is the normal state and the pad's double-flick roll (D-037)
		// has nowhere else to be played from.
		if (v) {
			[v publishRoll];
		}
		return;
	}
	[v publish];
}

/**
 * The engine's answers the chrome depends on, asked once a frame whatever else
 * is going on: is a menu dialog up, and should the gear be showing (D-037).
 */
- (void)refreshEngineChrome
{
	// The cached settings live here rather than in -publish for the same reason
	// the gear does (D-037): a hidden layer never reaches -publish, so a pad
	// player's cache was whatever the very first read gave and nothing could
	// ever correct it. Every 60th frame, which is the safety net; the paths
	// that WRITE one of these call -applySettings and do not wait for it.
	if ((++_publishes % 60) == 0) {
		[self refreshCachedSettings];
	}

	// The routing watchdog (D-041). Round Q asserted the three things that can
	// make a VISIBLE view unreachable from inside its own window, and asserted
	// them only when the layer came back from hidden - and the user's touch died
	// on a layer that was never hidden, for a reason that is one level up:
	// UIKit was routing his finger to a different window. Once a second is
	// often enough to catch it within a moment of it happening and cheap
	// enough to leave on (one hit test over a dozen views, measured below the
	// profiler's resolution), and unlike everything else here it can HEAL:
	// making the game's window key again is what a scene that lost its key
	// window needs.
	if ((_publishes % 120) == 0) {
		[self routeWatchdogTick];
	}

	const BOOL wasMenuOpen = _menuOpen;
	_menuOpen = menuIosDialogIsOpen() ? YES : NO;
	if (_menuOpen != wasMenuOpen && !_editing) {
		[self applyMenuChrome];
	}
	// A finger still down when the dialog closes under it (a pad's B, a timer)
	// would never be lifted - -liftPointerAt: only runs while a menu is open -
	// and the next menu's touches would be refused as a second finger.
	if (!_menuOpen && _pointerTouch) {
		_pointerTouch = nil;
		_pointerDown = NO;
		_pointerScrolled = NO;
	}
	[self applyChipRules];
	[self updateGearVisibility];
}

/**
 * A roll in flight, with nothing else to say (the layer is hidden because a pad
 * is connected). Same frame script as -publish's, which is the point: one roll
 * implementation, reached by a double tap or by a double flick.
 */
- (void)publishRoll
{
	if (_rollFrames <= 0) {
		// One trailing frame of zeroes, so the strafe ends where the script says
		// it ends rather than staying latched in the injected pad.
		if (_sentMask || _sentStick.dx != 0.0 || _sentStick.dy != 0.0) {
			inputIosPadSet(0, 0, 0);
			inputIosPadSetRStick(0, 0);
			_sentMask = 0;
			_sentStick = CGVectorMake(0, 0);
		}
		return;
	}

	unsigned mask = 0;
	const int dir = _rollDir;
	if (_rollFrames <= kRollPressBegin && _rollFrames > kRollPressEnd) {
		mask |= PD_CK_ROLL;
	}
	_rollFrames--;

	if (_cControlStyle == 0) {
		inputIosPadSetRStick(dir * 127, 0);
	} else {
		inputIosPadSetRStick(0, 0);
		mask |= (dir < 0) ? PDPadCLeft : PDPadCRight;
	}
	inputIosPadSet(mask, 0, 0);
	_sentMask = mask;
	_sentStick = CGVectorMake(dir, 0);
}

/**
 * Start a roll. The ONE place _rollFrames is armed (D-037).
 *
 * Both gestures land here: -noteStickTapAt: (a double tap in the touch stick's
 * region) and PDController's double flick of a pad's left stick. They share the
 * frame script in -publish/-publishRoll rather than each writing their own, and
 * they share PDDefDoubleTapRoll, which is also what turns Mod.CombatRoll on in
 * the engine - upstream ships the move disabled (D-032).
 */
- (BOOL)startRollDirection:(int)dir source:(NSString *)source
{
	if (!_cDoubleTapRoll || _menuOpen || _editing || _rollFrames > 0 || dir == 0) {
		return NO;
	}
	_rollDir = (dir < 0) ? -1 : +1;
	_rollFrames = kRollFrames;
#if !TARGET_OS_VISION
	[_haptics impactOccurred];
#endif
	NSLog(@"perfectdark: [touch] roll %@ (%@)", _rollDir < 0 ? @"LEFT" : @"RIGHT", source);
	return YES;
}

/** Drop every held button, the stick and any roll in flight. */
- (void)releaseEverything
{
	[self releaseHeld:NO];
}

/** ...keeping a roll in flight when `keepRoll`, which is the hidden-layer path. */
- (void)releaseHeld:(BOOL)keepRoll
{
	for (PDTouchButtonView *b in _buttons) {
		if (b.held) { b.held = NO; }
	}
	if (_leftFire.held) { _leftFire.held = NO; }
	for (PDTouchButtonView *b in _menuButtons) {
		if (b.held) { b.held = NO; }
	}
	[_buttonTouches removeAllObjects];
	[self clearAimDrag];
	[self clearWheel];
	_buttonMask = 0;
	_unpublishedMask = 0;
	_latchMask = 0;
	if (!keepRoll) {
		_rollFrames = 0;
	}
	_stickTouch = nil;
	_lookTouch = nil;
	_stickValue = CGVectorMake(0, 0);
	_pendingLookX = _pendingLookY = 0;
	[self hideStickChrome];
	inputIosPadSet(0, 0, 0);
	inputIosPadSetRStick(0, 0);
	_sentMask = 0;
	_sentStick = CGVectorMake(0, 0);
}

/**
 * The stuck-control watchdog (D-034).
 *
 * Every touch this layer tracks is supposed to be released by
 * touchesEnded:/touchesCancelled:, and the strong references above are what
 * make that reliable. This is the belt to that pair of braces: once a frame,
 * any tracked touch whose PHASE says the finger is already off the glass is
 * lifted as if the callback had arrived, and the fact is written to
 * Documents/touch-watchdog.txt with what was held.
 *
 * It is a diagnostic as much as a fix. If the user ever sees the stick stick
 * again, that file says which control it was, what phase the touch was in, and
 * how long ago the finger actually left - which is the evidence this round did
 * not have.
 */
- (void)runTouchWatchdog
{
	static const char *phases[] = { "began", "moved", "stationary", "ended", "cancelled", "regionEntered", "regionMoved", "regionExited" };
	NSMutableString *fired = nil;
	#define PD_DEAD(t) ((t) != nil && ((t).phase == UITouchPhaseEnded || (t).phase == UITouchPhaseCancelled))
	#define PD_NOTE(what, t) do { \
		if (!fired) { fired = [NSMutableString string]; } \
		const NSUInteger ph = (NSUInteger)(t).phase; \
		[fired appendFormat:@"%@(phase=%s) ", what, ph < sizeof(phases)/sizeof(phases[0]) ? phases[ph] : "?"]; \
	} while (0)

	if (PD_DEAD(_stickTouch)) {
		PD_NOTE(@"stick", _stickTouch);
		[self liftStickTouchAt:_stickOrigin];
	}
	if (PD_DEAD(_lookTouch)) {
		PD_NOTE(@"look", _lookTouch);
		_lookTouch = nil;
		_lookLead = CGVectorMake(0, 0);
	}
	if (PD_DEAD(_aimDragTouch)) {
		PD_NOTE(@"aim", _aimDragTouch);
		[self clearAimDrag];
	}
	if (PD_DEAD(_pointerTouch)) {
		PD_NOTE(@"pointer", _pointerTouch);
		[self liftPointerAt:_pointerPoint];
	}
	// A chip whose touch died keeps its mask bit down for ever; the map is
	// walked rather than indexed because the dead key is exactly what we are
	// looking for.
	NSMutableArray<UITouch *> *deadChips = nil;
	for (UITouch *t in _buttonTouches.keyEnumerator) {
		if (PD_DEAD(t)) {
			if (!deadChips) { deadChips = [NSMutableArray array]; }
			[deadChips addObject:t];
		}
	}
	for (UITouch *t in deadChips) {
		PDTouchButtonView *b = [_buttonTouches objectForKey:t];
		PD_NOTE(b.label ?: @"chip", t);
		if (b) {
			[self liftChip:b latch:NO];   // a dead touch is not a tap
			if ([self isAimChip:b]) { [self clearAimDrag]; }
			if ([self isWheelChip:b]) { [self clearWheel]; }
		}
		[_buttonTouches removeObjectForKey:t];
	}
	#undef PD_DEAD
	#undef PD_NOTE

	if (!fired) {
		return;
	}
	NSLog(@"perfectdark: [touch] WATCHDOG lifted %@", fired);
	[self noteWatchdog:fired];
}

/**
 * One line into Documents/touch-watchdog.txt. Separate from the detection so
 * the bridge can exercise the REPORTING half (`touch watchdogtest`) - the
 * detection half needs a real UITouch whose end callback never arrives, which
 * is precisely the thing no script can manufacture.
 */
/**
 * What the layer is holding, as one line of `state`.
 *
 * Player position is a poor instrument for "is the stick stuck": a body can
 * drift on a slope or be shoved by a guard. This is the thing that was actually
 * wrong - what the shell last handed the engine - and it reads zero the moment
 * the layer lets go.
 */
- (NSString *)heldReport
{
	return [[self heldLines] stringByAppendingString:[self cornerGeometryReport]];
}

- (NSString *)heldLines
{
	return [NSString stringWithFormat:
		@"touch_sent_mask=0x%x\ntouch_sent_stick=%.2f,%.2f\n"
		 "touch_mask=0x%x\ntouch_stick=%.2f,%.2f\ntouch_tracking=%d%d%d\ntouch_roll=%d\n"
		 "touch_hidden=%d\ntouch_pad=%d\ntouch_menu=%d\ngear_hidden=%d\n"
		 "touch_rollgesture=%d\ntouch_editing=%d\ntouch_aimdrag=%d\n"
		 "touch_wheel=%d\ntouch_wheel_stick=%.2f,%.2f\ntouch_alt_hidden=%d\ntouch_alt_engaged=%d\n"
		 "touch_user_hidden=%@\ntouch_edit_selected=%@\ntouch_hide_badge=%@\n"
		 "touch_latch=%d\ntouch_latched_taps=%u\n"
		 "pointer_valid=%d\npointer_down=%d\npointer_xy=%.1f,%.1f\n"
		 "pointer_published=%.1f,%.1f\npointer_engine=%d\npointer_click=%d\n",
		_sentMask, _sentStick.dx, _sentStick.dy,
		_buttonMask, _stickValue.dx, _stickValue.dy,
		_stickTouch != nil, _lookTouch != nil, _pointerTouch != nil, _rollFrames,
		(int)self.hidden, (int)self.padConnected, (int)_menuOpen,
		_gear ? (int)_gear.hidden : -1,
		(int)_cDoubleTapRoll, (int)_editing, (int)_aimDragArmed,
		(int)_wheelArmed, _wheelStick.dx, _wheelStick.dy, _altChip ? (int)_altChip.hidden : -1,
		_altChip ? (int)_altChip.engaged : -1,
		_userHidden.count ? [[_userHidden.allObjects sortedArrayUsingSelector:@selector(compare:)]
			componentsJoinedByString:@","] : @"-",
		_editSelected ?: @"-",
		(_hideBadge && !_hideBadge.hidden)
			? [NSString stringWithFormat:@"%.0f,%.0f", _hideBadge.center.x, _hideBadge.center.y] : @"-",
		(int)sTapLatch, _latchedTaps,
		(int)_pointerValid, (int)_pointerDown, _pointerPoint.x, _pointerPoint.y,
		_pointerPublished.x, _pointerPublished.y, (int)(inputIosPointerIsActive() != 0),
		_clickFrames];
}

/** One chip by label, or nil. */
- (nullable PDTouchButtonView *)chipForLabel:(NSString *)label
{
	for (PDTouchButtonView *b in [_buttons arrayByAddingObjectsFromArray:_menuButtons]) {
		if ([b.label isEqualToString:label]) {
			return b;
		}
	}
	return nil;
}

/**
 * The top-corner geometry in WINDOW coordinates: the gear, the START and BACK
 * chips (which share START's default spot), and both safe areas. The views
 * report their own frames - the instrument for "is the gear level with PAUSE"
 * (D-076), as `state` rows and as a log line whenever it changes.
 */
- (NSString *)cornerGeometryReport
{
	UIWindow *win = self.window;
	NSString *(^rect)(UIView *) = ^NSString *(UIView *v) {
		if (!v || !v.superview) {
			return @"none";
		}
		CGRect r = [v.superview convertRect:v.frame toView:nil];
		return [NSString stringWithFormat:@"%.1f,%.1f,%.1f,%.1f cy=%.1f",
			r.origin.x, r.origin.y, r.size.width, r.size.height, CGRectGetMidY(r)];
	};
	UIEdgeInsets ws = win ? win.safeAreaInsets : UIEdgeInsetsZero;
	UIEdgeInsets os = self.safeAreaInsets;
	return [NSString stringWithFormat:
		@"geo_window=%.1fx%.1f\ngeo_window_safe=%.1f,%.1f,%.1f,%.1f\n"
		 "geo_overlay=%@\ngeo_overlay_safe=%.1f,%.1f,%.1f,%.1f\n"
		 "geo_gear=%@\ngeo_start=%@\ngeo_back=%@\n",
		win.bounds.size.width, win.bounds.size.height, ws.top, ws.left, ws.bottom, ws.right,
		rect(self), os.top, os.left, os.bottom, os.right,
		rect(_gear), rect([self chipForLabel:@"START"]), rect([self chipForLabel:@"BACK"])];
}

- (void)noteWatchdog:(NSString *)what
{
	NSString *line = [NSString stringWithFormat:@"%@ frame=%llu lifted %@(mask=0x%x stick=%.2f,%.2f menu=%d hidden=%d)\n",
		NSDate.date.description, (unsigned long long)PDShell.shared.frameCount, what,
		_buttonMask, _stickValue.dx, _stickValue.dy, (int)_menuOpen, (int)self.hidden];
	NSString *path = [PDShell.shared.documentsPath stringByAppendingPathComponent:@"touch-watchdog.txt"];
	NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
	if (!fh) {
		[line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:NULL];
	} else {
		[fh seekToEndOfFile];
		[fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
		[fh closeFile];
	}
	return;
}

- (void)publish
{
	[self runTouchWatchdog];
	// The stick's layers, moved once per frame rather than once per touch
	// sample (D-034).
	[self applyStickChrome];

	if (_editing) {
		// Placing buttons is not playing. Nothing this layer knows reaches the
		// engine while the editor is open - otherwise dragging FIRE across the
		// screen would empty a magazine into a wall.
		inputIosPadSet(0, 0, 0);
		inputIosPadSetRStick(0, 0);
		_sentMask = 0;
		_sentStick = CGVectorMake(0, 0);
		_latchMask = 0;
		_unpublishedMask = 0;
		if (inputIosPointerIsActive()) {
			inputIosPointerClear();
		}
		return;
	}

	// D-086: a press lifted before this publish still goes out, once.
	unsigned mask = _buttonMask | _latchMask;
	_latchMask = 0;
	_unpublishedMask = 0;

	// _menuOpen and the gear were refreshed by +publishInput before it decided
	// whether to call this at all (D-037), so by here both are this frame's.
	// bean's aim-mode mirror appears and disappears with AIM.
	{
		const BOOL want = [self leftFireVisible];
		if (_leftFire.hidden == want) {
			_leftFire.hidden = !want;
			if (want) {
				_leftFire.center = [self centreForLabel:_leftFire.label radius:_leftFire.radius];
			} else if (_leftFire.held) {
				_leftFire.held = NO;
				_buttonMask &= ~_leftFire.mask;
				mask &= ~_leftFire.mask;
			}
		}
	}

	// The double-tap roll, played out over a few frames (D-032): a full strafe
	// the whole time, with the roll button pressed once part-way through -
	// bondmove.c:1765 reads it on the button's EDGE, and bwalkTryRoll() reads
	// the strafe for the direction.
	int rollStrafe = 0;
	if (_rollFrames > 0) {
		rollStrafe = _rollDir;
		if (_rollFrames <= kRollPressBegin && _rollFrames > kRollPressEnd) {
			mask |= PD_CK_ROLL;
		}
		_rollFrames--;
	}

	_sentStick = rollStrafe ? CGVectorMake(rollStrafe, 0) : _stickValue;
	if (_cControlStyle == 0) {
		// Dual analogue: the stick IS movement, on the axis that has a walk
		// speed (D-022). -128..127 is the N64 pad's range; screen-down is
		// pad-negative, the same sign convention inputReadController() uses for
		// the real stick. A roll in flight owns the sideways axis for its few
		// frames - it IS the strafe the engine reads the direction from.
		inputIosPadSetRStick(rollStrafe ? rollStrafe * 127 : (int)lround(_stickValue.dx * 127.0),
		                     (int)lround(-_stickValue.dy * 127.0));
	} else {
		// The N64 styles: four digital C directions with a threshold (D-013).
		inputIosPadSetRStick(0, 0);
		if (_stickValue.dy < -kMoveThreshold) mask |= PDPadCUp;
		if (_stickValue.dy > kMoveThreshold)  mask |= PDPadCDown;
		if (rollStrafe < 0 || (!rollStrafe && _stickValue.dx < -kMoveThreshold)) mask |= PDPadCLeft;
		if (rollStrafe > 0 || (!rollStrafe && _stickValue.dx > kMoveThreshold))  mask |= PDPadCRight;
	}

	if (_tapConfirmFrames > 0) {
		_tapConfirmFrames--;
		mask |= PDPadA;   // "Use / Accept"
	}

	// The weapon wheel's drag is the LEFT stick, which is what the active menu
	// reads (activemenutick.c) and, under CONTROLMODE_PC, nothing else the shell
	// drives - look is degrees and the touch stick is the right stick. -128..127
	// with screen-down pad-negative, the convention of every stick here.
	int wheelX = 0, wheelY = 0;
	if (_wheelArmed && (mask & PD_CK_RADIAL)) {
		wheelX = (int)lround(_wheelStick.dx * 127.0);
		wheelY = (int)lround(-_wheelStick.dy * 127.0);
	}
	inputIosPadSet(mask, wheelX, wheelY);
	_sentMask = mask;

	// The menu pointer. Active ONLY while a dialog is open - see overlay 0019.
	CGSize sz = self.bounds.size;
	if (_menuOpen && _pointerValid && sz.width > 0 && sz.height > 0) {
		// The button is suppressed on any frame the pointer MOVED, so the
		// highlight lands on the item under the finger one frame before the
		// click arrives. menuProcessInput() acts on inputs.select against the
		// focus it already had, so moving and clicking in the same frame
		// chooses whatever was highlighted a moment ago - which is how
		// "Game Pak" reliably selected "Cancel". A finger is down for at least
		// three frames, so nothing is lost by spending one of them aiming.
		// "Moved" has to have SLOP, and its absence was a second bug in
		// the user's report (D-043): a real fingertip jitters by a fraction of a
		// point every frame it is down, so an exact CGPointEqualToPoint test is
		// false on EVERY frame and the click is suppressed for ever - the
		// highlight follows the finger and nothing is ever chosen. An injected
		// tap holds a mathematically identical point, so every scripted menu
		// test in this port's history passed through the one branch a finger
		// can never reach. Half a point is below what a panel can resolve and
		// well under the aiming error the suppression exists to prevent.
		// D-083: the button is no longer the finger. It is the click a lifted
		// TAP owes (-liftPointerAt:), played out here at the lift point: an aim
		// frame, then kMenuClickFrames-1 frames down. The aim-then-click rule
		// above still holds - the point is frozen for the whole click, so only
		// its first frame can have moved.
		const CGFloat kPointerStillSlop = 0.5;
		BOOL button = NO;
		CGPoint at = _pointerPoint;
		if (_clickFrames > 0) {
			at = _clickPoint;
			button = _clickFrames < kMenuClickFrames;
			if (--_clickFrames == 0 && _clickQueued) {
				_clickQueued = NO;
				_clickFrames = kMenuClickFrames;
				_clickPoint = _clickQueuedPoint;
			}
		}
		const BOOL moved = hypot(at.x - _pointerPublished.x,
		                         at.y - _pointerPublished.y) > kPointerStillSlop;
		_pointerPublished = at;
		inputIosPointerSet((float)(at.x / sz.width),
		                   (float)(at.y / sz.height),
		                   (button && !moved) ? 1 : 0);
		if (_pendingWheel) {
			inputIosPointerAddWheel(_pendingWheel);
			_pendingWheel = 0;
		}
	} else if (!_menuOpen) {
		if (inputIosPointerIsActive()) {
			inputIosPointerClear();
		}
		_pointerValid = NO;
		_pointerDown = NO;
		_pendingWheel = 0;
		_clickFrames = 0;
		_clickQueued = NO;
	}

	if (_pendingLookX != 0.0 || _pendingLookY != 0.0) {
		inputIosLookAddDegrees((float)_pendingLookX, (float)_pendingLookY);
		_pendingLookX = 0.0;
		_pendingLookY = 0.0;
	}
}

// ---------------------------------------------------------------------------
// Bridge-driven synthetic input

- (NSString *)hitTestReportAtPoint:(CGPoint)p
{
	if (self.hidden) {
		return @"MISS overlay=hidden";
	}
	if (!CGRectContainsPoint(self.bounds, p)) {
		return @"MISS outside-overlay";
	}
	if (_editing) {
		PDTouchButtonView *chip = [self editChipAtPoint:p];
		return chip ? [NSString stringWithFormat:@"editing:%@ centre=%.0f,%.0f",
			chip.label, chip.center.x, chip.center.y] : @"editing";
	}
	PDTouchButtonView *b = [self buttonAtPoint:p];
	if (b) {
		return [NSString stringWithFormat:@"button:%@ mask=0x%x centre=%.0f,%.0f",
			b.label, b.mask, b.center.x, b.center.y];
	}
	if (_gear && !_gear.hidden &&
			CGRectContainsPoint([self convertRect:_gear.frame fromView:_gear.superview], p)) {
		return @"gear";
	}
	if (_menuOpen) {
		CGSize sz = self.bounds.size;
		return [NSString stringWithFormat:@"menu norm=%.3f,%.3f", p.x / sz.width, p.y / sz.height];
	}
	if (p.x < self.bounds.size.width * kStickZoneFrac) {
		return @"stick";
	}
	return @"look";
}

- (NSString *)injectTapAtPoint:(CGPoint)p holdMilliseconds:(NSInteger)ms
{
	NSString *what = [self hitTestReportAtPoint:p];
	if ([what hasPrefix:@"MISS"]) {
		return what;
	}

	if ([what isEqualToString:@"gear"]) {
		[self openSettings];
		return what;
	}

	if (_editing) {
		// In the editor a tap is not a press: it is a finger down and up through
		// the editor's own path - select a chip, or hit the selected chip's eye
		// badge (D-088). Moving a chip is `drag`.
		NSString *r = [self editBeganAt:p];
		if (_dragChip) {
			[self commitDrag];
		}
		return [NSString stringWithFormat:@"%@ %@", what, r];
	}

	// A synthetic touch has no UITouch, so the handlers are driven with nil and
	// the release is by point rather than by identity - which is why only one
	// synthetic touch may be in flight at a time.
	[self beginTouchAt:p touch:nil];

	PDTouchButtonView *b = [self buttonAtPoint:p];
	if (ms <= 0 && b) {
		// HOLD 0 (D-086): the lift in the same delivery as the press, with no
		// frame between them - what UIKit does when the system's edge gate
		// releases a touch it held back. The instrument for the latch.
		// HOLD < 0 (`tap X Y cancel`): the same, but CANCELLED - touchesCancelled's
		// path, which must never become a press.
		[self liftChip:b latch:(ms == 0)];
		if (ms < 0) {
			if ([self isAimChip:b]) { [self clearAimDrag]; }
			if ([self isWheelChip:b]) { [self clearWheel]; }
			return [what stringByAppendingString:@" hold=cancel"];
		}
		if ([self isAimChip:b]) { [self clearAimDrag]; }
		if ([self isWheelChip:b]) { [self clearWheel]; }
		return [what stringByAppendingString:@" hold=0"];
	}
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(16, ms) * NSEC_PER_MSEC)),
		dispatch_get_main_queue(), ^{
			if (b) {
				[self liftChip:b latch:YES];
				if ([self isAimChip:b]) { [self clearAimDrag]; }
				if ([self isWheelChip:b]) { [self clearWheel]; }
			} else if (self->_menuOpen) {
				[self liftPointerAt:p];
			} else if (p.x < self.bounds.size.width * kStickZoneFrac) {
				self->_stickTouch = nil;
				self->_stickValue = CGVectorMake(0, 0);
				[self hideStickChrome];
			} else {
				self->_lookTouch = nil;
				self->_tapConfirmFrames = 3;
			}
		});

	return what;
}

/**
 * Two taps at one point, from a script.
 *
 * simctl's injected events bypass UIKit, so the roll gesture cannot be driven
 * from outside the process at all; this is the same pair of touch-downs a thumb
 * makes, through the same handler.
 */
- (NSString *)injectDoubleTapAtPoint:(CGPoint)p
{
	NSString *what = [self hitTestReportAtPoint:p];
	if ([what hasPrefix:@"MISS"]) {
		return what;
	}
	// The first tap is lifted the way a finger lifts it - through the arming
	// rule in the touch-end path (short hold, no excursion) - so the bridge
	// proves the same gesture a thumb makes, not a shortcut past it.
	[self beginTouchAt:p touch:nil];
	[self liftStickTouchAt:p];
	[self beginTouchAt:p touch:nil];
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(80 * NSEC_PER_MSEC)),
		dispatch_get_main_queue(), ^{
			self->_stickTouch = nil;
			self->_stickValue = CGVectorMake(0, 0);
			[self hideStickChrome];
		});
	return [NSString stringWithFormat:@"%@ doubletap roll=%@ frames=%d", what,
		_rollFrames ? (_rollDir < 0 ? @"LEFT" : @"RIGHT") : @"none", _rollFrames];
}

- (NSString *)injectStreamFrom:(CGPoint)p by:(CGVector)perStep steps:(int)steps intervalMs:(double)ms
{
	NSString *what = [self hitTestReportAtPoint:p];
	if ([what hasPrefix:@"MISS"] || _editing) {
		return what;
	}
	steps = MAX(1, MIN(4000, steps));
	ms = MAX(1.0, MIN(1000.0, ms));

	[self beginTouchAt:p touch:nil];
	PDTouchButtonView *aimChip = [self buttonAtPoint:p];
	if (![self isAimChip:aimChip] && ![self isWheelChip:aimChip]) {
		aimChip = nil;   // (or the WHEEL chip: the same hold-drag-lift, D-085)
	}
	NSLog(@"perfectdark: [touch] stream %@ %d steps of %.1f,%.1f every %.1f ms",
		what, steps, perStep.dx, perStep.dy, ms);

	for (int i = 1; i <= steps; i++) {
		CGPoint at = CGPointMake(p.x + perStep.dx * i, p.y + perStep.dy * i);
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms * i * NSEC_PER_MSEC)),
			dispatch_get_main_queue(), ^{
				if ([what isEqualToString:@"stick"]) {
					[self moveStickTo:at];
				} else if ([what isEqualToString:@"look"]) {
					[self addLookFrom:CGPointMake(at.x - perStep.dx, at.y - perStep.dy) to:at];
				} else if ([what hasPrefix:@"menu"]) {
					[self movePointerTo:at];
				} else if (self->_wheelArmed) {
					// A stream that started on the WHEEL chip is the wheel's
					// drag: the radial menu stays open and the slice follows.
					[self moveWheelTo:at];
				} else if (self->_aimDragArmed) {
					// A stream that started on the AIM chip is the hold-and-drag
					// aim: R stays down for the length of the stream and the
					// drag feeds the same look path a thumb's would (D-046).
					[self addAimDragTo:at];
				}
			});
	}
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms * (steps + 1) * NSEC_PER_MSEC)),
		dispatch_get_main_queue(), ^{
			self->_stickTouch = nil;
			self->_stickValue = CGVectorMake(0, 0);
			self->_lookTouch = nil;
			[self hideStickChrome];
			if ([what hasPrefix:@"menu"]) {
				// A stream is a whole finger: it lifts (D-083), and a lift is
				// where a menu tap clicks - a stream that travelled does not.
				[self liftPointerAt:CGPointMake(p.x + perStep.dx * steps, p.y + perStep.dy * steps)];
			}
			if (aimChip) {
				// The lift: the same release a finger makes, which is what
				// leaves aim mode.
				aimChip.held = NO;
				self->_buttonMask &= ~aimChip.mask;
				[self clearAimDrag];
				[self clearWheel];
			}
			NSLog(@"perfectdark: [touch] stream done");
		});

	return [NSString stringWithFormat:@"%@ stream=%d@%.1fms", what, steps, ms];
}

- (NSString *)movePointerOnlyTo:(CGPoint)p
{
	if (!_menuOpen) {
		return @"MISS no-menu";
	}
	CGSize sz = self.bounds.size;
	_pointerPoint = p;
	_pointerValid = YES;
	_pointerDown = NO;
	_pointerScrolled = NO;
	return [NSString stringWithFormat:@"menu norm=%.3f,%.3f", p.x / sz.width, p.y / sz.height];
}

- (NSString *)injectDragFrom:(CGPoint)p by:(CGVector)d
{
	NSString *what = [self hitTestReportAtPoint:p];
	if ([what hasPrefix:@"MISS"]) {
		return what;
	}

	if (_editing) {
		// The scripted half of the layout editor: pick the chip under p, walk
		// it to p+d, and leave it HELD for a beat so a screenshot taken right
		// after this command shows the drag in progress rather than its result.
		PDTouchButtonView *chip = [self editChipAtPoint:p];
		if (!chip) {
			return @"MISS no-chip-here";
		}
		_dragChip = chip;
		_dragGrab = CGVectorMake(chip.center.x - p.x, chip.center.y - p.y);
		_dragUnit = CGPointMake(chip.center.x / MAX(1.0, self.bounds.size.width),
		                        chip.center.y / MAX(1.0, self.bounds.size.height));
		_dragStartUnit = _dragUnit;
		_editSelected = chip.label;
		chip.held = YES;
		for (int i = 1; i <= 8; i++) {
			[self dragChipTo:CGPointMake(p.x + d.dx * i / 8, p.y + d.dy * i / 8)];
		}
		// The same commit a lifted finger does, so what a script proves is what
		// a player gets.
		CGPoint landed = chip.center;
		[self commitDrag];
		return [NSString stringWithFormat:@"editing:%@ moved to %.0f,%.0f",
			chip.label, landed.x, landed.y];
	}

	[self beginTouchAt:p touch:nil];

	const int steps = 8;
	CGPoint at = p;
	for (int i = 1; i <= steps; i++) {
		CGPoint next = CGPointMake(p.x + d.dx * i / steps, p.y + d.dy * i / steps);
		if ([what isEqualToString:@"stick"]) {
			[self moveStickTo:next];
		} else if ([what isEqualToString:@"look"]) {
			[self addLookFrom:at to:next];
		} else if ([what hasPrefix:@"menu"]) {
			[self movePointerTo:next];
		} else if (_aimDragArmed) {
			[self addAimDragTo:next];
		}
		// A drag that started on a button is a button press being held and
		// dragged off; it must not also turn the view, or a validation run
		// could pass its look assertion while pointing at a button.
		at = next;
	}

	if ([what hasPrefix:@"menu"]) {
		[self liftPointerAt:at];
		return [NSString stringWithFormat:@"%@ dragged=%.0f,%.0f wheel=%d pointer=%.0f,%.0f",
			what, d.dx, d.dy, _pendingWheel, _pointerPoint.x, _pointerPoint.y];
	}

	if (_aimDragArmed) {
		// Held for a beat so a screenshot taken right after this command shows
		// aim mode ENGAGED, then lifted the way a finger lifts it.
		PDTouchButtonView *aimChip = [self buttonAtPoint:p];
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1500 * NSEC_PER_MSEC)),
			dispatch_get_main_queue(), ^{
				if (aimChip) {
					aimChip.held = NO;
					self->_buttonMask &= ~aimChip.mask;
				}
				[self clearAimDrag];
				NSLog(@"perfectdark: [touch] aim drag released");
			});
	} else if ([what isEqualToString:@"look"]) {
		_lookTouch = nil;
		_lookLast = at;
	} else {
		// A synthetic stick drag is released after a beat, so a validation run
		// sees movement for a few frames and then a stick back at rest rather
		// than a player walking into a wall for the rest of the session.
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(400 * NSEC_PER_MSEC)),
			dispatch_get_main_queue(), ^{
				self->_stickTouch = nil;
				self->_stickValue = CGVectorMake(0, 0);
				[self hideStickChrome];
			});
	}

	return [NSString stringWithFormat:@"%@ dragged=%.0f,%.0f look_deg=%.2f,%.2f stick=%.2f,%.2f",
		what, d.dx, d.dy, _pendingLookX, _pendingLookY, _stickValue.dx, _stickValue.dy];
}

@end
