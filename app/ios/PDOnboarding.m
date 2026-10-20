// PDOnboarding.m — the first screen, and the ROM classifier.
//
// Perfect Dark ships with no game data and never will (charter, Legal posture).
// The player supplies `Perfect Dark (USA) (Rev 1)` themselves, and the whole
// job of this file is to make the ten seconds in which that goes wrong
// intelligible: WHERE the file goes, in the words the Files app itself uses,
// and WHY the file they picked is not the right one - PAL, Japanese, v1.0 and
// a byte-swapped .v64 all look identical to somebody holding a ROM they
// downloaded years ago.
//
// It runs BEFORE the engine. romdataLoadRom() answers a wrong ROM with
// sysFatalError() (romdata.c:204-238), which on iOS is a dead end: an
// SDL_ShowMessageBox the player can only dismiss into a closed app. So the
// check happens here first and the engine is never started without a ROM it
// will accept.
#import "PDOnboarding.h"
#import "PDVision.h"
#import "PDShell.h"
#import "PDXbla.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <CommonCrypto/CommonDigest.h>

// The one hash we can stand behind: charter §What this is, verified against
// the user's own copy. The other three variants are NOT identified by hash here -
// we have no verified md5 for them, and a wrong constant would tell a player
// their good ROM is a bad one. They are identified by the cartridge header
// instead, which is what upstream checks too (romdata.c:29-46).
static NSString *const kNtscFinalMD5 = @"e03b088b6ac9e0080440efed07c1e40f";
static const unsigned long long kRomSize = 33554432ULL;   // ROMDATA_ROM_SIZE
static NSString *const kRomFileName = @"pd.ntsc-final.z64";

@implementation PDRomCheck
- (BOOL)ok { return self.verdict == PDRomAccepted; }
@end

@interface PDOnboardingViewController : UIViewController <UIDocumentPickerDelegate>
@property (nonatomic, copy) void (^onAccepted)(void);
/** Re-read Documents/added-content (and the legacy xbla/) and say what is in it. Main thread. */
- (void)refreshXbla;
@end

// ---------------------------------------------------------------------------

@implementation PDOnboarding

+ (NSString *)md5OfFileAtPath:(NSString *)path
{
	NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
	if (!fh) {
		return nil;
	}
	CC_MD5_CTX ctx;
	CC_MD5_Init(&ctx);
	while (1) {
		@autoreleasepool {
			NSData *chunk = [fh readDataOfLength:4 * 1024 * 1024];
			if (!chunk.length) {
				break;
			}
			CC_MD5_Update(&ctx, chunk.bytes, (CC_LONG)chunk.length);
		}
	}
	[fh closeFile];
	unsigned char digest[CC_MD5_DIGEST_LENGTH];
	CC_MD5_Final(digest, &ctx);
	NSMutableString *hex = [NSMutableString stringWithCapacity:32];
	for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) {
		[hex appendFormat:@"%02x", digest[i]];
	}
	return hex;
}

