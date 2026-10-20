// PDController.m — GCController first, per the family pad rules.
//
// Perfect Dark on a pad is already a solved problem inside the engine: SDL's
// game controller API drives inputReadController() (input.c:998-1040) with
// upstream's own default binds, and a pad paired to the phone arrives there as
// an SDL_GameController without this file doing anything at all. So what is
// left for the shell is the three things SDL cannot know:
//
//   1. **Explicit Goldenpad preset.** Existing engine bindings load normally.
//      The native settings action applies the requested semantic layout only
//      when chosen, preserving keyboard/D-pad binds and backing up the prior
//      state. Connecting a controller never reapplies this preset over edits.
//   2. **Look.** PD's right stick is NOT a look axis (docs/frame-map.md): it
//      goes into the N64 pad struct for the game's control styles. Twin-stick
//      look on a modern pad therefore has to come from the same degrees seam
//      the touch layer uses, dt-normalised so the feel does not change with the
//      frame rate, anchored at 120 Hz.
//   3. **Hide the touch overlay while a pad is connected**, and bring it back
//      when the pad goes away.
//   4. **The combat roll**, which is the user's on 0.0.0.7: "on gamepad, right
//      thumbstick click does a right roll. instead, it should be double tapping
//      left joystick LEFT or RIGHT to do a roll." Both halves live here - the
//      R3 bind is taken off the roll and the double flick replaces it (D-037) -
//      but the roll ITSELF is played by PDTouchOverlay, which is where the
//      touch layer's proven frame script already is.
#import <GameController/GameController.h>

#import "PDShell.h"
#import "PDDefaults.h"
#import "PDTouchOverlay.h"
#import "PDController.h"
#import "PDVision.h"
#import "PDWatchdog.h"

// port/include/input.h — the public bind API, declared here rather than in
// PDShell.h because taking R3 off the combat roll (D-037) is this file's
// business and nothing else asks.
extern void inputKeyBind(int idx, unsigned ck, int bind, unsigned vk);
extern const unsigned *inputKeyGetBinds(int idx, unsigned ck);
extern int inputGetKeyByName(const char *name);
extern int inputGetContKeyByName(const char *name);
extern const char *inputGetContKeyName(unsigned ck);

// Radial deadzone, the family constant.
static const float kPadDeadzone = 0.15f;
// The look integration is anchored here: a 120 Hz frame moves the view by
// exactly (speed / 120) degrees, and any other frame rate is scaled to match.
static const double kLookAnchorHz = 120.0;

// --- the double-flick roll (D-037) ------------------------------------------
// A flick is the stick going out past kFlickOut and coming back inside
// kFlickBack; two of them to the SAME side inside kFlickWindow are a roll. The
// hysteresis is the whole gesture: one threshold would make a stick resting
// near 0.7 chatter, and "back inside 0.3" is what makes a HELD stick - a player
// simply strafing - never complete a second flick and never roll.
static const float kFlickOut = 0.70f;
static const float kFlickBack = 0.30f;
static const NSTimeInterval kFlickWindow = 0.30;

@implementation PDController {
	NSTimeInterval _lastLook;
	// The double-flick state machine. _flickOut is the side of the excursion in
	// progress (0 = the stick is inside kFlickBack); _lastFlickSide/_lastFlickAt
	// are the flick that completed most recently.
	int _flickOut;
	int _lastFlickSide;
	NSTimeInterval _lastFlickAt;
	// While a script is feeding the left stick by hand, the REAL pad must stop
	// feeding it too - see -injectLeftStickX:.
	NSTimeInterval _injectUntil;
	BOOL _unbound;
}

+ (instancetype)shared
{
	static PDController *shared;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ shared = [PDController new]; });
	return shared;
}

/**
 * visionOS only: claim gamepad events for the app.
 *
 * The charter's Phase 5 trap, verbatim: "the pad is primary and must be claimed
 * with GCEventInteraction (GCUIEventTypeGamepad) or presses become gaze-pinch
 * events". Without this, xrOS routes a connected controller's buttons into the
 * system's pointer/selection machinery — the A button behaves like a pinch on
 * whatever the user is looking at — and GCController's own handlers see
 * nothing. With it, every gamepad event is delivered to the app and SDL's MFi
 * backend drives inputReadController() exactly as it does on iOS.
 *
 * It is attached to SDL's own UIWindow (a UIWindow is a UIView), which is the
 * first responder chain the game actually lives in, and only once.
 */
