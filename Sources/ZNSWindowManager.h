#import <UIKit/UIKit.h>
// Main-thread, one-shot preparation. Until commit, no existing window is parked
// or restored. Cancelling only releases the scene created by this preparation.
@interface ZNSWindowActivation : NSObject
- (BOOL)commit;
- (void)cancel;
@end
@interface ZNSWindowManager : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)reloadPreferences;
// YES: request accepted; scene readiness remains asynchronous.
- (BOOL)openBundleIdentifier:(NSString *)bundle;
// Admission policy only; does not create or activate a window.
- (BOOL)canOpenBundleIdentifier:(NSString *)bundle;
// Completion always arrives asynchronously; nil means admission failed.
- (ZNSWindowActivation *)prepareSwitcherBundleIdentifier:(NSString *)bundle whenReady:(void (^)(BOOL ready))completion;
// Notification presentation keeps an independent main window when parking/dipping.
- (BOOL)canOpenNotificationBundleIdentifier:(NSString *)bundle mode:(NSString *)mode;
- (ZNSWindowActivation *)prepareNotificationBundleIdentifier:(NSString *)bundle mode:(NSString *)mode whenReady:(void (^)(BOOL ready))completion;
// Completion reports actual scene readiness, not merely admission. Main thread only.
- (BOOL)openBundleIdentifier:(NSString *)bundle whenReady:(void (^)(BOOL ready))completion;
// YES consumes a desktop tap for an already managed App, including a busy window.
- (BOOL)handleDesktopIconTap:(UIView *)iconView;
// SpringBoard chrome policy; these do not alter hosted App content.
- (void)trackDesktopDockView:(UIView *)view;
- (BOOL)shouldHideDesktopDock;
- (BOOL)shouldHideDesktopIconsAndStatusBar;
- (BOOL)shouldHideDesktopPageControls;
- (void)emitDiagnostics;
- (void)attachGesturesToIconView:(UIView *)view;
- (void)closeForLock;
// Distinct from authorization revocation: skip competing scene transactions.
- (void)closeForDeviceLock;
// A confirmed switcher close releases only this App's bottom-dipped card.
- (void)closeDippedBundleIdentifier:(NSString *)bundle;
- (void)observeEvent:(UIEvent *)event;
@end