+ (PDRomCheck *)classifyFileAtPath:(NSString *)path
{
	PDRomCheck *c = [PDRomCheck new];

	NSError *err = nil;
	NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:&err];
	if (!attrs) {
		c.verdict = PDRomUnreadable;
		c.explanation = [NSString stringWithFormat:@"Could not read the file (%@).", err.localizedDescription];
		return c;
	}

	unsigned long long size = attrs.fileSize;
	NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
	NSData *head = [fh readDataOfLength:0x40];
	[fh closeFile];

	if (head.length < 0x40) {
		c.verdict = PDRomNotARom;
		c.explanation = @"That file is far too small to be an N64 ROM.";
		return c;
	}

	const unsigned char *h = head.bytes;

	// Byte order. A .z64 begins 80 37 12 40; .v64 is byte-swapped in pairs and
	// .n64 is word-swapped. Both are common and neither will ever load.
	if (!(h[0] == 0x80 && h[1] == 0x37 && h[2] == 0x12 && h[3] == 0x40)) {
		if ((h[0] == 0x37 && h[1] == 0x80) || (h[0] == 0x40 && h[1] == 0x12)) {
			c.verdict = PDRomByteSwapped;
			c.explanation = @"This ROM is in .v64 or .n64 byte order. Perfect Dark needs the "
			                 "big-endian .z64 form — convert it (any N64 ROM tool will) and try again.";
			return c;
		}
		c.verdict = PDRomNotARom;
		c.explanation = @"That is not an N64 ROM: it has no N64 cartridge header.";
		return c;
	}

	// GoldenEye 007 is the one other N64 ROM this app has a use for (GE Plus),
	// and the one a player is most likely to pick here by mistake.
	if (!memcmp(h + 0x20, "GOLDENEYE", 9)) {
		c.verdict = PDRomNotARom;
		c.explanation = @"That is GoldenEye 007, not Perfect Dark. GoldenEye is an optional extra "
		                 "for GE Plus and goes in the added-content folder — but Perfect Dark's own "
		                 "ROM is needed first.";
		return c;
	}
	// And the GoldenEye ROM hack the converter knows (Goldfinger 64, 24 MB).
	if (head.length >= 0x40 && geconvertHeaderVariantName(h, 0x40)) {
		c.verdict = PDRomNotARom;
		c.explanation = [NSString stringWithFormat:@"That is %s, a GoldenEye ROM hack, not Perfect Dark. "
		                 "It is an optional extra beside GE Plus and goes in the added-content folder — "
		                 "but Perfect Dark's own ROM is needed first.", geconvertHeaderVariantName(h, 0x40)];
		return c;
	}

	if (size != kRomSize) {
		c.verdict = PDRomWrongSize;
		c.explanation = [NSString stringWithFormat:
			@"An unmodified Perfect Dark ROM is exactly 32 MB (%llu bytes); this one is %llu. "
			 "If it came out of a zip or a rar, make sure the file itself was extracted.",
			kRomSize, size];
		return c;
	}

	char id4[5] = { (char)h[0x3b], (char)h[0x3c], (char)h[0x3d], (char)h[0x3e], 0 };
	unsigned rev = h[0x3f];

	if (!strcmp(id4, "NPDP")) {
		c.verdict = PDRomWrongRegionPAL;
		c.explanation = @"This is the PAL (European) release. The port is built from the US "
		                 "NTSC v1.1 game and its data layout, so only that one will load. "
		                 "Look for “Perfect Dark (USA) (Rev 1)”.";
		return c;
	}
	if (!strcmp(id4, "NPDJ")) {
		c.verdict = PDRomWrongRegionJPN;
		c.explanation = @"This is the Japanese release. The port is built from the US NTSC v1.1 "
		                 "game, so only that one will load. Look for “Perfect Dark (USA) (Rev 1)”.";
		return c;
	}
	if (strcmp(id4, "NPDE")) {
		c.verdict = PDRomNotARom;
		c.explanation = [NSString stringWithFormat:
			@"This is an N64 ROM, but not Perfect Dark (its cartridge id is “%s”).", id4];
		return c;
	}
	if (rev == 0) {
		c.verdict = PDRomWrongRevision;
		c.explanation = @"This is the US v1.0 release. Perfect Dark was patched to v1.1 and the "
		                 "port is built from v1.1 — the two have different data in different "
		                 "places. Look for “Perfect Dark (USA) (Rev 1)”, also called US V1.1.";
		return c;
	}

	// Header says the right game; the hash says whether it is intact.
	c.md5 = [self md5OfFileAtPath:path] ?: @"";
	if ([c.md5 caseInsensitiveCompare:kNtscFinalMD5] == NSOrderedSame) {
		c.verdict = PDRomAccepted;
		c.explanation = @"Perfect Dark (USA) (Rev 1) — this is the one.";
	} else {
		// The header is right and the size is right, so this is very probably a
		// hacked or patched copy rather than the wrong game. Accepted, with the
		// difference said out loud: upstream will refuse it later if it is
		// really broken, and refusing a Randomizer ROM here would be wrong.
		c.verdict = PDRomAccepted;
		c.explanation = [NSString stringWithFormat:
			@"Header matches US v1.1, but the contents differ from the stock ROM "
			 "(md5 %@). A modified or patched copy — loading it anyway.", c.md5];
	}
	return c;
}

+ (NSString *)installedRomPath
{
	NSString *docs = PDShell.shared.documentsPath;
	// Both places the engine looks: $B is Documents and Documents/data
	// (docs/frame-map.md, overlay patch 0009).
	for (NSString *candidate in @[ [docs stringByAppendingPathComponent:kRomFileName],
	                               [[docs stringByAppendingPathComponent:@"data"]
	                                 stringByAppendingPathComponent:kRomFileName] ]) {
		if ([NSFileManager.defaultManager fileExistsAtPath:candidate]) {
			return candidate;
		}
	}
	return nil;
}