+ (void)claimGamepadEventsInWindow:(UIWindow *)window
{
#if TARGET_OS_VISION
	static BOOL done = NO;
	if (done || !window) {
		return;
	}
	done = YES;
	GCEventInteraction *gamepad = [[GCEventInteraction alloc] init];
	gamepad.handledEventTypes = GCUIEventTypeGamepad;
	[window addInteraction:gamepad];
	NSLog(@"perfectdark: [pad] GCEventInteraction installed (GCUIEventTypeGamepad claimed)");
#else
	(void)window;
#endif
}

- (void)start
{
	[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(padsChanged)
	                                           name:GCControllerDidConnectNotification object:nil];
	[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(padsChanged)
	                                           name:GCControllerDidDisconnectNotification object:nil];
	[GCController startWirelessControllerDiscoveryWithCompletionHandler:^{}];
	[self padsChanged];
}

/**
 * Take the combat roll off R3 (the user, 0.0.0.7; D-037).
 *
 * Upstream binds it there by default - `{ CK_0800, SDL_CONTROLLER_BUTTON_
 * RIGHTSTICK }`, input.c:239, plus inputMigrateRollBind() which moves Third
 * Person off the right stick to make room for it. On a twin-stick phone pad
 * that is a click a thumb makes by accident while looking, and it costs a roll
 * every time. The double flick below replaces it.
 *
 * Only the R3 SLOT is cleared, and only for the one contkey: the keyboard's C
 * and anything the player bound themselves are left exactly as they are, and
 * the whole thing runs ONCE per launch, so a player who deliberately binds R3
 * back to the roll from PD's own options page keeps it for that session.
 *
 * All four controllers, because a pad can be assigned to any of them. Public
 * input.h API throughout (no overlay patch); engine thread.
 */
static void pdUnbindRollFromR3(void)
{
	const int ck = inputGetContKeyByName("CK_0800");
	if (ck < 0) {
		NSLog(@"perfectdark: [pad] no CK_0800 — the roll bind was left alone");
		return;
	}
	for (int ctrl = 0; ctrl < 4; ctrl++) {
		char name[32];
		snprintf(name, sizeof(name), "JOY%d_RSTICK", ctrl + 1);
		const int vk = inputGetKeyByName(name);
		const unsigned *binds = inputKeyGetBinds(ctrl, (unsigned)ck);
		if (vk <= 0 || !binds) {
			continue;
		}
		for (int b = 0; b < 4; b++) {
			if (binds[b] == (unsigned)vk) {
				inputKeyBind(ctrl, (unsigned)ck, b, 0);
				NSLog(@"perfectdark: [pad] %s unbound from the combat roll (player %d)", name, ctrl + 1);
			}
		}
	}
}

