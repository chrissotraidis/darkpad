// PDXbla.h — the Xbox 360 (XBLA) release on a phone: find it, say what it is,
// unpack it once, and show that happening.
//
// The engine already knows how to do all of this (port/src/xblaimport.c, and
// upstream's CLAUDE-notes/xbla.md). What it does not have is a way to tell a
// player *before* the game starts that the 227 MB file they just dropped into
// Files was recognised, what will happen to it, and roughly how long the one
// stall of their lives is going to be. On a desktop that stall is three seconds
// behind a menu the player opened on purpose; on a phone it is the first launch
// after a Files drop, and it must not look like a hang.
//
// So this file is two halves:
//
//   * a scan of Documents/xbla that mirrors the engine's own
//     (xblaDetect()/xblaScanDir(): a package by its magic, an archive by its
//     extension, either of them inside a folder, to overlay patch 0001's depth
//     of 4) and can run with no engine at all - which is what the onboarding
//     screen needs, since it runs before pdEngineMain();
//   * the unpack, driven from a background thread through the engine's own
//     xblaImportGetStfsPath(). That call blocks for the whole extraction, and
//     upstream calls it from exactly such a thread already (xblaImportWorker),
//     so this is upstream's own concurrency and not a new one. Doing it here
//     rather than leaving it to the first model load means the game thread is
//     never the one standing in the unpack, and there is a visible "preparing"
//     state instead of a frozen frame.
#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, PDXblaKind) {
	PDXblaNone = 0,
	PDXblaArchiveRar,     // Perfect Dark.rar — the user's copy, and the common one
	PDXblaArchive7z,      // the .7z upstream's own message names
	PDXblaArchiveOther,   // .zip / .pk3 — archiveIsSupported() takes these too
	PDXblaPackage,        // the bare STFS container: LIVE / CON  / PIRS
};

@interface PDXblaFind : NSObject
@property (nonatomic) PDXblaKind kind;
@property (nonatomic, copy, nullable) NSString *path;          // absolute
@property (nonatomic, copy, nullable) NSString *relativePath;  // under added-content/ (or the legacy xbla/)
@property (nonatomic) unsigned long long bytes;
@property (nonatomic, readonly) BOOL found;
/** One line naming what was found, for a label. */
@property (nonatomic, readonly) NSString *headline;
/** What will happen to it, in words. Includes the D-011 free-space note. */
@property (nonatomic, readonly) NSString *plan;
@end

@interface PDXbla : NSObject

/**
 * The pre-engine "preparing…" note, over SDL's window.
 *
 * Public because the texture-pack unpack (PDTexPacks) needs exactly the same
 * thing for exactly the same reason, and a second window class that looked the
 * same and behaved slightly differently is how two progress screens end up
 * fighting over the same key window.
 */
+ (void)showPreparingNote:(NSString *)text;
+ (void)hidePreparingNote;

/** Documents/added-content, created if it is not there. The engine makes it too (fs.c). */
+ (NSString *)dropDir;

/**
 * Copy `src` over `dst` without ever putting what is already at `dst` at risk
 * (D-075). The copy goes to a hidden temporary name beside `dst` first
 * (".pd-adding-<uuid>.partial", which every scan - the engine's and the
 * shell's - passes over because of its leading dot), and only a copy that
 * finished is renamed over `dst`, atomically. On any failure the temporary
 * file is removed and `dst` is exactly as it was.
 *
 * When `src` and `dst` are already the same file nothing is touched: the result
 * is YES and `*same` (if given) is set.
 */
+ (BOOL)copyFileSafely:(NSString *)src
                    to:(NSString *)dst
                  same:(BOOL *_Nullable)same
                 error:(NSError *_Nullable *_Nullable)err;

/**
 * Remove the temporary files of copies that never finished (the app was killed
 * mid-copy) from added-content/ and Documents. Main thread, at launch, before
 * anything can be copying.
 */
+ (void)sweepPartialCopies;