/**
 * A ROM the player dropped in with a different name, which is the single most
 * common way the first boot fails: "Perfect Dark (USA) (Rev 1).z64" sitting in
 * the folder next to nothing. If exactly one 32 MB .z64/.n64/.v64 is there and
 * it classifies as accepted, rename it into place rather than making somebody
 * type a file name on a phone keyboard.
 */
+ (nullable NSString *)adoptLooseRom
{
	NSString *docs = PDShell.shared.documentsPath;
	NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:docs error:NULL];
	for (NSString *name in names) {
		NSString *ext = name.pathExtension.lowercaseString;
		if (![@[ @"z64", @"n64", @"v64" ] containsObject:ext]) {
			continue;
		}
		NSString *full = [docs stringByAppendingPathComponent:name];
		PDRomCheck *c = [self classifyFileAtPath:full];
		if (!c.ok) {
			continue;
		}
		NSString *dst = [docs stringByAppendingPathComponent:kRomFileName];
		NSError *err = nil;
		if ([NSFileManager.defaultManager moveItemAtPath:full toPath:dst error:&err]) {
			NSLog(@"perfectdark: [onboard] adopted %@ as %@", name, kRomFileName);
			return dst;
		}
		NSLog(@"perfectdark: [onboard] could not rename %@: %@", name, err);
	}
	return nil;
}

+ (void)runUntilRomPresent
{
	NSAssert(NSThread.isMainThread, @"onboarding is UIKit");

	if ([self installedRomPath] || [self adoptLooseRom]) {
		NSLog(@"perfectdark: [onboard] ROM present, skipping onboarding");
		return;
	}

	NSLog(@"perfectdark: [onboard] no ROM in Documents — presenting onboarding");

	__block BOOL done = NO;
	int spins = 0;
	PDOnboardingViewController *vc = [PDOnboardingViewController new];
	vc.onAccepted = ^{ done = YES; };

	UIWindowScene *scene = nil;
	for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
		if ([s isKindOfClass:UIWindowScene.class]) {
			scene = (UIWindowScene *)s;
			break;
		}
	}
	UIWindow *win = scene ? [[UIWindow alloc] initWithWindowScene:scene]
	                      : [[UIWindow alloc] initWithFrame:PDVisionFallbackWindowFrame()];
	win.windowLevel = UIWindowLevelAlert + 1;
	win.rootViewController = vc;
	[win makeKeyAndVisible];
	PDShell.shared.overlayWindow = win;
	NSLog(@"perfectdark: [onboard] window frame=%@ scene=%@",
		NSStringFromCGRect(win.frame), scene ? @"yes" : @"no");

	// The engine has not started, so nothing else is pumping the run loop.
	while (!done) {
		@autoreleasepool {
			[NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode
			                    beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
			// A ROM dropped in through Files while this screen is up: no picker
			// involved, so poll for it.
			if (!done && ([self installedRomPath] || [self adoptLooseRom])) {
				done = YES;
			}
			// A package dropped through Files while this screen is up gets
			// acknowledged without anybody touching the picker. Once a second,
			// not every 50 ms: it is a directory walk four levels deep.
			if (++spins % 20 == 0) {
				[vc refreshXbla];
			}
		}
	}

	win.hidden = YES;
	PDShell.shared.overlayWindow = nil;
	NSLog(@"perfectdark: [onboard] ROM accepted, starting the engine");
}

@end

// ---------------------------------------------------------------------------

@implementation PDOnboardingViewController {
	UILabel *_status;
	UILabel *_xbla;
	UIButton *_xblaPick;
}

- (void)refreshXbla
{
	PDXblaFind *f = PDXbla.scan;
	_xbla.text = f.found ? [NSString stringWithFormat:@"%@\n%@", f.headline, f.plan] : f.plan;
	[_xblaPick setTitle:f.found ? @"Replace the Xbox 360 release…" : @"Add the Xbox 360 release…"
	           forState:UIControlStateNormal];
}

- (void)pickXbla
{
	__weak typeof(self) weakSelf = self;
	[PDXbla presentImporterFrom:self done:^(PDXblaFind *f) {
		NSLog(@"perfectdark: [onboard] xbla after import: %@", f.headline);
		[weakSelf refreshXbla];
	}];
}

- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.view.backgroundColor = [UIColor colorWithRed:0.04 green:0.04 blue:0.06 alpha:1.0];

	UILabel *title = [UILabel new];
	title.text = @"Perfect Dark";
	title.font = [UIFont systemFontOfSize:34 weight:UIFontWeightBold];
	title.textColor = UIColor.whiteColor;

	UILabel *body = [UILabel new];
	body.numberOfLines = 0;
	body.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
	body.font = [UIFont systemFontOfSize:15];
	body.text =
		@"This app contains no game data. You need your own copy of the Nintendo 64 game "
		 "Perfect Dark (USA) (Rev 1) — also called ntsc-final or US V1.1.\n\n"
		 "Put the file here, named pd.ntsc-final.z64:\n"
		 "    Files → On My iPhone → Perfect Dark\n\n"
		 "Then come back — this screen goes away by itself. Or use Choose a file… below "
		 "and it will be copied and renamed for you.";

	_status = [UILabel new];
	_status.numberOfLines = 0;
	_status.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
	_status.textColor = [UIColor colorWithRed:1.0 green:0.6 blue:0.4 alpha:1.0];

	UIButton *pick = [UIButton buttonWithType:UIButtonTypeSystem];
	[pick setTitle:@"Choose a file…" forState:UIControlStateNormal];
	pick.titleLabel.font = [UIFont systemFontOfSize:19 weight:UIFontWeightSemibold];
	[pick addTarget:self action:@selector(pickFile) forControlEvents:UIControlEventTouchUpInside];

	// The optional half: the Xbox 360 (XBLA) release. Its own label rather than
	// a sentence in the body, because it says what is actually in the folder
	// right now - "Found Perfect Dark.rar - a RAR archive, 227 MB" is a very
	// different screen from "put one here", and a player who dropped the file
	// and saw no acknowledgement has no way to tell which one they are looking
	// at. Refreshed by the same poll that watches for the ROM.
	_xbla = [UILabel new];
	_xbla.numberOfLines = 0;
	_xbla.font = [UIFont systemFontOfSize:14];
	_xbla.textColor = [UIColor colorWithWhite:0.72 alpha:1.0];

	_xblaPick = [UIButton buttonWithType:UIButtonTypeSystem];
	[_xblaPick setTitle:@"Add the Xbox 360 release…" forState:UIControlStateNormal];
	_xblaPick.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
	[_xblaPick addTarget:self action:@selector(pickXbla) forControlEvents:UIControlEventTouchUpInside];

	[self refreshXbla];

	// The other optional extras, in one plain sentence: GE Plus (D-072). No
	// button here - the screen is about the one file the game cannot start
	// without, and the settings page has the GoldenEye rows.
	UILabel *ge = [UILabel new];
	ge.numberOfLines = 0;
	ge.font = [UIFont systemFontOfSize:14];
	ge.textColor = [UIColor colorWithWhite:0.72 alpha:1.0];
	ge.text = @"Also optional: your own GoldenEye 007 (US) N64 ROM, and the GoldenEye XBLA "
	           "release (its .7z or .zip, or its Xbox 360 package), in the same added-content "
	           "folder under any name. With them, "
	           "GoldenEye's missions and arenas are playable as GE Plus in the Perfect Menu, "
	           "and the Goldfinger 64 ROM hack (its zip, patch or ROM) beside them. "
	           "They can be added later from Settings too.";

	UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:
		@[ title, body, _status, pick, _xbla, _xblaPick, ge ]];
	stack.axis = UILayoutConstraintAxisVertical;
	stack.spacing = 14;
	stack.translatesAutoresizingMaskIntoConstraints = NO;

	// In a scroll view: on a landscape phone the screen is 390 points tall and
	// the text is taller than that, which clipped the title off the top and the
	// last paragraph off the bottom. Centred when it fits, scrollable when not.
	UIScrollView *scroll = [UIScrollView new];
	scroll.translatesAutoresizingMaskIntoConstraints = NO;
	scroll.alwaysBounceVertical = NO;
	[scroll addSubview:stack];
	[self.view addSubview:scroll];

	UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
	UILayoutGuide *content = scroll.contentLayoutGuide;
	UILayoutGuide *frame = scroll.frameLayoutGuide;
	// content height = max(the screen, the text + margins); the text centred in it
	NSLayoutConstraint *fit = [content.heightAnchor constraintEqualToAnchor:frame.heightAnchor];
	fit.priority = UILayoutPriorityDefaultLow;
	[NSLayoutConstraint activateConstraints:@[
		[scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
		[scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
		[scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
		[scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
		[stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:28],
		[stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-28],
		[stack.widthAnchor constraintEqualToAnchor:frame.widthAnchor constant:-56],
		[content.heightAnchor constraintGreaterThanOrEqualToAnchor:frame.heightAnchor],
		[content.heightAnchor constraintGreaterThanOrEqualToAnchor:stack.heightAnchor constant:32],
		[stack.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
		fit,
	]];
}

- (void)viewDidAppear:(BOOL)animated
{
	[super viewDidAppear:animated];
	NSLog(@"perfectdark: [onboard] presented, view frame=%@", NSStringFromCGRect(self.view.frame));
	for (UIView *v in self.view.subviews) {
		if ([v isKindOfClass:UIScrollView.class]) {
			UIScrollView *sv = (UIScrollView *)v;
			UIStackView *st = sv.subviews.firstObject;
			NSLog(@"perfectdark: [onboard] scroll frame=%@ content=%@ stack=%@",
				NSStringFromCGRect(sv.frame), NSStringFromCGSize(sv.contentSize),
				NSStringFromCGRect(st.frame));
			// Test hook: a simulator cannot scroll this by injected touch, so a
			// capture of the last paragraph launches with this set.
			if (NSProcessInfo.processInfo.environment[@"PD_ONBOARD_SCROLL_END"]) {
				[sv setContentOffset:CGPointMake(0, MAX(0, sv.contentSize.height - sv.bounds.size.height))
				            animated:NO];
			}
			if ([st isKindOfClass:UIStackView.class]) {
				UILabel *last = (UILabel *)st.arrangedSubviews.lastObject;
				NSLog(@"perfectdark: [onboard] GE Plus note frame in window=%@",
					NSStringFromCGRect([last convertRect:last.bounds toView:nil]));
			}
		}
	}
}

- (void)pickFile
{
	UTType *z64 = [UTType typeWithFilenameExtension:@"z64"] ?: UTTypeData;
	UIDocumentPickerViewController *p =
		[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ z64, UTTypeData ]
		                                                           asCopy:YES];
	p.delegate = self;
	p.allowsMultipleSelection = NO;
	[self presentViewController:p animated:YES completion:nil];
	NSLog(@"perfectdark: [onboard] presenting the document picker");
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
	didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
	NSURL *url = urls.firstObject;
	if (!url) {
		return;
	}

	// asCopy:YES already gives us a copy in a temporary directory, but a
	// security scope is still the correct thing to ask for: it costs nothing
	// when it is not needed and is the difference between working and silently
	// reading nothing when it is.
	BOOL scoped = [url startAccessingSecurityScopedResource];
	PDRomCheck *check = [PDOnboarding classifyFileAtPath:url.path];
	NSLog(@"perfectdark: [onboard] picked %@ -> verdict %ld (%@)",
		url.lastPathComponent, (long)check.verdict, check.explanation);

	if (!check.ok) {
		_status.text = check.explanation;
		if (scoped) {
			[url stopAccessingSecurityScopedResource];
		}
		return;
	}

	NSString *dst = [PDShell.shared.documentsPath stringByAppendingPathComponent:kRomFileName];
	NSError *err = nil;
	// Copied beside the name and renamed over it only once complete (D-075): a
	// copy that fails part-way leaves whatever was at that name as it was.
	BOOL ok = [PDXbla copyFileSafely:url.path to:dst same:NULL error:&err];
	if (scoped) {
		[url stopAccessingSecurityScopedResource];
	}

	if (!ok) {
		_status.text = [NSString stringWithFormat:@"Could not copy the file in: %@", err.localizedDescription];
		return;
	}

	// The engine opens the ROM with plain fopen() at launch, and an app can be
	// launched while the device is still locked after a reboot. Data protection
	// would make that open fail with EPERM and look exactly like a missing
	// file, so the ROM is explicitly unprotected - it is the player's own game
	// data, not a secret.
	[NSFileManager.defaultManager setAttributes:@{ NSFileProtectionKey: NSFileProtectionNone }
	                               ofItemAtPath:dst error:NULL];

	NSLog(@"perfectdark: [onboard] ROM installed at %@", dst);
	if (self.onAccepted) {
		self.onAccepted();
	}
}

@end
