// PDVisionSettingsViewController.m — the 3D settings sheet (Phase 6 M6).
//
// Plan §2.10, and its rows/ranges/defaults/wording are
// ~/dev/q2repro-ios/SETTINGS-SPEC-FROM-VKQUAKE.md — a spec that went through
// six of the user's own feedback rounds on vkQuake and was then shipped twice
// (vkQuake, q2repro). Nothing here is ours to re-choose; what IS ours is the
// machinery, and that is deliberately the SAME machinery as the 2D page:
// NSUserDefaults is the truth (PDDefaults.h `vp3d.*`), one row descriptor per
// setting. Since D-082 the rows are not a table of their own: they are the
// LAST SECTION of the settings page (PDSettingsViewController), under the iOS
// sections, on every visionOS settings surface — see "The 3D rows" below.
//
// THREE THINGS ABOUT THE CHROME, EACH OF WHICH COST SOMEBODY A ROUND:
//
//   * A UIKIT MODAL PRESENTED DIRECTLY OVER AN OPEN IMMERSIVE SPACE SILENTLY
//     FAILS (SETTINGS-SPEC :13-37). So this table is not presented by UIKit at
//     all: PDVisionApp.swift hosts it inside a SwiftUI `.sheet`, which works,
//     and the sheet's header bar (title, prominent Done) is SwiftUI's — Reset
//     moved into the table's own "3D Settings | Reset" header at D-082, as in
//     vkQuake and openQ4 — a hosted navigation bar's Done and `safeAreaInset` both bury
//     controls instead.
//   * THE SHEET'S CONTENT IS NEVER GIVEN A FORCED HEIGHT that it can overflow:
//     SwiftUI centre-CLIPS taller content, which ate a Done bar and the first
//     and last rows on device AND sim. This table scrolls internally, so the
//     sheet's minHeight is a floor the content cannot exceed rather than a
//     height it can overflow (see PDVisionApp.swift).
//   * THE OPAQUE DARK BACKGROUND. D-054(b) left it off the 3D-only sheet (no
//     live layer under a sheet in 3D). D-082 puts it back: the sheet IS the
//     settings page now, and a plain table's floating headers must be opaque
//     or the rows show through them as they slide under — openQ4's D-106.
//
// AND THE ONE ORDERING RULE (plan §2.9): the sheet must be GONE before the 3D
// exit un-parks the window. pdVision3dSettingsSheetCloseAndWait() is called at
// the top of the exit, before the un-park, and pumps the run loop until the
// sheet's own .onDisappear has answered — so the sequence cannot happen in the
// other order even if the player left the sheet open and used the Crown.
#import "PDVision3D.h"

#if TARGET_OS_VISION

#import "PDDefaults.h"
#import "PDShell.h"
#import "PDXbla.h"

#include <math.h>
#include <objc/runtime.h>

// The engine's own fps counter (Video.DisplayFPS, lv.c:1003) is the "FPS on
// Panel" row: it is drawn in PD's 2D pass, which lands in BOTH eyes, so it
// appears on the panel exactly as it appears in 2D. It is therefore the SAME
// setting as the 2D page's "Show FPS" and shares its key — one truth, and a
// Reset of the 3D rows leaves it alone (spec: Units and FPS prefs are kept).

// ---------------------------------------------------------------------------
// Row descriptors (the 2D page's shape, one file over)
// ---------------------------------------------------------------------------

typedef NS_ENUM(NSInteger, PDVRowKind) {
	PDVRowSlider,
	PDVRowSwitch,
	PDVRowSegmented,
	PDVRowInfo,
	PDVRowButton,
	// D-082: the 3D rows are ONE table section now (so its "3D Settings |
	// Reset" header floats over all of them), and D-054's four groups survive
	// inside it as a caption row above each group and a note row under it —
	// where the grouped table had a section header and a section footer.
	PDVRowCaption,
	PDVRowNote,
};

@interface PDVRow : NSObject
@property (nonatomic) PDVRowKind kind;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *key;
/** The bridge's short name for this row (`3d settings set <name> <value>`). */
@property (nonatomic, copy) NSString *name;
@property (nonatomic) float min, max;
/** Whole-number rows snap; a length row does not. */
@property (nonatomic) BOOL snap;
/**
 * Render Resolution only: re-wrapping the eye ring on every sample of a drag
 * would tear the ring down sixty times a second. The label follows the thumb;
 * the ring is re-wrapped when the thumb is let go.
 */
@property (nonatomic) BOOL applyOnRelease;
@property (nonatomic, copy) NSString *(^text)(float v);
@property (nonatomic, copy) NSArray<NSString *> *choices;
@property (nonatomic, copy) NSArray<NSNumber *> *values;
@property (nonatomic, copy) NSString *(^info)(void);
@property (nonatomic, copy) void (^action)(void);
@end
@implementation PDVRow @end

// ---------------------------------------------------------------------------
// Units. Lengths are stored in METRES and shown in whatever the Units row says
// (ft by default — the family's choice, and the user's).
// ---------------------------------------------------------------------------

static BOOL pdVFeet(void) { return PDDefBool(PDDef3DUnitsFeet); }

