// PDWatchdog.m — heartbeat.txt, lifecycle.txt and hang.txt. PDWatchdog.h is why.
#import "PDWatchdog.h"

#import <UIKit/UIKit.h>

#import "PDShell.h"
#import "PDPacing.h"
#import "PDTouchOverlay.h"
#import "PDSettingsViewController.h"
#import "PDSceneDelegate.h"

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#include "build_stamp.h"

@interface PDWatchdog ()
+ (void)observeLifecycle;
@end

/** The main (== game) thread's pthread_t, so the dumper can name its stack. */
static pthread_t sMainPthread;

// ---------------------------------------------------------------------------
// Paths, resolved once on the main thread at start so the watchdog never has to
// ask Foundation for them.

static char sHeartbeatPath[1024];
static char sHeartbeatTmp[1024];
static char sLifecyclePath[1024];
static char sHangPath[1024];

// ---------------------------------------------------------------------------
// The snapshot: everything UIKit-shaped, copied on the main thread.
//
// One writer (the frame hook, on the game thread) and one reader (the
// watchdog). A seqlock rather than a mutex, because the reader must never be
// able to block the game thread and must never inherit a lock a wedged main
// thread is holding: an odd sequence means "being written, try again".

typedef struct {
	int appState;             // UIApplicationState: 0 active, 1 inactive, 2 background
	int ignoringInteraction;
	int settingsPresented;
	int keyWindowPresent;
	int sceneCount;
	int sceneStates[4];       // UISceneActivationState per connected window scene
	int thermal;
	int tickRateDiv;
	int framerateLimit;       // the window layer's target fps (videoGetFramerateLimit)
	int vsync;
	unsigned uiTouchesBegan;
	unsigned uiHitTests;
	double footprintMB;
	char keyWindowClass[64];
	char overlayState[16];
} PDUISnap;

static _Atomic uint64_t sSnapSeq;
static PDUISnap sSnap;

static _Atomic uint64_t sFrameCount;
static _Atomic(double) sLastFrameAt;
static _Atomic(double) sStartedAt;
static _Atomic int sHangDumpsWritten;

