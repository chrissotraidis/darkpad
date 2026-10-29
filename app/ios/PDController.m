// PDController.m — GCController first, per the family pad rules.
//
// Perfect Dark on a pad is already a solved problem inside the engine: SDL's
// game controller API drives inputReadController() (input.c:998-1040) with
// upstream's own default binds, and a pad paired to the phone arrives there as
// an SDL_GameController without this file doing anything at all. So what is
// left for the shell is the three things SDL cannot know:
//
//   1. **Goldenpad layout.** A new install (no pd.ini yet) gets the Goldenpad
//      layout once, on the first engine frame. Existing pd.ini bindings load
//      normally and are never replaced; the native settings action applies the
//      same layout on request, preserving keyboard/D-pad binds and backing up
//      the prior state. Connecting a controller never reapplies it over edits.
//   2. **Look is the engine's.** With Input.PlayerN.SwapSticks=1 (upstream's
//      default) the right stick is the N64 stick, which CONTROLMODE_PC uses to
//      turn and pitch; the left stick is movement. The shell adds no pad look.
//   3. **Hide gameplay touch controls in Auto while a pad is connected.**
//      Menu navigation and the layout editor remain touchable.
//   4. Optional double-flick roll, using the touch layer's existing gesture
//      playback. Connection changes never rewrite the player's bindings.
#import <GameController/GameController.h>

#import "PDShell.h"
#import "PDDefaults.h"
#import "PDTouchOverlay.h"
#import "PDController.h"
#import "PDVision.h"
#import "PDWatchdog.h"

// Public engine binding API used only by the explicitly selected preset.
extern void inputKeyBind(int idx, unsigned ck, int bind, unsigned vk);
extern const unsigned *inputKeyGetBinds(int idx, unsigned ck);
extern int inputGetKeyByName(const char *name);
extern int inputGetContKeyByName(const char *name);
extern const char *inputGetContKeyName(unsigned ck);

// --- the double-flick roll (D-037) ------------------------------------------
// A flick is the stick going out past kFlickOut and coming back inside
// kFlickBack; two of them to the SAME side inside kFlickWindow are a roll. The
// hysteresis is the whole gesture: one threshold would make a stick resting
// near 0.7 chatter, and "back inside 0.3" is what makes a HELD stick - a player
// simply strafing - never complete a second flick and never roll.
static const float kFlickOut = 0.70f;
static const float kFlickBack = 0.30f;
static const NSTimeInterval kFlickWindow = 0.30;

// Set once the new-install controller default has been decided, so later
// launches never reconsider it.
static NSString *const kDefaultLayoutDecided = @"pd.controller.defaultLayoutDecided";

extern void inputSaveBinds(void);

// Set once the arrow keys have been taken off the N64 stick on this install.
static NSString *const kArrowsOffStick = @"pd.controller.arrowsOffStick";

/**
 * Arrow keys on the N64 stick are a desktop default. On iPhone and iPad the
 * system can deliver a controller's left stick and D-pad as arrow presses
 * (before iOS 18, or wherever the gamepad claim is unavailable), which then
 * drive the look stick at full deflection. Engine thread.
 */
static void pdRemoveArrowStickBinds(void)
{
#if TARGET_OS_MACCATALYST
	// Physical keyboard controls are part of the desktop game. The iOS
	// controller-to-arrow workaround must not erase the player's bindings.
	return;
#else
	static const char *const stickKeys[] = { "STICK_XNEG", "STICK_XPOS", "STICK_YNEG", "STICK_YPOS" };
	static const char *const arrows[] = { "LEFT", "RIGHT", "DOWN", "UP" };
	for (int player = 0; player < 4; player++) {
		for (int i = 0; i < 4; i++) {
			int ck = inputGetContKeyByName(stickKeys[i]);
			int vk = inputGetKeyByName(arrows[i]);
			if (ck < 0 || ck >= 32 || vk <= 0) continue;
			const unsigned *binds = inputKeyGetBinds(player, (unsigned)ck);
			for (int slot = 0; slot < 4; slot++) {
				if (binds[slot] == (unsigned)vk) inputKeyBind(player, (unsigned)ck, slot, 0);
			}
		}
	}
	inputSaveBinds();
#endif
}