static NSString *pdVLen(float metres, BOOL signedReadout)
{
	const float v = pdVFeet() ? metres * 3.28084f : metres;
	NSString *u = pdVFeet() ? @"ft" : @"m";
	return signedReadout ? [NSString stringWithFormat:@"%+.1f %@", v, u]
	                     : [NSString stringWithFormat:@"%.1f %@", v, u];
}

// ---------------------------------------------------------------------------
// The apply. THE ONLY PLACE `vp3d.*` BECOMES 3D STATE.
// ---------------------------------------------------------------------------

void pdVision3dApplySettings(void)
{
	const float dist  = PDDefFloat(PDDef3DDistance);
	const float halfW = PDDefFloat(PDDef3DHalfWidth);
	const float halfH = PDDefFloat(PDDef3DHalfHeight);
	const float posH  = PDDefFloat(PDDef3DPosHeight);
	const float dim   = PDDefFloat(PDDef3DDimming);
	pdVisionPanelSet(dist, halfW, halfH, posH, dim);
	// D-061 lowered the Stereo Depth ceiling from 320 % to 300 % ("but cap at
	// 300%. 320 is a random max to pick"). A value PERSISTED above the new
	// ceiling is clamped DOWN and written back, so the sheet's slider and the
	// fold agree — an out-of-range stored value would otherwise sit there
	// invisibly, past the end of a slider that cannot represent it.
	if (PDDefFloat(PDDef3DStereoDepthPct) > 300.0f) {
		[NSUserDefaults.standardUserDefaults setFloat:300.0f forKey:PDDef3DStereoDepthPct];
		NSLog(@"perfectdark: [3d] stored Stereo Depth was above the 300 %% cap — clamped");
	}
	pdVisionStereoSetDepthPct(PDDefFloat(PDDef3DStereoDepthPct));
	pdVisionStereoSetConvergence(PDDefFloat(PDDef3DCrosshairUnits));
	// Asks; pdVisionEyeResizeIfPending() does it at the next frame boundary.
	pdVisionEyeSetRenderPct(PDDefFloat(PDDef3DRenderPct));
}

/**
 * D-058: the panel's shape has stopped moving, so re-size the eye to it.
 *
 * Every entry into 3D, every Reset, every bridge `3d settings set`, and the
 * RELEASE of any slider. Not a drag sample: six textures are not torn down and
 * rebuilt sixty times a second, and the quad stretching in the meantime is the
 * feedback the spec asks for.
 */
void pdVision3dCommitGeometry(void)
{
	pdVisionEyeCommitPanel();
}

void pdVision3dSettingsResetDefaults(void)
{
	// FORGET the keys rather than write the numbers back: the registered
	// defaults in PDDefaults.m are then the single place those values live, and
	// a Reset cannot drift from a fresh install the way a second copy of the
	// table can (q2repro shipped exactly that bug — its Reset wrote a render
	// budget the app never ships with).
	//
	// Units and FPS on Panel are deliberately NOT in this list (spec).
	NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
	for (NSString *k in @[ PDDef3DDistance, PDDef3DHalfWidth, PDDef3DHalfHeight,
	                       PDDef3DPosHeight, PDDef3DStereoDepthPct,
	                       PDDef3DCrosshairUnits, PDDef3DDimming, PDDef3DRenderPct ]) {
		[d removeObjectForKey:k];
	}
	pdVision3dApplySettings();
	pdVision3dCommitGeometry();
	NSLog(@"perfectdark: [3d] settings RESET to defaults (Units and FPS kept)");
	[PDVision3DRows reloadAll];
}

// ---------------------------------------------------------------------------
// The sheet's open/close state, and the exit ordering
// ---------------------------------------------------------------------------

static int pdVSheetUp = 0;
static int pdVSheetAsked = 0;

void pdVision3dSettingsSheetRequest(int open)
{
	if (!NSThread.isMainThread) {
		dispatch_async(dispatch_get_main_queue(), ^{ pdVision3dSettingsSheetRequest(open); });
		return;
	}
	pdVSheetAsked = open ? 1 : 0;
	NSLog(@"perfectdark: [3d] settings sheet %s requested", open ? "OPEN" : "CLOSE");
	PD_SetSettingsSheet(open ? true : false);
}

void pdVision3dSettingsSheetNote(int up)
{
	pdVSheetUp = up ? 1 : 0;
	if (!up) {
		pdVSheetAsked = 0;
	}
	NSLog(@"perfectdark: [3d] settings sheet is now %s", up ? "UP" : "GONE");
}

int pdVision3dSettingsSheetUp(void) { return pdVSheetUp; }