static double pdNow(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

// ---------------------------------------------------------------------------
// lifecycle.txt

static pthread_mutex_t sLifeLock = PTHREAD_MUTEX_INITIALIZER;

static int pdStampNow(char *buf, int len)
{
	struct timeval tv;
	gettimeofday(&tv, NULL);
	time_t secs = tv.tv_sec;
	struct tm tm;
	localtime_r(&secs, &tm);
	return snprintf(buf, (size_t)len, "%02d:%02d:%02d.%03d +%7.2f",
		tm.tm_hour, tm.tm_min, tm.tm_sec, (int)(tv.tv_usec / 1000),
		pdNow() - atomic_load(&sStartedAt));
}

void PDLifecycle(const char *fmt, ...)
{
	char msg[768];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(msg, sizeof msg, fmt, ap);
	va_end(ap);

	// The line goes to the syslog too: when the phone IS answering,
	// idevicesyslog is the quicker read, and when it is not, the file is the
	// only read.
	NSLog(@"perfectdark: [life] %s", msg);

	char stamp[64];
	pdStampNow(stamp, sizeof stamp);
	char line[1024];
	int n = snprintf(line, sizeof line, "%s [%s] %s\n", stamp,
		pthread_main_np() ? "main" : "aux", msg);
	if (n > (int)sizeof(line) - 1) {
		n = (int)sizeof(line) - 1;
	}

	if (!sLifecyclePath[0]) {
		return;
	}
	pthread_mutex_lock(&sLifeLock);
	int fd = open(sLifecyclePath, O_WRONLY | O_CREAT | O_APPEND, 0644);
	if (fd >= 0) {
		ssize_t w = write(fd, line, (size_t)n);
		(void)w;
		fsync(fd);
		close(fd);
	}
	pthread_mutex_unlock(&sLifeLock);
}

// ---------------------------------------------------------------------------
// The snapshot, taken on the main thread.

void PDWatchdogNoteFrame(uint64_t frameCount)
{
	atomic_store(&sFrameCount, frameCount);
	atomic_store(&sLastFrameAt, pdNow());

	// The UIKit half is not free (connectedScenes, a key-window walk), so it is
	// sampled rather than taken every frame: five times a second is far finer
	// than the once-a-second heartbeat that prints it.
	static double lastSnap = 0.0;
	const double now = pdNow();
	if (now - lastSnap < 0.2) {
		return;
	}
	lastSnap = now;

	PDUISnap s;
	memset(&s, 0, sizeof s);

	UIApplication *app = UIApplication.sharedApplication;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	s.appState = (int)app.applicationState;
#if TARGET_OS_VISION
	s.ignoringInteraction = -1;
#else
	s.ignoringInteraction = (int)app.isIgnoringInteractionEvents;
#endif
#pragma clang diagnostic pop

	UIWindow *key = nil;
	for (UIScene *sc in app.connectedScenes) {
		if (![sc isKindOfClass:UIWindowScene.class]) {
			continue;
		}
		UIWindowScene *ws = (UIWindowScene *)sc;
		if (s.sceneCount < (int)(sizeof(s.sceneStates) / sizeof(s.sceneStates[0]))) {
			s.sceneStates[s.sceneCount] = (int)ws.activationState;
		}
		s.sceneCount++;
		if (!key) {
			key = ws.keyWindow;
		}
	}
	s.keyWindowPresent = (key != nil);
	strlcpy(s.keyWindowClass, key ? NSStringFromClass(key.class).UTF8String : "NONE",
		sizeof s.keyWindowClass);

	s.settingsPresented = (int)PDSettingsViewController.isPresented;
	PDTouchOverlay *ov = PDTouchOverlay.current;
	strlcpy(s.overlayState, ov ? (ov.hidden ? "hidden" : "visible") : "none", sizeof s.overlayState);
	s.uiTouchesBegan = [PDTouchOverlay touchesBeganCount];
	s.uiHitTests = [PDTouchOverlay hitTestCount];
	s.thermal = (int)NSProcessInfo.processInfo.thermalState;

	if (PDShell.shared.engineRunning) {
		s.tickRateDiv = g_TickRateDiv;
		s.framerateLimit = videoGetFramerateLimit();
		s.vsync = videoGetVsync();
	} else {
		s.tickRateDiv = s.framerateLimit = s.vsync = -1;
	}

	task_vm_info_data_t vm;
	mach_msg_type_number_t cnt = TASK_VM_INFO_COUNT;
	if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &cnt) == KERN_SUCCESS) {
		s.footprintMB = (double)vm.phys_footprint / (1024.0 * 1024.0);
	}

	// Seqlock write: odd while in progress.
	atomic_fetch_add(&sSnapSeq, 1);
	atomic_thread_fence(memory_order_release);
	sSnap = s;
	atomic_thread_fence(memory_order_release);
	atomic_fetch_add(&sSnapSeq, 1);
}

static void pdReadSnap(PDUISnap *out)
{
	for (int tries = 0; tries < 8; tries++) {
		uint64_t a = atomic_load(&sSnapSeq);
		if (a & 1u) {
			continue;
		}
		atomic_thread_fence(memory_order_acquire);
		*out = sSnap;
		atomic_thread_fence(memory_order_acquire);
		if (atomic_load(&sSnapSeq) == a) {
			return;
		}
	}
	// Eight failed attempts means the writer is running flat out, which is
	// itself good news; take the torn copy, it is an instrument.
}

// ---------------------------------------------------------------------------
// heartbeat.txt

