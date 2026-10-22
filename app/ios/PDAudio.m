// PDAudio.m — see PDAudio.h.
#import "PDAudio.h"
#import "PDDefaults.h"
#import "PDShell.h"
#import "PDPacing.h"

#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

#include <stdatomic.h>
#include <math.h>
#include <SDL_timer.h>

// How far the game drops in "Lower Game Audio" while the other app plays.
// bean's number (audio_session_uikit.mm), and there is no reason for two ports
// in the same family to disagree about it.
static const float kDuckGain = 0.22f;

/** Read by the game thread once a frame; written by PDAudio's own queue. */
static _Atomic(float) sGain = 1.0f;
/** The other-app half of it, kept separately so a volume change is independent. */
static _Atomic(float) sDuck = 1.0f;

static int sApplied;            // times the category/options were actually set
static NSString *sLastError;
static BOOL sArmed;             // the first apply has happened

float pdPlatformAudioGain(void)
{
	return atomic_load_explicit(&sGain, memory_order_relaxed);
}

/** PDAudio's own serial queue. Never the main (game) thread. */
static dispatch_queue_t pdAudioQueue(void)
{
	static dispatch_queue_t q;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		q = dispatch_queue_create("com.rebelancap.perfectdark.audio-session",
			dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
	});
	return q;
}

static int pdCurrentMode(void)
{
	NSInteger m = PDDefInt(PDDefAudioSessionMode);
	return (m < 0 || m > 4) ? 2 : (int)m;
}

/**
 * The category options each mode wants.
 *
 * Playback throughout: the game must keep sounding with the hardware silent
 * switch on, which Playback buys over Ambient; only the mixability bits differ.
 */
static AVAudioSessionCategoryOptions pdOptionsForMode(int mode)
{
	switch (mode) {
	case 0:  // Stop Other Audio: non-mixable, activation interrupts the other app
		return 0;
	case 2:  // Lower Other Audio
		return AVAudioSessionCategoryOptionMixWithOthers | AVAudioSessionCategoryOptionDuckOthers;
	default: // Play Both / Lower Game / Mute Game: we do our own attenuating
		return AVAudioSessionCategoryOptionMixWithOthers;
	}
}

static BOOL pdOtherAudioPlaying(AVAudioSession *s)
{
	// isOtherAudioPlaying is the broad "someone else has sound out";
	// secondaryAudioShouldBeSilencedHint is the narrower "another app is
	// playing PRIMARY audio". Either means the player is listening to something
	// that is not us.
	return s.isOtherAudioPlaying || s.secondaryAudioShouldBeSilencedHint;
}

/** Fold volume x mute x duck into the one number the engine reads. */
static void pdRecomputeGain(void)
{
	float g = PDDefBool(PDDefAudioMute) ? 0.0f : PDDefFloat(PDDefAudioMasterVolume);
	if (g < 0.0f) {
		g = 0.0f;
	} else if (g > 1.0f) {
		g = 1.0f;
	}
	g *= atomic_load_explicit(&sDuck, memory_order_relaxed);

	const float was = atomic_exchange_explicit(&sGain, g, memory_order_relaxed);
	if (fabsf(was - g) > 0.0005f) {
		NSLog(@"perfectdark: [audio] gain %.2f -> %.2f (volume %.2f, mute %d, duck %.2f)",
			was, g, PDDefFloat(PDDefAudioMasterVolume), (int)PDDefBool(PDDefAudioMute),
			atomic_load_explicit(&sDuck, memory_order_relaxed));
	}
}

/** The other-app half: only modes 3 and 4 attenuate US. PDAudio's queue. */
static void pdRecomputeDuck(AVAudioSession *s)
{
	const int mode = pdCurrentMode();
	float duck = 1.0f;
	if (pdOtherAudioPlaying(s)) {
		if (mode == 3) {
			duck = kDuckGain;   // Lower Game Audio
		} else if (mode == 4) {
			duck = 0.0f;        // Mute Game Audio
		}
	}
	atomic_store_explicit(&sDuck, duck, memory_order_relaxed);
	pdRecomputeGain();
}

#if TARGET_OS_VISION
// 1 while the immersive space is open. Read on PDAudio's queue, written from
// the game thread's transition — a plain int is enough for a flag whose only
// consumer re-reads it every second anyway.
static volatile int sImmersive = 0;
static int sSpatialApplied = 0;
static NSString *sSpatialError = nil;

/**
 * The spatial intent, applied and RE-applied. PDAudio's queue.
 *
 * There is no "is it still head-tracked" that is cheaper than setting it, and
 * setting it when it already is costs a property write, so this is called on
 * every poll rather than on change. `intendedSpatialExperience` is readable, so
 * the state row can say what the session actually thinks.
 */
