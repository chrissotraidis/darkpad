// PDXbla.m — see PDXbla.h.
#import "PDXbla.h"
#import "PDVision.h"
#import "PDShell.h"
#import "PDDefaults.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// --- private to this file --------------------------------------------------

@interface PDXblaPickerDelegate : NSObject <UIDocumentPickerDelegate>
@property (nonatomic, copy, nullable) void (^done)(PDXblaFind *);
// Set instead of `done` by the GoldenEye rows: the picked URL (nil when
// cancelled) goes to them, and they decide whether anything is copied.
@property (nonatomic, copy, nullable) void (^picked)(NSURL *_Nullable);
@end

/** The "preparing XBLA art…" note: its own window over SDL's. */
@interface PDXblaProgressWindow : NSObject
/** nil = the XBLA wording with its own percentage; anything else is shown as-is. */
+ (void)showText:(nullable NSString *)text;
+ (void)show;
+ (void)hide;
+ (BOOL)isPresented;
@end

@interface PDXblaProgressViewController : UIViewController
@end

@interface PDXbla (Private)
+ (nullable NSString *)adoptPickedURL:(NSURL *)url name:(NSString *)name same:(BOOL *_Nullable)same error:(NSError **)err;
@end

// A copy in progress (D-075): hidden by the leading dot from the engine's
// fsScanDir and from every scan in this file, and swept at the next launch if
// the app was killed before it finished.
static NSString *const kPartialPrefix = @".pd-adding-";
static NSString *const kPartialExt    = @"partial";

// The engine's own names, from port/src/xblaimport.c. Kept as literals rather
// than included: the shell is Foundation and the port's headers drag in
// PR/ultratypes.h and the whole decomp include path (PDShell.h's rule).
// Upstream c18645860 (fs.h FS_ADDED_CONTENT_DIR, xblaimport.c xblaDetect):
// the player's copy goes in added-content/ beside the GoldenEye ROM and the
// GoldenEye XBLA release, and the engine MOVES whatever an older install had
// in xbla/ into it the first time it looks (fs.c fsAddedContentDir). xbla/ is
// still searched after it, so the shell searches both in the same order - the
// pre-engine unpack (D-020) runs before that first move, on the folder the
// archive is still in.
static NSString *const kXblaDir    = @"added-content";
static NSString *const kLegacyDir  = @"xbla";
static NSString *const kCacheSub   = @"xbla";      // cache/xbla, patch 0009 -> Caches/xbla
static NSString *const kDoneFile   = @".extracted";
// overlay/patches/0001-xbla-import-scan-depth.patch raises XBLAIMPORT_SCAN_DEPTH
// from 2 to 4, because the user's .rar stores the package four names deep
// (Perfect Dark/584109C2/000D0000/<content id>). Scanning shallower here than
// the engine does would mean the onboarding screen saying "nothing found"
// about a copy the engine goes on to use.
static const int kScanDepth = 4;
// xblaScanForPackage()'s two "not this release" tests (D-070): added-content/
// is shared, and the engine passes over the GoldenEye XBLA archive (an entry
// under files/new/char/) and the Community Edition updater zip (gebean.h
// GEBEANCE_DIFF_ENTRY) before it takes an archive for Perfect Dark's - and,
// since upstream v3.14.0, an archive holding a ROM patch (goldfinger64.zip).
// A .rar is never looked into, by the engine or here.
static NSString *const kGoldenEyeEntry = @"files/new/char/";
static NSString *const kCeUpdateEntry  = @"CEUpdate/files.diff";
// overlay 0046 (gebean.c GEBEAN_PKG_ENTRY / GEBEAN_PKG_NAME / GEBEAN_PKG_TITLE /
// GEBEAN_PKG_MIN_SIZE): GoldenEye XBLA in its Xbox 360 package form - an archive
// with the console's own content path in it or the package under its own name,
// or the package itself, known by its STFS title id. Overlay 0047 makes the
// engine's Perfect Dark scan pass over both, and so does this file's.
static NSString *const kGoldenEyePackageEntry = @"584108A9/000D0000/";
static NSString *const kGoldenEyePackageName  = @"30BA92710985645EF623D4A6BA9E8EFFAEC62617";
static const unsigned long long kGoldenEyePackageMinSize = 64ULL << 20;

/** gebean.c gebeanIsPackageFile(): GoldenEye XBLA's STFS package, by its title id at 0x360. */
static BOOL pdIsGoldenEyePackageFile(NSString *path)
{
	NSDictionary *a = [NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL];
	if (!a || ![a.fileType isEqualToString:NSFileTypeRegular] || a.fileSize < kGoldenEyePackageMinSize) {
		return NO;
	}
	NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
	NSData *h = [fh readDataOfLength:0x364];
	[fh closeFile];
	if (h.length != 0x364) {
		return NO;
	}
	const uint8_t *b = h.bytes;
	static const uint8_t title[4] = { 0x58, 0x41, 0x08, 0xa9 };
	return (!memcmp(b, "LIVE", 4) || !memcmp(b, "CON ", 4) || !memcmp(b, "PIRS", 4))
	    && !memcmp(b + 0x360, title, 4);
}

/** gebean.c gebeanArchiveHoldsPackage(): a .7z/.zip holding that package (never a .rar). */
static BOOL pdArchiveHoldsGoldenEyePackage(NSString *path)
{
	NSString *ext = path.pathExtension.lowercaseString;
	if (![ext isEqualToString:@"7z"] && ![ext isEqualToString:@"zip"] && ![ext isEqualToString:@"pk3"]) {
		return NO;
	}
	const char *p = path.fileSystemRepresentation;
	return archiveFindEntry(p, kGoldenEyePackageEntry.UTF8String)
	    || archiveFindEntry(p, kGoldenEyePackageName.UTF8String);
}

/** xblaimport.c / gexplusrom.c variantArchiveHasPatch(): an archive holding a ROM patch. */
static BOOL pdArchiveHoldsRomPatch(NSString *path)
{
	const char *p = path.fileSystemRepresentation;
	return archiveFindEntry(p, ".xdelta") || archiveFindEntry(p, ".vcdiff")
	    || archiveFindEntry(p, ".bps") || archiveFindEntry(p, ".ips");
}

static BOOL sUnpacking;
static NSTimeInterval sUnpackStarted;
static NSTimeInterval sLastUnpackSeconds;
static unsigned long long sUnpackArchiveBytes;
static NSString *sUnpackNote;            // the last thing the engine's importer said

@implementation PDXblaFind

- (BOOL)found { return self.kind != PDXblaNone; }

- (NSString *)headline
{
	if (!self.found) {
		return @"No Xbox 360 release found.";
	}
	NSString *what;
	switch (self.kind) {
	case PDXblaArchiveRar:   what = @"a RAR archive"; break;
	case PDXblaArchive7z:    what = @"a 7-Zip archive"; break;
	case PDXblaArchiveOther: what = @"an archive"; break;
	case PDXblaPackage:      what = @"the Xbox 360 package itself"; break;
	default:                 what = @"a file"; break;
	}
	return [NSString stringWithFormat:@"Found %@ — %@, %.0f MB.",
		self.relativePath ?: @"?", what, (double)self.bytes / (1024.0 * 1024.0)];
}

- (NSString *)plan
{
	if (!self.found) {
		// The Files wording, not the container path: the absolute path is right
		// and unusable - it is forty characters of UUID and a player on a phone
		// has no way to navigate to it. The ROM line above names the same folder
		// the same way.
		return @"Optional: the Xbox 360 (XBLA) release. Put Perfect Dark.rar, a .7z, the bare "
		        "Xbox 360 package, or a folder holding one, into the added-content folder (the one "
		        "folder for every optional extra) here:\n"
		        "    Files → On My iPhone → Perfect Dark → added-content\n"
		        "Then the game draws 4J's high-resolution textures, meshes, rooms, font and "
		        "explosions in place of the N64 art.";
	}
	if (self.kind == PDXblaPackage) {
		return @"That is the package itself, so nothing has to be unpacked — the game reads it "
		        "where it is. The Xbox 360 art will be on the first time you play.";
	}
	if (PDXbla.isUnpacked) {
		return @"Already unpacked — the Xbox 360 art is ready.";
	}
	// "A few seconds" is measured, not guessed: 1.7 s on the lane-3 simulator
	// (M-013). The release's archive is barely compressed, so this is close to
	// a 250 MB file copy and a phone's flash decides it.
	return @"The first launch after this unpacks it once, into the app's Caches folder: about "
	        "250 MB written, usually a few seconds. Keep about 500 MB free. Your own file is "
	        "never touched, and if the system ever reclaims the Caches folder the app quietly "
	        "unpacks it again.";
}