int PDWatchdogFormatHeartbeat(char *buf, int len)
{
	PDUISnap s;
	pdReadSnap(&s);

	PDPacingSnap p;
	pdPacingSnapshot(&p);

	const double now = pdNow();
	const double sinceFrame = now - atomic_load(&sLastFrameAt);

	char scenes[64] = "-";
	int at = 0;
	for (int i = 0; i < s.sceneCount && i < 4; i++) {
		at += snprintf(scenes + at, sizeof(scenes) - (size_t)at, i ? ",%d" : "%d", s.sceneStates[i]);
	}

	return snprintf(buf, (size_t)len,
		"build=%s\n"
		"version=%s\n"
		"unix=%lld\n"
		"uptime_s=%.1f\n"
		"frames=%llu\n"
		"since_frame_s=%.3f\n"
		"hang_dumps=%d\n"
		"app_state=%d\n"
		"scene_count=%d\n"
		"scene_states=%s\n"
		"key_window=%s\n"
		"key_window_present=%d\n"
		"settings_page=%d\n"
		"overlay=%s\n"
		"ui_touches_began=%u\n"
		"ui_hittests=%u\n"
		"ignoring_interaction=%d\n"
		"thermal=%d\n"
		"footprint_mb=%.1f\n"
		"tick_rate_div=%d\n"
		"video_framerate_limit=%d\n"
		"video_vsync=%d\n"
		"graft_enabled=%d\n"
		"pacing_mode=%s\n"
		"pacing_link_hz=%ld\n"
		"pacing_measured_hz=%.1f\n"
		"pacing_target=%ld\n"
		"pacing_engine_hz=%ld\n"
		"pacing_divisor=%d\n"
		"pacing_links=%llu\n"
		"pacing_presents=%llu\n"
		"pacing_dropped=%llu\n"
		"pacing_waiting=%llu\n"
		"pacing_present_allowed=%d\n"
		"pacing_early_wait=%d\n"
		"pacing_wait_mode=%s\n"
		"pacing_wake_us_mean=%.0f\n"
		"pacing_wake_us_max=%.0f\n"
		"pacing_wake_n=%llu\n",
		PD_IOS_BUILD_STAMP, PD_IOS_MARKETING_VERSION,
		(long long)time(NULL),
		now - atomic_load(&sStartedAt),
		(unsigned long long)atomic_load(&sFrameCount),
		sinceFrame,
		atomic_load(&sHangDumpsWritten),
		s.appState, s.sceneCount, scenes,
		s.keyWindowClass[0] ? s.keyWindowClass : "-", s.keyWindowPresent,
		s.settingsPresented, s.overlayState[0] ? s.overlayState : "-",
		s.uiTouchesBegan, s.uiHitTests, s.ignoringInteraction,
		s.thermal, s.footprintMB,
		s.tickRateDiv, s.framerateLimit, s.vsync, pdGraftEnabled,
		p.bypass ? "bypass" : "displaylink",
		p.appliedLinkHz, p.measuredHz, p.targetHz, p.engineHz, p.divisor,
		p.links, p.presents, p.dropped, p.waiting,
		p.presentAllowed, p.earlyWait,
		p.waitMode == 1 ? "runloop" : "sem", p.wakeUsMean, p.wakeUsMax, p.wakeSamples);
}

static void pdWriteHeartbeat(void)
{
	char body[2048];
	int n = PDWatchdogFormatHeartbeat(body, sizeof body);
	if (n <= 0) {
		return;
	}
	if (n > (int)sizeof(body)) {
		n = (int)sizeof(body) - 1;
	}

	// Temp file then rename: a reader (or a `devicectl copy from` while the app
	// is running) always sees a whole file, never half of one.
	int fd = open(sHeartbeatTmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) {
		return;
	}
	ssize_t w = write(fd, body, (size_t)n);
	(void)w;
	close(fd);
	rename(sHeartbeatTmp, sHeartbeatPath);
}

// ---------------------------------------------------------------------------
// hang.txt — the stack dumper.
//
// The technique is KSCrash's and PLCrashReporter's, and all of it is allowed in
// a sideloaded app: task_threads() to enumerate, thread_suspend() so the
// register state cannot move under us, thread_get_state(ARM_THREAD_STATE64) for
// pc/lr/fp, and a walk of the frame-pointer chain through vm_read_overwrite()
// so a bad fp is an error rather than a second crash.
//
// Symbolization happens only after every thread has been resumed: dladdr() takes
// the dyld lock, and the thread we just stopped may be holding it.

