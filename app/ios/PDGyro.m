#import "PDGyro.h"
#import "PDGyroMath.h"
#import "PDDefaults.h"
#import "PDShell.h"
#import "PDTouchOverlay.h"
#import "PDSettingsViewController.h"
#import <CoreMotion/CoreMotion.h>
#import <UIKit/UIKit.h>

extern int lvIsPaused(void);

@implementation PDGyro {
    CMMotionManager *_motion;
    PDGyroIntegrator _integrator;
    BOOL _aiming;
    BOOL _requested;
    NSUInteger _samples;
}

+ (instancetype)shared
{
    static PDGyro *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [PDGyro new]; });
    return instance;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _motion = [CMMotionManager new];
        _motion.deviceMotionUpdateInterval = 1.0 / 100.0;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(stop)
            name:UIApplicationWillResignActiveNotification object:nil];
    }
    return self;
}

- (void)recenter
{
    _integrator = (PDGyroIntegrator){0};
    _aiming = NO;
}

- (void)stop
{
    [_motion stopDeviceMotionUpdates];
    _requested = NO;
    [self recenter];
}

- (void)tick
{
#if TARGET_OS_VISION
    return; // Handset motion is not headset aiming.
#else
    int wheelSlot = 0;
    BOOL enabled = PDDefBool(PDDefGyroEnabled);
    BOOL active = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    BOOL blocked = !PDShell.shared.engineRunning || !active
        || PDSettingsViewController.isPresented || PDTouchOverlay.current.layoutEditing
        || lvIsPaused() || menuIosDialogIsOpen() || playerIosActiveMenu(&wheelSlot);
    if (!enabled || blocked || !_motion.deviceMotionAvailable) {
        if (_requested) [self stop];
        else [self recenter];
        return;
    }
    if (!_requested) {
        _requested = YES;
        // Poll the newest fused sample; no callback can race engine input.
        [_motion startDeviceMotionUpdates];
        [self recenter];
    }
    BOOL aiming = playerIosGetAimMode() != 0;
    UIInterfaceOrientation orientation = PDTouchOverlay.current.window.windowScene.interfaceOrientation;
    int landscape = orientation == UIInterfaceOrientationLandscapeLeft ? 1
        : orientation == UIInterfaceOrientationLandscapeRight ? -1 : 0;
    CMDeviceMotion *sample = _motion.deviceMotion;
    if (!sample) { [self recenter]; return; }
    PDGyroDelta delta = PDGyroStep(&_integrator, sample.timestamp,
        NSProcessInfo.processInfo.systemUptime, sample.rotationRate.x, sample.rotationRate.y,
        landscape, aiming, PDDefFloat(PDDefGyroSensitivity), PDDefBool(PDDefGyroInvertY));
    _aiming = aiming && landscape != 0;
    if (delta.yaw != 0 || delta.pitch != 0) {
        inputIosLookAddDegrees((float)delta.yaw, (float)delta.pitch);
        _samples++;
    }
#endif
}

- (NSString *)status
{
    if (!_motion.deviceMotionAvailable) return @"Motion sensor unavailable";
    if (!PDDefBool(PDDefGyroEnabled)) return @"Off";
    return @"Experimental • active only while aiming";
}

- (NSString *)stateLines
{
    return [NSString stringWithFormat:@"gyro_enabled=%d\ngyro_available=%d\ngyro_running=%d\ngyro_aiming=%d\ngyro_samples=%lu\n",
        PDDefBool(PDDefGyroEnabled), _motion.deviceMotionAvailable, _motion.deviceMotionActive,
        _aiming, (unsigned long)_samples];
}
@end
