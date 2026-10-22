// PDAudio.h — the audio session policy, the master gain, and keeping both.
//
// Two problems, one file.
//
// 1. THE CATEGORY. SDL opens its own AVAudioSession and configures it as
//    `.ambient`, which the Ring/Silent switch silences. A game whose music
//    stops because the phone is on silent reads as "no audio on iOS" and is
//    reported as a port bug every time. `.playback` is the category a game
//    wants, and it has to be RE-ASSERTED rather than set once, because SDL
//    reconfigures the session whenever it opens or reopens a device - which it
//    does on route changes, interruptions and its own device-lost recovery,
//    none of which the shell is told about.
//
// 2. WHAT HAPPENS TO THE PODCAST. The category is not just playback-or-not: its
//    OPTIONS decide whether the player's music keeps going, ducks, or stops
//    when the game starts. GoldenEye ships the family's five-mode choice for
//    this (ui/audio_session_uikit.mm) and it is the setting phone players
//    actually ask for; the names and the one-sentence explanations here are
//    that port's, verbatim, so the two apps say the same words (D-033).
//
// The two modes that attenuate the GAME rather than the other app cannot be
// done with a category at all - the system has no "duck me" - so they are a
// gain the mixer applies. That is the same gain the Volume and Mute rows use:
// pdPlatformAudioGain() (overlay 0023) multiplies it into the s16 buffer just
// before SDL_QueueAudio.
//
// Threading, paid for in round B: the game runs on the MAIN thread here (SDL's
// UIKit entry), so a main-run-loop timer doing AVAudioSession round trips is a
// timer doing them inside the frame. Everything periodic in this file runs on
// its own serial queue, and the notification observers do too.
#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PDAudio : NSObject

/** Apply the stored policy now and keep re-asserting it. Main thread. */
+ (void)begin;

/**
 * The mode changed: re-apply the session AND recompute the gain. Any thread;
 * the session work is done on PDAudio's own queue.
 */
+ (void)settingsChanged;

/**
 * Only the volume or the mute moved: recompute the gain and touch nothing else.
 *
 * A dragged slider samples sixty times a second and an AVAudioSession round
 * trip per sample is not free; this is one atomic store, so the sound follows
 * the thumb instead of the settings page's 0.4 s coalescing timer.
 */
+ (void)gainChanged;

/**
 * visionOS only: the picture is world-locked, so the sound should be too.
 *
 * ON  = `.headTracked(soundStageSize: .medium, anchoringStrategy: .front)`, so
 *       the mix stays where the panel is when the player turns their head.
 * OFF = `.automatic`, the windowed default.
 *
 * Re-applied on every session poll while it is on, because SDL's CoreAudio
 * backend reconfigures the session whenever it opens a device and drops the
 * spatial intent silently when it does (playbook §2.10: the symptom is "audio
 * coming from the parked window's direction"). No-op on iOS.
 */
+ (void)setImmersive:(BOOL)immersive;

/** The five mode names, index == the stored mode. bean's words. */
+ (NSArray<NSString *> *)modeTitles;

/** One sentence per mode, for the picker. bean's words, our game's name. */
+ (NSArray<NSString *> *)modeDetails;

/** `audio_*` lines for the bridge's `state`. */
+ (NSString *)stateLines;

/** Zero the queue counters so a measurement window measures one thing. */
+ (void)statsReset;

@end

/**
 * The engine's hook (overlay 0023, weak there, strong here).
 *
 * Master volume x mute x the other-app duck, as one multiplier on the frame's
 * samples. Called on the game thread once per frame; a plain atomic load.
 */
float pdPlatformAudioGain(void);

NS_ASSUME_NONNULL_END
