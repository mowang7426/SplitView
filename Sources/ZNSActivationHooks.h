#import <Foundation/Foundation.h>

// Install only from SpringBoard; preference reads happen after it finishes launch.
FOUNDATION_EXPORT void ZNSInstallActivationHooks(void);
FOUNDATION_EXPORT void ZNSReloadActivationPreferences(void);
// Disabled after alpha41 SIGTRAP in the system URL-open implementation.
// Both return NO; the swipe rebounds without releasing its scene. Tap fullscreen
// remains separate. No alternative private activation is assumed safe.
FOUNDATION_EXPORT BOOL ZNSCanOpenFullscreenWithoutAnimation(NSString *bundle);
FOUNDATION_EXPORT BOOL ZNSOpenFullscreenWithoutAnimation(NSString *bundle);

// Notification opening is deliberately not hooked: launching a bundle alone
// cannot preserve a notification's response, destination, or completion semantics.
