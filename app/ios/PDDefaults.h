// PDDefaults.h — NSUserDefaults is the truth; pd.ini is downstream of it.
//
// The charter's settings rule: "NSUserDefaults as truth driving pd.ini keys,
// persist across relaunch, verified by relaunch". So every row the settings
// page shows is a key here, and PDDefaultsApplyToEngine() is the one place that
// turns those into engine state - either by calling a video*/texpack*/xbla*
// function, or by writing the matching pd.ini key through configSetValue()
// (overlay 0013), which is what makes the setting survive into the file the
// game itself writes on resign-active.
//
// Touch/controller keys have no pd.ini counterpart: they belong to the shell.
#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Look / aiming
extern NSString *const PDDefLookDegPerPoint;   // float, degrees of view per point of drag
extern NSString *const PDDefLookDegPerPointY;  // float, the vertical axis on its own
extern NSString *const PDDefInvertY;           // bool
extern NSString *const PDDefPadLookSpeed;      // float, degrees/second at full stick

// Touch layer
// 0 = auto (hidden while a pad is connected), 1 = always on, 2 = off.
// "Auto" cannot be the only behaviour: the simulator reports a virtual
// "Gamepad" of its own, so an auto-only layer is invisible exactly where it is
// tested, and a player who leaves a pad paired on a shelf has no controls.
extern NSString *const PDDefTouchMode;         // int
// The stick is ALWAYS floating (D-032): it appears where the thumb lands in the
// left 45% of the view, which is bean's rule and the only one a thumb that never
// looks down can use. There is no "fixed stick" row and no fixed-stick code.
extern NSString *const PDDefButtonScale;       // float 0.6…1.8
extern NSString *const PDDefButtonOpacity;     // float 0.05…0.9
extern NSString *const PDDefHaptics;           // bool
/**
 * Combat-roll by gesture (D-032, extended by D-037). Default ON.
 *
 * TOUCH: double-tap the stick region; the left half of the region (nearer the
 * screen edge) rolls left, the right half rolls right.
 * GAMEPAD: double-flick the LEFT stick to one side (out past 0.70, back inside
 * 0.30, out again within 300 ms). One setting for both, as the user asked - and
 * with it, R3 is no longer bound to the roll at all (PDController.m).
 *
 * Turning this on is also what turns Dab's combat roll ON in the engine
 * (Mod.CombatRoll, which upstream ships as MODROLL_OFF) - a gesture for a move
 * the engine has disabled is a gesture that does nothing.
 */
extern NSString *const PDDefDoubleTapRoll;     // bool

// Control style (Q-003 / D-022). 0 = dual analogue: the touch stick is
// analogue MOVEMENT on the right stick and the drag is look, which is what
// CONTROLMODE_PC means. 1 = the N64 styles, where the stick sends the four C
// directions digitally (what D-013 shipped).
extern NSString *const PDDefControlStyle;      // int

/**
 * Where the player dragged each gameplay button, keyed by its label.
 *
 * A dictionary of label -> @{ @"x": unitX, @"y": unitY } in exactly the units
 * kButtons[] uses - bean's representation (GoldenEye), unit coordinates of the
 * FULL view - so the table in PDTouchOverlay.m stays the reset: a label absent
 * from this dictionary is drawn where the table says, and "Reset layout" is
 * forgetting the dictionary.
 *
 * The stick is always floating and has no origin to place, so it is not in here.
 */
extern NSString *const PDDefButtonLayout;      // dictionary

// Display / renderer
extern NSString *const PDDefRefreshHz;         // int 60 or 120
/**
 * Render scale as a PERCENTAGE of the panel's own scale: 100 = native.
 *
 * Read in main() and published as PD_IOS_RENDER_FRACTION before ANGLE exists;
 * gfx_angle_egl.mm multiplies the layer's own contentsScale by it. An explicit
 * PD_IOS_RENDER_SCALE in the environment (the gates set it, to draw the
 * oracle's resolution) always wins, and a replay run never reads this at all.
 */
// iOS: 100 / 75 / 50. visionOS: 100 ("1440p (Native)") / 150 ("4K"), which is
// contentsScale 3 on the headset's 1280x720-point window -> 3840x2160 (D-032).
extern NSString *const PDDefRenderScalePct;    // int
extern NSString *const PDDefShowFPS;           // bool
// D-044's shipping fallback, registered NO: with it YES the Frame rate row
// offers only 120 Hz on a 120 Hz panel. One flip, and 120 -> 60 cannot be
// reached by a player at all.
extern NSString *const PDDefHide60On120;       // bool

