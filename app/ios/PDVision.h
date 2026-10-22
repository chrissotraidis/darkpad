// PDVision.h — the handful of UIKit facts that differ on visionOS, in one
// place, so the shell sources stay one source tree (charter Phase 5;
// GoldenEye D-024: visionOS is a fourth build of ONE app, every difference
// behind TARGET_OS_VISION).
//
// What is actually missing on xrOS, measured by building the iOS shell against
// the xros SDK rather than guessed:
//
//   UIScreen                   unavailable — there are no screens, only window
//                              scenes, and a window's size is the user's drag.
//   UIImpactFeedbackGenerator  unavailable — no haptics on the headset.
//
// Everything else in the shell (UIWindowScene, UIWindow, UIViewController,
// UITableView, UIPanGestureRecognizer, GCController, AVAudioSession, the
// settings page, the onboarding page, the XBLA progress page) compiles and
// behaves identically, which is why this file is short.
#pragma once

#import <UIKit/UIKit.h>
#include <TargetConditionals.h>

#ifndef TARGET_OS_VISION
#define TARGET_OS_VISION 0
#endif

/**
 * Points-to-pixels for a CALayer that has no view to ask.
 *
 * visionOS renders every window at 2x (the compositor then resamples for the
 * display and for the user's distance), and `traitCollection.displayScale`
 * reports exactly that — but a bare CATextLayer being configured before it is
 * in a hierarchy has no traits to read, which is the only place this is used.
 */
static inline CGFloat PDVisionLayerScale(void)
{
#if TARGET_OS_VISION
	return 2.0;
#else
	return UIScreen.mainScreen.scale;
#endif
}

/**
 * The panel's maximum refresh, for the display link's frame-rate range.
 *
 * There is no UIScreen to ask on visionOS. The Vision Pro's panel runs 90 Hz
 * (M5 models up to 120); 90 is the honest floor and the display link clamps to
 * whatever the system will actually give, so under-reporting costs nothing and
 * over-reporting asks for a cadence the compositor will not honour.
 */
static inline NSInteger PDVisionMaxFPS(void)
{
#if TARGET_OS_VISION
	return 90;
#else
	return UIScreen.mainScreen.maximumFramesPerSecond;
#endif
}

/**
 * The HIGH option of the Frame rate row, and the display link's range (D-056).
 *
 * The row used to offer a hard-coded 120 Hz and the pacer used to gate anything
 * that was not >= 120 down to 60, which on a 90 Hz Vision Pro meant the user could
 * select "120 Hz" in the sheet and get 60 — the headset read of 0.0.0.9 reported
 * exactly that ("frame rate set to 120 but locked at 60 in 2D and 3D", and the
 * lifecycle log agreed: "refreshHz=120 -> applying panel rate 60 Hz").
 *
 * So the row's high option is the PANEL'S MAXIMUM, whatever it is: 120 on a
 * ProMotion phone, 90 on this Vision Pro, 96/100 on a newer one, and 60 on a
 * 60 Hz phone (where the row collapses to a single segment). Nothing about iOS
 * changes — PDVisionMaxFPS() there is UIScreen's own answer, so a ProMotion
 * phone still reads 120 and a 60 Hz phone still reads 60.
 *
 * Never below 60: a panel that reported something silly must not pace the
 * engine below the rate the game was written for.
 */
static inline NSInteger PDPanelHighHz(void)
{
	const NSInteger max = PDVisionMaxFPS();
	return max > 60 ? max : 60;
}

/**
 * The last-resort frame for an overlay UIWindow when no UIWindowScene has been
 * found yet (onboarding, the XBLA progress page, the settings page).
 *
 * On iOS that fallback is the screen's bounds. On visionOS a scene is the only
 * way a window can exist at all, so this really is unreachable there — it
 * exists so the `scene ? … : …` expression still compiles. The size is the
 * Vision Pro simulator's default window in points.
 */
static inline CGRect PDVisionFallbackWindowFrame(void)
{
#if TARGET_OS_VISION
	return CGRectMake(0, 0, 1280, 720);
#else
	return UIScreen.mainScreen.bounds;
#endif
}