static void pdApplySpatial(void)
{
	AVAudioSession *s = AVAudioSession.sharedInstance;
	// Head-tracked either way: OFF is not "no spatialisation" (that is
	// Bypassed, and it would make the windowed app sound flat), it is the
	// AUTOMATIC sound stage anchored the automatic way — the plan's
	// ".automatic/.automatic" — which is what a plain window gets.
	NSDictionary *opts = @{
		AVAudioSessionSpatialExperienceOptionSoundStageSize:
			@(sImmersive ? AVAudioSessionSoundStageSizeMedium
			             : AVAudioSessionSoundStageSizeAutomatic),
		AVAudioSessionSpatialExperienceOptionAnchoringStrategy:
			@(sImmersive ? AVAudioSessionAnchoringStrategyFront
			             : AVAudioSessionAnchoringStrategyAutomatic),
	};
	const int wantImm = sImmersive ? 1 : 0;
	NSError *err = nil;
	if ([s setIntendedSpatialExperience:AVAudioSessionSpatialExperienceHeadTracked
	                           options:opts error:&err]) {
		sSpatialError = nil;
		if (sSpatialApplied != wantImm + 1) {
			// Only the TRANSITIONS are logged: this runs once a second.
			NSLog(@"perfectdark: [audio] spatial experience -> headTracked(%s, %s)",
				sImmersive ? ".medium" : ".automatic", sImmersive ? ".front" : ".automatic");
		}
		sSpatialApplied = wantImm + 1;
	} else {
		sSpatialError = err.localizedDescription;
		NSLog(@"perfectdark: [audio] spatial experience REFUSED: %@", sSpatialError);
	}
}
#endif

// The stalled-device watch (overlay 0048). Restarts asked for, and the last log.
static int sKicks;
static int sKickLogged;
static unsigned int sKickAt;

/**
 * An audio interruption pauses SDL's AudioQueue, and SDL starts it again only
 * on the interruption's end or on the app becoming active - once; if that
 * AudioQueueStart fails (the session not active again yet) nothing retries, and
 * the game is silent while it keeps pushing. The engine says so: its burst drop
 * (overlay 0023) has lasted far longer than a device that plays ever lets it.
 * Then, with the app in the foreground and the session active, SDL is handed
 * the interruption's end once more - its own restart path, nothing else
 * listens for it from this session - at most every three seconds. On resume the
 * device plays the queue down and the engine resyncs once.
 */
static void pdKickStalledDevice(AVAudioSession *s)
{
	const unsigned int now = SDL_GetTicks();
	if (!g_PdAudioDropping || now - g_PdAudioDroppingSinceMs < 2000 || !pdIosPresentAllowed()
	    || (sKickAt && now - sKickAt < 3000)) {
		return;
	}
	NSError *err = nil;
	if (![s setActive:YES error:&err]) {
		sLastError = err.localizedDescription;
		return;   // still interrupted (a call): the next tick asks again
	}
	sKickAt = now;
	sKicks++;
	if (sKickLogged < 5) {
		sKickLogged++;
		NSLog(@"perfectdark: [audio] the device has not played for %u ms - restarting it (%d)",
			now - g_PdAudioDroppingSinceMs, sKicks);
	}
	[NSNotificationCenter.defaultCenter postNotificationName:AVAudioSessionInterruptionNotification
		object:s userInfo:@{ AVAudioSessionInterruptionTypeKey : @(AVAudioSessionInterruptionTypeEnded) }];
}

/** Set the category and options if they are not already ours. PDAudio's queue. */
static void pdApplySessionMode(void)
{
	AVAudioSession *s = AVAudioSession.sharedInstance;
	const int mode = pdCurrentMode();
	const AVAudioSessionCategoryOptions want = pdOptionsForMode(mode);
	NSError *err = nil;

	if (![s.category isEqualToString:AVAudioSessionCategoryPlayback] || s.categoryOptions != want) {
		if ([s setCategory:AVAudioSessionCategoryPlayback
		              mode:AVAudioSessionModeDefault
		           options:want
		             error:&err]) {
			sApplied++;
			NSLog(@"perfectdark: [audio] playback opts %#lx (mode %d, %d), route %@, sr %.0f",
				(unsigned long)want, mode, sApplied,
				s.currentRoute.outputs.firstObject.portType ?: @"?", s.sampleRate);
		} else {
			sLastError = err.localizedDescription;
		}
	}

	if (![s setActive:YES error:&err]) {
		// Not fatal and not always an error: an interruption (a call) leaves the
		// session inactive on purpose and the next poll picks it back up.
		sLastError = err.localizedDescription;
	}

	// Switching TO the non-mixable mode mid-session only interrupts the other
	// app when the session (re)activates, and setActive:YES on an already-active
	// session is a no-op — so if the other app is still going, bounce it once.
	if (mode == 0 && pdOtherAudioPlaying(s)) {
		[s setActive:NO
		 withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
		       error:NULL];
		if (![s setActive:YES error:&err]) {
			sLastError = err.localizedDescription;
		}
	}

	pdRecomputeDuck(s);
	sArmed = YES;
}

