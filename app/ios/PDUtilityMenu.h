// PDUtilityMenu.h — the ••• menu, in the family's menu shape (SunPad,
// MeleePad, GalaxyPad): Display, Controls, Audio, Add-ons, Help & Feedback and
// a destructive end action last.
#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface PDUtilityMenu : NSObject

/** "DarkPad <version>", the menu's title. */
@property (class, readonly) NSString *title;

/** Show the menu under the ••• button (main thread). It pauses the game. */
+ (void)present;

/** Engine-frame hook (main thread): cache whether End Session is available. */
+ (void)noteEngineFrame;

@end

NS_ASSUME_NONNULL_END
