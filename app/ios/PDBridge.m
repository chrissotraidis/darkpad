// PDBridge.m — the console bridge on TCP :8775 (D-002).
//
// This is what scripts/sim-validate.sh drives, and it is the reason a claim
// about this port can be checked rather than believed. It is compiled out of
// public builds: with PD_PUBLIC defined there is no listener, no thread and no
// commands - the file builds to nothing.
//
// Shape:
//   - one listener thread, one detached thread per client, line-oriented;
//   - SO_REUSEADDR plus a bind retry, because a simulator run that is killed
//     leaves the port in TIME_WAIT and the next run must not silently come up
//     without a bridge;
//   - every command that touches the engine runs in PDShell's frame-boundary
//     queue and the socket thread waits for the answer. Nothing here calls an
//     engine function on the socket thread. Ever.
//
// The commands are documented in docs/remote-console.md, which is the file to
// change when this one does.
#import <Foundation/Foundation.h>

#ifndef PD_PUBLIC

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#import "PDBridge.h"
#import "PDShell.h"
#import "PDPacing.h"
#import "PDTouchOverlay.h"
#import "PDSettingsViewController.h"
#import "PDDefaults.h"
#import "PDOnboarding.h"
#import "PDXbla.h"
#import "PDTexPacks.h"
#import "PDAudio.h"
#import "PDController.h"   // round Q: `pad fake` / `pad lx`
#import "PDWatchdog.h"     // round S: `heartbeat` / `hang` / `dump`
#import "PDGeometry.h"     // D-077: `geo` / `presented` / `picker`
#if !TARGET_OS_VISION
#import "PDSceneDelegate.h"
#endif
#if TARGET_OS_VISION
#import "PDVision3D.h"       // round V: `3d on|off|state`
#endif

// The engine's own, declared here rather than by dragging the decomp's headers
// into an ObjC translation unit (which is what every other engine call in this
// file does too).
extern int invGiveSingleWeapon(int weaponnum);
extern void bgunEquipWeapon(int weaponnum);
// The magazine (D-065): `give` armed Joanna with an EMPTY gun, so a scripted
// burst pressed the trigger on nothing and the crash-path session that found it
// was firing no rounds at all. The ammo readout is the evidence half — a burst
// that fired is a burst whose quantity went DOWN.
extern void bgunGiveMaxAmmo(int force);
extern int bgunGetAmmoQtyForWeapon(unsigned weaponnum, unsigned func);
// GE Plus's startup notice (overlay 0042) and the window surface's presents
// (app/gfx/gfx_angle_egl.mm): the background instrument of D-075.
extern int g_GexPlusNoticeDrawn;
extern int g_GexPlusNoticeHeld;
extern unsigned long long pdAngleSwapCount(void);

static const int kDefaultPort = 8775;
static const NSTimeInterval kEngineTimeout = 5.0;

/**
 * The port to listen on: 8775 (D-002), or PD_BRIDGE_PORT if it is set.
 *
 * The family note is one bridge per port at a time, and a simulator's loopback
 * is the MAC's loopback — an iPhone sim and the Vision Pro sim running this same
 * app would both try to bind :8775 and the second would sit in the retry loop
 * below for fifteen seconds and then come up bridge-less. The visionOS gate
 * therefore runs on 8785 (`SIMCTL_CHILD_PD_BRIDGE_PORT=8785 xcrun simctl
 * launch …`; docs/remote-console.md).
 */
static int pdBridgePort(void)
{
	const char *s = getenv("PD_BRIDGE_PORT");
	if (s && *s) {
		int p = atoi(s);
		if (p > 0 && p < 65536) {
			return p;
		}
		NSLog(@"perfectdark: [bridge] ignoring PD_BRIDGE_PORT=%s", s);
	}
	return kDefaultPort;
}

@implementation PDBridge

+ (void)start
{
	NSThread *t = [[NSThread alloc] initWithTarget:self selector:@selector(listen) object:nil];
	t.name = @"pd-bridge";
	[t start];
}

+ (void)listen
{
	const int kPort = pdBridgePort();
	int srv = socket(AF_INET, SOCK_STREAM, 0);
	if (srv < 0) {
		NSLog(@"perfectdark: [bridge] socket() failed: %s", strerror(errno));
		return;
	}

	int yes = 1;
	setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

	struct sockaddr_in addr;
	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_addr.s_addr = htonl(INADDR_ANY);
	addr.sin_port = htons(kPort);

	// A simulator run killed mid-flight leaves the port in TIME_WAIT for a
	// couple of minutes. Retrying beats coming up without a bridge and failing
	// the next validation run for the wrong reason.
	int bound = 0;
	for (int attempt = 0; attempt < 30; attempt++) {
		if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
			bound = 1;
			break;
		}
		NSLog(@"perfectdark: [bridge] bind :%d failed (%s), retry %d/30", kPort, strerror(errno), attempt + 1);
		usleep(500 * 1000);
	}
	if (!bound || listen(srv, 4) != 0) {
		NSLog(@"perfectdark: [bridge] GAVE UP on :%d — no console this run", kPort);
		close(srv);
		return;
	}

	NSLog(@"perfectdark: [bridge] listening on :%d", kPort);

	while (1) {
		int fd = accept(srv, NULL, NULL);
		if (fd < 0) {
			if (errno == EINTR) {
				continue;
			}
			NSLog(@"perfectdark: [bridge] accept failed: %s", strerror(errno));
			break;
		}
		// SO_NOSIGPIPE, and it is not a nicety.
		//
		// A write to a socket whose peer has gone raises SIGPIPE, whose default
		// disposition is to kill the process - and the peer here is a `nc -w N`
		// that gives up while a command is still running. A `tap` that landed
		// on "create this agent file" took longer than the client's timeout,
		// the client closed, the reply was written, and the GAME DIED, with no
		// crash.txt (SIGPIPE is not one of the faults PDCrash installs for) and
		// nothing in the log. The console that exists to prove things about the
		// port was killing the port.
		int nosig = 1;
		setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, sizeof(nosig));

		NSThread *c = [[NSThread alloc] initWithTarget:self selector:@selector(serve:) object:@(fd)];
		c.name = @"pd-bridge-client";
		[c start];
	}

	close(srv);
}

