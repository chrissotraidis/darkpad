// pd_ios_main.m — the iOS process entry point for Perfect Dark.
//
// Order of business, and why each thing is where it is:
//
//   1. publish Documents and Caches in the environment, which is where
//      port/src/fs.c picks both data roots up (overlay patch 0009);
//   2. install the crash handler before anything can crash (PDCrash.m —
//      upstream installs none at all on Apple, crash.c:324);
//   3. write a launch beacon, so a run that dies before the first log line is
//      still distinguishable from an app that never started;
//   4. assemble argv: the process arguments (xcrun simctl launch --args ...)
//      plus Documents/pd.args, one flag per line, for a device where there is
//      no command line;
//   5. register the lifecycle hooks: configSave on resign-active (upstream's
//      only caller is an atexit handler, and a swipe-kill is SIGKILL), and the
//      background/foreground pair that stops the renderer presenting into a
//      CAMetalLayer the system has taken back;
//   6. hand off to SDL_UIKitRunApp, which brings up UIApplication and calls
//      back into pdSDLMain on the same thread;
//   7. in pdSDLMain, BEFORE the engine: onboarding if there is no ROM (the
//      engine's own answer to a missing ROM is sysFatalError, which on a phone
//      is a dead end), then the bridge, the pacer and the pad;
//   8. pdEngineMain() (overlay patch 0010), which never returns. The touch
//      overlay is installed from the first frame hook, because that is the
//      first moment SDL's UIWindow exists.
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

// SDL_main.h does `#define main SDL_main` on iOS, which would quietly rename
// the function below and leave the executable with no entry point at all
// ("Undefined symbols: _main", referenced from <initial-undefines>). We provide
// main() ourselves and call SDL_UIKitRunApp() by hand, which is the whole of
// what SDL2main's iOS main() does.
#define SDL_MAIN_HANDLED 1
#include <signal.h>
#include <SDL.h>
#include <SDL_main.h>
#include <SDL_hints.h>

#import "PDShell.h"
#import "PDCrash.h"
#import "PDAudio.h"
#import "PDXbla.h"
#import "PDTexPacks.h"
#import "PDPacing.h"
#import "PDDefaults.h"
#import "PDOnboarding.h"
#import "PDDeepLink.h"
#import "PDController.h"
#import "PDTouchOverlay.h"
#import "PDSettingsViewController.h"
#import "PDWatchdog.h"
#ifndef PD_PUBLIC
#import "PDBridge.h"
#endif

#include "build_stamp.h"

#define PD_CONFIG_PATH "$S/pd.ini"

// app/gfx/gfx_angle_egl.mm
extern void pdAngleSuspend(void);
extern void pdAngleResume(void);

static BOOL pdReplayRun = NO;

