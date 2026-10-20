// PDDefaults.m — the settings truth, and the one place it reaches the engine.
#import "PDDefaults.h"
#import "PDShell.h"
#import "PDPacing.h"
#import "PDTexPacks.h"
#import "PDVision.h"
#import "PDAudio.h"
#import "PDSettingsViewController.h"
#import "PDWatchdog.h"
#if TARGET_OS_VISION
// The 3D mode's own rows (M6). Self-gated header; the iOS target never sees it.
#import "PDVision3D.h"
#endif

#include <string.h>
#include <math.h>

NSString *const PDDefLookDegPerPoint  = @"pd.look.degPerPoint";
NSString *const PDDefLookDegPerPointY = @"pd.look.degPerPointY";
NSString *const PDDefInvertY          = @"pd.look.invertY";
NSString *const PDDefPadLookSpeed     = @"pd.pad.lookDegPerSec";

NSString *const PDDefTouchMode        = @"pd.touch.mode";
NSString *const PDDefButtonScale      = @"pd.touch.buttonScale";
NSString *const PDDefButtonOpacity    = @"pd.touch.buttonOpacity";
NSString *const PDDefHaptics          = @"pd.touch.haptics";
NSString *const PDDefDoubleTapRoll    = @"pd.touch.doubleTapRoll";
NSString *const PDDefControlStyle     = @"pd.control.style";
NSString *const PDDefButtonLayout     = @"pd.touch.layout";

NSString *const PDDefRefreshHz        = @"pd.video.refreshHz";
NSString *const PDDefRenderScalePct   = @"pd.video.renderScalePct";
NSString *const PDDefShowFPS          = @"pd.video.showFPS";
NSString *const PDDefHide60On120      = @"pd.video.hide60on120";

NSString *const PDDefXblaWholeRelease = @"pd.xbla.wholeRelease";
NSString *const PDDefXblaGoldenEye    = @"pd.xbla.goldenEye";
NSString *const PDDefTexturePacks     = @"pd.texpacks.enabled";

NSString *const PDDefAudioSessionMode  = @"pd.audio.sessionMode";
NSString *const PDDefAudioMasterVolume = @"pd.audio.masterVolume";
NSString *const PDDefAudioMute         = @"pd.audio.mute";

NSString *const PDDef3DDistance        = @"vp3d.dist";
NSString *const PDDef3DHalfWidth       = @"vp3d.halfW";
NSString *const PDDef3DHalfHeight      = @"vp3d.halfH";
NSString *const PDDef3DPosHeight       = @"vp3d.posH";
NSString *const PDDef3DStereoDepthPct  = @"vp3d.depthPct";
NSString *const PDDef3DCrosshairUnits  = @"vp3d.conv";
NSString *const PDDef3DDimming         = @"vp3d.dim";
NSString *const PDDef3DRenderPct       = @"vp3d.renderPct";
NSString *const PDDef3DUnitsFeet       = @"vp3d.unitsFt";

