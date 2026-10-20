// PDCrash.m — a crash handler, because upstream has none on Apple.
//
// crashInit() installs handlers only under PLATFORM_WIN32 or PLATFORM_LINUX
// (crash.c:324), so on iOS a SIGSEGV is a silent disappearance: the app goes
// away and the player has nothing to send anybody. This is additive - it does
// not replace upstream's crash report, it stands beside it. Upstream's report
// ring (crashreport.c, every sysLogPrintf line, 200 lines deep) survives on
// every platform and keeps writing $S/crashreports/; what is missing is the
// signal and the backtrace, and that is what this adds.
//
// What a handler may do in a signal context is narrow: async-signal-safe calls
// only, no Objective-C, no malloc. So everything it needs - the path, the
// header text - is prepared at install time, and the handler itself does
// open/write/backtrace_symbols_fd/close and re-raises.
#import <Foundation/Foundation.h>

#include <execinfo.h>
#include <fcntl.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>
#include <stdlib.h>

#import "PDShell.h"
#import "PDCrash.h"

#include "build_stamp.h"

static char sCrashPath[1024];
static char sHeader[512];

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

static void pdCrashHandler(int sig, siginfo_t *info, void *ctx)
{
	(void)ctx;

	// O_APPEND: a second crash after a first one is evidence, not a reason to
	// lose the first.
	int fd = open(sCrashPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
	if (fd >= 0) {
		pdWriteAll(fd, "\n==== Perfect Dark iOS crash ====\n");
		pdWriteAll(fd, sHeader);
		pdWriteAll(fd, "signal: ");
		pdWriteAll(fd, strsignal(sig) ? strsignal(sig) : "?");
		pdWriteAll(fd, "\naddress: ");
		char addr[32];
		// No snprintf in a signal handler; a tiny hex formatter instead.
		unsigned long long a = (unsigned long long)(uintptr_t)(info ? info->si_addr : 0);
		int at = 0;
		addr[at++] = '0'; addr[at++] = 'x';
		for (int shift = 60; shift >= 0; shift -= 4) {
			int nyb = (int)((a >> shift) & 0xf);
			addr[at++] = (char)(nyb < 10 ? '0' + nyb : 'a' + nyb - 10);
		}
		addr[at] = '\0';
		pdWriteAll(fd, addr);
		pdWriteAll(fd, "\nbacktrace:\n");

		void *frames[64];
		int n = backtrace(frames, 64);
		backtrace_symbols_fd(frames, n, fd);
		pdWriteAll(fd, "================================\n");
		close(fd);
	}

	// Back to the default handler so the OS still produces its own report and
	// the debugger still stops where it should.
	signal(sig, SIG_DFL);
	raise(sig);
}

/**
 * An Objective-C exception that reaches the top is not a signal, so the handler
 * above never sees it - and on iOS it is the likelier of the two (a nil in a
 * dictionary literal, an out-of-range index in the shell). Different context,
 * different rules: nothing is on fire yet, so this one may use Foundation.
 */
static void pdUncaughtException(NSException *e)
{
	NSString *text = [NSString stringWithFormat:
		@"\n==== Perfect Dark iOS uncaught exception ====\nbuild: %s\n%@: %@\n%@\n",
		PD_IOS_BUILD_STAMP, e.name, e.reason, [e.callStackSymbols componentsJoinedByString:@"\n"]];
	NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@(sCrashPath)];
	if (!fh) {
		[text writeToFile:@(sCrashPath) atomically:NO encoding:NSUTF8StringEncoding error:NULL];
	} else {
		[fh seekToEndOfFile];
		[fh writeData:[text dataUsingEncoding:NSUTF8StringEncoding]];
		[fh closeFile];
	}
}

@implementation PDCrash

+ (void)install
{
	NSString *docs = PDShell.shared.documentsPath;
	NSString *path = [docs stringByAppendingPathComponent:@"crash.txt"];
	strlcpy(sCrashPath, path.fileSystemRepresentation, sizeof(sCrashPath));

	snprintf(sHeader, sizeof(sHeader), "build: %s\nversion: %s\nwhen (unix): %lld\n",
		PD_IOS_BUILD_STAMP, PD_IOS_MARKETING_VERSION, (long long)time(NULL));

	struct sigaction sa;
	memset(&sa, 0, sizeof(sa));
	sa.sa_sigaction = pdCrashHandler;
	sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
	sigemptyset(&sa.sa_mask);

	const int sigs[] = { SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP };
	for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
		sigaction(sigs[i], &sa, NULL);
	}

	NSSetUncaughtExceptionHandler(&pdUncaughtException);

	NSLog(@"perfectdark: crash handler installed -> %s", sCrashPath);
}

@end