@end

// ---------------------------------------------------------------------------

@implementation PDXbla

+ (NSString *)dropDir
{
	NSString *dir = [PDShell.shared.documentsPath stringByAppendingPathComponent:kXblaDir];
	if (![NSFileManager.defaultManager fileExistsAtPath:dir]) {
		[NSFileManager.defaultManager createDirectoryAtPath:dir
		                        withIntermediateDirectories:YES attributes:nil error:NULL];
	}
	return dir;
}

+ (NSString *)cacheDir
{
	return [[PDShell.shared.cachesPath stringByAppendingPathComponent:@"cache"]
		stringByAppendingPathComponent:kCacheSub];
}

/**
 * The engine's xblaLooksLikePackage(): STFS magic - and, since overlay 0047, not
 * GoldenEye XBLA's package, which is one too and shares the folder.
 */
+ (BOOL)looksLikePackage:(NSString *)path
{
	NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
	if (!fh) {
		return NO;
	}
	NSData *magic = [fh readDataOfLength:4];
	[fh closeFile];
	if (magic.length != 4) {
		return NO;
	}
	const char *m = magic.bytes;
	return (!memcmp(m, "LIVE", 4) || !memcmp(m, "CON ", 4) || !memcmp(m, "PIRS", 4))
	    && !pdIsGoldenEyePackageFile(path);
}

/** The engine's archiveIsSupported(): the extension, nothing else. */
+ (PDXblaKind)archiveKind:(NSString *)path
{
	NSString *ext = path.pathExtension.lowercaseString;
	if ([ext isEqualToString:@"rar"]) { return PDXblaArchiveRar; }
	if ([ext isEqualToString:@"7z"])  { return PDXblaArchive7z; }
	if ([ext isEqualToString:@"zip"] || [ext isEqualToString:@"pk3"]) { return PDXblaArchiveOther; }
	return PDXblaNone;
}

/**
 * An archive the engine's scan passes over because it is another release's -
 * or, since upstream v3.14.0 (xblaimport.c), a GoldenEye ROM hack's patch
 * passed around as an archive (goldfinger64.zip), which goes in the same folder.
 */
+ (BOOL)isOtherRelease:(NSString *)path
{
	const char *p = path.fileSystemRepresentation;
	return archiveFindEntry(p, kGoldenEyeEntry.UTF8String)
	    || archiveFindEntry(p, kCeUpdateEntry.UTF8String)
	    || pdArchiveHoldsRomPatch(path)
	    || pdArchiveHoldsGoldenEyePackage(path);
}

/**
 * One pass of the engine's xblaScanDir(). `archives` NO is the package pass and
 * YES the archive pass, and the engine runs them in that order for the reason
 * its comment gives: a player who has both has already paid for the extraction.
 */
+ (nullable NSString *)scanDir:(NSString *)dir archives:(BOOL)archives depth:(int)depth
{
	NSArray<NSString *> *names =
		[[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:NULL]
			sortedArrayUsingSelector:@selector(compare:)];
	NSMutableArray<NSString *> *subdirs = [NSMutableArray array];

	for (NSString *name in names) {
		if ([name hasPrefix:@"."]) {
			continue;               // the engine skips dotfiles, .extracted included
		}
		NSString *path = [dir stringByAppendingPathComponent:name];
		BOOL isDir = NO;
		if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir]) {
			continue;
		}
		if (isDir) {
			[subdirs addObject:path];
			continue;
		}
		if ([self looksLikePackage:path]) {
			return path;
		}
		if (archives && [self archiveKind:path] != PDXblaNone && ![self isOtherRelease:path]) {
			return path;
		}
	}

	if (depth > 0) {
		for (NSString *sub in subdirs) {
			NSString *hit = [self scanDir:sub archives:archives depth:depth - 1];
			if (hit) {
				return hit;
			}
		}
	}
	return nil;
}

+ (PDXblaFind *)scan
{
	PDXblaFind *f = [PDXblaFind new];
	NSString *root = nil;
	NSString *hit = nil;
	NSString *legacy = [PDShell.shared.documentsPath stringByAppendingPathComponent:kLegacyDir];

	// The engine's order (xblaDetect): added-content/ first, xbla/ after it,
	// a package before an archive within each. xbla/ is looked in, never made.
	for (NSString *dir in @[ self.dropDir, legacy ]) {
		hit = [self scanDir:dir archives:NO depth:kScanDepth]
		   ?: [self scanDir:dir archives:YES depth:kScanDepth];
		if (hit) {
			root = dir;
			break;
		}
	}
	if (!hit) {
		return f;
	}

	f.path = hit;
	f.relativePath = [hit hasPrefix:root] ? [hit substringFromIndex:root.length + 1] : hit.lastPathComponent;
	f.bytes = [NSFileManager.defaultManager attributesOfItemAtPath:hit error:NULL].fileSize;
	f.kind = [self looksLikePackage:hit] ? PDXblaPackage : [self archiveKind:hit];
	return f;
}

static PDXblaFind *sCachedScan;

+ (PDXblaFind *)cachedScan
{
	// The engine's first look moves xbla/* into added-content/ (fs.c
	// fsAddedContentDir) after the shell's pre-engine scan, so a cached find can
	// name a path that is no longer there. Gone = look again.
	if (sCachedScan.found && ![NSFileManager.defaultManager fileExistsAtPath:sCachedScan.path]) {
		sCachedScan = nil;
	}
	if (!sCachedScan) {
		sCachedScan = self.scan;
		NSLog(@"perfectdark: [xbla] scan cached: %@", sCachedScan.headline);
	}
	return sCachedScan;
}

+ (void)invalidateScan { sCachedScan = nil; }

+ (BOOL)isUnpacked
{
	NSString *dir = self.cacheDir;
	NSString *marker = [dir stringByAppendingPathComponent:kDoneFile];
	if (![NSFileManager.defaultManager fileExistsAtPath:marker]) {
		return NO;
	}
	// The marker alone is not the answer: xblaFindExtractedIn() wants a package
	// under it as well, and a half-written cache that kept its marker would
	// otherwise read as ready.
	return [self scanDir:dir archives:NO depth:kScanDepth] != nil;
}

+ (BOOL)needsUnpack
{
	PDXblaFind *f = self.scan;
	return f.found && f.kind != PDXblaPackage && !self.isUnpacked;
}

+ (BOOL)unpacking { return sUnpacking; }
+ (NSTimeInterval)unpackElapsed
{
	return sUnpacking ? (NSDate.timeIntervalSinceReferenceDate - sUnpackStarted) : 0;
}
+ (NSTimeInterval)lastUnpackSeconds { return sLastUnpackSeconds; }

/**
 * Bytes on disk under Caches/xbla against the archive's own size.
 *
 * archiveExtract() has no progress callback, so this is measured rather than
 * reported. The release's archive barely compresses (upstream: "already
 * compressed data"), so the two sizes are within a few percent of each other
 * and the number is honest enough to watch a bar move by. Clamped at 99 so it
 * never claims to be finished before the marker is written.
 */
+ (int)unpackPercent
{
	if (!sUnpacking || !sUnpackArchiveBytes) {
		return -1;
	}
	unsigned long long total = 0;
	NSDirectoryEnumerator *e = [NSFileManager.defaultManager enumeratorAtPath:self.cacheDir];
	for (NSString *rel in e) {
		total += e.fileAttributes.fileSize;
	}
	int pct = (int)((100.0 * (double)total) / (double)sUnpackArchiveBytes);
	return pct < 0 ? 0 : (pct > 99 ? 99 : pct);
}