#define kMaxThreads 64
#define kMaxFrames  40

typedef struct {
	thread_t port;
	int isMain;
	int count;
	uintptr_t pc[kMaxFrames];
	char name[48];
} PDThreadStack;

static int pdReadWord(uintptr_t addr, void *dst, size_t len)
{
	if (addr == 0 || (addr & 1) != 0) {
		return 0;
	}
	vm_size_t got = 0;
	if (vm_read_overwrite(mach_task_self(), (vm_address_t)addr, (vm_size_t)len,
			(vm_address_t)dst, &got) != KERN_SUCCESS) {
		return 0;
	}
	return got == len;
}

#if !defined(__arm64__)
#error "the hang dumper unwinds arm64 frame pointers; this port builds arm64 only"
#endif

static void pdWalk(PDThreadStack *out, const arm_thread_state64_t *st)
{
	uintptr_t pc = (uintptr_t)__darwin_arm_thread_state64_get_pc(*st);
	uintptr_t lr = (uintptr_t)__darwin_arm_thread_state64_get_lr(*st);
	uintptr_t fp = (uintptr_t)__darwin_arm_thread_state64_get_fp(*st);

	if (pc) {
		out->pc[out->count++] = pc;
	}
	if (lr && out->count < kMaxFrames) {
		out->pc[out->count++] = lr;
	}
	// { saved fp, saved lr } at [fp].
	uintptr_t frame[2];
	int guard = 0;
	while (fp && out->count < kMaxFrames && guard++ < kMaxFrames) {
		if (!pdReadWord(fp, frame, sizeof frame)) {
			break;
		}
		if (frame[1] == 0 || frame[0] <= fp) {
			break;
		}
		out->pc[out->count++] = frame[1];
		fp = frame[0];
	}
}

static void pdWriteAll(int fd, const char *s)
{
	size_t len = strlen(s);
	while (len) {
		ssize_t n = write(fd, s, len);
		if (n <= 0) {
			return;
		}
		s += n;
		len -= (size_t)n;
	}
}