+ (void)serve:(NSNumber *)fdnum
{
	int fd = fdnum.intValue;
	char buf[4096];
	NSMutableString *line = [NSMutableString string];

	while (1) {
		ssize_t n = read(fd, buf, sizeof(buf) - 1);
		if (n <= 0) {
			break;
		}
		buf[n] = '\0';
		[line appendString:@(buf) ?: @""];

		NSRange nl;
		while ((nl = [line rangeOfString:@"\n"]).location != NSNotFound) {
			NSString *cmd = [[line substringToIndex:nl.location]
				stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
			[line deleteCharactersInRange:NSMakeRange(0, nl.location + 1)];

			if (cmd.length == 0) {
				continue;
			}

			@autoreleasepool {
				NSString *reply = [self run:cmd];
				if (!reply) {          // `quit` answers nil: the app is going away
					close(fd);
					return;
				}
				if (![reply hasSuffix:@"\n"]) {
					reply = [reply stringByAppendingString:@"\n"];
				}
				NSData *out = [reply dataUsingEncoding:NSUTF8StringEncoding];
				write(fd, out.bytes, out.length);
			}
		}
	}

	close(fd);
}

// ---------------------------------------------------------------------------

static NSString *pdErr(NSString *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
	va_end(ap);
	return [@"ERR " stringByAppendingString:s];
}

/** Run one command line. Returns the reply, or nil when the app is quitting. */
+ (NSString *)run:(NSString *)cmdline
{
	NSMutableArray<NSString *> *argv = [NSMutableArray array];
	for (NSString *w in [cmdline componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
		if (w.length) {
			[argv addObject:w];
		}
	}
	NSString *cmd = argv.firstObject.lowercaseString;
	PDShell *shell = PDShell.shared;

	if ([cmd isEqualToString:@"help"]) {
		return @"commands: state | screenshot [path] | stage 0xNN | cfg get <k> | cfg set <k> <v> |"
		        " tap X Y [HOLD_MS | 0 = lift in the same delivery | cancel = cancelled in it; in the layout editor it selects a chip or hits its eye badge] | doubletap X Y | hit X Y | windows | heal <1-6> | pump <ms> | point X Y | drag X Y DX DY | stream X Y DX DY N MS | pacing [reset|engine HZ|early on|off|wait sem|runloop] | pad <button> <down|up> | touch <auto|on|off|latch on|off> | link <url> |"
		        " settings [close|<section>|row <section> <n>] | settings seg <section> <n> <i> | layout <edit|done|reset> |"
		        " audio [volume 0-100|mute on|off|mode 0-4|reset] | render <pct> |"
		        " prof [reset] | gfx |"
		        " gamefile <defaults|save|load [dev]> |"
		        " rom | xbla [wait N|release on|off|pick <path>] | geplus [scan|pick rom|xbla|hack <path>|release on|off] | adopt fail copy|swap|off | texpack | quit |"
		        " heartbeat | hang <ms> | dump | graft <on|off> | hide60 <on|off> |"
		        " stall <ms>|every <s> <ms>|off | geo [repair on|off|now] | presented | picker cancel|dismiss|pick <path> |"
		        " audio trace on|off|dump [name] | audio interrupt begin|end |"
		        " give <weaponnum> [noammo] | ammo <weaponnum> | pacing engine <hz|auto>"
#if TARGET_OS_VISION
	        " | 3d <on|off|park|unpark|crown|showeye|state|recenter|depth <pct>|gunconv <units>"
	        "|settings <open|close|get|set <row> <value>|press <row>|reset>>"
#endif
	        ;
	}

	if ([cmd isEqualToString:@"state"]) {
		__block NSString *out = nil;
		if (shell.engineRunning) {
			// On the game thread so the numbers all come from one frame.
			if (![shell enqueueAndWait:^{ out = [shell stateReport]; } timeout:kEngineTimeout]) {
				return pdErr(@"engine did not reach a frame boundary in %.0fs", kEngineTimeout);
			}
		} else {
			out = [shell stateReport];
		}
		NSString *extra = [NSString stringWithFormat:@"settings_page=%d\n"
			"present_allowed=%d\nnotice_drawn=%d\nnotice_held=%d\negl_swaps=%llu\n",
			(int)PDSettingsViewController.isPresented, pdIosPresentAllowed(),
			g_GexPlusNoticeDrawn, g_GexPlusNoticeHeld, pdAngleSwapCount()];
		return [out stringByAppendingString:extra];
	}

	if ([cmd isEqualToString:@"rom"]) {
		NSString *path = [PDOnboarding installedRomPath];
		if (!path) {
			return @"rom=none";
		}
		PDRomCheck *c = [PDOnboarding classifyFileAtPath:path];
		return [NSString stringWithFormat:@"rom=%@\nmd5=%@\nverdict=%ld\nwhy=%@",
			path.lastPathComponent, c.md5 ?: @"-", (long)c.verdict, c.explanation];
	}

	// The XBLA package: what is in Documents/xbla, whether it has been unpacked
	// into Caches yet, and - the half the gate needs - a way to WAIT for that,
	// because the unpack is a quarter of a gigabyte on a background thread and
	// polling a container path from the host is racing the app's own writes.
	// GE Plus's two files (D-072). `geplus` alone: the cached scan, no I/O on
	// the main thread. `geplus scan`: rescan in the background and wait for it.
	// `geplus pick <rom|xbla|hack> <path>`: the settings rows' picker completion with
	// a file the simulator can read - the same validation, copy into
	// added-content/, replace and alert as a real Files pick. The real picker's
	// UI is the one thing it does not exercise.
	// `geplus release on|off`: the GoldenEye XBLA switch row (D-081), the same
	// path as the row; answers what pd.ini now says and what this run uses.
	if ([cmd isEqualToString:@"geplus"]) {
		if (argv.count >= 3 && [argv[1].lowercaseString isEqualToString:@"release"]) {
			BOOL on = [argv[2].lowercaseString isEqualToString:@"on"];
			[PDSettingsViewController setSwitchRow:PDDefXblaGoldenEye to:on];
			__block int ini = -1, run = -1;
			if (![shell enqueueAndWait:^{
					char v[16] = { 0 };
					if (configGetValue("Mod.XblaGoldenEye", v, sizeof(v))) {
						ini = atoi(v);
					}
					run = gebeanSwitchIsOn();
				} timeout:kEngineTimeout]) {
				return pdErr(@"engine did not reach a frame boundary");
			}
			return [NSString stringWithFormat:@"ge_xbla asked=%d ini=%d this_run=%d (next launch takes it)",
				(int)on, ini, run];
		}
		if (argv.count >= 4 && [argv[1].lowercaseString isEqualToString:@"pick"]) {
			NSString *which = argv[2].lowercaseString;
			NSInteger kind = [which isEqualToString:@"rom"] ? PDGoldenEyeRom
				: [which isEqualToString:@"hack"] ? PDGoldenEyeHack : PDGoldenEyeXbla;
			NSString *path = [[argv subarrayWithRange:NSMakeRange(3, argv.count - 3)] componentsJoinedByString:@" "];
			if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
				return pdErr(@"no such file: %@", path);
			}
			[PDSettingsViewController goldenEyePicked:kind url:[NSURL fileURLWithPath:path]];
			return [NSString stringWithFormat:@"geplus picked %@ for %@ (see the alert and `geplus`)",
				path.lastPathComponent, argv[2]];
		}
		dispatch_semaphore_t done = dispatch_semaphore_create(0);
		__block NSString *lines = nil;
		BOOL rescan = argv.count >= 2 && [argv[1].lowercaseString isEqualToString:@"scan"];
		dispatch_async(dispatch_get_main_queue(), ^{
			if (rescan) {
				[PDXbla warmGoldenEyeScan:^{
					lines = [PDXbla goldenEyeStateLines];
					dispatch_semaphore_signal(done);
				}];
			} else {
				lines = [PDXbla goldenEyeStateLines];
				dispatch_semaphore_signal(done);
			}
		});
		dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)));
		return lines ?: pdErr(@"no answer from the main thread");
	}

	if ([cmd isEqualToString:@"xbla"]) {
		if (argv.count >= 2 && [argv[1].lowercaseString isEqualToString:@"wait"]) {
			NSTimeInterval limit = argv.count > 2 ? argv[2].doubleValue : 600.0;
			NSDate *until = [NSDate dateWithTimeIntervalSinceNow:limit];
			while (until.timeIntervalSinceNow > 0) {
				if (PDXbla.isUnpacked) {
					return [NSString stringWithFormat:@"xbla_extracted=1 secs=%.1f\n%@",
						PDXbla.lastUnpackSeconds, [PDXbla stateLines]];
				}
				PDXblaFind *f = PDXbla.scan;
				if (f.kind == PDXblaPackage) {
					return [@"xbla_extracted=1 (a bare package; nothing to unpack)\n"
						stringByAppendingString:[PDXbla stateLines]];
				}
				if (!f.found) {
					return pdErr(@"no package in %@", PDXbla.dropDir);
				}
				usleep(500 * 1000);
			}
			return pdErr(@"the unpack did not finish in %.0fs\n%@", limit, [PDXbla stateLines]);
		}
		if (argv.count >= 3 && [argv[1].lowercaseString isEqualToString:@"release"]) {
			BOOL on = [argv[2].lowercaseString isEqualToString:@"on"];
			[PDSettingsViewController setSwitchRow:PDDefXblaWholeRelease to:on];
			__block int now = -1;
			if (![shell enqueueAndWait:^{ now = xblaSwitchGetEnabled(); } timeout:kEngineTimeout]) {
				return pdErr(@"engine did not reach a frame boundary");
			}
			return [NSString stringWithFormat:@"xbla_release asked=%d xbla_enabled=%d", (int)on, now];
		}
		// `xbla pick <path>`: the Xbox 360 row's / onboarding's picker copy with a
		// file already in the container (the real picker cannot be driven here).
		if (argv.count >= 3 && [argv[1].lowercaseString isEqualToString:@"pick"]) {
			NSString *path = [[argv subarrayWithRange:NSMakeRange(2, argv.count - 2)] componentsJoinedByString:@" "];
			if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
				return pdErr(@"no such file: %@", path);
			}
			__block NSString *dst = nil;
			__block NSError *err = nil;
			dispatch_semaphore_t done = dispatch_semaphore_create(0);
			dispatch_async(dispatch_get_main_queue(), ^{
				NSError *e = nil;
				dst = [PDXbla adoptPickedURL:[NSURL fileURLWithPath:path] error:&e];
				err = e;
				[PDXbla invalidateScan];
				dispatch_semaphore_signal(done);
			});
			if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_SEC)))) {
				return pdErr(@"no answer from the main thread");
			}
			return dst ? [NSString stringWithFormat:@"xbla_pick=ok dst=%@", dst]
			           : [NSString stringWithFormat:@"xbla_pick=FAILED why=%@", err.localizedDescription];
		}
		return [PDXbla stateLines];
	}

	// `adopt fail copy|swap|off`: make the next copy into added-content/ fail at
	// that stage (PDXbla +failNextCopyAt:, D-075), to prove a failed replace
	// leaves the existing file as it was.
	if ([cmd isEqualToString:@"adopt"]) {
		if (argv.count >= 3 && [argv[1].lowercaseString isEqualToString:@"fail"]) {
			NSString *stage = argv[2].lowercaseString;
			if (![@[ @"copy", @"swap", @"off" ] containsObject:stage]) {
				return pdErr(@"usage: adopt fail copy|swap|off");
			}
			dispatch_async(dispatch_get_main_queue(), ^{
				[PDXbla failNextCopyAt:[stage isEqualToString:@"off"] ? nil : stage];
			});
			return [NSString stringWithFormat:@"adopt_fail_next=%@", stage];
		}
		return pdErr(@"usage: adopt fail copy|swap|off");
	}

	if ([cmd isEqualToString:@"screenshot"]) {
		if (!shell.engineRunning) {
			return pdErr(@"engine not running yet");
		}
		NSString *dir = [shell.documentsPath stringByAppendingPathComponent:@"screenshots"];
		NSSet *before = [NSSet setWithArray:
			[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:NULL] ?: @[]];

		// The game's own capture: taken in the pre-swap callback of the frame
		// being drawn (screenshot.c:174), so it is the frame the renderer
		// produced, the right way up, and not the simulator's portrait panel.
		if (![shell enqueueAndWait:^{ screenshotRequest(); } timeout:kEngineTimeout]) {
			return pdErr(@"engine did not reach a frame boundary");
		}

		NSString *made = nil;
		for (int i = 0; i < 100 && !made; i++) {
			usleep(50 * 1000);
			for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:NULL] ?: @[]) {
				if (![before containsObject:f] && [f.pathExtension.lowercaseString isEqualToString:@"png"]) {
					made = [dir stringByAppendingPathComponent:f];
					break;
				}
			}
		}
		if (!made) {
			return pdErr(@"no screenshot appeared in %@", dir);
		}

		if (argv.count > 1) {
			NSString *dst = argv[1];
			[NSFileManager.defaultManager removeItemAtPath:dst error:NULL];
			NSError *err = nil;
			if (![NSFileManager.defaultManager moveItemAtPath:made toPath:dst error:&err]) {
				return pdErr(@"could not move to %@: %@", dst, err.localizedDescription);
			}
			made = dst;
		}

		NSDictionary *a = [NSFileManager.defaultManager attributesOfItemAtPath:made error:NULL];
		return [NSString stringWithFormat:@"screenshot=%@ bytes=%llu", made, a.fileSize];
	}

	if ([cmd isEqualToString:@"stage"]) {
		if (argv.count < 2) {
			return pdErr(@"usage: stage 0xNN");
		}
		int stage = (int)strtol(argv[1].UTF8String, NULL, 0);
		__block int now = -1;
		if (![shell enqueueAndWait:^{ mainChangeToStage(stage); now = mainGetStageNum(); } timeout:kEngineTimeout]) {
			return pdErr(@"engine did not reach a frame boundary");
		}
		return [NSString stringWithFormat:@"stage requested 0x%x (was 0x%x)", stage, now];
	}

	if ([cmd isEqualToString:@"cfg"]) {
		if (argv.count < 3) {
			return pdErr(@"usage: cfg get <Section.Key> | cfg set <Section.Key> <value>");
		}
		NSString *sub = argv[1].lowercaseString;
		NSString *key = argv[2];

		if ([sub isEqualToString:@"get"]) {
			__block NSString *val = nil;
			if (![shell enqueueAndWait:^{
					char buf[512];
					val = configGetValue(key.UTF8String, buf, sizeof(buf)) ? @(buf) : nil;
				} timeout:kEngineTimeout]) {
				return pdErr(@"engine did not reach a frame boundary");
			}
			return val ? [NSString stringWithFormat:@"%@=%@", key, val] : pdErr(@"no such key %@", key);
		}

		if ([sub isEqualToString:@"set"]) {
			if (argv.count < 4) {
				return pdErr(@"usage: cfg set <Section.Key> <value>");
			}
			NSString *val = [[argv subarrayWithRange:NSMakeRange(3, argv.count - 3)] componentsJoinedByString:@" "];
			__block BOOL ok = NO;
			__block NSString *readback = nil;
			if (![shell enqueueAndWait:^{
					ok = configSetValue(key.UTF8String, val.UTF8String) != 0;
					char buf[512];
					if (configGetValue(key.UTF8String, buf, sizeof(buf))) {
						readback = @(buf);
					}
				} timeout:kEngineTimeout]) {
				return pdErr(@"engine did not reach a frame boundary");
			}
			// The read-back matters: config.c clamps silently, so "set" and
			// "what it became" are different questions.
			return ok ? [NSString stringWithFormat:@"%@=%@", key, readback ?: val]
			          : pdErr(@"no such key %@", key);
		}

		return pdErr(@"cfg get|set");
	}

	// What is under a point, WITHOUT pressing it. `tap` reports the same string
	// but has already acted on it, which makes "where are the chips" an
	// unanswerable question the moment one of the answers opens a menu.
	if ([cmd isEqualToString:@"hit"]) {
		if (argv.count < 3) {
			return pdErr(@"usage: hit X Y");
		}
		CGPoint p = CGPointMake(argv[1].doubleValue, argv[2].doubleValue);
		__block NSString *what = nil;
		dispatch_semaphore_t done = dispatch_semaphore_create(0);
		dispatch_async(dispatch_get_main_queue(), ^{
			PDTouchOverlay *v = PDTouchOverlay.current;
			what = v ? [v hitTestReportAtPoint:p] : @"MISS no-overlay";
			dispatch_semaphore_signal(done);
		});
		if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)))) {
			return pdErr(@"UIKit did not respond (is the game loop running?)");
		}
		return [NSString stringWithFormat:@"hit=%@", what];
	}

	if ([cmd isEqualToString:@"tap"] || [cmd isEqualToString:@"drag"]
			|| [cmd isEqualToString:@"doubletap"]) {
		BOOL drag = [cmd isEqualToString:@"drag"];
		BOOL twice = [cmd isEqualToString:@"doubletap"];
		if (argv.count < (drag ? 5u : 3u)) {
			return pdErr(@"usage: %@", drag ? @"drag X Y DX DY" : @"tap X Y [HOLD_MS]");
		}
		CGPoint p = CGPointMake(argv[1].doubleValue, argv[2].doubleValue);
		CGVector d = drag ? CGVectorMake(argv[3].doubleValue, argv[4].doubleValue) : CGVectorMake(0, 0);

		__block NSString *what = nil;
		dispatch_semaphore_t done = dispatch_semaphore_create(0);
		// UIKit, so the main queue; the main run loop is pumped by SDL from
		// inside the game loop, which is why this arrives at all.
		dispatch_async(dispatch_get_main_queue(), ^{
			PDTouchOverlay *v = PDTouchOverlay.current;
			if (!v) {
				what = @"MISS no-overlay";
			} else if (drag) {
				what = [v injectDragFrom:p by:d];
			} else if (twice) {
				what = [v injectDoubleTapAtPoint:p];
			} else {
				// 140 ms is a tap. An explicit hold is what lets a script
				// LOOK at the press while it is still down - `state`'s
				// touch_sent_mask is the only proof a chip reached the engine,
				// and it is zero again 140 ms later (D-037).
				what = [v injectTapAtPoint:p
				         holdMilliseconds:(argv.count > 3
				             ? ([argv[3].lowercaseString isEqualToString:@"cancel"] ? -1 : argv[3].integerValue)
				             : 140)];
			}
			dispatch_semaphore_signal(done);
		});
		if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)))) {
			return pdErr(@"UIKit did not respond (is the game loop running?)");
		}
		return [NSString stringWithFormat:@"hit=%@", what];
	}

	// What is in Documents/texture-packs, whether each folder carries the
	// row-order marker, and which one the engine has selected. The marker is
	// the whole difference between a pack and an upside-down pack
	// (CLAUDE-notes/texture-packs.md), and it is invisible in a screenshot of
	// anything symmetrical - so it is asserted here instead.
	// The pacing instrument (D-034). `pacing` prints the report on its own,
	// `pacing reset` zeroes the frame-interval histogram so the next window
	// measures one thing - which is the whole point of an A/B.
	// `give <weaponnum>` — put a weapon in Joanna's hands (OTA builds only, like
	// the rest of the bridge).
	//
	// It exists because of a VERIFICATION GAP that shipped a bug: `--boot-stage`
	// drops the player into a level without running the mission's loadout, so
	// every 3D gate before dev1 ran UNARMED, PD draws no viewmodel when unarmed,
	// and "the gun is invisible in 3D" therefore could not be seen on a
	// simulator at all. The user found it in the headset instead.
	//
	// WEAPON_FALCON2 is 2 (constants.h:4653); anything the enum knows works.
	if ([cmd isEqualToString:@"give"]) {
		if (argv.count < 2) {
			return pdErr(@"usage: give <weaponnum>   (2 = Falcon 2)");
		}
		const int wep = (int)argv[1].integerValue;
		if (wep < 1 || wep > 60) {
			return pdErr(@"weapon number out of range: %@", argv[1]);
		}
		// `give 17 noammo` keeps the old behaviour (the weapon, empty).
		const BOOL noammo = (argv.count > 2 && [argv[2].lowercaseString isEqualToString:@"noammo"]);
		__block int got = 0, ammo = 0;
		if (![shell enqueueAndWait:^{
				got = invGiveSingleWeapon(wep) ? 1 : 0;
				bgunEquipWeapon(wep);
				if (!noammo) {
					bgunGiveMaxAmmo(1);
				}
				ammo = bgunGetAmmoQtyForWeapon((unsigned)wep, 0);
			} timeout:kEngineTimeout]) {
			return pdErr(@"engine did not reach a frame boundary");
		}
		return [NSString stringWithFormat:@"gave=%d inventory_accepted=%d ammo=%d", wep, got, ammo];
	}

	// `ammo <weaponnum>` — the quantity for that weapon's primary function, read
	// and nothing else. A burst of automatic fire is proved by the drop.
	if ([cmd isEqualToString:@"ammo"]) {
		if (argv.count < 2) {
			return pdErr(@"usage: ammo <weaponnum>");
		}
		const int wep = (int)argv[1].integerValue;
		if (wep < 1 || wep > 60) {
			return pdErr(@"weapon number out of range: %@", argv[1]);
		}
		__block int ammo = 0;
		if (![shell enqueueAndWait:^{
				ammo = bgunGetAmmoQtyForWeapon((unsigned)wep, 0);
			} timeout:kEngineTimeout]) {
			return pdErr(@"engine did not reach a frame boundary");
		}
		return [NSString stringWithFormat:@"weapon=%d ammo=%d", wep, ammo];
	}

	if ([cmd isEqualToString:@"pacing"]) {
		if (argv.count > 1 && [argv[1].lowercaseString isEqualToString:@"reset"]) {
			[PDPacing.shared resetHistogram];
			return @"pacing_histogram=reset";
		}
		// `pacing engine <hz>` forces the engine's declared tick rate without
		// touching the panel's. It exists because the SIMULATOR reports
		// maximumFramesPerSecond = 60 for every device, ProMotion or not
		// (docs/build.md §Traps, round C) - so the one case that matters, a
		// link running faster than the engine can tick, cannot be reached
		// there by asking for 120. Setting the engine's rate to 30 under a
		// 60 Hz link reaches exactly the same code with the same arithmetic.
		// `pacing early on|off` moves the one display-link wait from just before
		// the present to the top of the frame (D-040). Live, so the two
		// placements can be compared on the same device in the same session.
		// `pacing wait sem|runloop` (D-045): HOW the game thread waits for the
		// link. The game thread is the MAIN thread, so a semaphore wait blocks
		// UIKit's own event dispatch for the whole of the pacer's slack and
		// touches queue undelivered; the run-loop wait services the loop while
		// it waits. Live, so the broken and fixed halves can be A/B'd on the
		// phone in one session with no relaunch.
		if (argv.count > 2 && [argv[1].lowercaseString isEqualToString:@"wait"]) {
			NSString *mode = argv[2].lowercaseString;
			if (![mode isEqualToString:@"sem"] && ![mode isEqualToString:@"runloop"]) {
				return pdErr(@"pacing wait: expected sem|runloop, got %@", argv[2]);
			}
			PDPacing.shared.waitMode = [mode isEqualToString:@"runloop"]
				? PDPacingWaitRunLoop : PDPacingWaitSem;
			[PDPacing.shared resetHistogram];
			return [PDPacing.shared report];
		}
		if (argv.count > 2 && [argv[1].lowercaseString isEqualToString:@"early"]) {
			PDPacing.shared.earlyWait = [argv[2].lowercaseString isEqualToString:@"on"];
			[PDPacing.shared resetHistogram];
			return [NSString stringWithFormat:@"pacing_early=%d\n%@",
				(int)PDPacing.shared.earlyWait, [PDPacing.shared report]];
		}
		if (argv.count > 2 && [argv[1].lowercaseString isEqualToString:@"engine"]
				&& [argv[2].lowercaseString isEqualToString:@"auto"]) {
			// Unpin: under the compositor clock the engine's declared rate goes
			// back to following the cadence (D-056).
			PDPacing.shared.engineHzPinned = NO;
			return [NSString stringWithFormat:@"pacing_engine_pinned=0\n%@",
				[PDPacing.shared report]];
		}
		if (argv.count > 2 && [argv[1].lowercaseString isEqualToString:@"engine"]) {
			const NSInteger hz = argv[2].integerValue;
			if (hz < 1 || hz > 240) {
				return pdErr(@"engine hz out of range: %@", argv[2]);
			}
			// Pinned: an explicit rate is an instrument and must survive the
			// compositor clock's own rate-following (D-056).
			PDPacing.shared.engineHzPinned = YES;
			PDPacing.shared.engineTickHz = hz;
			// The engine's own gate, the other half of D-034: 0 is uncapped,
			// N divides the 60 Hz tick rate by N.
			[shell enqueueAndWait:^{
				char buf[8];
				snprintf(buf, sizeof(buf), "%d", hz >= 120 ? 0 : (int)MAX(1, lround(60.0 / (double)hz)));
				configSetValue("Game.TickRateDivisor", buf);
			} timeout:kEngineTimeout];
			return [PDPacing.shared report];
		}
		return [PDPacing.shared report];
	}

	// A continuous synthetic touch stream: the touch-vs-pad comparison the user
	// made, run from a script. `stream X Y DX DY N MS`.
	if ([cmd isEqualToString:@"stream"]) {
		if (argv.count < 7) {
			return pdErr(@"usage: stream X Y DX DY N MS");
		}
		CGPoint p = CGPointMake(argv[1].doubleValue, argv[2].doubleValue);
		CGVector d = CGVectorMake(argv[3].doubleValue, argv[4].doubleValue);
		int n = argv[5].intValue;
		double ms = argv[6].doubleValue;
		__block NSString *what = nil;
		dispatch_semaphore_t done = dispatch_semaphore_create(0);
		dispatch_async(dispatch_get_main_queue(), ^{
			PDTouchOverlay *v = PDTouchOverlay.current;
			what = v ? [v injectStreamFrom:p by:d steps:n intervalMs:ms] : @"MISS no-overlay";
			dispatch_semaphore_signal(done);
		});
		if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)))) {
			return pdErr(@"UIKit did not respond (is the game loop running?)");
		}
		return [NSString stringWithFormat:@"hit=%@", what];
	}

	if ([cmd isEqualToString:@"texpack"]) {
		NSMutableString *out = [NSMutableString string];
		NSString *dir = PDTexPacks.dropDir;
		[out appendFormat:@"texpack_dir=%@\n", dir];
		NSArray<NSString *> *packs = PDTexPacks.installedPacks;
		[out appendFormat:@"texpack_packs=%lu\n", (unsigned long)packs.count];
		for (NSString *n in packs) {
			BOOL marked = [NSFileManager.defaultManager fileExistsAtPath:
				[[dir stringByAppendingPathComponent:n] stringByAppendingPathComponent:@"bottomup.txt"]];
			[out appendFormat:@"texpack_pack=%@ bottomup=%d\n", n, marked ? 1 : 0];
		}
		if (shell.engineRunning) {
			__block int sel = -2, num = 0;
			__block NSString *selName = @"-";
			if (![shell enqueueAndWait:^{
				texpackRefreshPacks();
				num = texpackGetNumPacks();
				sel = texpackGetSelectedPack();
				const char *nm = (sel >= 0) ? texpackGetPackName(sel) : NULL;
				selName = nm ? @(nm) : @"-";
			} timeout:kEngineTimeout]) {
				return pdErr(@"engine did not reach a frame boundary in %.0fs", kEngineTimeout);
			}
			[out appendFormat:@"texpack_enabled=%d\ntexpack_engine_packs=%d\ntexpack_selected=%d\ntexpack_selected_name=%@\n",
				texpackLoadEnabled(), num, sel, selName];
		}
		return out;
	}

	if ([cmd isEqualToString:@"point"]) {
		if (argv.count < 3) {
			return pdErr(@"usage: point X Y   (move the menu highlight, do not choose)");
		}
		CGPoint p = CGPointMake(argv[1].doubleValue, argv[2].doubleValue);
		__block NSString *what = nil;
		dispatch_semaphore_t done = dispatch_semaphore_create(0);
		dispatch_async(dispatch_get_main_queue(), ^{
			PDTouchOverlay *v = PDTouchOverlay.current;
			what = v ? [v movePointerOnlyTo:p] : @"MISS no-overlay";
			dispatch_semaphore_signal(done);
		});
		if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)))) {
			return pdErr(@"UIKit did not respond (is the game loop running?)");
		}
		return [NSString stringWithFormat:@"hit=%@", what];
	}

	// --- round Q (D-037): the two `pad` sub-commands a simulator needs --------
	// A simulator cannot be handed or taken away a controller, and injected
	// events bypass UIKit, so the two things the user reported - the gear on a
	// pad pause, and the touch layer coming back dead when the pad is unplugged
	// - have no script at all without these. Both drive the REAL paths: `fake`
	// runs the same -padsChanged: the connect/disconnect notifications run, and
	// `lx` feeds the same double-flick state machine a thumb feeds.
	if ([cmd isEqualToString:@"pad"] && argv.count >= 2
			&& [argv[1].lowercaseString isEqualToString:@"fake"]) {
		NSString *want = argv.count > 2 ? argv[2].lowercaseString : @"";
		int state;
		if ([want isEqualToString:@"on"])       { state = 1; }
		else if ([want isEqualToString:@"off"]) { state = 0; }
		else if ([want isEqualToString:@"auto"]) { state = -1; }
		else { return pdErr(@"usage: pad fake <on|off|auto>"); }

		__block NSString *out = nil;
		dispatch_semaphore_t done = dispatch_semaphore_create(0);
		dispatch_async(dispatch_get_main_queue(), ^{
			PDTouchOverlaySetFakePad(state);
			[PDController.shared padsChanged];
			PDTouchOverlay *v = PDTouchOverlay.current;
			out = [NSString stringWithFormat:@"pad_fake=%d pad_connected=%d overlay_hidden=%d "
				@"overlay_interactive=%d overlay_in_window=%d",
				state, (int)PDTouchOverlayAnyPadConnected(), (int)v.hidden,
				(int)v.userInteractionEnabled, (int)(v.window != nil)];
			dispatch_semaphore_signal(done);
		});
		if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)))) {
			return pdErr(@"UIKit did not respond (is the game loop running?)");
		}
		return out;
	}

	if ([cmd isEqualToString:@"pad"] && argv.count >= 3
			&& [argv[1].lowercaseString isEqualToString:@"flick"]) {
		// The whole gesture in one enqueued block: out, back, out. Everything
		// the state machine checks is exercised (both thresholds, the matching
		// sides, the 300 ms window) except the wall-clock spacing, which three
		// separate `pad lx` round trips cannot guarantee anyway - nc reconnects
		// between them and the window is 300 ms.
		NSString *side = argv[2].lowercaseString;
		float v;
		if ([side isEqualToString:@"left"])       { v = -0.9f; }
		else if ([side isEqualToString:@"right"]) { v = +0.9f; }
		else { return pdErr(@"usage: pad flick <left|right>"); }

		__block NSString *a = nil, *b = nil, *c = nil;
		if (![shell enqueueAndWait:^{
				PDController *pc = PDController.shared;
				a = [pc injectLeftStickX:v];
				b = [pc injectLeftStickX:0.0f];
				c = [pc injectLeftStickX:v];
				[pc injectLeftStickX:0.0f];
			} timeout:kEngineTimeout]) {
			return pdErr(@"engine did not reach a frame boundary");
		}
		return [NSString stringWithFormat:@"pad flick %@ -> %@ | %@ | %@", side, a, b, c];
	}

	if ([cmd isEqualToString:@"pad"] && argv.count >= 3
			&& [argv[1].lowercaseString isEqualToString:@"lx"]) {
		const float x = argv[2].floatValue;
		__block NSString *out = nil;
		if (![shell enqueueAndWait:^{
				out = [PDController.shared injectLeftStickX:x];
			} timeout:kEngineTimeout]) {
			return pdErr(@"engine did not reach a frame boundary");
		}
		return [NSString stringWithFormat:@"pad lx %.2f -> %@", x, out];
	}
	// --- end round Q ----------------------------------------------------------

	if ([cmd isEqualToString:@"pad"]) {
		if (argv.count < 3) {
			return pdErr(@"usage: pad <a|b|z|start|l|r|cu|cd|cl|cr|x|y|roll|crouch> <down|up>"
				@" | pad fake <on|off|auto> | pad lx <-1..1> | pad flick <left|right>");
		}
		static NSDictionary<NSString *, NSNumber *> *names;
		static dispatch_once_t once;
		dispatch_once(&once, ^{
			names = @{
				@"a": @(PDPadA), @"b": @(PDPadB), @"z": @(PDPadG), @"start": @(PDPadStart),
				@"l": @(PDPadL), @"r": @(PDPadR),
				@"cu": @(PDPadCUp), @"cd": @(PDPadCDown), @"cl": @(PDPadCLeft), @"cr": @(PDPadCRight),
				@"up": @(PDPadUp), @"down": @(PDPadDown), @"left": @(PDPadLeft), @"right": @(PDPadRight),
				@"x": @(0x40u), @"y": @(0x80u), @"roll": @(0x08000000u), @"crouch": @(0x80000000u),
			};
		});
		NSNumber *mask = names[argv[1].lowercaseString];
		if (!mask) {
			return pdErr(@"unknown button %@", argv[1]);
		}
		BOOL down = [argv[2].lowercaseString isEqualToString:@"down"];
		__block unsigned now = 0;
		if (![shell enqueueAndWait:^{
				inputIosPadSetButton(mask.unsignedIntValue, down);
				now = inputIosPadGetButtons();
			} timeout:kEngineTimeout]) {
			return pdErr(@"engine did not reach a frame boundary");
		}
		return [NSString stringWithFormat:@"pad %@ %@ mask=0x%x", argv[1], down ? @"down" : @"up", now];
	}

	if ([cmd isEqualToString:@"link"]) {
		// Feeds a perfectdark:// URL into the same queue the system's own
		// delivery uses (PDDeepLink.m), so the parse-and-consume half is
		// testable from a script. The delivery half cannot be: on iOS 27
		// `simctl openurl` puts up an "Open in Perfect Dark?" confirmation that
		// nothing can tap (idb ui tap is dead, and injected events bypass
		// UIKit) - that dialog is itself the proof the scheme is registered.
		if (argv.count < 2) {
			return pdErr(@"usage: link perfectdark://stage/0x1d");
		}
		NSURL *url = [NSURL URLWithString:argv[1]];
		if (!url || ![url.scheme.lowercaseString isEqualToString:@"perfectdark"]) {
			return pdErr(@"not a perfectdark:// url: %@", argv[1]);
		}
		[shell queueDeepLink:url];
		return [NSString stringWithFormat:@"link queued %@", url];
	}

	// Where a REAL touch would go (D-041). `hit` answers from the overlay's own
	// model and is right even when UIKit is delivering every touch somewhere
	// else; this walks the windows the way UIKit does and hit-tests from the
	// window, so it is the one command that can see a routing failure. Run it
	// either side of a transition (settings open/close, a pad connect, the
	// layout editor) and compare `route_ok`.
	// The numbered recovery experiments (D-041 round 2). The user's phone reaches
	// a state where route_ok=1 and no touch is ever delivered; it has never
	// reproduced anywhere else. Rather than guess the cause, each candidate
	// recovery is a number, tried one at a time over USB while he is IN the
	// broken state, with `ui_hittests` in the report saying whether UIKit
	// started delivering again. Whichever one works names the cause.
	if ([cmd isEqualToString:@"heal"]) {
		const int which = argv.count > 1 ? argv[1].intValue : 0;
		__block NSString *out = nil;
		dispatch_semaphore_t done = dispatch_semaphore_create(0);
		dispatch_async(dispatch_get_main_queue(), ^{
			out = [PDTouchOverlay heal:which];
			dispatch_semaphore_signal(done);
		});
		if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)))) {
			return pdErr(@"UIKit did not respond (is the game loop running?)");
		}
		return out;
	}

	// `pump <ms>` — give the main run loop a real turn in the DEFAULT mode at the
	// end of every frame hook (D-043). SDL's own pump runs
	// CFRunLoopRunInMode(default, 0.000002, TRUE), which is enough for the
	// main-queue source (so the bridge always answers) and may not be enough for
	// a port-based HID source once the frame is paced the way D-040 paces it.
	// If this restores delivery on the broken instance, that is the answer.
	if ([cmd isEqualToString:@"pump"]) {
		if (argv.count > 1) {
			int ms = argv[1].intValue;
			pdExtraPumpMs = (ms < 0) ? 0 : (ms > 8 ? 8 : ms);
		}
		return [NSString stringWithFormat:@"pump_ms=%d", pdExtraPumpMs];
	}

	// ---- round S / D-044: the instruments that do not need a socket ---------
	//
	// These four exist because the failure they chase makes this very socket go
	// silent. They are here so the SIMULATOR can prove the files are written and
	// the stack walk is real; on the phone the files are the whole answer.

	// `heartbeat` — exactly what Documents/heartbeat.txt holds this second.
	if ([cmd isEqualToString:@"heartbeat"]) {
		return [PDWatchdog report];
	}

	// `hang <ms>` — block the GAME thread on purpose, so the watchdog's 2-second
	// trip and its stack walk can be proven on the simulator rather than
	// believed. Enqueued (not enqueueAndWait): the socket thread must come back
	// at once, and the block is what has to be stuck.
	if ([cmd isEqualToString:@"hang"]) {
		const int ms = argv.count > 1 ? argv[1].intValue : 3000;
		[shell enqueue:^{ PDWatchdogFakeHang(ms); }];
		return [NSString stringWithFormat:@"hang_queued_ms=%d", ms];
	}

	// `stall <ms>` / `stall every <s> <ms>` / `stall off` — block the GAME
	// thread for a fixed time, once or on a repeat, to reproduce a hitch
	// deterministically (D-078: what the audio does across one). Unlike `hang`
	// this is a plain sleep with nothing else attached, and it is short: the
	// watchdog's 2 s trip is not the point.
	if ([cmd isEqualToString:@"stall"]) {
		static volatile int sStallEveryMs = 0, sStallEveryLen = 0, sStallGen = 0;
		NSString *what = argv.count > 1 ? argv[1].lowercaseString : @"";
		if ([what isEqualToString:@"off"]) {
			sStallGen++;
			sStallEveryMs = 0;
			return @"stall_every=off";
		}
		if ([what isEqualToString:@"every"] && argv.count > 3) {
			const int periodMs = (int)lround(argv[2].doubleValue * 1000.0);
			const int len = argv[3].intValue;
			if (periodMs < 100 || len <= 0 || len > 5000) {
				return pdErr(@"usage: stall every <seconds> <ms 1-5000>");
			}
			const int gen = ++sStallGen;
			sStallEveryMs = periodMs;
			sStallEveryLen = len;
			[NSThread detachNewThreadWithBlock:^{
				while (sStallGen == gen) {
					usleep((useconds_t)sStallEveryMs * 1000);
					if (sStallGen != gen) {
						break;
					}
					const int l = sStallEveryLen;
					[shell enqueue:^{
						PDLifecycle("bridge: stall %d ms (repeat)", l);
						usleep((useconds_t)l * 1000);
					}];
				}
			}];
			return [NSString stringWithFormat:@"stall_every_ms=%d stall_ms=%d", periodMs, len];
		}
		const int ms = what.intValue;
		if (ms <= 0 || ms > 5000) {
			return pdErr(@"usage: stall <ms 1-5000> | stall every <seconds> <ms> | stall off");
		}
		[shell enqueue:^{
			PDLifecycle("bridge: stall %d ms", ms);
			usleep((useconds_t)ms * 1000);
		}];
		return [NSString stringWithFormat:@"stall_queued_ms=%d", ms];
	}

	// `geo` / `geo repair on|off|now` — the picture's size chain (D-077).
	if ([cmd isEqualToString:@"geo"]) {
		NSString *what = argv.count > 1 ? argv[1].lowercaseString : @"";
		NSString *arg = argv.count > 2 ? argv[2].lowercaseString : @"";
		__block NSString *out = nil;
		dispatch_semaphore_t done = dispatch_semaphore_create(0);
		dispatch_async(dispatch_get_main_queue(), ^{
			if ([what isEqualToString:@"repair"] && [arg isEqualToString:@"off"]) {
				pdGeoRepairEnabled = 0;
			} else if ([what isEqualToString:@"repair"] && [arg isEqualToString:@"on"]) {
				pdGeoRepairEnabled = 1;
			} else if ([what isEqualToString:@"repair"]) {
				pdGeoCheckpoint("bridge geo repair");
			} else if ([what isEqualToString:@"keyboard"]) {
				// A real keyboard, raised from the topmost presented page: what
				// the Files picker's search field does to every window in the
				// app, SDL's included (D-077). `geo keyboard` shows it for 3 s.
				UIWindow *top = nil;
				for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
					if (![sc isKindOfClass:UIWindowScene.class]) {
						continue;
					}
					for (UIWindow *w in ((UIWindowScene *)sc).windows) {
						if (!w.hidden && w.isKeyWindow) {
							top = w;
						}
					}
				}
				UIViewController *vc = top.rootViewController;
				while (vc.presentedViewController) {
					vc = vc.presentedViewController;
				}
				UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 10, 10)];
				tf.alpha = 0.02;
				[vc.view addSubview:tf];
				const BOOL ok = [tf becomeFirstResponder];
				PDLifecycle("bridge: keyboard test field first responder=%d in %s", ok,
					NSStringFromClass(vc.class).UTF8String);
				dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
					[tf resignFirstResponder];
					[tf removeFromSuperview];
				});
			} else if ([what isEqualToString:@"device"] && arg.length) {
				// The PHYSICAL orientation, as UIKit's autorotation reads it.
				// A simulator boots physically portrait and simctl cannot turn
				// it; a phone in a player's hands is physically landscape. The
				// difference matters to a window UIKit believes is portrait
				// (D-076/D-077), so a script needs to be able to set it.
				// 1 portrait, 3 landscape-left (home right), 4 landscape-right.
				const long o = arg.integerValue;
				[UIDevice.currentDevice setValue:@(o) forKey:@"orientation"];
				[UIViewController attemptRotationToDeviceOrientation];
				PDLifecycle("bridge: UIDevice orientation set to %ld", o);
			}
			out = [NSString stringWithFormat:@"geo_repair_enabled=%d\n%@", pdGeoRepairEnabled, pdGeoReport()];
			dispatch_semaphore_signal(done);
		});
		if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)))) {
			return pdErr(@"UIKit did not respond (is the game loop running?)");
		}
		return out;
	}

	// `presented` — every window of every scene and the controllers presented
	// in it, with the orientations each one supports. `picker cancel` /
	// `picker pick <path>` finish the REAL document picker the way a finger
	// does (dismiss, then the delegate hears); `picker dismiss` dismisses
	// whatever is on top (an alert: as if OK was pressed). D-077.
	if ([cmd isEqualToString:@"presented"] || [cmd isEqualToString:@"picker"]) {
		NSString *what = argv.count > 1 ? argv[1].lowercaseString : @"";
		NSString *path = nil;
		if ([what isEqualToString:@"pick"] && argv.count > 2) {
			path = [[argv subarrayWithRange:NSMakeRange(2, argv.count - 2)] componentsJoinedByString:@" "];
			if (![path hasPrefix:@"/"]) {
				path = [NSHomeDirectory() stringByAppendingPathComponent:path];
			}
		}
		__block NSString *out = nil;
		dispatch_semaphore_t done = dispatch_semaphore_create(0);
		dispatch_async(dispatch_get_main_queue(), ^{
			if ([cmd isEqualToString:@"presented"] || what.length == 0) {
				out = pdGeoPresentedReport();
			} else if ([what isEqualToString:@"cancel"] || [what isEqualToString:@"dismiss"]) {
				out = pdGeoPickerFinish(nil);
			} else if (path) {
				out = pdGeoPickerFinish(path);
			} else {
				out = @"ERR usage: picker [cancel|dismiss|pick <path>]";
			}
			dispatch_semaphore_signal(done);
		});
		if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)))) {
			return pdErr(@"UIKit did not respond (is the game loop running?)");
		}
		return out;
	}

	// `dump` — write Documents/hang.txt now, from this socket thread.
	if ([cmd isEqualToString:@"dump"]) {
		const int n = PDWatchdogDumpNow("bridge dump");
		return [NSString stringWithFormat:@"hang_dump_threads=%d", n];
	}

	// `graft off|on` — D-038's re-graft, live. Off only bites once the overlay
	// exists, so it can never brick a launch (PDSceneDelegate.h).
	if ([cmd isEqualToString:@"graft"]) {
		if (argv.count > 1) {
			pdGraftEnabled = [argv[1].lowercaseString isEqualToString:@"on"] ? 1 : 0;
			PDLifecycle("bridge: graft %s", pdGraftEnabled ? "ON" : "OFF");
		}
		return [NSString stringWithFormat:@"graft_enabled=%d", pdGraftEnabled];
	}

	// `hide60 on|off` — the shipping fallback, live, so both sides can be tried
	// in one session on the phone. `on` takes the 60 segment off the Frame rate
	// row on a 120 Hz panel.
	if ([cmd isEqualToString:@"hide60"]) {
		if (argv.count > 1) {
			[NSUserDefaults.standardUserDefaults setBool:[argv[1].lowercaseString isEqualToString:@"on"]
			                                      forKey:PDDefHide60On120];
			[PDSettingsViewController rebuildRows];
		}
		return [NSString stringWithFormat:@"hide60on120=%d", (int)PDDefBool(PDDefHide60On120)];
	}

	if ([cmd isEqualToString:@"windows"]) {
		__block NSString *out = nil;
		dispatch_semaphore_t done = dispatch_semaphore_create(0);
		dispatch_async(dispatch_get_main_queue(), ^{
			out = [PDTouchOverlay windowsReport];
			dispatch_semaphore_signal(done);
		});
		if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)))) {
			return pdErr(@"UIKit did not respond (is the game loop running?)");
		}
		return out;
	}

	// `touch latch on|off` (D-086): the zero-frame tap latch, switchable so the
	// bug and the fix can be shown on one build with `tap X Y 0`.
	if ([cmd isEqualToString:@"touch"] && argv.count > 2
			&& [argv[1].lowercaseString isEqualToString:@"latch"]) {
		const BOOL on = [argv[2].lowercaseString isEqualToString:@"on"];
		[PDTouchOverlay setTapLatchEnabled:on];   // a BOOL read once a frame
		return [NSString stringWithFormat:@"touch_latch=%d", (int)PDTouchOverlay.tapLatchEnabled];
	}

	if ([cmd isEqualToString:@"touch"] && argv.count > 1
			&& [argv[1].lowercaseString isEqualToString:@"watchdogtest"]) {
		__block NSString *out = nil;
		dispatch_semaphore_t done = dispatch_semaphore_create(0);
		dispatch_async(dispatch_get_main_queue(), ^{
			PDTouchOverlay *v = PDTouchOverlay.current;
			[v noteWatchdog:@"SELFTEST(phase=selftest) "];
			out = v ? @"watchdog=wrote a line to Documents/touch-watchdog.txt" : @"MISS no-overlay";
			dispatch_semaphore_signal(done);
		});
		dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)));
		return out ?: @"watchdog=?";
	}

	if ([cmd isEqualToString:@"touch"]) {
		// The simulator reports a virtual "Gamepad", so in auto mode the layer
		// hides itself exactly where scripts/sim-validate.sh wants to press it.
		// This is the same setting the settings page writes, not a back door.
		static NSDictionary<NSString *, NSNumber *> *modes;
		static dispatch_once_t onceT;
		dispatch_once(&onceT, ^{ modes = @{ @"auto": @0, @"on": @1, @"always": @1, @"off": @2 }; });
		NSNumber *mode = argv.count > 1 ? modes[argv[1].lowercaseString] : nil;
		if (!mode) {
			return pdErr(@"usage: touch <auto|on|off>");
		}
		[NSUserDefaults.standardUserDefaults setInteger:mode.integerValue forKey:PDDefTouchMode];
		dispatch_semaphore_t done = dispatch_semaphore_create(0);
		dispatch_async(dispatch_get_main_queue(), ^{
			[PDTouchOverlay.current applySettings];
			dispatch_semaphore_signal(done);
		});
		dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)));
		return [NSString stringWithFormat:@"touch mode=%@ overlay=%@", argv[1],
			PDTouchOverlay.current.hidden ? @"hidden" : @"visible"];
	}

	// The layout editor, from a script. Injected events bypass UIKit, so the
	// only way a validation run can open it is the same way the settings row
	// does - by asking the overlay. `drag` then moves a chip (the overlay's
	// inject path has an edit-mode arm).
	if ([cmd isEqualToString:@"layout"]) {
		NSString *what = argv.count > 1 ? argv[1].lowercaseString : @"";
		__block NSString *out = nil;
		dispatch_semaphore_t done = dispatch_semaphore_create(0);
		dispatch_async(dispatch_get_main_queue(), ^{
			PDTouchOverlay *v = PDTouchOverlay.current;
			if (!v) {
				out = @"no overlay";
			} else if ([what isEqualToString:@"edit"]) {
				[PDSettingsViewController dismiss];
				[v beginLayoutEditing];
				out = @"layout editing";
			} else if ([what isEqualToString:@"done"]) {
				[v endLayoutEditing];
				out = @"layout done";
			} else if ([what isEqualToString:@"reset"]) {
				[v resetLayout];
				out = @"layout reset";
			} else {
				out = @"usage: layout <edit|done|reset>";
			}
			dispatch_semaphore_signal(done);
		});
		dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)));
		NSDictionary *stored = [NSUserDefaults.standardUserDefaults dictionaryForKey:PDDefButtonLayout];
		NSMutableArray<NSString *> *hidden = [NSMutableArray array];
		for (NSString *k in stored) {
			id e = stored[k];
			if ([e isKindOfClass:NSDictionary.class] && [((NSDictionary *)e)[@"hidden"] boolValue]) {
				[hidden addObject:k];
			}
		}
		[hidden sortUsingSelector:@selector(compare:)];
		return [NSString stringWithFormat:@"%@\nlayout_entries=%lu\nlayout=%@\nlayout_hidden=%@",
			out ?: @"timed out", (unsigned long)stored.count,
			stored.count ? [stored.allKeys componentsJoinedByString:@","] : @"-",
			hidden.count ? [hidden componentsJoinedByString:@","] : @"-"];
	}

	// The frame breakdown (app/gfx/pd_frame_prof.c, overlay 0026/0027). Nothing
	// outside the app can profile a sideloaded build on this hardware, so this
	// is the profiler: p50/p95/max in milliseconds over the last 512 engine
	// frames, per section. `prof reset` zeroes the rings so a window measures
	// one thing - set the rate, play for ten seconds, read.
	if ([cmd isEqualToString:@"prof"]) {
		if (argv.count > 1 && [argv[1].lowercaseString isEqualToString:@"reset"]) {
			__block BOOL done = NO;
			if (shell.engineRunning) {
				if (![shell enqueueAndWait:^{ pdProfReset(); done = YES; } timeout:kEngineTimeout]) {
					return pdErr(@"engine did not reach a frame boundary in %.0fs", kEngineTimeout);
				}
			} else {
				pdProfReset();
				done = YES;
			}
			return done ? @"prof_reset=1" : pdErr(@"prof reset did not run");
		}
		// Read on the game thread so every row comes from one frame's rings.
		__block NSString *out = nil;
		// A pointer, not an array: a block cannot capture one.
		char *buf = (char *)calloc(1, 2048);
		if (!buf) {
			return pdErr(@"out of memory");
		}
		void (^report)(void) = ^{
			buf[0] = 0;
			pdProfReport(buf, 2048);
			out = [NSString stringWithUTF8String:buf];
		};
		if (shell.engineRunning) {
			if (![shell enqueueAndWait:report timeout:kEngineTimeout]) {
				free(buf);
				return pdErr(@"engine did not reach a frame boundary in %.0fs", kEngineTimeout);
			}
		} else {
			report();
		}
		free(buf);
		return out ?: pdErr(@"no profile");
	}

	// Upstream's own per-frame renderer counters (gfx_api.h). Draw calls and
	// texture uploads are what say whether a slow frame is geometry, state
	// changes, or the texture cache thrashing.
	if ([cmd isEqualToString:@"gfx"]) {
		__block struct GfxTraceStats st;
		memset(&st, 0, sizeof(st));
		if (shell.engineRunning) {
			if (![shell enqueueAndWait:^{ gfx_trace_stats(&st); } timeout:kEngineTimeout]) {
				return pdErr(@"engine did not reach a frame boundary in %.0fs", kEngineTimeout);
			}
		} else {
			gfx_trace_stats(&st);
		}
		return [NSString stringWithFormat:
			@"gfx_drawcalls=%u\ngfx_tris=%u\ngfx_verts=%u\ngfx_distincttextures=%u\n"
			 "gfx_texuploads=%u\ngfx_texevictions=%u\ngfx_bufferfullflushes=%u\n"
			 "gfx_cacheentries=%u\ngfx_cachesize=%u\n",
			st.drawcalls, st.tris, st.verts, st.distincttextures,
			st.texuploads, st.texevictions, st.bufferfullflushes,
			st.cacheentries, st.cachesize];
	}

	// The render-scale row, from a script. It only takes effect at launch (the
	// drawable's size is fixed when the renderer comes up), so this writes the
	// default and says so; the caller relaunches and reads `state`.
	if ([cmd isEqualToString:@"render"]) {
		if (argv.count < 2) {
			return pdErr(@"usage: render <100|75|50>");
		}
		const NSInteger pct = argv[1].integerValue;
		if (pct < 25 || pct > 200) {
			return pdErr(@"render scale out of range: %ld", (long)pct);
		}
		[NSUserDefaults.standardUserDefaults setInteger:pct forKey:PDDefRenderScalePct];
		[NSUserDefaults.standardUserDefaults synchronize];
		return [NSString stringWithFormat:@"render_scale_pct=%ld (takes effect on the next launch)",
			(long)pct];
	}

	// The audio rows, from a script: the same defaults the settings page writes,
	// then the same push. Injected events cannot move a UISlider, and the
	// alternative - writing the preferences plist from outside - is served from
	// cfprefsd's cache and does not always reach the process.
	//
	// The three eeprom values ("Sound", "Music", "Sound Mode") are NOT here any
	// more: they are the game's, in its own Audio Options page (D-033). What is
	// here is the shell's master gain and the other-app policy.
	if ([cmd isEqualToString:@"audio"]) {
		if (argv.count == 1) {
			return [PDAudio stateLines];
		}
		NSString *which = argv[1].lowercaseString;
		if ([which isEqualToString:@"trace"]) {
			// `audio trace on|off|dump [name]` — the per-push ring in overlay
			// 0023 (D-078): queue level, ratio, integrator and what happened,
			// one CSV row per push, written to Documents/<name>.
			NSString *sub = argv.count > 2 ? argv[2].lowercaseString : @"";
			if ([sub isEqualToString:@"on"]) {
				g_PdAudioTraceCount = 0;
				g_PdAudioTraceOn = 1;
				return @"audio_trace=on";
			}
			if ([sub isEqualToString:@"off"]) {
				g_PdAudioTraceOn = 0;
				return @"audio_trace=off";
			}
			if ([sub isEqualToString:@"dump"]) {
				NSString *name = argv.count > 3 ? argv[3] : @"audio-trace.csv";
				NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
				NSString *dst = [docs stringByAppendingPathComponent:name.lastPathComponent];
				const unsigned n = g_PdAudioTraceCount;
				const unsigned len = PD_AUDIO_TRACE_LEN;
				const unsigned first = n > len ? n - len : 0;
				NSMutableString *csv = [NSMutableString stringWithString:@"push,us,queued,out,rate_milli,integ_e6,flags\n"];
				for (unsigned i = first; i < n; i++) {
					const struct pdaudiotrace *t = &g_PdAudioTrace[i % len];
					[csv appendFormat:@"%u,%llu,%d,%d,%d,%d,%d\n", i, (unsigned long long)t->us,
						t->queued, t->outSamples, t->rateMilli, t->integ, t->flags];
				}
				[csv writeToFile:dst atomically:YES encoding:NSUTF8StringEncoding error:NULL];
				return [NSString stringWithFormat:@"audio_trace_rows=%u file=%@", n - first, dst];
			}
			return pdErr(@"usage: audio trace on|off|dump [name]");
		}
		if ([which isEqualToString:@"interrupt"]) {
			// `audio interrupt begin|end` - posts the session's interruption
			// notification as the system would (overlay 0048's test): `begin`
			// makes SDL pause its AudioQueue the way a call or Siri does, and
			// leaving out `end` is the lost-end case the shell's stalled-device
			// watch exists for.
			NSString *sub = argv.count > 2 ? argv[2].lowercaseString : @"";
			if (![sub isEqualToString:@"begin"] && ![sub isEqualToString:@"end"]) {
				return pdErr(@"usage: audio interrupt begin|end");
			}
			const AVAudioSessionInterruptionType t = [sub isEqualToString:@"begin"]
				? AVAudioSessionInterruptionTypeBegan : AVAudioSessionInterruptionTypeEnded;
			[NSNotificationCenter.defaultCenter postNotificationName:AVAudioSessionInterruptionNotification
				object:AVAudioSession.sharedInstance userInfo:@{ AVAudioSessionInterruptionTypeKey : @(t) }];
			return [NSString stringWithFormat:@"audio_interrupt=%@", sub];
		}
		if ([which isEqualToString:@"reset"]) {
			// The queue counters are cumulative and a session that included a
			// stage load has a min of zero for ever. Zero them, play, read.
			[PDAudio statsReset];
			return [PDAudio stateLines];
		}
		if (argv.count < 3) {
			return pdErr(@"usage: audio [volume 0-100 | mute on|off | mode 0-4 | reset]");
		}
		if ([which isEqualToString:@"volume"]) {
			double pct = argv[2].doubleValue;
			if (pct < 0 || pct > 100) {
				return pdErr(@"volume out of range: %@", argv[2]);
			}
			[NSUserDefaults.standardUserDefaults setFloat:(float)(pct / 100.0)
			                                       forKey:PDDefAudioMasterVolume];
		} else if ([which isEqualToString:@"mute"]) {
			[NSUserDefaults.standardUserDefaults setBool:[argv[2].lowercaseString isEqualToString:@"on"]
			                                      forKey:PDDefAudioMute];
		} else if ([which isEqualToString:@"mode"]) {
			NSInteger m = argv[2].integerValue;
			if (m < 0 || m > 4) {
				return pdErr(@"mode out of range: %@ (0-4)", argv[2]);
			}
			[NSUserDefaults.standardUserDefaults setInteger:m forKey:PDDefAudioSessionMode];
		} else {
			return pdErr(@"usage: audio [volume 0-100 | mute on|off | mode 0-4]");
		}
		[NSUserDefaults.standardUserDefaults synchronize];
		[PDAudio settingsChanged];
		// The session work is asynchronous on PDAudio's own queue on purpose
		// (it must never land on the game thread); give it a moment so the
		// state a script reads next is the state it just asked for.
		usleep(250 * 1000);
		[PDSettingsViewController reloadRows];
		return [PDAudio stateLines];
	}

	// A game-file load, on demand. Loading one rewrites all three of the game's
	// own audio values from the eeprom (gamefile.c) - which is the game's
	// business now (D-033) - and, more usefully for a script, it is the only
	// way to make a slot load happen at a frame of its choosing rather than
	// only at boot. `defaults` is the new-campaign path; `load <device>` is the
	// real slot load and returns the engine's own error number.
	if ([cmd isEqualToString:@"gamefile"]) {
		NSString *what = argv.count > 1 ? argv[1].lowercaseString : @"";
		// SAVEDEVICE_GAMEPAK (constants.h:3907) is the eeprom — the only save
		// device this port has; 0-3 are the N64's controller paks.
		const int device = argv.count > 2 ? argv[2].intValue : 4;
		__block NSString *out = nil;
		if ([what isEqualToString:@"defaults"]) {
			if (![shell enqueueAndWait:^{
				gamefileLoadDefaults(&g_GameFile);
				out = [NSString stringWithFormat:@"gamefile defaults loaded; sfx_volume=%u music_volume=%u sound_mode=%d",
					(unsigned)g_SfxVolume, (unsigned)optionsGetMusicVolume(), g_SoundMode];
			} timeout:kEngineTimeout]) {
				return pdErr(@"engine did not reach a frame boundary in %.0fs", kEngineTimeout);
			}
			return out;
		}
		if ([what isEqualToString:@"save"]) {
			// So a validation run has a file to load: writing one is what sets
			// g_GameFileGuid.fileid, and without that gamefileLoad() reads
			// nothing and returns -1.
			__block int ret = -1;
			if (![shell enqueueAndWait:^{
				ret = gamefileSave(device, 0, 0);
				out = [NSString stringWithFormat:@"gamefile save device=%d ret=%d", device, ret];
			} timeout:kEngineTimeout]) {
				return pdErr(@"engine did not reach a frame boundary in %.0fs", kEngineTimeout);
			}
			return out;
		}
		if ([what isEqualToString:@"load"]) {
			__block int ret = -1;
			if (![shell enqueueAndWait:^{
				ret = gamefileLoad(device);
				out = [NSString stringWithFormat:@"gamefile load device=%d ret=%d; sfx_volume=%u music_volume=%u sound_mode=%d",
					device, ret, (unsigned)g_SfxVolume, (unsigned)optionsGetMusicVolume(), g_SoundMode];
			} timeout:kEngineTimeout]) {
				return pdErr(@"engine did not reach a frame boundary in %.0fs", kEngineTimeout);
			}
			return out;
		}
		return pdErr(@"usage: gamefile defaults | gamefile save [device] | gamefile load [device]");
	}

	// `settings seg <section> <row> <segment>` - the Frame rate row, and every
	// other segmented one, through the control's own handler. `settings row`
	// cannot: a segmented row's action lives on the UISegmentedControl, not on
	// the table row, so pressing the row does nothing at all (D-041 round 2).
	if ([cmd isEqualToString:@"settings"] && argv.count >= 5
			&& [argv[1].lowercaseString isEqualToString:@"seg"]) {
		__block NSString *what = nil;
		dispatch_semaphore_t done = dispatch_semaphore_create(0);
		dispatch_async(dispatch_get_main_queue(), ^{
			what = [PDSettingsViewController setSegmentInSection:argv[2]
				atIndex:argv[3].integerValue to:argv[4].integerValue];
			dispatch_semaphore_signal(done);
		});
		dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)));
		return what ? [NSString stringWithFormat:@"set %@", what]
		            : pdErr(@"no such segmented row (is the page up?)");
	}

	if ([cmd isEqualToString:@"settings"] && argv.count >= 4
			&& [argv[1].lowercaseString isEqualToString:@"row"]) {
		__block NSString *what = nil;
		dispatch_semaphore_t done = dispatch_semaphore_create(0);
		dispatch_async(dispatch_get_main_queue(), ^{
			what = [PDSettingsViewController pressRowInSection:argv[2] atIndex:argv[3].integerValue];
			dispatch_semaphore_signal(done);
		});
		dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)));
		return what ? [NSString stringWithFormat:@"pressed %@", what]
		            : pdErr(@"no such row (is the page up?)");
	}

	if ([cmd isEqualToString:@"settings"]) {
		if (argv.count > 1 && [argv[1].lowercaseString isEqualToString:@"close"]) {
			[PDSettingsViewController dismiss];
			return @"settings closed";
		}
		[PDSettingsViewController present];
		if (argv.count > 1) {
			// `settings xbla` scrolls to the Xbox 360 section, so a screenshot
			// of the rows under test is one command rather than a finger.
			[PDSettingsViewController scrollToSectionContaining:argv[1]];
			return [NSString stringWithFormat:@"settings open at %@", argv[1]];
		}
		return @"settings open";
	}