+ (void)beginUnpackIfNeeded
{
	// Asked once a frame, so the answer is decided once. Upstream paid for
	// exactly this lesson on its own side (xblaimport.c: 57 opens of a 233 MB
	// archive and 110 directory probes over one level load, all of them
	// re-deciding what the first one decided).
	static BOOL decided;

	if (decided || sUnpacking || !PDShell.shared.engineRunning) {
		return;
	}
	decided = YES;

	PDXblaFind *f = self.scan;
	if (!f.found || f.kind == PDXblaPackage) {
		return;
	}
	if (self.isUnpacked) {
		return;
	}

	sUnpacking = YES;
	sUnpackStarted = NSDate.timeIntervalSinceReferenceDate;
	sUnpackArchiveBytes = f.bytes;
	sUnpackNote = @"unpacking";
	NSLog(@"perfectdark: [xbla] unpacking %@ (%llu bytes) into %@",
		f.relativePath, f.bytes, self.cacheDir);

	[PDXblaProgressWindow show];

	// Upstream's own worker thread calls exactly this function for exactly this
	// reason (xblaimport.c, xblaImportWorker) - the unpack is mutex-guarded and
	// fsFullPath()'s scratch buffer is _Thread_local, so a second thread in
	// there is the designed case. What it buys us is that the GAME thread is
	// never the one waiting: the frame loop keeps turning, the progress note
	// keeps drawing, and the model loader finds the package already there.
	NSThread *t = [[NSThread alloc] initWithBlock:^{
		const char *path = xblaImportGetStfsPath();
		NSTimeInterval took = NSDate.timeIntervalSinceReferenceDate - sUnpackStarted;

		if (path && *path) {
			NSLog(@"perfectdark: [xbla] unpacked in %.1fs -> %s", took, path);
			sUnpackNote = @"ready";
		} else {
			NSLog(@"perfectdark: [xbla] unpack FAILED after %.1fs", took);
			sUnpackNote = @"failed";
		}
		sLastUnpackSeconds = took;
		sUnpacking = NO;

		// The importer decided there was no package while the archive was still
		// an archive; now there is one, so let it look again.
		[PDShell.shared enqueue:^{ xblaImportRedetect(); }];
		dispatch_async(dispatch_get_main_queue(), ^{ [PDXblaProgressWindow hide]; });
	}];
	t.name = @"pd-xbla-unpack";
	t.qualityOfService = NSQualityOfServiceUserInitiated;
	[t start];
}

/**
 * The unpack the shell does itself, before the engine exists. See the header
 * for why it is not left to the engine (D-020).
 *
 * The layout written here is exactly the one xblaEnsureUnpackedLocked() expects
 * to find on the next launch - the archive's contents under Caches/cache/xbla
 * and a `.extracted` marker beside them - so the engine's own path is a scan
 * and a stat, and nothing is unpacked twice.
 */
+ (void)showPreparingNote:(NSString *)text
{
	[PDXblaProgressWindow showText:text];
	// The note is a UIKit view and nothing else is turning the run loop yet;
	// one pass gets it on screen before the caller starts blocking.
	[NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode
	                    beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
}

+ (void)hidePreparingNote
{
	[PDXblaProgressWindow hide];
}

+ (void)runUnpackUntilReady
{
	NSAssert(NSThread.isMainThread, @"pre-engine, UIKit's thread");

	PDXblaFind *f = self.scan;
	if (!f.found || f.kind == PDXblaPackage || self.isUnpacked) {
		if (f.found) {
			NSLog(@"perfectdark: [xbla] %@ — nothing to unpack", f.headline);
		}
		return;
	}

	NSString *dir = self.cacheDir;
	[NSFileManager.defaultManager createDirectoryAtPath:dir
	                        withIntermediateDirectories:YES attributes:nil error:NULL];

	// A cache that has files in it but no marker is a previous attempt that was
	// killed (the app swiped away mid-unpack, or the gate's terminate). Start
	// clean rather than extracting over the top of half a package.
	NSArray *leftovers = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:NULL];
	if (leftovers.count) {
		NSLog(@"perfectdark: [xbla] clearing %lu leftovers from an unfinished unpack",
			(unsigned long)leftovers.count);
		[NSFileManager.defaultManager removeItemAtPath:dir error:NULL];
		[NSFileManager.defaultManager createDirectoryAtPath:dir
		                        withIntermediateDirectories:YES attributes:nil error:NULL];
	}

	sUnpacking = YES;
	sUnpackStarted = NSDate.timeIntervalSinceReferenceDate;
	sUnpackArchiveBytes = f.bytes;
	sUnpackNote = @"unpacking";
	NSLog(@"perfectdark: [xbla] pre-engine unpack of %@ (%llu bytes) -> %@",
		f.relativePath, f.bytes, dir);

	[PDXblaProgressWindow show];

	__block BOOL ok = NO;
	NSString *src = f.path;
	NSThread *t = [[NSThread alloc] initWithBlock:^{
		// archive.c takes absolute paths straight through fsFullPath(), so this
		// works with no fsInit() behind it (PDShell.h).
		ok = archiveExtract(src.fileSystemRepresentation, dir.fileSystemRepresentation) > 0;
		sUnpacking = NO;
	}];
	t.name = @"pd-xbla-unpack";
	t.qualityOfService = NSQualityOfServiceUserInitiated;
	[t start];

	// The engine is not running, so nothing else is pumping the run loop - the
	// same shape as PDOnboarding's wait, and for the same reason.
	while (sUnpacking) {
		@autoreleasepool {
			[NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode
			                    beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
		}
	}

	sLastUnpackSeconds = NSDate.timeIntervalSinceReferenceDate - sUnpackStarted;

	if (ok && [self scanDir:dir archives:NO depth:kScanDepth]) {
		// The marker is what says "finished" to both sides. Written only after
		// a package has actually been found under it, so a truncated archive
		// cannot leave a cache that reads as ready for ever.
		[NSFileManager.defaultManager createFileAtPath:[dir stringByAppendingPathComponent:kDoneFile]
		                                      contents:[NSData data] attributes:nil];
		sUnpackNote = @"ready";
		NSLog(@"perfectdark: [xbla] unpacked in %.1fs", sLastUnpackSeconds);
	} else {
		sUnpackNote = @"failed";
		NSLog(@"perfectdark: [xbla] unpack FAILED after %.1fs (archiveExtract %@, package %@)",
			sLastUnpackSeconds, ok ? @"ok" : @"failed",
			[self scanDir:dir archives:NO depth:kScanDepth] ?: @"not found");
	}

	[PDXblaProgressWindow hide];
}

+ (NSString *)stateLines
{
	PDXblaFind *f = self.scan;
	NSMutableString *s = [NSMutableString string];
	[s appendFormat:@"xbla_found=%d\n", (int)f.found];
	[s appendFormat:@"xbla_kind=%@\n", f.found ? (f.kind == PDXblaPackage ? @"package" : @"archive") : @"none"];
	[s appendFormat:@"xbla_file=%@\n", f.relativePath ?: @"-"];
	[s appendFormat:@"xbla_extracted=%d\n", (int)self.isUnpacked];
	[s appendFormat:@"xbla_unpacking=%d\n", (int)sUnpacking];
	[s appendFormat:@"xbla_unpack_pct=%d\n", self.unpackPercent];
	[s appendFormat:@"xbla_unpack_secs=%.1f\n", sLastUnpackSeconds];
	[s appendFormat:@"xbla_cache=%@\n", self.cacheDir];
	[s appendFormat:@"xbla_note=%@\n", sUnpackNote ?: @"-"];
	return s;
}

// --- the Files importer ----------------------------------------------------

// the picker does not retain its delegate
static PDXblaPickerDelegate *sPickerDelegate;

+ (void)presentImporterFrom:(UIViewController *)vc done:(void (^)(PDXblaFind *))done
{
	PDXblaPickerDelegate *keep = sPickerDelegate = [PDXblaPickerDelegate new];
	keep.done = done;

	// Anything at all: the release travels as .rar, .7z, .zip and as a bare
	// package with a 40-hex-character name and no extension whatsoever, and a
	// picker that filters on type would hide the last of those completely.
	UIDocumentPickerViewController *p =
		[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeItem ] asCopy:YES];
	p.delegate = keep;
	p.allowsMultipleSelection = NO;
	[vc presentViewController:p animated:YES completion:nil];
	NSLog(@"perfectdark: [xbla] presenting the document picker");
}

/** Copy a picked file into Documents/added-content. Main thread; returns the new path. */
+ (nullable NSString *)adoptPickedURL:(NSURL *)url error:(NSError **)err
{
	return [self adoptPickedURL:url name:url.lastPathComponent same:NULL error:err];
}

/** The same, under a name of the caller's choosing (the GoldenEye rows never overwrite another kind of file). */
+ (nullable NSString *)adoptPickedURL:(NSURL *)url name:(NSString *)name same:(BOOL *)same error:(NSError **)err
{
	NSString *dst = [self.dropDir stringByAppendingPathComponent:name];
	if (![self copyFileSafely:url.path to:dst same:same error:err]) {
		return nil;
	}
	return dst;
}

// --- copying the player's files in (D-075) ---------------------------------

#ifndef PD_PUBLIC
static NSString *sFailNextCopy; // test hook: "copy" or "swap", consumed by the next copy
+ (void)failNextCopyAt:(NSString *)stage
{
	sFailNextCopy = stage.length ? stage.lowercaseString : nil;
	NSLog(@"perfectdark: [adopt] test hook: next copy fails at %@", sFailNextCopy ?: @"(nothing)");
}
#endif