#ifndef PD_PUBLIC
/**
 * Test hook for the bridge (`adopt fail copy|swap|off`): the NEXT
 * +copyFileSafely:… fails at that stage. "copy" leaves a half-written temporary
 * file and reports ENOSPC, as a copy that ran out of space would; "swap" lets
 * the copy finish and refuses the rename. Compiled out of public builds.
 */
+ (void)failNextCopyAt:(nullable NSString *)stage;
#endif

/** Caches/xbla — where patch 0009 routes the engine's cache/ to. */
+ (NSString *)cacheDir;

/** Scan Documents/xbla the way the engine does. No engine needed. */
+ (PDXblaFind *)scan;

/**
 * The last scan, re-run only when something could have changed.
 *
 * -scan walks Documents/xbla recursively and reads an archive header off disk,
 * and the settings page's Package row asked for one on EVERY dequeue of that
 * cell - so scrolling the page re-scanned a 250 MB drop directory once a row
 * (D-032). The result is cached and invalidated by the two things that can move
 * it: an import, and a redetect.
 */
+ (PDXblaFind *)cachedScan;

/** Forget the cached scan (an import finished, or the engine redetected). */
+ (void)invalidateScan;

/** A finished unpack: the `.extracted` marker AND a package beside it. */
+ (BOOL)isUnpacked;

/** A package the player dropped that is still inside its archive. */
+ (BOOL)needsUnpack;

/**
 * Start the one-time unpack on a background thread if one is needed, and put
 * the "preparing XBLA art…" note up while it runs. Idempotent, and a no-op
 * when there is nothing to unpack or one is already running. Game thread
 * (the frame hook) - it needs the engine up, because it is the engine's own
 * fsInit() that knows where cache/ went.
 */
+ (void)beginUnpackIfNeeded;

/**
 * The first-launch unpack, done BEFORE pdEngineMain() and with a progress
 * screen up (D-020).
 *
 * Upstream's own rule is that the game stays usable while this happens, and on
 * a desktop it does: the extraction is on the texture converter's worker
 * thread behind a menu the player opened. On iOS it is not: with Mod.XblaMeshes
 * on and a package present, the FIRST MODEL LOAD of the front end calls
 * xblaImportGetStfsPath(), which blocks - on the game thread, which is the main
 * thread, which is the one UIKit draws and pumps from. Nothing can be shown
 * while that runs, so the player gets a frozen frame and no explanation.
 *
 * So the shell gets there first. Returns when there is nothing left to unpack;
 * a no-op on every launch after the first.
 */
+ (void)runUnpackUntilReady;

@property (class, readonly) BOOL unpacking;
@property (class, readonly) NSTimeInterval unpackElapsed;
/** 0-100, from the bytes on disk against the archive's size. -1 when idle. */
@property (class, readonly) int unpackPercent;
/** Seconds the last completed unpack took, or 0. */
@property (class, readonly) NSTimeInterval lastUnpackSeconds;

/** `xbla_*` lines for the bridge's `state` (docs/remote-console.md). */
+ (NSString *)stateLines;

/**
 * A Files document picker that copies an archive or a package into
 * Documents/xbla. Presented from `vc`; `done` runs on the main thread with the
 * fresh scan, whether or not anything was picked.
 */
+ (void)presentImporterFrom:(UIViewController *)vc done:(void (^_Nullable)(PDXblaFind *))done;

/**
 * The importer's own copy: `url` into added-content/ under its own name,
 * replacing a file of that name only once the copy is complete (D-075).
 * Returns the path, or nil with `err` set and nothing changed. Public so the
 * bridge's `xbla pick <path>` can drive exactly this path on a simulator.
 */
+ (nullable NSString *)adoptPickedURL:(NSURL *)url error:(NSError *_Nullable *_Nullable)err;

@end