@implementation PDAudio

+ (NSArray<NSString *> *)modeTitles
{
	// Index == the stored mode. bean's names, which say what the ROW does
	// rather than what AVAudioSession calls it.
	return @[ @"Stop Other Audio", @"Play Both", @"Lower Other Audio",
	          @"Lower Game Audio", @"Mute Game Audio" ];
}

+ (NSArray<NSString *> *)modeDetails
{
	// One sentence each, because "duck" and "mix" mean nothing to a player and
	// a four-word label would not help. bean's sentences, this game's name.
	return @[
		@"Music and podcasts stop when Perfect Dark starts.",
		@"Both play together, neither one quieter.",
		@"Music and podcasts drop to the background; game audio stays full.",
		@"Game audio drops to the background while another app is playing.",
		@"Game audio goes silent while another app is playing.",
	];
}

+ (void)begin
{
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		pdRecomputeGain();

		dispatch_async(pdAudioQueue(), ^{ pdApplySessionMode(); });

		// The poll. SDL's CoreAudio backend sets its OWN category when it opens
		// the device, and it opens the device AFTER this runs at boot — so at
		// launch the session carries SDL's options until something puts ours
		// back (bean measured the same thing on GoldenEye, 2026-09-10). Re-
		// asserting on drift covers SDL's open, any later re-open, and the
		// system. On PDAudio's queue, NOT the main run loop: the main thread is
		// the game thread here, and an AVAudioSession round trip inside the
		// frame is a frame that can miss its display link (M-029).
		static dispatch_source_t timer;
		timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, pdAudioQueue());
		dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
			NSEC_PER_SEC, NSEC_PER_SEC / 4);
		dispatch_source_set_event_handler(timer, ^{
			if (!sArmed) {
				return;
			}
			AVAudioSession *s = AVAudioSession.sharedInstance;
			if (![s.category isEqualToString:AVAudioSessionCategoryPlayback] ||
			    s.categoryOptions != pdOptionsForMode(pdCurrentMode())) {
				NSLog(@"perfectdark: [audio] session drifted to %@ opts %#lx — re-asserting",
					s.category, (unsigned long)s.categoryOptions);
				pdApplySessionMode();
				return;
			}
			// The other app may have started or stopped without the hint
			// notification firing (it only fires for primary-audio changes we
			// are secondary to).
			pdRecomputeDuck(s);
			pdKickStalledDevice(s);
#if TARGET_OS_VISION
			// ...and the spatial intent, every second: SDL drops it whenever it
			// re-opens the device and says nothing (plan §2.7).
			pdApplySpatial();
#endif
		});
		dispatch_resume(timer);

		// The duck-game modes must react when the other app starts or stops
		// MID-game, and the category is worth re-asserting on foreground (SDL
		// or the system may have touched the session while backgrounded).
		NSOperationQueue *q = [NSOperationQueue new];
		q.maxConcurrentOperationCount = 1;
		q.qualityOfService = NSQualityOfServiceUtility;
		NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
		[nc addObserverForName:AVAudioSessionSilenceSecondaryAudioHintNotification
		                object:nil queue:q usingBlock:^(NSNotification *n) {
			(void)n;
			dispatch_async(pdAudioQueue(), ^{ pdRecomputeDuck(AVAudioSession.sharedInstance); });
		}];
		[nc addObserverForName:UIApplicationDidBecomeActiveNotification
		                object:nil queue:q usingBlock:^(NSNotification *n) {
			(void)n;
			dispatch_async(pdAudioQueue(), ^{ pdApplySessionMode(); });
		}];

		NSLog(@"perfectdark: [audio] session armed — playback, mode %d, re-asserted on drift",
			pdCurrentMode());
	});
}

+ (void)gainChanged
{
	pdRecomputeGain();
}

+ (void)setImmersive:(BOOL)immersive
{
#if TARGET_OS_VISION
	sImmersive = immersive ? 1 : 0;
	dispatch_async(pdAudioQueue(), ^{
		pdApplySessionMode();   // the category first: spatial is meaningless without it
		pdApplySpatial();
	});
#else
	(void)immersive;
#endif
}