void PDDefaultsRegister(void)
{
	[NSUserDefaults.standardUserDefaults registerDefaults:@{
		// 0.30 deg/pt, both axes (D-032). 0.20 was the family's SEED for a first
		// tuning round (charter Phase 1) and this is that round: at 844 points
		// wide a full-screen drag is now ~250 degrees, about two thirds of a
		// turn, which is where bean's shipped port sits.
		PDDefLookDegPerPoint: @0.30f,
		PDDefLookDegPerPointY: @0.30f,
		PDDefInvertY: @NO,
		// A pad's right stick at full deflection: 180 deg/s is roughly where a
		// console shooter of this era sat before anyone learned to raise it.
		PDDefPadLookSpeed: @180.0f,

		PDDefTouchMode: @(0),   // auto
		PDDefButtonScale: @1.0f,
		// bean's own number, tuned on his device over a shipping port's life
		// (touch_overlay_uikit.mm:48). The chips are drawn bean's way now - a
		// thin ring with the glyph at rather more than the ring's alpha - so a
		// figure that would be invisible as a filled disc is not.
		PDDefButtonOpacity: @0.28f,
		PDDefHaptics: @YES,
		PDDefDoubleTapRoll: @YES,
		// D-022: dual analogue. It is not a new control style - it is the port's
		// own default one (CONTROLMODE_PC, forced from Game.PlayerN.ExtendedControls
		// on every gamefile load) with the touch stick finally on the axis that
		// means movement.
		PDDefControlStyle: @(0),
		// Nothing dragged yet: every chip is where kButtons[] puts it.
		PDDefButtonLayout: @{},

		// The panel's own maximum, whatever it is (D-056): 120 on a ProMotion
		// phone, 90 on this Vision Pro, 60 on a 60 Hz phone. The pacer already
		// takes the whole range (docs/pacing.md); resolving the DEFAULT at
		// register time rather than storing 60 is what stops a ProMotion phone
		// booting at half its panel rate and needing the row touched to get the
		// other half — and it is what stops the headset booting at 60 on a
		// 90 Hz panel, which is what 0.0.0.9 did.
		PDDefRefreshHz: @(PDPanelHighHz()),
		// Native. 2x SSAA is deliberately not offered: the harbourmasters
		// policy is that it goes on the menu only after a device gpu-time
		// check proves the headroom, and this port has no device number at all
		// yet (Q-010). The lever itself takes any value the env carries.
		PDDefRenderScalePct: @(100),
		PDDefShowFPS: @NO,
		// D-044: OFF here on purpose — the user must still be able to reproduce
		// the 120 -> 60 wedge. `hide60 on` over the bridge, or @YES here, is the
		// one-line insurance for the next public build.
		PDDefHide60On120: @NO,

		// D-011: the XBLA release is on whenever a package is present.
		PDDefXblaWholeRelease: @YES,
		// D-081: GoldenEye's release is on whenever it is there, as it was
		// before the switch came back (D-072); off is the player's choice.
		PDDefXblaGoldenEye: @YES,
		PDDefTexturePacks: @YES,

		// "Lower Other Audio" - bean's default and the family's (D-033): a
		// podcast keeps going, quietly, which is what a player who started one
		// before opening a game meant. Full volume, not muted.
		PDDefAudioSessionMode: @(2),
		PDDefAudioMasterVolume: @1.0f,
		PDDefAudioMute: @NO,

		// The visionOS 3D panel. THE USER'S OWN NUMBERS after the 0.0.0.11
		// headset session (D-061): "make default screen width 20 ft, height
		// 12 ft. stereo depth 150%. ... crosshair distance be 25 ft." So a
		// 6.096 x 3.658 m screen (20 x 12 ft, aspect 5:3) 3.6 m away at eye
		// level, 80 % surroundings dimming, stereo depth 150 %, and the
		// crosshair plane at 25 ft = 762 PD units (1 unit ~ 1 cm,
		// constants.h:496). The eye FOLLOWS this shape (D-058), so the panel's
		// aspect is the eye's: 2560x1536 at the 2560 budget, not 2560x1440.
		//
		// The halves are exact in FEET, because feet is what the readout shows
		// by default: 3.048 m = 10.000 ft and 1.8288 m = 6.000 ft, so the rows
		// read "20.0 ft" and "12.0 ft" and not "19.9".
		PDDef3DDistance: @3.6f,
		PDDef3DHalfWidth: @3.048f,
		PDDef3DHalfHeight: @1.8288f,
		PDDef3DPosHeight: @0.0f,
		PDDef3DStereoDepthPct: @150.0f,
		PDDef3DCrosshairUnits: @762.0f,
		PDDef3DDimming: @0.80f,
		// 100 %, and NOT q2repro's shipped 60 %: that number is a MEASURED
		// device verdict on a Q2 frame through ANGLE, and this port has no
		// device number at all yet (M5, Q-021). A default chosen from another
		// engine's measurement would be exactly the "vibes, not numbers" the
		// charter forbids — so the row ships at native and M5 moves it.
		PDDef3DRenderPct: @100.0f,
		PDDef3DUnitsFeet: @YES,
	}];
}

float PDDefFloat(NSString *key) { return [NSUserDefaults.standardUserDefaults floatForKey:key]; }
BOOL PDDefBool(NSString *key) { return [NSUserDefaults.standardUserDefaults boolForKey:key]; }
NSInteger PDDefInt(NSString *key) { return [NSUserDefaults.standardUserDefaults integerForKey:key]; }

/**
 * Writes one int config key. Returns YES only if the value actually CHANGED.
 *
 * That distinction is load-bearing, not tidiness. videoSetTextureEnhance()
 * invalidates the texture cache, so calling it with the value the engine
 * already had re-uploads every texture a couple of frames into the run - which
 * is invisible to play, and showed up as a diverging `tex uploads` line in the
 * seeded replay's gfx stream against the oracle. A setting that has not changed
 * must cost nothing.
 */
