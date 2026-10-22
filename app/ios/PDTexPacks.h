// PDTexPacks.h — a texture pack that arrived through the Files app.
//
// On a desktop a pack is installed from inside the game: Extended Options ->
// Texture Packs -> Community Packs downloads it, unpacks it, and — the part
// that matters — writes the row-order marker into the folder it just made
// (upstream's CLAUDE-notes/texture-packs.md, "The marker is the point").
//
// On a phone the pack arrives a completely different way: the player drops a
// zip into Files -> Perfect Dark -> texture-packs. Nothing unpacks it and
// nothing writes the marker, and a pack without one is drawn UPSIDE DOWN in
// every texture, with nothing on disk to say why. PD Plus HD is exactly this
// case: its top folder used to be called `ext_tex`, which the loader
// recognises by itself, and v0.09 renamed it to `PD Plus HD`.
//
// So this file is the Files-drop half of that installer:
//
//   * unpack an archive dropped in texture-packs/ into a folder beside it,
//     once, the way communityInstall() does;
//   * write `bottomup.txt` at the top of any pack folder that has no marker
//     and is not called `ext_tex`, because a pack that reaches a phone was
//     built for an emulator or the VR fork — the only packs in the port's own
//     row order are its own dumps, and Dump All Assets is on the iOS deadlist;
//     EXCEPT a Plus HD pack from v0.10 on (Ultimate / XBLA / Forever Plus HD),
//     which is stored the right way up and which Community Packs leaves
//     unmarked on purpose - marking one turns every texture over (D-090), so
//     those are skipped and a marker of OURS found in one is removed;
//   * select a pack if one is present and none is selected, since a player who
//     dropped a pack into Files has already said what they want.
//
// Everything here runs BEFORE pdEngineMain(), beside the XBLA unpack (D-020),
// for the same reason: the engine's first texture load must find a finished
// folder, not one being written under it.
#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PDTexPacks : NSObject

/** Documents/texture-packs, created if it is not there. */
+ (NSString *)dropDir;

/** Pack folder names currently on disk (top level, dot-files skipped). */
+ (NSArray<NSString *> *)installedPacks;

/**
 * Unpack anything new, write missing row-order markers, and report what it
 * did, one line per action (empty when there was nothing to do). Pre-engine,
 * main thread; blocks while an archive extracts, with the run loop spun.
 */
+ (NSArray<NSString *> *)prepare;

/** The name the shell would select — a pack folder, or nil. */
+ (nullable NSString *)preferredPack;

@end

NS_ASSUME_NONNULL_END
