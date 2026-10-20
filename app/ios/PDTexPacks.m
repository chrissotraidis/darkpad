// PDTexPacks.m — see the header for why this exists at all.
#import "PDTexPacks.h"
#import "PDShell.h"
#import "PDXbla.h"

// upstream's own name for the row-order marker (port/src/texpack.c, and
// CLAUDE-notes/texture-packs.md). A folder called `ext_tex` says the same
// thing by its name and needs no file.
static NSString *const kMarkerName = @"bottomup.txt";
static NSString *const kSelfDescribingFolder = @"ext_tex";

// What archiveExtract() will take (port/src/archive.c's archiveIsSupported()).
static BOOL pdIsArchive(NSString *name)
{
	NSString *ext = name.pathExtension.lowercaseString;
	return [ext isEqualToString:@"zip"] || [ext isEqualToString:@"7z"]
	    || [ext isEqualToString:@"rar"] || [ext isEqualToString:@"pk3"];
}

@implementation PDTexPacks

+ (NSString *)dropDir
{
	NSString *dir = [PDShell.shared.documentsPath stringByAppendingPathComponent:@"texture-packs"];
	[NSFileManager.defaultManager createDirectoryAtPath:dir
	                        withIntermediateDirectories:YES attributes:nil error:NULL];
	return dir;
}

+ (NSArray<NSString *> *)entriesIn:(NSString *)dir
{
	NSArray<NSString *> *all = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:NULL] ?: @[];
	NSMutableArray *out = [NSMutableArray array];
	for (NSString *n in all) {
		// A dot-prefixed name is the port's own convention for "not a pack"
		// (.cache, and the in-progress download community.c writes).
		if (![n hasPrefix:@"."]) {
			[out addObject:n];
		}
	}
	return [out sortedArrayUsingSelector:@selector(compare:)];
}

+ (NSArray<NSString *> *)installedPacks
{
	NSString *dir = self.dropDir;
	NSMutableArray *out = [NSMutableArray array];
	for (NSString *n in [self entriesIn:dir]) {
		BOOL isDir = NO;
		if ([NSFileManager.defaultManager fileExistsAtPath:[dir stringByAppendingPathComponent:n]
		                                       isDirectory:&isDir] && isDir) {
			[out addObject:n];
		}
	}
	return out;
}

+ (nullable NSString *)preferredPack
{
	return self.installedPacks.firstObject;
}

// The first line of every marker this file writes - how a marker that is OURS
// is told from one Community Packs or the player wrote (D-090).
static NSString *const kOurMarkerHead = @"Written by Perfect Dark for iOS.";

/**
 * Whether one folder name says "a Plus HD pack from v0.10 on", which is stored
 * the RIGHT way up (upstream community.c: bottomUp 0 for all three; the note
 * in CLAUDE-notes/texture-packs.md). v0.10 split the release into Ultimate,
 * XBLA and Forever Plus HD - names that did not exist before it - and
 * Community Packs installs as "<name> v0.NN". v0.09 and earlier were one pack,
 * "PD Plus HD", in N64 order, and still get the marker.
 */
static BOOL pdNameIsRightWayUpPlusHd(NSString *name)
{
	// "_" and "-" are the separators a hand-renamed folder uses ("PD_Plus_HD_v0.11")
	NSString *n = [[name.lowercaseString stringByReplacingOccurrencesOfString:@"_" withString:@" "]
	               stringByReplacingOccurrencesOfString:@"-" withString:@" "];
	if ([n rangeOfString:@"plus hd"].location == NSNotFound
	 && [n rangeOfString:@"plushd"].location == NSNotFound
	 && [n rangeOfString:@"plus.hd"].location == NSNotFound) {
		return NO;
	}
	for (NSString *family in @[ @"ultimate", @"xbla", @"forever" ]) {
		if ([n rangeOfString:family].location != NSNotFound) {
			return YES;
		}
	}
	NSRegularExpression *re = [NSRegularExpression
		regularExpressionWithPattern:@"(?:^|[^\\d.])v?(\\d+)\\.(\\d+)" options:0 error:NULL];
	NSTextCheckingResult *m = [re firstMatchInString:n options:0 range:NSMakeRange(0, n.length)];
	if (m) {
		NSInteger major = [n substringWithRange:[m rangeAtIndex:1]].integerValue;
		NSInteger minor = [n substringWithRange:[m rangeAtIndex:2]].integerValue;
		return major > 0 || minor >= 10;
	}
	return NO;
}

/** The pack folder, or the one folder an archive put inside it, says v0.10+ Plus HD. */
+ (BOOL)packIsRightWayUp:(NSString *)dir named:(NSString *)name
{
	if (pdNameIsRightWayUpPlusHd(name)) {
		return YES;
	}
	for (NSString *sub in [self entriesIn:dir]) {
		BOOL isDir = NO;
		if ([NSFileManager.defaultManager fileExistsAtPath:[dir stringByAppendingPathComponent:sub]
		                                       isDirectory:&isDir] && isDir
		    && pdNameIsRightWayUpPlusHd(sub)) {
			return YES;
		}
	}
	return NO;
}

/**
 * Remove a marker this shell wrote into a pack stored the right way up (the
 * 1.0.1 - 1.0.1.8 shell marked every pack, D-090). Only our own marker: one
 * Community Packs or the player wrote is theirs to keep.
 */