@implementation PDController {
	// A new install: apply the Goldenpad layout on the first engine frame.
	BOOL _applyDefaultLayout;
	// The double-flick state machine. _flickOut is the side of the excursion in
	// progress (0 = the stick is inside kFlickBack); _lastFlickSide/_lastFlickAt
	// are the flick that completed most recently.
	int _flickOut;
	int _lastFlickSide;
	NSTimeInterval _lastFlickAt;
	// While a script is feeding the left stick by hand, the REAL pad must stop
	// feeding it too - see -injectLeftStickX:.
	NSTimeInterval _injectUntil;
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
	// iPhone and iPad as well (iOS 18+): without this the system also turns the
	// left stick and D-pad into arrow-key presses for UI focus, SDL delivers
	// them as keystrokes, and the arrows were bound to the N64 stick - so the
	// left stick moved AND spun the view at full deflection (device trace,
	// 2026-10-25: GC left 0.58 -> engine stick -128,127 plus the rstick).
	static BOOL done = NO;
	if (done || !window) {
		return;
	}
	if (@available(iOS 18.0, visionOS 2.0, *)) {
		done = YES;
		GCEventInteraction *gamepad = [[GCEventInteraction alloc] init];
		gamepad.handledEventTypes = GCUIEventTypeGamepad;
		[window addInteraction:gamepad];
		NSLog(@"perfectdark: [pad] GCEventInteraction installed (GCUIEventTypeGamepad claimed)");
	}
}

- (void)start
{
	// Before the engine starts, pd.ini's absence means nobody has bindings yet.
	NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
	if (![defaults boolForKey:kDefaultLayoutDecided]) {
		NSString *docs = PDShell.shared.documentsPath;
		_applyDefaultLayout = ![NSFileManager.defaultManager
			fileExistsAtPath:[docs stringByAppendingPathComponent:@"pd.ini"]];
		if (!_applyDefaultLayout) [defaults setBool:YES forKey:kDefaultLayoutDecided];
	}
	[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(padsChanged)
	                                           name:GCControllerDidConnectNotification object:nil];
	[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(padsChanged)
	                                           name:GCControllerDidDisconnectNotification object:nil];
	[GCController startWirelessControllerDiscoveryWithCompletionHandler:^{}];
	[self padsChanged];
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
	pdRemoveArrowStickBinds();
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


	if (!any) {
		// Nothing half-done survives the pad going away: an excursion in
		// progress is not a flick, and a flick with no second half is not a
		// roll. (The overlay's own release-on-hide is D-034's.)
		_flickOut = 0;
		_lastFlickSide = 0;
		_lastFlickAt = 0;
	}
}


// --- controller trace (PD_PAD_TRACE=1 at launch) -----------------------------
// What iOS reports for each physical control beside what SDL hands the engine
// and what the player then does, sampled at most every 0.1 s while anything is
// held. Written to Documents/pad-trace.txt, capped at 2 MB.
extern int inputIosPadDebug(int cidx, int *axes, int *swapped, int *devidx, const char **name);
extern int optionsGetControlMode(int mpchrnum);
extern signed char joyGetStickX(signed char contpadnum);
extern signed char joyGetStickY(signed char contpadnum);
extern signed char joyGetRStickX(signed char contpadnum);
extern signed char joyGetRStickY(signed char contpadnum);
extern unsigned int joyGetButtons(signed char contpadnum, unsigned int mask);
extern int SDL_NumJoysticks(void);