int PDWatchdogDumpNow(const char *why)
{
	static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
	if (pthread_mutex_trylock(&lock) != 0) {
		return 0;   // one dump at a time; never queue behind one
	}

	static PDThreadStack stacks[kMaxThreads];   // static: no malloc, no stack blow
	int nstacks = 0;

	const thread_t self = mach_thread_self();
	// The main thread's mach port, taken from the pthread_t +start recorded:
	// pthread_main_np() answers only about the CALLING thread, and the caller
	// here is the watchdog.
	const thread_t mainPort = sMainPthread ? pthread_mach_thread_np(sMainPthread) : MACH_PORT_NULL;

	thread_act_array_t threads = NULL;
	mach_msg_type_number_t count = 0;
	if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) {
		mach_port_deallocate(mach_task_self(), self);
		pthread_mutex_unlock(&lock);
		return -1;
	}

	for (mach_msg_type_number_t i = 0; i < count && nstacks < kMaxThreads; i++) {
		thread_t th = threads[i];
		if (th == self) {
			continue;
		}
		PDThreadStack *s = &stacks[nstacks];
		memset(s, 0, sizeof *s);
		s->port = th;
		s->isMain = (th == mainPort);

		pthread_t pt = pthread_from_mach_thread_np(th);
		if (pt) {
			pthread_getname_np(pt, s->name, sizeof s->name);
		}
		if (!s->name[0]) {
			strlcpy(s->name, s->isMain ? "main/game" : "?", sizeof s->name);
		}

		if (thread_suspend(th) != KERN_SUCCESS) {
			continue;
		}
		arm_thread_state64_t st;
		mach_msg_type_number_t sc = ARM_THREAD_STATE64_COUNT;
		if (thread_get_state(th, ARM_THREAD_STATE64, (thread_state_t)&st, &sc) == KERN_SUCCESS) {
			pdWalk(s, &st);
		}
		thread_resume(th);
		nstacks++;
	}

	// Everything is running again. Only now is it safe to symbolize.
	int fd = open(sHangPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
	if (fd >= 0) {
		char head[2048];
		char stamp[64];
		pdStampNow(stamp, sizeof stamp);
		snprintf(head, sizeof head,
			"\n==== Perfect Dark iOS hang dump (%s) ====\n%s\n", why ? why : "?", stamp);
		pdWriteAll(fd, head);
		int n = PDWatchdogFormatHeartbeat(head, sizeof head);
		if (n > 0) {
			pdWriteAll(fd, head);
		}

		for (int i = 0; i < nstacks; i++) {
			PDThreadStack *s = &stacks[i];
			char line[512];
			snprintf(line, sizeof line, "\nthread %d \"%s\"%s frames=%d\n",
				i, s->name, s->isMain ? " <- MAIN / GAME THREAD" : "", s->count);
			pdWriteAll(fd, line);
			for (int f = 0; f < s->count; f++) {
				Dl_info info;
				memset(&info, 0, sizeof info);
				const char *img = "?", *sym = "?";
				uintptr_t off = 0;
				if (dladdr((void *)s->pc[f], &info) && info.dli_fname) {
					const char *slash = strrchr(info.dli_fname, '/');
					img = slash ? slash + 1 : info.dli_fname;
					if (info.dli_sname) {
						sym = info.dli_sname;
						off = s->pc[f] - (uintptr_t)info.dli_saddr;
					}
				}
				snprintf(line, sizeof line, "  %2d  0x%016lx  %-28s %s + %lu\n",
					f, (unsigned long)s->pc[f], img, sym, (unsigned long)off);
				pdWriteAll(fd, line);
			}
		}
		pdWriteAll(fd, "================================\n");
		fsync(fd);
		close(fd);
	}

	for (mach_msg_type_number_t i = 0; i < count; i++) {
		mach_port_deallocate(mach_task_self(), threads[i]);
	}
	vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(thread_t));
	mach_port_deallocate(mach_task_self(), self);

	atomic_fetch_add(&sHangDumpsWritten, 1);
	pthread_mutex_unlock(&lock);
	return nstacks;
}

void PDWatchdogFakeHang(int ms)
{
	if (ms < 0) {
		ms = 0;
	}
	if (ms > 30000) {
		ms = 30000;
	}
	PDLifecycle("hang test: blocking this thread for %d ms", ms);
	// usleep, deliberately, and deliberately NOT a run-loop turn: this is
	// imitating a game thread that cannot get on with the frame.
	usleep((useconds_t)ms * 1000);
	PDLifecycle("hang test: released after %d ms", ms);
}

// ---------------------------------------------------------------------------

static void *pdWatchdogMain(void *arg)
{
	(void)arg;
	pthread_setname_np("pd-watchdog");

	double lastDump = 0.0;
	while (1) {
		struct timespec ts = { .tv_sec = 1, .tv_nsec = 0 };
		nanosleep(&ts, NULL);

		pdWriteHeartbeat();

		const double now = pdNow();
		const double since = now - atomic_load(&sLastFrameAt);
		PDUISnap s;
		pdReadSnap(&s);

		// A background app whose frame hook has stopped is an app that is doing
		// what it was told. Only a foreground-active one that has gone quiet is
		// a hang. (app_state 0 = UIApplicationStateActive.)
		const int active = (s.appState == 0);
		if (since > 2.0 && active && (now - lastDump) > 10.0) {
			lastDump = now;
			char why[128];
			snprintf(why, sizeof why, "frame hook silent for %.1f s, app_state=%d", since, s.appState);
			PDWatchdogDumpNow(why);
			PDLifecycle("HANG: %s — hang.txt written", why);
		}
	}
	return NULL;
}