+ (BOOL)unmarkOurMarkerIn:(NSString *)dir
{
	NSString *marker = [dir stringByAppendingPathComponent:kMarkerName];
	NSString *text = [NSString stringWithContentsOfFile:marker encoding:NSUTF8StringEncoding error:NULL];
	if (![text hasPrefix:kOurMarkerHead]) {
		return NO;
	}
	NSError *err = nil;
	if (![NSFileManager.defaultManager removeItemAtPath:marker error:&err]) {
		NSLog(@"perfectdark: [texpack] could not remove %@: %@", marker, err);
		return NO;
	}
	return YES;
}

/** Write the row-order marker into a pack folder that has none. */
+ (BOOL)markFolder:(NSString *)dir named:(NSString *)name
{
	if ([name.lowercaseString isEqualToString:kSelfDescribingFolder]) {
		return NO;   // the loader reads the name itself
	}
	NSString *marker = [dir stringByAppendingPathComponent:kMarkerName];
	if ([NSFileManager.defaultManager fileExistsAtPath:marker]) {
		return NO;
	}
	NSString *text = [kOurMarkerHead stringByAppendingString:@"\n"
		 "\n"
		 "This file tells the game the pack's images are already in N64 row\n"
		 "order (bottom row first) and must not be turned over on load. Every\n"
		 "pack built for an emulator or the VR fork is - and a pack that\n"
		 "reached this phone came from one of those, because the port's own\n"
		 "dumps are the only ones the other way up and the asset dump is not\n"
		 "available on iOS.\n"
		 "\n"
		 "If this pack draws upside down, delete this file.\n"];
	NSError *err = nil;
	if (![text writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:&err]) {
		NSLog(@"perfectdark: [texpack] could not write %@: %@", marker, err);
		return NO;
	}
	return YES;
}

+ (NSArray<NSString *> *)prepare
{
	NSAssert(NSThread.isMainThread, @"pre-engine, UIKit's thread");

	NSString *dir = self.dropDir;
	NSMutableArray<NSString *> *log = [NSMutableArray array];

	// 1. Unpack anything new. The archive is KEPT (ground rule 5: never delete
	//    the player's files) and a dot-prefixed marker beside it records that
	//    it has been done, so the next launch is a stat rather than 180 MB.
	for (NSString *name in [self entriesIn:dir]) {
		if (!pdIsArchive(name)) {
			continue;
		}
		NSString *src = [dir stringByAppendingPathComponent:name];
		NSString *done = [dir stringByAppendingPathComponent:
			[NSString stringWithFormat:@".%@.installed", name]];
		if ([NSFileManager.defaultManager fileExistsAtPath:done]) {
			continue;
		}

		unsigned long long bytes = [[NSFileManager.defaultManager
			attributesOfItemAtPath:src error:NULL][NSFileSize] unsignedLongLongValue];
		NSLog(@"perfectdark: [texpack] unpacking %@ (%llu bytes) into %@", name, bytes, dir);
		[PDXbla showPreparingNote:[NSString stringWithFormat:@"Unpacking the texture pack\n%@", name]];

		__block BOOL ok = NO;
		__block BOOL running = YES;
		NSThread *t = [[NSThread alloc] initWithBlock:^{
			// Absolute paths go through fsFullPath() untouched (fs.c:115), so
			// this needs no fsInit() - the same property D-020 leans on.
			ok = archiveExtract(src.fileSystemRepresentation, dir.fileSystemRepresentation) > 0;
			running = NO;
		}];
		t.name = @"pd-texpack-unpack";
		t.qualityOfService = NSQualityOfServiceUserInitiated;
		[t start];

		NSTimeInterval started = NSDate.timeIntervalSinceReferenceDate;
		while (running) {
			@autoreleasepool {
				[NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode
				                    beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
			}
		}
		NSTimeInterval secs = NSDate.timeIntervalSinceReferenceDate - started;
		[PDXbla hidePreparingNote];

		if (ok) {
			[@"" writeToFile:done atomically:YES encoding:NSUTF8StringEncoding error:NULL];
			[log addObject:[NSString stringWithFormat:@"unpacked %@ in %.1fs", name, secs]];
		} else {
			[log addObject:[NSString stringWithFormat:@"FAILED to unpack %@", name]];
		}
		NSLog(@"perfectdark: [texpack] %@", log.lastObject);
	}

	// 2. The marker. This is the whole reason the shell is involved at all:
	//    without it every texture in the pack is upside down and nothing on
	//    disk says why (upstream's texture-packs.md).
	//    NOT every pack: the Plus HD packs from v0.10 on are stored the right
	//    way up and Community Packs leaves them unmarked on purpose; marking
	//    one turned every texture in it over (D-090). Undo our own marker in
	//    one, from the shells that did.
	for (NSString *name in self.installedPacks) {
		NSString *packDir = [dir stringByAppendingPathComponent:name];
		if ([self packIsRightWayUp:packDir named:name]) {
			if ([self unmarkOurMarkerIn:packDir]) {
				[log addObject:[NSString stringWithFormat:@"removed our %@ from %@ (stored the right way up)",
				                kMarkerName, name]];
				NSLog(@"perfectdark: [texpack] %@", log.lastObject);
			}
			continue;
		}
		if ([self markFolder:packDir named:name]) {
			[log addObject:[NSString stringWithFormat:@"wrote %@ into %@", kMarkerName, name]];
			NSLog(@"perfectdark: [texpack] %@", log.lastObject);
		}
	}

	return log;
}

@end
