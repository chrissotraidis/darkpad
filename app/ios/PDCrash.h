// PDCrash.h — signal handler + backtrace to Documents/crash.txt (additive:
// upstream installs no handler at all on Apple, crash.c:324).
#pragma once

#import <Foundation/Foundation.h>

@interface PDCrash : NSObject
/** Install the handlers. Main thread, once, as early as possible. */
+ (void)install;
@end
