// PDBridge.h — the console bridge on TCP :8775 (D-002). Compiled out when
// PD_PUBLIC is defined. Commands: docs/remote-console.md.
#pragma once

#import <Foundation/Foundation.h>

@interface PDBridge : NSObject
/** Start the listener thread. Called once at launch in non-public builds. */
+ (void)start;
@end
