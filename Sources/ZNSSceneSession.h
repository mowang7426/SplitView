#import <UIKit/UIKit.h>
@class ZNSKeyboardPlacement;
@interface ZNSSceneSession : NSObject
// Identity check for queued visual-only keyboard events; never mutate from UI.
@property(nonatomic,strong,readonly) ZNSKeyboardPlacement *keyboardPlacement;
@property(nonatomic,copy,readonly) NSString *bundleIdentifier;
// May be replaced after an acknowledged orientation change while the App scene
// itself stays alive. Read again in resize completion; do not cache its identity.
@property(nonatomic,strong,readonly) UIView *hostView;
@property(nonatomic,readonly) BOOL landscape;
@property(nonatomic,readonly) CGSize canvasSize;
// Original native canvas retained until the confirmed handoff. Read-only visual endpoint.
@property(nonatomic,readonly) CGSize temporaryPortraitCanvas;
// Current direction's requested placement: external or window. Applied reports
// only an actual external attachment, never verified text delivery.
@property(nonatomic,copy,readonly) NSString *keyboardMode;
@property(nonatomic,readonly) BOOL keyboardModeApplied;
// Main-thread only. Re-read the preference and reconcile the owned keyboard.
- (BOOL)reloadKeyboardPreference;
// Main-thread only. Remains YES until the real scene-update callback arrives.
@property(nonatomic,readonly) BOOL layoutInFlight;
// Main-thread, one-shot notification of the hosted client process exiting.
// Set before start; weakly capture the owner and check its session identity.
// Before invocation, the session has already released its host/lease/keepalive.
// The owner must remove its window in EVERY presentation mode, including an
// in-flight startup. Do not depend on hostView being nonnil in this callback.
// Not a card-removal notification: a removed card whose process stays alive
// does not trigger this. stopForFullscreen: clears it without invoking it.
@property(nonatomic,copy) void (^processDidExit)(void);
// Set before processDidExit, only after a matching real process-exit event.
// Main-thread only; never reset/reused for a replacement process.
@property(nonatomic,readonly) BOOL clientProcessExited;
+ (void)emitDiagnostics;
- (instancetype)initWithBundleIdentifier:(NSString *)identifier;
- (void)startWithSize:(CGSize)size completion:(void (^)(BOOL success, NSString *message))completion;
// size is the target App's logical content size, not a thumbnail's displayed
// size. Any finite positive width/height is allowed; UI minimums/aspect ratio
// belong to the caller. Frame is sent to FBScene so this is a real scene resize,
// not merely a host-view transform. Client redraw/relayout is not guaranteed.
// YES means accepted, not finished. NO never calls completion. While busy a
// second request is rejected, not queued. Accepted completions run on the main
// queue after FBScene's callback and local host layout; they do NOT prove that
// the client rendered a frame. stopForFullscreen: cancels callbacks silently.
// Callers should weakly capture their view/controller in completion.
- (BOOL)resize:(CGSize)size landscape:(BOOL)landscape completion:(void (^)(BOOL success, NSString *message))completion;
// Compatibility entry point with the same asynchronous acceptance semantics.
- (BOOL)resize:(CGSize)size landscape:(BOOL)landscape;
// Temporary portrait input presentation, frame in the overlay's screen space.
// Changes this hosted scene's frame/reference size only. YES means submitted,
// not rendered. Completion and timeout both verify applied scene/host state;
// the failure callback runs only after a real mismatch rollback. Normal
// resize/teardown supersedes pending temporary work.
- (BOOL)applyTemporaryPortraitFrame:(CGRect)frame failure:(void (^)(void))failure;
// Cleared/called inside the existing no-animation handoff before host dimensions change.
@property(nonatomic,copy) void (^znsPortraitRestorePrepareVisual)(void);
@property(nonatomic,readonly) BOOL znsPortraitHandoffInFlight;
@property(nonatomic,readonly) BOOL znsPortraitRestorePending;
- (BOOL)znsRestorePortraitAfterHide:(void (^)(BOOL success))completion;
- (void)znsCancelPortraitRestore;
- (BOOL)restoreTemporaryPortraitCanvas;
- (BOOL)restoreTemporaryPortraitCanvasWithDuration:(NSTimeInterval)duration options:(NSUInteger)options;
// Eligibility only; never starts SBS automatically. NO revokes a manual trial.
- (void)setKeyboardFocusActive:(BOOL)active;
// Reconcile the host footprint after container layout; no scene transaction,
// no transform replacement. Skipped while a scene transition is in flight.
- (void)layoutHostInCanvas;
// Main-thread only; call ONLY for an independently verified, committed user
// removal from the system switcher, never for card reuse/layout disappearance.
// Immediately drop lease/keepalive and cancel pending scene work, without
// claiming process death or erasing memory for a process that is still alive.
// The owner must then remember presentation as usual and immediately remove
// its container via stopForFullscreen:NO in the same main-thread turn. Teardown
// will skip restoration transactions because the system owns scene destruction.
- (void)prepareForSwitcherRemoval;
// Real device-lock only: withdraw the lease before system locking, cancel
// pending layouts, and let SpringBoard own scene background/geometry changes.
- (void)prepareForDeviceLock;
- (void)stopForFullscreen:(BOOL)fullscreen;
@end