static BOOL pdSameFile(NSString *a, NSString *b)
{
	struct stat sa, sb;
	return stat(a.fileSystemRepresentation, &sa) == 0 && stat(b.fileSystemRepresentation, &sb) == 0
	    && sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino;
}

static NSError *pdPosixError(int code, NSString *what)
{
	return [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:@{
		NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %s", what, strerror(code)],
	}];
}

+ (BOOL)copyFileSafely:(NSString *)src to:(NSString *)dst same:(BOOL *)same error:(NSError **)err
{
	NSFileManager *fm = NSFileManager.defaultManager;
	if (same) {
		*same = NO;
	}
	// Picking the very file that is already in place (the app's own copy, chosen
	// again through Files or the bridge): there is nothing to do, and removing
	// or overwriting the destination would destroy the source with it.
	if (pdSameFile(src, dst)) {
		if (same) {
			*same = YES;
		}
		NSLog(@"perfectdark: [adopt] %@ is already in place; nothing copied", dst.lastPathComponent);
		return YES;
	}

	NSString *tmp = [dst.stringByDeletingLastPathComponent stringByAppendingPathComponent:
		[NSString stringWithFormat:@"%@%@.%@", kPartialPrefix, NSUUID.UUID.UUIDString, kPartialExt]];
	NSError *e = nil;
	BOOL ok = [fm copyItemAtPath:src toPath:tmp error:&e];
#ifndef PD_PUBLIC
	if (ok && [sFailNextCopy isEqualToString:@"copy"]) {
		sFailNextCopy = nil;
		// what a copy that ran out of space leaves behind: half a file
		unsigned long long n = [fm attributesOfItemAtPath:tmp error:NULL].fileSize;
		truncate(tmp.fileSystemRepresentation, (off_t)(n / 2));
		ok = NO;
		e = pdPosixError(ENOSPC, @"test hook: the copy ran out of space");
	}
#endif
	if (ok) {
		// The engine opens these with plain fopen(), and an app can be launched
		// while the device is still locked after a reboot. Data protection would
		// make that open fail with EPERM and look exactly like a missing file.
		// Set on the temporary file, so the name that appears is already right.
		[fm setAttributes:@{ NSFileProtectionKey: NSFileProtectionNone } ofItemAtPath:tmp error:NULL];

		int rc;
#ifndef PD_PUBLIC
		if ([sFailNextCopy isEqualToString:@"swap"]) {
			sFailNextCopy = nil;
			rc = -1;
			errno = EIO;
		} else
#endif
		{
			// rename(2) replaces an existing file in one step: at every instant
			// the name is either the old file or the complete new one.
			rc = rename(tmp.fileSystemRepresentation, dst.fileSystemRepresentation);
		}
		if (rc != 0) {
			ok = NO;
			e = pdPosixError(errno, @"could not move the copy into place");
		}
	}
	if (!ok) {
		// Only ever our own temporary file; the destination was never touched.
		[fm removeItemAtPath:tmp error:NULL];
		NSLog(@"perfectdark: [adopt] copy of %@ -> %@ FAILED (%@); the existing file is untouched",
			src.lastPathComponent, dst.lastPathComponent, e.localizedDescription);
		if (err) {
			*err = e;
		}
		return NO;
	}
	NSLog(@"perfectdark: [adopt] copied %@ -> %@", src.lastPathComponent, dst);
	return YES;
}

+ (void)sweepPartialCopies
{
	NSAssert(NSThread.isMainThread, @"at launch, before anything copies");
	NSFileManager *fm = NSFileManager.defaultManager;
	for (NSString *dir in @[ self.dropDir, PDShell.shared.documentsPath ]) {
		for (NSString *name in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
			if ([name hasPrefix:kPartialPrefix] && [name.pathExtension isEqualToString:kPartialExt]) {
				NSString *p = [dir stringByAppendingPathComponent:name];
				[fm removeItemAtPath:p error:NULL];
				NSLog(@"perfectdark: [adopt] removed an unfinished copy %@", p);
			}
		}
	}
}

@end

// ---------------------------------------------------------------------------

@implementation PDXblaPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller
	didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
	NSURL *url = urls.firstObject;
	if (self.picked) {
		self.picked(url);
		return;
	}
	if (url) {
		BOOL scoped = [url startAccessingSecurityScopedResource];
		NSError *err = nil;
		NSString *dst = [PDXbla adoptPickedURL:url error:&err];
		if (scoped) {
			[url stopAccessingSecurityScopedResource];
		}
		NSLog(@"perfectdark: [xbla] imported %@ -> %@ (%@)",
			url.lastPathComponent, dst ?: @"FAILED", err ?: @"ok");
	}
	if (self.done) {
		[PDXbla invalidateScan];
		self.done(PDXbla.scan);
	}
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller
{
	if (self.picked) {
		self.picked(nil);
		return;
	}
	if (self.done) {
		[PDXbla invalidateScan];
		self.done(PDXbla.scan);
	}
}

@end

// ---------------------------------------------------------------------------

// "Preparing XBLA art…" — a window of its own over SDL's, the same shape the
// settings page uses and for the same reason (SDL owns the game window's root
// view controller and fights anything presented over it for orientation).
@implementation PDXblaProgressWindow

static UIWindow *sProgressWindow;
static UILabel *sProgressLabel;
static UIProgressView *sProgressBar;
static NSTimer *sProgressTimer;

static NSString *sProgressFixedText;

+ (void)show { [self showText:nil]; }

+ (void)showText:(NSString *)text
{
	if (!NSThread.isMainThread) {
		dispatch_async(dispatch_get_main_queue(), ^{ [self showText:text]; });
		return;
	}
	sProgressFixedText = [text copy];
	if (sProgressWindow) {
		return;
	}

	UIViewController *vc = [PDXblaProgressViewController new];
	UIWindowScene *scene = nil;
	for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
		if ([s isKindOfClass:UIWindowScene.class]) {
			scene = (UIWindowScene *)s;
			break;
		}
	}
	sProgressWindow = scene ? [[UIWindow alloc] initWithWindowScene:scene]
	                        : [[UIWindow alloc] initWithFrame:PDVisionFallbackWindowFrame()];
	sProgressWindow.windowLevel = UIWindowLevelAlert;
	sProgressWindow.rootViewController = vc;
	sProgressWindow.backgroundColor = UIColor.clearColor;
	[sProgressWindow makeKeyAndVisible];
	// Sceneless when shown before the scene has connected (a cold launch):
	// pdGraftSDLWindows() puts it on the scene when it arrives (D-073).
	if (!scene) {
		PDShell.shared.overlayWindow = sProgressWindow;
	}

	sProgressTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
		if (sProgressFixedText) {
			sProgressLabel.text = sProgressFixedText;
			sProgressBar.hidden = YES;
			return;
		}
		sProgressBar.hidden = NO;
		int pct = PDXbla.unpackPercent;
		int secs = (int)lround(PDXbla.unpackElapsed);
		sProgressLabel.text = [NSString stringWithFormat:
			@"Preparing the Xbox 360 art — %d%%\n%d second%s so far. This happens once.",
			pct < 0 ? 0 : pct, secs, secs == 1 ? "" : "s"];
		sProgressBar.progress = (pct < 0 ? 0 : pct) / 100.0f;
	}];
	NSLog(@"perfectdark: [xbla] progress note up");
}

+ (void)hide
{
	if (!NSThread.isMainThread) {
		dispatch_async(dispatch_get_main_queue(), ^{ [self hide]; });
		return;
	}
	[sProgressTimer invalidate];
	sProgressTimer = nil;
	sProgressFixedText = nil;
	sProgressWindow.hidden = YES;
	if (PDShell.shared.overlayWindow == sProgressWindow) {
		PDShell.shared.overlayWindow = nil;
	}
	sProgressWindow = nil;
	sProgressLabel = nil;
	sProgressBar = nil;
	NSLog(@"perfectdark: [xbla] progress note down");
}

+ (BOOL)isPresented { return sProgressWindow != nil && !sProgressWindow.hidden; }

@end

@implementation PDXblaProgressViewController

- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }

- (void)viewDidLoad
{
	[super viewDidLoad];
	// The engine has not started yet, so there is nothing behind this: opaque,
	// and the same near-black the onboarding screen uses.
	self.view.backgroundColor = [UIColor colorWithRed:0.04 green:0.04 blue:0.06 alpha:1.0];

	UILabel *title = [UILabel new];
	title.text = @"Xbox 360 release";
	title.font = [UIFont systemFontOfSize:26 weight:UIFontWeightBold];
	title.textColor = UIColor.whiteColor;
	title.textAlignment = NSTextAlignmentCenter;

	sProgressLabel = [UILabel new];
	sProgressLabel.numberOfLines = 0;
	sProgressLabel.textAlignment = NSTextAlignmentCenter;
	sProgressLabel.font = [UIFont systemFontOfSize:15];
	sProgressLabel.textColor = [UIColor colorWithWhite:0.88 alpha:1.0];
	sProgressLabel.text = @"Preparing the Xbox 360 art — 0%\nThis happens once.";

	sProgressBar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];

	UILabel *foot = [UILabel new];
	foot.numberOfLines = 0;
	foot.textAlignment = NSTextAlignmentCenter;
	foot.font = [UIFont systemFontOfSize:13];
	foot.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
	// Honest: the game has not started yet. This runs before pdEngineMain()
	// precisely so that the alternative - a frozen drawn frame - cannot happen
	// (D-020), which means there is nothing behind this to keep playing.
	foot.text = @"The game starts as soon as this finishes. Your own copy of the release is "
	             "not touched.";

	UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:
		@[ title, sProgressLabel, sProgressBar, foot ]];
	stack.axis = UILayoutConstraintAxisVertical;
	stack.spacing = 12;
	stack.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:stack];

	UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
	[NSLayoutConstraint activateConstraints:@[
		[stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:60],
		[stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-60],
		[stack.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
	]];
}

@end

// ===========================================================================
// GE Plus's two files (PDXbla.h, D-071/D-072).
// ===========================================================================

// port/src/geconvert.h GECONVERT_ROM_SIZE: the US cartridge, 12 MB.
static const unsigned long long kGoldenEyeRomSize = 0xc00000ULL;
// port/src/gebean.c GEBEAN_SCAN_DEPTH and GEBEAN_WANT_CHARS: a folder holding
// files/new/char, or an archive with an entry under it - or, since overlay 0046,
// the Xbox 360 package or an archive holding it - four levels down (a folder of
// the package as it comes out of its archive has it four names deep).
static const int kGoldenEyeScanDepth = 4;
// gebean.c GEBEAN_DONE_FILE's prefix, and GEBEAN_NOSPACE_FILE (overlay 0046).
static NSString *const kGeMarkerPrefix = @".extracted";
static NSString *const kGeNoSpaceFile  = @".needs-space";
static NSString *const kGoldenEyeTree = @"files/new/char";
// port/include/gexplusrom.h GEXPLUSROM_DIR and its CONVERT.txt stamp; overlay
// 0043 puts the arenas in Caches/mods, an older build left them in Documents/mods.
static NSString *const kArenasDir = @"GoldenEye Arenas";
// gexplusrom.c's ROM hacks: geconvert.h GECONVERT_ROM_SIZE is the floor for the
// hack's own ROM (Goldfinger 64's is 24 MB), VARIANT_ARCHIVE_MAX the ceiling for
// an archive of its patch; the conversion's stamp names its source on its second
// line, from $E (overlay 0053), and overlay 0053 puts it in Caches/mods.
static const unsigned long long kHackArchiveMax = 128ULL << 20;
static NSString *const kStampFrom = @"Converted from ";
// STFS title ids at 0x360 of a package: Perfect Dark's and GoldenEye XBLA's.
static const uint8_t kTitlePerfectDark[4] = { 0x58, 0x41, 0x09, 0xc2 };
static const uint8_t kTitleGoldenEye[4]   = { 0x58, 0x41, 0x08, 0xa9 };

@implementation PDGoldenEyeFind

- (BOOL)found { return self.path != nil; }

- (NSString *)rowText
{
	if (!self.found) {
		return @"none in Documents/added-content";
	}
	NSString *size = self.isFolder ? @"folder"
		: [NSString stringWithFormat:@"%.0f MB", (double)self.bytes / (1024.0 * 1024.0)];
	NSString *state;
	if (self.kind == PDGoldenEyeRom) {
		state = self.ready ? @"ready" : @"converted when the app next opens";
	} else if (self.kind == PDGoldenEyeHack) {
		// a patch is applied to the GoldenEye ROM; with none there is nothing to
		// apply it to (gexplusrom.c variantFromPatch)
		state = self.ready ? @"ready"
			: self.needsRom ? @"needs the GoldenEye 007 ROM above"
			: @"converted when the app next opens";
	} else if (!PDDefBool(PDDefXblaGoldenEye)) {
		// D-081: the switch row under this one is off - the engine does not
		// look at the release at all, so it is not unpacked either
		state = (self.ready || self.isFolder) ? @"ready, switched off" : @"switched off";
	} else if (self.ready || self.isFolder) {
		state = @"ready";
	} else if (self.needMb > 0) {
		// the last start could not unpack it (overlay 0046); it tries again
		state = [NSString stringWithFormat:@"needs %d MB free to unpack (%d MB free last time)",
			self.needMb, self.freeMb];
	} else {
		state = @"unpacked when the app next opens";
	}
	return [NSString stringWithFormat:@"%@ (%@), %@", self.relativePath ?: @"?", size, state];
}

@end

@implementation PDXbla (GoldenEye)

static PDGoldenEyeFind *sGeRom, *sGeXbla, *sGeHack;     // main thread only
static dispatch_queue_t sGeQueue;

static NSData *pdHead(NSString *path, NSUInteger len)
{
	NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
	NSData *d = [fh readDataOfLength:len];
	[fh closeFile];
	return d;
}

/** The engine's ROM test: GoldenEye's size, then its header. */
static BOOL pdIsGoldenEyeUsRom(NSString *path, unsigned long long size)
{
	if (size != kGoldenEyeRomSize) {
		return NO;
	}
	NSData *h = pdHead(path, 0x40);
	return h.length == 0x40 && geconvertHeaderIsGoldenEyeUs(h.bytes, h.length);
}

static BOOL pdIsArchiveExt(NSString *path)
{
	NSString *ext = path.pathExtension.lowercaseString;
	return [ext isEqualToString:@"7z"] || [ext isEqualToString:@"zip"] || [ext isEqualToString:@"pk3"];
}

/** gebean.c's archive test: one it can read, with an entry under files/new/char/. */
static BOOL pdIsGoldenEyeArchive(NSString *path)
{
	return pdIsArchiveExt(path) && archiveFindEntry(path.fileSystemRepresentation, kGoldenEyeEntry.UTF8String);
}

/** gexplusrom.c's ROM hack test for the hack's own ROM: bigger than GoldenEye's, a header the converter knows. */
static NSString *pdHackRomName(NSString *path, unsigned long long size)
{
	if (size <= kGoldenEyeRomSize) {
		return nil;
	}
	NSData *h = pdHead(path, 0x40);
	const char *name = h.length == 0x40 ? geconvertHeaderVariantName(h.bytes, h.length) : NULL;
	return name ? @(name) : nil;
}

/**
 * gexPlusRomConvertVariants()'s three ways in, by the file alone: a patch by
 * its name, an archive of one (a few MB, not a release), or the hack's ROM.
 * A patch is only known to make a hack once it is applied, which is the
 * engine's to do; the shell takes it on its name, as the engine looks at it.
 */
static BOOL pdIsHackSource(NSString *path, unsigned long long size, BOOL *isPatch)
{
	if (rompatchIsPatchName(path.lastPathComponent.fileSystemRepresentation)) {
		*isPatch = YES;
		return YES;
	}
	if (pdIsArchiveExt(path) && size <= kHackArchiveMax && pdArchiveHoldsRomPatch(path)) {
		*isPatch = YES;
		return YES;
	}
	*isPatch = NO;
	return pdHackRomName(path, size) != nil;
}

static BOOL pdIsDir(NSString *path)
{
	BOOL d = NO;
	return [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&d] && d;
}

/** gexplusrom.c's scan: the top level of a folder, nothing deeper. */
static NSString *pdScanRom(NSString *dir)
{
	NSArray *names = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:NULL]
		sortedArrayUsingSelector:@selector(compare:)];
	for (NSString *name in names) {
		if ([name hasPrefix:@"."]) {
			continue;   // fsScanDir skips dotfiles, an unfinished copy included (D-075)
		}
		NSString *p = [dir stringByAppendingPathComponent:name];
		NSDictionary *a = [NSFileManager.defaultManager attributesOfItemAtPath:p error:NULL];
		if (a && ![a.fileType isEqualToString:NSFileTypeDirectory] && pdIsGoldenEyeUsRom(p, a.fileSize)) {
			return p;
		}
	}
	return nil;
}

static BOOL pdHackConverted(NSString *hit);

/**
 * gexPlusRomConvertVariants()'s scan: the top level of added-content/, files
 * only. The engine converts from every source it finds, so the one shown is
 * the first already converted, else the first in name order.
 */
