#import "ZNSWindowManager.h"
#import "ZNSAuthorization.h"
#import "ZNSActivationHooks.h"
#import "ZNSSceneSession.h"
#import "ZNSRecentApps.h"
#import "ZNSPrivate.h"
#import "ZNSGeometry.h"
#import "ZNSSecondTierPolicy.h"
#import "ZNSDipGeometry.h"
#import "ZNSDipIconView.h"
#import "ZNSKeyboardPlacement.h"
#import "ZNSPortraitKeyboardGeometry.h"

static BOOL ZNSDipEnabled=NO;
static BOOL ZNSFollowDeviceRotation=NO;
static BOOL ZNSShowWindowBars=YES;
#import "ZNSIconSwipeRecognizer.h"
#import "ZNSLayerInput.h"
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIGestureRecognizerSubclass.h>

// Prefer the actual hosting container, including iPad multitasking bounds.
// Before an overlay exists, use the main-display scene without changing its policy.
static CGSize ZNSCanvasSurfaceSize(UIView *container) {
    CGSize size=container.bounds.size;
    if (isfinite(size.width) && isfinite(size.height) && size.width>0 && size.height>0) return size;
    id scene=ZNSGet(ZNSShared(@"SBMainWorkspace"),@"mainWindowScene");
    if (![scene isKindOfClass:UIWindowScene.class] || [(UIWindowScene *)scene screen]!=UIScreen.mainScreen) {
        scene=nil;
        for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
            if ([candidate isKindOfClass:UIWindowScene.class] && [(UIWindowScene *)candidate screen]==UIScreen.mainScreen &&
                candidate.activationState==UISceneActivationStateForegroundActive) { scene=candidate; break; }
        }
    }
    if ([scene isKindOfClass:UIWindowScene.class]) size=[(UIWindowScene *)scene coordinateSpace].bounds.size;
    if (isfinite(size.width) && isfinite(size.height) && size.width>0 && size.height>0) return size;
    return UIScreen.mainScreen.bounds.size;
}

// A remote App receives content touches outside SpringBoard's recognizers.
// Arm a local, transparent selection surface only while the main window is
// behind a free thumbnail. Keep the whole selection touch local until release.
@interface ZNSStackActivationView : UIView
@property(nonatomic,copy) void (^didTouch)(void);
@property(nonatomic) BOOL armed;
@property(nonatomic) NSUInteger activeTouchCount;
- (void)refreshInput;
@end
@implementation ZNSStackActivationView
- (void)setArmed:(BOOL)armed { _armed=armed; [self refreshInput]; }
- (void)refreshInput {
    BOOL enabled=self.armed || self.activeTouchCount>0;
    self.hidden=!enabled;
    ZNSSetLayerInputEnabled(self.layer,enabled);
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    self.activeTouchCount+=touches.count;
    if(self.didTouch) self.didTouch();
    [self refreshInput];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { (void)touches; (void)event; }
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    self.activeTouchCount-=MIN(self.activeTouchCount,touches.count);
    [self refreshInput];
}
- (BOOL)accessibilityActivate {
    if(!self.armed) return NO;
    if(self.didTouch) self.didTouch();
    return YES;
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self touchesEnded:touches withEvent:event];
}
@end

// Observe local controls only; the selection surface owns its touch lifetime.
@interface ZNSStackTouchObserver : UIGestureRecognizer
@property(nonatomic,copy) void (^didTouch)(void);
@end
@implementation ZNSStackTouchObserver
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    if(![touches.anyObject.view isKindOfClass:ZNSStackActivationView.class] && self.didTouch) self.didTouch();
    self.state=UIGestureRecognizerStateFailed;
}
- (BOOL)canPreventGestureRecognizer:(UIGestureRecognizer *)other { (void)other; return NO; }
- (BOOL)canBePreventedByGestureRecognizer:(UIGestureRecognizer *)other { (void)other; return NO; }
@end

// Tracks a held resize corner from touch-down, even before a pan recognises.
// It observes only and never prevents the existing proportional resize pan.
@interface ZNSDipResizeTouchObserver : UIGestureRecognizer
@property(nonatomic,copy) void (^heldChanged)(BOOL);
@end
@implementation ZNSDipResizeTouchObserver
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches; (void)event;
    if(self.heldChanged) self.heldChanged(YES);
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { (void)touches; (void)event; }
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches; (void)event;
    self.state=UIGestureRecognizerStateFailed;
    void (^changed)(BOOL)=self.heldChanged;
    dispatch_async(dispatch_get_main_queue(),^{ if(changed) changed(NO); });
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self touchesEnded:touches withEvent:event]; }
- (BOOL)canPreventGestureRecognizer:(UIGestureRecognizer *)other { (void)other; return NO; }
- (BOOL)canBePreventedByGestureRecognizer:(UIGestureRecognizer *)other { (void)other; return NO; }
@end

// Only the two strips claim render-server input, never their enclosing box.
// The same local rectangles drive UIKit hit testing and the input layers.
@interface ZNSCornerHitView : UIView
@property(nonatomic,strong) NSArray<UIView *> *hitStrips;
- (void)setHorizontalRegion:(CGRect)horizontal sideRegion:(CGRect)side enabled:(BOOL)enabled;
@end
@implementation ZNSCornerHitView
- (instancetype)initWithFrame:(CGRect)frame {
    if(!(self=[super initWithFrame:frame])) return nil;
    UIView *horizontal=[UIView new],*side=[UIView new];
    self.hitStrips=@[horizontal,side];
    for(UIView *strip in self.hitStrips) {
        ZNSSetLayerInputOpaque(strip.layer,YES);
        [self addSubview:strip];
    }
    return self;
}
- (void)setHorizontalRegion:(CGRect)horizontal sideRegion:(CGRect)side enabled:(BOOL)enabled {
    CGRect regions[]={horizontal,side};
    CGRect enclosing=CGRectNull;
    for(unsigned i=0;i<2;i++) if(!CGRectIsNull(regions[i]) && !CGRectIsEmpty(regions[i]))
        enclosing=CGRectUnion(enclosing,regions[i]);
    BOOL active=enabled && !CGRectIsNull(enclosing) && !CGRectIsEmpty(enclosing);
    self.hidden=!active; self.userInteractionEnabled=active;
    self.frame=active?enclosing:CGRectZero;
    for(unsigned i=0;i<2;i++) {
        UIView *strip=self.hitStrips[i];
        BOOL valid=active && !CGRectIsNull(regions[i]) && !CGRectIsEmpty(regions[i]);
        strip.frame=valid?CGRectOffset(regions[i],-enclosing.origin.x,-enclosing.origin.y):CGRectZero;
        strip.hidden=!valid; strip.userInteractionEnabled=valid;
        ZNSSetLayerInputEnabled(strip.layer,valid);
    }
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    (void)event;
    if(self.hidden || !self.userInteractionEnabled) return NO;
    for(UIView *strip in self.hitStrips)
        if(!strip.hidden && CGRectContainsPoint(strip.frame,point)) return YES;
    return NO;
}
@end

@class ZNSFloatingView;
@interface ZNSOverlayWindow : UIWindow
@end
@interface ZNSRootController : UIViewController
@property(nonatomic,copy) void (^geometryChanged)(void);
@end
@interface ZNSFloatingView : UIView <UIGestureRecognizerDelegate>
@property(nonatomic) BOOL portraitKeyboardExpanded;
@property(nonatomic) CGRect portraitKeyboardSavedFrame;
@property(nonatomic) CGRect portraitKeyboardSavedExpandedFrame;
@property(nonatomic) CGRect portraitKeyboardTarget;
@property(nonatomic) BOOL portraitKeyboardSuppressed;
@property(nonatomic) BOOL portraitKeyboardRestoring;
@property(nonatomic) NSUInteger portraitKeyboardRestoreGeneration;
@property(nonatomic) NSUInteger portraitKeyboardHideRetryGeneration;
@property(nonatomic) BOOL portraitKeyboardHideRetryActive;
@property(nonatomic,copy) BOOL (^portraitKeyboardHideRetryGuard)(void);
- (void)znsAttemptPortraitHideRestore:(NSUInteger)attempt token:(NSUInteger)token;
- (void)znsRetryPortraitHideRestore:(NSUInteger)attempt token:(NSUInteger)token;

@property(nonatomic) BOOL portraitKeyboardVisualRestoring;
@property(nonatomic) BOOL portraitKeyboardVisualRestoreCompleted;
@property(nonatomic) BOOL portraitKeyboardVisualFinalizePending;
@property(nonatomic) BOOL portraitKeyboardVisualReturning;
- (void)cancelPortraitKeyboardVisualRestoreWithDuration:(NSTimeInterval)duration options:(UIViewAnimationOptions)options;
- (void)znsRestorePortraitKeyboardAfterHide;
- (void)znsResumePortraitAfterHide;
- (void)clearPortraitKeyboardVisualRestore;
@property(nonatomic) NSUInteger portraitKeyboardVisualRestoreGeneration;
@property(nonatomic) BOOL portraitKeyboardChromeFading;
- (void)expandPortraitKeyboardToFrame:(CGRect)frame duration:(NSTimeInterval)duration options:(UIViewAnimationOptions)options;
- (void)beginPortraitKeyboardVisualRestoreWithDuration:(NSTimeInterval)duration options:(UIViewAnimationOptions)options;
- (void)restorePortraitKeyboardWithDuration:(NSTimeInterval)duration options:(UIViewAnimationOptions)options;
@property(nonatomic,strong) ZNSSceneSession *session;
@property(nonatomic,strong) UIView *content;
@property(nonatomic,strong) UIView *canvasContainer;
@property(nonatomic,strong) ZNSStackActivationView *stackActivation;
@property(nonatomic) BOOL stackCovered;
- (void)updateStackActivation;
@property(nonatomic,copy) BOOL (^willActivate)(void);
@property(nonatomic,strong) UIView *bodyBackground;
@property(nonatomic,weak) UIGestureRecognizer *activeManipulation;
@property(nonatomic) BOOL needsSceneResize;
@property(nonatomic,strong) UIView *toolbar;
@property(nonatomic,strong) UIButton *topBar;
@property(nonatomic,strong) UIButton *bottomBar;
@property(nonatomic) BOOL fillHeightLayout;
@property(nonatomic) BOOL dismissing;
@property(nonatomic) BOOL fullscreenExpanding;
@property(nonatomic) CFTimeInterval chromeAnimationEpoch;
@property(nonatomic,strong) UILabel *topBarHint;
@property(nonatomic,strong) UILabel *bottomBarHint;
@property(nonatomic) CFTimeInterval barHintsDeadline;
@property(nonatomic) NSUInteger barHintsGeneration;
- (void)restartBarHints;
- (void)applyFullscreenProgress:(CGFloat)progress;
- (void)restoreChromeOpacity;
@property(nonatomic) BOOL rebounding;
@property(nonatomic) NSUInteger interactionGeneration;
- (void)cancelInteraction;
- (CGRect)defaultMainFrame;
- (CGRect)restoredMainFrame;
@property(nonatomic,strong) UIView *tools;
@property(nonatomic,strong) UILabel *message;
@property(nonatomic,strong) UIButton *restoreButton;
@property(nonatomic,strong) UIButton *thumbnailButton;
@property(nonatomic) BOOL thumbnail;
@property(nonatomic) BOOL dipped;
@property(nonatomic) BOOL dipExtracted;
@property(nonatomic) BOOL dipResizeAvailable;
@property(nonatomic) BOOL dipSavedToolsExpanded;
@property(nonatomic) BOOL dipToolbarHidden;
@property(nonatomic,copy) CGRect (^dipDockBounds)(void);
@property(nonatomic,strong) CALayer *dipOpacityMask;
- (void)updateDipAppearance;
@property(nonatomic) CGRect dipExpandedFrame;
@property(nonatomic) BOOL dipReturnLandscape;
@property(nonatomic) CGRect dipReturnFrame;
@property(nonatomic) BOOL dipReturnThumbnail;
@property(nonatomic) NSUInteger dipReturnTier;
@property(nonatomic) BOOL dipReturnFree;
@property(nonatomic) BOOL dipReturnRight;
@property(nonatomic) CGRect dipReturnParkedFrame;
@property(nonatomic,copy) BOOL (^tryDip)(void);
@property(nonatomic,copy) BOOL (^pullDip)(void);
@property(nonatomic,copy) CGRect (^parkedMovementBounds)(void);
- (CGRect)parkedMovementArea;
- (void)appIconTapped;
@property(nonatomic) BOOL thumbnailRight;
@property(nonatomic) NSUInteger thumbnailTier;
@property(nonatomic) BOOL thumbnailFree;
@property(nonatomic) BOOL parkedPerspectiveActive;
@property(nonatomic) CGFloat parkedSqueezeProgress;
@property(nonatomic) BOOL parkedBottomContact;
@property(nonatomic,strong) NSTimer *squeezeFeedbackTimer;
@property(nonatomic,strong) UIImpactFeedbackGenerator *squeezeFeedback;
- (void)updateSqueezeFeedback;
- (void)stopSqueezeFeedback;
- (BOOL)applyParkedDrag:(CGRect)proposed safe:(CGRect)safe allowDip:(BOOL)allowDip commitDip:(BOOL)commitDip;
- (void)finishParkedSqueezeAtFrame:(CGRect)target;
@property(nonatomic) CGRect thumbnailGestureFrame;
@property(nonatomic) NSTimeInterval thumbnailGestureStart;
@property(nonatomic) BOOL thumbnailGestureWasFree;
- (CGRect)thumbnailFrameInSafe:(CGRect)safe;
@property(nonatomic) BOOL dockedFromThumbnail;
@property(nonatomic) BOOL wasParkedIcon;
@property(nonatomic) BOOL rotationOverflow;
// Per hosted App lifetime; restoring/parking does not discard a manual choice.
@property(nonatomic) BOOL manualOrientationOverride;
@property(nonatomic) BOOL switcherLaunchOrientationPending;
@property(nonatomic) BOOL pendingDeviceOrientation;
@property(nonatomic) BOOL deviceLandscapeTarget;
@property(nonatomic) BOOL deviceRotationInFlight;
- (BOOL)applyPendingDeviceOrientation;
- (void)rotateHostedCanvasToLandscape:(BOOL)landscape automatic:(BOOL)automatic;
@property(nonatomic) BOOL restoreOnNextArrange;
@property(nonatomic) BOOL restoringPosition;
@property(nonatomic) BOOL portraitSaved;
@property(nonatomic) CGRect portraitFrame;
@property(nonatomic) CGSize portraitCanvas;
@property(nonatomic) NSUInteger portraitTier;
@property(nonatomic) BOOL contentInputSaved;
@property(nonatomic) BOOL contentInputOriginal;
@property(nonatomic) BOOL contentInputBlocked;
@property(nonatomic,copy) void (^presentationChanged)(void);
@property(nonatomic,copy) void (^requestFront)(void);
@property(nonatomic) NSUInteger stackOrder;
- (BOOL)isStackParticipant;
@property(nonatomic,strong) NSArray<UIView *> *corners;
@property(nonatomic,copy) void (^closeAction)(BOOL fullscreen);
@property(nonatomic,copy) CGRect (^safeBounds)(void);
@property(nonatomic,copy) CGRect (^mainSafeBounds)(void);
@property(nonatomic) BOOL docked;
@property(nonatomic) BOOL ready;
@property(nonatomic,copy) void (^activationReadyCompletion)(BOOL ready);
@property(nonatomic) BOOL connecting;
@property(nonatomic) BOOL closing;
@property(nonatomic,copy) BOOL (^canOccupy)(CGRect frame);
@property(nonatomic) CGRect expandedFrame;
@property(nonatomic) CGRect gestureFrame;
@property(nonatomic) BOOL cornerPushing;
@property(nonatomic) CGPoint cornerPushDeformation;
@property(nonatomic) BOOL cornerPushRight;
@property(nonatomic) BOOL cornerPushParking;
@property(nonatomic) CGSize lastContainerSize;
@property(nonatomic) CGRect lastSafeBounds;
@property(nonatomic) NSUInteger containerGeneration;
@property(nonatomic) NSUInteger parkedGestureGeneration;
@property(nonatomic,weak) UIPanGestureRecognizer *parkedPan;
@property(nonatomic) NSUInteger toolsGeneration;
- (instancetype)initWithFrame:(CGRect)frame bundle:(NSString *)bundle icon:(UIImage *)icon;
- (void)start;
- (BOOL)parkLiveThumbnail;
- (void)fitAfterContainerChange;
@end
@interface ZNSWindowActivation ()
@property(nonatomic,copy) NSString *notificationMode;
@property(nonatomic) BOOL ready;
@property(nonatomic) BOOL finished;
@property(nonatomic,copy) BOOL (^commitAction)(void);
@property(nonatomic,copy) void (^cancelAction)(void);
@end
@implementation ZNSWindowActivation
- (BOOL)commit {
    if (!NSThread.isMainThread || self.finished || !self.ready) return NO;
    BOOL accepted=self.commitAction && self.commitAction();
    if (!accepted) { [self cancel]; return NO; }
    self.finished=YES; self.commitAction=nil; self.cancelAction=nil;
    return YES;
}
- (void)cancel {
    if (self.finished) return;
    self.finished=YES;
    void (^cleanup)(void)=self.cancelAction;
    self.cancelAction=nil; self.commitAction=nil;
    if (cleanup) cleanup();
}
- (void)dealloc { if (!_finished && _cancelAction) _cancelAction(); }
@end

@interface ZNSWindowManager ()
@property(nonatomic,weak) ZNSWindowActivation *switcherPreparation;
@property(nonatomic,strong) ZNSWindowActivation *desktopPreparation;
- (BOOL)openDesktopBundleIdentifier:(NSString *)bundle;
@property(nonatomic,strong) ZNSSceneSession *preparedSwitcherSession;
@property(nonatomic,copy) NSString *notificationOpeningMode;
- (ZNSWindowActivation *)prepareBundleIdentifier:(NSString *)bundle switcherLaunch:(BOOL)switcherLaunch whenReady:(void (^)(BOOL))completion;
- (BOOL)presentNotificationWindow:(ZNSFloatingView *)view mode:(NSString *)mode;
@property(nonatomic,strong) ZNSOverlayWindow *window;
@property(nonatomic,strong) ZNSRootController *controller;
@property(nonatomic,strong) ZNSFloatingView *floating;
@property(nonatomic,strong) NSMutableArray<ZNSFloatingView *> *windows;
@property(nonatomic,strong) NSMutableArray<ZNSFloatingView *> *parkedOrder;
@property(nonatomic,strong) NSMutableArray<ZNSFloatingView *> *dippedOrder;
@property(nonatomic,weak) ZNSFloatingView *dipToolbarOwner;
@property(nonatomic,weak) ZNSFloatingView *dipSnapTarget;
@property(nonatomic,strong) CAShapeLayer *dipTether;
@property(nonatomic,strong) ZNSDipIconView *dipIcon;
@property(nonatomic,strong) ZNSDipIconView *dipDynamicIcon;
@property(nonatomic,weak) ZNSFloatingView *dipExtractedWindow;
@property(nonatomic,strong) UIPanGestureRecognizer *dipDynamicPan;
@property(nonatomic) CGRect dipDynamicDragFrame;
@property(nonatomic) CFTimeInterval dipRestoreDeadline;
@property(nonatomic) NSUInteger dipExtractionGeneration;
@property(nonatomic) BOOL dipExtractionEnabled;
@property(nonatomic,strong) NSTimer *dipDragonTimer;
@property(nonatomic,strong) CADisplayLink *dipDragonClock;
@property(nonatomic) CFTimeInterval dipDragonDeadline;
@property(nonatomic) NSTimeInterval dipDragonRemaining;
@property(nonatomic) CFTimeInterval dipDragonFlightStart;
@property(nonatomic) CGPoint dipDragonFlightOrigin;
@property(nonatomic) BOOL dipDragonHeld;
@property(nonatomic) BOOL dipDragonStowed;
@property(nonatomic) BOOL dipDragonReturning;
@property(nonatomic,strong) CAShapeLayer *dipDragonTether;
@property(nonatomic) CFTimeInterval dipDragonPressBegan;
@property(nonatomic) BOOL dipDragonSuppressTap;
@property(nonatomic) BOOL dipTrayRecalledOnTouch;
@property(nonatomic) BOOL dipDragonDeparting;
- (void)beginDipRestoreConfirmation;
- (void)setDipResizeHeld:(BOOL)held window:(ZNSFloatingView *)card;
- (void)cancelDipRestoreConfirmation;
- (void)recallDipDragon;
- (void)dipTrayPressed:(UIControl *)sender;
- (void)stopDipDragonMotion;
- (void)scheduleDipDragonHide;
- (void)swimDipDragonHome:(BOOL)home;
- (void)disableDipExtractionWhenReady;
- (void)updateDipDynamicIcon;
- (void)extractDipWindow:(ZNSFloatingView *)view;
- (void)clearDipExtraction;
- (void)returnExtractedDip;
- (void)returnExtractedDipSelecting:(ZNSFloatingView *)next;
@property(nonatomic,strong) UIPanGestureRecognizer *dipIconPan;
@property(nonatomic) CGRect dipIconDragFrame;
@property(nonatomic) BOOL dipIconManuallyPlaced;
@property(nonatomic) NSInteger dipSnapCorner;
- (void)updateDipIcon;
- (void)updateDipMotion;
- (void)updateDipIconTetherSelecting:(BOOL)select;
- (BOOL)canPlaceDipIcon:(CGRect)frame;
@property(nonatomic,strong) NSHashTable<UIView *> *desktopDockViews;
@property(nonatomic) NSUInteger maxDippedApps;
@property(nonatomic) BOOL dipEvictionPacking;
- (CGRect)desktopDockFrame;
- (void)ejectOldestDipToParking;
- (void)clearDipTether;
- (BOOL)dipWindow:(ZNSFloatingView *)view;
- (BOOL)pullDippedWindow:(ZNSFloatingView *)view;
- (void)layoutDippedWindows:(BOOL)animated;
- (void)releaseDippedToParking;
- (CGRect)parkedMovementFrame;
- (CGFloat)dipReservedTop;
@property(nonatomic,weak) ZNSFloatingView *pendingIconRestore;
@property(nonatomic) BOOL arranging;
@property(nonatomic) BOOL closingAllWindows;
@property(nonatomic) BOOL deviceLockClosing;
@property(nonatomic) BOOL arrangeScheduled;
@property(nonatomic) NSUInteger maxParkedApps;
@property(nonatomic) NSUInteger nextStackOrder;
- (void)raiseWindow:(ZNSFloatingView *)view;
- (void)updateWindowStack;
@property(nonatomic) CGRect lastAvailableFrame;
@property(nonatomic) CGRect lastMainAvailableFrame;
@property(nonatomic) UIEdgeInsets mainStatusInsets;
@property(nonatomic) UIInterfaceOrientation mainStatusOrientation;
- (CGRect)mainAvailableFrame;
- (void)arrangeParked;
- (BOOL)activateWindow:(ZNSFloatingView *)view;
- (void)closeWindow:(ZNSFloatingView *)view fullscreen:(BOOL)fullscreen;
- (void)finishCloseWindow:(ZNSFloatingView *)view fullscreen:(BOOL)fullscreen;
@property(nonatomic,strong) UIButton *outsideButton;
@property(nonatomic,strong) UIView *keyboardDismissShield;
@property(nonatomic) BOOL keyboardDismissClosesWindow;
@property(nonatomic,copy) NSString *keyboardDismissCloseOrientation;
- (void)refreshKeyboardDismissShield;
- (BOOL)consumeKeyboardOutsideTap:(UITapGestureRecognizer *)gesture;
- (void)keyboardOutsideTapped:(UITapGestureRecognizer *)gesture;
- (void)portraitKeyboardGeometryChanged:(NSNotification *)notification;
- (void)externalKeyboardVisibilityChanged:(NSNotification *)notification;
- (void)updateOutsideButton;
@property(nonatomic) BOOL enabled;
@property(nonatomic,copy) NSString *iconGesture;
@property(nonatomic,strong) NSSet<NSString *> *excluded;
@property(nonatomic,strong) NSHashTable<UIView *> *iconViews;
- (void)close:(BOOL)fullscreen;
@end

@implementation ZNSOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit=[super hitTest:point withEvent:event];
    return (hit==self || hit==self.rootViewController.view) ? nil : hit;
}
- (BOOL)canBecomeKeyWindow { return NO; }
@end
@implementation ZNSRootController
- (void)loadView { self.view=[UIView new]; self.view.backgroundColor=UIColor.clearColor; }
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; if (self.geometryChanged) self.geometryChanged(); }
- (void)viewSafeAreaInsetsDidChange { [super viewSafeAreaInsetsDidChange]; if (self.geometryChanged) self.geometryChanged(); }
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAllButUpsideDown; }
@end

static void ZNSAnimate(NSTimeInterval duration, void (^changes)(void)) {
    [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled()?0:duration delay:0
        options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction|UIViewAnimationOptionCurveEaseOut
        animations:changes completion:nil];
}

static void ZNSCornerColor(CAShapeLayer *shape,BOOL enabled,CFTimeInterval epoch) {
    if(!enabled || UIAccessibilityIsReduceMotionEnabled()) {
        [shape removeAnimationForKey:@"ZNSCornerCycle"]; return;
    }
    if([shape animationForKey:@"ZNSCornerCycle"]) return;
    CAKeyframeAnimation *color=[CAKeyframeAnimation animationWithKeyPath:@"strokeColor"];
    color.values=@[(__bridge id)UIColor.whiteColor.CGColor,(__bridge id)UIColor.systemRedColor.CGColor,
                   (__bridge id)UIColor.systemOrangeColor.CGColor,(__bridge id)UIColor.whiteColor.CGColor];
    color.keyTimes=@[@0,@(1.0/3.0),@(2.0/3.0),@1];
    color.calculationMode=kCAAnimationDiscrete;
    // One colour per bounce; colour changes occur at the invisible near point.
    color.duration=3*1.8; color.repeatCount=HUGE_VALF;
    color.beginTime=[shape convertTime:epoch fromLayer:nil];
    [shape addAnimation:color forKey:@"ZNSCornerCycle"];
}