static BOOL pdSetInt(const char *key, NSInteger v)
{
	char buf[32], now[512];
	snprintf(buf, sizeof(buf), "%ld", (long)v);

	if (!configGetValue(key, now, sizeof(now))) {
		NSLog(@"perfectdark: settings: no such config key %s", key);
		return NO;
	}
	if (!strcmp(now, buf)) {
		return NO;
	}

	configSetValue(key, buf);
	// Read back: config.c clamps silently, so "changed" means what the engine
	// took, not what we asked for.
	char after[512];
	configGetValue(key, after, sizeof(after));
	return strcmp(now, after) != 0;
}

/** Set when the panel rate could not be applied because the page was up. */
static BOOL sPacingDeferred = NO;

BOOL PDDefaultsPacingIsDeferred(void) { return sPacingDeferred; }

void PDDefaultsApplyToEngine(void)
{
	NSCAssert(NSThread.isMainThread, @"engine state is the game thread's");
	PDLifecycle("defaults: apply begin (refreshHz=%ld, page=%d)",
		(long)PDDefInt(PDDefRefreshHz), (int)PDSettingsViewController.isPresented);

	// Picture settings are FIXED, not rows (D-032). Enhance Textures stays at
	// upstream's own 2x; Vivid Colours and Black Level stay OFF, and off is what
	// keeps gfx_opengl from ever building the grade pass - a shader compiled on
	// the game thread the first time the setting is touched, which is the freeze
	// a player hits when he flips the row mid-level. The values are still pushed
	// (and still only when they moved, see pdSetInt) so a pd.ini carried in from
	// a desktop machine cannot arm the pass behind our back.
	if (pdSetInt("Mod.EnhanceTextures", 1 /* MODENHANCE_2X */)) {
		videoSetTextureEnhance(modGetTextureEnhanceScale(), modGetSmoothTextScale());
	}
	if (pdSetInt("Mod.VividColours", 0)) {
		videoSetVividColours(modGetVividSaturation(), modGetVividContrast());
	}
	if (pdSetInt("Mod.BlackLevel", 0)) {
		videoSetBlackLevel(modGetBlackLevelLift());
	}

	// Dab's combat roll is MODROLL_OFF upstream (main.c:308, modoptions.c:30),
	// so the double-tap gesture would be a gesture for a move the engine has
	// disabled. The setting that offers the gesture is what turns the move on;
	// PLAYERSONLY rather than EVERYONE, so enabling a control does not also
	// change what the simulants do.
	pdSetInt("Mod.CombatRoll", PDDefBool(PDDefDoubleTapRoll) ? 2 /* PLAYERSONLY */ : 0);

	pdSetInt("Video.DisplayFPS", PDDefBool(PDDefShowFPS) ? 1 : 0);

	// Control style. The ini key is what gamefile.c:169/:344 read on every
	// new-file and load path, so writing it is what makes the choice stick;
	// optionsSetControlMode() is what makes it true for the file already
	// loaded. Both, in that order, or the row appears to do nothing until the
	// next launch.
	{
		const BOOL dual = (PDDefInt(PDDefControlStyle) == 0);
		pdSetInt("Game.Player1.ExtendedControls", dual ? 1 : 0);
		const int want = dual ? 8 /* CONTROLMODE_PC */ : 0 /* CONTROLMODE_11 */;
		if (optionsGetControlMode(0) != want) {
			optionsSetControlMode(0, want);
		}
	}

	// Pacing owns the panel rate; Video.VSync and Video.FramerateLimit are
	// inert on iOS and are forced off so a pd.ini carried from a desktop
	// machine cannot re-arm the busy-wait limiter (docs/pacing.md).
	pdSetInt("Video.VSync", 0);
	pdSetInt("Video.FramerateLimit", 0);
	{
		// D-034. The panel rate the player asked for, clamped to what the panel
		// has - and then the ENGINE's own tick gate set to match it, which is
		// the half that was missing in 0.0.0.6.
		//
		// `Game.TickRateDivisor` is g_TickRateDiv (main.c:64,297), copied into
		// g_Vars.mininc60 every frame (timing.c:74) and spun on at the top of
		// frametimeCalculate(): at its default 1 the engine refuses to BEGIN a
		// frame until a 60th of a second has passed, so a 120 Hz display link
		// over it serves every other callback and the frames that do land land
		// unevenly. 0 is upstream's own "uncap tickrate" (the Extended Options
		// checkbox, optionsmenu.c:992), and it is not a hack: lvupdate60f is
		// diffframe240 * 0.25 (lv.c:2347), so at 120 fps every frame advances
		// the sim by exactly half a 60 Hz tick and motion is genuinely smooth
		// rather than doubled.
		// D-056: the row's high option is the PANEL's maximum, so "not 60" means
		// "whatever this panel can do" — 120 on a ProMotion phone, 90 on this
		// Vision Pro. The old form was `>= 120 && max >= 120 ? 120 : 60`, which
		// silently floored a 90 Hz headset at 60 however the row was set.
		//
		// A value stored by an EARLIER build can be above this panel's maximum
		// (0.0.0.9's row offered 120 on the headset and the user selected it), so
		// it is clamped here and WRITTEN BACK — otherwise the segmented control
		// would show no selection at all for a rate the engine is not using.
		const NSInteger high = PDPanelHighHz();
		if (PDDefInt(PDDefRefreshHz) > high) {
			PDLifecycle("defaults: refreshHz %ld is above this panel's %ld — clamped",
				(long)PDDefInt(PDDefRefreshHz), (long)high);
			[NSUserDefaults.standardUserDefaults setInteger:high forKey:PDDefRefreshHz];
		}
		const NSInteger want = PDDefInt(PDDefRefreshHz) >= high ? high : 60;
		// ...but NOT while the settings page is on screen (D-041 round 2).
		//
		// The user: "it doesn't break the touch screen when I change from 60 to
		// 120 fps" - only 120 -> 60, twice, on two builds. That direction is
		// the only one that turns the ENGINE's tick gate back ON
		// (Game.TickRateDivisor 0 -> 1, a sysSleep spin at the top of
		// frametimeCalculate) and SHRINKS the display link's frame-rate range,
		// and the 0.4 s coalescer in -[PDSettingsViewController commit] lands
		// it while the page's own UIWindow is key and a UIKit transition may
		// still be in flight. Re-pacing the main thread underneath UIKit at
		// that moment is the one thing this port does that could stop touches
		// being delivered while leaving hit-testing, the engine and the bridge
		// all perfect - which is exactly the state he reaches.
		//
		// So it waits. +[PDSettingsViewController dismiss] re-applies, on the
		// frame hook, with the page already gone.
		if (PDSettingsViewController.isPresented) {
			sPacingDeferred = YES;
			PDLifecycle("defaults: panel rate %ld Hz DEFERRED (settings page is up)", (long)want);
			NSLog(@"perfectdark: [defaults] panel rate %ld Hz DEFERRED - the settings page is up",
				(long)want);
		} else {
			sPacingDeferred = NO;
			PDLifecycle("defaults: applying panel rate %ld Hz (tick gate -> 0, engine+target %ld)",
				(long)want, (long)want);
			// The tick gate is OFF on iOS at EVERY rate, and that is the
			// round-R fix for the user's dead touch (D-043).
			//
			// D-034 set the divisor to 1 at 60 Hz, reasoning that the engine's
			// gate should match the panel. It should not: on iOS the display
			// link is the ONE pacer (docs/pacing.md), and the gate is a second
			// wait on the same clock - the exact thing that document exists to
			// forbid, arriving this time as
			//
			//     do { ... if (g_TickExtraSleep) sysSleep(EXTRA_SLEEP_TIME); }
			//     while (g_Vars.mininc60 && diffframe60 < g_Vars.mininc60);
			//
			// (timing.c:41-54). With mininc60 = 1 that loop parks the MAIN
			// thread in nanosleep(), at the top of the frame, right after the
			// pacer has already waited there for the link (D-040). The main
			// thread is this app's game thread AND its UIKit thread, so while
			// it is in there the run loop turns only in SDL's own event pump -
			// and the HID event source never gets serviced. Touch delivery
			// stops dead while hit-testing, the windows, the key window, the
			// engine, the bridge and even the bridge's own main-queue blocks
			// all stay perfect, which is precisely the state the user reached.
			//
			// It explains his asymmetry exactly: 60 -> 120 sets the divisor to
			// 0 and never breaks; 120 -> 60 set it to 1 and broke every time,
			// on three builds. PROVEN LIVE on the broken instance over USB:
			// `cfg set Game.TickRateDivisor 0` and nothing else, and
			// ui_touches_began went 14 -> 30 -> 35 while he tapped, having not
			// moved for any of the six window-level recoveries.
			//
			// Nothing is lost by turning it off at 60. lvupdate60f is
			// diffframe240 * 0.25 (lv.c:2347), so the sim advances by the real
			// elapsed time whatever the rate; at a link-paced 60 fps that is
			// one 60 Hz tick a frame, which is what the gate was there to
			// enforce. It is upstream's own "uncap tickrate" (optionsmenu.c).
			pdSetInt("Game.TickRateDivisor", 0);
			PDPacing.shared.engineTickHz = want;
			PDPacing.shared.targetHz = want;
			PDLifecycle("defaults: panel rate applied (tick_rate_div=%d)", g_TickRateDiv);
		}
	}

	// One switch, all five parts (D-032). The parts are written first so that a
	// pd.ini which had one of them off cannot leave the release half-applied;
	// the whole-release switch is applied last because it writes all five
	// itself (xblaswitch.c).
	{
		const BOOL on = PDDefBool(PDDefXblaWholeRelease);
		pdSetInt("Mod.XblaMeshes", on);
		pdSetInt("Mod.XblaMeshTextures", on);
		pdSetInt("Mod.XblaStages", on);
		pdSetInt("Mod.XblaFont", on);
		pdSetInt("Mod.XblaExplosions", on);
	}
	// GoldenEye XBLA's switch (D-081). The engine reads it ONCE a run, at
	// startup and from pd.ini (overlay 0050: the Combat Simulator's pool is
	// built from the release then), so pd.ini is written the moment it moves:
	// a swipe-kill after flipping the row must not lose it. A pd.ini carried
	// over from 1.0.0 (whose pin still had this key, default 0) is put right
	// here too, on the first frame - it would cost that one launch only.
	if (pdSetInt("Mod.XblaGoldenEye", PDDefBool(PDDefXblaGoldenEye) ? 1 : 0)) {
		configSave("$S/pd.ini");
		NSLog(@"perfectdark: [geplus] Mod.XblaGoldenEye=%d written to pd.ini (this run: %d, takes effect next launch)",
			PDDefBool(PDDefXblaGoldenEye) ? 1 : 0, gebeanSwitchIsOn());
	}

	// Same rule: xblaSwitchSetEnabled() reloads meshes and rooms, and
	// texpackSetLoadEnabled() drops replacements - neither is free, and neither
	// is asked for when the answer is already what it is.
	if (xblaImportIsAvailable() && xblaSwitchGetEnabled() != (PDDefBool(PDDefXblaWholeRelease) ? 1 : 0)) {
		xblaSwitchSetEnabled(PDDefBool(PDDefXblaWholeRelease));
	}

	// The master gain: volume x mute x the other-app duck, one multiplier the
	// engine reads once a frame (D-033). Cheap and thread-safe - an atomic
	// store - so it rides along with every other apply.
	[PDAudio settingsChanged];

	if (texpackLoadEnabled() != (PDDefBool(PDDefTexturePacks) ? 1 : 0)) {
		texpackSetLoadEnabled(PDDefBool(PDDefTexturePacks));
	}

	// A pack dropped into Files with nothing selected: select it. Dropping a
	// pack into the app's own folder is the phone's version of "install this",
	// and there is no other way to say it - the Texture Packs page's list is a
	// menu the player would have to find first. Only ever fills a BLANK
	// selection, so a player who chose one keeps it.
#if TARGET_OS_VISION
	// The 3D rows, pushed from the same apply as everything else — so a
	// launch, a bridge `settings` write and the sheet's own commit all reach
	// the panel through one path. In 2D it is a handful of stores into statics
	// nothing reads until the next entry; in 3D the compositor picks the new
	// geometry up on its very next frame.
	pdVision3dApplySettings();
#endif

	if (PDDefBool(PDDefTexturePacks) && texpackGetSelectedPack() < 0) {
		NSString *want = PDTexPacks.preferredPack;
		if (want) {
			texpackRefreshPacks();
			if (texpackSelectPackByName(want.UTF8String)) {
				NSLog(@"perfectdark: [texpack] selected \"%@\" (nothing was selected)", want);
			} else {
				NSLog(@"perfectdark: [texpack] could not select \"%@\"", want);
			}
		}
	}
}
