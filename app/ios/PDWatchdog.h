// PDWatchdog.h — the instrument for a failure that answers no sockets (D-044).
//
// Round R's wedge on the user's phone had the game alive by `devicectl`, touch
// dead, and the :8775 bridge silent even to `help` — a command that never
// touches the engine. A bridge that cannot answer means no socket thread got
// scheduled, and everything this port can measure is read THROUGH that bridge.
// So the next answer has to be waiting in a FILE when the phone comes back on
// the cable, written by a thread that owes nothing to GCD, to the main run loop
// or to UIKit:
//
//   Documents/heartbeat.txt   once a second, whole (temp + rename): what the
//                             app thinks it is doing right now.
//   Documents/lifecycle.txt   append + fsync, one line per lifecycle event,
//                             settings commit, pacer reconfiguration or graft.
//                             This is what survives a suspension.
//   Documents/hang.txt        a symbolized backtrace of every thread, taken
//                             when the frame hook has not run for 2 s while
//                             the app believes it is foreground-active.
//
// Rules this file obeys, because the failure it chases is "nothing runs":
//   - a plain pthread, not a dispatch queue: a jammed main queue must not be
//     able to stop it;
//   - it never calls into UIKit and never dispatches to the main thread. Every
//     UIKit-shaped value it prints is a copy taken ON the main thread by
//     PDWatchdogNoteFrame() and left in a plain struct;
//   - no Objective-C and no malloc inside the hang dumper: fixed buffers,
//     write(2), and symbolization only AFTER every suspended thread has been
//     resumed (dladdr takes the dyld lock, and the thread holding it may be
//     the one we just stopped).
#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/**
 * One timestamped line into Documents/lifecycle.txt, appended and fsync'd.
 *
 * Safe from any thread. fsync per line is deliberate: the whole point is that
 * the line survives a process that is about to be suspended or killed with no
 * chance to flush.
 */
void PDLifecycle(const char *fmt, ...) __printflike(1, 2);

/**
 * Called from pdIosFrameHook(), on the game thread, once a frame.
 *
 * Two jobs: stamp "the frame hook ran" (an atomic, free), and — at most a few
 * times a second — copy the UIKit-side state the watchdog is not allowed to
 * read for itself into the snapshot it prints.
 */
void PDWatchdogNoteFrame(uint64_t frameCount);

/** `hang <ms>` on the bridge: block the calling (game) thread on purpose. */
void PDWatchdogFakeHang(int ms);

/** `dump` on the bridge: write hang.txt now. Returns the number of threads. */
int PDWatchdogDumpNow(const char *why);

/** Documents/heartbeat.txt's body, which is also what the bridge prints. */
int PDWatchdogFormatHeartbeat(char *buf, int len);

#ifdef __cplusplus
}
#endif

@interface PDWatchdog : NSObject
/** Starts the pthread. Called once, from pdSDLMain, before the engine. */
+ (void)start;
/** The heartbeat body as a string, for the bridge's `state`. */
+ (NSString *)report;
@end

NS_ASSUME_NONNULL_END