+ (NSString *)applyGoldenpadLayout
{
	// Goldenpad's semantic actions, plus PD's distinct reload/alternate/radial.
	static const struct { const char *key; const char *button; } map[] = {
		{ "Z_TRIG", "RTRIGGER" }, { "R_TRIG", "LTRIGGER" },
		{ "CK_8000", "LSHOULDER" },
		{ "Y_BUTTON", "RSHOULDER" }, { "Y_BUTTON", "A" }, { "Y_BUTTON", "Y" },
		{ "B_BUTTON", "B" }, { "B_BUTTON", "X" },
		{ "X_BUTTON", "LSTICK" }, { "L_TRIG", "RSTICK" },
		{ "D_JPAD", "BACK" }, { "START_BUTTON", "START" },
		{ "ACCEPT_BUTTON", "A" }, { "CANCEL_BUTTON", "B" },
	};
	unsigned proposed[4][32][4];
	unsigned original[4][32][4];
	// This engine's public contkey enumeration has 32 entries. Refuse a new
	// incompatible engine rather than indexing a silently changed table.
	if (!inputGetContKeyName(31)[0] || inputGetContKeyName(32)[0])
		return @"Controller layout could not be applied to this engine version.";
	for (int player = 0; player < 4; player++) {
		NSMutableSet<NSNumber *> *buttons = [NSMutableSet set];
		for (unsigned i = 0; i < sizeof(map) / sizeof(map[0]); i++) {
			char name[64]; snprintf(name, sizeof(name), "JOY%d_%s", player + 1, map[i].button);
			int vk = inputGetKeyByName(name);
			if (vk <= 0) return @"A controller button is unavailable in this engine.";
			[buttons addObject:@(vk)];
		}
		for (unsigned ck = 0; ck < 32; ck++) {
			const unsigned *old = inputKeyGetBinds(player, ck);
			for (int slot = 0; slot < 4; slot++) {
				original[player][ck][slot] = old[slot];
				proposed[player][ck][slot] = [buttons containsObject:@(old[slot])] ? 0 : old[slot];
			}
		}
		for (unsigned i = 0; i < sizeof(map) / sizeof(map[0]); i++) {
			int ck = inputGetContKeyByName(map[i].key);
			if (ck < 0 || ck >= 32) return @"A Perfect Dark action is unavailable.";
			int slot = 0;
			while (slot < 4 && proposed[player][ck][slot]) slot++;
			if (slot == 4) return @"Your custom bindings leave no free slot. No bindings were changed.";
			char name[64]; snprintf(name, sizeof(name), "JOY%d_%s", player + 1, map[i].button);
			proposed[player][ck][slot] = inputGetKeyByName(name);
		}
	}
	// Keep an inspectable backup of the previous bindings before changing any.
	NSMutableArray *backup = [NSMutableArray array];
	for (int player = 0; player < 4; player++) {
		NSMutableArray *keys = [NSMutableArray array];
		for (int ck = 0; ck < 32; ck++) {
			[keys addObject:@[@(original[player][ck][0]), @(original[player][ck][1]),
				@(original[player][ck][2]), @(original[player][ck][3])]];
		}
		[backup addObject:keys];
	}
	if (![NSUserDefaults.standardUserDefaults objectForKey:@"pd.controller.beforeGoldenpad"])
		[NSUserDefaults.standardUserDefaults setObject:backup forKey:@"pd.controller.beforeGoldenpad"];
	for (int player = 0; player < 4; player++)
		for (unsigned ck = 0; ck < 32; ck++)
			for (int slot = 0; slot < 4; slot++)
				inputKeyBind(player, ck, slot, proposed[player][ck][slot]);
	// Goldenpad's LT always aims; the optional dual-trigger-fire mode conflicts.
	configSetValue("Mod.AkimboTriggers", "0");
	inputSaveBinds();
	if (!configSave("$S/pd.ini")) return @"Layout applied for this session, but saving pd.ini failed.";
	return @"Goldenpad layout applied. RT fires, LT aims, LB crouches; A/Y/RB change weapons; B/X interact. Click left stick to reload, right stick for alternate fire, and View/Back for the weapon wheel. D-pad navigation is unchanged.";
}

- (void)padsChanged
{
	BOOL any = PDTouchOverlayAnyPadConnected();
	NSLog(@"perfectdark: [pad] %lu connected%@", (unsigned long)GCController.controllers.count,
		any ? [NSString stringWithFormat:@" (%@)", GCController.controllers.firstObject.vendorName ?: @"?"] : @"");

	PDTouchOverlay.current.padConnected = any;
	// D-084: one lifecycle.txt line per connect/disconnect. A phone report of
	// "the touch controls did not hide" could not be answered from a devicectl
	// pull - this file had no pad lines - and the answer turned out to be the
	// On-screen controls row set to On (always), not anything the pad did.
	{
		static const char *modes[] = { "auto", "on", "off" };
		const NSInteger mode = PDDefInt(PDDefTouchMode);
		PDTouchOverlay *ov = PDTouchOverlay.current;
		PDLifecycle("pad %s: %lu GCController(s), touch mode %s, overlay %s",
			any ? "connected" : "absent", (unsigned long)GCController.controllers.count,
			(mode >= 0 && mode <= 2) ? modes[mode] : "?",
			!ov ? "not installed" : (ov.hidden ? "hidden" : "visible"));
	}

	if (any && !_unbound) {
		_unbound = YES;
		// Engine state, so: frame boundary, like everything else.
		[PDShell.shared enqueue:^{
			NSLog(@"perfectdark: [pad] engine sees controller 0 %@",
				inputControllerConnected(0) ? @"connected" : @"NOT connected");
			pdUnbindRollFromR3();
		}];
	}

	if (!any) {
		// Nothing half-done survives the pad going away: an excursion in
		// progress is not a flick, and a flick with no second half is not a
		// roll. (The overlay's own release-on-hide is D-034's.)
		_flickOut = 0;
		_lastFlickSide = 0;
		_lastFlickAt = 0;
	}
}

/** Radial deadzone, then the remaining range rescaled so it still reaches 1. */
static void pdRadialDeadzone(float *x, float *y)
{
	float mag = sqrtf(*x * *x + *y * *y);
	if (mag <= kPadDeadzone) {
		*x = 0.f;
		*y = 0.f;
		return;
	}
	float scaled = MIN(1.f, (mag - kPadDeadzone) / (1.f - kPadDeadzone));
	*x = *x / mag * scaled;
	*y = *y / mag * scaled;
}