#if TARGET_OS_VISION
	// The 3D mode (Phase 6). `on`/`off` is what the ornament's button does — the
	// ornament needs a gaze-pinch and simctl cannot inject one, so this is the
	// only way a scripted gate can enter 3D. Hops to the main thread because
	// that is where the transition sequencing has to run (and it gets there: the
	// pacer's wait runs the main run loop, D-045, so the main QUEUE drains while
	// the engine holds the main THREAD).
	if ([cmd isEqualToString:@"3d"]) {
		NSString *what = argv.count > 1 ? argv[1].lowercaseString : @"state";
		if ([what isEqualToString:@"on"] || [what isEqualToString:@"off"]) {
			const BOOL on = [what isEqualToString:@"on"];
			dispatch_async(dispatch_get_main_queue(), ^{ pdVision3dSetMode(on); });
			// Not "it is on": it is REQUESTED. The space takes a moment to open
			// and `3d state` is how the gate learns it did.
			return [NSString stringWithFormat:@"3d %@ requested", what];
		}
		if ([what isEqualToString:@"state"]) {
			return pdVision3dStateLines();
		}
		// Re-place the world-locked panel in front of where the player is
		// looking now. A flag the compositor thread picks up, so it is safe
		// from here.
		if ([what isEqualToString:@"recenter"]) {
			pdVisionRecenter();
			return @"3d recenter requested";
		}
		// Stereo Depth as a percentage of the default 63 mm separation. 0 is
		// the gate's own instrument: both eyes become the mono projection, so
		// an L/R pair must come out pixel-identical.
		if ([what isEqualToString:@"depth"]) {
			if (argv.count < 3) {
				return [NSString stringWithFormat:@"stereo_depth_pct=%.0f",
					(double)pdVisionStereoDepthPct()];
			}
			pdVisionStereoSetDepthPct(argv[2].floatValue);
			return [NSString stringWithFormat:@"stereo_depth_pct=%.0f",
				(double)pdVisionStereoDepthPct()];
		}
		// The park is normally the space-open timer's (plan §2.9). These two
		// rows exist so the gate can drive the geometry cycle on its own and
		// read the result, and so a park that the SYSTEM refused is visible as
		// a refusal rather than as "the card did not shrink".
		if ([what isEqualToString:@"park"] || [what isEqualToString:@"unpark"]) {
			const int park = [what isEqualToString:@"park"];
			pdVision3dParkRequest(park);
			return [NSString stringWithFormat:@"3d %@ requested", what];
		}
		// Which eye the mono simulator samples and a screenshot keeps, at
		// RUNTIME. `PD_VP3D_SHOWEYE` does the same thing per launch, which is
		// what the seeded replays use; this row is for the one measurement a
		// replay cannot make — PD's pause dialog will not open in a
		// --fixed-step run, and while it IS open the game is frozen, so two
		// screenshots from one live session are comparable frame-for-frame.
		if ([what isEqualToString:@"showeye"]) {
			NSString *e = argv.count > 2 ? argv[2].lowercaseString : @"";
			int want = -2;
			if ([e hasPrefix:@"l"] || [e isEqualToString:@"0"])      { want = PD_EYE_LEFT; }
			else if ([e hasPrefix:@"r"] || [e isEqualToString:@"1"]) { want = PD_EYE_RIGHT; }
			else if ([e hasPrefix:@"a"])                             { want = -2; }
			else { return pdErr(@"usage: 3d showeye <L|R|auto>"); }
			pdVisionEyeSetShowEye(want);
			return [NSString stringWithFormat:@"show_eye=%d", pdVisionEyeShowEye()];
		}
		// A SYSTEM dismissal, as far as the shell can tell: the Crown, or the
		// player closing the space from outside the app. It cannot be injected
		// on a simulator (there is no Crown and no way to invalidate the layer
		// from here), so this row drives the same two calls the loop makes on
		// its `invalidated` path — stop, then reconcile — which is where the
		// immediate pd.ini + eeprom write lives. Dev instrument, like
		// `pad fake`: nothing in the app ever sends it.
		if ([what isEqualToString:@"crown"]) {
			if (!pdVision3dActive()) {
				return pdErr(@"3d crown: not in 3D");
			}
			pdVision3dImmStop = 1;
			pdVision3dImmersiveEnded();
			return @"3d crown simulated (loop stopping, reconcile queued)";
		}
		// THE SETTINGS SHEET (M6). `open`/`close` drive the SwiftUI sheet the
		// ornament's gear opens — the simulator can inject no gaze-pinch, so
		// this is the only scripted way in, exactly as `3d on` is for the
		// space. `set <row> <value>` writes the row's NSUserDefaults key and
		// pushes it live; `get` prints every row; `press <name>` presses a
		// button row (Recenter) on the open sheet.
		if ([what isEqualToString:@"settings"]) {
			NSString *sub = argv.count > 2 ? argv[2].lowercaseString : @"get";
			if ([sub isEqualToString:@"open"] || [sub isEqualToString:@"close"]) {
				const int open = [sub isEqualToString:@"open"];
				pdVision3dSettingsSheetRequest(open);
				// REQUESTED, not done: SwiftUI presents on its own turn of the
				// run loop, and `3d state`'s `sheet_open` row — set by the
				// sheet's own .onAppear — is how the gate learns it landed.
				return [NSString stringWithFormat:@"3d settings %@ requested", sub];
			}
			if ([sub isEqualToString:@"get"]) {
				return pdVision3dSettingsStateLines();
			}
			if ([sub isEqualToString:@"reset"]) {
				pdVision3dSettingsResetDefaults();
				return pdVision3dSettingsStateLines();
			}
			if ([sub isEqualToString:@"set"]) {
				if (argv.count < 5) {
					return pdErr(@"usage: 3d settings set <dist|width|height|posh|depth"
					              "|conv|dim|render|units|fps> <value>");
				}
				NSString *took = pdVision3dSettingsSet(argv[3], argv[4]);
				return took ?: pdErr([NSString stringWithFormat:@"no 3d settings row \"%@\"", argv[3]]);
			}
			if ([sub isEqualToString:@"press"]) {
				if (argv.count < 4) {
					return pdErr(@"usage: 3d settings press <recenter>");
				}
				// UIKit, so it runs on the main thread and this thread waits —
				// the shape every other `settings` command here uses.
				NSString *name = argv[3];
				__block int ok = -1;
				dispatch_semaphore_t done = dispatch_semaphore_create(0);
				dispatch_async(dispatch_get_main_queue(), ^{
					PDVisionSettingsViewController *vc = PDVisionSettingsViewController.current;
					ok = vc ? ([vc pressRowNamed:name] ? 1 : 0) : -1;
					dispatch_semaphore_signal(done);
				});
				dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW,
					(int64_t)(5 * NSEC_PER_SEC)));
				if (ok < 0) {
					return pdErr(@"3d settings press: the sheet is not open");
				}
				return ok ? [NSString stringWithFormat:@"pressed %@", name]
				          : pdErr([NSString stringWithFormat:@"no button row \"%@\"", name]);
			}
			// D-082: the sheet is the whole settings page now, taller than any
			// viewport, and the simulator cannot scroll it by hand. `scroll 3d 4`
			// puts row 4 of the 3D section at the top (its header floating over
			// it); `scroll display` an iOS section. `seg units 0` moves a 3D
			// segmented row through its own control.
			if ([sub isEqualToString:@"scroll"] || [sub isEqualToString:@"seg"]) {
				if (argv.count < 4 || ([sub isEqualToString:@"seg"] && argv.count < 5)) {
					return pdErr(@"usage: 3d settings scroll <section> [row] | 3d settings seg <row> <index>");
				}
				const BOOL scroll = [sub isEqualToString:@"scroll"];
				NSString *a3 = argv[3];
				const NSInteger n = argv.count > 4 ? argv[4].integerValue : 0;
				__block NSString *out = nil;
				dispatch_semaphore_t done = dispatch_semaphore_create(0);
				dispatch_async(dispatch_get_main_queue(), ^{
					PDVisionSettingsViewController *vc = PDVisionSettingsViewController.current;
					if (vc && pdVision3dSettingsSheetUp()) {
						if (scroll) {
							[vc scrollToSection:a3 row:n];
							out = [NSString stringWithFormat:@"scrolled to %@ row %ld", a3, (long)n];
						} else {
							out = [vc.rows3d setSegmentNamed:a3 to:n];
							out = out ? [NSString stringWithFormat:@"set %@", out] : nil;
						}
					}
					dispatch_semaphore_signal(done);
				});
				dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW,
					(int64_t)(5 * NSEC_PER_SEC)));
				return out ?: pdErr(@"3d settings %@: the sheet is not open, or no such row", sub);
			}
			return pdErr(@"usage: 3d settings <open|close|get|set <row> <value>|press <row>|reset"
			              "|scroll <section> [row]|seg <row> <index>>");
		}
		// The ONE A/B round the plan allows on the gun's convergence (§2.4),
		// and then this row goes. 0 restores C_gun = znear.
		if ([what isEqualToString:@"gunconv"]) {
			if (argv.count < 3) {
				return pdErr(@"usage: 3d gunconv <units|0>");
			}
			pdVisionStereoSetGunConvergence(argv[2].floatValue);
			return @"3d gunconv set";
		}
		return pdErr(@"usage: 3d <on|off|park|unpark|crown|showeye|state|recenter"
		              "|depth <pct>|gunconv <units>|settings ...>");
	}
