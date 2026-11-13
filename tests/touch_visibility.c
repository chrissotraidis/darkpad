#include "../app/ios/PDTouchVisibility.h"
#include <assert.h>
#include <stdio.h>

int main(void)
{
	// Auto (the registered default) hides only for a usable controller.
	assert(!PDTouchGameplayHidden(PDTouchModeAuto, false, false, false));
	assert(PDTouchGameplayHidden(PDTouchModeAuto, true, false, false));   // connected before launch or mid-game
	assert(!PDTouchGameplayHidden(PDTouchModeAuto, false, false, false)); // disconnected again
	// Game menus stay touchable in Auto even with a controller.
	assert(!PDTouchGameplayHidden(PDTouchModeAuto, true, true, false));

	// Turning auto-hide off while connected restores the controls; on hides them.
	assert(!PDTouchAutoHideEnabled(PDTouchModeWithAutoHide(false)));
	assert(!PDTouchGameplayHidden(PDTouchModeWithAutoHide(false), true, false, false));
	assert(PDTouchGameplayHidden(PDTouchModeWithAutoHide(true), true, false, false));

	// Show Touch Controls (On) wins over a connected controller.
	assert(!PDTouchGameplayHidden(PDTouchModeOn, true, false, false));
	// Hide Touch Controls (Off) holds without a controller.
	assert(PDTouchGameplayHidden(PDTouchModeOff, false, false, false));
	// The layout editor always shows the controls so Done stays reachable.
	assert(!PDTouchGameplayHidden(PDTouchModeOff, true, false, true));

	puts("touch visibility: pass");
	return 0;
}