static NSString *pdScanHack(NSString *dir, BOOL *isPatch)
{
	NSString *first = nil;
	BOOL firstPatch = NO;
	NSArray *names = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:NULL]
		sortedArrayUsingSelector:@selector(compare:)];
	for (NSString *name in names) {
		if ([name hasPrefix:@"."]) {
			continue;
		}
		NSString *p = [dir stringByAppendingPathComponent:name];
		NSDictionary *a = [NSFileManager.defaultManager attributesOfItemAtPath:p error:NULL];
		BOOL patch = NO;
		if (a && [a.fileType isEqualToString:NSFileTypeRegular] && a.fileSize > 0
		    && pdIsHackSource(p, a.fileSize, &patch)) {
			if (pdHackConverted(p)) {
				*isPatch = patch;
				return p;
			}
			if (!first) {
				first = p;
				firstPatch = patch;
			}
		}
	}
	*isPatch = firstPatch;
	return first;
}

/** gebeanScan(): `archives` NO looks for an unpacked folder, YES for an archive. */
static NSString *pdScanGeXbla(NSString *dir, BOOL archives, int depth)
{
	if (!archives && pdIsDir([dir stringByAppendingPathComponent:kGoldenEyeTree])) {
		return dir;
	}
	NSArray *names = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:NULL]
		sortedArrayUsingSelector:@selector(compare:)];
	for (NSString *name in names) {
		if ([name hasPrefix:@"."]) {
			continue;
		}
		NSString *p = [dir stringByAppendingPathComponent:name];
		if (pdIsDir(p)) {
			if (!archives && pdIsDir([p stringByAppendingPathComponent:kGoldenEyeTree])) {
				return p;
			}
			if (depth > 0) {
				NSString *hit = pdScanGeXbla(p, archives, depth - 1);
				if (hit) {
					return hit;
				}
			}
		} else if (archives && (pdIsGoldenEyeArchive(p) || pdArchiveHoldsGoldenEyePackage(p)
		                        || pdIsGoldenEyePackageFile(p))) {
			return p;
		}
	}
	return nil;
}

static BOOL pdArenasConverted(void)
{
	NSString *docs = PDShell.shared.documentsPath, *caches = PDShell.shared.cachesPath;
	for (NSString *root in @[ caches, docs ]) {
		NSString *stamp = [[[root stringByAppendingPathComponent:@"mods"]
			stringByAppendingPathComponent:kArenasDir] stringByAppendingPathComponent:@"CONVERT.txt"];
		if ([NSFileManager.defaultManager fileExistsAtPath:stamp]) {
			return YES;
		}
	}
	return NO;
}

/**
 * Whether a hack's conversion was made from this file: its CONVERT.txt, in
 * Caches/mods (overlay 0053) or Documents/mods, names it on its second line -
 * "$E/added-content/<name>" since 0053 (gexplusrom.c variantCanonical()).
 */
static BOOL pdHackConverted(NSString *hit)
{
	NSString *docs = PDShell.shared.documentsPath, *caches = PDShell.shared.cachesPath;
	char *realDocs = realpath(docs.fileSystemRepresentation, NULL);
	char *realHit = realpath(hit.fileSystemRepresentation, NULL);
	NSString *want = nil;
	if (realDocs && realHit && !strncmp(realHit, realDocs, strlen(realDocs)) && realHit[strlen(realDocs)] == '/') {
		want = [@"$E" stringByAppendingString:@(realHit + strlen(realDocs))];
	} else if (realHit) {
		want = @(realHit);
	}
	free(realDocs);
	free(realHit);
	for (int i = 0; want && geconvertVariantNameAt(i); i++) {
		for (NSString *root in @[ caches, docs ]) {
			NSString *stamp = [[[root stringByAppendingPathComponent:@"mods"]
				stringByAppendingPathComponent:@(geconvertVariantNameAt(i))] stringByAppendingPathComponent:@"CONVERT.txt"];
			NSArray *lines = [[NSString stringWithContentsOfFile:stamp encoding:NSUTF8StringEncoding error:NULL]
				componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
			if (lines.count >= 2 && [lines[1] isEqualToString:[kStampFrom stringByAppendingString:want]]) {
				return YES;
			}
		}
	}
	return NO;
}

/** Caches/cache/xbla/goldeneye - gebean.c's cache, under patch 0009's Caches. */
static NSString *pdGeCacheDir(void)
{
	return [PDXbla.cacheDir stringByAppendingPathComponent:@"goldeneye"];
}

/**
 * Whether the engine will find the cache ready for this file. gebean.c's
 * GEBEAN_DONE_FILE is ".extracted" plus a number upstream raises when it wants
 * more of the archive; any of them means "unpacked once". Since overlay 0046 it
 * names what it was unpacked from, "<file name> <size>", and a cache made from
 * another file is unpacked again; an empty one (older builds) only ever came
 * from an archive of the loose files, and still counts for one.
 */
static BOOL pdGeXblaUnpacked(NSString *hit, unsigned long long bytes)
{
	NSString *cache = pdGeCacheDir();
	for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:cache error:NULL]) {
		if (![name hasPrefix:kGeMarkerPrefix]) {
			continue;
		}
		NSString *have = [[NSString stringWithContentsOfFile:[cache stringByAppendingPathComponent:name]
			encoding:NSUTF8StringEncoding error:NULL] stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
		if (have.length == 0) {
			return pdIsGoldenEyeArchive(hit);
		}
		return [have isEqualToString:[NSString stringWithFormat:@"%@ %llu", hit.lastPathComponent, bytes]];
	}
	return NO;
}

/** MB needed and free when the engine last refused to unpack for want of room (overlay 0046). */
static BOOL pdGeNeedsSpace(int *needMb, int *freeMb)
{
	NSString *t = [NSString stringWithContentsOfFile:[pdGeCacheDir() stringByAppendingPathComponent:kGeNoSpaceFile]
		encoding:NSUTF8StringEncoding error:NULL];
	return t && sscanf(t.UTF8String, "%d %d", needMb, freeMb) == 2;
}

static PDGoldenEyeFind *pdFind(PDGoldenEyeKind kind, NSString *hit, NSString *root)
{
	PDGoldenEyeFind *f = [PDGoldenEyeFind new];
	f.kind = kind;
	if (!hit) {
		return f;
	}
	f.path = hit;
	f.relativePath = [hit hasPrefix:[root stringByAppendingString:@"/"]]
		? [hit substringFromIndex:root.length + 1] : hit.lastPathComponent;
	f.isFolder = pdIsDir(hit);
	f.bytes = f.isFolder ? 0 : [NSFileManager.defaultManager attributesOfItemAtPath:hit error:NULL].fileSize;
	f.ready = kind == PDGoldenEyeRom ? pdArenasConverted()
		: kind == PDGoldenEyeHack ? pdHackConverted(hit) : pdGeXblaUnpacked(hit, f.bytes);
	if (kind == PDGoldenEyeXbla && !f.isFolder) {
		f.isPackage = !pdIsGoldenEyeArchive(hit);
		int need = 0, free = 0;
		if (!f.ready && pdGeNeedsSpace(&need, &free)) {
			f.needMb = need;
			f.freeMb = free;
		}
	}
	return f;
}

/** All three scans, any thread. */
static void pdScanGoldenEye(PDGoldenEyeFind **rom, PDGoldenEyeFind **xbla, PDGoldenEyeFind **hack)
{
	NSString *docs = PDShell.shared.documentsPath;
	NSString *drop = PDXbla.dropDir;
	NSString *legacy = [docs stringByAppendingPathComponent:kLegacyDir];

	// The ROM: added-content/, then the base dir (Documents itself on iOS), from
	// which the engine moves it into added-content/ at its next start.
	NSString *hit = pdScanRom(drop), *root = drop;
	if (!hit) {
		hit = pdScanRom(docs);
		root = docs;
	}
	*rom = pdFind(PDGoldenEyeRom, hit, root);

	// The release: a folder before an archive, added-content/ before xbla/.
	hit = nil;
	for (NSNumber *archives in @[ @NO, @YES ]) {
		for (NSString *dir in @[ drop, legacy ]) {
			if ((hit = pdScanGeXbla(dir, archives.boolValue, kGoldenEyeScanDepth))) {
				root = dir;
				break;
			}
		}
		if (hit) {
			break;
		}
	}
	*xbla = pdFind(PDGoldenEyeXbla, hit, root);

	// A ROM hack (Goldfinger 64): added-content/ only, as the engine looks.
	BOOL isPatch = NO;
	hit = pdScanHack(drop, &isPatch);
	*hack = pdFind(PDGoldenEyeHack, hit, drop);
	(*hack).isPatch = hit && isPatch;
	(*hack).needsRom = (*hack).isPatch && !(*rom).found;
}