void pdVision3dSettingsSheetCloseAndWait(void)
{
	if (!pdVSheetUp && !pdVSheetAsked) {
		return;
	}
	NSLog(@"perfectdark: [3d] the settings sheet is open at the 3D exit —"
	       " closing it BEFORE the un-park");
	pdVision3dSettingsSheetRequest(0);
	// Pumped, not slept: SwiftUI services the dismissal on THIS thread (the
	// main thread), so a sleep here would guarantee the thing it waits for
	// cannot happen — the same trap the exit's own scene wait documents, and
	// the same idiom the pacer uses (D-045).
	//
	// AND THE WAIT IS WALL-CLOCK, NOT A COUNT OF PUMPS. The first version
	// counted twenty 50 ms pumps and finished in FORTY MILLISECONDS:
	// CFRunLoopRunInMode returns the moment it has handled one source, so
	// `returnAfterSourceHandled == true` makes the timeout an upper bound and
	// nothing more. Measured, the sheet's own dismissal takes ~450 ms (SwiftUI
	// animates it), so the pump-count version issued the un-park BEFORE the
	// sheet was gone — the exact ordering this function exists to prevent, and
	// invisible in every row of `3d state`.
	const CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 2.0;
	const CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
	while (pdVSheetUp && CFAbsoluteTimeGetCurrent() < deadline) {
		CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, true);
	}
	NSLog(@"perfectdark: [3d] settings sheet gone=%d after %.0f ms of pumping",
		!pdVSheetUp, (CFAbsoluteTimeGetCurrent() - t0) * 1000.0);
}

// ---------------------------------------------------------------------------
// The bridge's rows
// ---------------------------------------------------------------------------

NSString *pdVision3dSettingsStateLines(void)
{
	int ew = 0, eh = 0;
	pdVisionEyeGetSize(&ew, &eh);
	const float aspect = (eh > 0) ? (float)ew / (float)eh : 0.0f;
	return [NSString stringWithFormat:
		@"sheet_open=%d\nset_dist=%.2f\nset_width=%.2f\nset_height=%.2f\n"
		 "set_posh=%.2f\nset_depth=%.0f\nset_conv=%.0f\nset_dim=%.0f\n"
		 "set_render=%.0f\nset_units=%s\nset_fps=%d\n"
		 "panel_px=%dx%d\npanel_px_aspect=%.1f:9\n%@",
		pdVSheetUp,
		(double)PDDefFloat(PDDef3DDistance),
		(double)(PDDefFloat(PDDef3DHalfWidth) * 2.0f),
		(double)(PDDefFloat(PDDef3DHalfHeight) * 2.0f),
		(double)PDDefFloat(PDDef3DPosHeight),
		(double)PDDefFloat(PDDef3DStereoDepthPct),
		(double)PDDefFloat(PDDef3DCrosshairUnits),
		(double)(PDDefFloat(PDDef3DDimming) * 100.0f),
		(double)PDDefFloat(PDDef3DRenderPct),
		pdVFeet() ? "ft" : "m",
		(int)PDDefBool(PDDefShowFPS),
		ew, eh, (double)(aspect * 9.0f),
		pdVisionPanelStateLines()];
}

/** Writes one float row and pushes it. Returns the value actually stored. */
static float pdVSetFloat(NSString *key, float v, float lo, float hi)
{
	if (v < lo) v = lo;
	if (v > hi) v = hi;
	[NSUserDefaults.standardUserDefaults setFloat:v forKey:key];
	return v;
}

NSString *pdVision3dSettingsSet(NSString *row, NSString *value)
{
	NSString *r = row.lowercaseString;
	const float v = value.floatValue;
	NSString *took = nil;

	if ([r isEqualToString:@"dist"] || [r isEqualToString:@"distance"]) {
		took = [NSString stringWithFormat:@"set_dist=%.2f",
			(double)pdVSetFloat(PDDef3DDistance, v, 1.0f, 8.0f)];
	} else if ([r isEqualToString:@"width"]) {
		// The bridge speaks FULL width, like the sheet's readout; the key is
		// the half-extent, like the compositor.
		took = [NSString stringWithFormat:@"set_width=%.2f",
			(double)(pdVSetFloat(PDDef3DHalfWidth, v * 0.5f, 0.6f, 6.096f) * 2.0f)];
	} else if ([r isEqualToString:@"height"]) {
		took = [NSString stringWithFormat:@"set_height=%.2f",
			(double)(pdVSetFloat(PDDef3DHalfHeight, v * 0.5f, 0.5f, 3.0f) * 2.0f)];
	} else if ([r isEqualToString:@"posh"] || [r isEqualToString:@"position"]) {
		took = [NSString stringWithFormat:@"set_posh=%.2f",
			(double)pdVSetFloat(PDDef3DPosHeight, v, -1.5f, 10.0f)];
	} else if ([r isEqualToString:@"depth"]) {
		took = [NSString stringWithFormat:@"set_depth=%.0f",
			(double)pdVSetFloat(PDDef3DStereoDepthPct, v, 0.0f, 300.0f)];
	} else if ([r isEqualToString:@"conv"] || [r isEqualToString:@"crosshair"]) {
		took = [NSString stringWithFormat:@"set_conv=%.0f",
			(double)pdVSetFloat(PDDef3DCrosshairUnits, v, 100.0f, 1500.0f)];
	} else if ([r isEqualToString:@"dim"] || [r isEqualToString:@"dimming"]) {
		// Per cent on the wire, 0…1 in the store (the engine reads a fraction).
		took = [NSString stringWithFormat:@"set_dim=%.0f",
			(double)(pdVSetFloat(PDDef3DDimming, v / 100.0f, 0.0f, 1.0f) * 100.0f)];
	} else if ([r isEqualToString:@"render"] || [r isEqualToString:@"resolution"]) {
		took = [NSString stringWithFormat:@"set_render=%.0f",
			(double)pdVSetFloat(PDDef3DRenderPct, v, 40.0f, 100.0f)];
	} else if ([r isEqualToString:@"units"]) {
		const BOOL ft = ([value.lowercaseString hasPrefix:@"f"] || v == 1.0f);
		[NSUserDefaults.standardUserDefaults setBool:ft forKey:PDDef3DUnitsFeet];
		took = [NSString stringWithFormat:@"set_units=%s", ft ? "ft" : "m"];
	} else if ([r isEqualToString:@"fps"]) {
		// "1" / "on" / "yes" are all on; anything else is off.
		NSString *lv = value.lowercaseString;
		const BOOL on = (v != 0.0f) || [lv isEqualToString:@"on"] || [lv isEqualToString:@"yes"];
		[NSUserDefaults.standardUserDefaults setBool:on forKey:PDDefShowFPS];
		// The engine's own Video.DisplayFPS, through the same apply the 2D page
		// uses — on the game thread, because it writes engine config.
		[PDShell.shared enqueue:^{
			PDDefaultsApplyToEngine();
			configSave("$S/pd.ini");
		}];
		took = [NSString stringWithFormat:@"set_fps=%d", (int)on];
	} else {
		return nil;
	}

	pdVision3dApplySettings();
	// A bridge set is atomic — there is no drag and no release, so it commits
	// here. This is what makes `3d settings set width 7` re-wrap the eye, which
	// is the only scripted path to the geometry on a simulator that injects no
	// taps at all.
	pdVision3dCommitGeometry();
	[PDVision3DRows reloadAll];
	NSLog(@"perfectdark: [3d] settings set %@ -> %@", r, took);
	return took;
}

