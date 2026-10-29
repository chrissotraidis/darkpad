#import "PDMac.h"

#if TARGET_OS_MACCATALYST
#import "PDShell.h"
#import "PDSettingsViewController.h"
#import <objc/runtime.h>
#include <SDL_events.h>
#include <stdatomic.h>

extern int inputMouseIsLocked(void);
extern void inputLockMouse(int locked);

@interface UIResponder (PDMacCommands)
- (void)pdMacShowSettings:(id)sender;
@end

@implementation UIResponder (PDMacCommands)
- (void)pdMacShowSettings:(id)sender
{
    (void)sender;
    if (PDShell.shared.engineRunning) [PDSettingsViewController present];
}
@end

static UIKeyCommand *pdMacSettingsCommand(void)
{
    UIKeyCommand *command = [UIKeyCommand keyCommandWithInput:@"," modifierFlags:UIKeyModifierCommand
        action:@selector(pdMacShowSettings:)];
    command.title = @"Settings…";
    command.wantsPriorityOverSystemBehavior = YES;
    return command;
}

void PDMacInstallSettingsCommand(UIViewController *controller)
{
    [controller addKeyCommand:pdMacSettingsCommand()];
}

static void (*pdMacOriginalBuildMenu)(id, SEL, id<UIMenuBuilder>);

static void pdMacBuildMenu(id application, SEL selector, id<UIMenuBuilder> builder)
{
    if (pdMacOriginalBuildMenu) pdMacOriginalBuildMenu(application, selector, builder);
    if (builder.system != UIMenuSystem.mainSystem) return;
    UIMenu *settings = [UIMenu menuWithTitle:@"" image:nil identifier:UIMenuPreferences
        options:UIMenuOptionsDisplayInline children:@[pdMacSettingsCommand()]];
    if ([builder menuForIdentifier:UIMenuPreferences]) {
        [builder replaceMenuForIdentifier:UIMenuPreferences withMenu:settings];
    } else {
        [builder insertSiblingMenu:settings afterMenuForIdentifier:UIMenuAbout];
    }
}

// SDL's GCKeyboard receives keys independently of UIKit. The same shortcut
// remains available when SDL's hidden text field owns the responder chain.
static int pdMacKeyWatch(void *unused, SDL_Event *event)
{
    (void)unused;
    if (event->type == SDL_KEYDOWN && !event->key.repeat
        && event->key.keysym.sym == SDLK_COMMA && (event->key.keysym.mod & KMOD_GUI)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (PDShell.shared.engineRunning) [PDSettingsViewController present];
        });
    }
    return 0;
}

void PDMacConfigureWindow(UIWindow *window)
{
    PDMacInstallSettingsCommand(window.rootViewController);
    window.windowScene.sizeRestrictions.minimumSize = CGSizeMake(800, 450);
    window.windowScene.title = @"DarkPad";
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Catalyst does not consult SDL's NSObject app delegate for its menu
        // bar. Extend the application's public menu-builder entry point while
        // preserving UIKit's standard menus. class_replaceMethod adds an
        // override if this method is inherited, without changing UIResponder.
        Class applicationClass = object_getClass(UIApplication.sharedApplication);
        SEL selector = @selector(buildMenuWithBuilder:);
        Method original = class_getInstanceMethod(applicationClass, selector);
        pdMacOriginalBuildMenu = (void *)method_getImplementation(original);
        class_replaceMethod(applicationClass, selector, (IMP)pdMacBuildMenu,
            method_getTypeEncoding(original));
        [UIMenuSystem.mainSystem setNeedsRebuild];
        SDL_AddEventWatch(pdMacKeyWatch, NULL);
    });
}

// SDL's keyboard event watch may run on GameController's handler queue.
static _Atomic(int) sInputBlocked;

int PDMacInputBlocked(void)
{
    return atomic_load(&sInputBlocked);
}

void PDMacSetInputBlocked(BOOL blocked)
{
    static BOOL restoreMouse;
    if (atomic_exchange(&sInputBlocked, !!blocked) == !!blocked) return;
    if (blocked) {
        restoreMouse = inputMouseIsLocked() != 0;
        inputLockMouse(0);
    } else if (restoreMouse) {
        inputLockMouse(1);
        restoreMouse = NO;
    }
}

void PDMacOpenDataFolder(void)
{
    NSURL *url = [NSURL fileURLWithPath:PDShell.shared.documentsPath isDirectory:YES];
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}
#endif
