// PDGeometry.h — the chain of sizes the picture depends on, watched (D-077).
//
// The game's picture is only right when every link agrees: the window scene's
// interface orientation, SDL's UIWindow and its root view, SDL's Metal view and
// its CAMetalLayer (bounds x contentsScale), the EGL surface ANGLE derives from
// that layer, SDL's own idea of the window size, and the size the renderer
// last drew at. A single portrait-shaped link on a landscape-only iPhone is the
// "picture squeezed into the left of the screen" failure. This file logs every
// change of any link to Documents/lifecycle.txt (on change only), answers the
// bridge's `geo` command and the size_* rows of `state`, and on an iPhone puts
// a portrait-shaped game window back to the scene's landscape shape before the
// renderer can draw into it.
//
// iOS only. On visionOS windows are freely resizable and every function here is
// an empty stub.
#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/** Once per frame from the frame hook, on the main (= game) thread. */
void pdGeoFrame(void);

/**
 * Snapshot and log now, with a reason, even if nothing changed, and repair if
 * needed. Main thread. Used at the moments the window hierarchy hands key
 * status around (settings dismiss, scene activation).
 */
void pdGeoCheckpoint(const char *why);

/**
 * iPhone: if SDL's window or its views are portrait-shaped while the scene is
 * landscape, put them back and make SDL re-measure. Returns how many views it
 * had to correct (0 when everything already agreed). Main thread.
 */
int pdGeoRepair(const char *why);

/** The size_* rows for `state`, and the long form for `geo`. */
NSString *pdGeoStateLines(void);
NSString *pdGeoReport(void);

/** The bridge's `presented` and `picker cancel|pick <path>` (dev builds). */
NSString *pdGeoPresentedReport(void);
NSString *pdGeoPickerFinish(NSString *_Nullable pathOrNil);

/** `geo repair on|off`: the repair half can be switched off to reproduce. */
extern int pdGeoRepairEnabled;

/** Called from the scene delegate when UIKit moves the scene's coordinate space. */
void pdGeoSceneCoordinateSpaceChanged(long oldOrientation, long newOrientation);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