// ---------------------------------------------------------------------------
// The 3D rows (D-082)
//
// Not a table any more: a SECTION of one. The user, 2026-10-02: "all ios settings
// should show in the vision pro settings above the 3d settings. we do this in
// all ports so users can easily access settings." So on visionOS the settings
// page — the ornament gear's sheet, in 2D and in 3D, AND the in-window gear's
// page — is PDSettingsViewController's ONE table: the iOS sections in their iOS
// order, then this, as its last section, under a "3D Settings | Reset" header.
//
// openQ4's shape (D-106 there, openq4_ios_settings.m:1199-1368): a PLAIN table,
// whose current section header floats at the top of the viewport while you
// scroll inside that section and is replaced on the way out of it. That is why
// D-054's four groups are one section here rather than four: four sections
// would float "Stereo" over the Reset header the moment Screen scrolled past.
// The groups keep their names and their explanations as caption and note rows.
//
// This object owns the row model, the cells, and the controls' handlers — the
// same code the sheet had, moved, not copied — and is owned by whichever
// PDSettingsViewController is drawing it.
// ---------------------------------------------------------------------------

/** Every live 3D-rows provider, so a bridge set or a Reset redraws all of them. */
static NSHashTable<PDVision3DRows *> *sProviders;

@implementation PDVision3DRows {
	__weak UITableView *_tableView;
	NSArray<PDVRow *> *_rows;
}

+ (void)reloadAll
{
	if (!NSThread.isMainThread) {
		dispatch_async(dispatch_get_main_queue(), ^{ [self reloadAll]; });
		return;
	}
	for (PDVision3DRows *p in sProviders.allObjects) {
		[p reload];
	}
}

- (instancetype)initWithTableView:(UITableView *)tableView
{
	if ((self = [super init])) {
		_tableView = tableView;
		[self buildRows];
		if (!sProviders) {
			sProviders = [NSHashTable weakObjectsHashTable];
		}
		[sProviders addObject:self];
	}
	return self;
}

- (NSInteger)count { return (NSInteger)_rows.count; }

/**
 * Redraw the 3D section only. A whole-table reload would rebuild ~40 iOS cells
 * to change a number in one of these.
 */
- (void)reload
{
	UITableView *tv = _tableView;
	const NSInteger s = tv.numberOfSections - 1;
	if (s < 0) {
		return;
	}
	[UIView performWithoutAnimation:^{
		[tv reloadSections:[NSIndexSet indexSetWithIndex:(NSUInteger)s]
		  withRowAnimation:UITableViewRowAnimationNone];
	}];
}

// --- the rows --------------------------------------------------------------

static PDVRow *pdVSlider(NSString *title, NSString *name, NSString *key,
                         float lo, float hi, NSString *(^text)(float))
{
	PDVRow *r = [PDVRow new];
	r.kind = PDVRowSlider; r.title = title; r.name = name; r.key = key;
	r.min = lo; r.max = hi; r.text = text;
	return r;
}

static PDVRow *pdVInfo(NSString *title, NSString *name, NSString *(^info)(void))
{
	PDVRow *r = [PDVRow new];
	r.kind = PDVRowInfo; r.title = title; r.name = name; r.info = info;
	return r;
}