@implementation PDWatchdog

+ (void)start
{
	static BOOL started = NO;
	if (started) {
		return;
	}
	started = YES;

	NSString *docs = PDShell.shared.documentsPath;
	strlcpy(sHeartbeatPath, [docs stringByAppendingPathComponent:@"heartbeat.txt"].fileSystemRepresentation,
		sizeof sHeartbeatPath);
	strlcpy(sHeartbeatTmp, [docs stringByAppendingPathComponent:@"heartbeat.tmp"].fileSystemRepresentation,
		sizeof sHeartbeatTmp);
	strlcpy(sLifecyclePath, [docs stringByAppendingPathComponent:@"lifecycle.txt"].fileSystemRepresentation,
		sizeof sLifecyclePath);
	strlcpy(sHangPath, [docs stringByAppendingPathComponent:@"hang.txt"].fileSystemRepresentation,
		sizeof sHangPath);

	sMainPthread = pthread_self();   // +start runs on the main/game thread
	atomic_store(&sStartedAt, pdNow());
	atomic_store(&sLastFrameAt, pdNow());

	PDLifecycle("=== launch: build %s (%s) ===", PD_IOS_BUILD_STAMP, PD_IOS_MARKETING_VERSION);
	[self observeLifecycle];

	pthread_attr_t attr;
	pthread_attr_init(&attr);
	pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
	pthread_t t;
	if (pthread_create(&t, &attr, pdWatchdogMain, NULL) != 0) {
		NSLog(@"perfectdark: [watchdog] pthread_create failed: %s", strerror(errno));
	} else {
		NSLog(@"perfectdark: [watchdog] running -> %s", sHeartbeatPath);
	}
	pthread_attr_destroy(&attr);
}

/**
 * Every UIApplication and UIScene notification, one line each.
 *
 * pd_ios_main.m already observes the four it ACTS on; this is the complete set,
 * written for the record. If the wedge is a suspension (H1), the last line in
 * lifecycle.txt is the whole answer.
 */
+ (void)observeLifecycle
{
	NSArray<NSNotificationName> *names = @[
		UIApplicationDidFinishLaunchingNotification,
		UIApplicationDidBecomeActiveNotification,
		UIApplicationWillResignActiveNotification,
		UIApplicationDidEnterBackgroundNotification,
		UIApplicationWillEnterForegroundNotification,
		UIApplicationWillTerminateNotification,
		UIApplicationDidReceiveMemoryWarningNotification,
		UISceneWillConnectNotification,
		UISceneDidDisconnectNotification,
		UISceneDidActivateNotification,
		UISceneWillDeactivateNotification,
		UISceneWillEnterForegroundNotification,
		UISceneDidEnterBackgroundNotification,
		UIWindowDidBecomeKeyNotification,
		UIWindowDidResignKeyNotification,
		UIWindowDidBecomeVisibleNotification,
		UIWindowDidBecomeHiddenNotification,
	];
	for (NSNotificationName n in names) {
		[NSNotificationCenter.defaultCenter addObserverForName:n object:nil queue:nil
			usingBlock:^(NSNotification *note) {
				NSString *who = @"";
				if ([note.object isKindOfClass:UIScene.class]) {
					who = [NSString stringWithFormat:@" scene=%@ state=%ld",
						((UIScene *)note.object).session.persistentIdentifier,
						(long)((UIScene *)note.object).activationState];
				} else if ([note.object isKindOfClass:UIWindow.class]) {
					UIWindow *w = note.object;
					who = [NSString stringWithFormat:@" window=%p cls=%@ level=%.0f hidden=%d",
						w, NSStringFromClass(w.class), (double)w.windowLevel, (int)w.hidden];
				}
				PDLifecycle("%s%s", note.name.UTF8String, who.UTF8String);
			}];
	}
}

+ (NSString *)report
{
	char buf[2048];
	int n = PDWatchdogFormatHeartbeat(buf, sizeof buf);
	return n > 0 ? @(buf) : @"";
}

@end