+ (PDGoldenEyeFind *)cachedGoldenEye:(PDGoldenEyeKind)kind
{
	return kind == PDGoldenEyeRom ? sGeRom : kind == PDGoldenEyeHack ? sGeHack : sGeXbla;
}

+ (void)warmGoldenEyeScan:(void (^)(void))done
{
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		sGeQueue = dispatch_queue_create("pd.geplus.scan", DISPATCH_QUEUE_SERIAL);
	});
	(void)PDXbla.dropDir; // made here, on the main thread, before the queue reads it
	dispatch_async(sGeQueue, ^{
		NSTimeInterval t0 = NSDate.timeIntervalSinceReferenceDate;
		PDGoldenEyeFind *rom = nil, *xbla = nil, *hack = nil;
		pdScanGoldenEye(&rom, &xbla, &hack);
		NSTimeInterval took = NSDate.timeIntervalSinceReferenceDate - t0;
		dispatch_async(dispatch_get_main_queue(), ^{
			sGeRom = rom;
			sGeXbla = xbla;
			sGeHack = hack;
			NSLog(@"perfectdark: [geplus] scan (%.0f ms): rom=%@ | xbla=%@ | hack=%@",
				took * 1000.0, rom.rowText, xbla.rowText, hack.rowText);
			if (done) {
				done();
			}
		});
	});
}

+ (NSString *)goldenEyeProblemWithFile:(NSString *)path expecting:(PDGoldenEyeKind)kind
{
	NSError *err = nil;
	NSDictionary *a = [NSFileManager.defaultManager attributesOfItemAtPath:path error:&err];
	if (!a) {
		return [NSString stringWithFormat:@"The file could not be read (%@).", err.localizedDescription];
	}
	if ([a.fileType isEqualToString:NSFileTypeDirectory]) {
		return @"That is a folder. Pick the file itself.";
	}
	unsigned long long size = a.fileSize;
	NSData *hd = pdHead(path, 0x400);
	const uint8_t *h = hd.bytes;
	const BOOL n64 = hd.length >= 0x40 && (
		(h[0] == 0x80 && h[1] == 0x37 && h[2] == 0x12 && h[3] == 0x40) ||
		(h[0] == 0x37 && h[1] == 0x80 && h[2] == 0x40 && h[3] == 0x12) ||
		(h[0] == 0x40 && h[1] == 0x12 && h[2] == 0x37 && h[3] == 0x80));
	const BOOL stfs = hd.length >= 0x364 && (!memcmp(h, "LIVE", 4) || !memcmp(h, "CON ", 4) || !memcmp(h, "PIRS", 4));
	const BOOL geRom = n64 && pdIsGoldenEyeUsRom(path, size);
	const BOOL geXbla = !n64 && !stfs && (pdIsGoldenEyeArchive(path) || pdArchiveHoldsGoldenEyePackage(path));
	const BOOL gePackage = stfs && pdIsGoldenEyePackageFile(path);
	BOOL hackPatch = NO;
	const BOOL hack = !geRom && !stfs && pdIsHackSource(path, size, &hackPatch);

	if (kind == PDGoldenEyeHack) {
		if (hack) {
			return nil;
		}
		if (geRom) {
			return @"That is the GoldenEye 007 N64 ROM. Add it with the GoldenEye 007 ROM row.";
		}
		if (geXbla || gePackage) {
			return @"That is the GoldenEye XBLA release. Add it with the GoldenEye XBLA row.";
		}
		if (n64) {
			return @"That is an N64 ROM, but not Goldfinger 64.";
		}
		return @"That is not Goldfinger 64. It comes as goldfinger64.zip, as the patch inside it "
		        "(.xdelta), or as the Goldfinger 64 ROM already patched.";
	}
	if (hack) {
		return hackPatch ? @"That is a ROM patch. A GoldenEye ROM hack's patch (goldfinger64.zip, or the .xdelta in it) "
		                   "goes in with the Goldfinger 64 row."
		                 : @"That is Goldfinger 64, a GoldenEye ROM hack. Add it with the Goldfinger 64 row.";
	}

	if (kind == PDGoldenEyeRom) {
		if (geRom) {
			return nil;
		}
		if (geXbla) {
			return @"That is the GoldenEye XBLA release, not the N64 ROM. Add it with the GoldenEye XBLA row.";
		}
		if (n64) {
			// The cartridge name sits at 0x20 in .z64 order; a .v64/.n64 dump
			// is swapped, so look for the name both ways round before saying
			// which game it is.
			NSString *name = [[NSString alloc] initWithBytes:h + 0x20 length:20 encoding:NSASCIIStringEncoding];
			NSString *swapped = nil;
			uint8_t sw[20];
			for (int i = 0; i < 20; i += 2) { sw[i] = h[0x21 + i]; sw[i + 1] = h[0x20 + i]; }
			swapped = [[NSString alloc] initWithBytes:sw length:20 encoding:NSASCIIStringEncoding];
			NSString *both = [[name ?: @"" stringByAppendingString:swapped ?: @""] uppercaseString];
			if ([both containsString:@"GOLDENEYE"]) {
				return @"That is GoldenEye 007, but not the US cartridge, or a modified copy. "
				        "GE Plus is converted from GoldenEye 007 (U) only - the 12 MB US release, unchanged.";
			}
			if ([both containsString:@"PERFECT DARK"]) {
				return @"That is the Perfect Dark ROM. This row wants the GoldenEye 007 (US) N64 ROM.";
			}
			return @"That is an N64 ROM, but not GoldenEye 007 (US).";
		}
		return @"That is not an N64 ROM. GE Plus needs your own GoldenEye 007 (US) N64 ROM - "
		        ".z64, .n64 or .v64, 12 MB.";
	}

	// PDGoldenEyeXbla: the loose files or the Xbox 360 package, in a .7z/.zip or bare
	if (geXbla || gePackage) {
		return nil;
	}
	if (geRom) {
		return @"That is the GoldenEye 007 N64 ROM. Add it with the GoldenEye 007 ROM row.";
	}
	if (stfs) {
		if (!memcmp(h + 0x360, kTitlePerfectDark, 4)) {
			return @"That is Perfect Dark's Xbox 360 release. Add it with the Xbox 360 row above.";
		}
		if (!memcmp(h + 0x360, kTitleGoldenEye, 4)) {
			return @"That is GoldenEye XBLA's Xbox 360 package, but it is too small to be the whole "
			        "release - it may be cut short.";
		}
		return @"That is an Xbox 360 package, but not the GoldenEye XBLA release.";
	}
	if (n64) {
		return @"That is an N64 ROM. This row wants the GoldenEye XBLA release.";
	}
	NSString *ext = path.pathExtension.lowercaseString;
	if ([ext isEqualToString:@"rar"]) {
		return @"The game cannot look inside a .rar for this release - only a .7z or a .zip, or the "
		        "Xbox 360 package itself taken out of the .rar. If this is Perfect Dark's own Xbox 360 "
		        "release, add it with the Xbox 360 row above.";
	}
	if (pdIsArchiveExt(path) && archiveFindEntry(path.fileSystemRepresentation, kCeUpdateEntry.UTF8String)) {
		return @"That is the GoldenEye XBLA Community Edition updater, not the release itself. "
		        "Add the release here; the updater can go in the same added-content folder with the Files app.";
	}
	if (pdIsArchiveExt(path)) {
		return @"That archive does not hold the GoldenEye XBLA release (neither its files nor its "
		        "Xbox 360 package).";
	}
	return @"That is not the GoldenEye XBLA release. It comes as a .7z or a .zip, or as the "
	        "Xbox 360 package itself.";
}

+ (void)presentGoldenEyeImporter:(PDGoldenEyeKind)kind
                            from:(UIViewController *)vc
                            done:(void (^)(NSString *, NSString *))done
{
	PDXblaPickerDelegate *keep = sPickerDelegate = [PDXblaPickerDelegate new];
	keep.picked = ^(NSURL *url) {
		if (!url) {
			done(nil, @"");
			return;
		}
		[PDXbla adoptGoldenEye:kind pickedURL:url done:done];
	};
	UIDocumentPickerViewController *p =
		[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeItem ] asCopy:YES];
	p.delegate = keep;
	p.allowsMultipleSelection = NO;
	[vc presentViewController:p animated:YES completion:nil];
	NSLog(@"perfectdark: [geplus] presenting the document picker (%@)",
		kind == PDGoldenEyeRom ? @"rom" : kind == PDGoldenEyeHack ? @"hack" : @"xbla");
}