/** A group's name, where the grouped table had a section header. */
static PDVRow *pdVCaption(NSString *title)
{
	PDVRow *r = [PDVRow new];
	r.kind = PDVRowCaption; r.title = title;
	return r;
}

/** A group's explanation, where the grouped table had a section footer. */
static PDVRow *pdVNote(NSString *text)
{
	PDVRow *r = [PDVRow new];
	r.kind = PDVRowNote; r.title = text;
	return r;
}

- (void)buildRows
{
	_rows = @[
		pdVCaption(@"Screen"),
		// SETTINGS-SPEC's four screen rows, in its order and its ranges.
		pdVSlider(@"Screen Distance", @"dist", PDDef3DDistance, 1.0f, 8.0f,
			^NSString *(float v) { return pdVLen(v, NO); }),
		// Stored as the HALF-extent (what the compositor scales a unit quad
		// by), shown as the full width (what a player means by "how wide").
		pdVSlider(@"Screen Width", @"width", PDDef3DHalfWidth, 0.6f, 6.096f,
			^NSString *(float v) { return pdVLen(v * 2.0f, NO); }),
		pdVSlider(@"Screen Height", @"height", PDDef3DHalfHeight, 0.5f, 3.0f,
			^NSString *(float v) { return pdVLen(v * 2.0f, NO); }),
		// SIGNED readout: 0 is eye level and the sign is the whole meaning
		// of the row. The panel tilts to face the viewer as it rises by
		// construction (PDImmersive.m's pdMakeAnchor faces the frozen head
		// from wherever the panel ends up), so there is no separate tilt.
		pdVSlider(@"Screen Position Height", @"posh", PDDef3DPosHeight, -1.5f, 10.0f,
			^NSString *(float v) { return pdVLen(v, YES); }),
		pdVNote(@"Where the screen hangs in the room. It is placed in front of you when 3D "
		         "starts and then stays put — Recenter Screen, at the bottom, moves it to "
		         "wherever you are looking now."),

		pdVCaption(@"Stereo"),
		// Per cent of the proven default separation (3.15 PD units ~ a
		// 63 mm IPD), which reads far better than raw units — and 0 % is
		// the gate's own instrument: both eyes become the mono projection
		// and an L/R pair must come out pixel-identical.
		pdVSlider(@"Stereo Depth", @"depth", PDDef3DStereoDepthPct, 0.0f, 300.0f,
			^NSString *(float v) { return [NSString stringWithFormat:@"%.0f%%", v]; }),
		// RENAMED from "Crosshair Distance" (D-064). That was the user's own
		// coinage and the family's shipped label (q2repro's SETTINGS-SPEC:
		// "after living with 'focus distance' he coined this and it
		// stuck"), and it was exactly right while the reticle LIVED on this
		// plane. It does not any more: the crosshair now takes the depth of
		// whatever it points at, so a row named after it would be naming
		// the one thing it no longer controls. This is the convergence
		// plane and nothing else, so it says so. PD units, 1 unit ~ 1 cm
		// (constants.h:496), so the readout divides by 100 to reach metres;
		// the stored key, the bridge row and `conv`/`crosshair` as bridge
		// spellings are all unchanged, so nothing scripted has to move.
		pdVSlider(@"Convergence", @"conv", PDDef3DCrosshairUnits, 100.0f, 1500.0f,
			^NSString *(float v) { return pdVLen(v / 100.0f, NO); }),
		pdVNote(@"Stereo Depth is how far apart the two eyes' cameras sit: 0% is a flat "
		         "picture, 100% is a normal pair of eyes. Convergence is the game distance "
		         "that sits exactly ON the screen — nearer things come towards you, further "
		         "things sit behind it. The crosshair is not on that plane: it takes the "
		         "depth of whatever it is pointing at."),

		pdVCaption(@"Panel"),
		pdVSlider(@"Surroundings Dimming", @"dim", PDDef3DDimming, 0.0f, 1.0f,
			^NSString *(float v) { return [NSString stringWithFormat:@"%.0f%%", v * 100.0f]; }),
		// The eye target's size as a percentage of its base. Applied on
		// RELEASE (see PDVRow.applyOnRelease): the ring is re-wrapped at a
		// frame boundary, and doing that per sample of a drag would tear
		// down and rebuild six textures sixty times a second.
		({
			PDVRow *r = pdVSlider(@"Render Resolution", @"render", PDDef3DRenderPct,
				40.0f, 100.0f,
				^NSString *(float v) { return [NSString stringWithFormat:@"%.0f%%", v]; });
			r.snap = YES;
			r.applyOnRelease = YES;
			r;
		}),
		pdVInfo(@"Panel Width", @"panelw", ^NSString *{
			int w = 0, h = 0; pdVisionEyeGetSize(&w, &h);
			return [NSString stringWithFormat:@"%d px", w];
		}),
		pdVInfo(@"Panel Height", @"panelh", ^NSString *{
			int w = 0, h = 0; pdVisionEyeGetSize(&w, &h);
			return [NSString stringWithFormat:@"%d px", h];
		}),
		pdVInfo(@"Aspect Ratio", @"aspect", ^NSString *{
			int w = 0, h = 0; pdVisionEyeGetSize(&w, &h);
			return (h > 0) ? [NSString stringWithFormat:@"%.1f:9", 9.0 * (double)w / (double)h]
			               : @"—";
		}),
		// The game's own counter (Video.DisplayFPS): it is drawn in PD's 2D
		// pass, which lands in both eyes, so it appears on the panel. Same
		// key as the Display section's Show FPS — one setting, two places to
		// reach it — which is also why Reset leaves it alone.
		({
			PDVRow *r = [PDVRow new];
			r.kind = PDVRowSwitch; r.title = @"FPS on Panel"; r.name = @"fps";
			r.key = PDDefShowFPS;
			r;
		}),
		pdVNote(@"Render Resolution is how many pixels the game draws for each eye, as a "
		         "share of the full panel. Lower it if 3D stutters; the change takes effect "
		         "as soon as you let go of the slider."),

		// D-054's unnamed last group: no caption, as it had no header.
		({
			PDVRow *r = [PDVRow new];
			r.kind = PDVRowSegmented; r.title = @"Units"; r.name = @"units";
			r.key = PDDef3DUnitsFeet;
			r.choices = @[ @"m", @"ft" ];
			r.values = @[ @0, @1 ];
			r;
		}),
		({
			PDVRow *r = [PDVRow new];
			r.kind = PDVRowButton; r.title = @"Recenter Screen"; r.name = @"recenter";
			r.action = ^{ pdVisionRecenter(); };
			r;
		}),
	];
}

