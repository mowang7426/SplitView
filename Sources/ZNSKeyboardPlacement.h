#import <UIKit/UIKit.h>

// Posted on the main queue after a real visibility/owner change. Observers may
// update their local input shield, but must not acquire keyboard focus.
FOUNDATION_EXPORT NSNotificationName const ZNSExternalKeyboardVisibilityDidChangeNotification;

// Placement only. Never acquires focus, sends text or calls SBS focus services.
@interface ZNSKeyboardPlacement : NSObject
// Main-thread only; nil for hidden, ambiguous or no-longer-owned surfaces.
+ (NSString *)visibleExternalKeyboardBundleIdentifier;
// Call from the recognized-tap handler, BEFORE icon activation/parking/closing.
// point is in view's coordinates (not fixed screen coordinates). YES consumes
// the entire tap, even if the App refuses to resign; never forward/replay it.
// NO means there is no verified external keyboard, or the tap hits its content
// or drag handle. The optional output is the verified owner's bundle identifier.
// This does not install a shield: WindowManager must intercept remote App taps
// with its own CA input layer if those taps should also dismiss the keyboard.
+ (BOOL)consumeOutsideTapAtPoint:(CGPoint)point inView:(UIView *)view bundleIdentifier:(NSString * __autoreleasing *)identifier;
@property(nonatomic,readonly) BOOL applied;
@property(nonatomic,readonly) BOOL external;
- (void)configurePortraitExternal:(BOOL)portrait landscapeExternal:(BOOL)landscape move:(BOOL)move;
- (void)setPlacementActive:(BOOL)active;
- (void)updateScene:(id)scene bundleIdentifier:(NSString *)identifier;
- (void)updateHost:(UIView *)host canvas:(CGSize)canvas;
- (void)suspend;
- (void)invalidate;
@end