- (void)tick
{
	GCController *pad = GCController.controllers.firstObject;
	if (!pad.extendedGamepad) {
		_lastLook = 0;
		return;
	}

	GCExtendedGamepad *gp = pad.extendedGamepad;

	// The left stick is PD's look axis under CONTROLMODE_PC, and a double flick
	// of it either way is the combat roll (D-037).
	if (NSDate.timeIntervalSinceReferenceDate >= _injectUntil) {
		[self noteLeftStickX:gp.leftThumbstick.xAxis.value];
	}

	float rx = gp.rightThumbstick.xAxis.value;
	float ry = gp.rightThumbstick.yAxis.value;
	pdRadialDeadzone(&rx, &ry);
	if (rx == 0.f && ry == 0.f) {
		_lastLook = NSDate.timeIntervalSinceReferenceDate;
		return;
	}

	NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
	double dt = (_lastLook > 0) ? (now - _lastLook) : (1.0 / kLookAnchorHz);
	_lastLook = now;
	// A hitch must not throw the view across the room.
	dt = MIN(MAX(dt, 1.0 / 240.0), 1.0 / 15.0);

	double speed = PDDefFloat(PDDefPadLookSpeed);   // degrees per second at full stick
	if (speed <= 0) {
		speed = 180.0;
	}
	double invert = PDDefBool(PDDefInvertY) ? -1.0 : 1.0;

	// Square response on the stick: precision near centre, full speed at the
	// edge, which is what every console shooter of this shape does.
	double fx = rx * fabs(rx);
	double fy = ry * fabs(ry);

	inputIosLookAddDegrees((float)(fx * speed * dt), (float)(-fy * speed * dt * invert));
}

/**
 * The double-flick roll detector (D-037). One x sample of the LEFT stick.
 *
 * Out past 0.70, back inside 0.30, out past 0.70 the same way again inside
 * 300 ms. The roll fires on the SECOND excursion rather than on its return, so
 * it comes out the instant the thumb commits, which is how the move reads on a
 * pad. Three properties fall out of the shape and all three are the point:
 *
 *  - a single flick never rolls (there is no second excursion);
 *  - a HELD stick never rolls (it never comes back inside 0.30, so no flick
 *    completes) - a player strafing hard is not asking for a roll;
 *  - flicking left then right never rolls (the sides must match).
 *
 * The roll itself is PDTouchOverlay's: one implementation, one setting
 * (PDDefDoubleTapRoll, which is also what turns Mod.CombatRoll on), whether the
 * gesture came from a thumb on glass or a thumb on a stick.
 */
- (NSString *)noteLeftStickX:(float)x
{
	const NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
	const float mag = fabsf(x);

	if (mag >= kFlickOut) {
		const int side = (x < 0) ? -1 : +1;
		if (_flickOut == side) {
			return @"lx: still out";
		}
		_flickOut = side;
		if (_lastFlickSide == side && (now - _lastFlickAt) <= kFlickWindow) {
			// Consumed: three flicks are one roll, not two.
			_lastFlickSide = 0;
			_lastFlickAt = 0;
			const BOOL rolled = [PDTouchOverlay.current startRollDirection:side
				source:[NSString stringWithFormat:@"pad double flick %@", side < 0 ? @"LEFT" : @"RIGHT"]];
			return rolled ? [NSString stringWithFormat:@"lx: ROLL %@", side < 0 ? @"LEFT" : @"RIGHT"]
			              : @"lx: second flick, roll refused (setting off, or a menu)";
		}
		return @"lx: first flick out";
	}

	if (mag < kFlickBack && _flickOut != 0) {
		_lastFlickSide = _flickOut;
		_lastFlickAt = now;
		_flickOut = 0;
		return @"lx: flick complete, armed";
	}

	return @"lx: idle";
}

/**
 * Dev instrument, and it has to SILENCE the real pad for half a second.
 *
 * -tick feeds this state machine one sample a frame from whatever stick is
 * attached, and the simulator always has one (its virtual "Gamepad", resting at
 * 0.0). So a scripted `pad lx 0.9` followed by `pad lx 0.95` had sixty frames of
 * 0.0 interleaved between them, which completed a flick the script never made
 * and turned "a held stick must not roll" into a roll. Measured, not reasoned:
 * the first run of the gate's held-stick probe rolled.
 *
 * The lockout is long enough to cover a whole scripted gesture and short enough
 * that a player's pad is back in charge before they notice. Nothing in the app
 * ever calls this.
 */
- (NSString *)injectLeftStickX:(float)x
{
	_injectUntil = NSDate.timeIntervalSinceReferenceDate + 0.5;
	return [self noteLeftStickX:x];
}

@end