static void ZNSChromeBounce(UIView *line,CGPoint away,BOOL enabled,CFTimeInterval epoch) {
    if(!enabled || UIAccessibilityIsReduceMotionEnabled()) {
        [line.layer removeAnimationForKey:@"ZNSChromeBounce"]; return;
    }
    if([line.layer animationForKey:@"ZNSChromeBounce"]) return;
    // Shared timing, radial travel and opacity for bars and corners. Only the
    // visual child moves; the fixed, App-safe gesture container does not.
    // Additive position animation leaves the layout's scale transform intact.
    CAKeyframeAnimation *move=[CAKeyframeAnimation animationWithKeyPath:@"position"];
    move.additive=YES;
    move.values=@[[NSValue valueWithCGPoint:CGPointMake(-away.x,-away.y)],
                  [NSValue valueWithCGPoint:CGPointMake(away.x,away.y)],
                  [NSValue valueWithCGPoint:CGPointMake(-away.x,-away.y)]];
    move.keyTimes=@[@0,@0.5,@1];
    move.timingFunctions=@[[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut],
                           [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];
    CAKeyframeAnimation *fade=[CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    fade.values=@[@0,@1,@0]; fade.keyTimes=move.keyTimes; fade.timingFunctions=move.timingFunctions;
    CAAnimationGroup *group=[CAAnimationGroup animation];
    move.duration=fade.duration=group.duration=1.8;
    group.animations=@[move,fade]; group.repeatCount=HUGE_VALF;
    group.beginTime=[line.layer convertTime:epoch fromLayer:nil];
    [line.layer addAnimation:group forKey:@"ZNSChromeBounce"];
}

static void ZNSActionFeedback(void) {
    static UIImpactFeedbackGenerator *feedback;
    static dispatch_once_t once;
    dispatch_once(&once,^{ feedback=[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight]; });
    [feedback impactOccurred];
    [feedback prepare];
}

static void ZNSSoftFeedback(void) {
    static UIImpactFeedbackGenerator *feedback;
    static dispatch_once_t once;
    dispatch_once(&once,^{ feedback=[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleSoft]; });
    [feedback prepare];
    [feedback impactOccurredWithIntensity:0.35];
}

// Project a live surface onto a convex quad: three corners stay fixed and
// only the pushed bottom corner yields. Coordinates are layer-center relative.
static CATransform3D ZNSCornerPushTransform(CGSize size,BOOL right,CGPoint offset) {
    CGFloat w=size.width,h=size.height;
    if(!isfinite(w) || !isfinite(h) || w<=0 || h<=0) return CATransform3DIdentity;
    CGPoint p[4]={{-w/2,-h/2},{w/2,-h/2},{w/2,h/2},{-w/2,h/2}};
    NSUInteger index=right?2:3;
    p[index].x+=ZNSClamp(offset.x,-w*0.18,w*0.18);
    p[index].y+=ZNSClamp(offset.y,-h*0.15,h*0.15);
    CGFloat dx1=p[1].x-p[2].x,dx2=p[3].x-p[2].x;
    CGFloat dy1=p[1].y-p[2].y,dy2=p[3].y-p[2].y;
    CGFloat dx3=p[0].x-p[1].x+p[2].x-p[3].x;
    CGFloat dy3=p[0].y-p[1].y+p[2].y-p[3].y;
    CGFloat det=dx1*dy2-dx2*dy1;
    if(fabs(det)<0.001) return CATransform3DIdentity;
    CGFloat g=(dx3*dy2-dx2*dy3)/det,k=(dx1*dy3-dx3*dy1)/det;
    CGFloat a=p[1].x-p[0].x+g*p[1].x,b=p[3].x-p[0].x+k*p[3].x;
    CGFloat d=p[1].y-p[0].y+g*p[1].y,e=p[3].y-p[0].y+k*p[3].y;
    CATransform3D t=CATransform3DIdentity;
    t.m11=a/w; t.m21=b/h; t.m41=p[0].x+(a+b)/2;
    t.m12=d/w; t.m22=e/h; t.m42=p[0].y+(d+e)/2;
    t.m14=g/w; t.m24=k/h; t.m44=1+(g+k)/2;
    return t;
}

@implementation ZNSFloatingView
#include "ZNSPortraitFloating.inc"
- (BOOL)isStackParticipant {
    return !self.closing && !self.dipped && !self.docked && (!self.thumbnail || self.thumbnailFree);
}
- (instancetype)initWithFrame:(CGRect)frame bundle:(NSString *)bundle icon:(UIImage *)icon {
    if (!(self=[super initWithFrame:frame])) return nil;
    __weak typeof(self) weakSelf=self;
    _chromeAnimationEpoch=CACurrentMediaTime();
    ZNSStackTouchObserver *observer=[[ZNSStackTouchObserver alloc] initWithTarget:nil action:NULL];
    observer.cancelsTouchesInView=NO; observer.delaysTouchesBegan=NO; observer.delaysTouchesEnded=NO;
    observer.didTouch=^{ if(weakSelf.isStackParticipant && !weakSelf.thumbnail && weakSelf.requestFront) weakSelf.requestFront(); };
    [self addGestureRecognizer:observer];
    self.accessibilityIdentifier=@"ZNSFloatingWindow";
    self.backgroundColor=UIColor.clearColor;
    _bodyBackground=[UIView new];
    _bodyBackground.userInteractionEnabled=NO;
    // Keep the existing geometry/hit regions, but never paint the reserved
    // gutter: its scaled thumbnail inset otherwise becomes a thick light rim.
    _bodyBackground.backgroundColor=UIColor.clearColor;
    _bodyBackground.layer.cornerRadius=16; _bodyBackground.layer.borderWidth=0;
    _bodyBackground.layer.borderColor=UIColor.clearColor.CGColor;
    _bodyBackground.layer.shadowColor=UIColor.blackColor.CGColor;
    _bodyBackground.layer.shadowOpacity=0.24; _bodyBackground.layer.shadowRadius=16;
    _bodyBackground.layer.shadowOffset=CGSizeMake(0,5);
    [self addSubview:_bodyBackground];
    _session=[[ZNSSceneSession alloc] initWithBundleIdentifier:bundle];
    _content=[UIView new]; _content.backgroundColor=UIColor.blackColor;
    _content.clipsToBounds=YES; _content.layer.cornerRadius=12; [self addSubview:_content];
    _contentInputSaved=ZNSReadLayerHitFlag(_content.layer,NSSelectorFromString(@"allowsHitTesting"),&_contentInputOriginal);
    _canvasContainer=[UIView new]; [_content addSubview:_canvasContainer];
    // Stay blank while connecting; only the completion failure shows text.
    _message=[UILabel new]; _message.hidden=YES;
    _message.textColor=UIColor.lightGrayColor; _message.font=[UIFont systemFontOfSize:14];
    _message.numberOfLines=0; _message.textAlignment=NSTextAlignmentCenter;
    [_content addSubview:_message];
    _stackActivation=[ZNSStackActivationView new];
    _stackActivation.backgroundColor=UIColor.clearColor;
    _stackActivation.multipleTouchEnabled=YES;
    _stackActivation.accessibilityIdentifier=@"ZNSRaiseMainContent";
    _stackActivation.isAccessibilityElement=YES;
    _stackActivation.accessibilityLabel=@"将主分屏置顶";
    _stackActivation.didTouch=^{
        if(weakSelf.isStackParticipant && !weakSelf.thumbnail && weakSelf.requestFront) weakSelf.requestFront();
    };
    BOOL stackShield=ZNSSetLayerInputOpaque(_stackActivation.layer,YES);
    _stackActivation.armed=NO;
    [_content addSubview:_stackActivation];
    os_log(ZNSLog(),"main content selection shield configured=%d",stackShield);
    _toolbar=[UIView new]; [self addSubview:_toolbar];
    _toolbar.accessibilityLabel=@"窗口控制栏，可拖动";
    _tools=[[UIView alloc] initWithFrame:CGRectMake(0,0,150,32)]; [_toolbar addSubview:_tools];
    _tools.backgroundColor=UIColor.secondarySystemBackgroundColor;
    _tools.layer.cornerRadius=10;
    _tools.layer.borderWidth=0.5;
    _tools.layer.borderColor=[UIColor.labelColor colorWithAlphaComponent:0.18].CGColor;
    UIImageView *appIcon=[[UIImageView alloc] initWithFrame:CGRectMake(4,4,24,24)];
    appIcon.image=icon ?: [UIImage systemImageNamed:@"app.fill"];
    appIcon.contentMode=UIViewContentModeScaleAspectFit; appIcon.layer.cornerRadius=7; appIcon.clipsToBounds=YES;
    appIcon.accessibilityLabel=@"应用图标"; appIcon.tag=914; [_tools addSubview:appIcon];
    appIcon.userInteractionEnabled=YES;
    [appIcon addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(appIconTapped)]];
    NSArray *colors=@[UIColor.systemRedColor,UIColor.systemYellowColor,UIColor.systemGreenColor];
    NSArray *labels=@[@"关闭小窗",@"最小化为悬浮图标",@"全屏打开"];
    NSArray *symbols=@[@"xmark",@"minus",@"arrow.up.left.and.arrow.down.right"];
    for (NSUInteger i=0;i<3;i++) {
        UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];
        button.frame=CGRectMake(30+28*i,0,28,32); button.tag=i;
        button.accessibilityLabel=labels[i]; button.accessibilityIdentifier=[@"ZNSControl" stringByAppendingFormat:@"%lu",(unsigned long)i];
        UIView *dot=[[UIView alloc] initWithFrame:CGRectMake(2,4,24,24)];
        dot.backgroundColor=colors[i]; dot.layer.cornerRadius=12; dot.userInteractionEnabled=NO; [button addSubview:dot];
        UIImageView *glyph=[[UIImageView alloc] initWithFrame:CGRectMake(7,9,14,14)];
        glyph.image=[UIImage systemImageNamed:symbols[i]]; glyph.tintColor=[UIColor.blackColor colorWithAlphaComponent:0.65];
        glyph.contentMode=UIViewContentModeScaleAspectFit; [button addSubview:glyph];
        [button addTarget:self action:@selector(control:) forControlEvents:UIControlEventTouchUpInside];
        [_tools addSubview:button];
    }
    UIButton *rotate=[UIButton buttonWithType:UIButtonTypeSystem]; rotate.frame=CGRectMake(116,0,30,32);
    rotate.accessibilityLabel=@"切换应用横竖屏"; rotate.accessibilityIdentifier=@"ZNSRotate"; rotate.tag=3;
    [rotate setImage:[UIImage systemImageNamed:@"rotate.right" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightRegular]] forState:UIControlStateNormal];
    [rotate addTarget:self action:@selector(rotateApp) forControlEvents:UIControlEventTouchUpInside];
    [_tools addSubview:rotate];
    UIPanGestureRecognizer *drag=[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)];
    drag.cancelsTouchesInView=YES; drag.maximumNumberOfTouches=1;
    drag.delegate=self; [_toolbar addGestureRecognizer:drag];
    UITapGestureRecognizer *tap=[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(appIconTapped)];
    tap.delegate=self; tap.cancelsTouchesInView=NO; [tap requireGestureRecognizerToFail:drag]; [_toolbar addGestureRecognizer:tap];
    _topBar=[UIButton buttonWithType:UIButtonTypeCustom];
    _bottomBar=[UIButton buttonWithType:UIButtonTypeCustom];
    NSArray<UIButton *> *bars=@[_topBar,_bottomBar];
    for(NSUInteger i=0;i<bars.count;i++) {
        UIButton *bar=bars[i]; bar.tag=i;
        bar.backgroundColor=UIColor.clearColor;
        UIView *line=[UIView new]; line.userInteractionEnabled=NO;
        line.backgroundColor=UIColor.whiteColor; line.layer.cornerRadius=ZNSBarThickness()/2;
        [bar addSubview:line];
        UILabel *hint=[UILabel new];
        hint.text=i?@"上滑/点击-退出APP":@"上滑放大/点击全屏";
        hint.font=[UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        hint.textColor=UIColor.whiteColor;
        hint.textAlignment=NSTextAlignmentCenter;
        hint.adjustsFontSizeToFitWidth=YES; hint.minimumScaleFactor=0.65;
        hint.shadowColor=[UIColor.blackColor colorWithAlphaComponent:0.8];
        hint.shadowOffset=CGSizeMake(0,1);
        hint.userInteractionEnabled=NO; hint.hidden=YES;
        hint.accessibilityIdentifier=i?@"ZNSBottomBarHint":@"ZNSTopBarHint";
        // A child of the visual line inherits its exact fade and movement;
        // neither the label nor its extra width changes the fixed hit region.
        [line addSubview:hint];
        if(i) _bottomBarHint=hint; else _topBarHint=hint;
        bar.accessibilityIdentifier=i?@"ZNSBottomBar":@"ZNSTopBar";
        bar.accessibilityLabel=i?@"关闭小窗，上滑跟手关闭":@"全屏打开应用，上滑跟手放大进入全屏";
        ZNSSetLayerInputOpaque(bar.layer,YES);
        UITapGestureRecognizer *barTap=[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(barTapped:)];
        barTap.delegate=self; [bar addGestureRecognizer:barTap];
        UIPanGestureRecognizer *pan=[[UIPanGestureRecognizer alloc] initWithTarget:self action:i?@selector(dismissPanned:):@selector(fullscreenPanned:)];
        pan.maximumNumberOfTouches=1; pan.delegate=self; [bar addGestureRecognizer:pan];
        [barTap requireGestureRecognizerToFail:pan];
        [self addSubview:bar];
    }
    NSMutableArray *corners=[NSMutableArray new];
    for (NSUInteger i=0;i<4;i++) {
        ZNSCornerHitView *handle=[[ZNSCornerHitView alloc] initWithFrame:CGRectZero]; handle.tag=i;
        handle.accessibilityLabel=i>=2?(i==2?@"左下推动角":@"右下推动角"):[NSString stringWithFormat:@"缩放角%lu",(unsigned long)i+1];
        handle.accessibilityIdentifier=[NSString stringWithFormat:@"ZNSResize%lu",(unsigned long)i];
        handle.accessibilityHint=i>=2?@"按住推动可回拉；松手轻推复原，充分推向左或右则弹到对应侧一档空挂":@"上角等比缩放，保持应用内容比例与逻辑画布不变";
        UIView *arc=[[UIView alloc] initWithFrame:CGRectMake(0,0,32,32)];
        arc.userInteractionEnabled=NO;
        ZNSSetLayerInputEnabled(arc.layer,NO);
        CAShapeLayer *stroke=[CAShapeLayer layer];
        stroke.fillColor=UIColor.clearColor.CGColor; stroke.strokeColor=UIColor.whiteColor.CGColor;
        stroke.lineWidth=1.5; stroke.lineCap=kCALineCapRound;
        [arc.layer addSublayer:stroke];
        [handle insertSubview:arc atIndex:0];
        UIPanGestureRecognizer *resize=[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(resizeGesture:)];
        resize.delegate=self; [handle addGestureRecognizer:resize];
        if(i==1) {
            ZNSDipResizeTouchObserver *hold=[ZNSDipResizeTouchObserver new];
            hold.cancelsTouchesInView=NO; hold.delaysTouchesBegan=NO; hold.delaysTouchesEnded=NO;
            __weak typeof(self) weakView=self;
            hold.heldChanged=^(BOOL held) {
                ZNSFloatingView *view=weakView;
                if(view.dipExtracted && view.dipResizeAvailable)
                    [[ZNSWindowManager shared] setDipResizeHeld:held window:view];
            };
            [handle addGestureRecognizer:hold];
        }
        [corners addObject:handle]; [self addSubview:handle];
    }
    _corners=corners;
    _restoreButton=[UIButton buttonWithType:UIButtonTypeCustom];
    _restoreButton.accessibilityLabel=@"恢复分屏小窗"; _restoreButton.accessibilityIdentifier=@"ZNSRestore";
    [_restoreButton setImage:appIcon.image forState:UIControlStateNormal];
    _restoreButton.imageView.contentMode=UIViewContentModeScaleAspectFit;
    _restoreButton.layer.cornerRadius=17; _restoreButton.clipsToBounds=YES;
    _restoreButton.backgroundColor=[UIColor colorWithWhite:0.12 alpha:0.85];
    _restoreButton.layer.borderWidth=1.25;
    _restoreButton.layer.borderColor=[UIColor colorWithWhite:1 alpha:0.85].CGColor;
    _restoreButton.imageEdgeInsets=UIEdgeInsetsMake(1.5,1.5,1.5,1.5);
    _restoreButton.imageView.layer.cornerRadius=14;
    _restoreButton.imageView.clipsToBounds=YES;
    _restoreButton.accessibilityHint=@"轻点恢复，拖动移动，长按关闭窗口";
    UIPanGestureRecognizer *iconDrag=[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragDocked:)];
    [_restoreButton addGestureRecognizer:iconDrag];
    UILongPressGestureRecognizer *iconHold=[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(dockedHeld:)];
    iconHold.minimumPressDuration=0.55; iconHold.allowableMovement=10; iconHold.cancelsTouchesInView=YES;
    [_restoreButton addGestureRecognizer:iconHold];
    UITapGestureRecognizer *iconTap=[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dockedTapped:)];
    [iconTap requireGestureRecognizerToFail:iconDrag];
    [iconTap requireGestureRecognizerToFail:iconHold];
    [_restoreButton addGestureRecognizer:iconTap];
    _restoreButton.hidden=YES; [self addSubview:_restoreButton];
    _thumbnailButton=[UIButton buttonWithType:UIButtonTypeCustom];
    _thumbnailButton.accessibilityLabel=@"实时缩略窗，点击恢复小窗";
    _thumbnailButton.accessibilityIdentifier=@"ZNSLiveThumbnail";
    UITapGestureRecognizer *restoreTap=[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(thumbnailTapped:)];
    restoreTap.cancelsTouchesInView=YES;
    [_thumbnailButton addGestureRecognizer:restoreTap];
    _thumbnailButton.accessibilityHint=@"下滑放大一档，上滑关闭，左右滑换边或收为图标，长按旋转";
    UIPanGestureRecognizer *thumbnailPan=[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(thumbnailPanned:)];
    thumbnailPan.maximumNumberOfTouches=1;
    thumbnailPan.cancelsTouchesInView=YES;
    [_thumbnailButton addGestureRecognizer:thumbnailPan];
    [restoreTap requireGestureRecognizerToFail:thumbnailPan];
    UILongPressGestureRecognizer *hold=[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(thumbnailHeld:)];
    hold.minimumPressDuration=0.55; hold.cancelsTouchesInView=YES;
    [_thumbnailButton addGestureRecognizer:hold];
    [restoreTap requireGestureRecognizerToFail:hold];
    _thumbnailButton.hidden=YES; [self addSubview:_thumbnailButton];
    BOOL thumbnailShield=ZNSSetLayerInputOpaque(_thumbnailButton.layer,YES);
    os_log(ZNSLog(),"thumbnail input shield configured=%d contentGateAvailable=%d",thumbnailShield,_contentInputSaved);
    _tools.userInteractionEnabled=NO;
    _tools.layer.anchorPoint=CGPointMake(0,0.5); _tools.center=CGPointMake(0,16);
    _tools.transform=CGAffineTransformMakeScale(0.50,0.50);
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(motionPreferenceChanged:) name:UIAccessibilityReduceMotionStatusDidChangeNotification object:nil];
    return self;
}
- (void)restartBarHints {
    // Only opening/restoring a main window resets this clock. Layout, rotation,
    // touching content and tool expansion must never extend the three cycles.
    self.chromeAnimationEpoch=CACurrentMediaTime();
    NSTimeInterval duration=3*1.8;
    self.barHintsDeadline=self.chromeAnimationEpoch+duration;
    NSUInteger generation=++self.barHintsGeneration;
    for(UIView *handle in self.corners) {
        UIView *arc=handle.subviews.firstObject;
        [arc.layer removeAnimationForKey:@"ZNSChromeBounce"];
        [arc.layer.sublayers.firstObject removeAnimationForKey:@"ZNSCornerCycle"];
    }
    for(UIButton *bar in @[self.topBar,self.bottomBar])
        [bar.subviews.firstObject.layer removeAnimationForKey:@"ZNSChromeBounce"];
    for(UILabel *hint in @[self.topBarHint,self.bottomBarHint]) {
        [hint.layer removeAnimationForKey:@"ZNSHintLifetime"];
        hint.hidden=NO;
        // Model opacity stays zero: the render server hides the text at the
        // exact third trough even if the main queue is briefly busy.
        hint.layer.opacity=0;
        CABasicAnimation *lifetime=[CABasicAnimation animationWithKeyPath:@"opacity"];
        lifetime.fromValue=@1; lifetime.toValue=@1; lifetime.duration=duration;
        lifetime.beginTime=[hint.layer convertTime:self.chromeAnimationEpoch fromLayer:nil];
        [hint.layer addAnimation:lifetime forKey:@"ZNSHintLifetime"];
    }
    [self setNeedsLayout];
    __weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(duration*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        ZNSFloatingView *view=weakSelf;
        if(!view || view.barHintsGeneration!=generation) return;
        view.topBarHint.hidden=YES; view.bottomBarHint.hidden=YES;
    });
}
- (void)motionPreferenceChanged:(NSNotification *)note { (void)note; [self setNeedsLayout]; }
- (CGRect)mainSafe { return self.mainSafeBounds ? self.mainSafeBounds() : (self.safeBounds ? self.safeBounds() : self.superview.bounds); }
- (CGRect)safe {
    if(!self.thumbnail && !self.docked) return [self mainSafe];
    return self.safeBounds ? self.safeBounds() : self.superview.bounds;
}
- (CGRect)parkedMovementArea { return self.parkedMovementBounds?self.parkedMovementBounds():self.superview.bounds; }
- (CGRect)thumbnailFrameInSafe:(CGRect)safe {
    if(!self.thumbnail && !self.docked && self.safeBounds) safe=self.safeBounds();
    CGSize canvas=self.session.canvasSize;
    if (canvas.width<=0 || canvas.height<=0) canvas=ZNSScreenCanvas(ZNSCanvasSurfaceSize(self.superview),self.session.landscape);
    CGRect bounds=self.thumbnailFree?[self parkedMovementArea]:safe;
    CGRect target=ZNSThumbnailTierFrame(canvas,bounds,self.thumbnailRight,(unsigned)self.thumbnailTier);
    if (self.thumbnailFree) target.origin=CGPointMake(self.center.x-target.size.width/2,self.center.y-target.size.height/2);
    else if (self.thumbnail) target.origin.y=self.frame.origin.y;
    return ZNSConstrainIcon(target,bounds);
}
- (CGSize)desiredCanvas {
    // The logical App canvas never depends on its presentation footprint.
    return ZNSScreenCanvas(ZNSCanvasSurfaceSize(self.superview),self.session.landscape);
}
- (CGRect)defaultMainFrame {
    self.fillHeightLayout=self.superview.bounds.size.width>self.superview.bounds.size.height && !self.session.landscape;
    return ZNSDefaultMainWindow([self mainSafe],ZNSCanvasSurfaceSize(self.superview),self.session.landscape);
}
- (CGRect)restoredMainFrame {
    if(self.superview.bounds.size.width>self.superview.bounds.size.height) return [self defaultMainFrame];
    self.fillHeightLayout=NO;
    CGRect frame=ZNSFitMainWindow(self.expandedFrame,[self safe],NO);
    return CGRectIsEmpty(frame)?[self defaultMainFrame]:frame;
}
- (void)start {
    self.connecting=YES;
    if (self.presentationChanged) self.presentationChanged();
    __weak typeof(self) weakSelf=self;
    [self.session startWithSize:[self desiredCanvas] completion:^(BOOL success,NSString *message) {
        ZNSFloatingView *self=weakSelf; if (!self || self.closing || !self.superview) return;
        self.connecting=NO;
        self.ready=success; self.message.text=message;
        self.message.hidden=success;
        if (success) {
            [self attachHost];
            ZNSPromoteRecentApp(self.session);
        }
        else os_log_error(ZNSLog(),"window reports scene unavailable");
        void (^readyCompletion)(BOOL)=self.activationReadyCompletion;
        self.activationReadyCompletion=nil;
        if (self.presentationChanged) self.presentationChanged();
        if (readyCompletion) readyCompletion(success);
    }];
}
- (void)attachHost {
    UIView *host=self.session.hostView;
    if (host && host.superview!=self.canvasContainer) [self.canvasContainer insertSubview:host atIndex:0];
    [self setNeedsLayout]; [self layoutIfNeeded];
}
- (void)setStackCovered:(BOOL)covered {
    _stackCovered=covered;
    [self updateStackActivation];
}
- (void)updateStackActivation {
    self.stackActivation.armed=self.stackCovered && !self.thumbnail && !self.docked && !self.dipped &&
        !self.closing && !self.dismissing && !self.rebounding && !self.session.layoutInFlight;
}
- (void)updateContentInputGate {
    [self updateStackActivation];
    // UIKit hit tests are gated too, even if the existing remote layer-input
    // capability is unavailable. Normal-state policy matches layoutSubviews.
    self.content.userInteractionEnabled=!self.portraitKeyboardVisualRestoring && !self.thumbnail && !self.dipped;
    BOOL block=self.portraitKeyboardVisualRestoring || self.parkedBottomContact || self.cornerPushing || self.closing || self.dipped || self.dismissing || self.rebounding || self.thumbnail || self.docked || self.session.layoutInFlight;
    if (block==self.contentInputBlocked) return;
    BOOL applied=self.contentInputSaved && ZNSSetLayerInputEnabled(self.content.layer,block?NO:self.contentInputOriginal);
    if (applied) self.contentInputBlocked=block;
    os_log(ZNSLog(),"content layer input gate blocked=%d applied=%d",block,applied);
}
- (void)dealloc {
    [_squeezeFeedbackTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_contentInputSaved && _contentInputBlocked) ZNSSetLayerInputEnabled(_content.layer,_contentInputOriginal);
}
- (void)updateDipAppearance {
    self.bodyBackground.layer.shadowOpacity=self.dipped?0:0.24;
    if(!self.dipped) {
        if(self.content.layer.mask==self.dipOpacityMask) self.content.layer.mask=nil;
        self.dipOpacityMask=nil;
        return;
    }
    CGRect dock=(!self.dipExtracted && self.dipDockBounds)?self.dipDockBounds():CGRectNull;
    UIBezierPath *outside=[UIBezierPath bezierPathWithRect:self.content.bounds];
    UIBezierPath *inside=[UIBezierPath bezierPath];
    if(!CGRectIsNull(dock) && !CGRectIsEmpty(dock) && self.superview) {
        CGPoint corners[4]={{CGRectGetMinX(dock),CGRectGetMinY(dock)},{CGRectGetMaxX(dock),CGRectGetMinY(dock)},
            {CGRectGetMaxX(dock),CGRectGetMaxY(dock)},{CGRectGetMinX(dock),CGRectGetMaxY(dock)}};
        for(NSUInteger i=0;i<4;i++) {
            CGPoint p=[self.content convertPoint:corners[i] fromView:self.superview];
            if(i) [inside addLineToPoint:p]; else [inside moveToPoint:p];
        }
        [inside closePath]; [outside appendPath:inside];
    }
    if(!self.dipOpacityMask) {
        self.dipOpacityMask=[CALayer layer];
        [self.dipOpacityMask addSublayer:[CAShapeLayer layer]];
        [self.dipOpacityMask addSublayer:[CAShapeLayer layer]];
    }
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    self.dipOpacityMask.frame=self.content.bounds; self.dipOpacityMask.masksToBounds=YES;
    CAShapeLayer *normal=(CAShapeLayer *)self.dipOpacityMask.sublayers[0];
    CAShapeLayer *overDock=(CAShapeLayer *)self.dipOpacityMask.sublayers[1];
    normal.frame=self.content.bounds; normal.path=outside.CGPath; normal.fillRule=kCAFillRuleEvenOdd;
    normal.fillColor=[UIColor colorWithWhite:1 alpha:0.60].CGColor;
    overDock.frame=self.content.bounds; overDock.path=inside.CGPath;
    overDock.fillColor=[UIColor colorWithWhite:1 alpha:0.22].CGColor;
    self.content.layer.mask=self.dipOpacityMask;
    [CATransaction commit];
}
- (void)setDipResizeAvailable:(BOOL)available {
    if(_dipResizeAvailable==available) return;
    _dipResizeAvailable=available;
    [self setNeedsLayout];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.portraitKeyboardVisualRestoring || self.session.znsPortraitRestorePending) return;
    [self updateContentInputGate];
    BOOL expanded=self.tools.userInteractionEnabled;
    BOOL parked=self.docked || self.thumbnail;
    BOOL deviceLandscape=self.superview.bounds.size.width>self.superview.bounds.size.height;
    CGRect reference=ZNSMainReferenceWindow([self safe],ZNSCanvasSurfaceSize(self.superview),self.session.landscape);
    CGFloat chromeScale=parked?1:ZNSMainDecorationScale(self.bounds,reference);
    CGAffineTransform toolbarTransform=self.dipped?self.toolbar.transform:CGAffineTransformIdentity;
    self.toolbar.transform=CGAffineTransformIdentity;
    self.toolbar.frame=ZNSMainToolsFrame(self.bounds,expanded);
    self.toolbar.transform=toolbarTransform;
    [self.tools viewWithTag:3].hidden=!expanded;
    self.tools.bounds=CGRectMake(0,0,expanded?150:116,32);
    CGFloat toolScale=ZNSMainToolScale(self.toolbar.bounds.size.width,expanded)*chromeScale;
    if(deviceLandscape && self.session.landscape) toolScale*=1.5;
    self.tools.transform=CGAffineTransformMakeScale(toolScale,toolScale);
    // Keep the left anchor and bottom gap while only the visible tools shrink.
    self.tools.center=CGPointMake(0,self.toolbar.bounds.size.height-16*toolScale);
    for(UIView *control in self.tools.subviews) if([control isKindOfClass:UIButton.class]) {
        control.hidden=self.dipped || (control.tag==3 && !expanded);
        control.userInteractionEnabled=!self.dipped;
    }
    if(self.dipped) {
        CGFloat size=expanded?48:32;
        self.toolbar.bounds=CGRectMake(0,0,size,size);
        self.toolbar.center=CGPointMake(8+size/2,24);
        self.tools.bounds=CGRectMake(0,0,32,32);
        self.tools.transform=CGAffineTransformMakeScale(size/32,size/32);
        self.tools.center=CGPointMake(size/2,size/2);
    }
    // Reset visual-only tilt before writing frames; the outer window and its
    // gesture/packing rectangle always remain untransformed.
    self.content.layer.transform=CATransform3DIdentity;
    self.bodyBackground.layer.transform=CATransform3DIdentity;
    // Bars share the existing toolbar row; no extra vertical gap or side rail.
    self.bodyBackground.frame=parked?self.bounds:ZNSMainBody(self.bounds);
    self.toolbar.hidden=parked || self.dipped;
    // The display preference hides only the visual line (and its label), not
    // the transparent button that owns the original tap/pan hit region.
    self.topBar.hidden=parked || deviceLandscape;
    self.bottomBar.hidden=parked;
    CGRect localScreen=[self convertRect:[self safe] fromView:self.superview];
    self.topBar.frame=parked?CGRectZero:ZNSMainBarHitFrame(self.bounds,localScreen,expanded,NO);
    self.bottomBar.frame=parked?CGRectZero:ZNSMainBarHitFrame(self.bounds,localScreen,expanded,YES);
    for(UIButton *bar in @[self.topBar,self.bottomBar]) {
        bar.subviews.firstObject.hidden=!ZNSShowWindowBars;
        bar.userInteractionEnabled=!parked && !self.dipped && !self.closing && !(deviceLandscape && bar==self.topBar);
        ZNSSetLayerInputEnabled(bar.layer,bar.userInteractionEnabled);
        if(parked) continue;
        CGRect visual=ZNSMainBarFrame(self.bounds,expanded,bar==self.bottomBar);
        UIView *line=bar.subviews.firstObject;
        // Motion belongs only to this visible line; the hit region stays still.
        line.bounds=CGRectMake(0,0,visual.size.width,ZNSBarThickness());
        // The label is a child of the line: width, stroke and text all scale
        // together without shrinking the independent gesture container.
        line.transform=CGAffineTransformMakeScale(chromeScale,chromeScale);
        line.center=CGPointMake(CGRectGetMidX(visual)-bar.frame.origin.x,
                               CGRectGetMidY(visual)-bar.frame.origin.y);
        BOOL bottom=bar==self.bottomBar;
        UILabel *hint=bottom?self.bottomBarHint:self.topBarHint;
        // Keep text outside the App content and clear of the expanded tools.
        // The visual label may extend beyond the bar; its hit area never does.
        CGFloat left=CGRectGetMinX(localScreen)+4;
        if(!bottom) left=MAX(left,CGRectGetMaxX(self.toolbar.frame)+4);
        CGFloat right=CGRectGetMaxX(localScreen)-4;
        CGFloat width=MIN(150,MAX(1,right-left));
        CGFloat x=MIN(MAX(CGRectGetMidX(visual)-width/2,left),right-width);
        hint.frame=CGRectMake(x-(CGRectGetMidX(visual)-visual.size.width/2),
                              bottom?ZNSBarThickness()+4:-20,width,16);
    }
    self.content.hidden=self.docked;
    self.content.userInteractionEnabled=!self.thumbnail && !self.dipped;
    self.content.accessibilityElementsHidden=self.thumbnail || self.dipped;
    self.thumbnailButton.accessibilityValue=[NSString stringWithFormat:@"第%lu档，%@",(unsigned long)self.thumbnailTier+1,self.thumbnailFree?@"自由移动":@"贴边空挂"];
    NSString *outward=self.thumbnailRight?@"右滑":@"左滑";
    self.thumbnailButton.accessibilityLabel=self.thumbnailTier==2?@"第三档实时空挂，触摸置顶":@"实时缩略窗，点击恢复小窗";
    self.thumbnailButton.accessibilityHint=self.thumbnailTier==2?@"轻点只置顶，不恢复分屏；慢拖移动，快速左滑或右滑回对应侧一档；快速下滑回可移动二档，横竖屏同灵敏度；上滑关闭":(self.thumbnailTier==1?@"普通慢拖自由移动；被主窗遮挡时首次点击只置顶，再点恢复；快速左滑回左侧一档、右滑回右侧一档；上滑关闭，竖向App下滑回原侧一档，二者同灵敏度；横向App下滑升三档，横竖屏同灵敏度":[NSString stringWithFormat:@"下滑放大到第二档；上滑关闭，向内横滑换边，%@收为图标，长按旋转",outward]);
    // Temporary input uses the ENTIRE scene, including native keyboard space.
    // No toolbar gutter, aspect-fit letterbox, manual inset or second height deduction.
    self.content.frame=self.portraitKeyboardExpanded?self.bounds:(self.thumbnail?ZNSThumbnailContentFrame(self.session.canvasSize,self.bounds,(unsigned)self.thumbnailTier):(self.docked?self.bounds:ZNSMainContent(self.bounds)));
    self.content.layer.maskedCorners=self.portraitKeyboardExpanded?(kCALayerMinXMinYCorner|kCALayerMaxXMinYCorner):(kCALayerMinXMinYCorner|kCALayerMaxXMinYCorner|kCALayerMinXMaxYCorner|kCALayerMaxXMaxYCorner);
    if (self.portraitKeyboardExpanded) {
        self.bodyBackground.frame=self.bounds;
        self.toolbar.hidden=YES;
        self.bottomBar.hidden=YES;
        self.bottomBar.userInteractionEnabled=NO;
        ZNSSetLayerInputEnabled(self.bottomBar.layer,NO);
    }
    self.stackActivation.frame=self.content.bounds;
    self.message.frame=CGRectInset(self.content.bounds,12,12);
    UIView *host=self.session.hostView;
    CGSize canvas=self.session.canvasSize;
    if (host && canvas.width>0 && canvas.height>0) {
        self.canvasContainer.bounds=(CGRect){CGPointZero,canvas};
        CGRect fitted=ZNSPortraitFittedCanvas(self.content.bounds,canvas);
        CGFloat scale=fitted.size.width/canvas.width;
        self.canvasContainer.transform=self.portraitKeyboardExpanded?ZNSPortraitCanvasTransform():CGAffineTransformMakeScale(scale,scale);
        self.canvasContainer.center=CGPointMake(CGRectGetMidX(self.content.bounds),CGRectGetMidY(self.content.bounds));
        [self.session layoutHostInCanvas];
        host.userInteractionEnabled=!self.docked && !self.thumbnail && !self.dipped && !self.session.layoutInFlight;
    }
    BOOL breathe=!parked && !self.dipped && !self.closing && !self.dismissing && !self.rebounding && !self.parkedBottomContact;
    BOOL showHints=ZNSShowWindowBars && breathe && self.barHintsDeadline>CACurrentMediaTime();
    self.topBarHint.hidden=!showHints || deviceLandscape; self.bottomBarHint.hidden=!showHints;
    for (NSUInteger i=0;i<self.corners.count;i++) {
        ZNSCornerHitView *corner=(ZNSCornerHitView *)self.corners[i];
        BOOL dipResize=self.dipExtracted && self.dipResizeAvailable && i==1;
        BOOL cornerDisabled=self.dipped?!dipResize:(parked || (deviceLandscape && i==0));
        corner.hidden=cornerDisabled;
        CGRect horizontal=ZNSMainCornerHandle(self.bounds,localScreen,(unsigned)i,expanded);
        CGRect side=ZNSMainCornerSideHandle(self.bounds,localScreen,(unsigned)i);
        if(dipResize && self.thumbnail) {
            CGPoint p=ZNSCornerCenter(self.bodyBackground.frame,(unsigned)i);
            horizontal=ZNSCornerHandle(self.bodyBackground.frame,localScreen,(unsigned)i);
            side=CGRectIntersection(CGRectMake(p.x-4,p.y-4,28,28),localScreen);
        }
        [corner setHorizontalRegion:cornerDisabled?CGRectZero:horizontal
                         sideRegion:cornerDisabled?CGRectZero:side
                            enabled:!cornerDisabled && !self.closing];
        CGRect handle=corner.frame;
        CGPoint center=ZNSCornerCenter(self.bodyBackground.frame,(unsigned)i);
        UIView *arc=corner.subviews.firstObject;
        // A full quarter-circle plus tangent tails wraps the corner. The two
        // ends are parallel to the body's width/height; the midpoint stays put.
        arc.bounds=CGRectMake(0,0,32,32);
        arc.center=CGPointMake(center.x-handle.origin.x,center.y-handle.origin.y);
        arc.transform=CGAffineTransformMakeScale(chromeScale,chromeScale);
        CAShapeLayer *stroke=(CAShapeLayer *)arc.layer.sublayers.firstObject;
        CGPoint pivot=CGPointMake(16+((i&1)?-16:16),16+((i&2)?-16:16));
        CGFloat angle=(i&2)?((i&1)?M_PI_4:3*M_PI_4):((i&1)?-M_PI_4:-3*M_PI_4);
        CGFloat radius=ZNSCornerArcRadius(),start=angle-M_PI_4,end=angle+M_PI_4,tail=4;
        CGPoint a=CGPointMake(pivot.x+radius*cos(start),pivot.y+radius*sin(start));
        CGPoint b=CGPointMake(pivot.x+radius*cos(end),pivot.y+radius*sin(end));
        UIBezierPath *path=[UIBezierPath bezierPath];
        [path moveToPoint:CGPointMake(a.x+tail*sin(start),a.y-tail*cos(start))];
        [path addLineToPoint:a];
        [path addArcWithCenter:pivot radius:radius startAngle:start endAngle:end clockwise:YES];
        [path addLineToPoint:CGPointMake(b.x-tail*sin(end),b.y+tail*cos(end))];
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        stroke.frame=arc.bounds; stroke.path=path.CGPath;
        [CATransaction commit];
        ZNSCornerColor(stroke,breathe,self.chromeAnimationEpoch);
        CGFloat diagonal=1.5/sqrt(2.0);
        ZNSChromeBounce(arc,CGPointMake((i&1)?diagonal:-diagonal,(i&2)?diagonal:-diagonal),breathe,self.chromeAnimationEpoch);
    }
    ZNSChromeBounce(self.topBar.subviews.firstObject,CGPointMake(0,-1.5),breathe && ZNSShowWindowBars,self.chromeAnimationEpoch);
    ZNSChromeBounce(self.bottomBar.subviews.firstObject,CGPointMake(0,1.5),breathe && ZNSShowWindowBars,self.chromeAnimationEpoch);
    self.thumbnailButton.frame=self.bounds; self.thumbnailButton.hidden=!self.thumbnail || self.dipped;
    ZNSSetLayerInputEnabled(self.thumbnailButton.layer,self.thumbnail && !self.dipped);
    self.restoreButton.frame=self.bounds; self.restoreButton.hidden=!self.docked;
    if(self.dipped) {
        self.topBar.hidden=YES; self.bottomBar.hidden=YES;
        self.topBarHint.hidden=YES; self.bottomBarHint.hidden=YES;
        ZNSSetLayerInputEnabled(self.topBar.layer,NO); ZNSSetLayerInputEnabled(self.bottomBar.layer,NO);
        for(ZNSCornerHitView *corner in self.corners) {
            if(self.dipExtracted && self.dipResizeAvailable && corner.tag==1) continue;
            [corner setHorizontalRegion:CGRectZero sideRegion:CGRectZero enabled:NO];
            corner.hidden=YES;
        }
    }
    [self updateDipAppearance];
    // Mirror the vertical-axis perspective on the right: the edge nearest
    // the screen boundary comes forward. Keep host and hit geometry intact.
    BOOL perspective=self.thumbnail && !self.docked && !self.dipped &&
        self.thumbnailTier<2 && !self.thumbnailFree;
    CGFloat w=self.content.bounds.size.width,h=self.content.bounds.size.height;
    perspective=perspective && isfinite(w) && isfinite(h) && w>0 && h>0;
    if(perspective) {
        CGFloat degrees=self.session.landscape?18.0:12.0;
        CGFloat angle=(self.thumbnailRight?-degrees:degrees)*M_PI/180.0;
        CGFloat depth=w*3.0,s=sin(angle),c=cos(angle);
        // Normalize using the nearest edge on either side. Reversing direction
        // changes perspective only, not its enclosing size or visible height.
        CGFloat fit=1.0-w*fabs(s)/(2.0*depth);
        CATransform3D lean=CATransform3DIdentity;
        lean.m11=c*fit; lean.m22=fit;
        lean.m13=-s; lean.m31=s*fit; lean.m33=c;
        lean.m14=s/depth; lean.m34=-c/depth;
        self.content.layer.transform=lean;
        self.bodyBackground.layer.transform=lean;
        if(!self.parkedPerspectiveActive && !UIAccessibilityIsReduceMotionEnabled()) {
            // One settling bounce on admission/repacking, never on every layout.
            CASpringAnimation *bounce=[CASpringAnimation animationWithKeyPath:@"transform"];
            bounce.fromValue=[NSValue valueWithCATransform3D:CATransform3DIdentity];
            bounce.toValue=[NSValue valueWithCATransform3D:lean];
            bounce.mass=1; bounce.stiffness=200; bounce.damping=19;
            bounce.initialVelocity=0; bounce.duration=bounce.settlingDuration;
            [self.content.layer addAnimation:bounce forKey:@"zns.parkedPerspectiveBounce"];
            [self.bodyBackground.layer addAnimation:bounce forKey:@"zns.parkedPerspectiveBounce"];
        }
    }
    if(!perspective || UIAccessibilityIsReduceMotionEnabled()) {
        [self.content.layer removeAnimationForKey:@"zns.parkedPerspectiveBounce"];
        [self.bodyBackground.layer removeAnimationForKey:@"zns.parkedPerspectiveBounce"];
    }
    self.parkedPerspectiveActive=perspective;
    BOOL canSqueeze=!self.docked && (self.dipExtracted || (!self.dipped && (!self.thumbnail || self.thumbnailFree)));
    if(canSqueeze && self.parkedSqueezeProgress>0) {
        CGFloat compression=ZNSClamp(self.parkedSqueezeProgress,0,0.72);
        // Compress the live surfaces about the window's fixed bottom edge.
        // The logical scene size and gesture containers never change shape.
        CGFloat width=MAX(1,self.bounds.size.width),bottom=CGRectGetMaxY(self.bounds);
        CGFloat middle=CGRectGetMidX(self.bounds);
        CGFloat room=2*MIN(CGRectGetMidX(self.frame)-CGRectGetMinX(self.superview.bounds),
                           CGRectGetMaxX(self.superview.bounds)-CGRectGetMidX(self.frame));
        CGFloat stretch=MIN(1+0.12*compression,MAX(1,room/width));
        if(UIAccessibilityIsReduceMotionEnabled()) stretch=1;
        for(UIView *surface in @[self.content,self.bodyBackground]) {
            CATransform3D squeeze=CATransform3DMakeScale(stretch,1-compression,1);
            squeeze.m41=(stretch-1)*(surface.center.x-middle);
            squeeze.m42=(bottom-surface.center.y)*compression;
            surface.layer.transform=squeeze;
        }
        if(!self.thumbnail) {
            // Visual chrome follows the body while the held gesture's hit region
            // stays put. Normal layout above restores every center/scale on release.
            NSMutableArray<UIView *> *visuals=[NSMutableArray arrayWithObject:self.tools];
            for(UIView *bar in @[self.topBar,self.bottomBar])
                if(bar.subviews.firstObject) [visuals addObject:bar.subviews.firstObject];
            for(UIView *corner in self.corners)
                if(corner.subviews.firstObject) [visuals addObject:corner.subviews.firstObject];
            for(UIView *visual in visuals) {
                CGPoint center=[self convertPoint:visual.center fromView:visual.superview];
                center.x=middle+(center.x-middle)*stretch;
                center.y=bottom-(bottom-center.y)*(1-compression);
                visual.center=[visual.superview convertPoint:center fromView:self];
                visual.transform=CGAffineTransformConcat(visual.transform,CGAffineTransformMakeScale(stretch,1-compression));
            }
        }
    }
    if(self.cornerPushing && !self.thumbnail && !self.dipped && !self.docked && !UIAccessibilityIsReduceMotionEnabled()) {
        self.content.layer.transform=ZNSCornerPushTransform(self.content.bounds.size,self.cornerPushRight,self.cornerPushDeformation);
        self.bodyBackground.layer.transform=ZNSCornerPushTransform(self.bodyBackground.bounds.size,self.cornerPushRight,self.cornerPushDeformation);
        UIView *arc=self.corners[self.cornerPushRight?3:2].subviews.firstObject;
        [arc.layer removeAnimationForKey:@"ZNSChromeBounce"];
        arc.center=CGPointMake(arc.center.x+self.cornerPushDeformation.x,arc.center.y+self.cornerPushDeformation.y);
    }
    // Shadow follows the visible rounded surface, not the transparent gutter.
    UIView *surface=self.docked?self.restoreButton:self.content;
    CGRect shadowRect=[self.bodyBackground convertRect:surface.bounds fromView:surface];
    self.bodyBackground.layer.shadowPath=[UIBezierPath bezierPathWithRoundedRect:shadowRect cornerRadius:surface.layer.cornerRadius].CGPath;
}
- (CGRect)collapsedToolsHitFrame {
    if(self.docked || self.thumbnail || self.dipped || self.closing ||
       self.toolbar.hidden || self.tools.userInteractionEnabled) return CGRectNull;
    // Grow only the touch target in window points, never the visible tools.
    // A smaller App window must not shrink this padding along with its chrome.
    CGRect visual=[self.tools convertRect:self.tools.bounds toView:self];
    CGFloat width=MAX(44,visual.size.width+20);
    CGFloat height=MAX(44,visual.size.height+20);
    CGRect target=CGRectMake(CGRectGetMidX(visual)-width/2,
                             CGRectGetMidY(visual)-height/2,width,height);
    // Extend upwards rather than taking touches from the hosted App.
    CGFloat bottom=CGRectGetMinY(ZNSMainContent(self.bounds))-1;
    if(CGRectGetMaxY(target)>bottom) target.origin.y=bottom-height;
    CGRect safe=[self convertRect:[self safe] fromView:self.superview];
    target=CGRectIntersection(target,safe);
    // The top bar retains its own independent gesture region.
    if(!self.topBar.hidden && CGRectIntersectsRect(target,self.topBar.frame)) {
        CGFloat right=MIN(CGRectGetMaxX(target),CGRectGetMinX(self.topBar.frame)-1);
        target.size.width=MAX(0,right-CGRectGetMinX(target));
    }
    return target;
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if(self.dipped) {
        UIView *handle=self.corners.count>1?self.corners[1]:nil;
        if(self.dipExtracted && self.dipResizeAvailable && !handle.hidden &&
           [handle pointInside:[self convertPoint:point toView:handle] withEvent:event]) return YES;
        return !self.toolbar.hidden && [self.toolbar pointInside:[self convertPoint:point toView:self.toolbar] withEvent:event];
    }
    if(CGRectContainsPoint([self collapsedToolsHitFrame],point)) return YES;
    if(!self.docked && !self.thumbnail && !self.closing) {
        if(!self.toolbar.hidden && CGRectContainsPoint(self.tools.bounds,[self.tools convertPoint:point fromView:self])) return YES;
        for(UIView *handle in self.corners) if(!handle.hidden && [handle pointInside:[self convertPoint:point toView:handle] withEvent:event]) return YES;
        for(UIView *bar in @[self.topBar,self.bottomBar]) if(!bar.hidden && CGRectContainsPoint(bar.frame,point)) return YES;
    }
    return [super pointInside:point withEvent:event];
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if(self.hidden || self.alpha<0.01 || !self.userInteractionEnabled) return nil;
    if(self.dipped) {
        UIView *handle=self.corners.count>1?self.corners[1]:nil;
        if(self.dipExtracted && self.dipResizeAvailable && !handle.hidden &&
           [handle pointInside:[self convertPoint:point toView:handle] withEvent:event])
            return [handle hitTest:[self convertPoint:point toView:handle] withEvent:event];
        if(!self.toolbar.hidden) {
            UIView *tool=[self.toolbar hitTest:[self convertPoint:point toView:self.toolbar] withEvent:event];
            if(tool) return tool;
        }
        return nil;
    }
    if(!self.docked && !self.thumbnail && !self.closing) {
        for(UIView *handle in self.corners) {
            if(!handle.hidden && [handle pointInside:[self convertPoint:point toView:handle] withEvent:event]) return [handle hitTest:[self convertPoint:point toView:handle] withEvent:event];
        }
    }
    // Corner resizing keeps priority. The added collapsed-tool padding routes
    // to the same toolbar tap/drag recognizers, not to its action buttons.
    if(CGRectContainsPoint([self collapsedToolsHitFrame],point)) return self.toolbar;
    if(!self.docked && !self.thumbnail && !self.closing && !self.toolbar.hidden) {
        CGPoint toolPoint=[self.tools convertPoint:point fromView:self];
        if(CGRectContainsPoint(self.tools.bounds,toolPoint)) {
            UIView *toolHit=[self.tools hitTest:toolPoint withEvent:event];
            return toolHit?:self.toolbar;
        }
    }
    if (!self.docked && !self.thumbnail && self.tools.userInteractionEnabled && CGRectContainsPoint(self.toolbar.frame,point)) {
        UIView *toolHit=[self.toolbar hitTest:[self convertPoint:point toView:self.toolbar] withEvent:event];
        if(toolHit) return toolHit;
    }
    UIView *hit=[super hitTest:point withEvent:event];
    // A parked live view is display-only. The entire hit belongs to restore;
    // UIKit keeps that touch on the button even after it expands the window.
    if (hit && self.thumbnail) return self.thumbnailButton;
    // The detached strip must not leave an invisible full-width title bar.
    if (hit==self && !self.docked && !CGRectContainsPoint(self.bodyBackground.frame,point)) return nil;
    return hit;
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    if ([gesture isKindOfClass:UIPanGestureRecognizer.class]) [self restorePortraitKeyboardWithDuration:0 options:0];
    BOOL dipResize=self.dipExtracted && self.dipResizeAvailable &&
        self.corners.count>1 && gesture.view==self.corners[1];
    if(self.dipped && gesture.view!=self.toolbar && !dipResize) return NO;
    if(self.closing || self.activeManipulation || self.rebounding || self.dismissing || self.session.layoutInFlight || (self.thumbnail && !dipResize) || self.docked) return NO;
    if((gesture.view==self.bottomBar || gesture.view==self.topBar) && [gesture isKindOfClass:UIPanGestureRecognizer.class]) {
        CGPoint v=[(UIPanGestureRecognizer *)gesture velocityInView:self.superview];
        return v.y<0 && fabs(v.y)>fabs(v.x);
    }
    return YES;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    if (gesture.view!=self.toolbar) return YES;
    // A pan may start on any tool, cancelling its button touch once dragging
    // begins. A stationary tap still belongs exclusively to that button.
    if ([gesture isKindOfClass:UIPanGestureRecognizer.class]) return YES;
    for (UIView *view=touch.view; view && view!=self.toolbar; view=view.superview)
        if ([view isKindOfClass:UIControl.class] || (view.tag==914 && self.tools.userInteractionEnabled)) return NO;
    return YES;
}
- (void)cancelInteraction {
    [self restorePortraitKeyboardWithDuration:0 options:0];
    [self stopSqueezeFeedback];
    ++self.interactionGeneration;
    BOOL transformed=self.dismissing || self.rebounding || self.cornerPushing;
    self.cornerPushing=NO; self.cornerPushParking=NO; self.cornerPushDeformation=CGPointZero;
    BOOL wasSqueezing=self.parkedBottomContact;
    self.parkedSqueezeProgress=0; self.parkedBottomContact=NO;
    if(wasSqueezing) {
        [self.content.layer removeAllAnimations];
        [self.bodyBackground.layer removeAllAnimations];
    } else {
        [self.content.layer removeAnimationForKey:@"zns.cornerPushReturn"];
        [self.bodyBackground.layer removeAnimationForKey:@"zns.cornerPushReturn"];
    }
    self.content.layer.transform=CATransform3DIdentity;
    self.bodyBackground.layer.transform=CATransform3DIdentity;
    self.dismissing=NO; self.rebounding=NO; self.fullscreenExpanding=NO;
    [self restoreChromeOpacity];
    UIGestureRecognizer *gesture=self.activeManipulation; self.activeManipulation=nil;
    if(gesture) { gesture.enabled=NO; gesture.enabled=YES; }
    UIGestureRecognizer *parked=self.parkedPan; self.parkedPan=nil;
    if(parked) { parked.enabled=NO; parked.enabled=YES; }
    [self.layer removeAllAnimations];
    self.transform=CGAffineTransformIdentity; self.alpha=1;
    if(transformed && !CGRectIsEmpty(self.gestureFrame)) self.frame=self.gestureFrame;
    [self updateContentInputGate]; [self setNeedsLayout];
    if(self.dipExtracted) [[ZNSWindowManager shared] setDipResizeHeld:NO window:self];
}
- (void)barTapped:(UITapGestureRecognizer *)gesture {
    if(gesture.state!=UIGestureRecognizerStateRecognized || self.closing || self.activeManipulation || self.rebounding || self.dismissing || self.docked || self.thumbnail || self.session.layoutInFlight) return;
    if(self.closeAction) { ZNSActionFeedback(); self.closeAction(gesture.view==self.topBar); }
}
- (void)restoreChromeOpacity {
    [self.toolbar.layer removeAllAnimations];
    [self.topBar.subviews.firstObject.layer removeAllAnimations];
    [self.bottomBar.subviews.firstObject.layer removeAllAnimations];
    for(UIView *corner in self.corners) [corner.subviews.firstObject.layer removeAllAnimations];
    self.toolbar.alpha=1;
    self.topBar.subviews.firstObject.alpha=1; self.bottomBar.subviews.firstObject.alpha=1;
    for(UIView *corner in self.corners) corner.subviews.firstObject.alpha=1;
}
- (void)applyFullscreenProgress:(CGFloat)progress {
    CGFloat p=ZNSClamp(progress,0,1);
    self.transform=UIAccessibilityIsReduceMotionEnabled()?CGAffineTransformIdentity:
        ZNSFullscreenTransform(self.gestureFrame,self.superview.bounds,p);
    CGFloat opacity=UIAccessibilityIsReduceMotionEnabled()?1:1-p;
    self.toolbar.alpha=opacity;
    self.topBar.subviews.firstObject.alpha=opacity; self.bottomBar.subviews.firstObject.alpha=opacity;
    for(UIView *corner in self.corners) corner.subviews.firstObject.alpha=opacity;
}
- (void)fullscreenPanned:(UIPanGestureRecognizer *)gesture {
    if(self.closing || self.thumbnail || self.docked) return;
    if(gesture.state==UIGestureRecognizerStateBegan) {
        if(self.activeManipulation || self.dismissing || self.rebounding || self.session.layoutInFlight || !self.ready) return;
        self.gestureFrame=self.frame;
        self.activeManipulation=gesture; self.fullscreenExpanding=YES; self.dismissing=YES;
        ++self.interactionGeneration;
        [self.layer removeAllAnimations]; [self updateContentInputGate];
        [self setNeedsLayout]; [self layoutIfNeeded];
    }
    if(self.activeManipulation!=gesture || !self.fullscreenExpanding) return;
    CGFloat dy=[gesture translationInView:self.superview].y;
    [self applyFullscreenProgress:ZNSFullscreenProgress(dy)];
    BOOL ended=gesture.state==UIGestureRecognizerStateEnded;
    BOOL cancelled=gesture.state==UIGestureRecognizerStateCancelled || gesture.state==UIGestureRecognizerStateFailed;
    if(!ended && !cancelled) return;
    self.activeManipulation=nil;
    BOOL commit=ended && ZNSShouldEnterFullscreen(dy,[gesture velocityInView:self.superview].y) && self.closeAction!=nil;
    if (commit && !ZNSCanOpenFullscreenWithoutAnimation(self.session.bundleIdentifier)) {
        os_log_error(ZNSLog(),"swipe fullscreen rebounded: nonanimated handoff unavailable");
        commit=NO;
    }
    self.rebounding=!commit;
    NSUInteger generation=++self.interactionGeneration;
    __weak typeof(self) weakSelf=self;
    [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled()?0:0.24 delay:0
        options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionCurveEaseOut
        animations:^{ [weakSelf applyFullscreenProgress:commit?1:0]; }
        completion:^(BOOL finished) {
            ZNSFloatingView *self=weakSelf;
            if(!self || self.closing || generation!=self.interactionGeneration || !self.fullscreenExpanding) return;
            if(finished && commit && self.closeAction) {
                ZNSActionFeedback(); self.closeAction(YES); return;
            }
            self.transform=CGAffineTransformIdentity;
            self.fullscreenExpanding=NO; self.dismissing=NO; self.rebounding=NO;
            [self restoreChromeOpacity]; [self updateContentInputGate];
            [self setNeedsLayout];
        }];
}
- (void)dismissPanned:(UIPanGestureRecognizer *)gesture {
    if(self.closing || self.docked || self.thumbnail) return;
    if(gesture.state==UIGestureRecognizerStateBegan) {
        if(self.activeManipulation || self.rebounding || self.session.layoutInFlight) return;
        self.activeManipulation=gesture; self.dismissing=YES;
        ++self.interactionGeneration; self.gestureFrame=self.frame;
        [self.layer removeAllAnimations]; [self updateContentInputGate];
    }
    if(self.activeManipulation!=gesture || !self.dismissing) return;
    CGFloat dy=[gesture translationInView:self.superview].y;
    CGFloat p=ZNSDismissProgress(dy,self.gestureFrame.size.height);
    self.transform=CGAffineTransformConcat(CGAffineTransformMakeScale(1-0.35*p,1-0.35*p),CGAffineTransformMakeTranslation(0,-MIN(MAX(0,-dy),self.gestureFrame.size.height)*0.28));
    self.alpha=1-0.5*p;
    BOOL ended=gesture.state==UIGestureRecognizerStateEnded;
    BOOL cancelled=gesture.state==UIGestureRecognizerStateCancelled || gesture.state==UIGestureRecognizerStateFailed;
    if(!ended && !cancelled) return;
    self.activeManipulation=nil;
    if(ended && ZNSShouldDismiss(dy,[gesture velocityInView:self.superview].y,self.gestureFrame.size.height) && self.closeAction) {
        ZNSActionFeedback(); self.closeAction(NO); return;
    }
    self.dismissing=NO; self.rebounding=YES;
    NSUInteger generation=++self.interactionGeneration;
    [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled()?0:0.22 delay:0 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionCurveEaseOut animations:^{
        self.transform=CGAffineTransformIdentity; self.alpha=1;
    } completion:^(BOOL finished) {
        (void)finished;
        if(self.closing || generation!=self.interactionGeneration) return;
        self.rebounding=NO; [self updateContentInputGate];
    }];
}
- (void)appIconTapped {
    if(self.closing || self.activeManipulation || self.rebounding) return;
    if(self.dipped && self.tools.userInteractionEnabled && self.pullDip) { self.pullDip(); return; }
    [self expandTools];
}
- (void)expandTools {
    if (self.closing || self.activeManipulation || self.dismissing || self.rebounding || self.thumbnail || self.docked) return;
    BOOL opening=!self.tools.userInteractionEnabled;
    self.tools.userInteractionEnabled=YES;
    if(opening) ZNSSoftFeedback();
    NSUInteger generation=++self.toolsGeneration;
    ZNSAnimate(0.16, ^{
        self.tools.transform=CGAffineTransformIdentity;
        [self setNeedsLayout]; [self layoutIfNeeded];
    });
    if(self.dipped) return; // Its next explicit tool tap restores the main window.
    __weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2200*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        ZNSFloatingView *self=weakSelf;
        if (self && !self.closing && generation==self.toolsGeneration) {
            self.tools.userInteractionEnabled=NO;
            ZNSAnimate(0.18, ^{
                self.tools.transform=CGAffineTransformMakeScale(0.50,0.50);
                [self setNeedsLayout]; [self layoutIfNeeded];
            });
        }
    });
}
- (void)control:(UIButton *)sender {
    if(self.dipped) return;
    if(self.closing || self.activeManipulation || self.dismissing || self.rebounding || self.thumbnail || self.docked || self.session.layoutInFlight) return;
    [self expandTools];
    if (sender.tag==1) [self dock];
    else if (self.closeAction) { ZNSActionFeedback(); self.closeAction(sender.tag==2); }
}
- (BOOL)parkLiveThumbnail {
    [self restorePortraitKeyboardWithDuration:0 options:0];
    if(self.dipped) return NO;
    if (self.closing || self.activeManipulation || self.dismissing || self.rebounding || self.docked || self.thumbnail || (!self.connecting && (self.session.layoutInFlight || !self.ready))) return NO;
    CGRect target=[self thumbnailFrameInSafe:[self safe]];
    if (CGRectIsEmpty(target)) return NO;
    self.thumbnailTier=0; self.thumbnailFree=NO; self.rotationOverflow=NO; self.portraitSaved=NO; self.restoringPosition=NO;
    target=[self thumbnailFrameInSafe:[self safe]];
    ZNSActionFeedback();
    self.expandedFrame=self.cornerPushParking?self.gestureFrame:self.frame; self.thumbnail=YES;
    [self updateContentInputGate];
    self.toolsGeneration++; self.tools.userInteractionEnabled=NO;
    self.tools.transform=CGAffineTransformMakeScale(0.50,0.50);
    if (self.presentationChanged) self.presentationChanged();
    [self setNeedsLayout];
    if(self.cornerPushParking) {
        self.rebounding=YES;
        NSUInteger generation=++self.interactionGeneration;
        [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled()?0:0.48 delay:0 usingSpringWithDamping:0.68 initialSpringVelocity:0 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{
            self.frame=target; [self layoutIfNeeded];
        } completion:^(BOOL finished) {
            (void)finished;
            if(self.closing || generation!=self.interactionGeneration) return;
            self.rebounding=NO; [self updateContentInputGate];
            if(self.presentationChanged) self.presentationChanged();
        }];
    } else ZNSAnimate(0.20, ^{ self.frame=target; [self layoutIfNeeded]; });
    os_log(ZNSLog(),"live thumbnail parked; original scene/view retained canvas=%.0fx%.0f",self.session.canvasSize.width,self.session.canvasSize.height);
    return YES;
}
- (void)thumbnailTapped:(UITapGestureRecognizer *)gesture {
    if(gesture.state!=UIGestureRecognizerStateRecognized || !self.thumbnail || self.closing) return;
    BOOL covered=self.stackCovered;
    
    if(self.thumbnailTier==2 || (self.thumbnailFree && covered)) {
        // Third tier always selects only; a rear moved second tier needs one
        // complete selection tap before a subsequent tap can restore it.
        if(self.requestFront) self.requestFront();
        return;
    }
    [self restore];
}
- (void)dockedTapped:(UITapGestureRecognizer *)gesture {
    if (gesture.state==UIGestureRecognizerStateRecognized && self.docked) {
        
        [self restore];
    }
}
- (void)dockedHeld:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state!=UIGestureRecognizerStateBegan || !self.docked || !self.closeAction) return;
    ZNSActionFeedback();
    self.closeAction(NO);
}
- (void)stopSqueezeFeedback {
    [self.squeezeFeedbackTimer invalidate]; self.squeezeFeedbackTimer=nil;
    self.squeezeFeedback=nil;
}
- (void)updateSqueezeFeedback {
    UIGestureRecognizer *gesture=self.thumbnail?self.parkedPan:self.activeManipulation;
    BOOL held=gesture && (gesture.state==UIGestureRecognizerStateBegan || gesture.state==UIGestureRecognizerStateChanged);
    BOOL active=held && self.parkedSqueezeProgress>0 && ZNSDipEnabled && self.ready &&
        self.window && !self.window.hidden && !self.hidden && !self.closing && !self.dipped && !self.rebounding && !self.session.layoutInFlight;
    if(!active) { [self stopSqueezeFeedback]; return; }
    if(self.squeezeFeedbackTimer) return;
    self.squeezeFeedback=[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleSoft];
    [self.squeezeFeedback prepare]; [self.squeezeFeedback impactOccurredWithIntensity:0.15];
    __weak typeof(self) weakSelf=self;
    self.squeezeFeedbackTimer=[NSTimer timerWithTimeInterval:0.18 repeats:YES block:^(NSTimer *timer){
        ZNSFloatingView *view=weakSelf;
        if(!view) { [timer invalidate]; return; }
        [view updateSqueezeFeedback];
        if(view.squeezeFeedbackTimer!=timer) return;
        [view.squeezeFeedback impactOccurredWithIntensity:0.15];
        [view.squeezeFeedback prepare];
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.squeezeFeedbackTimer forMode:NSRunLoopCommonModes];
}
- (BOOL)applyParkedDrag:(CGRect)proposed safe:(CGRect)safe allowDip:(BOOL)allowDip commitDip:(BOOL)commitDip {
    CGRect screen=self.superview.bounds;
    CGFloat progress=allowDip?ZNSDipSqueezeProgress(proposed,screen):0;
    if(progress>0) self.parkedBottomContact=YES;
    self.parkedSqueezeProgress=progress;
    [self updateSqueezeFeedback];
    [UIView performWithoutAnimation:^{
        self.frame=allowDip?ZNSDipSqueezedFrame(proposed,safe,screen):ZNSConstrainIcon(proposed,self.thumbnail?[self parkedMovementArea]:[self safe]);
        [self setNeedsLayout]; [self layoutIfNeeded];
    }];
    if(commitDip && allowDip && progress>0.50 && self.tryDip) {
        // Main windows and second tiers commit only on release, using CURRENT
        // compression. Keep the live shape until the dip destination is laid out.
        self.parkedSqueezeProgress=0;
        if(self.tryDip()) {
            self.parkedBottomContact=NO;
            return YES;
        }
        self.parkedSqueezeProgress=progress;
    }
    return NO;
}
- (void)finishParkedSqueezeAtFrame:(CGRect)target {
    [self stopSqueezeFeedback];
    self.parkedSqueezeProgress=0;
    self.rebounding=YES;
    // Cancellation during recovery must never resurrect an old main-window frame.
    self.gestureFrame=target;
    NSUInteger generation=++self.interactionGeneration;
    [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled()?0:0.42 delay:0 usingSpringWithDamping:0.78 initialSpringVelocity:0 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{
        self.frame=target; [self setNeedsLayout]; [self layoutIfNeeded];
    } completion:^(BOOL finished){
        (void)finished;
        if(self.closing || generation!=self.interactionGeneration) return;
        self.rebounding=NO; self.parkedBottomContact=NO;
        if(!self.thumbnail && !self.docked && !self.dipped) {
            self.expandedFrame=self.frame;
            if(self.tools.userInteractionEnabled) [self expandTools];
        }
        [self updateContentInputGate]; [self setNeedsLayout];
        if(self.presentationChanged) self.presentationChanged();
    }];
}
- (void)thumbnailPanned:(UIPanGestureRecognizer *)gesture {
    if (!self.thumbnail || self.closing || self.rebounding) return;
    if (gesture.state==UIGestureRecognizerStateBegan) {
        if (self.session.layoutInFlight) return;
        self.parkedSqueezeProgress=0; self.parkedBottomContact=NO;
        self.parkedPan=gesture; self.parkedGestureGeneration=self.containerGeneration;
        self.restoringPosition=NO;
        self.thumbnailGestureFrame=self.frame;
        self.thumbnailGestureStart=NSProcessInfo.processInfo.systemUptime;
        self.thumbnailGestureWasFree=self.thumbnailFree;
        if(self.requestFront) self.requestFront();
    }
    if(self.parkedGestureGeneration!=self.containerGeneration || self.parkedPan!=gesture) return;
    if(gesture.state==UIGestureRecognizerStateEnded || gesture.state==UIGestureRecognizerStateCancelled || gesture.state==UIGestureRecognizerStateFailed) self.parkedPan=nil;
    CGPoint delta=[gesture translationInView:self.superview];
    CGPoint velocity=[gesture velocityInView:self.superview];
    if (gesture.state==UIGestureRecognizerStateCancelled || gesture.state==UIGestureRecognizerStateFailed) {
        if (self.thumbnailTier==1 || self.thumbnailGestureWasFree) {
            self.thumbnailFree=self.thumbnailGestureWasFree;
            if(self.parkedBottomContact) {
                [self finishParkedSqueezeAtFrame:self.thumbnailGestureFrame];
            } else {
                self.parkedSqueezeProgress=0;
                self.frame=self.thumbnailGestureFrame;
                [self setNeedsLayout];
                if(self.presentationChanged) self.presentationChanged();
            }
        }
        return;
    }
    if (self.thumbnailTier==1) {
        // Both portrait and landscape second tiers begin packed. A real drag
        // promotes only this window into the independent overlay stack.
        if(!self.thumbnailFree && hypot(delta.x,delta.y)>=4) {
            self.thumbnailFree=YES; self.restoringPosition=NO; self.portraitSaved=NO;
            if(self.presentationChanged) self.presentationChanged();
            if(self.requestFront) self.requestFront();
        }
        BOOL allowDip=ZNSDipEnabled && self.ready && !self.session.layoutInFlight;
        if(self.thumbnailFree) {
            CGRect proposed=CGRectOffset(self.thumbnailGestureFrame,delta.x,delta.y);
            if([self applyParkedDrag:proposed safe:[self mainSafe] allowDip:allowDip commitDip:gesture.state==UIGestureRecognizerStateEnded]) return;
        }
        if(gesture.state!=UIGestureRecognizerStateEnded) return;
        if(self.parkedBottomContact) {
            [self finishParkedSqueezeAtFrame:ZNSConstrainIcon(self.frame,[self parkedMovementArea])];
            return;
        }
        ZNSSecondTierAction action=ZNSSecondTierActionForGesture(self.session.landscape,self.superview.bounds.size.width>self.superview.bounds.size.height,self.thumbnailRight,delta,velocity,NSProcessInfo.processInfo.systemUptime-self.thumbnailGestureStart);
        if(action==ZNSSecondTierActionNone) {
            CGRect target=ZNSConstrainIcon(self.frame,[self parkedMovementArea]);
            if(!CGRectEqualToRect(target,self.frame)) {
                self.rebounding=YES;
                NSUInteger generation=++self.interactionGeneration;
                [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled()?0:0.36 delay:0 usingSpringWithDamping:0.74 initialSpringVelocity:0 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{
                    self.frame=target; [self layoutIfNeeded];
                } completion:^(BOOL finished){
                    (void)finished;
                    if(self.closing || generation!=self.interactionGeneration) return;
                    self.rebounding=NO;
                    if(self.presentationChanged) self.presentationChanged();
                }];
            }
            return;
        }
        if(action==ZNSSecondTierActionClose) {
            if(self.closeAction) { ZNSActionFeedback(); self.closeAction(NO); }
            return;
        }
        self.restoringPosition=NO; self.portraitSaved=NO; self.rotationOverflow=NO;
        if(action==ZNSSecondTierActionAdvance) { self.thumbnailTier=2; self.thumbnailFree=YES; }
        else {
            self.thumbnailFree=NO;
            self.thumbnailTier=0;
            if (fabs(delta.x)>fabs(delta.y)) self.thumbnailRight=delta.x>0;
        }
        ZNSActionFeedback();
        CGRect target=[self thumbnailFrameInSafe:[self safe]];
        ZNSAnimate(0.20, ^{ self.frame=target; [self setNeedsLayout]; [self layoutIfNeeded]; });
        if(self.presentationChanged) self.presentationChanged();
        return;
    }
    if (self.thumbnailGestureWasFree) {
        BOOL allowDip=ZNSDipEnabled && self.ready && !self.session.layoutInFlight;
        CGRect dragged=CGRectOffset(self.thumbnailGestureFrame,delta.x,delta.y);
        if([self applyParkedDrag:dragged safe:self.superview.bounds allowDip:allowDip commitDip:YES]) return;
        if (gesture.state!=UIGestureRecognizerStateEnded) return;
        if(self.parkedBottomContact) {
            [self finishParkedSqueezeAtFrame:ZNSConstrainIcon(self.frame,[self parkedMovementArea])];
            return;
        }
        // Away from bottom contact, preserve the existing directional flicks.
        NSTimeInterval elapsed=NSProcessInfo.processInfo.systemUptime-self.thumbnailGestureStart;
        if (ZNSThumbnailSensitiveFlick(delta,velocity,elapsed,1)) {
            self.thumbnailRight=delta.x>0;
            self.thumbnailTier=0; self.thumbnailFree=NO;
            ZNSActionFeedback();
            CGRect target=[self thumbnailFrameInSafe:[self safe]];
            ZNSAnimate(0.20, ^{ self.frame=target; [self setNeedsLayout]; [self layoutIfNeeded]; });
            if (self.presentationChanged) self.presentationChanged();
            os_log(ZNSLog(),"free thumbnail returned to edge sideRight=%d tier=1",self.thumbnailRight);
        } else if ((delta.y>0 || self.superview.bounds.size.width>self.superview.bounds.size.height)?
                   ZNSThumbnailSensitiveFlick(delta,velocity,elapsed,0):
                   ZNSThumbnailDeliberateFlick(delta,velocity,elapsed,0)) {
            // Downward return is equally sensitive in portrait and landscape.
            if(delta.y<0) {
                if (self.closeAction) { ZNSActionFeedback(); self.closeAction(NO); }
            } else if(!self.session.layoutInFlight) {
                self.thumbnailTier=1; self.thumbnailFree=YES;
                self.restoringPosition=NO; self.portraitSaved=NO; self.rotationOverflow=NO;
                ZNSActionFeedback();
                CGRect target=[self thumbnailFrameInSafe:[self safe]];
                ZNSAnimate(0.20, ^{ self.frame=target; [self setNeedsLayout]; [self layoutIfNeeded]; });
                if(self.presentationChanged) self.presentationChanged();
            }
        } else {
            CGRect target=ZNSConstrainIcon(self.frame,[self parkedMovementArea]);
            ZNSAnimate(0.20, ^{ self.frame=target; [self setNeedsLayout]; [self layoutIfNeeded]; });
        }
        return;
    }
    if (gesture.state!=UIGestureRecognizerStateEnded) return;
    if (fabs(delta.y)>=40 && fabs(delta.y)>1.5*fabs(delta.x)) {
        if (delta.y<0) {
            if (self.closeAction) { ZNSActionFeedback(); self.closeAction(NO); }
        } else {
            if(self.session.layoutInFlight) return;
            NSUInteger next=ZNSThumbnailNextTier((unsigned)self.thumbnailTier,self.session.landscape);
            if(next==self.thumbnailTier) return;
            self.thumbnailTier=next;
            self.thumbnailFree=self.thumbnailTier==2;
            ZNSActionFeedback();
            CGRect target=[self thumbnailFrameInSafe:[self safe]];
            ZNSAnimate(0.20, ^{ self.frame=target; [self setNeedsLayout]; [self layoutIfNeeded]; });
            if (self.presentationChanged) self.presentationChanged();
            os_log(ZNSLog(),"thumbnail tier=%lu free=%d canvas=%.0fx%.0f frame=%.1fx%.1f",(unsigned long)self.thumbnailTier+1,self.thumbnailFree,self.session.canvasSize.width,self.session.canvasSize.height,target.size.width,target.size.height);
        }
    } else if (ZNSThumbnailHorizontalSwipeRecognized(delta,velocity,self.thumbnailRight)) {
        [self thumbnailHorizontalSwipe:delta.x>0];
    }
}
- (void)thumbnailHorizontalSwipe:(BOOL)swipeRight {
    if (self.session.layoutInFlight || !self.ready) return;
    ZNSActionFeedback();
    self.restoringPosition=NO;
    if(ZNSThumbnailReturnsFirst((unsigned)self.thumbnailTier,self.thumbnailRight,swipeRight)) {
        self.thumbnailTier=0; self.thumbnailFree=NO;
        self.portraitSaved=NO; self.rotationOverflow=NO;
        CGRect target=[self thumbnailFrameInSafe:[self safe]];
        ZNSAnimate(0.20, ^{ self.frame=target; [self setNeedsLayout]; [self layoutIfNeeded]; });
        if(self.presentationChanged) self.presentationChanged();
        os_log(ZNSLog(),"second tier returned to first by outward swipe sideRight=%d",self.thumbnailRight);
        return;
    }
    if (ZNSThumbnailSwipeDocks(self.thumbnailRight,swipeRight)) {
        // Unlike the yellow button, this icon returns to a thumbnail first.
        self.rotationOverflow=NO; self.portraitSaved=NO;
        self.dockedFromThumbnail=YES; self.thumbnail=NO; self.docked=YES;
        self.restoreButton.accessibilityLabel=@"恢复实时空挂窗口";
        if (self.presentationChanged) self.presentationChanged();
        CGFloat iconSize=ZNSParkedIconSize();
        CGRect target=ZNSConstrainIcon(CGRectMake(self.thumbnailRight?CGRectGetMaxX([self safe])-iconSize:CGRectGetMinX([self safe]),self.frame.origin.y,iconSize,iconSize),[self safe]);
        [self setNeedsLayout];
        ZNSAnimate(0.20, ^{ self.frame=target; [self layoutIfNeeded]; });
        os_log(ZNSLog(),"thumbnail outward swipe docked sideRight=%d",self.thumbnailRight);
    } else {
        self.thumbnailRight=!self.thumbnailRight;
        CGRect target=[self thumbnailFrameInSafe:[self safe]];
        ZNSAnimate(0.20, ^{ self.frame=target; [self layoutIfNeeded]; });
        os_log(ZNSLog(),"thumbnail inward swipe crossed sideRight=%d",self.thumbnailRight);
        if (self.presentationChanged) self.presentationChanged();
    }
}
- (void)thumbnailHeld:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state!=UIGestureRecognizerStateBegan || !self.thumbnail || !self.ready) return;
    [self rotateHostedCanvas];
}
- (void)dock {
    [self restorePortraitKeyboardWithDuration:0 options:0];
    if (self.closing || self.activeManipulation || self.dismissing || self.rebounding || self.docked || self.thumbnail || self.session.layoutInFlight) return;
    ZNSActionFeedback();
    self.dockedFromThumbnail=NO;
    self.restoreButton.accessibilityLabel=@"恢复分屏小窗";
    self.expandedFrame=self.frame; self.docked=YES;
    [self updateContentInputGate];
    self.toolsGeneration++;
    self.tools.userInteractionEnabled=NO;
    self.tools.transform=CGAffineTransformMakeScale(0.50,0.50);
    if (self.presentationChanged) self.presentationChanged();
    CGRect icon=ZNSConstrainIcon(CGRectMake(self.frame.origin.x,self.frame.origin.y,ZNSParkedIconSize(),ZNSParkedIconSize()),[self safe]);
    [self setNeedsLayout];
    ZNSAnimate(0.20, ^{
        self.frame=icon; [self layoutIfNeeded];
    });
    os_log(ZNSLog(),"window minimized to movable icon");
}
- (void)restore {
    if(self.dipped) { if(self.pullDip) self.pullDip(); return; }
    if (!ZNSReadAuthorization(YES)) return;
    if (self.closing || self.rebounding || self.parkedPan || self.session.layoutInFlight || (!self.docked && !self.thumbnail)) return;
    if (self.docked && self.dockedFromThumbnail) {
        self.rotationOverflow=NO; self.portraitSaved=NO;
        ZNSActionFeedback();
        self.docked=NO; self.thumbnail=YES; self.dockedFromThumbnail=NO;
        if (self.presentationChanged) self.presentationChanged();
        [self setNeedsLayout];
        CGRect target=[self thumbnailFrameInSafe:[self safe]];
        ZNSAnimate(0.20, ^{ self.frame=target; [self layoutIfNeeded]; });
        os_log(ZNSLog(),"thumbnail icon restored to live thumbnail");
        return;
    }
    if (self.willActivate && !self.willActivate()) return;
    self.dockedFromThumbnail=NO; self.rotationOverflow=NO; self.portraitSaved=NO;
    ZNSActionFeedback();
    BOOL wasThumbnail=self.thumbnail;
    self.docked=NO; self.thumbnail=NO;
    [self restartBarHints];
    [self updateContentInputGate];
    if (self.presentationChanged) self.presentationChanged();
    [self setNeedsLayout];
    ZNSAnimate(0.20, ^{
        self.frame=[self restoredMainFrame]; self.expandedFrame=self.frame; [self layoutIfNeeded];
    });
    [self applySceneSize];
    ZNSPromoteRecentApp(self.session);
    os_log(ZNSLog(),"window restored thumbnail=%d original scene retained=%d",wasThumbnail,self.session.hostView!=nil);
}
- (void)dragDocked:(UIPanGestureRecognizer *)gesture {
    if (!self.docked || self.closing) return;
    if (gesture.state==UIGestureRecognizerStateBegan) {
        self.gestureFrame=self.frame; self.parkedPan=gesture; self.parkedGestureGeneration=self.containerGeneration;
    }
    if(self.parkedGestureGeneration!=self.containerGeneration || self.parkedPan!=gesture) return;
    if(gesture.state==UIGestureRecognizerStateEnded || gesture.state==UIGestureRecognizerStateCancelled || gesture.state==UIGestureRecognizerStateFailed) self.parkedPan=nil;
    CGPoint delta=[gesture translationInView:self.superview];
    CGRect proposed=ZNSConstrainIcon(CGRectOffset(self.gestureFrame,delta.x,delta.y),[self safe]);
    if (!self.canOccupy || self.canOccupy(proposed)) self.frame=proposed;
    if (gesture.state==UIGestureRecognizerStateCancelled) self.frame=self.gestureFrame;
    if (gesture.state==UIGestureRecognizerStateEnded) os_log(ZNSLog(),"floating icon drag ended");
}
- (void)drag:(UIPanGestureRecognizer *)gesture {
    if(self.dipped) return;
    if(self.closing || self.rebounding || self.dismissing || self.session.layoutInFlight || (self.activeManipulation && self.activeManipulation!=gesture)) return;
    if (gesture.state==UIGestureRecognizerStateBegan) {
        self.activeManipulation=gesture; self.gestureFrame=self.frame;
        self.parkedSqueezeProgress=0; self.parkedBottomContact=NO;
        ++self.toolsGeneration;
    }
    if(self.activeManipulation!=gesture) return;
    BOOL ended=gesture.state==UIGestureRecognizerStateEnded;
    BOOL cancelled=gesture.state==UIGestureRecognizerStateCancelled || gesture.state==UIGestureRecognizerStateFailed;
    if(ended || cancelled) self.activeManipulation=nil;
    if(!cancelled) {
        CGPoint delta=[gesture translationInView:self.superview];
        CGRect next=CGRectOffset(self.gestureFrame,delta.x,delta.y);
        if([self applyParkedDrag:next safe:[self mainSafe] allowDip:ZNSDipEnabled && self.ready commitDip:ended]) return;
    }
    if(!ended && !cancelled) return;
    CGRect target=cancelled?self.gestureFrame:ZNSConstrainIcon(self.frame,[self safe]);
    if(self.parkedBottomContact) {
        [self finishParkedSqueezeAtFrame:target];
        if(self.tools.userInteractionEnabled) [self expandTools];
        return;
    }
    if(!CGRectEqualToRect(self.frame,target)) {
        self.rebounding=YES;
        NSUInteger generation=++self.interactionGeneration;
        [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled()?0:0.36 delay:0 usingSpringWithDamping:0.74 initialSpringVelocity:0 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{
            self.frame=target; [self layoutIfNeeded];
        } completion:^(BOOL finished){
            (void)finished;
            if(self.closing || generation!=self.interactionGeneration) return;
            self.rebounding=NO; self.expandedFrame=self.frame; [self updateContentInputGate];
        }];
    } else self.expandedFrame=self.frame;
    if(self.tools.userInteractionEnabled) [self expandTools];
}
- (void)pushCornerGesture:(UIPanGestureRecognizer *)gesture {
    if(self.dipped || self.docked || self.thumbnail || self.closing || self.dismissing || self.rebounding ||
       self.session.layoutInFlight || !self.ready || (self.activeManipulation && self.activeManipulation!=gesture)) return;
    if(gesture.state==UIGestureRecognizerStateBegan) {
        ++self.interactionGeneration;
        self.activeManipulation=gesture; self.gestureFrame=self.frame;
        self.cornerPushing=YES; self.cornerPushDeformation=CGPointZero;
        self.cornerPushRight=(gesture.view.tag&1)!=0;
        [self.content.layer removeAnimationForKey:@"zns.cornerPushReturn"];
        [self.bodyBackground.layer removeAnimationForKey:@"zns.cornerPushReturn"];
        [self updateContentInputGate];
    }
    if(self.activeManipulation!=gesture || !self.cornerPushing) return;
    CGPoint delta=[gesture translationInView:self.superview];
    if(!isfinite(delta.x) || !isfinite(delta.y)) delta=CGPointZero;
    CGFloat threshold=ZNSClamp(self.gestureFrame.size.width*0.30,80,140);
    CGFloat amount=MIN(1.35,fabs(delta.x)/threshold);
    if(fabs(delta.x)>1) self.cornerPushRight=delta.x>0;
    CGFloat sign=self.cornerPushRight?1:-1;
    // Rubber-band translation and shape use the CURRENT displacement, not the
    // largest value reached. Pulling back always reduces/reverses the effect.
    CGFloat travel=delta.x/(1+fabs(delta.x)/MAX(1,self.gestureFrame.size.width));
    CGRect moved=CGRectOffset(self.gestureFrame,travel,delta.y*0.35);
    self.frame=ZNSConstrainIcon(moved,[self mainSafe]);
    self.cornerPushDeformation=CGPointMake(-sign*MIN(32,self.bounds.size.width*0.10)*amount,
                                          -MIN(24,self.bounds.size.height*0.07)*amount);
    [self setNeedsLayout]; [self layoutIfNeeded];
    BOOL ended=gesture.state==UIGestureRecognizerStateEnded;
    BOOL cancelled=gesture.state==UIGestureRecognizerStateCancelled || gesture.state==UIGestureRecognizerStateFailed;
    if(!ended && !cancelled) return; // No admission while the finger is down.
    CATransform3D contentShape=self.content.layer.transform,bodyShape=self.bodyBackground.layer.transform;
    self.activeManipulation=nil; self.cornerPushing=NO; self.cornerPushDeformation=CGPointZero;
    BOOL commit=ended && fabs(delta.x)>=threshold && fabs(delta.x)>=fabs(delta.y)*1.2;
    if(commit) {
        self.thumbnailRight=delta.x>0;
        self.cornerPushParking=YES;
        BOOL parked=[self parkLiveThumbnail];
        self.cornerPushParking=NO;
        if(parked) {
            if(!UIAccessibilityIsReduceMotionEnabled()) {
                NSArray<CALayer *> *layers=@[self.content.layer,self.bodyBackground.layer];
                for(NSUInteger i=0;i<layers.count;i++) {
                    CALayer *layer=layers[i];
                    [layer removeAnimationForKey:@"zns.parkedPerspectiveBounce"];
                    CASpringAnimation *spring=[CASpringAnimation animationWithKeyPath:@"transform"];
                    spring.fromValue=[NSValue valueWithCATransform3D:(i?bodyShape:contentShape)];
                    spring.toValue=[NSValue valueWithCATransform3D:layer.transform];
                    spring.mass=1; spring.stiffness=220; spring.damping=23; spring.duration=0.48;
                    [layer addAnimation:spring forKey:@"zns.cornerPushReturn"];
                }
            }
            return;
        }
    }
    self.rebounding=YES;
    NSUInteger generation=++self.interactionGeneration;
    [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled()?0:0.42 delay:0 usingSpringWithDamping:0.76 initialSpringVelocity:0 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{
        self.frame=self.gestureFrame; [self setNeedsLayout]; [self layoutIfNeeded];
    } completion:^(BOOL finished) {
        (void)finished;
        if(self.closing || generation!=self.interactionGeneration) return;
        self.rebounding=NO; self.expandedFrame=self.frame; [self updateContentInputGate];
    }];
    if(!UIAccessibilityIsReduceMotionEnabled()) {
        NSArray<CALayer *> *layers=@[self.content.layer,self.bodyBackground.layer];
        for(NSUInteger i=0;i<layers.count;i++) {
            CASpringAnimation *spring=[CASpringAnimation animationWithKeyPath:@"transform"];
            spring.fromValue=[NSValue valueWithCATransform3D:(i?bodyShape:contentShape)];
            spring.toValue=[NSValue valueWithCATransform3D:CATransform3DIdentity];
            spring.mass=1; spring.stiffness=240; spring.damping=25;
            spring.duration=0.42;
            [layers[i] addAnimation:spring forKey:@"zns.cornerPushReturn"];
        }
    }
}
- (void)resizeGesture:(UIPanGestureRecognizer *)gesture {
    BOOL dipResize=self.dipExtracted && self.dipResizeAvailable && gesture.view.tag==1;
    if(self.dipped && !dipResize) return;
    if(gesture.view.tag>=2) { [self pushCornerGesture:gesture]; return; }
    if (self.closing || self.dismissing || self.rebounding || (self.activeManipulation && self.activeManipulation!=gesture) || self.docked || (self.thumbnail && !dipResize) || self.session.layoutInFlight) return;
    if (gesture.state==UIGestureRecognizerStateBegan) {
        self.activeManipulation=gesture; self.gestureFrame=self.frame;
        if(dipResize) [[ZNSWindowManager shared] setDipResizeHeld:YES window:self];
    }
    if(self.activeManipulation!=gesture) return;
    CGPoint delta=[gesture translationInView:self.superview];
    if(dipResize) self.frame=ZNSResizeWindowWithChrome(self.gestureFrame,delta,1,[self mainSafe],self.thumbnail?CGSizeZero:ZNSMainChrome(self.fillHeightLayout));
    else self.frame=ZNSResizeMainWindow(self.gestureFrame,delta,(unsigned)gesture.view.tag,[self safe],self.fillHeightLayout);
    [self setNeedsLayout];
    if (gesture.state==UIGestureRecognizerStateCancelled || gesture.state==UIGestureRecognizerStateFailed) self.frame=self.gestureFrame;
    if (gesture.state==UIGestureRecognizerStateEnded || gesture.state==UIGestureRecognizerStateCancelled || gesture.state==UIGestureRecognizerStateFailed) {
        self.activeManipulation=nil;
        if(!self.thumbnail) self.expandedFrame=self.frame;
        if(dipResize) [[ZNSWindowManager shared] setDipResizeHeld:NO window:self];
    }
    if(dipResize) {
        [self layoutIfNeeded];
        [[ZNSWindowManager shared] updateDipDynamicIcon];
    }
}
- (void)applySceneSize {
    // Presentation-only resize: never submit a tiny window-sized App canvas.
    if(self.closing) return;
    if(self.session.layoutInFlight) { self.needsSceneResize=YES; return; }
    self.needsSceneResize=NO; [self attachHost];
}
- (void)rotateApp {
    if(self.dipped) return;
    [self expandTools]; if (self.docked || self.thumbnail) return;
    [self rotateHostedCanvas];
}
- (void)rotateHostedCanvas {
    [self rotateHostedCanvasToLandscape:!self.session.landscape automatic:NO];
}
- (BOOL)applyPendingDeviceOrientation {
    if(self.dipExtracted) { self.pendingDeviceOrientation=NO; self.switcherLaunchOrientationPending=NO; return NO; }
    if (self.closing) { self.pendingDeviceOrientation=NO; self.switcherLaunchOrientationPending=NO; return NO; }
    if (self.deviceRotationInFlight) return YES;
    if (!ZNSFollowDeviceRotation && !self.switcherLaunchOrientationPending) { self.pendingDeviceOrientation=NO; return NO; }
    if (!self.pendingDeviceOrientation) return NO;
    BOOL mainWindow=self.dipExtracted || (!self.thumbnail && !self.docked && !self.dipped);
    BOOL parkedFollower=!self.manualOrientationOverride && self.thumbnailTier<=1 &&
        (self.thumbnail || (self.docked && self.dockedFromThumbnail && self.rotationOverflow));
    if ((!mainWindow && !parkedFollower) || (self.switcherLaunchOrientationPending && !mainWindow)) {
        self.pendingDeviceOrientation=NO; self.switcherLaunchOrientationPending=NO; return NO;
    }
    // The initial connection/rotation callback schedules packing again. Never
    // pack the old portrait canvas and collapse it before the new canvas arrives.
    if (self.connecting || self.session.layoutInFlight ||
        (self.dipExtracted && (self.activeManipulation || self.rebounding))) return YES;
    if (self.switcherLaunchOrientationPending &&
        (self.parkedPan || self.activeManipulation || self.dismissing || self.rebounding)) return YES;
    self.pendingDeviceOrientation=NO;
    if (!self.ready || self.session.landscape==self.deviceLandscapeTarget) {
        self.switcherLaunchOrientationPending=NO; return NO;
    }
    [self rotateHostedCanvasToLandscape:self.deviceLandscapeTarget automatic:YES];
    self.switcherLaunchOrientationPending=NO;
    return self.deviceRotationInFlight;
}
- (void)rotateHostedCanvasToLandscape:(BOOL)landscape automatic:(BOOL)automatic {
    [self restorePortraitKeyboardWithDuration:0 options:0];
    if(self.dipped) return;
    if(automatic && !ZNSFollowDeviceRotation && !self.switcherLaunchOrientationPending) { self.pendingDeviceOrientation=NO; return; }
    if (self.closing || self.parkedPan || self.activeManipulation || self.dismissing || self.rebounding || !self.ready || (!automatic && self.docked) || self.session.layoutInFlight) return;
    CGSize canvas=ZNSScreenCanvas(ZNSCanvasSurfaceSize(self.superview),landscape);
    __weak typeof(self) weakSelf=self;
    self.deviceRotationInFlight=automatic;
    BOOL accepted=[self.session resize:canvas landscape:landscape completion:^(BOOL success,NSString *message) {
        ZNSFloatingView *self=weakSelf;
        if (!self || self.closing || !self.superview) return;
        self.deviceRotationInFlight=NO;
        if (!success) {
            os_log_error(ZNSLog(),"rotation rejected after scene callback: %{public}@",message);
            if (self.closeAction) self.closeAction(NO);
            return;
        }
        // Read the CURRENT device bounds after the async scene update. A device
        // rotation in flight must never restore a captured old-sized frame.
        self.thumbnailTier=MIN(self.thumbnailTier,ZNSThumbnailMaxTier(landscape));
        self.thumbnailFree=self.thumbnailTier==2 || (self.thumbnailTier==1 && self.thumbnailFree);
        CGRect fittedMain=[self defaultMainFrame];
        self.expandedFrame=fittedMain;
        self.restoringPosition=NO;
        if (!automatic) { self.portraitSaved=NO; self.rotationOverflow=NO; }
        ZNSAnimate(0.20, ^{
            if (!self.docked) self.frame=self.thumbnail?[self thumbnailFrameInSafe:[self safe]]:fittedMain;
            [self attachHost];
        });
        if (self.presentationChanged) self.presentationChanged();
        if(self.needsSceneResize || landscape) [self applySceneSize];
        os_log(ZNSLog(),"rotation layout synchronized thumbnail=%d landscape=%d automatic=%d",self.thumbnail,landscape,automatic);
    }];
    if (accepted) {
        if (!automatic) {
            self.manualOrientationOverride=YES;
            self.pendingDeviceOrientation=NO;
            ZNSActionFeedback();
        }
        [self setNeedsLayout]; [self layoutIfNeeded];
    }
    else {
        self.deviceRotationInFlight=NO;
        os_log_error(ZNSLog(),"rotation request not accepted; existing window retained");
    }
}
- (void)fitAfterContainerChange {
    // UIKit may relayout the unchanged root while the keyboard animates.
    // Only a real container/safe-area change owns the presentation now.
    if (!CGSizeEqualToSize(self.superview.bounds.size,self.lastContainerSize) ||
        !CGRectEqualToRect([self safe],self.lastSafeBounds))
        [self restorePortraitKeyboardWithDuration:0 options:0];
    if(self.closing) return;
    if(self.dipExtracted) {
        CGSize size=self.superview.bounds.size;
        CGRect safe=[self mainSafe];
        if(CGSizeEqualToSize(size,self.lastContainerSize) && CGRectEqualToRect(safe,self.lastSafeBounds)) return;
        self.lastContainerSize=size; self.lastSafeBounds=safe;
        [self cancelInteraction]; ++self.containerGeneration;
        self.pendingDeviceOrientation=NO;
        self.expandedFrame=[self defaultMainFrame];
        CGRect target=self.dipReturnLandscape?ZNSThumbnailTierFrame(self.session.canvasSize,safe,self.thumbnailRight,2):self.expandedFrame;
        self.frame=ZNSCenterFrame(target,safe);
        [self attachHost]; [self setNeedsLayout];
        return;
    }
    if(self.dipped && !self.dipExtracted) {
        CGSize size=self.superview.bounds.size;
        BOOL changed=!CGSizeEqualToSize(size,self.lastContainerSize);
        self.lastContainerSize=size; self.lastSafeBounds=[self safe];
        if(changed) {
            [self cancelInteraction]; ++self.containerGeneration;
            // Keep the admission size as the reference; fit it afresh for each
            // orientation rather than cumulatively shrinking the dipped card.
            self.expandedFrame=ZNSFitMainWindow(self.dipExpandedFrame,[self mainSafe],0);
        }
        [self setNeedsLayout];
        return;
    }
    CGSize size=self.superview.bounds.size;
    CGRect safe=[self safe];
    if (CGSizeEqualToSize(size,self.lastContainerSize) && CGRectEqualToRect(safe,self.lastSafeBounds)) return;
    CGSize old=self.lastContainerSize; self.lastContainerSize=size;
    self.lastSafeBounds=safe;
    [self setNeedsLayout];
    ++self.containerGeneration;
    if (old.width<=0 || old.height<=0) { self.frame=[self defaultMainFrame]; self.expandedFrame=self.frame; return; }
    if(self.session.layoutInFlight) self.needsSceneResize=YES;
    [self cancelInteraction];
    BOOL toLandscape=old.width<=old.height && size.width>size.height;
    BOOL toPortrait=old.width>old.height && size.width<=size.height;
    BOOL mainWindow=self.dipExtracted || (!self.thumbnail && !self.docked && !self.dipped);
    BOOL parkedFollower=!self.manualOrientationOverride && self.thumbnailTier<=1 &&
        (self.thumbnail || (self.docked && self.dockedFromThumbnail && self.rotationOverflow));
    if (ZNSFollowDeviceRotation && (toLandscape || toPortrait) && (mainWindow || parkedFollower)) {
        // Align the main window with the new device orientation using exactly
        // the scene-rotation path used by the toolbar, not a UIKit transform.
        // Existing parked/manual-override eligibility is intentionally unchanged.
        self.deviceLandscapeTarget=toLandscape;
        self.pendingDeviceOrientation=YES;
    }
    if(toLandscape && self.thumbnail) { self.portraitFrame=self.frame; self.portraitCanvas=self.session.canvasSize; self.portraitTier=self.thumbnailTier; self.portraitSaved=YES; }
    if(toLandscape) self.restoringPosition=NO;
    if(toPortrait && self.portraitSaved) {
        self.restoringPosition=self.thumbnail;
        self.restoreOnNextArrange=self.docked && self.rotationOverflow;
    }
    // A device orientation transition resets the future main window too, even
    // while it is parked as a thumbnail/icon. No tiny landscape frame survives.
    if(toLandscape || toPortrait) self.expandedFrame=[self defaultMainFrame];
    else self.expandedFrame=ZNSFitMainWindow(self.expandedFrame,safe,self.fillHeightLayout);
    if (self.thumbnail) {
        if (self.thumbnailFree) self.center=CGPointMake(self.center.x/old.width*size.width,self.center.y/old.height*size.height);
        CGRect target=[self thumbnailFrameInSafe:safe];
        if(self.restoringPosition) target.origin=self.portraitFrame.origin;
        self.frame=ZNSConstrainIcon(target,self.thumbnailFree?[self parkedMovementArea]:safe);
        return;
    }
    if (self.docked) {
        CGPoint center=self.center;
        center.x=center.x/old.width*size.width; center.y=center.y/old.height*size.height;
        self.center=center; self.frame=ZNSConstrainIcon(self.frame,safe);
    }
    else {
        self.frame=(toLandscape || toPortrait)?self.expandedFrame:ZNSFitMainWindow(self.frame,safe,self.fillHeightLayout);
        self.expandedFrame=self.frame;
        [self applySceneSize];
    }
}
@end