/**
 * EVERY ROW, BY NAME, IN THE LOG, under its group's name. "Every row in §2.10
 * is present" is an acceptance item, and a room screenshot can only ever show
 * the rows inside the sheet's viewport. This line is what makes the claim
 * checkable by a gate (`settings row: [Group] Title (name)`, the M6 shape).
 */
- (void)logRows
{
	NSString *group = @"-";
	for (PDVRow *r in _rows) {
		if (r.kind == PDVRowCaption) {
			group = r.title;
			continue;
		}
		if (r.kind == PDVRowNote) {
			group = @"-";
			continue;
		}
		NSLog(@"perfectdark: [3d] settings row: [%@] %@ (%@)", group, r.title, r.name ?: @"-");
	}
}

// --- the header ------------------------------------------------------------

+ (CGFloat)headerHeight { return 92.0; }

/**
 * "3D Settings | Reset" — vkQuake's header view by way of openQ4
 * (openq4_ios_settings.m:1317-1368), both of its traps included: the table must
 * answer heightForHeaderInSection or a custom header is compressed, and the
 * BUTTON is anchored with the label hung off its centre, or the pill overhangs
 * the first row. OPAQUE, because a plain table's header floats over the rows.
 */
- (UIView *)headerViewForWidth:(CGFloat)width
{
	UIView *hv = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, PDVision3DRows.headerHeight)];
	hv.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1.0];

	UILabel *l = [UILabel new];
	l.text = @"3D Settings";
	l.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
	l.textColor = UIColor.whiteColor;
	l.translatesAutoresizingMaskIntoConstraints = NO;
	[hv addSubview:l];

	// A REAL tinted pill, not a bare text button: a bare one is nearly
	// impossible to gaze-pinch (SETTINGS-SPEC-FROM-VKQUAKE.md:31-35). Orange,
	// as the sheet bar's Reset was (D-054).
	UIButtonConfiguration *cfg = [UIButtonConfiguration tintedButtonConfiguration];
	cfg.title = @"Reset";
	cfg.baseForegroundColor = UIColor.systemOrangeColor;
	cfg.baseBackgroundColor = UIColor.systemOrangeColor;
	cfg.contentInsets = NSDirectionalEdgeInsetsMake(10, 22, 10, 22);
	UIButton *reset = [UIButton buttonWithConfiguration:cfg primaryAction:nil];
	reset.translatesAutoresizingMaskIntoConstraints = NO;
	[reset addTarget:self action:@selector(resetTapped) forControlEvents:UIControlEventTouchUpInside];
	[hv addSubview:reset];

	[NSLayoutConstraint activateConstraints:@[
		[l.leadingAnchor constraintEqualToAnchor:hv.leadingAnchor constant:20],
		[reset.trailingAnchor constraintEqualToAnchor:hv.trailingAnchor constant:-20],
		[reset.bottomAnchor constraintEqualToAnchor:hv.bottomAnchor constant:-16],
		[reset.topAnchor constraintGreaterThanOrEqualToAnchor:hv.topAnchor constant:8],
		[l.centerYAnchor constraintEqualToAnchor:reset.centerYAnchor],
		[l.trailingAnchor constraintLessThanOrEqualToAnchor:reset.leadingAnchor constant:-12],
	]];
	return hv;
}

/** The header's Reset: the 3D rows only, exactly as the sheet bar's was. */
- (void)resetTapped
{
	NSLog(@"perfectdark: [3d] settings header Reset pressed");
	pdVision3dSettingsResetDefaults();
}

// --- the cells -------------------------------------------------------------