#endif

	if ([cmd isEqualToString:@"crash"]) {
		// Deliberately crashes the app, to prove the handler writes a usable
		// Documents/crash.txt (upstream installs no signal handler at all on
		// Apple, crash.c:324, so ours is the only one). Dev builds only - this
		// whole file is compiled out when PD_PUBLIC is set - and it takes the
		// same route a real fault does, on the game thread at a frame boundary.
		if (argv.count < 2 || ![argv[1] isEqualToString:@"yes-really"]) {
			return pdErr(@"usage: crash yes-really  (deliberately faults the app)");
		}
		[shell enqueue:^{
			NSLog(@"perfectdark: [bridge] deliberate crash requested");
			volatile int *p = (int *)(uintptr_t)0xDEAD0000;
			*p = 1;
		}];
		return @"crashing";
	}

	if ([cmd isEqualToString:@"quit"]) {
		// exit(0) runs atexit(cleanup), which is what writes pd.ini
		// (main.c:124) - so this is also the only clean way to end a scripted
		// run with its settings saved.
		[shell enqueue:^{
			inputSaveBinds();
			configSave("$S/pd.ini");
			NSLog(@"perfectdark: [bridge] quit");
			exit(0);
		}];
		return nil;
	}

	return pdErr(@"unknown command %@ (try help)", cmd);
}

@end

#endif // !PD_PUBLIC
