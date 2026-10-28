// PDOnboarding.h — "drop your ROM here", and the classifier behind it.
#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, PDRomVerdict) {
	PDRomAccepted,        // Perfect Dark (USA) (Rev 1) — "ntsc-final"
	PDRomWrongRegionPAL,
	PDRomWrongRegionJPN,
	PDRomWrongRevision,   // USA v1.0
	PDRomByteSwapped,     // .v64 / .n64 byte order
	PDRomWrongSize,
	PDRomNotARom,
	PDRomUnreadable,
	PDRomContentMismatch, // Header matches, but data differs from supported US Rev 1.
};

@interface PDRomCheck : NSObject
@property (nonatomic) PDRomVerdict verdict;
@property (nonatomic, copy) NSString *md5;
@property (nonatomic, copy) NSString *explanation;   // in words, for the player
@property (nonatomic, readonly) BOOL ok;
@end

@interface PDOnboarding : NSObject

/** Classify a candidate file. Reads it once; safe on any thread. */
+ (PDRomCheck *)classifyFileAtPath:(NSString *)path;
/** As classifyFileAtPath:, but a .v64/.n64 dump is checked as a temporary .z64
    copy; *usable is the file to install (the original or that copy). */
+ (PDRomCheck *)checkRomAtPath:(NSString *)path usable:(NSString *_Nullable *_Nonnull)usable;

/** The ROM the engine will load, if a valid one is already in place. */
+ (nullable NSString *)installedRomPath;

/**
 * If no valid ROM is present, put the onboarding screen up and spin the run
 * loop until one is. Returns when the engine may start. Main thread, called
 * before pdEngineMain().
 */
+ (void)runUntilRomPresent;

@end

NS_ASSUME_NONNULL_END