+ (void)adoptGoldenEye:(PDGoldenEyeKind)kind
             pickedURL:(NSURL *)url
                  done:(void (^)(NSString *, NSString *))done
{
	NSString *what = kind == PDGoldenEyeRom ? @"GoldenEye 007 ROM"
		: kind == PDGoldenEyeHack ? @"Goldfinger 64 file" : @"GoldenEye XBLA release";
	BOOL scoped = [url startAccessingSecurityScopedResource];
	NSString *problem = [self goldenEyeProblemWithFile:url.path expecting:kind];
	NSLog(@"perfectdark: [geplus] picked %@ for the %@ row: %@", url.lastPathComponent,
		kind == PDGoldenEyeRom ? @"rom" : kind == PDGoldenEyeHack ? @"hack" : @"xbla", problem ?: @"accepted");
	if (problem) {
		if (scoped) {
			[url stopAccessingSecurityScopedResource];
		}
		done([NSString stringWithFormat:@"Not the %@", what], [problem stringByAppendingString:@" Nothing was added."]);
		return;
	}

	// The one this replaces: the file of the same kind the scan found, which the
	// engine would otherwise go on taking first. Removed only after the new copy
	// is safely in, and only when it is not the very file being picked.
	PDGoldenEyeFind *old = [self cachedGoldenEye:kind];
	if (!old) {
		// the background scan has not landed yet: this one is the player's own
		// action, so it may wait for the answer
		PDGoldenEyeFind *rom = nil, *xbla = nil, *hack = nil;
		pdScanGoldenEye(&rom, &xbla, &hack);
		old = kind == PDGoldenEyeRom ? rom : kind == PDGoldenEyeHack ? hack : xbla;
	}
	// Never over the top of a file of another kind that happens to share the
	// name: the copy gets a name of its own instead ("name 2.7z").
	NSString *name = url.lastPathComponent;
	NSString *want = [self.dropDir stringByAppendingPathComponent:name];
	// (The file at that name being the very one picked is not a clash either:
	// the copy below sees that and leaves it alone.)
	for (int n = 2; [NSFileManager.defaultManager fileExistsAtPath:want]
	                && !(old.found && [old.path isEqualToString:want])
	                && !pdSameFile(url.path, want); n++) {
		NSString *ext = url.pathExtension;
		NSString *stem = [url.lastPathComponent stringByDeletingPathExtension];
		name = ext.length ? [NSString stringWithFormat:@"%@ %d.%@", stem, n, ext]
		                  : [NSString stringWithFormat:@"%@ %d", stem, n];
		want = [self.dropDir stringByAppendingPathComponent:name];
	}
	NSError *err = nil;
	BOOL same = NO;
	NSString *dst = [self adoptPickedURL:url name:name same:&same error:&err];
	if (scoped) {
		[url stopAccessingSecurityScopedResource];
	}
	if (!dst) {
		NSString *kept = old.found ? [NSString stringWithFormat:@" %@ is still there, unchanged.", old.relativePath] : @"";
		done(@"Could not add it", [NSString stringWithFormat:@"The file could not be copied in (%@).%@",
			err.localizedDescription, kept]);
		return;
	}
	if (same) {
		// The file picked is the one already in added-content/: nothing was
		// copied, so nothing is replaced and the unpack it made stays valid.
		NSLog(@"perfectdark: [geplus] %@ is already in place", dst);
		[self warmGoldenEyeScan:^{
			done([NSString stringWithFormat:@"%@ already added", what],
				[NSString stringWithFormat:@"%@ is already in added-content. Nothing was changed.",
					dst.lastPathComponent]);
		}];
		return;
	}
	// The old file of the same kind goes only now, with the new one complete and
	// in place under its own name (D-075).
	NSString *replaced = nil;
	if (old.found && !old.isFolder && ![old.path isEqualToString:dst]
	    && [NSFileManager.defaultManager fileExistsAtPath:old.path]) {
		[NSFileManager.defaultManager removeItemAtPath:old.path error:NULL];
		replaced = old.relativePath;
		NSLog(@"perfectdark: [geplus] replaced %@", old.path);
	} else if (old.found && [old.path isEqualToString:dst]) {
		replaced = old.relativePath;   // same name, swapped in place by the rename
		NSLog(@"perfectdark: [geplus] replaced %@ in place", dst);
	}
	if (kind == PDGoldenEyeXbla) {
		// A different copy of the release must be unpacked again; the old cache
		// is the game's own and regenerable (Caches).
		[NSFileManager.defaultManager removeItemAtPath:pdGeCacheDir() error:NULL];
	}
	NSLog(@"perfectdark: [geplus] added %@", dst);

	NSString *msg;
	if (kind == PDGoldenEyeRom) {
		msg = @"The next time you open the app, GoldenEye's missions and arenas are converted from it "
		       "(a few seconds, once). Then choose GE Plus in the Perfect Menu.";
	} else if (kind == PDGoldenEyeHack) {
		msg = @"The next time you open the app, Goldfinger 64's missions and arenas are converted from it "
		       "(a few seconds, once). Then choose Goldfinger 64 in the Perfect Menu.";
		BOOL isPatch = NO;
		pdIsHackSource(dst, [NSFileManager.defaultManager attributesOfItemAtPath:dst error:NULL].fileSize, &isPatch);
		if (isPatch && !sGeRom.found) {
			msg = [msg stringByAppendingString:@" The patch is applied to your GoldenEye 007 (US) ROM, so add "
			                                    "that too with the GoldenEye 007 ROM row."];
		}
	} else {
		msg = @"The next time you open the app it is unpacked once into the app's Caches folder "
		       "(about 400 MB written; keep 1 GB free). GE Plus then draws GoldenEye's HD art "
		       "whenever the Xbox 360 switch is on.";
	}
	if (replaced) {
		msg = [NSString stringWithFormat:@"It replaces %@. %@", replaced, msg];
	}
	[self warmGoldenEyeScan:^{
		done([NSString stringWithFormat:@"%@ added", what], msg);
	}];
}

/**
 * Overlay 0046's free-space question, asked by the engine before the GoldenEye
 * XBLA package form is unpacked: the volume's capacity for important use, which
 * counts what the system will purge from other apps to make room. -1 when it
 * cannot be told (the engine then goes ahead and lets a write fail).
 *
 * Dev builds only: PD_FAKE_FREE_MB in the launch environment answers that many
 * MB instead, so the refusal can be shown on a simulator with a full-size disk.
 */
long long pdIosAvailableBytes(const char *path)
{
#ifndef PD_PUBLIC
	const char *fake = getenv("PD_FAKE_FREE_MB");
	if (fake && *fake) {
		NSLog(@"perfectdark: [geplus] free space faked at %s MB (PD_FAKE_FREE_MB)", fake);
		return atoll(fake) << 20;
	}
#endif
	@autoreleasepool {
		NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path] isDirectory:YES];
		NSNumber *n = nil;
		NSError *err = nil;
		if (![url getResourceValue:&n forKey:NSURLVolumeAvailableCapacityForImportantUsageKey error:&err] || !n) {
			NSLog(@"perfectdark: [geplus] free space unknown at %s (%@)", path, err.localizedDescription);
			return -1;
		}
		NSLog(@"perfectdark: [geplus] free space for important use: %lld MB", n.longLongValue >> 20);
		return n.longLongValue;
	}
}

+ (NSString *)goldenEyeStateLines
{
	NSMutableString *s = [NSMutableString string];
	if (!sGeRom || !sGeXbla || !sGeHack) {
		[s appendString:@"ge_scan=pending\n"];
		return s;
	}
	NSArray *pairs = @[ @[ @"ge_rom", sGeRom ], @[ @"ge_xbla", sGeXbla ], @[ @"ge_hack", sGeHack ] ];
	for (NSArray *pair in pairs) {
		NSString *k = pair[0];
		PDGoldenEyeFind *f = pair[1];
		[s appendFormat:@"%@_found=%d\n%@_file=%@\n%@_ready=%d\n%@_row=%@\n",
			k, (int)f.found, k, f.relativePath ?: @"-", k, (int)f.ready, k, f.rowText];
		if (f.kind == PDGoldenEyeHack) {
			[s appendFormat:@"ge_hack_form=%@\n", !f.found ? @"none" : f.isPatch ? @"patch" : @"rom"];
		}
		if (f.kind == PDGoldenEyeXbla) {
			[s appendFormat:@"ge_xbla_form=%@\nge_xbla_need_mb=%d\nge_xbla_switch=%d\n",
				!f.found ? @"none" : f.isFolder ? @"folder" : f.isPackage ? @"package" : @"archive", f.needMb,
				(int)PDDefBool(PDDefXblaGoldenEye)];
		}
	}
	return s;
}

@end
