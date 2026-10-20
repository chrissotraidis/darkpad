// PDDeepLink.h — perfectdark:// handling on an app whose delegate is SDL's.
#pragma once

#import <Foundation/Foundation.h>

@interface PDDeepLink : NSObject
/** Install the handlers. Main thread, after UIApplication exists. */
+ (void)install;
@end