static void pdPadTrace(GCExtendedGamepad *gp)
{
	static int enabled = -1;
	static FILE *out;
	static NSTimeInterval last;
	static unsigned long long written;
	if (enabled < 0) {
		const char *e = getenv("PD_PAD_TRACE");
		enabled = e && !strcmp(e, "1");
		if (enabled) {
			NSString *docs = PDShell.shared.documentsPath;
			out = fopen([docs stringByAppendingPathComponent:@"pad-trace.txt"].fileSystemRepresentation, "w");
			enabled = out != NULL;
		}
	}
	if (!enabled || written > 2000000) return;

	int axes[4] = {0}, swapped = -1, devidx = -1;
	const char *name = "?";
	int have = inputIosPadDebug(0, axes, &swapped, &devidx, &name);
	float lx = gp.leftThumbstick.xAxis.value, ly = gp.leftThumbstick.yAxis.value;
	float rx = gp.rightThumbstick.xAxis.value, ry = gp.rightThumbstick.yAxis.value;
	int dpad = (gp.dpad.up.pressed ? 1 : 0) | (gp.dpad.down.pressed ? 2 : 0) | (gp.dpad.left.pressed ? 4 : 0) | (gp.dpad.right.pressed ? 8 : 0);
	int face = (gp.buttonA.pressed ? 1 : 0) | (gp.buttonB.pressed ? 2 : 0) | (gp.buttonX.pressed ? 4 : 0) | (gp.buttonY.pressed ? 8 : 0)
		| (gp.leftShoulder.pressed ? 16 : 0) | (gp.rightShoulder.pressed ? 32 : 0)
		| (gp.leftTrigger.value > 0.25f ? 64 : 0) | (gp.rightTrigger.value > 0.25f ? 128 : 0);
	BOOL active = fabsf(lx) > 0.2f || fabsf(ly) > 0.2f || fabsf(rx) > 0.2f || fabsf(ry) > 0.2f || dpad || face;
	if (!active && !gp) return;

	NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
	if (!active || now - last < 0.1) return;
	last = now;

	static int header;
	if (!header) {
		header = 1;
		NSMutableArray *names = [NSMutableArray array];
		for (GCController *c in GCController.controllers) [names addObject:c.vendorName ?: @"?"];
		written += fprintf(out, "# GCControllers=%s SDLjoysticks=%d SDLpad0=%s have=%d devidx=%d SwapSticks=%d\n",
			[names componentsJoinedByString:@","].UTF8String, SDL_NumJoysticks(), name ? name : "?", have, devidx, swapped);
		written += fprintf(out, "# t | GC L(x,y) R(x,y) dpad face | SDL leftXY rightXY | mode | engine stick rstick buttons | theta verta pos\n");
	}
	float theta = 0, verta = 0, px = 0, py = 0, pz = 0;
	playerIosGetView(&theta, &verta);
	playerIosGetPos(&px, &py, &pz);
	written += fprintf(out, "%.2f | GC %.2f,%.2f %.2f,%.2f d%x f%02x | SDL %d,%d %d,%d | m%d | e %d,%d %d,%d b%08x | %.1f %.1f %.0f,%.0f,%.0f\n",
		fmod(now, 1000.0), lx, ly, rx, ry, dpad, face, axes[0], axes[1], axes[2], axes[3],
		optionsGetControlMode(0), joyGetStickX(0), joyGetStickY(0), joyGetRStickX(0), joyGetRStickY(0),
		joyGetButtons(0, 0xffffffffu), theta, verta, px, py, pz);
	fflush(out);
}

- (void)tick
{
#if !TARGET_OS_MACCATALYST
	if (![NSUserDefaults.standardUserDefaults boolForKey:kArrowsOffStick]) {
		pdRemoveArrowStickBinds();
		configSave("$S/pd.ini");
		[NSUserDefaults.standardUserDefaults setBool:YES forKey:kArrowsOffStick];
		NSLog(@"perfectdark: [pad] arrow keys removed from the N64 stick binds");
	}
#endif
	if (_applyDefaultLayout) {
		_applyDefaultLayout = NO;
		NSString *result = [PDController applyGoldenpadLayout];
		[NSUserDefaults.standardUserDefaults setBool:YES forKey:kDefaultLayoutDecided];
		NSLog(@"perfectdark: [pad] new install, default controller layout: %@", result);
	}
	// Look belongs to the engine. Input.PlayerN.SwapSticks (default 1) sends
	// the physical right stick to the N64 stick, which CONTROLMODE_PC turns
	// and pitches with, and the left stick to movement. A second shell look
	// on the right stick doubled the pitch and turned the opposite way.
	GCExtendedGamepad *gp = GCController.controllers.firstObject.extendedGamepad;
	pdPadTrace(gp);

	// A double flick of the left stick either way is the combat roll (D-037).
	if (gp && NSDate.timeIntervalSinceReferenceDate >= _injectUntil) {
		[self noteLeftStickX:gp.leftThumbstick.xAxis.value];
	}
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
