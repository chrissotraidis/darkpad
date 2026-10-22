#pragma once
#import <Foundation/Foundation.h>

@interface PDGyro : NSObject
@property (class, readonly) PDGyro *shared;
// Main/game thread, alongside the existing touch/controller frame hooks.
- (void)tick;
- (void)recenter;
- (NSString *)status;
- (NSString *)stateLines;
@end
