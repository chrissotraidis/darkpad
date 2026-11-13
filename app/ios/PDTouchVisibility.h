#pragma once
#include <stdbool.h>

// PDDefTouchMode values, unchanged: Auto is the registered default on iOS.
enum { PDTouchModeAuto = 0, PDTouchModeOn = 1, PDTouchModeOff = 2 };

// Gameplay chips are hidden by Off, or by Auto while a usable controller is
// connected outside a game menu. The layout editor always shows them.
static inline bool PDTouchGameplayHidden(long mode, bool padConnected, bool menuOpen, bool editing)
{
	return !editing && (mode == PDTouchModeOff || (mode == PDTouchModeAuto && padConnected && !menuOpen));
}

// "Auto-hide Touch Controls with Controller" is the Auto mode.
static inline bool PDTouchAutoHideEnabled(long mode) { return mode == PDTouchModeAuto; }

// Turning auto-hide off keeps the controls showing (On); turning it on
// returns to Auto. "Show Touch Controls" is On; "Hide Touch Controls" is Off.
static inline long PDTouchModeWithAutoHide(bool enabled) { return enabled ? PDTouchModeAuto : PDTouchModeOn; }