static char ZNSIconGesturesKey;
static NSUInteger ZNSPreferenceReads;
static NSUInteger ZNSTouchCandidates;
static NSUInteger ZNSTouchAccepted;
static NSUInteger ZNSRecognizedSwipes;
@implementation ZNSWindowManager
- (CGRect)dipFrameForWindow:(ZNSFloatingView *)view index:(NSUInteger)index count:(NSUInteger)count {
    CGRect safe=[self mainAvailableFrame],screen=self.controller.view.bounds;
    CGRect frame=ZNSDipCardFrame(view.dipExpandedFrame,safe,screen,(unsigned)index,(unsigned)count);
    // Shared size and angle make every slot's top/bottom identical. Never
    // align against another App's saved frame or temporary scene orientation.
    CGFloat angle=ZNSDipCardAngle(view.session.landscape);
    CGFloat tiltedHeight=frame.size.height*fabs(cos(angle))+frame.size.width*fabs(sin(angle));
    // Pin the upper 30% of the final tilted footprint to the CURRENT screen
    // bottom in both orientations, overriding any old slot/corner y offset.
    frame.origin.y=CGRectGetMaxY(screen)+tiltedHeight*0.20-frame.size.height/2;
    return frame;
}
- (CGFloat)dipReservedTop {
    CGRect screen=self.controller.view.bounds;
    CGFloat top=CGRectGetMaxY(screen);
    NSUInteger index=0,count=self.dippedOrder.count;
    for(ZNSFloatingView *view in self.dippedOrder) {
        if(!view.closing && view.dipped) {
            CGRect frame=[self dipFrameForWindow:view index:index count:count];
            CGFloat angle=ZNSDipCardAngle(view.session.landscape);
            top=MIN(top,CGRectGetMidY(frame)-(frame.size.height*cos(angle)+frame.size.width*sin(angle))/2-10);
        }
        index++;
    }
    return top;
}
- (CGRect)parkedMovementFrame {
    CGRect frame=self.controller.view.bounds;
    frame.size.height=MAX(1,MIN(CGRectGetMaxY(frame),[self dipReservedTop])-frame.origin.y);
    return frame;
}
- (void)trackDesktopDockView:(UIView *)view {
    if(!NSThread.isMainThread || !view) return;
    if(!self.desktopDockViews) self.desktopDockViews=[NSHashTable weakObjectsHashTable];
    [self.desktopDockViews addObject:view];
    for(ZNSFloatingView *card in self.dippedOrder) [card updateDipAppearance];
}
- (CGRect)desktopDockFrame {
    CGRect result=CGRectNull;
    for(UIView *dock in self.desktopDockViews) {
        if(!dock.window || dock.window.screen!=self.window.screen || dock.hidden || dock.alpha<0.01) continue;
        BOOL visible=YES;
        for(UIView *parent=dock.superview;parent;parent=parent.superview)
            if(parent.hidden || parent.alpha<0.01) { visible=NO; break; }
        if(!visible) continue;
        CGRect frame=[dock convertRect:dock.bounds toView:self.controller.view];
        frame=CGRectIntersection(frame,self.controller.view.bounds);
        if(!CGRectIsNull(frame) && !CGRectIsEmpty(frame)) result=CGRectIsNull(result)?frame:CGRectUnion(result,frame);
    }
    return result;
}
- (void)setDipResizeHeld:(BOOL)held window:(ZNSFloatingView *)card {
    if(!card || card!=self.dipExtractedWindow || !card.dipResizeAvailable || card.closing) return;
    [self cancelDipRestoreConfirmation];
    [self.dipDragonTimer invalidate]; self.dipDragonTimer=nil;
    self.dipDragonDeadline=0; self.dipDragonRemaining=5;
    self.dipDragonHeld=held;
    if(!held && !card.activeManipulation) [self scheduleDipDragonHide];
}
- (void)cancelDipRestoreConfirmation {
    self.dipRestoreDeadline=0;
    [self.dipIcon.layer removeAnimationForKey:@"ZNSDipRestoreFlash"];
    [self.dipDynamicIcon.layer removeAnimationForKey:@"ZNSDipRestoreFlash"];
}
- (void)beginDipRestoreConfirmation {
    if(!self.dipIcon || !self.dipDynamicIcon || !self.dipExtractedWindow) return;
    [self.dipDragonTimer invalidate]; self.dipDragonTimer=nil;
    [self cancelDipRestoreConfirmation];
    self.dipRestoreDeadline=CACurrentMediaTime()+5.0;
    self.dipDragonDeadline=0;
    for(UIView *icon in @[self.dipIcon,self.dipDynamicIcon]) {
        CABasicAnimation *flash=[CABasicAnimation animationWithKeyPath:@"opacity"];
        flash.fromValue=@1; flash.toValue=@0.30; flash.duration=0.5;
        flash.autoreverses=YES; flash.repeatCount=5;
        [icon.layer addAnimation:flash forKey:@"ZNSDipRestoreFlash"];
    }
    self.dipIcon.accessibilityHint=@"五秒内再次点击恢复取出窗口的触摸和工具";
    __weak typeof(self) weakSelf=self;
    self.dipDragonTimer=[NSTimer timerWithTimeInterval:5 repeats:NO block:^(NSTimer *timer) {
        ZNSWindowManager *manager=weakSelf;
        if(manager.dipDragonTimer!=timer) return;
        manager.dipDragonTimer=nil;
        [manager cancelDipRestoreConfirmation];
        if(!manager.dipDragonHeld && !manager.dipExtractedWindow.activeManipulation)
            [manager swimDipDragonHome:YES];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.dipDragonTimer forMode:NSRunLoopCommonModes];
}
- (void)stopDipDragonMotion {
    [self cancelDipRestoreConfirmation];
    self.dipDragonDeparting=NO;
    [self.dipDragonTimer invalidate]; self.dipDragonTimer=nil;
    [self.dipDragonClock invalidate]; self.dipDragonClock=nil;
    self.dipDragonDeadline=0; self.dipDragonHeld=NO;
    self.dipDragonStowed=NO; self.dipDragonRemaining=5;
    self.dipDynamicIcon.transform=CGAffineTransformIdentity;
    [self.dipDragonTether removeFromSuperlayer]; self.dipDragonTether=nil;
    self.dipIcon.showsCompanionDragon=NO;
}
- (void)recallDipDragon {
    if(!self.dipExtractionEnabled || !self.enabled || !self.dipExtractedWindow || self.dipExtractedWindow.closing) return;
    [self stopDipDragonMotion];
    [self.dipDynamicIcon.layer removeAllAnimations];
    self.dipDynamicIcon.hidden=NO; self.dipDynamicIcon.alpha=1;
    [self updateDipDynamicIcon];
    [self scheduleDipDragonHide];
}
- (void)dipTrayPressed:(UIControl *)sender {
    self.dipTrayRecalledOnTouch=NO;
    if(sender!=self.dipIcon || !self.dipExtractedWindow || self.dipDragonDeparting) return;
    // A touch while away recalls only; a later tap at the corner arms restore.
    if(self.dipDragonClock || self.dipDragonStowed) {
        [self recallDipDragon]; self.dipTrayRecalledOnTouch=YES;
    }
}
- (CGPoint)dipDragonCornerCenter {
    CGRect safe=[self mainAvailableFrame];
    CGFloat size=MIN(ZNSParkedIconSize()*0.80,MIN(safe.size.width,safe.size.height));
    CGRect frame=ZNSConstrainIcon((CGRect){self.dipExtractedWindow.frame.origin,CGSizeMake(size,size)},safe);
    return CGPointMake(CGRectGetMidX(frame),CGRectGetMidY(frame));
}
- (void)scheduleDipDragonHide {
    if(self.dipRestoreDeadline>CACurrentMediaTime()) return;
    [self.dipDragonTimer invalidate]; self.dipDragonTimer=nil;
    if(!self.dipExtractionEnabled || !self.dipExtractedWindow || self.dipDragonHeld || self.dipDragonStowed || self.dipDragonClock || self.dipExtractedWindow.activeManipulation) return;
    [self cancelDipRestoreConfirmation];
    NSTimeInterval delay=MAX(0.05,self.dipDragonRemaining);
    self.dipDragonDeadline=CACurrentMediaTime()+delay;
    __weak typeof(self) weakSelf=self;
    self.dipDragonTimer=[NSTimer timerWithTimeInterval:delay repeats:NO block:^(NSTimer *timer){
        ZNSWindowManager *manager=weakSelf;
        if(manager.dipDragonTimer!=timer) return;
        manager.dipDragonTimer=nil; manager.dipDragonDeadline=0;
        if(manager.dipDragonHeld || manager.dipExtractedWindow.activeManipulation) return;
        [manager swimDipDragonHome:YES];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.dipDragonTimer forMode:NSRunLoopCommonModes];
}
- (void)dipDragonPressed:(UIControl *)sender {
    if(sender!=self.dipDynamicIcon || !self.dipExtractedWindow || self.dipDragonClock) return;
    [self cancelDipRestoreConfirmation];
    self.dipDragonRemaining=5;
    self.dipDragonPressBegan=CACurrentMediaTime(); self.dipDragonSuppressTap=NO;
    [self.dipDragonTimer invalidate]; self.dipDragonTimer=nil;
    self.dipDragonDeadline=0; self.dipDragonHeld=YES;
}
- (void)dipDragonReleased:(UIControl *)sender {
    if(sender!=self.dipDynamicIcon || !self.dipExtractedWindow) return;
    self.dipDragonHeld=NO; self.dipDragonRemaining=5;
    if(self.dipDragonPressBegan>0 && CACurrentMediaTime()-self.dipDragonPressBegan>=0.35) self.dipDragonSuppressTap=YES;
    if(!self.dipExtractedWindow.activeManipulation) [self scheduleDipDragonHide];
}
- (void)swimDipDragonHome:(BOOL)home {
    if(!self.dipExtractionEnabled || (!self.dipExtractedWindow && !self.dipDragonDeparting) || !self.dipDynamicIcon || !self.dipIcon) return;
    if(!home) { [self recallDipDragon]; return; }
    [self cancelDipRestoreConfirmation];
    [self.dipDragonTimer invalidate]; self.dipDragonTimer=nil; self.dipDragonDeadline=0;
    [self.dipDragonClock invalidate]; self.dipDragonClock=nil;
    self.dipIcon.showsCompanionDragon=NO;
    [self.dipDragonTether removeFromSuperlayer];
    self.dipDragonTether=[CAShapeLayer layer];
    self.dipDragonTether.strokeColor=UIColor.systemRedColor.CGColor;
    self.dipDragonTether.fillColor=UIColor.clearColor.CGColor;
    self.dipDragonTether.lineWidth=3; self.dipDragonTether.lineCap=kCALineCapRound;
    self.dipDragonTether.zPosition=9999;
    [self.controller.view.layer addSublayer:self.dipDragonTether];
    self.dipDragonStowed=NO; self.dipDragonHeld=NO;
    self.dipDragonReturning=home;
    self.dipDragonFlightOrigin=self.dipDynamicIcon.center;
    self.dipDragonFlightStart=CACurrentMediaTime();
    [self.dipDynamicIcon.layer removeAllAnimations];
    self.dipDynamicIcon.hidden=NO; self.dipDynamicIcon.alpha=1;
    self.dipDynamicIcon.userInteractionEnabled=NO;
    ZNSSetLayerInputEnabled(self.dipDynamicIcon.layer,NO);
    self.dipExtractedWindow.dipResizeAvailable=NO;
    [self.dipExtractedWindow layoutIfNeeded];
    self.dipDragonClock=[CADisplayLink displayLinkWithTarget:self selector:@selector(tickDipDragon:)];
    self.dipDragonClock.preferredFramesPerSecond=30;
    [self.dipDragonClock addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}
- (void)tickDipDragon:(CADisplayLink *)clock {
    if(!self.dipExtractionEnabled || !self.enabled ||
       (!self.dipExtractedWindow && !self.dipDragonDeparting) || self.dipExtractedWindow.closing ||
       !self.dipIcon || !self.dippedOrder.count || self.window.hidden) { [self clearDipExtraction]; return; }
    BOOL home=self.dipDragonReturning;
    CGPoint end=home?self.dipIcon.center:[self dipDragonCornerCenter];
    CGPoint start=self.dipDragonFlightOrigin;
    CGFloat t=MIN(1,MAX(0,(clock.timestamp-self.dipDragonFlightStart)/5.0));
    CGFloat u=t*t*(3-2*t),dx=end.x-start.x,dy=end.y-start.y,length=MAX(1,hypot(dx,dy));
    // Three alternating bends taper at both ends while the dragon's own body
    // wave keeps crawling. Endpoint tracks the live tray/corner after rotation.
    CGFloat wave=UIAccessibilityIsReduceMotionEnabled()?0:sin(t*M_PI*6)*sin(t*M_PI)*MIN(22,length*0.12);
    self.dipDynamicIcon.center=CGPointMake(start.x+dx*u-dy/length*wave,start.y+dy*u+dx/length*wave);
    CGFloat scale=home?1-0.80*u:0.20+0.80*u;
    self.dipDynamicIcon.transform=CGAffineTransformMakeScale(scale,scale);
    UIBezierPath *tether=[UIBezierPath bezierPath];
    CGPoint dragon=self.dipDynamicIcon.center;
    CGFloat distance=hypot(dragon.x-end.x,dragon.y-end.y);
    CGFloat radius=MIN(distance,CGRectGetWidth(self.dipIcon.bounds)*0.5);
    CGPoint edge=distance>0?CGPointMake(end.x+(dragon.x-end.x)*radius/distance,end.y+(dragon.y-end.y)*radius/distance):end;
    [tether moveToPoint:dragon]; [tether addLineToPoint:edge];
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    self.dipDragonTether.frame=self.controller.view.bounds;
    self.dipDragonTether.path=tether.CGPath;
    self.dipDragonTether.opacity=MIN(1,MAX(0,(distance-radius)/20));
    [CATransaction commit];
    [self.controller.view bringSubviewToFront:self.dipDynamicIcon];
    if(t<1) return;
    if(self.dipDragonDeparting) {
        [self clearDipExtraction];
        [self updateDipIconTetherSelecting:NO];
        return;
    }
    [self.dipDragonClock invalidate]; self.dipDragonClock=nil;
    self.dipDynamicIcon.transform=CGAffineTransformIdentity;
    self.dipDragonStowed=home; self.dipDynamicIcon.hidden=home;
    self.dipIcon.showsCompanionDragon=home;
    [self.dipDragonTether removeFromSuperlayer]; self.dipDragonTether=nil;
    self.dipDynamicIcon.alpha=home?0:1;
    if(!home) {
        self.dipDragonRemaining=5;
        [self updateDipDynamicIcon]; [self scheduleDipDragonHide];
    }
}
- (void)disableDipExtractionWhenReady {
    if(self.dipExtractionEnabled) return;
    [self stopDipDragonMotion];
    self.dipDynamicIcon.hidden=YES; self.dipDynamicIcon.userInteractionEnabled=NO;
    ZNSSetLayerInputEnabled(self.dipDynamicIcon.layer,NO);
    ZNSFloatingView *card=self.dipExtractedWindow;
    card.dipResizeAvailable=NO; [card layoutIfNeeded];
    if(!card || card.closing) { [self clearDipExtraction]; return; }
    if(card.session.layoutInFlight || card.rebounding) {
        NSUInteger generation=self.dipExtractionGeneration;
        __weak typeof(self) weakSelf=self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/10),dispatch_get_main_queue(),^{
            if(weakSelf.dipExtractionGeneration==generation) [weakSelf disableDipExtractionWhenReady];
        });
        return;
    }
    [card cancelInteraction];
    [self returnExtractedDip];
}
- (void)clearDipExtraction {
    [self stopDipDragonMotion];
    ++self.dipExtractionGeneration;
    self.dipRestoreDeadline=0;
    [self.dipIcon.layer removeAnimationForKey:@"ZNSDipRestoreFlash"];
    ZNSFloatingView *card=self.dipExtractedWindow;
    self.dipExtractedWindow=nil;
    if(card.activeManipulation==self.dipDynamicPan) card.activeManipulation=nil;
    card.dipExtracted=NO; card.dipResizeAvailable=NO; card.parkedSqueezeProgress=0;
    self.dipDynamicPan.enabled=NO;
    ZNSSetLayerInputEnabled(self.dipDynamicIcon.layer,NO);
    [self.dipDynamicIcon removeFromSuperview]; self.dipDynamicIcon=nil; self.dipDynamicPan=nil;
    self.dipIcon.accessibilityHint=@"轻点恢复对应窗口；拖动靠近下探窗口左上角切换应用";
}
- (void)updateDipDynamicIcon {
    if(self.dipDragonDeparting) return; // Preserve the live five-second flight.
    ZNSFloatingView *card=self.dipExtractedWindow;
    BOOL extracted=card && card.dipExtracted && card.dipped && !card.closing;
    card.dipResizeAvailable=extracted && self.dipExtractionEnabled && self.enabled &&
        !self.closingAllWindows && !self.deviceLockClosing && self.controller &&
        !self.dipDragonStowed && !self.dipDragonClock && !self.window.hidden;
    BOOL near=self.dipTether && self.dipTether.opacity>0;
    if(!self.dipExtractionEnabled || !self.enabled || self.closingAllWindows || self.deviceLockClosing || !self.controller || self.window.hidden ||
       (!extracted && (!near || !self.dipToolbarOwner || self.dipIcon.hidden))) {
        if(self.dipDynamicIcon) {
            self.dipDynamicIcon.userInteractionEnabled=NO;
            ZNSSetLayerInputEnabled(self.dipDynamicIcon.layer,NO);
            if(self.dipDynamicIcon.alpha>0) [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled()?0:0.85 delay:0 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{ self.dipDynamicIcon.alpha=0; } completion:nil];
        }
        return;
    }
    if(extracted && (self.dipDragonStowed || self.dipDragonClock)) {
        if(self.dipDragonStowed) self.dipDynamicIcon.hidden=YES;
        self.dipDynamicIcon.userInteractionEnabled=NO;
        ZNSSetLayerInputEnabled(self.dipDynamicIcon.layer,NO);
        return;
    }
    if(!self.dipDynamicIcon) {
        self.dipDynamicIcon=[[ZNSDipIconView alloc] initWithFrame:CGRectZero];
        self.dipDynamicIcon.appImage=nil;
        self.dipDynamicIcon.backgroundColor=UIColor.clearColor;
        self.dipDynamicIcon.layer.borderColor=[UIColor colorWithWhite:1 alpha:0.35].CGColor;
        self.dipDynamicIcon.alpha=0;
        self.dipDynamicIcon.accessibilityIdentifier=@"ZNSDipDynamicIcon";
        self.dipDynamicIcon.accessibilityLabel=@"下探动态图标";
        [self.dipDynamicIcon addTarget:self action:@selector(dipDynamicTapped) forControlEvents:UIControlEventTouchUpInside];
        [self.dipDynamicIcon addTarget:self action:@selector(dipDragonPressed:) forControlEvents:UIControlEventTouchDown];
        [self.dipDynamicIcon addTarget:self action:@selector(dipDragonReleased:) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside|UIControlEventTouchCancel];
        self.dipDynamicPan=[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragDipDynamic:)];
        self.dipDynamicPan.maximumNumberOfTouches=1;
        [self.dipDynamicIcon addGestureRecognizer:self.dipDynamicPan];
        [self.controller.view addSubview:self.dipDynamicIcon];
        ZNSSetLayerInputOpaque(self.dipDynamicIcon.layer,YES);
    }
    CGRect safe=[self mainAvailableFrame];
    CGFloat size=MIN(ZNSParkedIconSize()*0.80,MIN(safe.size.width,safe.size.height));
    CGPoint origin;
    if(extracted) origin=CGPointMake(CGRectGetMinX(card.frame),CGRectGetMinY(card.frame));
    else {
        origin=CGPointMake(CGRectGetMaxX(self.dipIcon.frame)+4,CGRectGetMidY(self.dipIcon.frame)-size/2);
        if(origin.x+size>CGRectGetMaxX(safe)) origin.x=CGRectGetMinX(self.dipIcon.frame)-size-4;
    }
    self.dipDynamicIcon.hidden=NO;
    self.dipDynamicIcon.frame=ZNSConstrainIcon((CGRect){origin,CGSizeMake(size,size)},safe);
    self.dipDynamicIcon.accessibilityHint=extracted?@"点击依次切换下探窗口；拖动移动，向下挤压放回":@"取出对应窗口，保持透明和触摸穿透";
    self.dipDynamicIcon.layer.cornerRadius=size*0.30;
    self.dipDynamicIcon.layer.borderWidth=0.8;
    if(self.dipDynamicIcon.alpha<1) [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled()?0:0.25 delay:0 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{ self.dipDynamicIcon.alpha=1; } completion:nil];
    self.dipDynamicIcon.userInteractionEnabled=YES;
    ZNSSetLayerInputEnabled(self.dipDynamicIcon.layer,YES);
    [self.controller.view bringSubviewToFront:self.dipDynamicIcon];
}
- (void)extractDipWindow:(ZNSFloatingView *)view {
    if(!self.dipExtractionEnabled || !self.enabled || !ZNSReadAuthorization(YES) || self.deviceLockClosing || self.closingAllWindows ||
       !view.dipped || view.closing || view.rebounding || view.session.layoutInFlight ||
       ![self.dippedOrder containsObject:view] || self.dipExtractedWindow) return;
    [self stopDipDragonMotion];
    self.dipExtractedWindow=view; view.dipExtracted=YES;
    self.dipToolbarOwner=view;
    NSUInteger token=++self.dipExtractionGeneration;
    [self clearDipTether]; [self updateDipMotion];
    __weak typeof(self) weakSelf=self;
    __weak ZNSFloatingView *weakView=view;
    void (^present)(BOOL)=^(BOOL success) {
        ZNSWindowManager *manager=weakSelf; ZNSFloatingView *card=weakView;
        if(!manager || !card || token!=manager.dipExtractionGeneration || manager.dipExtractedWindow!=card || card.closing) return;
        if(!success) { [manager clearDipExtraction]; [manager layoutDippedWindows:YES]; return; }
        // Use the App's admission orientation, never the tray's forced portrait
        // canvas or the device orientation at the instant of extraction.
        BOOL landscape=card.dipReturnLandscape;
        card.docked=NO; card.thumbnail=landscape;
        card.thumbnailTier=landscape?2:0; card.thumbnailFree=landscape;
        CGRect safe=[manager mainAvailableFrame];
        card.expandedFrame=[card defaultMainFrame];
        CGRect target=landscape?ZNSThumbnailTierFrame(card.session.canvasSize,safe,card.thumbnailRight,2):card.expandedFrame;
        target=ZNSCenterFrame(target,safe);
        card.pendingDeviceOrientation=NO;
        card.rebounding=YES; ++card.interactionGeneration;
        [card setNeedsLayout]; [card updateContentInputGate];
        [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled()?0:0.42 delay:0 usingSpringWithDamping:0.68 initialSpringVelocity:0 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{
            card.transform=CGAffineTransformIdentity;
            card.bounds=(CGRect){CGPointZero,target.size}; card.center=CGPointMake(CGRectGetMidX(target),CGRectGetMidY(target));
            [card attachHost]; [card layoutIfNeeded];
            [manager updateDipDynamicIcon];
        } completion:^(BOOL finished) {
            (void)finished;
            if(token!=manager.dipExtractionGeneration || manager.dipExtractedWindow!=card || card.closing) return;
            card.rebounding=NO; [card updateContentInputGate];
            [manager updateDipIcon]; [manager updateWindowStack]; [manager scheduleArrange];
            if(manager.dipExtractionEnabled) [manager scheduleDipDragonHide];
            else [manager disableDipExtractionWhenReady];
        }];
        [manager updateWindowStack];
    };
    BOOL landscape=view.dipReturnLandscape;
    if(view.session.landscape!=landscape) {
        BOOL accepted=[view.session resize:ZNSScreenCanvas(ZNSCanvasSurfaceSize(self.controller.view),landscape) landscape:landscape completion:^(BOOL success,NSString *message) { (void)message; present(success); }];
        if(!accepted) present(NO);
    } else present(YES);
}
- (void)returnExtractedDip { [self returnExtractedDipSelecting:nil]; }
- (void)returnExtractedDipSelecting:(ZNSFloatingView *)next {
    ZNSFloatingView *card=self.dipExtractedWindow;
    if(!card || card.closing || card.session.layoutInFlight || card.rebounding) return;
    // Preserve the admission frame/orientation; putting back is not a new entry.
    card.thumbnail=NO; card.thumbnailFree=NO; card.pendingDeviceOrientation=NO;
    [self clearDipExtraction];
    self.dipToolbarOwner=card;
    if(card.session.landscape) {
        __weak typeof(self) weakSelf=self;
        __weak ZNSFloatingView *weakCard=card;
        BOOL accepted=[card.session resize:ZNSScreenCanvas(ZNSCanvasSurfaceSize(self.controller.view),NO) landscape:NO completion:^(BOOL success,NSString *message) {
            (void)message;
            ZNSWindowManager *manager=weakSelf; ZNSFloatingView *view=weakCard;
            if(!manager || !view || view.closing || !view.dipped || view.dipExtracted || ![manager.windows containsObject:view]) return;
            if(!success) { if(view.closeAction) view.closeAction(NO); return; }
            [view attachHost]; [manager layoutDippedWindows:YES]; [manager scheduleArrange];
        }];
        if(!accepted) { if(card.closeAction) card.closeAction(NO); return; }
    }
    if(next) [self extractDipWindow:next];
    [self layoutDippedWindows:YES]; [self scheduleArrange];
}
- (void)dipDynamicTapped {
    if(!self.dipExtractionEnabled || !self.enabled || !ZNSReadAuthorization(YES)) return;
    if(self.dipExtractedWindow && (self.dipDragonSuppressTap ||
       (self.dipDragonPressBegan>0 && CACurrentMediaTime()-self.dipDragonPressBegan>=0.35))) return;
    ZNSFloatingView *old=self.dipExtractedWindow;
    if(!old) { [self extractDipWindow:self.dipToolbarOwner]; return; }
    if(old.closing || old.rebounding || old.session.layoutInFlight || self.dippedOrder.count<2) return;
    NSUInteger index=[self.dippedOrder indexOfObjectIdenticalTo:old];
    if(index==NSNotFound) return;
    ZNSFloatingView *next=nil;
    for(NSUInteger step=1;step<self.dippedOrder.count;step++) {
        ZNSFloatingView *candidate=self.dippedOrder[(index+step)%self.dippedOrder.count];
        if(candidate.dipped && !candidate.closing && !candidate.rebounding && !candidate.session.layoutInFlight) { next=candidate; break; }
    }
    if(!next) return;
    [self returnExtractedDipSelecting:next];
}
- (void)dragDipDynamic:(UIPanGestureRecognizer *)gesture {
    ZNSFloatingView *card=self.dipExtractedWindow;
    if(!card || card.closing || card.rebounding || card.session.layoutInFlight || gesture!=self.dipDynamicPan) return;
    if(gesture.state==UIGestureRecognizerStateBegan) {
        [self.dipDragonTimer invalidate]; self.dipDragonTimer=nil;
        self.dipDragonDeadline=0; self.dipDragonHeld=YES; self.dipDragonSuppressTap=YES;
        card.activeManipulation=gesture;
        self.dipDynamicDragFrame=card.frame;
        self.dipRestoreDeadline=0; [self.dipIcon.layer removeAnimationForKey:@"ZNSDipRestoreFlash"];
    } else if(card.activeManipulation!=gesture) return; // Rotation cancelled this drag.
    CGPoint translation=[gesture translationInView:self.controller.view];
    BOOL cancelled=gesture.state==UIGestureRecognizerStateCancelled || gesture.state==UIGestureRecognizerStateFailed;
    CGRect proposed=cancelled?self.dipDynamicDragFrame:CGRectOffset(self.dipDynamicDragFrame,translation.x,translation.y);
    CGRect safe=[self mainAvailableFrame];
    // Clamp the window to the safe area. Continued downward finger travel
    // compresses the live surface instead of putting its handle under system UI.
    CGFloat progress=cancelled?0:ZNSDipSqueezeProgress(proposed,safe);
    card.parkedSqueezeProgress=progress;
    card.frame=ZNSConstrainIcon(proposed,safe);
    [card setNeedsLayout]; [card layoutIfNeeded]; [self updateDipDynamicIcon];
    if(gesture.state==UIGestureRecognizerStateEnded || cancelled) {
        card.activeManipulation=nil;
        self.dipDragonHeld=NO; self.dipDragonRemaining=5;
        if(!cancelled && progress>0.50) { [self returnExtractedDip]; return; }
        [self scheduleDipDragonHide];
        card.parkedSqueezeProgress=0;
        [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled()?0:0.25 animations:^{ [card setNeedsLayout]; [card layoutIfNeeded]; }];
        [self scheduleArrange];
    }
}
- (void)clearDipTether {
    [self.dipTether removeFromSuperlayer]; self.dipTether=nil; self.dipSnapTarget=nil;
    [self updateDipDynamicIcon];
}
- (void)ejectOldestDipToParking {
    ZNSFloatingView *old=self.dippedOrder.firstObject;
    if(!old) return;
    if(old==self.dipExtractedWindow) [self clearDipExtraction];
    [self clearDipTether]; [self.dippedOrder removeObject:old];
    if(self.dipToolbarOwner==old) self.dipToolbarOwner=nil;
    if(old.closing) return;
    [old cancelInteraction];
    old.dipped=NO; old.dipToolbarHidden=NO; old.toolbar.transform=CGAffineTransformIdentity;
    old.thumbnail=YES; old.docked=NO; old.thumbnailTier=0; old.thumbnailFree=NO;
    old.dockedFromThumbnail=NO; old.wasParkedIcon=NO; old.rotationOverflow=NO;
    old.portraitSaved=NO; old.restoringPosition=NO; old.restoreOnNextArrange=NO;
    old.pendingDeviceOrientation=NO; old.stackOrder=0;
    old.tools.userInteractionEnabled=NO; ++old.toolsGeneration;
    old.expandedFrame=old.dipExpandedFrame;
    [self.parkedOrder removeObject:old]; [self.parkedOrder insertObject:old atIndex:0];
    self.pendingIconRestore=old; self.dipEvictionPacking=YES;
    [old updateContentInputGate]; [old setNeedsLayout]; [old layoutIfNeeded];
    [self scheduleArrange];
}
- (void)layoutDippedWindows:(BOOL)animated {
    [self clearDipTether];
    if(!self.dippedOrder.count) { [self updateDipIcon]; return; }
    if(![self.dippedOrder containsObject:self.dipToolbarOwner]) self.dipToolbarOwner=self.dippedOrder.lastObject;
    NSUInteger index=0,count=self.dippedOrder.count;
    for(ZNSFloatingView *view in [self.dippedOrder copy]) {
        if(view.closing || !view.dipped || view.dipExtracted) { index++; continue; }
        if(view.activeManipulation) [view cancelInteraction];
        CGRect target=[self dipFrameForWindow:view index:index++ count:count];
        CGFloat angle=ZNSDipCardAngle(view.session.landscape);
        view.dipToolbarHidden=self.dipToolbarOwner!=view;
        view.toolbar.transform=CGAffineTransformIdentity;
        view.rebounding=animated;
        [view.layer removeAnimationForKey:@"zns.dipIdleMotion"];
        NSUInteger generation=++view.interactionGeneration;
        [view setNeedsLayout];
        // Complete absorption/bounce first, then raise the left/tool edge.
        [UIView animateWithDuration:(!animated || UIAccessibilityIsReduceMotionEnabled())?0:0.36 delay:0 usingSpringWithDamping:0.74 initialSpringVelocity:0 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{
            view.transform=CGAffineTransformIdentity;
            view.bounds=(CGRect){CGPointZero,target.size};
            view.center=CGPointMake(CGRectGetMidX(target),CGRectGetMidY(target));
            [view layoutIfNeeded];
        } completion:^(BOOL finished){
            (void)finished;
            if(view.closing || !view.dipped || view.interactionGeneration!=generation) return;
            [UIView animateWithDuration:(!animated || UIAccessibilityIsReduceMotionEnabled())?0:0.20 delay:0 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{
                view.transform=CGAffineTransformMakeRotation(angle);
            } completion:^(BOOL tilted){
                (void)tilted;
                if(view.interactionGeneration==generation && view.dipped && !view.closing) {
                    view.rebounding=NO; [view updateContentInputGate]; [view updateDipAppearance];
                    [self updateDipIcon];
                }
            }];
        }];
    }
    [self updateWindowStack];
}
- (BOOL)dipWindow:(ZNSFloatingView *)view {
    if(self.dipExtractedWindow) return NO;
    BOOL fromMovableTier=view.thumbnail && view.thumbnailTier>=1;
    if(!ZNSDipEnabled || !self.enabled || !view.ready || view.closing || view.session.clientProcessExited || view.session.layoutInFlight || view.dipped || (view.thumbnail && !fromMovableTier) || view.docked) return NO;
    BOOL convertToPortrait=view.session.landscape;
    CGRect returnFrame=fromMovableTier?view.expandedFrame:view.gestureFrame;
    if(CGRectIsEmpty(returnFrame)) returnFrame=[view defaultMainFrame];
    if(convertToPortrait) {
        // Dip admission has its own portrait policy, independent of the device
        // follow-rotation switch and the App's previous manual orientation.
        __weak typeof(self) weakSelf=self;
        __weak ZNSFloatingView *weakView=view;
        CGSize canvas=ZNSScreenCanvas(ZNSCanvasSurfaceSize(self.controller.view),NO);
        BOOL accepted=[view.session resize:canvas landscape:NO completion:^(BOOL success,NSString *message) {
            ZNSWindowManager *manager=weakSelf;
            ZNSFloatingView *card=weakView;
            if(!manager || !card || card.closing || ![manager.windows containsObject:card]) return;
            if(!success) {
                os_log_error(ZNSLog(),"dip portrait scene update failed: %{public}@",message);
                // Match the existing scene-rotation failure path: a failed
                // transaction cannot remain presented as a valid live scene.
                if(card.closeAction) card.closeAction(NO);
                return;
            }
            [card cancelInteraction];
            card.pendingDeviceOrientation=NO;
            card.dipExpandedFrame=[card defaultMainFrame];
            card.expandedFrame=card.dipExpandedFrame;
            card.thumbnailTier=MIN(card.thumbnailTier,ZNSThumbnailMaxTier(NO));
            [card attachHost];
            if(card.dipped) [manager layoutDippedWindows:YES];
            else {
                // Capacity eviction may have parked this card during the ack.
                if(card.thumbnail) card.frame=[card thumbnailFrameInSafe:[manager availableFrame]];
                else if(!card.docked) card.frame=card.expandedFrame;
                [manager presentationChanged:card];
            }
            [manager updateOutsideButton]; [manager scheduleArrange];
        }];
        if(!accepted) return NO;
    }
    view.dipSavedToolsExpanded=view.tools.userInteractionEnabled;
    view.dipReturnLandscape=convertToPortrait;
    view.dipReturnFrame=returnFrame;
    view.dipReturnThumbnail=fromMovableTier;
    view.dipReturnTier=view.thumbnailTier;
    view.dipReturnFree=view.thumbnailFree;
    view.dipReturnRight=view.thumbnailRight;
    view.dipReturnParkedFrame=CGRectIsEmpty(view.thumbnailGestureFrame)?view.frame:view.thumbnailGestureFrame;
    if(!self.dippedOrder) self.dippedOrder=[NSMutableArray new];
    NSUInteger capacity=MAX(1,MIN(5,self.maxDippedApps));
    while(self.dippedOrder.count>=capacity) [self ejectOldestDipToParking];
    // Portrait entries retain their main size. Landscape entries get a real
    // portrait canvas and a matching portrait frame, never a stretched preview.
    CGRect expanded=fromMovableTier?view.expandedFrame:view.gestureFrame;
    if(convertToPortrait) expanded=ZNSDefaultMainWindow([self mainAvailableFrame],ZNSCanvasSurfaceSize(self.controller.view),NO);
    if(CGRectIsEmpty(expanded)) expanded=[view defaultMainFrame];
    view.dipExpandedFrame=ZNSFitMainWindow(expanded,[self mainAvailableFrame],0);
    view.expandedFrame=view.dipExpandedFrame;
    view.thumbnail=NO; view.thumbnailFree=NO; view.dockedFromThumbnail=NO;
    view.rotationOverflow=NO; view.portraitSaved=NO; view.restoringPosition=NO;
    view.restoreOnNextArrange=NO; view.wasParkedIcon=NO; view.parkedPan=nil;
    view.dipped=YES; view.pendingDeviceOrientation=NO; view.stackCovered=NO;
    view.tools.userInteractionEnabled=NO; ++view.toolsGeneration;
    [self.parkedOrder removeObject:view]; [self.dippedOrder addObject:view];
    self.dipToolbarOwner=view;
    [self updateDipMotion];
    // Every newly admitted dip becomes the selector's App immediately.
    self.dipIcon.appImage=[view.restoreButton imageForState:UIControlStateNormal];
    for(ZNSFloatingView *parked in self.parkedOrder)
        if(!parked.closing && (parked.parkedPan || parked.activeManipulation)) [parked cancelInteraction];
    if(self.floating==view) self.floating=nil;
    [view stopSqueezeFeedback];
    [view updateContentInputGate]; [view.session setKeyboardFocusActive:NO];
    [self layoutDippedWindows:YES]; [self updateOutsideButton]; [self scheduleArrange];
    ZNSSoftFeedback();
    return YES;
}
- (BOOL)pullDippedWindow:(ZNSFloatingView *)view {
    if(!view.dipped || view.closing || view.rebounding || view.activeManipulation || view.session.layoutInFlight || ![self.dippedOrder containsObject:view]) return NO;
    if(!self.enabled || !ZNSReadAuthorization(YES) || view.session.clientProcessExited) return NO;
    BOOL extracted=view.dipExtracted && self.dipExtractedWindow==view;
    if(extracted) {
        view.dipReturnLandscape=view.session.landscape;
        view.dipReturnThumbnail=NO;
        // Restore a normal, directly interactive main window, not a parked
        // thumbnail whose content is intentionally gated by its tap overlay.
        view.dipReturnFrame=view.thumbnail?[view defaultMainFrame]:view.frame;
    }
    [view.layer removeAnimationForKey:@"zns.dipIdleMotion"];
    if(view.session.landscape!=view.dipReturnLandscape) {
        // The tray may use portrait, but pulling out restores the App's real
        // admission orientation before presenting the main window.
        BOOL landscape=view.dipReturnLandscape;
        __weak typeof(self) weakSelf=self;
        __weak ZNSFloatingView *weakView=view;
        return [view.session resize:ZNSScreenCanvas(ZNSCanvasSurfaceSize(self.controller.view),landscape) landscape:landscape completion:^(BOOL success,NSString *message) {
            ZNSWindowManager *manager=weakSelf;
            ZNSFloatingView *card=weakView;
            if(!manager || !card || card.closing || ![manager.windows containsObject:card]) return;
            if(!success) {
                os_log_error(ZNSLog(),"dip return orientation failed: %{public}@",message);
                if(card.closeAction) card.closeAction(NO);
                return;
            }
            [card attachHost];
            if(!card.dipped || ![manager.dippedOrder containsObject:card]) {
                // Eviction/closing the tray while the scene was updating must
                // not unexpectedly promote that App into the main window.
                [card fitAfterContainerChange]; [manager scheduleArrange];
                return;
            }
            card.pendingDeviceOrientation=NO;
            card.switcherLaunchOrientationPending=NO;
            if(![manager pullDippedWindow:card]) [manager layoutDippedWindows:YES];
        }];
    }
    BOOL restoreParked=view.dipReturnThumbnail;
    if(!restoreParked && ![self activateWindow:view]) return NO; // Only a main-window return parks the current main App.
    ZNSDipIconView *departing=extracted?self.dipDynamicIcon:nil;
    if(extracted) [self clearDipExtraction];
    [self.dippedOrder removeObject:view];
    view.dipped=NO; view.dipToolbarHidden=NO; view.toolbar.transform=CGAffineTransformIdentity;
    view.pendingDeviceOrientation=NO; view.switcherLaunchOrientationPending=NO; view.rebounding=YES;
    CGRect target=ZNSFitMainWindow(view.dipReturnFrame,[self mainAvailableFrame],0);
    if(CGRectIsEmpty(target)) target=[view defaultMainFrame];
    view.expandedFrame=target;
    if(!restoreParked) {
        view.thumbnail=NO; view.thumbnailFree=NO; view.docked=NO;
    }
    if(restoreParked) {
        view.thumbnail=YES; view.docked=NO;
        view.thumbnailTier=MIN(view.dipReturnTier,ZNSThumbnailMaxTier(view.session.landscape));
        view.thumbnailFree=view.thumbnailTier==2 || view.dipReturnFree;
        view.thumbnailRight=view.dipReturnRight;
        view.stackOrder=++self.nextStackOrder;
        [self.parkedOrder removeObject:view]; [self.parkedOrder addObject:view];
        if(self.floating==view) self.floating=nil;
        target=[view thumbnailFrameInSafe:[self availableFrame]];
        if(view.thumbnailFree) {
            CGRect saved=view.dipReturnParkedFrame;
            target.origin=CGPointMake(CGRectGetMidX(saved)-target.size.width/2,CGRectGetMidY(saved)-target.size.height/2);
            target=ZNSConstrainIcon(target,[view parkedMovementArea]);
        }
        [view.session setKeyboardFocusActive:NO];
    }
    ++view.toolsGeneration; view.tools.userInteractionEnabled=extracted && view.dipSavedToolsExpanded;
    if(extracted) {
        [view.content.layer removeAnimationForKey:@"ZNSDipExtractRestoreFade"];
        [UIView performWithoutAnimation:^{ [view updateDipAppearance]; }];
    }
    NSUInteger generation=++view.interactionGeneration;
    [view setNeedsLayout];
    [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled()?0:0.38 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{
        view.transform=CGAffineTransformIdentity;
        view.bounds=(CGRect){CGPointZero,target.size};
        view.center=CGPointMake(CGRectGetMidX(target),CGRectGetMidY(target));
        [view layoutIfNeeded];
    } completion:^(BOOL finished){
        (void)finished;
        if(view.closing || view.dipped || generation!=view.interactionGeneration) return;
        view.rebounding=NO; [view updateContentInputGate]; [view restartBarHints];
        [self updateOutsideButton];
        if(restoreParked) [self scheduleArrange];
    }];
    [self layoutDippedWindows:YES]; [self presentationChanged:view];
    if(departing && self.dipExtractionEnabled && self.dippedOrder.count && self.dipIcon) {
        [self.dipDynamicIcon removeFromSuperview];
        self.dipDynamicIcon=departing;
        self.dipDynamicPan=nil;
        for(UIGestureRecognizer *gesture in departing.gestureRecognizers) gesture.enabled=NO;
        self.dipDragonDeparting=YES;
        [self.controller.view addSubview:departing];
        [self swimDipDragonHome:YES];
    }
    ZNSPromoteRecentApp(view.session);
    return YES;
}
- (void)releaseDippedToParking {
    [self clearDipExtraction];
    [self clearDipTether];
    NSArray<ZNSFloatingView *> *leaving=[self.dippedOrder copy];
    [self.dippedOrder removeAllObjects]; self.dipToolbarOwner=nil;
    for(ZNSFloatingView *view in leaving) {
        if(view.closing || !view.dipped) continue;
        [view cancelInteraction];
        view.dipped=NO; view.dipToolbarHidden=NO; view.toolbar.transform=CGAffineTransformIdentity;
        view.thumbnail=YES; view.docked=NO; view.thumbnailTier=0; view.thumbnailFree=NO;
        view.dockedFromThumbnail=NO; view.wasParkedIcon=NO; view.rotationOverflow=NO;
        view.portraitSaved=NO; view.restoringPosition=NO; view.restoreOnNextArrange=NO;
        view.tools.userInteractionEnabled=NO; ++view.toolsGeneration;
        view.expandedFrame=[view defaultMainFrame];
        [self.parkedOrder removeObject:view]; [self.parkedOrder addObject:view];
        view.frame=[view thumbnailFrameInSafe:[self availableFrame]];
        [view updateContentInputGate]; [view setNeedsLayout];
        if(self.floating==view) self.floating=nil;
    }
    [self updateOutsideButton]; [self scheduleArrange];
}
- (BOOL)canPlaceDipIcon:(CGRect)frame {
    for(ZNSFloatingView *other in self.parkedOrder) {
        if(other.closing || other.hidden || (other.thumbnail && other.thumbnailFree)) continue;
        if(!ZNSParkedPairClear(frame,other.frame,other.docked)) return NO;
    }
    return YES;
}
- (void)updateDipMotion {
    BOOL enabled=!self.dipExtractedWindow && !UIAccessibilityIsReduceMotionEnabled() && self.enabled && self.window && !self.window.hidden;
    for(ZNSFloatingView *card in self.windows) {
        BOOL animate=enabled && card==self.dipToolbarOwner && card.dipped &&
            [self.dippedOrder containsObject:card] && !card.closing && !card.hidden &&
            !card.rebounding && !card.activeManipulation && !card.session.layoutInFlight;
        if(!animate) { [card.layer removeAnimationForKey:@"zns.dipIdleMotion"]; continue; }
        if([card.layer animationForKey:@"zns.dipIdleMotion"]) continue;
        CAKeyframeAnimation *sway=[CAKeyframeAnimation animationWithKeyPath:@"transform.rotation.z"];
        sway.values=@[@0,@(-0.025),@0.025,@(-0.014),@0.008,@0];
        sway.keyTimes=@[@0,@0.18,@0.40,@0.63,@0.82,@1];
        sway.duration=0.9; sway.additive=YES;
        sway.calculationMode=kCAAnimationLinear;
        CGFloat rise=MAX(0,card.bounds.size.height*0.20);
        CAKeyframeAnimation *hop=[CAKeyframeAnimation animationWithKeyPath:@"position.y"];
        hop.values=@[@0,@(-rise),@(-rise),@0];
        hop.keyTimes=@[@0,@0.18,@0.78,@1];
        hop.timingFunctions=@[[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut],
                              [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear],
                              [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];
        hop.duration=0.9; hop.additive=YES;
        CAAnimationGroup *cycle=[CAAnimationGroup animation];
        cycle.animations=@[sway,hop]; cycle.duration=5.0; cycle.repeatCount=HUGE_VALF;
        // Rise by 20% of this card's height during the sway, then return exactly
        // to its model position. The rest of each five-second cycle stays still.
        [card.layer addAnimation:cycle forKey:@"zns.dipIdleMotion"];
    }
}
- (void)dipMotionPreferenceChanged:(NSNotification *)notification {
    (void)notification;
    [self updateDipMotion];
}
- (void)updateDipIcon {
    if(!self.dipToolbarOwner.dipped || self.dipToolbarOwner.closing || ![self.dippedOrder containsObject:self.dipToolbarOwner]) {
        self.dipToolbarOwner=nil;
        for(ZNSFloatingView *card in self.dippedOrder.reverseObjectEnumerator)
            if(card.dipped && !card.closing) { self.dipToolbarOwner=card; break; }
        [self clearDipTether];
    }
    [self updateDipMotion];
    if(!self.dipToolbarOwner || !self.controller || self.window.hidden) {
        [self clearDipExtraction];
        [self clearDipTether];
        [self.dipIcon removeFromSuperview]; self.dipIcon=nil; self.dipIconPan=nil;
        self.dipIconManuallyPlaced=NO;
        return;
    }
    CGRect safe=[self availableFrame];
    if(!self.dipIcon) {
        CGFloat size=MIN(ZNSParkedIconSize(),MIN(safe.size.width,safe.size.height));
        self.dipIcon=[[ZNSDipIconView alloc] initWithFrame:CGRectMake(CGRectGetMinX(safe),CGRectGetMinY(safe),size,size)];
        [self.dipIcon addTarget:self action:@selector(dipIconTapped) forControlEvents:UIControlEventTouchUpInside];
        [self.dipIcon addTarget:self action:@selector(dipTrayPressed:) forControlEvents:UIControlEventTouchDown];
        self.dipIconPan=[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragDipIcon:)];
        self.dipIconPan.maximumNumberOfTouches=1;
        self.dipIconPan.cancelsTouchesInView=YES;
        [self.dipIcon addGestureRecognizer:self.dipIconPan];
        ZNSSetLayerInputOpaque(self.dipIcon.layer,YES);
        [self.controller.view addSubview:self.dipIcon];
    }
    self.dipIcon.appImage=[self.dipToolbarOwner.restoreButton imageForState:UIControlStateNormal];
    self.dipIcon.accessibilityValue=self.dipToolbarOwner.session.bundleIdentifier;
    if(self.dipIconPan.state==UIGestureRecognizerStateBegan || self.dipIconPan.state==UIGestureRecognizerStateChanged) {
        [self updateDipIconTetherSelecting:NO];
        return;
    }
    if(!self.dipIconManuallyPlaced) {
        // The packing pass reserves this first row before placing thumbnails.
        CGFloat size=MIN(ZNSParkedIconSize(),MIN(safe.size.width,safe.size.height));
        self.dipIcon.frame=CGRectMake(CGRectGetMinX(safe),CGRectGetMinY(safe),size,size);
        self.dipIcon.hidden=NO; ZNSSetLayerInputEnabled(self.dipIcon.layer,YES);
        [self updateDipIconTetherSelecting:NO];
        return;
    }
    // Like parked icons: safe-area clamping, no overlap with fixed thumbnails
    // or other icons. Free second/third tiers do not reserve parking cells.
    CGFloat iconSize=MIN(ZNSParkedIconSize(),MIN(safe.size.width,safe.size.height));
    CGRect desired=ZNSConstrainIcon(CGRectMake(self.dipIcon.center.x-iconSize/2,self.dipIcon.center.y-iconSize/2,iconSize,iconSize),safe);
    BOOL placed=[self canPlaceDipIcon:desired];
    if(!placed) {
        NSUInteger capacity=self.parkedOrder.count;
        CGRect *occupied=calloc(MAX(capacity,1),sizeof(CGRect));
        if(occupied) {
            unsigned count=0,thumbnails=0;
            for(ZNSFloatingView *v in self.parkedOrder)
                if(v.thumbnail && !v.thumbnailFree && !v.closing && !v.hidden) occupied[count++]=v.frame;
            thumbnails=count;
            for(ZNSFloatingView *v in self.parkedOrder)
                if(v.docked && !v.closing && !v.hidden) occupied[count++]=v.frame;
            CGRect found=CGRectZero;
            for(NSUInteger attempt=0;attempt<8;attempt++) {
                BOOL right=CGRectGetMidX(desired)>CGRectGetMidX(safe);
                if(ZNSFindIconFrame(desired,safe,occupied,count,thumbnails,right,&found) ||
                   ZNSFindIconFrame(desired,safe,occupied,count,thumbnails,!right,&found)) { placed=YES; break; }
                if(desired.size.width<=16) break;
                desired.size.width=MAX(16,desired.size.width*0.8); desired.size.height=desired.size.width;
            }
            if(placed) desired=found;
            free(occupied);
        }
    }
    // Do not silently overlap another icon if the packing area is exhausted.
    // A bottom fixed thumbnail yields, then the normal packing pass retries.
    self.dipIcon.hidden=!placed;
    ZNSSetLayerInputEnabled(self.dipIcon.layer,placed);
    if(!placed) {
        [self clearDipTether];
        ZNSFloatingView *bottom=[self bottomParkedVictim:self.parkedOrder excluding:self.pendingIconRestore targets:@{}];
        if(bottom) { [self collapseParkedToIcon:bottom]; [self scheduleArrange]; }
        return;
    }
    self.dipIcon.frame=ZNSConstrainIcon(desired,safe);
    [self updateDipIconTetherSelecting:NO];
}
- (CGPoint)dipCorner:(NSInteger)corner ofWindow:(ZNSFloatingView *)view {
    // The outer view includes transparent control gutters. Anchor to the
    // visible content's rounded corner instead, including its rotation/scale.
    UIView *surface=view.content;
    CGRect b=surface.bounds;
    CGFloat radius=MAX(0,MIN(surface.layer.cornerRadius,MIN(b.size.width,b.size.height)*0.5));
    CGFloat inset=radius*(1.0-M_SQRT1_2);
    CGPoint local=CGPointMake((corner&1)?CGRectGetMaxX(b)-inset:CGRectGetMinX(b)+inset,
                              (corner&2)?CGRectGetMaxY(b)-inset:CGRectGetMinY(b)+inset);
    return [surface convertPoint:local toView:self.controller.view];
}
- (void)updateDipIconTetherSelecting:(BOOL)select {
    if(self.dipExtractedWindow) {
        self.dipToolbarOwner=self.dipExtractedWindow;
        self.dipIcon.appImage=[self.dipExtractedWindow.restoreButton imageForState:UIControlStateNormal];
        self.dipIcon.accessibilityValue=self.dipExtractedWindow.session.bundleIdentifier;
        [self clearDipTether]; return;
    }
    if(!self.dipIcon || !self.dipToolbarOwner) { [self clearDipTether]; return; }
    CGPoint point=self.dipIcon.center,anchor=CGPointZero;
    CGFloat best=CGFLOAT_MAX;
    ZNSFloatingView *target=nil; NSInteger corner=0;
    for(ZNSFloatingView *candidate in self.dippedOrder) {
        if(candidate.closing || !candidate.dipped || candidate.rebounding) continue;
        if(!select && candidate!=self.dipToolbarOwner) continue;
        CGPoint a=[self dipCorner:0 ofWindow:candidate];
        CGFloat distance=hypot(point.x-a.x,point.y-a.y);
        if(distance<best) { best=distance; target=candidate; anchor=a; }
    }
    BOOL near=target && best<=CGRectGetWidth(self.dipIcon.bounds)*0.5+88;
    if(near) {
        BOOL changed=self.dipToolbarOwner!=target;
        self.dipSnapTarget=target; self.dipSnapCorner=corner;
        if(select) self.dipToolbarOwner=target;
        self.dipIcon.appImage=[self.dipToolbarOwner.restoreButton imageForState:UIControlStateNormal];
        self.dipIcon.accessibilityValue=self.dipToolbarOwner.session.bundleIdentifier;
        if(changed && select) { [self updateWindowStack]; [self updateDipMotion]; }
        if(!self.dipTether) {
            self.dipTether=[CAShapeLayer layer];
            self.dipTether.strokeColor=UIColor.systemRedColor.CGColor;
            self.dipTether.fillColor=UIColor.clearColor.CGColor;
            self.dipTether.lineWidth=3; self.dipTether.lineCap=kCALineCapRound;
            self.dipTether.zPosition=10000;
            [self.controller.view.layer addSublayer:self.dipTether];
        }
        [self.dipTether removeAnimationForKey:@"ZNSDipTetherFade"];
    } else {
        // Keep the previous App selection when away. Fade the existing line
        // once, rather than restarting its disappearance on every pan update.
        if(!self.dipTether) return;
        if(self.dipSnapTarget.dipped && !self.dipSnapTarget.closing)
            anchor=[self dipCorner:self.dipSnapCorner ofWindow:self.dipSnapTarget];
        else { [self clearDipTether]; return; }
        if(self.dipTether.opacity>0) {
            CABasicAnimation *fade=[CABasicAnimation animationWithKeyPath:@"opacity"];
            fade.fromValue=@1; fade.toValue=@0; fade.duration=UIAccessibilityIsReduceMotionEnabled()?0:0.85;
            fade.timingFunction=[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
            [self.dipTether addAnimation:fade forKey:@"ZNSDipTetherFade"];
        }
    }
    UIBezierPath *path=[UIBezierPath bezierPath];
    CGFloat length=hypot(anchor.x-point.x,anchor.y-point.y);
    CGFloat radius=MIN(length,CGRectGetWidth(self.dipIcon.bounds)*0.5);
    CGPoint start=length>0?CGPointMake(point.x+(anchor.x-point.x)*radius/length,point.y+(anchor.y-point.y)*radius/length):point;
    [path moveToPoint:start]; [path addLineToPoint:anchor];
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    self.dipTether.frame=self.controller.view.bounds; self.dipTether.path=path.CGPath;
    self.dipTether.opacity=near?1:0;
    [CATransaction commit];
    [self updateDipDynamicIcon];
}
- (void)dragDipIcon:(UIPanGestureRecognizer *)gesture {
    if(!self.dipIcon || gesture!=self.dipIconPan) return;
    if(gesture.state==UIGestureRecognizerStateBegan) self.dipIconDragFrame=self.dipIcon.frame;
    CGPoint delta=[gesture translationInView:self.controller.view];
    CGRect proposed=ZNSConstrainIcon(CGRectOffset(self.dipIconDragFrame,delta.x,delta.y),[self availableFrame]);
    BOOL cancelled=gesture.state==UIGestureRecognizerStateCancelled || gesture.state==UIGestureRecognizerStateFailed;
    if(cancelled) proposed=ZNSConstrainIcon(self.dipIconDragFrame,[self availableFrame]);
    if([self canPlaceDipIcon:proposed]) self.dipIcon.frame=proposed;
    [self updateDipIconTetherSelecting:!cancelled];
    if(gesture.state==UIGestureRecognizerStateEnded && !CGRectEqualToRect(self.dipIcon.frame,self.dipIconDragFrame)) {
        self.dipIconManuallyPlaced=YES;
        [self scheduleArrange];
    }
}
- (void)dipIconTapped {
    if(self.dipDragonDeparting) return; // Do not interrupt the five-second exit.
    if(self.dipTrayRecalledOnTouch) { self.dipTrayRecalledOnTouch=NO; return; }
    if(self.dipExtractedWindow) {
        ZNSFloatingView *card=self.dipExtractedWindow;
        if(!self.enabled || !ZNSReadAuthorization(YES) || card.closing || card.rebounding ||
           self.dipDragonHeld || card.activeManipulation || card.session.layoutInFlight) return;
        if(self.dipDragonClock || self.dipDragonStowed) { [self recallDipDragon]; return; }
        if(self.dipRestoreDeadline>CACurrentMediaTime()) {
            if([self pullDippedWindow:card]) ZNSSoftFeedback();
        } else [self beginDipRestoreConfirmation];
        return;
    }
    ZNSFloatingView *view=self.dipToolbarOwner;
    if(!self.enabled || !ZNSReadAuthorization(YES) || !view || !view.dipped || view.closing ||
       view.rebounding || view.activeManipulation || view.session.layoutInFlight ||
       ![self.dippedOrder containsObject:view]) return;
    // The shared tray tool must use the same saved-state restore as card taps
    // and desktop activation. The former shortcut hard-coded second tier and
    // bypassed both admission orientation and tier/position memory.
    if([self pullDippedWindow:view]) ZNSSoftFeedback();
}

+ (instancetype)shared {
    static ZNSWindowManager *manager; static dispatch_once_t once;
    dispatch_once(&once,^{ manager=[self new]; manager.windows=[NSMutableArray new]; manager.parkedOrder=[NSMutableArray new]; manager.iconViews=[NSHashTable weakObjectsHashTable]; manager.enabled=NO; manager.maxParkedApps=8; manager.maxDippedApps=3; manager.iconGesture=@"both"; manager.excluded=[NSSet set];
        [[NSNotificationCenter defaultCenter] addObserver:manager selector:@selector(dipMotionPreferenceChanged:) name:UIAccessibilityReduceMotionStatusDidChangeNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:manager selector:@selector(portraitKeyboardGeometryChanged:) name:ZNSPortraitKeyboardGeometryDidChangeNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:manager selector:@selector(portraitKeyboardWillHideVisual:) name:ZNSPortraitKeyboardWillHideVisualNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:manager selector:@selector(externalKeyboardVisibilityChanged:) name:ZNSExternalKeyboardVisibilityDidChangeNotification object:nil];
    });
    return manager;
}
- (void)emitDiagnostics {
    [ZNSSceneSession emitDiagnostics];
    NSUInteger visible=0,down=0,up=0,detached=0;
    for (UIView *view in self.iconViews) {
        if (view.window) visible++;
        for (ZNSIconSwipeRecognizer *gesture in objc_getAssociatedObject(view,&ZNSIconGesturesKey)) {
            if (gesture.view!=view || ![view.gestureRecognizers containsObject:gesture]) { detached++; continue; }
            if (!gesture.enabled || !view.window) continue;
            if (gesture.direction==UISwipeGestureRecognizerDirectionDown) down++;
            if (gesture.direction==UISwipeGestureRecognizerDirectionUp) up++;
        }
    }
    os_log(ZNSLog(),"ZNS diag detachedGestures=%lu",(unsigned long)detached);
    os_log(ZNSLog(),"ZNS diag prefsReads=%lu enabled=%d direction=%{public}@ attached=%lu inWindow=%lu down=%lu up=%lu candidates=%lu accepted=%lu recognized=%lu floating=%d",(unsigned long)ZNSPreferenceReads,self.enabled,self.iconGesture,(unsigned long)self.iconViews.count,(unsigned long)visible,(unsigned long)down,(unsigned long)up,(unsigned long)ZNSTouchCandidates,(unsigned long)ZNSTouchAccepted,(unsigned long)ZNSRecognizedSwipes,self.floating!=nil);
}
- (void)reloadPreferences {
    ZNSPreferenceReads++;
    BOOL preferencesReady=CFPreferencesAppSynchronize(CFSTR(APELIN_PACKAGE_ID));
    BOOL authorized=preferencesReady && ZNSReadAuthorization(NO);
    if(!authorized) ZNSDisableFeatureSwitches();
    id enabled=CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("Enabled"),CFSTR(APELIN_PACKAGE_ID)));
    id direction=CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("IconGesture"),CFSTR(APELIN_PACKAGE_ID)));
    id excluded=CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("ExcludedApps"),CFSTR(APELIN_PACKAGE_ID)));
    id limit=CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("MaxParkedApps"),CFSTR(APELIN_PACKAGE_ID)));
    id follow=CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("FollowDeviceRotation"),CFSTR(APELIN_PACKAGE_ID)));
    id showBars=CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("ShowWindowBars"),CFSTR(APELIN_PACKAGE_ID)));
    ZNSShowWindowBars=[showBars respondsToSelector:@selector(boolValue)]?[showBars boolValue]:YES;
    id dip=CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("DipEnabled"),CFSTR(APELIN_PACKAGE_ID)));
    id dynamicDip=CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("DynamicDipEnabled"),CFSTR(APELIN_PACKAGE_ID)));
    self.dipExtractionEnabled=authorized && ([dynamicDip respondsToSelector:@selector(boolValue)]?[dynamicDip boolValue]:YES);
    id dipLimit=CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("MaxDippedApps"),CFSTR(APELIN_PACKAGE_ID)));
    id keyboardClose=CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("KeyboardDismissClosesWindow"),CFSTR(APELIN_PACKAGE_ID)));
    id keyboardCloseOrientation=CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("KeyboardDismissCloseOrientation"),CFSTR(APELIN_PACKAGE_ID)));
    self.keyboardDismissClosesWindow=[keyboardClose respondsToSelector:@selector(boolValue)] && [keyboardClose boolValue];
    self.keyboardDismissCloseOrientation=[@[@"portrait",@"landscape",@"both"] containsObject:keyboardCloseOrientation]?keyboardCloseOrientation:@"both";
    self.maxDippedApps=[dipLimit respondsToSelector:@selector(integerValue)]?MAX(1,MIN(5,[dipLimit integerValue])):3;
    ZNSDipEnabled=authorized && ([dip respondsToSelector:@selector(boolValue)]?[dip boolValue]:YES);
    if(!ZNSDipEnabled && self.dippedOrder.count) [self releaseDippedToParking];
    else if(self.dippedOrder.count>self.maxDippedApps) {
        while(self.dippedOrder.count>self.maxDippedApps) [self ejectOldestDipToParking];
        [self layoutDippedWindows:YES];
    }
    ZNSFollowDeviceRotation=[follow respondsToSelector:@selector(boolValue)]?[follow boolValue]:NO;
    if(!ZNSFollowDeviceRotation) for(ZNSFloatingView *view in self.windows) view.pendingDeviceOrientation=NO;
    self.maxParkedApps=[limit respondsToSelector:@selector(integerValue)]?MAX(3,MIN(8,[limit integerValue])):8;
    self.enabled=authorized && ([enabled respondsToSelector:@selector(boolValue)]?[enabled boolValue]:NO);
    self.iconGesture=[@[@"up",@"down",@"both"] containsObject:direction]?direction:@"both";
    NSMutableSet *set=[NSMutableSet setWithObjects:@"com.apple.springboard",@"com.apple.PreBoard",@"com.apple.Setup",nil];
    if ([excluded isKindOfClass:NSString.class]) {
        NSCharacterSet *separators=[NSCharacterSet characterSetWithCharactersInString:@",，;；\n \t"];
        for (NSString *item in [excluded componentsSeparatedByCharactersInSet:separators]) if (item.length) [set addObject:item];
    }
    self.excluded=set;
    for (UIView *view in self.iconViews) [self configureGestures:view];
    for (ZNSFloatingView *view in self.windows) {
        [view.session reloadKeyboardPreference];
        [view setNeedsLayout];
    }
    if (!authorized) [self closeForLock]; // Immediately release all hosts, including closing/connecting ones.
    else if (!self.enabled) [self close:NO];
    else for (ZNSFloatingView *view in [self.windows copy])
        if ([set containsObject:view.session.bundleIdentifier]) [self closeWindow:view fullscreen:NO];
    if(!self.dipExtractionEnabled) [self disableDipExtractionWhenReady];
    else [self updateDipDynamicIcon];
    [self scheduleArrange];
    os_log(ZNSLog(),"preferences reloaded enabled=%d direction=%{public}@ maxParked=%lu",self.enabled,self.iconGesture,(unsigned long)self.maxParkedApps);
}
- (NSString *)bundleForIcon:(UIView *)view {
    id icon=ZNSGet(view,@"icon");
    id bundle=ZNSGet(icon,@"applicationBundleID");
    if ([bundle isKindOfClass:NSString.class] && [bundle length]>0) return bundle;
    bundle=ZNSGet(view,@"applicationBundleIdentifierForShortcuts");
    return [bundle isKindOfClass:NSString.class] && [bundle length]>0?bundle:nil;
}
- (void)configureGestures:(UIView *)view {
    NSArray *gestures=objc_getAssociatedObject(view,&ZNSIconGesturesKey);
    for (ZNSIconSwipeRecognizer *gesture in gestures) {
        BOOL match=[self.iconGesture isEqualToString:@"both"] || (gesture.direction==UISwipeGestureRecognizerDirectionUp ? [self.iconGesture isEqualToString:@"up"] : [self.iconGesture isEqualToString:@"down"]);
        if (gesture.enabled!=(self.enabled && match)) gesture.enabled=self.enabled && match;
    }
}
- (void)attachGesturesToIconView:(UIView *)view {
    if(!NSThread.isMainThread || !view.window) return;
    Class iconClass=NSClassFromString(@"SBIconView");
    if(!iconClass || ![view isKindOfClass:iconClass]) return;
    if (!objc_getAssociatedObject(view,&ZNSIconGesturesKey)) {
        NSMutableArray *gestures=[NSMutableArray new];
        for (NSNumber *direction in @[@(UISwipeGestureRecognizerDirectionUp),@(UISwipeGestureRecognizerDirectionDown)]) {
            ZNSIconSwipeRecognizer *gesture=[[ZNSIconSwipeRecognizer alloc] initWithTarget:self action:@selector(iconSwiped:)];
            gesture.direction=direction.unsignedIntegerValue; gesture.delegate=self; gesture.cancelsTouchesInView=YES;
            gesture.numberOfTouchesRequired=1;
            gesture.delaysTouchesBegan=NO; gesture.delaysTouchesEnded=NO;
            [view addGestureRecognizer:gesture]; [gestures addObject:gesture];
        }
        objc_setAssociatedObject(view,&ZNSIconGesturesKey,gestures,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self.iconViews addObject:view];
        os_log(ZNSLog(),"native icon swipe attached receiver=%{public}@",NSStringFromClass(view.class));
    }
    for (UIGestureRecognizer *gesture in objc_getAssociatedObject(view,&ZNSIconGesturesKey)) {
        if (gesture.view!=view || ![view.gestureRecognizers containsObject:gesture]) {
            [view addGestureRecognizer:gesture];
            os_log(ZNSLog(),"restored detached icon gesture");
        }
    }
    [self configureGestures:view];
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    if(![recognizer isKindOfClass:ZNSIconSwipeRecognizer.class]) return YES;
    ZNSIconSwipeRecognizer *swipe=(ZNSIconSwipeRecognizer *)recognizer;
    UIView *icon=recognizer.view;
    Class iconClass=NSClassFromString(@"SBIconView");
    if (!iconClass || ![icon isKindOfClass:iconClass] || !touch.view ||
        (touch.view!=icon && ![touch.view isDescendantOfView:icon])) icon=nil;
    NSString *bundle=icon?[self bundleForIcon:icon]:nil;
    BOOL hasBundle=bundle.length>0;
    BOOL excluded=hasBundle && [self.excluded containsObject:bundle];
    BOOL editing=icon && ZNSBool(icon,@"isEditing");
    BOOL locked=ZNSBool(ZNSShared(@"SBLockScreenManager"),@"isUILocked");
    BOOL allowed=self.enabled && hasBundle && !excluded && !editing && !locked;
    swipe.sourceIconView=allowed?icon:nil;
    swipe.sourceBundleIdentifier=allowed?bundle:nil;
    ZNSTouchCandidates++; if (allowed) ZNSTouchAccepted++;
    os_log(ZNSLog(),"ZNS icon candidate allowed=%d enabled=%d hasBundle=%d excluded=%d editing=%d locked=%d",allowed,self.enabled,hasBundle,excluded,editing,locked);
    return allowed;
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    os_log(ZNSLog(),"ZNS icon recognizer shouldBegin state=%ld attached=%d",(long)recognizer.state,recognizer.view!=nil);
    return YES;
}
- (BOOL)openDesktopBundleIdentifier:(NSString *)bundle {
    // The desktop needs no hidden switcher preparation. Use the normal visible
    // window path: it shows the actual scene failure instead of silently
    // cancelling before a window exists, and reuses an already hosted App.
    [self.desktopPreparation cancel]; self.desktopPreparation=nil;
    return [self openBundleIdentifier:bundle];
}
- (void)iconSwiped:(ZNSIconSwipeRecognizer *)gesture {
    if (gesture.state!=UIGestureRecognizerStateRecognized) return;
    UIView *icon=gesture.sourceIconView;
    NSString *bundle=gesture.sourceBundleIdentifier;
    if(!self.enabled || !icon.window || !bundle.length || [self.excluded containsObject:bundle] ||
       ![[self bundleForIcon:icon] isEqualToString:bundle] || ZNSBool(icon,@"isEditing") ||
       ZNSBool(ZNSShared(@"SBLockScreenManager"),@"isUILocked")) return;
    if(icon!=gesture.view && ![icon isDescendantOfView:gesture.view]) return;
    ZNSRecognizedSwipes++;
    os_log(ZNSLog(),"ZNS icon recognized direction=%lu receiver=%{public}@",(unsigned long)gesture.direction,NSStringFromClass(gesture.view.class));
    BOOL accepted=[self openDesktopBundleIdentifier:bundle];
    os_log(ZNSLog(),"ZNS icon activation accepted=%d; scene readiness pending",accepted);
}
- (BOOL)handleDesktopIconTap:(UIView *)iconView {
    if (!NSThread.isMainThread || !self.enabled || !ZNSReadAuthorization(YES)) return NO;
    if (ZNSBool(ZNSShared(@"SBLockScreenManager"),@"isUILocked") || ZNSBool(iconView,@"isEditing")) return NO;
    NSString *bundle=[self bundleForIcon:iconView];
    if (!bundle.length || [self.excluded containsObject:bundle]) return NO;
    BOOL managed=NO;
    for (ZNSFloatingView *view in self.windows)
        if ([view.session.bundleIdentifier isEqualToString:bundle]) { managed=YES; break; }
    if (!managed) return NO; // Ordinary icons retain the system's full-screen launch.
    BOOL restored=[self openDesktopBundleIdentifier:bundle];
    // A connecting/rotating/closing window must not fall through and launch the
    // same scene full-screen. A busy tap is consumed; the user can retry it.
    os_log(ZNSLog(),"desktop managed icon tap consumed restored=%d",restored);
    return YES;
}
- (BOOL)currentDeviceLandscape {
    UIWindowScene *scene=self.window.windowScene;
    if(!scene) {
        id mainScene=ZNSGet(ZNSShared(@"SBMainWorkspace"),@"mainWindowScene");
        if([mainScene isKindOfClass:UIWindowScene.class] && [(UIWindowScene *)mainScene screen]==UIScreen.mainScreen) scene=mainScene;
    }
    if(!scene) for(UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
        if([candidate isKindOfClass:UIWindowScene.class] && [(UIWindowScene *)candidate screen]==UIScreen.mainScreen && candidate.activationState==UISceneActivationStateForegroundActive) {
            scene=(UIWindowScene *)candidate; break;
        }
    }
    if(scene.interfaceOrientation!=UIInterfaceOrientationUnknown)
        return UIInterfaceOrientationIsLandscape(scene.interfaceOrientation);
    CGSize size=ZNSCanvasSurfaceSize(self.controller.view);
    return size.width>size.height;
}
- (BOOL)canOpenNotificationBundleIdentifier:(NSString *)bundle mode:(NSString *)mode {
    if(![@[@"main",@"parked",@"parked2",@"dip"] containsObject:mode] || ![self canOpenBundleIdentifier:bundle]) return NO;
    if([mode isEqualToString:@"dip"] && (!ZNSDipEnabled || self.dipExtractedWindow)) return NO;
    for(ZNSFloatingView *view in self.windows) {
        if(![view.session.bundleIdentifier isEqualToString:bundle]) continue;
        if(!view.ready || view.connecting || view.closing || view.rebounding || view.activeManipulation ||
           view.parkedPan || view.dismissing || view.session.layoutInFlight || view.session.clientProcessExited) return NO;
    }
    if([mode isEqualToString:@"main"] && self.floating &&
       (self.floating.closing || self.floating.connecting || self.floating.rebounding ||
        self.floating.activeManipulation || self.floating.dismissing || self.floating.session.layoutInFlight)) return NO;
    return YES;
}
- (ZNSWindowActivation *)prepareNotificationBundleIdentifier:(NSString *)bundle mode:(NSString *)mode whenReady:(void (^)(BOOL))completion {
    if(![self canOpenNotificationBundleIdentifier:bundle mode:mode]) return nil;
    ZNSWindowActivation *request=[self prepareBundleIdentifier:bundle switcherLaunch:NO whenReady:completion];
    request.notificationMode=mode;
    return request;
}
- (BOOL)presentNotificationWindow:(ZNSFloatingView *)view mode:(NSString *)mode {
    if(!view || ![self canOpenNotificationBundleIdentifier:view.session.bundleIdentifier mode:mode]) return NO;
    if([mode isEqualToString:@"main"]) return YES;
    if([mode isEqualToString:@"dip"] && view.dipped) {
        self.dipToolbarOwner=view; [self layoutDippedWindows:NO]; return YES;
    }
    CGRect expanded=view.dipped?view.dipExpandedFrame:((view.thumbnail || view.docked)?view.expandedFrame:view.frame);
    if(view==self.dipExtractedWindow) [self clearDipExtraction];
    [view cancelInteraction];
    [self.dippedOrder removeObject:view];
    if(self.dipToolbarOwner==view) self.dipToolbarOwner=nil;
    view.dipped=NO; view.dipToolbarHidden=NO; view.toolbar.transform=CGAffineTransformIdentity;
    view.transform=CGAffineTransformIdentity;
    view.docked=NO; view.thumbnail=NO; view.thumbnailFree=NO; view.thumbnailTier=0;
    view.dockedFromThumbnail=NO; view.wasParkedIcon=NO; view.rotationOverflow=NO;
    view.portraitSaved=NO; view.restoringPosition=NO; view.restoreOnNextArrange=NO;
    view.pendingDeviceOrientation=NO; view.stackCovered=NO; view.stackOrder=0;
    view.tools.userInteractionEnabled=NO; ++view.toolsGeneration;
    view.expandedFrame=ZNSFitMainWindow(expanded,[self mainAvailableFrame],0);
    view.frame=view.expandedFrame; view.gestureFrame=view.expandedFrame;
    [self.parkedOrder removeObject:view];
    if([mode isEqualToString:@"dip"]) {
        // Only this notification route forces the oldest expelled card left.
        NSUInteger capacity=MAX(1,MIN(5,self.maxDippedApps));
        while(self.dippedOrder.count>=capacity) {
            self.dippedOrder.firstObject.thumbnailRight=NO;
            [self ejectOldestDipToParking];
        }
        return [self dipWindow:view];
    }
    view.thumbnail=YES;
    // Tier indices are zero-based. New second-tier windows enter normal
    // parking order; dragging later opts into the existing free-move policy.
    view.thumbnailTier=[mode isEqualToString:@"parked2"]?1:0;
    if(self.floating==view) self.floating=nil;
    [self.parkedOrder addObject:view];
    [view.session setKeyboardFocusActive:NO]; [view updateContentInputGate];
    [view setNeedsLayout];
    [self layoutDippedWindows:YES]; [self updateOutsideButton]; [self scheduleArrange];
    return YES;
}
- (ZNSWindowActivation *)prepareSwitcherBundleIdentifier:(NSString *)bundle whenReady:(void (^)(BOOL))completion {
    return [self prepareBundleIdentifier:bundle switcherLaunch:YES whenReady:completion];
}
- (ZNSWindowActivation *)prepareBundleIdentifier:(NSString *)bundle switcherLaunch:(BOOL)switcherLaunch whenReady:(void (^)(BOOL))completion {
    if (![self canOpenBundleIdentifier:bundle]) return nil;
    [self.switcherPreparation cancel]; self.switcherPreparation=nil;
    ZNSFloatingView *existing=nil;
    for (ZNSFloatingView *candidate in self.windows) {
        if (![candidate.session.bundleIdentifier isEqualToString:bundle]) continue;
        if (!candidate.ready || candidate.connecting || candidate.closing || candidate.session.layoutInFlight) return nil;
        existing=candidate; break;
    }
    ZNSWindowActivation *request=[ZNSWindowActivation new];
    self.switcherPreparation=request;
    __weak typeof(self) weakSelf=self;
    __weak ZNSWindowActivation *weakRequest=request;
    __weak ZNSFloatingView *weakExisting=existing;
    BOOL restoring=existing!=nil;
    ZNSSceneSession *prepared=restoring?nil:[[ZNSSceneSession alloc] initWithBundleIdentifier:bundle];
    request.cancelAction=^{
        ZNSWindowManager *manager=weakSelf;
        if(manager.deviceLockClosing) [prepared prepareForDeviceLock];
        [prepared stopForFullscreen:NO];
        if (manager.switcherPreparation==weakRequest) manager.switcherPreparation=nil;
    };
    request.commitAction=^BOOL{
        ZNSWindowManager *manager=weakSelf;
        ZNSWindowActivation *current=weakRequest;
        if (!manager || !current || manager.switcherPreparation!=current || ![manager canOpenBundleIdentifier:bundle]) return NO;
        if(current.notificationMode && ![manager canOpenNotificationBundleIdentifier:bundle mode:current.notificationMode]) return NO;
        if (restoring) {
            ZNSFloatingView *view=weakExisting;
            if (!view || ![manager.windows containsObject:view] || !view.ready || view.closing || view.connecting || view.session.layoutInFlight) return NO;
        } else {
            // Another entry point must never steal the prepared scene's lease.
            for (ZNSFloatingView *view in manager.windows)
                if ([view.session.bundleIdentifier isEqualToString:bundle]) return NO;
            if (!prepared.hostView || prepared.layoutInFlight) return NO;
            if (!CGSizeEqualToSize(prepared.canvasSize,ZNSScreenCanvas(ZNSCanvasSurfaceSize(manager.controller.view),prepared.landscape))) return NO;
        }
        manager.switcherPreparation=nil;
        manager.preparedSwitcherSession=prepared;
        manager.notificationOpeningMode=current.notificationMode;
        BOOL accepted=NO;
        @try { accepted=[manager openBundleIdentifier:bundle]; }
        @finally { manager.preparedSwitcherSession=nil; manager.notificationOpeningMode=nil; }
        BOOL launchLandscape=switcherLaunch && [manager currentDeviceLandscape];
        if(accepted && (ZNSFollowDeviceRotation || launchLandscape) && !current.notificationMode) {
            // One-shot card activation also aligns restored windows, independently
            // of the continuous follow-device preference and without a manual override.
            ZNSFloatingView *view=manager.floating;
            view.switcherLaunchOrientationPending=launchLandscape;
            view.deviceLandscapeTarget=[manager currentDeviceLandscape];
            view.pendingDeviceOrientation=YES;
            [view applyPendingDeviceOrientation];
        }
        return accepted;
    };
    void (^report)(BOOL)=^(BOOL success){
        dispatch_async(dispatch_get_main_queue(),^{
            ZNSWindowActivation *current=weakRequest;
            if (!current || current.finished) return;
            current.ready=success;
            if (completion) completion(success);
            if (!success) [current cancel];
        });
    };
    prepared.processDidExit=^{
        ZNSWindowActivation *current=weakRequest;
        if(!current || current.finished) return;
        current.ready=NO;
        if(completion) completion(NO);
        [current cancel];
    };
    if (restoring) report(YES);
    else [prepared startWithSize:ZNSScreenCanvas(ZNSCanvasSurfaceSize(self.controller.view),NO) completion:^(BOOL success,NSString *message){
        (void)message;
        ZNSWindowActivation *current=weakRequest;
        ZNSWindowManager *manager=weakSelf;
        if(!current || current.finished || !manager) return;
        BOOL landscape=(switcherLaunch || ZNSFollowDeviceRotation) && [manager currentDeviceLandscape];
        if(!success || !landscape) { report(success); return; }
        // Preparation completes only after the same real scene resize used by
        // toolbar rotation, so the first visible switcher window is landscape.
        BOOL accepted=[prepared resize:ZNSScreenCanvas(ZNSCanvasSurfaceSize(manager.controller.view),YES) landscape:YES completion:^(BOOL rotated,NSString *rotationMessage){
            (void)rotationMessage; report(rotated);
        }];
        if(!accepted) report(NO);
    }];
    return request;
}
- (BOOL)openBundleIdentifier:(NSString *)bundle whenReady:(void (^)(BOOL ready))completion {
    if (![self openBundleIdentifier:bundle]) return NO;
    ZNSFloatingView *view=nil;
    for (ZNSFloatingView *candidate in self.windows)
        if ([candidate.session.bundleIdentifier isEqualToString:bundle] && !candidate.closing) { view=candidate; break; }
    if (!view) return NO;
    if (view.connecting) {
        __weak typeof(self) weakSelf=self;
        __weak ZNSFloatingView *weakView=view;
        view.activationReadyCompletion=^(BOOL ready) {
            ZNSFloatingView *current=weakView;
            BOOL valid=ready && current && !current.closing &&
                !current.docked &&
                [weakSelf.windows containsObject:current];
            if (completion) completion(valid);
        };
    } else if (completion) completion(view.ready && !view.closing);
    return YES;
}
- (BOOL)canOpenBundleIdentifier:(NSString *)bundle {
    if (!NSThread.isMainThread) return NO;
    if (!ZNSReadAuthorization(YES)) { [self reloadPreferences]; return NO; }
    if (!self.enabled || ![bundle isKindOfClass:NSString.class] || !bundle.length || [self.excluded containsObject:bundle]) return NO;
    return !ZNSBool(ZNSShared(@"SBLockScreenManager"),@"isUILocked");
}
- (BOOL)openBundleIdentifier:(NSString *)bundle {
    if (!NSThread.isMainThread) return NO;
    [self.switcherPreparation cancel]; self.switcherPreparation=nil;
    if (![self canOpenBundleIdentifier:bundle]) return NO;
    BOOL notificationParked=self.notificationOpeningMode && [@[@"parked",@"parked2",@"dip"] containsObject:self.notificationOpeningMode];
    for (ZNSFloatingView *existing in [self.windows copy]) {
        if (![existing.session.bundleIdentifier isEqualToString:bundle]) continue;
        if (existing.closing || existing.connecting || existing.session.layoutInFlight) return NO;
        if (existing.ready) {
            if(notificationParked) {
                BOOL accepted=[self presentNotificationWindow:existing mode:self.notificationOpeningMode];
                if(accepted) ZNSPromoteRecentApp(existing.session);
                return accepted;
            }
            if(existing.dipped) return [self pullDippedWindow:existing];
            if (![self activateWindow:existing]) return NO;
            existing.dockedFromThumbnail=NO;
            [existing restore];
            [self presentationChanged:existing];
            ZNSPromoteRecentApp(existing.session);
            return YES;
        }
        [self finishCloseWindow:existing fullscreen:NO];
    }
    if(!notificationParked) {
        if (self.floating.closing || self.floating.activeManipulation || self.floating.dismissing || self.floating.rebounding || self.floating.connecting || self.floating.session.layoutInFlight) return NO;
        if (self.floating.ready) { if(![self.floating parkLiveThumbnail]) return NO; }
        else if (self.floating) [self closeWindow:self.floating fullscreen:NO];
    }
    __weak typeof(self) weakSelf=self;
    if (!self.window) {
    self.controller=[ZNSRootController new];
    id workspace=ZNSShared(@"SBMainWorkspace");
    id scene=ZNSGet(workspace,@"mainWindowScene");
    if (![scene isKindOfClass:UIWindowScene.class] || [(UIWindowScene *)scene screen]!=UIScreen.mainScreen) {
        scene=nil;
        for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes)
            if ([candidate isKindOfClass:UIWindowScene.class] && [(UIWindowScene *)candidate screen]==UIScreen.mainScreen &&
                candidate.activationState==UISceneActivationStateForegroundActive) { scene=candidate; break; }
    }
    self.window=[scene isKindOfClass:UIWindowScene.class]?[[ZNSOverlayWindow alloc] initWithWindowScene:scene]:[[ZNSOverlayWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.frame=[scene isKindOfClass:UIWindowScene.class]?[(UIWindowScene *)scene coordinateSpace].bounds:UIScreen.mainScreen.bounds; self.window.windowLevel=UIWindowLevelNormal+20;
    self.window.backgroundColor=UIColor.clearColor; self.window.rootViewController=self.controller;
    self.controller.geometryChanged=^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ZNSDesktopVisibilityChanged" object:nil];
        // Rotation keeps dipped cards in the bottom tray; relayout below uses
        // the current device bounds rather than converting them to parked Apps.
        CGRect available=[weakSelf availableFrame],mainAvailable=[weakSelf mainAvailableFrame];
        if(CGRectEqualToRect(available,weakSelf.lastAvailableFrame) && CGRectEqualToRect(mainAvailable,weakSelf.lastMainAvailableFrame)) return;
        BOOL mainGeometryChanged=!CGRectEqualToRect(mainAvailable,weakSelf.lastMainAvailableFrame);
        weakSelf.lastAvailableFrame=available; weakSelf.lastMainAvailableFrame=mainAvailable;
        for (ZNSFloatingView *view in [weakSelf.windows copy]) [view fitAfterContainerChange];
        if(mainGeometryChanged) [weakSelf layoutDippedWindows:NO];
        weakSelf.outsideButton.frame=weakSelf.controller.view.bounds;
        [weakSelf scheduleArrange];
    };
    self.window.hidden=NO;
    [self.controller.view layoutIfNeeded];
    self.outsideButton=[UIButton buttonWithType:UIButtonTypeCustom];
    self.outsideButton.frame=self.controller.view.bounds;
    self.outsideButton.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    self.outsideButton.accessibilityLabel=@"收起为实时缩略窗";
    self.outsideButton.accessibilityIdentifier=@"ZNSOutsidePark";
    self.outsideButton.hidden=YES;
    // Transparent UIKit views can be skipped by the render-server hit test
    // when a different app owns the foreground scene. Claim only this local
    // control's region; the floating scene remains above it and interactive.
    BOOL outsideShield=ZNSSetLayerInputOpaque(self.outsideButton.layer,YES);
    os_log(ZNSLog(),"outside park input shield configured=%d",outsideShield);
    [self.outsideButton addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(outsideTapped:)]];
    [self.controller.view addSubview:self.outsideButton];
    }
    CGRect safe=[self availableFrame];
    CGRect frame=ZNSInitialCanvasWindow(safe,ZNSCanvasSurfaceSize(self.controller.view));
    // This reads the icon image only, never a screenshot of app content.
    UIImage *image=nil;
    SEL iconSelector=NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if (!image && [UIImage respondsToSelector:iconSelector]) {
        @try { image=((id(*)(id,SEL,id,NSInteger,CGFloat))objc_msgSend)(UIImage.class,iconSelector,bundle,0,UIScreen.mainScreen.scale); }
        @catch (NSException *exception) { os_log_error(ZNSLog(),"icon unavailable: %{public}@",exception.name); }
    }
    ZNSFloatingView *view=[[ZNSFloatingView alloc] initWithFrame:frame bundle:bundle icon:image];
    BOOL prepared=[self.preparedSwitcherSession.bundleIdentifier isEqualToString:bundle] && self.preparedSwitcherSession.hostView!=nil;
    if (prepared) view.session=self.preparedSwitcherSession;
    __weak ZNSFloatingView *weakView=view;
    __weak ZNSSceneSession *weakSession=view.session;
    view.session.processDidExit=^{
        ZNSFloatingView *exitedView=weakView;
        ZNSWindowManager *manager=weakSelf;
        if(!manager || !exitedView || exitedView.session!=weakSession ||
           ![manager.windows containsObject:exitedView]) return;
        // A terminated client cannot leave any live-shaped black container,
        // including parked tiers, icons, the main window or a connecting view.
        [exitedView cancelInteraction];
        [manager finishCloseWindow:exitedView fullscreen:NO];
    };
    if(!notificationParked) self.floating=view;
    [self.windows addObject:view];
    view.safeBounds=^{ return [weakSelf availableFrame]; };
    view.mainSafeBounds=^{ return [weakSelf mainAvailableFrame]; };
    view.parkedMovementBounds=^{ return [weakSelf parkedMovementFrame]; };
    view.dipDockBounds=^{ return weakSelf?[weakSelf desktopDockFrame]:CGRectNull; };
    view.tryDip=^BOOL{ return [weakSelf dipWindow:weakView]; };
    view.pullDip=^BOOL{ return [weakSelf pullDippedWindow:weakView]; };
    view.closeAction=^(BOOL fullscreen){ [weakSelf closeWindow:weakView fullscreen:fullscreen]; };
    view.willActivate=^{ return [weakSelf activateWindow:weakView]; };
    view.presentationChanged=^{ [weakSelf presentationChanged:weakView]; };
    view.requestFront=^{ [weakSelf raiseWindow:weakView]; };
    view.canOccupy=^BOOL(CGRect frame) {
        if(weakSelf.dipIcon && !weakSelf.dipIcon.hidden &&
           !ZNSParkedPairClear(frame,weakSelf.dipIcon.frame,weakView.docked)) return NO;
        for (ZNSFloatingView *other in weakSelf.parkedOrder) {
            if (other==weakView || other.closing || other.hidden || (other.thumbnail && other.thumbnailFree)) continue;
            if (!ZNSParkedPairClear(frame,other.frame,weakView.docked==other.docked)) return NO;
        }
        return YES;
    };
    [self.controller.view addSubview:view];
    [view fitAfterContainerChange];
    if (prepared) {
        view.connecting=NO; view.ready=YES; self.preparedSwitcherSession=nil;
        view.message.hidden=YES;
        [view attachHost];
        if(notificationParked) {
            if(![self presentNotificationWindow:view mode:self.notificationOpeningMode]) {
                [self finishCloseWindow:view fullscreen:NO]; return NO;
            }
        } else [self presentationChanged:view];
        ZNSPromoteRecentApp(view.session);
    } else [view start];
    [self arrangeParked];
    if(!notificationParked) [self animateOpening:view];
    os_log(ZNSLog(),"floating scene request accepted");
    return YES;
}
- (void)raiseWindow:(ZNSFloatingView *)view {
    if(!view || !view.isStackParticipant || ![self.windows containsObject:view]) return;
    view.stackOrder=++self.nextStackOrder;
    [self updateWindowStack];
}
- (void)updateWindowStack {
    UIView *root=self.controller.view;
    // The selected dip card leads its siblings; its selector is independent.
    for(ZNSFloatingView *card in self.dippedOrder)
        if(!card.closing && card.dipped && card!=self.dipToolbarOwner) [root bringSubviewToFront:card];
    if(self.dipToolbarOwner.dipped && !self.dipToolbarOwner.closing) [root bringSubviewToFront:self.dipToolbarOwner];
    // Lower tiers/icons retain packing order below the independently movable layer.
    for(ZNSFloatingView *view in self.parkedOrder)
        if(!view.closing && !view.isStackParticipant) [root bringSubviewToFront:view];
    if(self.dipIcon.superview==root) [root bringSubviewToFront:self.dipIcon];
    NSArray<ZNSFloatingView *> *ordered=[self.windows sortedArrayUsingComparator:^NSComparisonResult(ZNSFloatingView *a,ZNSFloatingView *b) {
        if(a.stackOrder==b.stackOrder) return NSOrderedSame;
        return a.stackOrder<b.stackOrder?NSOrderedAscending:NSOrderedDescending;
    }];
    ZNSFloatingView *front=nil;
    for(ZNSFloatingView *view in ordered) {
        if(view.isStackParticipant) { [root bringSubviewToFront:view]; front=view; }
    }
    // Remote content bypasses the local touch observer. Only the rear main
    // needs a selection surface; free thumbnails already own their touches.
    for(ZNSFloatingView *view in self.windows)
        view.stackCovered=view.isStackParticipant && front!=view;
    [self refreshKeyboardDismissShield];
    // The extracted surface is a non-interactive overlay; both independent
    // controls must remain reachable above it and any newly raised main window.
    if(self.dipExtractedWindow.superview==root && !self.dipExtractedWindow.closing)
        [root bringSubviewToFront:self.dipExtractedWindow];
    if(self.dipExtractedWindow && self.dipIcon.superview==root) [root bringSubviewToFront:self.dipIcon];
    [self updateDipDynamicIcon];
}
- (void)presentationChanged:(ZNSFloatingView *)view {
    if (!view || ![self.windows containsObject:view]) return;
    if(view.dipped) {
        [self.parkedOrder removeObject:view];
        if(self.floating==view) self.floating=nil;
        [self updateOutsideButton]; [self scheduleArrange]; return;
    }
    if(!view.isStackParticipant) view.stackOrder=0;
    else if(!view.stackOrder) [self raiseWindow:view];
    if (view.thumbnail || view.docked) {
        view.activationReadyCompletion=nil; // Parking cancels the pending Home request, even if restored later.
        if (view.thumbnail && view.wasParkedIcon) {
            // Explicit icon restore is always first tier and leads the packed queue.
            view.thumbnailTier=0; view.thumbnailFree=NO; view.restoringPosition=NO;
            view.portraitSaved=NO; view.rotationOverflow=NO; view.stackOrder=0;
            [self.parkedOrder removeObject:view];
            [self.parkedOrder insertObject:view atIndex:0];
            self.pendingIconRestore=view;
        }
        if (![self.parkedOrder containsObject:view]) [self.parkedOrder addObject:view];
        if (self.floating==view) self.floating=nil;
    } else [self.parkedOrder removeObject:view];
    view.wasParkedIcon=view.docked;
    [self updateOutsideButton];
    [self scheduleArrange];
}
- (void)scheduleArrange {
    if(self.arrangeScheduled) return;
    self.arrangeScheduled=YES;
    __weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_main_queue(),^{ weakSelf.arrangeScheduled=NO; [weakSelf arrangeParked]; });
}
- (BOOL)activateWindow:(ZNSFloatingView *)view {
    if (!self.enabled || !ZNSReadAuthorization(YES)) return NO;
    if (!view || view.closing || view.parkedPan || ![self.windows containsObject:view] || view.session.layoutInFlight || self.floating.session.layoutInFlight || self.floating.activeManipulation || self.floating.dismissing || self.floating.rebounding) return NO;
    ZNSFloatingView *old=self.floating;
    if (old && old!=view) {
        if (old.ready) { if(![old parkLiveThumbnail]) return NO; }
        else [self closeWindow:old fullscreen:NO];
    }
    [self.parkedOrder removeObject:view];
    self.floating=view;
    view.stackOrder=++self.nextStackOrder;
    [self.controller.view bringSubviewToFront:view];
    return YES;
}
- (void)collapseParkedToIcon:(ZNSFloatingView *)view {
    [view cancelInteraction];
    view.thumbnail=NO; view.docked=YES; view.dockedFromThumbnail=YES; view.wasParkedIcon=YES;
    view.restoreButton.accessibilityLabel=@"恢复实时空挂窗口";
    [view updateContentInputGate]; [view setNeedsLayout];
}
- (ZNSFloatingView *)bottomParkedVictim:(NSArray<ZNSFloatingView *> *)items excluding:(ZNSFloatingView *)requested targets:(NSDictionary<NSValue *,NSValue *> *)targets {
    ZNSFloatingView *bottom=nil;
    CGFloat edge=-CGFLOAT_MAX;
    for(ZNSFloatingView *candidate in items) {
        // Free overlays count toward capacity, but never reserve packing cells.
        if(candidate==requested || !candidate.thumbnail || (candidate.thumbnailFree && targets!=nil) || candidate.closing) continue;
        NSValue *value=targets[[NSValue valueWithNonretainedObject:candidate]];
        CGFloat y=CGRectGetMaxY(value?value.CGRectValue:candidate.frame);
        if(!bottom || y>=edge) { bottom=candidate; edge=y; }
    }
    return bottom;
}
- (void)arrangeParked {
    if (self.arranging || !self.window) return;
    self.arranging=YES;
    NSMutableArray<ZNSFloatingView *> *items=[NSMutableArray new];
    for (ZNSFloatingView *v in self.parkedOrder) if (!v.closing && (v.thumbnail || v.docked)) [items addObject:v];
    BOOL waitingForDirection=NO;
    for (ZNSFloatingView *v in [self.windows copy]) {
        BOOL waiting=[v applyPendingDeviceOrientation];
        // A main-window rotation must be drained too, but doesn't reserve any
        // parked cells, so only parked transactions hold the packing pass.
        if(waiting && (v.thumbnail || v.docked)) waitingForDirection=YES;
    }
    if (waitingForDirection) { self.arranging=NO; return; }
    CGRect safe=[self availableFrame];
    BOOL dipFirstRow=NO;
    if(!self.dipIconManuallyPlaced) for(ZNSFloatingView *card in self.dippedOrder)
        if(card.dipped && !card.closing) { dipFirstRow=YES; break; }
    if(dipFirstRow) {
        CGFloat iconSize=MIN(ZNSParkedIconSize(),MIN(safe.size.width,safe.size.height));
        CGFloat reserved=MIN(iconSize+6,MAX(0,safe.size.height-1));
        safe.origin.y+=reserved; safe.size.height-=reserved;
    }
    ZNSFloatingView *requested=self.pendingIconRestore;
    if(![items containsObject:requested] || !requested.thumbnail) requested=nil;
    BOOL landscape=self.controller.view.bounds.size.width>self.controller.view.bounds.size.height;
    NSUInteger live=0;
    for(ZNSFloatingView *v in items) if(v.thumbnail) live++;
    if(self.dipEvictionPacking || dipFirstRow) {
        while(live>self.maxParkedApps) {
            ZNSFloatingView *bottom=[self bottomParkedVictim:items excluding:requested targets:nil];
            if(!bottom) break;
            bottom.rotationOverflow=NO; [self collapseParkedToIcon:bottom]; live--;
        }
    } else for(ZNSFloatingView *v in items) if(live>self.maxParkedApps && v.thumbnail && v!=requested) {
        v.rotationOverflow=NO; [self collapseParkedToIcon:v]; live--;
    }
    // Only icons created by a landscape space shortage are eligible. User-docked
    // icons and capacity overflow never unexpectedly turn into thumbnails.
    for(ZNSFloatingView *v in items) if(v.restoreOnNextArrange) {
        v.restoreOnNextArrange=NO;
        if(landscape || !v.rotationOverflow || live>=self.maxParkedApps) continue;
        // Reserve restoration candidates before movable icons. The packing pass
        // accepts the exact old position or collapses the candidate again.
        v.docked=NO; v.thumbnail=YES; v.wasParkedIcon=NO; v.dockedFromThumbnail=NO;
        v.restoringPosition=YES; live++;
    }
    CGRect *occupied=calloc(MAX(items.count,1),sizeof(CGRect));
    if(!occupied) { self.arranging=NO; return; }
    NSMutableDictionary<NSValue *,NSValue *> *targets=[NSMutableDictionary new];
    BOOL demotedForRestore=NO;
    for(NSUInteger attempt=0;attempt<=items.count+1;attempt++) {
        [targets removeAllObjects]; unsigned used=0;
        // Free third tiers neither reserve parking cells nor become space victims.
        for(ZNSFloatingView *v in items) if(v.thumbnail && v.thumbnailFree) {
            CGRect target=[v thumbnailFrameInSafe:safe];
            if(v.restoringPosition) target.origin=v.portraitFrame.origin;
            target=ZNSConstrainIcon(target,[self parkedMovementFrame]);
            targets[[NSValue valueWithNonretainedObject:v]]=[NSValue valueWithCGRect:target];
        }
        ZNSFloatingView *victim=nil;
        NSMutableArray<ZNSFloatingView *> *ordered=[NSMutableArray new];
        if(requested.thumbnail) [ordered addObject:requested];
        for(ZNSFloatingView *v in items) if(v!=requested && v.thumbnail && !v.thumbnailFree && v.restoringPosition) [ordered addObject:v];
        for(ZNSFloatingView *v in items) if(v!=requested && v.thumbnail && !v.thumbnailFree && !v.restoringPosition) [ordered addObject:v];
        for(ZNSFloatingView *v in ordered) {
            CGRect desired=[v thumbnailFrameInSafe:safe],target=CGRectZero;
            if(v.restoringPosition) desired.origin=v.portraitFrame.origin;
            if(landscape && v.portraitSaved && v.portraitTier==v.thumbnailTier && CGSizeEqualToSize(v.portraitCanvas,v.session.canvasSize)) desired.size=v.portraitFrame.size;
            BOOL inScreen=CGRectContainsRect(v.thumbnailFree?self.controller.view.bounds:safe,desired);
            if((v.thumbnailFree || v.restoringPosition) && inScreen && ZNSFrameClear(desired,occupied,used)) target=desired;
            else if(v.restoringPosition || !ZNSFindParkedFrame(desired,safe,occupied,used,v.thumbnailRight,0,&target)) { victim=v; break; }
            occupied[used++]=target; targets[[NSValue valueWithNonretainedObject:v]]=[NSValue valueWithCGRect:target];
        }
        if(!victim) {
            unsigned thumbnailCount=used;
            // Use the same safe area as parked thumbnails on ALL edges.
            // Restoring physical x/width puts landscape icons under the status
            // bar/notch region even though their vertical positions are safe.
            CGRect iconSafe=safe;
            NSUInteger icons=0;
            for(ZNSFloatingView *v in items) if(v.docked) icons++;
            CGFloat iconSize=fmin(ZNSParkedIconSize(),fmin(iconSafe.size.width,iconSafe.size.height));
            while(iconSize>16 && floor((iconSafe.size.width+6)/(iconSize+6))*floor((iconSafe.size.height+3)/(iconSize+3))<icons) iconSize-=2;
            for(ZNSFloatingView *v in items) if(v.docked) {
                CGRect desired=CGRectMake(v.frame.origin.x,v.frame.origin.y,iconSize,iconSize),target;
                if(!ZNSFindIconFrame(desired,iconSafe,occupied,used,thumbnailCount,v.thumbnailRight,&target)) {
                    for(ZNSFloatingView *other in items) if(other!=requested && other.thumbnail && !other.thumbnailFree) { victim=other; break; }
                    if(!victim && requested.thumbnail) victim=requested;
                    if(!victim) {
                        // No fixed thumbnails remain: repack only icons. Keep
                        // every free overlay's independently constrained target.
                        NSUInteger index=0;
                        for(ZNSFloatingView *icon in items) if(icon.docked) {
                            CGRect grid=ZNSIconGridFrame(iconSafe,(unsigned)icons,(unsigned)index++);
                            targets[[NSValue valueWithNonretainedObject:icon]]=[NSValue valueWithCGRect:grid];
                        }
                    }
                    break;
                }
                occupied[used++]=target; targets[[NSValue valueWithNonretainedObject:v]]=[NSValue valueWithCGRect:target];
            }
        }
        if(!victim) break;
        if(self.dipEvictionPacking || dipFirstRow) {
            ZNSFloatingView *bottom=[self bottomParkedVictim:items excluding:requested targets:targets];
            if(bottom) victim=bottom;
        }
        if(requested && !demotedForRestore && !self.dipEvictionPacking && !dipFirstRow) {
            // Only the oldest packed second tier yields; free overlays are untouched.
            ZNSFloatingView *second=nil;
            for(ZNSFloatingView *v in items) {
                if(v!=requested && v.thumbnail && v.thumbnailTier==1 && !v.thumbnailFree && !v.closing && !v.parkedPan && !v.session.layoutInFlight) { second=v; break; }
            }
            if(second) {
                second.thumbnailTier=0; second.restoringPosition=NO; second.portraitSaved=NO;
                second.rotationOverflow=NO; second.portraitTier=0; second.portraitCanvas=CGSizeZero;
                [items removeObject:second]; [items addObject:second];
                [self.parkedOrder removeObject:second]; [self.parkedOrder addObject:second];
                [second setNeedsLayout]; demotedForRestore=YES;
                continue;
            }
        }
        if(landscape && victim.portraitSaved) victim.rotationOverflow=YES;
        if(landscape && victim.thumbnailTier==1) {
            // A second-tier space overflow is an icon whose next thumbnail is
            // first tier, both on tap and on automatic portrait restoration.
            victim.thumbnailTier=0; victim.thumbnailFree=NO;
            victim.portraitTier=0; victim.portraitCanvas=CGSizeZero;
            victim.restoringPosition=NO;
        }
        [self collapseParkedToIcon:victim];
    }
    free(occupied);
    for(ZNSFloatingView *view in items) {
        NSValue *value=targets[[NSValue valueWithNonretainedObject:view]];
        if(!value || view.parkedPan) continue;
        CGRect target=value.CGRectValue;
        if(view.thumbnail) view.rotationOverflow=NO;
        if(!view.thumbnail) view.restoringPosition=NO;
        [view setNeedsLayout];
        if(!CGRectEqualToRect(view.frame,target)) {
            [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled()?0:0.18 delay:0 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction|UIViewAnimationOptionCurveEaseOut animations:^{
                view.frame=target; [view layoutIfNeeded];
            } completion:nil];
        } else [view layoutIfNeeded];
    }
    self.pendingIconRestore=nil; self.dipEvictionPacking=NO;
    [self updateWindowStack];
    self.arranging=NO; [self updateOutsideButton];
}
- (BOOL)shouldHideDesktopIconsAndStatusBar {
    if(!self.enabled || !self.window || self.window.hidden) return NO;
    CGSize size=self.controller.view.bounds.size;
    BOOL landscape=size.width>size.height;
    for(ZNSFloatingView *view in self.windows)
        if(!view.closing && !view.hidden && (landscape || (!view.thumbnail && !view.docked && !view.dipped))) return YES;
    return NO;
}
- (BOOL)shouldHideDesktopPageControls {
    // Preserve the existing main-window/landscape policy. A dipped card adds
    // only search/page-control suppression, not icon, status-bar or Dock hiding.
    if([self shouldHideDesktopIconsAndStatusBar]) return YES;
    if(!self.enabled || !self.window || self.window.hidden) return NO;
    for(ZNSFloatingView *view in self.windows)
        if(view.dipped && !view.hidden) return YES;
    return NO;
}
- (BOOL)shouldHideDesktopDock {
    if([self shouldHideDesktopIconsAndStatusBar]) return YES;
    if(!self.enabled || !self.window || self.window.hidden) return NO;
    for(ZNSFloatingView *view in self.windows) {
        if(view.closing || view.hidden || view.docked || view.dipped) continue;
        if(!view.thumbnail || (view.thumbnailFree && view.thumbnailTier>=1)) return YES;
    }
    return NO;
}
- (void)updateOutsideButton {
    [self updateDipIcon];
    [self updateWindowStack];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ZNSDesktopVisibilityChanged" object:nil];
    // Release every non-main scene before requesting the new owner. Ready is
    // essential: a late scene-attach callback must not focus a parked window.
    ZNSFloatingView *owner=self.floating;
    BOOL focusAllowed=owner.ready && !owner.closing && !owner.docked && !owner.thumbnail && !owner.dipped && !owner.rebounding && !self.window.hidden;
    for(ZNSFloatingView *view in self.windows)
        if(view!=owner || !focusAllowed) {
            [view restorePortraitKeyboardWithDuration:0 options:0];
            [view.session setKeyboardFocusActive:NO];
        }
    if(focusAllowed) [owner.session setKeyboardFocusActive:YES];
    BOOL active=(self.floating.ready || self.floating.connecting) && !self.floating.docked && !self.floating.thumbnail && !self.floating.dipped && !self.floating.rebounding;
    self.outsideButton.hidden=!active;
    // Disable as well as hide: parked/icon states must leave other apps usable.
    BOOL applied=ZNSSetLayerInputEnabled(self.outsideButton.layer,active);
    os_log(ZNSLog(),"outside park input active=%d applied=%d",active,applied);
}
#include "ZNSPortraitManager.inc"
- (void)externalKeyboardVisibilityChanged:(NSNotification *)notification {
    (void)notification;
    [self refreshKeyboardDismissShield];
}
- (void)refreshKeyboardDismissShield {
    UIView *root=self.controller.view;
    NSString *bundle=[ZNSKeyboardPlacement visibleExternalKeyboardBundleIdentifier];
    BOOL active=self.enabled && self.window && !self.window.hidden && root && bundle.length>0;
    if(active && !self.keyboardDismissShield) {
        UIView *shield=[[UIView alloc] initWithFrame:root.bounds];
        shield.backgroundColor=UIColor.clearColor;
        shield.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
        shield.accessibilityIdentifier=@"ZNSExternalKeyboardOutsideDismiss";
        shield.accessibilityLabel=@"点击键盘外部收起键盘";
        [shield addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(keyboardOutsideTapped:)]];
        ZNSSetLayerInputOpaque(shield.layer,YES);
        self.keyboardDismissShield=shield;
        [root addSubview:shield];
    }
    self.keyboardDismissShield.frame=root.bounds;
    self.keyboardDismissShield.hidden=!active;
    self.keyboardDismissShield.userInteractionEnabled=active;
    ZNSSetLayerInputEnabled(self.keyboardDismissShield.layer,active);
    if(active) [root bringSubviewToFront:self.keyboardDismissShield];
}
- (BOOL)consumeKeyboardOutsideTap:(UITapGestureRecognizer *)gesture {
    NSString *bundle=nil;
    if(![ZNSKeyboardPlacement consumeOutsideTapAtPoint:[gesture locationInView:gesture.view]
                                              inView:gesture.view bundleIdentifier:&bundle]) return NO;
    BOOL landscape=[self currentDeviceLandscape];
    BOOL close=self.keyboardDismissClosesWindow &&
        ([self.keyboardDismissCloseOrientation isEqualToString:@"both"] ||
         [self.keyboardDismissCloseOrientation isEqualToString:(landscape?@"landscape":@"portrait")]);
    if(close && bundle.length) {
        for(ZNSFloatingView *view in [self.windows copy]) {
            if(!view.closing && [view.session.bundleIdentifier isEqualToString:bundle])
                [self closeWindow:view fullscreen:NO];
        }
    }
    [self refreshKeyboardDismissShield];
    return YES;
}
- (void)keyboardOutsideTapped:(UITapGestureRecognizer *)gesture {
    if(gesture.state!=UIGestureRecognizerStateRecognized) return;
    if(ZNSBool(ZNSShared(@"SBLockScreenManager"),@"isUILocked")) { [self close:NO]; return; }
    [self consumeKeyboardOutsideTap:gesture];
    // Always consume this shield's touch: never fall through to park/activate.
}
- (void)outsideTapped:(UITapGestureRecognizer *)gesture {
    if (gesture.state!=UIGestureRecognizerStateRecognized) return;
    if([self consumeKeyboardOutsideTap:gesture]) return;
    if(!self.floating || self.floating.dipped || self.floating.rebounding) return;
    if (ZNSBool(ZNSShared(@"SBLockScreenManager"),@"isUILocked")) { [self close:NO]; return; }
    // Our outside-tap shield sits above Home's icons while a main window is up.
    // Resolve only a real Home-screen icon under this local tap; do not forward
    // synthetic touches, invoke launch, or inspect an unrelated foreground App.
    if (ZNSBool(UIApplication.sharedApplication,@"isShowingHomescreen")) {
        Class homeClass=NSClassFromString(@"SBHomeScreenWindow");
        Class iconClass=NSClassFromString(@"SBIconView");
        for (UIWindow *home in self.window.windowScene.windows) {
            if (!homeClass || !iconClass || ![home isKindOfClass:homeClass] || home.hidden || home.alpha<0.01) continue;
            CGPoint point=[gesture locationInView:home];
            UIView *hit=[home hitTest:point withEvent:nil];
            for (UIView *icon=hit;icon && icon!=home;icon=icon.superview) {
                if (![icon isKindOfClass:iconClass]) continue;
                if (ZNSBool(icon,@"isEnabled") && [self handleDesktopIconTap:icon]) return;
                break;
            }
        }
    }
    os_log(ZNSLog(),"outside park tap received ready=%d",self.floating.ready);
    [self.floating parkLiveThumbnail];
}
- (CGRect)availableFrame {
    CGRect bounds=self.controller.view.bounds;
    UIEdgeInsets insets=self.controller.view.safeAreaInsets;
    insets.top=MAX(insets.top,48)+6; insets.bottom=MAX(insets.bottom,20)+6;
    insets.left=MAX(insets.left,6); insets.right=MAX(insets.right,6);
    CGRect available=UIEdgeInsetsInsetRect(bounds,insets);
    available.size.height=MAX(1,MIN(CGRectGetMaxY(available),[self dipReservedTop])-available.origin.y);
    return available;
}
- (CGRect)mainAvailableFrame {
    CGRect bounds=self.controller.view.bounds;
    UIEdgeInsets safe=self.controller.view.safeAreaInsets;
    UIEdgeInsets inset=UIEdgeInsetsZero;
    // Read the actual status-bar strip in this window's coordinates, even when
    // its view is hidden. Keep only that edge; other edges use the physical screen.
    CGRect bar=self.window.windowScene.statusBarManager.statusBarFrame;
    if(!CGRectIsEmpty(bar) && !CGRectIsNull(bar)) {
        bar=[self.window convertRect:bar fromCoordinateSpace:self.window.screen.coordinateSpace];
        bar=[self.controller.view convertRect:bar fromView:self.window];
        bar=CGRectIntersection(bounds,bar);
    }
    if(!CGRectIsEmpty(bar) && !CGRectIsNull(bar) && bar.size.width>=bounds.size.width*0.5 && bar.size.height<bounds.size.height*0.5) {
        if(CGRectGetMidY(bar)<CGRectGetMidY(bounds)) inset.top=MAX(safe.top,CGRectGetMaxY(bar)-CGRectGetMinY(bounds))+6;
        else inset.bottom=MAX(safe.bottom,CGRectGetMaxY(bounds)-CGRectGetMinY(bar))+6;
    } else if(!CGRectIsEmpty(bar) && !CGRectIsNull(bar) && bar.size.height>=bounds.size.height*0.5 && bar.size.width<bounds.size.width*0.5) {
        if(CGRectGetMidX(bar)<CGRectGetMidX(bounds)) inset.left=MAX(safe.left,CGRectGetMaxX(bar)-CGRectGetMinX(bounds))+6;
        else inset.right=MAX(safe.right,CGRectGetMaxX(bounds)-CGRectGetMinX(bar))+6;
    } else {
        // Status frame can disappear while hidden or during rotation: preserve
        // the status/notch side from the interface orientation, never device gravity.
        if(self.mainStatusOrientation==self.window.windowScene.interfaceOrientation && !UIEdgeInsetsEqualToEdgeInsets(self.mainStatusInsets,UIEdgeInsetsZero))
            inset=self.mainStatusInsets;
        else if(self.window.windowScene.interfaceOrientation==UIInterfaceOrientationLandscapeLeft)
            inset.right=MAX(safe.right,48)+6;
        else if(self.window.windowScene.interfaceOrientation==UIInterfaceOrientationLandscapeRight)
            inset.left=MAX(safe.left,48)+6;
        else if(self.window.windowScene.interfaceOrientation==UIInterfaceOrientationPortraitUpsideDown)
            inset.bottom=MAX(safe.bottom,48)+6;
        else inset.top=MAX(safe.top,48)+6;
    }
    self.mainStatusInsets=inset; self.mainStatusOrientation=self.window.windowScene.interfaceOrientation;
    return UIEdgeInsetsInsetRect(bounds,inset);
}
- (CGPoint)notchPoint {
    CGRect b=self.controller.view.bounds;
    switch(self.window.windowScene.interfaceOrientation) {
        case UIInterfaceOrientationLandscapeLeft: return CGPointMake(CGRectGetMaxX(b)-8,CGRectGetMidY(b));
        case UIInterfaceOrientationLandscapeRight: return CGPointMake(CGRectGetMinX(b)+8,CGRectGetMidY(b));
        case UIInterfaceOrientationPortraitUpsideDown: return CGPointMake(CGRectGetMidX(b),CGRectGetMaxY(b)-8);
        default: return CGPointMake(CGRectGetMidX(b),CGRectGetMinY(b)+8);
    }
}
- (void)animateOpening:(ZNSFloatingView *)view {
    [view restartBarHints];
    if(UIAccessibilityIsReduceMotionEnabled()) return;
    CGPoint notch=[self notchPoint];
    CATransform3D source=CATransform3DMakeTranslation(notch.x-view.center.x,notch.y-view.center.y,0);
    source=CATransform3DScale(source,0.04,0.006,1);
    CABasicAnimation *expand=[CABasicAnimation animationWithKeyPath:@"transform"];
    expand.fromValue=[NSValue valueWithCATransform3D:source]; expand.toValue=[NSValue valueWithCATransform3D:CATransform3DIdentity];
    expand.duration=0.42; expand.timingFunction=[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [view.layer addAnimation:expand forKey:@"ZNSNotchOpening"];
    CABasicAnimation *fade=[CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue=@0; fade.toValue=@1; fade.duration=0.25;
    [view.layer addAnimation:fade forKey:@"ZNSNotchFade"];
}
- (void)closeWindow:(ZNSFloatingView *)view fullscreen:(BOOL)fullscreen {
    if (!view || view.closing || ![self.windows containsObject:view]) return;
    if(view==self.dipExtractedWindow) [self clearDipExtraction];
    if(fullscreen || UIAccessibilityIsReduceMotionEnabled()) { [self finishCloseWindow:view fullscreen:fullscreen]; return; }
    view.closing=YES; ++view.interactionGeneration; ++view.toolsGeneration;
    // Lifecycle must invalidate a pending visual hide before taking ownership
    // of the root transform for the closing animation.
    [view restorePortraitKeyboardWithDuration:0 options:0];
    view.rebounding=NO; view.dismissing=NO; view.activeManipulation=nil; view.userInteractionEnabled=NO;
    view.activationReadyCompletion=nil;
    view.presentationChanged=nil; view.willActivate=nil; view.closeAction=nil; view.canOccupy=nil;
    [view updateContentInputGate];
    [view.layer removeAllAnimations];
    if(self.floating==view) self.floating=nil;
    [self updateOutsideButton];
    CGPoint notch=[self notchPoint];
    CGAffineTransform destination=CGAffineTransformMakeTranslation(notch.x-view.center.x,notch.y-view.center.y);
    destination=CGAffineTransformScale(destination,0.04,0.006);
    __weak typeof(self) weakSelf=self;
    [UIView animateWithDuration:0.36 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        view.transform=destination; view.alpha=0;
    } completion:^(BOOL finished) { (void)finished; [weakSelf finishCloseWindow:view fullscreen:NO]; }];
}
- (void)finishCloseWindow:(ZNSFloatingView *)view fullscreen:(BOOL)fullscreen {
    if (!view || ![self.windows containsObject:view]) return;
    if(view==self.dipExtractedWindow) [self clearDipExtraction];
    NSString *bundle=view.session.bundleIdentifier;
    BOOL expandedFullscreen=fullscreen && view.fullscreenExpanding;
    view.closing=YES; ++view.interactionGeneration; ++view.toolsGeneration;
    [view restorePortraitKeyboardWithDuration:0 options:0];
    view.rebounding=NO; view.dismissing=NO; view.activeManipulation=nil;
    view.activationReadyCompletion=nil;
    view.presentationChanged=nil; view.willActivate=nil; view.closeAction=nil; view.canOccupy=nil;
    [self.windows removeObject:view]; [self.parkedOrder removeObject:view];
    [self.dippedOrder removeObject:view];
    if(self.dipToolbarOwner==view) self.dipToolbarOwner=nil;
    view.tryDip=nil; view.pullDip=nil; view.parkedMovementBounds=nil; view.dipDockBounds=nil;
    if(!self.closingAllWindows) [self layoutDippedWindows:YES];
    [view.layer removeAllAnimations];
    [view.session stopForFullscreen:fullscreen];
    [view removeFromSuperview];
    if (self.floating==view) self.floating=nil;
    if (self.windows.count==0) {
        [self.outsideButton removeFromSuperview]; self.outsideButton=nil;
        ZNSSetLayerInputEnabled(self.keyboardDismissShield.layer,NO);
        [self.keyboardDismissShield removeFromSuperview]; self.keyboardDismissShield=nil;
        self.window.hidden=YES; self.controller.geometryChanged=nil;
        self.window.rootViewController=nil; self.window=nil; self.controller=nil;
    } else if(!self.closingAllWindows) [self arrangeParked];
    if(!self.closingAllWindows) [self updateOutsideButton];
    if (expandedFullscreen) {
        if (!ZNSOpenFullscreenWithoutAnimation(bundle))
            os_log_error(ZNSLog(),"expanded fullscreen handoff failed; animated icon launch deliberately skipped");
    } else if (fullscreen && bundle.length && [UIApplication.sharedApplication respondsToSelector:@selector(launchApplicationWithIdentifier:suspended:)]) {
        @try { [UIApplication.sharedApplication launchApplicationWithIdentifier:bundle suspended:NO]; }
        @catch(NSException *exception) { os_log_error(ZNSLog(),"fullscreen launch rejected: %{public}@",exception.name); }
    }
}
- (void)close:(BOOL)fullscreen {
    for (ZNSFloatingView *view in [self.windows copy]) [self closeWindow:view fullscreen:fullscreen];
}
- (void)closeDippedBundleIdentifier:(NSString *)bundle {
    if(![bundle isKindOfClass:NSString.class] || !bundle.length) return;
    if(!NSThread.isMainThread) {
        NSString *identifier=[bundle copy];
        dispatch_async(dispatch_get_main_queue(),^{ [self closeDippedBundleIdentifier:identifier]; });
        return;
    }
    // Finish immediately, including any in-flight dip/close animation. Never
    // relaunch the App or remove another App's card from the system switcher.
    for(ZNSFloatingView *view in [self.windows copy]) {
        if(view.dipped && [view.session.bundleIdentifier isEqualToString:bundle]) {
            [view cancelInteraction];
            [self finishCloseWindow:view fullscreen:NO];
        }
    }
}
- (void)closeForDeviceLock {
    if(!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(),^{ [self closeForDeviceLock]; });
        return;
    }
    if(self.deviceLockClosing) return;
    self.deviceLockClosing=YES;
    @try {
        self.window.hidden=YES;
        // Withdraw ALL leases before tearing down the first hosted window.
        for(ZNSFloatingView *view in [self.windows copy]) [view.session prepareForDeviceLock];
        [self.preparedSwitcherSession prepareForDeviceLock];
        [self closeForLock];
    } @finally { self.deviceLockClosing=NO; }
}
- (void)closeForLock {
    if(!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(),^{ [self closeForLock]; });
        return;
    }
    if(self.closingAllWindows) return;
    self.closingAllWindows=YES;
    @try {
        // Hide immediately and disconnect geometry callbacks before removals.
        self.window.hidden=YES;
        self.controller.geometryChanged=nil;
        [self clearDipExtraction]; [self clearDipTether];
        [self.dipIcon removeFromSuperview]; self.dipIcon=nil; self.dipIconPan=nil;
        self.dipIconManuallyPlaced=NO;
        self.pendingIconRestore=nil;
        [self.switcherPreparation cancel]; self.switcherPreparation=nil;
        [self.desktopPreparation cancel]; self.desktopPreparation=nil;
        for(ZNSFloatingView *view in [self.windows copy]) {
            view.closing=YES;
            view.userInteractionEnabled=NO;
            [view stopSqueezeFeedback];
            [self finishCloseWindow:view fullscreen:NO];
        }
    } @finally { self.closingAllWindows=NO; }
}
- (void)observeEvent:(UIEvent *)event { (void)event; /* Outside taps use the local overlay control, not a global event hook. */ }
@end
