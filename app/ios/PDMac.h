// The desktop adaptations of the shared UIKit shell.
#pragma once
#import <UIKit/UIKit.h>
#include <TargetConditionals.h>

#if TARGET_OS_MACCATALYST
void PDMacConfigureWindow(UIWindow *window);
void PDMacInstallSettingsCommand(UIViewController *controller);
void PDMacSetInputBlocked(BOOL blocked);
int PDMacInputBlocked(void);
void PDMacOpenDataFolder(void);
#else
static inline void PDMacConfigureWindow(UIWindow *window) { (void)window; }
static inline void PDMacInstallSettingsCommand(UIViewController *controller) { (void)controller; }
static inline void PDMacSetInputBlocked(BOOL blocked) { (void)blocked; }
#endif