// Written before anything else can fail. If this file is present and pd.log is
// not, the engine died between UIApplication coming up and the first log line.
static void pdWriteLaunchBeacon(NSString *docs)
{
	NSString *path = [docs stringByAppendingPathComponent:@"launch-beacon.txt"];
	NSString *text = [NSString stringWithFormat:
		@"perfectdark-ios launch\nbuild: %s\nversion: %s\nwhen: %@\ndocuments: %@\n",
		PD_IOS_BUILD_STAMP, PD_IOS_MARKETING_VERSION, [NSDate date], docs];
	[text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

/**
 * Extra launch flags from Documents/pd.args, one per line, '#' comments ignored.
 *
 * The simulator can pass a command line (`xcrun simctl launch --args`) and a
 * device cannot, so the seeded-replay flags that the whole regression vehicle
 * rests on (--rng-seed, --fixed-step, --exit-frame, --screenshot-frame,
 * --boot-stage) need a second way in that survives a Files drop. Everything the
 * CLI accepts is accepted here; see docs/upstream-cli.md.
 */
static NSArray<NSString *> *pdArgsFromFile(NSString *docs)
{
	NSString *path = [docs stringByAppendingPathComponent:@"pd.args"];
	NSString *body = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
	if (!body) {
		return @[];
	}
	NSMutableArray *out = [NSMutableArray array];
	for (NSString *rawLine in [body componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
		NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
		if (line.length == 0 || [line hasPrefix:@"#"]) {
			continue;
		}
		// A line may hold several whitespace-separated flags, the way a command
		// line does; quoting is deliberately not supported, no PD flag needs it.
		for (NSString *word in [line componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]) {
			if (word.length) {
				[out addObject:word];
			}
		}
	}
	return out;
}

static void pdSaveConfigNow(void)
{
	if (!PDShell.shared.engineRunning) {
		return;
	}
	// Order matters: inputSaveBinds() refreshes the strings the config entries
	// point at, then configSave() writes them. docs/frame-map.md.
	inputSaveBinds();
	configSave(PD_CONFIG_PATH);
	NSLog(@"perfectdark: config written on resign-active");
}

/**
 * The same write, callable from elsewhere in the shell (PDShell.h).
 *
 * The visionOS 3D mode needs it: a Crown dismissal of the immersive space is
 * very often the first half of a swipe-kill, and a swipe-kill is SIGKILL, so
 * pd.ini has to be on disk before it rather than at the next resign-active
 * that may never come. Game thread, like every other caller.
 */
void pdIosSaveConfigNow(void)
{
	pdSaveConfigNow();
}

/**
 * perfectdark:// deep links, without owning the app delegate.
 *
 * SDL2's own UIApplicationDelegate handles application:openURL:options: and
 * turns it into an SDL_DROPFILE event, so an event watch is all the shell needs
 * to see one - and an event watch sees it whatever the lifecycle state, which
 * matters because iOS delivers a launch URL before the engine exists. The link
 * is queued and consumed in the frame hook (PDShell.m).
 */
static int pdSDLEventWatch(void *userdata, SDL_Event *event)
{
	(void)userdata;
	if (event->type == SDL_DROPFILE && event->drop.file) {
		NSString *s = @(event->drop.file);
		if ([s.lowercaseString hasPrefix:@"perfectdark:"]) {
			NSURL *url = [NSURL URLWithString:s];
			if (url) {
				[PDShell.shared queueDeepLink:url];
			}
		}
	}
	return 0;
}

static void pdRegisterLifecycle(void)
{
	NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;

	[nc addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:nil
		usingBlock:^(NSNotification *note) { (void)note; PDLifecycle("app resign-active -> configSave"); pdSaveConfigNow(); }];

	[nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil
		usingBlock:^(NSNotification *note) {
			(void)note;
			PDLifecycle("app BACKGROUND -> pdAngleSuspend + pacer suspend");
			NSLog(@"perfectdark: background — pausing the pacer and the renderer");
			pdAngleSuspend();
			[PDPacing.shared suspend];
		}];

	[nc addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:nil
		usingBlock:^(NSNotification *note) {
			(void)note;
			PDLifecycle("app FOREGROUND -> pdAngleResume + pacer resume");
			NSLog(@"perfectdark: foreground — resuming");
			pdAngleResume();
			[PDPacing.shared resume];
		}];

	[nc addObserverForName:UIApplicationWillTerminateNotification object:nil queue:nil
		usingBlock:^(NSNotification *note) { (void)note; pdSaveConfigNow(); }];

	// The scene-lifecycle twins, because the app declares a scene manifest from
	// D-038 on and the app-level notifications above are a compatibility
	// courtesy rather than a contract. Both fire in a scene-based app today;
	// pdSaveConfigNow() is idempotent and the pacer's suspend/resume already
	// no-op when they are already in that state, so the doubling costs nothing
	// and the save surviving is what matters (swipe-kill is SIGKILL).
	[nc addObserverForName:UISceneWillDeactivateNotification object:nil queue:nil
		usingBlock:^(NSNotification *note) { (void)note; pdSaveConfigNow(); }];

	[nc addObserverForName:UISceneDidEnterBackgroundNotification object:nil queue:nil
		usingBlock:^(NSNotification *note) {
			(void)note;
			PDLifecycle("scene BACKGROUND -> pdAngleSuspend + pacer suspend");
			NSLog(@"perfectdark: scene background — pausing the pacer and the renderer");
			pdAngleSuspend();
			[PDPacing.shared suspend];
		}];

	[nc addObserverForName:UISceneWillEnterForegroundNotification object:nil queue:nil
		usingBlock:^(NSNotification *note) {
			(void)note;
			PDLifecycle("scene FOREGROUND -> pdAngleResume + pacer resume");
			NSLog(@"perfectdark: scene foreground — resuming");
			pdAngleResume();
			[PDPacing.shared resume];
		}];
}

int pdSDLMain(int argc, char *argv[])
{
	@autoreleasepool {
		[UIApplication sharedApplication].idleTimerDisabled = YES;

		PDDefaultsRegister();

		// SDL2 disables drop events by default (SDL_events.c:646), and a
		// perfectdark:// link arrives as one - SDL's own delegate turns
		// application:openURL: into SDL_SendDropFile. Without this the watch
		// below is never called and deep links silently do nothing. (The
		// engine's event loop ignores SDL_DROPFILE, so the string SDL
		// allocated for each link is leaked; it is one short string per deep
		// link and the alternative is owning the app delegate.)
		SDL_EventState(SDL_DROPFILE, SDL_ENABLE);
		SDL_AddEventWatch(pdSDLEventWatch, NULL);

		// ...and the path iOS actually uses now, which SDL has no idea about:
		// a scene-based app gets its URLs through -scene:openURLContexts: on
		// the scene delegate. PDDeepLink.m explains what was measured.
		[PDDeepLink install];

		// Copies into added-content/ or Documents that a killed app never
		// finished (D-075) - hidden from every scan by their leading dot, and
		// removed here before anything looks or copies.
		[PDXbla sweepPartialCopies];

		// Before the engine: a missing or wrong ROM is a fatal error inside
		// romdataInit() (romdata.c:204-238) and a phone has nowhere to put an
		// SDL message box. This returns only once a ROM the engine will accept
		// is in Documents.
		[PDOnboarding runUntilRomPresent];

		// Before SDL's audio device opens (videoInit/audioInit are inside
		// pdEngineMain): SDL configures the session as `.ambient`, which the
		// Ring/Silent switch mutes, so ours is set first and re-asserted on
		// drift afterwards, off the game thread (D-033). Not in a replay -
		// those run --no-sound and an active session there is a device opened
		// for nothing.
		if (!pdReplayRun) {
			[PDAudio begin];
		}

#ifndef PD_PUBLIC
		// Before the unpack, not after: the unpack is the longest thing that
		// happens before the engine exists, and it is the one the gate most
		// needs to be able to watch. `state` answers without an engine.
		[PDBridge start];
#endif

		// The one-time XBLA unpack, before the engine and with a progress
		// screen up (D-020). After this the engine's own xblaImportGetStfsPath()
		// is a scan and a stat rather than a quarter of a gigabyte on the
		// thread UIKit draws from.
		[PDXbla runUnpackUntilReady];
		// GE Plus's two files: looked for once now, on a background queue, so the
		// settings page has an answer the first time it opens (D-072).
		[PDXbla warmGoldenEyeScan:nil];

		// A texture pack dropped into Files: unpack it and write the row-order
		// marker BEFORE the engine's first texture load, for the same reason
		// the XBLA unpack is here (D-020). See PDTexPacks.h.
		[PDTexPacks prepare];

		// Upstream's inputInit() (input.c:846-873) turns on every SDL HIDAPI
		// driver hint, Steam included. On iOS SDL's HIDAPI backend is
		// src/hidapi/ios/hid.m, and with SDL_HINT_JOYSTICK_HIDAPI_STEAM set it
		// creates a CBCentralManager the moment the game-controller subsystem
		// starts - and iOS aborts any app that touches CoreBluetooth without
		// NSBluetoothAlwaysUsageDescription (the 0.0.0.2/0.0.0.3 device crash,
		// "Abort trap: 6" under CoreBluetooth on a dispatch queue; the sim does
		// not enforce it, so the gate stayed green). Pads arrive through
		// GCController (PDController) and SDL's own iOS joystick backend;
		// HIDAPI on iOS only ever meant Steam Controllers over BLE. OVERRIDE
		// priority outranks the engine's later plain SDL_SetHint calls.
		SDL_SetHintWithPriority(SDL_HINT_JOYSTICK_HIDAPI, "0", SDL_HINT_OVERRIDE);
		SDL_SetHintWithPriority(SDL_HINT_JOYSTICK_HIDAPI_STEAM, "0", SDL_HINT_OVERRIDE);

		// Half of the keyboard trap (D-033, the user on device): creating a
		// profile offers "type with the iOS keyboard", and once it was up there
		// was no way down - force-quit. SDL only calls SDL_StopTextInput() from
		// textFieldShouldReturn: when this hint is set, and nothing set it
		// (SDL_uikitviewcontroller.m:587-596). The other half is overlay 0024,
		// which makes the same Return ACCEPT the name rather than be dropped on
		// the floor by inputTextHandler().
		SDL_SetHintWithPriority(SDL_HINT_RETURN_KEY_HIDES_IME, "1", SDL_HINT_OVERRIDE);

#if !TARGET_OS_VISION
		// The "picture squeezed into the left of the screen until relaunch"
		// fault (D-077). The engine's window is RESIZABLE, so with no hint
		// SDL's view controller claims portrait as well as landscape
		// (UIKit_GetSupportedOrientations). And on EVERY keyboard notification
		// in the process - the Files picker's search field raises one - SDL's
		// view controller recomputes its view frame (updateKeyboard ->
		// UIKit_ComputeViewFrame), deciding landscape vs portrait from
		// UIApplication.statusBarOrientation, which under the UIScene life
		// cycle is Unknown. Unknown plus "portrait is supported" = portrait:
		// SDL laid its view out 420x912 on a 912x420 scene and kept it. The
		// app is landscape-only on iPhone and iPad (Info.plist); saying so to
		// SDL makes that computation answer landscape whatever the status bar
		// claims. PDGeometry.m repairs any portrait shape that still gets in.
		SDL_SetHintWithPriority(SDL_HINT_ORIENTATIONS, "LandscapeLeft LandscapeRight", SDL_HINT_OVERRIDE);
#endif

		[PDPacing.shared startWithBypass:pdReplayRun];
		PDPacing.shared.targetHz = PDDefInt(PDDefRefreshHz) >= 120 ? 120 : 60;
		[PDController.shared start];

		PDShell.shared.replayRun = pdReplayRun;
		PDShell.shared.engineRunning = YES;
	}

	return pdEngineMain(argc, (const char **)argv);
}

/**
 * Everything main() does before handing the process to SDL, in one function
 * both entry points call.
 *
 * There are two entry points from round V on. On iOS, main() below runs this
 * and then calls SDL_UIKitRunApp, which brings up UIApplication and calls back
 * into pdSDLMain (D-038). On visionOS there is no main() at all: an
 * ImmersiveSpace can only be declared by a SwiftUI `App`, so PDVisionApp.swift
 * owns the process entry and PDHostViewController calls this and then pdSDLMain
 * directly, from a run-loop timer (D-047). Nothing in here depends on which of
 * the two called it - UIApplication may or may not exist yet, and every step
 * below is happy either way.
 *
 * Returns the assembled argv (NULL-terminated, strdup'd, never freed - it
 * outlives the process) and writes its count to *outArgc.
 */
char **pdShellPrepare(int argc, char *argv[], int *outArgc)
{
	@autoreleasepool {
		NSString *docs = PDShell.shared.documentsPath;
		NSString *caches = PDShell.shared.cachesPath;

		setenv("PD_IOS_DOCUMENTS", docs.fileSystemRepresentation, 1);
		setenv("PD_IOS_CACHES", caches.fileSystemRepresentation, 1);
		// SDL's iOS backend would otherwise let the screen dim; the engine also
		// asks for this once UIApplication exists (pdSDLMain).
		setenv("SDL_HINT_IDLE_TIMER_DISABLED", "1", 1);

		// The render-scale row, published as an environment variable because
		// that is where the renderer reads it: gfx_angle_egl.mm has no way to
		// ask NSUserDefaults, and the value is wanted before ANGLE's first
		// surface exists. Two guards, and both matter:
		//
		//   * an explicit PD_IOS_RENDER_SCALE always wins (the gates set it via
		//     SIMCTL_CHILD_ so the replay draws the oracle's resolution), and
		//     this never overwrites it - it sets a different variable that
		//     pdAngleApplyRenderScale() only consults when the absolute one is
		//     absent;
		//   * a seeded replay is skipped outright, for the same reason it skips
		//     the settings push: in a determinism run the container is the
		//     truth and a leftover NSUserDefaults value is not.
		//
		// Live changes are not possible: the drawable size is an engine-wide
		// input (viewport, framebuffers, the 2D scale), so the row's footer
		// says it takes effect on the next launch. Applied below, once argv has
		// said whether this is a replay.
		PDDefaultsRegister();

		[[NSFileManager defaultManager] createDirectoryAtPath:docs
		                          withIntermediateDirectories:YES attributes:nil error:NULL];

		// Belt to the bridge's braces (PDBridge sets SO_NOSIGPIPE per socket):
		// nothing in this app should ever die because a socket peer went away,
		// and the default disposition of SIGPIPE is to kill the process.
		signal(SIGPIPE, SIG_IGN);

		[PDCrash install];
		pdWriteLaunchBeacon(docs);
		// Before anything can go quiet: the heartbeat, the lifecycle log and the
		// hang dumper (D-044). It starts here rather than in pdSDLMain so that
		// didFinishLaunching and the scene's own connection are already on the
		// record by the time the engine exists.
		[PDWatchdog start];

		NSArray<NSString *> *extra = pdArgsFromFile(docs);

		// argv[0] plus the process arguments plus the file's, in that order, so
		// a --args flag on the simulator can still be overridden by a later one
		// the way a command line behaves.
		int total = argc + (int)extra.count;
		char **argvOut = (char **)calloc((size_t)total + 1, sizeof(char *));
		int n = 0;
		for (int i = 0; i < argc; i++) {
			argvOut[n++] = strdup(argv[i]);
		}
		for (NSString *a in extra) {
			argvOut[n++] = strdup(a.UTF8String);
		}
		argvOut[n] = NULL;

		NSMutableString *shown = [NSMutableString string];
		for (int i = 0; i < n; i++) {
			[shown appendFormat:@"%s ", argvOut[i]];
			// A seeded replay paces itself: the display link would hold it to
			// 60 fps and turn a ten-second gate into a two-minute one
			// (docs/pacing.md).
			if (!strcmp(argvOut[i], "--fixed-step") || !strcmp(argvOut[i], "--exit-frame")) {
				pdReplayRun = YES;
			}
		}
		if (!pdReplayRun) {
			const NSInteger pct = PDDefInt(PDDefRenderScalePct);
			if (pct > 0 && pct != 100) {
				char buf[32];
				snprintf(buf, sizeof(buf), "%.4f", (double)pct / 100.0);
				setenv("PD_IOS_RENDER_FRACTION", buf, 1);
				NSLog(@"perfectdark: render scale %ld%% -> PD_IOS_RENDER_FRACTION=%s", (long)pct, buf);
			}
		}

		NSLog(@"perfectdark: build %s (%s)", PD_IOS_BUILD_STAMP, PD_IOS_MARKETING_VERSION);
		NSLog(@"perfectdark: documents %@", docs);
		NSLog(@"perfectdark: argv %@", shown);

		pdRegisterLifecycle();

		if (outArgc) {
			*outArgc = n;
		}
		return argvOut;
	}
}

#if !TARGET_OS_VISION
int main(int argc, char *argv[])
{
	int n = 0;
	char **argvOut = pdShellPrepare(argc, argv, &n);
	return SDL_UIKitRunApp(n, argvOut, pdSDLMain);
}
#endif