// ---------------------------------------------------------------------------
// GE Plus's optional files, which share added-content/ with the release
// above (D-071, D-072). The engine finds them by their contents, at startup:
//
//   * a GoldenEye 007 (US) N64 ROM - port/src/gexplusrom.c, top level of
//     added-content/ (or the base dir, from which it is moved in), 12 MB,
//     header and CRCs checked by geconvertHeaderIsGoldenEyeUs();
//   * the GoldenEye XBLA release - port/src/gebean.c, a folder holding
//     files/new/char, or a .7z/.zip with an entry under files/new/char/; or
//     (overlay 0046) the same release as the Xbox 360 package (STFS, title
//     584108A9), bare, in a folder, or in a .7z/.zip - four levels deep in
//     added-content/ (then the legacy xbla/).
//   * a GoldenEye ROM hack the converter knows (Goldfinger 64) - gexplusrom.c's
//     variants: the hack's ROM patched already (either byte order), its patch
//     (.xdelta/.vcdiff/.bps/.ips) or a .zip/.7z holding one, at the top level
//     of added-content/. A patch is applied to the GoldenEye ROM above.
//
// What changes takes effect at the NEXT launch: the conversion and the unpack
// run before the menus exist (main.c), and an iOS app cannot restart itself.

typedef NS_ENUM(NSInteger, PDGoldenEyeKind) {
	PDGoldenEyeRom = 0,
	PDGoldenEyeXbla = 1,
	PDGoldenEyeHack = 2,
};

@interface PDGoldenEyeFind : NSObject
@property (nonatomic) PDGoldenEyeKind kind;
@property (nonatomic, copy, nullable) NSString *path;          // absolute
@property (nonatomic, copy, nullable) NSString *relativePath;  // under added-content/
@property (nonatomic) unsigned long long bytes;                // 0 for a folder
@property (nonatomic) BOOL isFolder;                           // an unpacked release
@property (nonatomic) BOOL isPackage;                          // the Xbox 360 package form (bare, in a folder or archive)
@property (nonatomic) BOOL isPatch;                            // a ROM hack's patch (or an archive of one), not its ROM
@property (nonatomic) BOOL needsRom;                           // that patch, with no GoldenEye 007 ROM to apply it to
/** MB the engine's last unpack needed and did not find, and MB that were free (0 = no refusal). */
@property (nonatomic) int needMb;
@property (nonatomic) int freeMb;
/** The game has already made what it needs from it (arenas converted / release unpacked). */
@property (nonatomic) BOOL ready;
@property (nonatomic, readonly) BOOL found;
/** One line for the settings row: "name (12 MB), ready" or "none in Documents/added-content". */
@property (nonatomic, readonly) NSString *rowText;
@end

@interface PDXbla (GoldenEye)

/**
 * The last GoldenEye scan, or nil while the first one is still running. The
 * scan reads ROM headers and archive directories, so it never runs on the main
 * thread: +warmGoldenEyeScan: starts it on a background queue at launch and
 * after every import, and the settings page shows "checking…" until it lands.
 */
+ (nullable PDGoldenEyeFind *)cachedGoldenEye:(PDGoldenEyeKind)kind;

/** Rescan both in the background; `done` runs on the main thread. */
+ (void)warmGoldenEyeScan:(void (^_Nullable)(void))done;

/**
 * What the picked file is, in plain words, against the kind the row asked for.
 * nil = it is the right thing. Never touches added-content/.
 */
+ (nullable NSString *)goldenEyeProblemWithFile:(NSString *)path expecting:(PDGoldenEyeKind)kind;

/**
 * The Files picker for one of the two, through the same machinery as the
 * release's importer. `done` runs on the main thread with a title and a
 * message for the player (nil title = the picker was cancelled).
 */
+ (void)presentGoldenEyeImporter:(PDGoldenEyeKind)kind
                            from:(UIViewController *)vc
                            done:(void (^)(NSString *_Nullable title, NSString *message))done;

/**
 * The picker's own completion: validate `url`, and only if it is the right
 * thing copy it into added-content/, replacing the file of the same kind that
 * was there. Public so the bridge can drive exactly this path on a simulator,
 * where the real picker cannot be operated by injected touches.
 */
+ (void)adoptGoldenEye:(PDGoldenEyeKind)kind
             pickedURL:(NSURL *)url
                  done:(void (^)(NSString *_Nullable title, NSString *message))done;

/** `ge_*` lines for the bridge. Uses the cached scan; no I/O. */
+ (NSString *)goldenEyeStateLines;

@end

NS_ASSUME_NONNULL_END