- (UITableViewCell *)cellForRow:(NSInteger)index
{
	PDVRow *row = _rows[(NSUInteger)index];
	UITableViewCell *cell =
		[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
	cell.textLabel.text = row.title;
	cell.selectionStyle = UITableViewCellSelectionStyleNone;

	switch (row.kind) {
	case PDVRowSlider: {
		UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 260, 30)];
		sl.minimumValue = row.min;
		sl.maximumValue = row.max;
		sl.value = PDDefFloat(row.key);
		objc_setAssociatedObject(sl, @selector(commit), row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		[sl addTarget:self action:@selector(sliderChanged:)
		     forControlEvents:UIControlEventValueChanged];
		// The release, for the rows that only apply then. Both touch-up events:
		// a gaze-pinch that drifts off the thumb ends in TouchUpOutside.
		[sl addTarget:self action:@selector(sliderReleased:)
		     forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
		cell.accessoryView = sl;
		cell.detailTextLabel.text = row.text ? row.text(sl.value) : nil;
		break;
	}
	case PDVRowSwitch: {
		UISwitch *sw = [UISwitch new];
		sw.on = PDDefBool(row.key);
		objc_setAssociatedObject(sw, @selector(commit), row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		[sw addTarget:self action:@selector(switchChanged:)
		    forControlEvents:UIControlEventValueChanged];
		cell.accessoryView = sw;
		break;
	}
	case PDVRowSegmented: {
		UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:row.choices];
		seg.selectedSegmentIndex = PDDefBool(row.key) ? 1 : 0;
		objc_setAssociatedObject(seg, @selector(commit), row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		[seg addTarget:self action:@selector(segChanged:)
		     forControlEvents:UIControlEventValueChanged];
		cell.accessoryView = seg;
		break;
	}
	case PDVRowInfo:
		cell.detailTextLabel.text = row.info ? row.info() : @"";
		break;
	case PDVRowButton:
		cell.selectionStyle = UITableViewCellSelectionStyleDefault;
		cell.textLabel.textColor = cell.tintColor;
		break;
	case PDVRowCaption:
		// What an inset-grouped section header looks like, as a row.
		cell.textLabel.text = row.title.uppercaseString;
		cell.textLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
		cell.textLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
		cell.userInteractionEnabled = NO;
		break;
	case PDVRowNote:
		cell.textLabel.font = [UIFont systemFontOfSize:13];
		cell.textLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
		cell.textLabel.numberOfLines = 0;
		cell.userInteractionEnabled = NO;
		break;
	}
	return cell;
}

- (void)didSelectRow:(NSInteger)index
{
	PDVRow *row = _rows[(NSUInteger)index];
	if (row.kind == PDVRowButton && row.action) {
		NSLog(@"perfectdark: [3d] settings row pressed: %@", row.title);
		row.action();
	}
}

/**
 * Press a row by NAME, for the bridge (`3d settings press recenter`).
 *
 * The simulator injects no taps at all on visionOS, so without this there is no
 * scripted path through a button row — the same gap `settings row` fills on the
 * iOS sections.
 */
- (BOOL)pressRowNamed:(NSString *)name
{
	for (PDVRow *row in _rows) {
		if ([row.name isEqualToString:name] && row.action) {
			row.action();
			return YES;
		}
	}
	return NO;
}

/** This section's row index for a row name, or NSNotFound. */
- (NSInteger)rowIndexNamed:(NSString *)name
{
	for (NSUInteger i = 0; i < _rows.count; i++) {
		if ([_rows[i].name isEqualToString:name]) {
			return (NSInteger)i;
		}
	}
	return NSNotFound;
}

/**
 * Move a SEGMENTED 3D row through its own control, exactly as a finger would
 * (`3d settings seg units 0`) — the 3D twin of `settings seg`. The cell has to
 * be on screen; the bridge scrolls to it first. Returns what it moved, or nil.
 */
- (NSString *)setSegmentNamed:(NSString *)name to:(NSInteger)segIndex
{
	const NSInteger i = [self rowIndexNamed:name];
	UITableView *tv = _tableView;
	if (i == NSNotFound || !tv || _rows[(NSUInteger)i].kind != PDVRowSegmented) {
		return nil;
	}
	NSIndexPath *ip = [NSIndexPath indexPathForRow:i inSection:tv.numberOfSections - 1];
	[tv scrollToRowAtIndexPath:ip atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
	[tv layoutIfNeeded];
	UISegmentedControl *sc = (UISegmentedControl *)[tv cellForRowAtIndexPath:ip].accessoryView;
	if (![sc isKindOfClass:UISegmentedControl.class] || segIndex < 0
	    || segIndex >= (NSInteger)sc.numberOfSegments) {
		return nil;
	}
	sc.selectedSegmentIndex = segIndex;
	[self segChanged:sc];
	return [NSString stringWithFormat:@"3D/%@ -> %@", _rows[(NSUInteger)i].title,
		_rows[(NSUInteger)i].choices[(NSUInteger)segIndex]];
}

// --- the controls ----------------------------------------------------------

- (void)sliderChanged:(UISlider *)sl
{
	PDVRow *row = objc_getAssociatedObject(sl, @selector(commit));
	if (row.snap) {
		sl.value = roundf(sl.value);
	}
	[NSUserDefaults.standardUserDefaults setFloat:sl.value forKey:row.key];
	if (!row.applyOnRelease) {
		// LIVE, on every sample: instant feedback on the panel is the whole
		// point of a geometry slider (SETTINGS-SPEC). This is five float
		// stores, not a settings commit — there is no coalescer to wait for.
		pdVision3dApplySettings();
	}
	// The label beside the thumb, without reloading the table under the finger.
	UITableViewCell *cell = (UITableViewCell *)sl.superview;
	if ([cell isKindOfClass:UITableViewCell.class] && row.text) {
		cell.detailTextLabel.text = row.text(sl.value);
	}
}

- (void)sliderReleased:(UISlider *)sl
{
	PDVRow *row = objc_getAssociatedObject(sl, @selector(commit));
	pdVision3dApplySettings();
	// EVERY slider's release commits the panel geometry (D-058): the three
	// Screen rows change the eye's aspect and pixel count, and the others cost
	// one comparison that returns immediately.
	pdVision3dCommitGeometry();
	if (row.applyOnRelease || [row.name isEqualToString:@"width"]
	    || [row.name isEqualToString:@"height"] || [row.name isEqualToString:@"dist"]) {
		NSLog(@"perfectdark: [3d] %@ released at %.0f", row.title, (double)sl.value);
		// Panel Width / Height / Aspect are read from the eye, and the eye is
		// re-wrapped a frame or two from now — so the info rows are refreshed
		// after the boundary, not before it.
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
			dispatch_get_main_queue(), ^{ [PDVision3DRows reloadAll]; });
	}
}

- (void)switchChanged:(UISwitch *)sw
{
	PDVRow *row = objc_getAssociatedObject(sw, @selector(commit));
	[NSUserDefaults.standardUserDefaults setBool:sw.on forKey:row.key];
	if ([row.key isEqualToString:PDDefShowFPS]) {
		// An engine config key: it goes through the same apply as the iOS
		// rows, on the game thread, and is written to pd.ini straight away.
		[PDShell.shared enqueue:^{
			PDDefaultsApplyToEngine();
			configSave("$S/pd.ini");
		}];
		// The Display section's Show FPS is the same key, on the same page.
		[PDSettingsViewController reloadRows];
	} else {
		pdVision3dApplySettings();
	}
}

- (void)segChanged:(UISegmentedControl *)seg
{
	PDVRow *row = objc_getAssociatedObject(seg, @selector(commit));
	[NSUserDefaults.standardUserDefaults setBool:(seg.selectedSegmentIndex == 1)
	                                      forKey:row.key];
	NSLog(@"perfectdark: [3d] settings %@ -> %@", row.title,
		row.choices[(NSUInteger)seg.selectedSegmentIndex]);
	// Every length readout in the section just changed its unit.
	[PDVision3DRows reloadAll];
}

@end

// ---------------------------------------------------------------------------
// The sheet's table
//
// The SAME page as the in-window gear's (D-082): a PDSettingsViewController,
// iOS sections and the 3D section, hosted by PD3DSettingsSheet in the SwiftUI
// `.sheet` instead of in its own UIWindow — a UIKit modal presented directly
// over an open immersive space silently fails (SETTINGS-SPEC :13-37), and the
// sheet's bar (title, Done) stays SwiftUI's. All this subclass adds is what the
// bridge and the M6 gate already reach for: +current, the row log, the frame log.
// ---------------------------------------------------------------------------

static __weak PDVisionSettingsViewController *sCurrent;

@implementation PDVisionSettingsViewController

+ (PDVisionSettingsViewController *)current { return sCurrent; }

+ (void)reloadRows
{
	if (!NSThread.isMainThread) {
		dispatch_async(dispatch_get_main_queue(), ^{ [self reloadRows]; });
		return;
	}
	[sCurrent.tableView reloadData];
}

- (instancetype)init
{
	return [super initWithStyle:UITableViewStylePlain];
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	sCurrent = self;
	[self.rows3d logRows];
	NSLog(@"perfectdark: [3d] settings table loaded (%ld sections, the last one 3D)",
		(long)[self numberOfSectionsInTableView:self.tableView]);
}

- (void)viewDidAppear:(BOOL)animated
{
	[super viewDidAppear:animated];
	sCurrent = self;
	[self.tableView reloadData];
	// The GoldenEye rows read a cached scan, as on the in-window page's open.
	[PDXbla warmGoldenEyeScan:^{ [PDVisionSettingsViewController reloadRows]; }];
	// The charter's evidence rule: a UIKit placement is proven by the view
	// logging its own frame, never by "the screenshot looks right".
	NSLog(@"perfectdark: [3d] settings table on screen frame=%@ content=%@",
		NSStringFromCGRect(self.tableView.frame),
		NSStringFromCGSize(self.tableView.contentSize));
}

- (BOOL)pressRowNamed:(NSString *)name
{
	return [self.rows3d pressRowNamed:name];
}

@end

#endif // TARGET_OS_VISION