// XBLA + packs
// The F6 equivalent, and the only XBLA switch there is (D-032): all five parts
// follow it. Five separate rows were five ways to half-apply one release.
extern NSString *const PDDefXblaWholeRelease;  // bool
// GoldenEye XBLA's own switch (D-081, overlay 0050): engine key
// Mod.XblaGoldenEye. Off is GE Plus in GoldenEye's N64 look, as if the release
// were not in added-content/. Read by the engine once a run, so it takes effect
// the next time the app opens; ON by default.
extern NSString *const PDDefXblaGoldenEye;     // bool
extern NSString *const PDDefTexturePacks;      // bool

// Audio (D-033). The game's OWN audio settings - "Sound", "Music" and "Sound
// Mode" - are not here and are not pd.ini keys: they live in the N64 game file
// in the eeprom and are edited in the game's own Audio Options page, which
// rewrites all three on every game-file load. Mirroring them in this page was
// round 1's mistake (it needed an engine callback to survive a slot change, and
// the user's answer was that it is not what he wants from this page anyway).
//
// What a phone needs INSTEAD is a volume it can reach without opening the
// game's menus, a mute, and a policy for the player's own music - all three of
// which are the shell's, applied as one gain on the frame's samples by
// pdPlatformAudioGain() (overlay 0023, PDAudio.m).
/** 0…4, the five "Other App Audio" modes. Default 2, "Lower Other Audio". */
extern NSString *const PDDefAudioSessionMode;   // int
/** Master volume as a multiplier, 0.0…1.0. Default 1.0. */
extern NSString *const PDDefAudioMasterVolume;  // float
extern NSString *const PDDefAudioMute;          // bool

// visionOS 3D mode (Phase 6 M6, plan §2.10). The rows of the 3D settings sheet,
// and the family's own values from ~/dev/q2repro-ios/SETTINGS-SPEC-FROM-VKQUAKE.md
// — a spec that went through six of the user's own feedback rounds on vkQuake, so
// the ranges and defaults are not ours to re-choose.
//
// LENGTHS ARE METRES, and the WIDTH and HEIGHT keys store the HALF-extent
// while the sheet shows the full one (the compositor scales a unit quad, so
// halves are what it wants and doubling for display is free). The Units row is
// presentation only: it changes no stored value.
//
// Registered on iOS as well as visionOS. They drive nothing there — the sheet
// and every setter are inside TARGET_OS_VISION — but one registration site for
// every default in the app is worth more than a second #if.
extern NSString *const PDDef3DDistance;      // float m, 1.0…8.0
extern NSString *const PDDef3DHalfWidth;     // float m, 0.6…4.0 (shown 1.2…8.0)
extern NSString *const PDDef3DHalfHeight;    // float m, 0.5…3.0 (shown 1.0…6.0)
extern NSString *const PDDef3DPosHeight;     // float m, -1.5…+10.0, signed readout
extern NSString *const PDDef3DStereoDepthPct; // float %, 0…320
extern NSString *const PDDef3DCrosshairUnits; // float PD units, 100…1500 (610 = 20 ft)
extern NSString *const PDDef3DDimming;       // float 0…1, shown as %
extern NSString *const PDDef3DRenderPct;     // float %, 40…100 of the eye's base size
extern NSString *const PDDef3DUnitsFeet;     // bool, YES = ft (the family default)

/** Registers the defaults. Call before anything reads one. */
void PDDefaultsRegister(void);

/**
 * Push every setting into the live engine. Game thread only (it calls engine
 * functions); the settings page goes through PDShell's queue to get here.
 */
void PDDefaultsApplyToEngine(void);

/** Convenience readers with the registered fallbacks already applied. */
float PDDefFloat(NSString *key);
BOOL PDDefBool(NSString *key);
NSInteger PDDefInt(NSString *key);

NS_ASSUME_NONNULL_END

/**
 * Did the last PDDefaultsApplyToEngine() hold the panel rate back because the
 * settings page was up? (D-041 round 2 - see PDDefaults.m.) The settings page's
 * dismiss re-applies when this is YES.
 */
BOOL PDDefaultsPacingIsDeferred(void);