+ (void)settingsChanged
{
	pdRecomputeGain();
	dispatch_async(pdAudioQueue(), ^{ pdApplySessionMode(); });
}

+ (NSString *)stateLines
{
	AVAudioSession *s = AVAudioSession.sharedInstance;
	AVAudioSessionPortDescription *out = s.currentRoute.outputs.firstObject;
	return [NSString stringWithFormat:
		@"audio_category=%@\naudio_options=%#lx\naudio_route=%@\naudio_rate=%.0f\n"
		 "audio_outchannels=%ld\naudio_applied=%d\naudio_error=%@\n"
		 "audio_mode=%d\naudio_mode_name=%@\naudio_volume=%.2f\naudio_mute=%d\n"
		 "audio_duck=%.2f\naudio_gain=%.2f\naudio_other_playing=%d\n"
		 "audio_queued=%d\naudio_queued_min=%d\naudio_queued_max=%d\n"
		 "audio_underruns=%d\naudio_drops=%d\naudio_pushes=%d\naudio_reprimes=%d\n"
		 "audio_silence=%d\naudio_push_samples=%d\n"
		 "audio_have_freq=%d\naudio_have_samples=%d\naudio_have_channels=%d\n"
		 "audio_have_format=%#x\naudio_buffer_size=%d\naudio_queue_limit=%d\n"
		 "audio_prime_samples=%d\naudio_out_samples=%d\naudio_rate_milli=%d\n"
		 "audio_rate_min_milli=%d\naudio_rate_max_milli=%d\naudio_resync_underrun=%d\n"
		 "audio_resync_burst=%d\naudio_dropped_samples=%d\n"
		 "audio_dropping=%d\naudio_dropping_ms=%u\naudio_device_restarts=%d\n"
#if TARGET_OS_VISION
		 "audio_spatial_immersive=%d\naudio_spatial_experience=%d\n"
		 "audio_spatial_applied=%d\naudio_spatial_error=%@\n"
#endif
		 ,
		s.category ?: @"-", (unsigned long)s.categoryOptions, out.portType ?: @"none",
		s.sampleRate, (long)s.outputNumberOfChannels, sApplied, sLastError ?: @"-",
		pdCurrentMode(), PDAudio.modeTitles[(NSUInteger)pdCurrentMode()],
		PDDefFloat(PDDefAudioMasterVolume), (int)PDDefBool(PDDefAudioMute),
		atomic_load_explicit(&sDuck, memory_order_relaxed), pdPlatformAudioGain(),
		(int)pdOtherAudioPlaying(s),
		g_PdAudioQueued, g_PdAudioQueuedMin, g_PdAudioQueuedMax,
		g_PdAudioUnderruns, g_PdAudioDrops, g_PdAudioPushes, g_PdAudioReprimes,
		g_PdAudioSilence, g_PdAudioPushSamples,
		g_PdAudioHaveFreq, g_PdAudioHaveSamples, g_PdAudioHaveChannels,
		(unsigned)g_PdAudioHaveFormat, g_PdAudioBufferSize, g_PdAudioQueueLimit,
		g_PdAudioPrimeSamples, g_PdAudioOutSamples, g_PdAudioRateMilli,
		g_PdAudioRateMinMilli, g_PdAudioRateMaxMilli, g_PdAudioResyncUnder,
		g_PdAudioResyncOver, g_PdAudioDroppedSamples,
		g_PdAudioDropping, g_PdAudioDropping ? SDL_GetTicks() - g_PdAudioDroppingSinceMs : 0u, sKicks
#if TARGET_OS_VISION
		, sImmersive, (int)s.intendedSpatialExperience, sSpatialApplied,
		sSpatialError ?: @"-"
#endif
		];
}

/**
 * Zero the queue counters so a window measures one thing.
 *
 * The cumulative min and the underrun count are the two numbers that say
 * whether the cushion is holding, and both are useless across a session that
 * included a stage load. `audio reset` on the bridge, then play for five
 * minutes, then read.
 */
+ (void)statsReset
{
	g_PdAudioQueuedMin = -1;
	g_PdAudioQueuedMax = 0;
	g_PdAudioUnderruns = 0;
	g_PdAudioDrops = 0;
	g_PdAudioReprimes = 0;
	g_PdAudioSilence = 0;
	g_PdAudioResyncUnder = 0;
	g_PdAudioResyncOver = 0;
	g_PdAudioDroppedSamples = 0;
	g_PdAudioRateMinMilli = g_PdAudioRateMilli;
	g_PdAudioRateMaxMilli = g_PdAudioRateMilli;
}

@end
