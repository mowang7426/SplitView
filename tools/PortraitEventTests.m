// Runs production placement + scene + floating view + manager methods.
// Only UIKit/render-server transport is mocked. NOT a device rendering test.
#define main ZNSSceneTestsMain
#include "PortraitSceneTests.m"
#undef main

typedef NSUInteger UIViewAnimationOptions;
typedef double CFTimeInterval;
typedef struct { CGFloat top,left,bottom,right; } UIEdgeInsets;
#define UIViewAnimationOptionBeginFromCurrentState 4
#define UIViewAnimationOptionAllowUserInteraction 2
static BOOL UIAccessibilityIsReduceMotionEnabled(void) { return NO; }
static double ZNSNow=10;
static double CACurrentMediaTime(void) { return ZNSNow; }
static NSUInteger ZNSAnimations,ZNSCurrentAnimation,ZNSWithoutAnimations;
static NSTimeInterval ZNSLastAnimationDuration;
static NSUInteger ZNSLastAnimationOptions;
static NSMutableArray *ZNSAnimationEnds;
typedef NS_ENUM(NSUInteger,ZNSClientKeyboardPhase) {
    ZNSClientKeyboardUnknown=0, ZNSClientKeyboardShown=1,
    ZNSClientKeyboardWillHide=2, ZNSClientKeyboardHidden=3
};
#include "../Sources/ZNSClientHiddenProof.inc"
static uint64_t ZNSMockPhase=101,ZNSMockRequest,ZNSMockResponse,ZNSMockExpected;
static NSInteger ZNSMockLive=2,ZNSMockReplyLive=2;
static void ZNSMockReply(void) { ZNSMockReplyLive=ZNSMockLive; ZNSMockResponse=ZNSMockRequest; }
static uint64_t ZNSReadClientKeyboardPhaseWord(pid_t pid) { return pid==42?ZNSMockPhase:0; }
static ZNSClientKeyboardPhase ZNSReadClientKeyboardPhase(pid_t pid) { return (ZNSClientKeyboardPhase)(ZNSReadClientKeyboardPhaseWord(pid)&3); }
static uint64_t ZNSRequestClientHiddenProof(pid_t pid,uint64_t phase) {
    assert(pid==42); ZNSMockExpected=phase; ZNSMockResponse=0; return ++ZNSMockRequest;
}
static NSInteger ZNSReadClientHiddenProof(pid_t pid,uint64_t request,uint64_t phase) {
    if (pid!=42 || !request || request!=ZNSMockResponse || phase!=ZNSMockExpected) return 0;
    return ZNSClientResolveHiddenProof(phase,ZNSMockPhase,ZNSMockReplyLive);
}
static NSDictionary *ZNSPortraitRestoreTiming;
static NSUInteger ZNSVisibilityPublications;
static void ZNSPublishKeyboardVisibility(void) { ZNSVisibilityPublications++; }
@interface ZNSTestLayer : NSObject
@property(nonatomic) CGFloat cornerRadius;
@property(nonatomic) NSUInteger maskedCorners;
- (void)removeAllAnimations;
- (void)removeAnimationForKey:(NSString *)key;
@end
@implementation ZNSTestLayer
- (void)removeAllAnimations {}
- (void)removeAnimationForKey:(NSString *)key { assert(([@[@"transform",@"cornerRadius",@"opacity"] containsObject:key])); }
@end
@interface NSLayoutConstraint : NSObject
+ (void)activateConstraints:(NSArray *)constraints;
@end
@implementation NSLayoutConstraint
+ (void)activateConstraints:(NSArray *)constraints { (void)constraints; }
@end
@class UIWindow;
@interface UIView : NSObject
@property(nonatomic) CGRect frame,bounds;
@property(nonatomic) CGPoint center;
@property(nonatomic) CGAffineTransform transform;
@property(nonatomic) NSUInteger autoresizingMask;
@property(nonatomic) BOOL translatesAutoresizingMaskIntoConstraints;
@property(nonatomic,strong) ZNSTestLayer *layer;
@property(nonatomic,strong) NSArray *subviews;
@property(nonatomic,copy) void (^onDetach)(void);
- (void)insertSubview:(UIView *)view atIndex:(NSUInteger)index;
@property(nonatomic) BOOL hidden,userInteractionEnabled;
@property(nonatomic) CGFloat alpha;
@property(nonatomic) NSUInteger frameAnimation,transformAnimation;
@property(nonatomic) NSUInteger layouts;
@property(nonatomic) CGSize lastLayoutCanvas;
- (UIView *)snapshotViewAfterScreenUpdates:(BOOL)updates;
+ (void)performWithoutAnimation:(void (^)(void))block;
- (void)addSubview:(UIView *)view;
- (void)removeFromSuperview;
@property(nonatomic,strong) UIView *superview;
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic) UIEdgeInsets safeAreaInsets;
- (CGRect)convertRect:(CGRect)rect toView:(UIView *)view;
- (CGRect)convertRect:(CGRect)rect fromView:(UIView *)view;
- (void)setNeedsLayout;
- (void)layoutIfNeeded;
+ (void)animateWithDuration:(NSTimeInterval)duration delay:(NSTimeInterval)delay options:(NSUInteger)options animations:(void (^)(void))animations completion:(void (^)(BOOL))completion;
@end
@implementation UIView
@synthesize transform=_transform;
- (instancetype)init { if ((self=[super init])) { _transform=CGAffineTransformIdentity; _layer=[ZNSTestLayer new]; } return self; }
- (void)setTransform:(CGAffineTransform)transform { _transform=transform; self.transformAnimation=ZNSCurrentAnimation; }
- (CGRect)frame {
    CGRect relative=CGRectMake(-self.bounds.size.width/2,-self.bounds.size.height/2,self.bounds.size.width,self.bounds.size.height);
    CGRect mapped=CGRectApplyAffineTransform(relative,self.transform);
    return CGRectOffset(mapped,self.center.x,self.center.y);
}
- (void)setFrame:(CGRect)frame {
    assert(CGAffineTransformIsIdentity(self.transform)); // UIKit frame is undefined under nonidentity transform.
    self.bounds=(CGRect){CGPointZero,frame.size};
    self.center=CGPointMake(CGRectGetMidX(frame),CGRectGetMidY(frame)); self.frameAnimation=ZNSCurrentAnimation;
}
- (UIView *)snapshotViewAfterScreenUpdates:(BOOL)updates {
    (void)updates; assert(!"remote surface snapshot is forbidden"); return nil;
}
+ (void)performWithoutAnimation:(void (^)(void))block {
    NSUInteger previous=ZNSCurrentAnimation; ZNSCurrentAnimation=0; ZNSWithoutAnimations++;
    block(); ZNSCurrentAnimation=previous;
}
- (void)addSubview:(UIView *)view { view.superview=self; }
- (void)removeFromSuperview { self.superview=nil; if(self.onDetach) self.onDetach(); }
- (void)insertSubview:(UIView *)view atIndex:(NSUInteger)index { (void)index; view.superview=self; }
- (CGRect)convertRect:(CGRect)rect toView:(UIView *)view { (void)view; return rect; }
- (CGRect)convertRect:(CGRect)rect fromView:(UIView *)view { (void)view; return rect; }
- (void)setNeedsLayout {}
- (void)layoutIfNeeded {}
+ (void)animateWithDuration:(NSTimeInterval)duration delay:(NSTimeInterval)delay options:(NSUInteger)options animations:(void (^)(void))animations completion:(void (^)(BOOL))completion {
    (void)delay; ZNSLastAnimationDuration=duration; ZNSLastAnimationOptions=options;
    NSUInteger previous=ZNSCurrentAnimation; ZNSCurrentAnimation=++ZNSAnimations;
    animations(); ZNSCurrentAnimation=previous;
    if(completion) [ZNSAnimationEnds addObject:[^{ completion(YES); } copy]];
}
@end
@interface UIWindow : UIView
@property(nonatomic,strong) UIView *keyboard;
@end
@implementation UIWindow @end
@interface NSValue (ZNSGeometryTest)
+ (instancetype)valueWithCGRect:(CGRect)rect;
- (CGRect)CGRectValue;
@end
@implementation NSValue (ZNSGeometryTest)
+ (instancetype)valueWithCGRect:(CGRect)rect { return [self valueWithBytes:&rect objCType:@encode(CGRect)]; }
- (CGRect)CGRectValue { CGRect rect; [self getValue:&rect size:sizeof(rect)]; return rect; }
@end
static BOOL ZNSFiniteRect(CGRect r) { return isfinite(r.origin.x)&&isfinite(r.origin.y)&&isfinite(r.size.width)&&isfinite(r.size.height)&&r.size.width>0&&r.size.height>0; }
static BOOL ZNSFocus=YES,ZNSInput=YES;
static BOOL ZNSKeyboardMatchesFocus(id owner) { (void)owner; return ZNSFocus; }
static BOOL ZNSKeyboardInputPresent(id input) { (void)input; return ZNSInput; }
static id ZNSKeyboardObject(id object,NSString *key) { (void)key; return object; }
static id ZNSActiveKeyboardDelegate(void) { return @1; }
@interface ZNSKeyboardPlacement : ZNSTempKeyboard
@property(nonatomic) BOOL external;
@property(nonatomic,strong) UIView *nativeCandidate;
- (UIView *)findKeyboard;
- (void)znsRecoverHiddenNativeSurface;
@property(nonatomic) uint64_t znsHiddenProofRequest,znsHiddenProofPhase;
@property(nonatomic) BOOL portraitExpansion,active,suspended,invalidated,keyboardHidden,dismissPending,explicitlyDismissed,mutating,clientVisibilityKnown,clientKeyboardShown,clientKeyboardWillHide,portraitKeyboardVisibleLatch,attached;
@property(nonatomic) CFTimeInterval portraitCanvasTransitionUntil,hiddenAt;
@property(nonatomic) CGRect portraitKeyboardFrame,geometryBounds,geometryContent,clientKeyboardRegion,reportedKeyboardFrame;
@property(nonatomic) CGSize clientKeyboardCanvas;
@property(nonatomic,strong) UIView *host;
@property(nonatomic,strong) id geometryKeyboard,geometryDelegate,frameDelegate;
@property(nonatomic) NSUInteger restores,schedules,dismissGeneration,portraitKeyboardVisualPhaseGeneration;
@property(nonatomic) pid_t clientPID;
@property(nonatomic) BOOL nativeScreenKeyboard,independent;
@property(nonatomic,strong) UIView *keyboard,*originalParent,*keyboardContainer,*dragHandle;
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic,strong) NSArray *savedConstraints;
@property(nonatomic,strong) id attachedDelegate;
@property(nonatomic) NSUInteger originalIndex,savedAutoresizing;
@property(nonatomic) BOOL savedTranslates;
@property(nonatomic) CGAffineTransform savedTransform;
@property(nonatomic) CGRect savedBounds;
@property(nonatomic) CGPoint savedCenter;
@property(nonatomic,strong) NSString *lastReason;
@property(nonatomic,copy) NSString *bundleIdentifier;
@property(nonatomic) NSTimeInterval presentationDuration;
@property(nonatomic) UIViewAnimationOptions presentationOptions;
@property(nonatomic) BOOL presentationTimingKnown;
- (BOOL)externalKeyboardVisible;
- (BOOL (^)(void))znsPortraitHiddenRestoreGuard;
- (void)restore;
- (void)schedule;
- (void)clearShowProof;
- (void)rejectExternal:(NSString *)reason;
- (BOOL)znsPortraitPresentationEligible;
- (BOOL)znsPortraitKeyboardContinuity;
- (void)znsBeginPortraitGeometryRefresh;
- (BOOL)znsDeferPortraitSystemHide;
- (void)znsClientWillHide;
- (void)znsResampleHiddenProof;
- (void)znsAcceptClientPhase:(ZNSClientKeyboardPhase)phase;
- (void)znsClientDidHide;
- (void)znsReparentForNativeKeyboardUpdate;
- (BOOL)znsMayAcceptNativeShown;
- (void)znsApplyNativeShowResult:(BOOL)result inputPresent:(BOOL)inputPresent;
- (void)znsAcceptClientGeometry:(CGRect)region canvas:(CGSize)canvas valid:(BOOL)valid focused:(BOOL)focused;
@end
static NSNotificationName const ZNSPortraitKeyboardWillHideVisualNotification=@"ZNSPortraitKeyboardWillHideVisual";
static pid_t ZNSVerifiedPID=42;
static pid_t ZNSKeyboardClientPID(ZNSKeyboardPlacement *owner) { (void)owner; return ZNSVerifiedPID; }
#undef dispatch_async
#define dispatch_async(queue,...) ZNSEnqueue((__VA_ARGS__),NO)
#define ZNSVisualSynchronousTest(...) (__VA_ARGS__)()
#include "../Sources/ZNSPortraitVisualEvent.inc"
static void ConfirmHidden(ZNSKeyboardPlacement *p) {
    ZNSMockPhase=((ZNSMockPhase>>2)+1)*4+ZNSClientKeyboardHidden;
    ZNSMockLive=2;
    [p znsAcceptClientPhase:ZNSClientKeyboardHidden];
    ZNSMockReply();
    [p znsAcceptClientPhase:ZNSClientKeyboardHidden];
}
static BOOL ZNSKeyboardHookReady=YES;
static BOOL ZNSKeyboardVisible(UIView *view) { return !view.hidden && view.alpha>=0.01; }
@implementation ZNSKeyboardPlacement
- (UIView *)findKeyboard { return self.nativeCandidate; }
#include "../Sources/ZNSHiddenSurfaceRecovery.inc"
- (BOOL)externalKeyboardVisible { return self.attached && self.active && !self.suspended && !self.invalidated && !self.keyboardHidden && !self.dismissPending; }
- (void)setMutating:(BOOL)value { _mutating=value; if(value) { self.attached=NO; self.restores++; } }
@synthesize mutating=_mutating;
#include "../Sources/ZNSKeyboardRestore.inc"
- (void)schedule { ++self.schedules; }
- (void)clearShowProof { self.portraitCanvasTransitionUntil=0; self.portraitKeyboardVisibleLatch=NO; self.geometryKeyboard=nil; self.geometryDelegate=nil; }
- (void)rejectExternal:(NSString *)reason { self.lastReason=reason; }
#include "../Sources/ZNSPortraitPlacement.inc"
@end
@interface ZNSFloatingView : UIView
@property(nonatomic) BOOL portraitKeyboardExpanded,portraitKeyboardSuppressed,portraitKeyboardRestoring;
@property(nonatomic) NSUInteger portraitKeyboardRestoreGeneration;
@property(nonatomic) NSUInteger portraitKeyboardHideRetryGeneration;
@property(nonatomic) BOOL portraitKeyboardHideRetryActive;
@property(nonatomic,copy) BOOL (^portraitKeyboardHideRetryGuard)(void);
- (void)znsAttemptPortraitHideRestore:(NSUInteger)attempt token:(NSUInteger)token;
- (void)znsRetryPortraitHideRestore:(NSUInteger)attempt token:(NSUInteger)token;

@property(nonatomic) BOOL portraitKeyboardVisualRestoring,portraitKeyboardVisualRestoreCompleted,portraitKeyboardVisualFinalizePending,portraitKeyboardVisualReturning;
@property(nonatomic) NSUInteger portraitKeyboardVisualRestoreGeneration;
@property(nonatomic) BOOL portraitKeyboardChromeFading;
- (void)beginPortraitKeyboardVisualRestoreWithDuration:(NSTimeInterval)duration options:(UIViewAnimationOptions)options;
- (void)cancelPortraitKeyboardVisualRestoreWithDuration:(NSTimeInterval)duration options:(UIViewAnimationOptions)options;
- (void)znsRestorePortraitKeyboardAfterHide;
- (void)znsResumePortraitAfterHide;
- (void)clearPortraitKeyboardVisualRestore;
@property(nonatomic) CGRect portraitKeyboardSavedFrame,portraitKeyboardSavedExpandedFrame,portraitKeyboardTarget,expandedFrame;
@property(nonatomic) BOOL ready,closing,docked,thumbnail,dipped,dismissing,rebounding,fullscreenExpanding;
@property(nonatomic,strong) id activeManipulation;
@property(nonatomic,strong) ZNSSceneSession *session;
@property(nonatomic,strong) UIView *content,*bodyBackground,*canvasContainer,*toolbar,*topBar,*bottomBar;
- (void)updateContentInputGate;
- (void)expandPortraitKeyboardToFrame:(CGRect)frame duration:(NSTimeInterval)duration options:(UIViewAnimationOptions)options;
- (void)restorePortraitKeyboardWithDuration:(NSTimeInterval)duration options:(UIViewAnimationOptions)options;
@end
@implementation ZNSFloatingView
- (void)updateContentInputGate {
    self.content.userInteractionEnabled=!self.portraitKeyboardVisualRestoring;
    if (!self.portraitKeyboardVisualRestoring) {
        assert(CGAffineTransformIsIdentity(self.bodyBackground.transform));
        assert(CGAffineTransformIsIdentity(self.content.transform));
        assert(CGAffineTransformIsIdentity(self.canvasContainer.transform));
    }
}
- (void)layoutIfNeeded {
    if (self.portraitKeyboardVisualRestoring || self.session.znsPortraitRestorePending) return;
    self.layouts++; self.lastLayoutCanvas=self.session.canvasSize;
    assert(CGSizeEqualToSize(self.session.canvasSize,self.session.hostView.referenceSize));
    assert(CGSizeEqualToSize(self.session.canvasSize,self.session.keyboardPlacement.canvas));
    self.bodyBackground.frame=self.portraitKeyboardExpanded?self.bounds:ZNSMainBody(self.bounds);
    self.content.frame=self.portraitKeyboardExpanded?self.bounds:ZNSMainContent(self.bounds);
    CGSize canvas=self.session.canvasSize;
    self.canvasContainer.bounds=(CGRect){CGPointZero,canvas};
    CGRect fitted=ZNSPortraitFittedCanvas(self.content.bounds,canvas);
    CGFloat scale=fitted.size.width/canvas.width;
    self.canvasContainer.transform=self.portraitKeyboardExpanded?ZNSPortraitCanvasTransform():CGAffineTransformMakeScale(scale,scale);
    self.canvasContainer.center=CGPointMake(CGRectGetMidX(self.content.bounds),CGRectGetMidY(self.content.bounds));
}
#include "../Sources/ZNSPortraitFloating.inc"
@end
@interface ZNSWindowManager : NSObject
@property(nonatomic) BOOL enabled;
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic,strong) ZNSFloatingView *floating;
@property(nonatomic,strong) NSArray<ZNSFloatingView *> *windows;
- (void)portraitKeyboardGeometryChanged:(NSNotification *)notification;
- (void)portraitKeyboardWillHideVisual:(NSNotification *)notification;
@end
@implementation ZNSWindowManager
#include "../Sources/ZNSPortraitManager.inc"
@end
static ZNSWindowManager *Manager(ZNSKeyboardPlacement **placement) {
    ZNSMockPhase=101; ZNSMockResponse=0; ZNSMockExpected=0; ZNSMockLive=2;
    ZNSWindowManager *m=[ZNSWindowManager new]; m.enabled=YES; m.window=[UIWindow new];
    UIView *root=[UIView new]; root.bounds=CGRectMake(0,0,390,844); root.safeAreaInsets=(UIEdgeInsets){47,0,34,0};
    ZNSFloatingView *v=[ZNSFloatingView new]; v.ready=YES; v.frame=CGRectMake(50,180,290,560); v.expandedFrame=v.frame;
    v.superview=root; v.window=m.window; v.session=New(); v.session.bundleIdentifier=@"test.owned.app";
    v.content=[UIView new]; v.bodyBackground=[UIView new]; v.canvasContainer=[UIView new];
    v.toolbar=[UIView new]; v.topBar=[UIView new]; v.bottomBar=[UIView new];
    v.content.superview=v; v.bodyBackground.superview=v; v.canvasContainer.superview=v.content;
    m.floating=v; m.windows=@[v];
    ZNSKeyboardPlacement *p=[ZNSKeyboardPlacement new]; p.canvas=v.session.canvasSize;
    p.portraitExpansion=YES; p.active=YES; p.attached=YES; p.host=[UIView new]; p.host.window=m.window;
    p.portraitKeyboardFrame=CGRectMake(0,510,390,334); v.session.keyboardPlacement=p;
    p.bundleIdentifier=v.session.bundleIdentifier; p.clientPID=42;
    v.content.superview=v;
    [NSNotificationCenter.defaultCenter addObserver:m selector:@selector(portraitKeyboardWillHideVisual:)
        name:ZNSPortraitKeyboardWillHideVisualNotification object:p];
    [v layoutIfNeeded];
    *placement=p; return m;
}
#include "../Sources/ZNSPortraitVisibilityEvent.inc"
static void Publish(ZNSWindowManager *m,ZNSKeyboardPlacement *p,BOOL ended) {
    static ZNSWindowManager *lastManager;
    static NSDictionary *previous;
    static ZNSKeyboardPlacement *previousOwner;
    if (m!=lastManager) { lastManager=m; previous=nil; previousOwner=nil; }
    NSDictionary *current=[p znsPortraitPresentationEligible]?
        @{@"bundle":p.bundleIdentifier,@"frame":[NSValue valueWithCGRect:p.portraitKeyboardFrame],
          @"window":m.window,@"continuity":@([p znsPortraitKeyboardContinuity]),
          @"duration":@(p.presentationTimingKnown?p.presentationDuration:0.25),
          @"options":@(p.presentationOptions)}:nil;
    BOOL continuity=!current && previous && p==previousOwner &&
        [p.bundleIdentifier isEqual:previous[@"bundle"]] && [p znsPortraitKeyboardContinuity];
    NSDictionary *restore=ZNSPortraitRestoreTiming?:
        @{@"ended":@(ended),@"duration":@0.25,@"options":@0};
    NSDictionary *info=ZNSPortraitVisibilityEvent(current,previous,restore,continuity);
    if (current) previousOwner=p;
    if (!continuity) previous=current;
    [m portraitKeyboardGeometryChanged:[NSNotification notificationWithName:@"test" object:nil userInfo:info]];
}
#include "PortraitVisualTests.inc"
#include "PortraitHideRetryTests.inc"
#include "PortraitHiddenProofTests.inc"
#include "PortraitHiddenSurfaceTests.inc"
int main(void) { @autoreleasepool {
    assert(ZNSSceneTestsMain()==0);
    ZNSAnimationEnds=[NSMutableArray new];
    ZNSReady=[NSMutableArray new]; ZNSDeadlines=[NSMutableArray new];
    ZNSKeyboardPlacement *p; ZNSWindowManager *m=Manager(&p); ZNSFloatingView *v=m.floating;
    CGRect original=v.frame,expanded=CGRectMake(0,152,390,692);
    // Regression: verified surface arrives BEFORE the asynchronous App shown.
    assert(!p.clientKeyboardShown && !p.clientVisibilityKnown);
    ZNSKeyboardPlacement *initial=p;
    v.session.hostView.onConfigure=^{
        assert(initial.portraitCanvasTransitionUntil>ZNSNow);
        initial.attached=NO; // synchronous native setter/reparent callback
        assert([initial znsDeferPortraitSystemHide]);
        [initial znsApplyNativeShowResult:NO inputPresent:YES];
        assert(!initial.keyboardHidden);
    };
    Publish(m,p,NO);
    assert(v.portraitKeyboardExpanded && CGRectEqualToRect(v.frame,expanded));
    assert(!p.attached && [p znsPortraitPresentationEligible]);
    assert(CGSizeEqualToSize(v.session.canvasSize,expanded.size));
    NSUInteger restores=p.restores,animations=ZNSAnimations;
    // The scene update temporarily invalidates window/canvas geometry. This
    // used to restore, publish nil, collapse the scene and suppress re-entry.
    [p znsAcceptClientGeometry:CGRectZero canvas:CGSizeZero valid:NO focused:YES];
    Publish(m,p,NO);
    assert(p.restores==restores && v.portraitKeyboardExpanded && ZNSAnimations==animations);
    assert([p.lastReason isEqual:@"P3_GEOMETRY_PENDING"]);
    // Old-canvas reply is not an acknowledgment of the new scene dimensions.
    [p znsAcceptClientGeometry:CGRectMake(0,510,390,334) canvas:CGSizeMake(390,844) valid:YES focused:YES];
    assert(p.restores==restores && [p.lastReason isEqual:@"P3_GEOMETRY_OLD_CANVAS"]);
    // Our reparent's SpringBoard hide is not App hide. Ownership still required.
    assert([p znsDeferPortraitSystemHide]);
    ZNSInput=NO; assert(![p znsDeferPortraitSystemHide]); ZNSInput=YES;
    ZNSFocus=NO; assert(![p znsDeferPortraitSystemHide] && ![p znsPortraitPresentationEligible]); ZNSFocus=YES;
    Ack(v.session); assert(!v.session.temporaryPortraitPending);
    [p znsAcceptClientGeometry:CGRectMake(0,358,390,334) canvas:CGSizeMake(390,692) valid:YES focused:YES];
    assert(p.clientKeyboardShown && !p.keyboardHidden);
    // Transport mock: UIKit has remounted the SAME ownership-proven surface.
    // No assertion below purports to test private render-server behavior.
    p.attached=YES;
    ZNSNow+=2;
    for(unsigned i=0;i<8;i++) Publish(m,p,NO);
    assert(v.portraitKeyboardExpanded && CGRectEqualToRect(v.frame,expanded));
    assert(ZNSAnimations==animations);
    // Temporary invalid sample with a visible attachment MUST NOT reparent it.
    restores=p.restores;
    [p znsAcceptClientGeometry:CGRectZero canvas:CGSizeZero valid:NO focused:YES];
    assert(p.attached && p.restores==restores);
    // Existing UIKit show/setFrame hooks detach before reconciliation. Their
    // actual production helper must retain the proven presentation as well.
    [p znsReparentForNativeKeyboardUpdate];
    assert(!p.attached && [p znsPortraitPresentationEligible]);
    Publish(m,p,NO); assert(v.portraitKeyboardExpanded && ZNSAnimations==animations);
    p.attached=YES;
    // A shown latch survives prolonged editing and repeated reparent loss; the
    // bounded refresh grace is no longer allowed to collapse a visible keyboard.
    assert(p.portraitKeyboardVisibleLatch); p.portraitCanvasTransitionUntil=0;
    p.attached=NO; ZNSNow+=30;
    assert([p znsPortraitPresentationEligible]);
    Publish(m,p,NO); assert(v.portraitKeyboardExpanded && ZNSAnimations==animations);
    // WillHide must NOT enter manager/scene restoration from a native setter.
    // DidHide uses the existing queued visibility publication (Publish here
    // models delivery only; private UIKit/rendering is not tested).
    p.attached=YES;
    p.presentationDuration=0.37; p.presentationOptions=7UL<<16; p.presentationTimingKnown=YES;
    NSUInteger updates=v.session.scene.updates,layouts=v.layouts;
    [p znsAcceptClientPhase:ZNSClientKeyboardWillHide];
    assert(p.clientKeyboardWillHide && v.portraitKeyboardExpanded);
    assert(v.session.scene.updates==updates && p.attached);
    Publish(m,p,NO);
    assert(v.portraitKeyboardExpanded && v.session.scene.updates==updates);
    [p znsAcceptClientPhase:ZNSClientKeyboardWillHide];
    [p znsAcceptClientGeometry:CGRectMake(0,358,390,334) canvas:p.canvas valid:YES focused:YES];
    assert(p.clientKeyboardWillHide && p.attached);
    // Native cancellation: shown after WillHide keeps the same presentation.
    [p znsAcceptClientPhase:ZNSClientKeyboardShown];
    assert(!p.clientKeyboardWillHide && v.portraitKeyboardExpanded);
    [p znsAcceptClientPhase:ZNSClientKeyboardWillHide];
    __weak ZNSFloatingView *weakFloating=v;
    v.session.hostView.onConfigure=^{
        ZNSFloatingView *view=weakFloating;
        assert(view.portraitKeyboardExpanded && CGRectEqualToRect(view.frame,expanded));
        assert(view.layouts==layouts); // no old-canvas layout before restore
        [view restorePortraitKeyboardWithDuration:0.4 options:0]; // reentry ignored
    };
    ConfirmHidden(p);
    Publish(m,p,YES);
    assert(v.session.znsPortraitRestorePending && v.portraitKeyboardExpanded);
    ClientLayout(v.session);
    assert(!v.portraitKeyboardExpanded && CGRectEqualToRect(v.frame,original));
    assert(v.session.scene.updates==updates+1 && !v.session.scene.lastContext);
    assert(v.layouts==layouts+1 && CGSizeEqualToSize(v.lastLayoutCanvas,CGSizeMake(390,844)));
    assert(!v.portraitKeyboardRestoring); Drain(ZNSAnimationEnds); assert(!v.portraitKeyboardRestoring);
    ConfirmHidden(p); Publish(m,p,YES);
    assert(v.session.scene.updates==updates+1);
    Ack(v.session); Original(v.session);
    // Real App did-hide wins even during a geometry refresh and before a scene ack.
    [p znsBeginPortraitGeometryRefresh];
    ConfirmHidden(p); Publish(m,p,YES); Ack(v.session);
    assert(!v.portraitKeyboardExpanded && !v.portraitKeyboardSuppressed);
    assert(CGRectEqualToRect(v.frame,original)); Original(v.session);
    assert(![p znsPortraitPresentationEligible] && !p.portraitCanvasTransitionUntil);
    // keyboard6: run the PRODUCTION event classifier and manager on the same
    // PID-shown owner; host loss, in-flight layout and invalid conversion are
    // unknown, not hide. DidHide still restores the frame and native canvas.
    {
        ZNSKeyboardPlacement *q; ZNSWindowManager *n=Manager(&q); ZNSFloatingView *w=n.floating;
        CGRect narrow=w.frame; Publish(n,q,NO); Ack(w.session);
        [q znsAcceptClientPhase:ZNSClientKeyboardShown];
        assert(w.portraitKeyboardExpanded && [q znsPortraitKeyboardContinuity]);
        q.host.window=nil; Publish(n,q,NO);
        Publish(n,q,YES); // stale restore timing cannot override PID shown
        assert(w.portraitKeyboardExpanded && CGRectEqualToRect(w.frame,expanded) &&
            w.session.temporaryPortraitSettings);
        q.host.window=n.window; Publish(n,q,NO);
        w.session.layoutInFlight=YES; Publish(n,q,NO);
        assert(w.portraitKeyboardExpanded && CGRectEqualToRect(w.frame,expanded));
        w.session.layoutInFlight=NO;
        CGRect bounds=w.superview.bounds; w.superview.bounds=CGRectZero;
        Publish(n,q,NO); assert(w.portraitKeyboardExpanded && w.session.temporaryPortraitSettings);
        w.superview.bounds=bounds; Publish(n,q,NO);
        ConfirmHidden(q); Publish(n,q,YES);
        assert(w.session.znsPortraitRestorePending && w.portraitKeyboardExpanded);
        ClientLayout(w.session);
        assert(!w.portraitKeyboardExpanded && CGRectEqualToRect(w.frame,narrow) &&
            !w.session.temporaryPortraitSettings);
        Ack(w.session); Original(w.session);
        // Focus loss and explicit close must NOT inherit unknown continuity.
        n=Manager(&q); w=n.floating; Publish(n,q,NO); Ack(w.session);
        [q znsAcceptClientPhase:ZNSClientKeyboardShown];
        ZNSFocus=NO; Publish(n,q,NO);
        assert(!w.portraitKeyboardExpanded && !w.session.temporaryPortraitSettings);
        Drain(ZNSAnimationEnds); assert(!w.portraitKeyboardRestoring);
        ZNSFocus=YES; q.host.window=n.window; Publish(n,q,NO); Ack(w.session);
        assert(w.portraitKeyboardExpanded);
        w.closing=YES; q.host.window=nil; Publish(n,q,NO);
        assert(!w.portraitKeyboardExpanded && !w.session.temporaryPortraitSettings);
        Ack(w.session); Original(w.session);
        n=Manager(&q); w=n.floating; Publish(n,q,NO); Ack(w.session);
        [q znsAcceptClientPhase:ZNSClientKeyboardShown];
        n.floating=nil; Publish(n,q,NO);
        assert(!w.portraitKeyboardExpanded && !w.session.temporaryPortraitSettings);
        Ack(w.session); Original(w.session);
    }
    // Event was initially rejected by manager layoutInFlight; unchanged next
    // presentation is retried, not lost forever by geometry-only coalescing.
    m=Manager(&p); v=m.floating; v.session.layoutInFlight=YES;
    Publish(m,p,NO); assert(!v.portraitKeyboardExpanded && !v.portraitKeyboardSuppressed);
    v.session.layoutInFlight=NO; Publish(m,p,NO); assert(v.portraitKeyboardExpanded); Ack(v.session);
    // Lost geometry past the bounded deadline restores safely WITHOUT a new
    // suppression. Once the owned surface returns, the same show can retry.
    ZNSNow+=2; Publish(m,p,NO); assert(!v.portraitKeyboardExpanded && !v.portraitKeyboardSuppressed);
    Drain(ZNSAnimationEnds); assert(!v.portraitKeyboardRestoring);
    p.attached=YES; Publish(m,p,NO); assert(v.portraitKeyboardExpanded); Ack(v.session);
    // Explicit drag/rotate suppression survives transient nil presentation;
    // only a real hide/end clears it for the next input session.
    [v restorePortraitKeyboardWithDuration:0 options:0];
    assert(v.portraitKeyboardSuppressed);
    p.attached=NO; p.portraitCanvasTransitionUntil=0; Publish(m,p,NO);
    assert(v.portraitKeyboardSuppressed);
    p.attached=YES; Publish(m,p,NO); assert(!v.portraitKeyboardExpanded);
    ConfirmHidden(p); Publish(m,p,YES); assert(!v.portraitKeyboardSuppressed);
    Ack(v.session); Drain(ZNSDeadlines); Drain(ZNSReady);
    // Scene rejection does not leave a full-width frame with an old canvas.
    m=Manager(&p); v=m.floating; original=v.frame; v.session.hostView.rejectNext=YES;
    Publish(m,p,NO); assert(!v.portraitKeyboardExpanded && v.portraitKeyboardSuppressed);
    assert(CGRectEqualToRect(v.frame,original)); Ack(v.session); Original(v.session);
    // Preserve external/landscape handling: invalid geometry has its original
    // behavior outside portrait expansion; lifecycle/focus never bypass gates.
    m=Manager(&p); p.portraitExpansion=NO;
    p.clientKeyboardRegion=CGRectMake(0,510,390,334);
    [p znsAcceptClientGeometry:CGRectZero canvas:CGSizeZero valid:NO focused:YES];
    assert(p.restores==1 && ![p znsPortraitPresentationEligible]);
    p.portraitExpansion=YES; p.attached=YES; [p znsBeginPortraitGeometryRefresh]; p.attached=NO;
    p.suspended=YES; assert(![p znsPortraitPresentationEligible]); p.suspended=NO;
    p.invalidated=YES; assert(![p znsPortraitPresentationEligible]); p.invalidated=NO;
    p.active=NO; assert(![p znsPortraitPresentationEligible]); p.active=YES;
    p.host.window=nil; assert(![p znsPortraitPresentationEligible]);
    // Execute the actual restore implementation, including reentrant native
    // detach and transport exception paths; never replace restore with success.
    m=Manager(&p); UIView *surface=[UIView new],*parent=[UIView new],*container=[UIView new];
    p.keyboard=surface; p.originalParent=parent; p.keyboardContainer=container;
    surface.superview=container; p.window=[UIWindow new]; p.window.keyboard=surface;
    __weak ZNSKeyboardPlacement *weakPlacement=p;
    surface.onDetach=^{ [weakPlacement restore]; };
    NSUInteger publications=ZNSVisibilityPublications;
    [p restore];
    assert(surface.superview==parent && !p.keyboard && !p.window && !p.mutating);
    assert(ZNSVisibilityPublications==publications+1);
    p.keyboard=surface; p.originalParent=parent; p.keyboardContainer=container; surface.superview=container;
    surface.onDetach=^{ [NSException raise:@"test.surface.lost" format:@"transport failed"]; };
    [p restore];
    assert(p.invalidated && !p.keyboard && !p.window && !p.mutating);
    assert(ZNSVisibilityPublications==publications+2);
    // A native restoration callback removes a manager window mid-enumeration.
    // The production manager must iterate a stable copy, not mutable windows.
    m=Manager(&p); v=m.floating; Publish(m,p,NO); Ack(v.session);
    m.windows=[@[v,[ZNSFloatingView new]] mutableCopy];
    __weak ZNSWindowManager *weakManager=m;
    v.session.hostView.onConfigure=^{
        ZNSWindowManager *owner=weakManager;
        [(NSMutableArray *)owner.windows removeObject:owner.floating]; owner.floating=nil;
    };
    BOOL enumerationFailed=NO;
    p.active=NO; // lifecycle path stays synchronous, even if DidHide also arrives
    @try { ConfirmHidden(p); Publish(m,p,YES); }
    @catch (__unused NSException *exception) { enumerationFailed=YES; }
    assert(!enumerationFailed && m.windows.count==1 && !m.floating);
    Ack(v.session);
    // Failed restore preserves saved floating geometry for retry instead of
    // clearing it while the scene remains on its expanded canvas.
    m=Manager(&p); v=m.floating; original=v.frame;
    Publish(m,p,NO); Ack(v.session);
    CGRect saved=v.portraitKeyboardSavedFrame;
    v.session.hostView.rejectNext=YES;
    NSUInteger failedAnimations=ZNSAnimations;
    [v restorePortraitKeyboardWithDuration:0.3 options:0];
    assert(v.portraitKeyboardExpanded && CGRectEqualToRect(v.portraitKeyboardSavedFrame,saved));
    assert(v.session.temporaryPortraitSettings && !v.portraitKeyboardRestoring && ZNSAnimations==failedAnimations);
    [v restorePortraitKeyboardWithDuration:0.3 options:0]; Ack(v.session);
    assert(!v.portraitKeyboardExpanded && CGRectEqualToRect(v.frame,original) && v.portraitKeyboardRestoring);
    Drain(ZNSAnimationEnds); assert(!v.portraitKeyboardRestoring && CGRectIsEmpty(v.portraitKeyboardSavedFrame));
    Original(v.session);
    // Legacy explicit force entry preserves timing. Normal DidHide is tested
    // separately below and must never clear before client-size confirmation.
    m=Manager(&p); v=m.floating; original=v.frame; Publish(m,p,NO); Ack(v.session);
    [p znsAcceptClientPhase:ZNSClientKeyboardShown];
    p.presentationDuration=0.28; p.presentationOptions=3UL<<16; p.presentationTimingKnown=YES;
    NSUInteger beforeAnimations=ZNSAnimations,beforeWithout=ZNSWithoutAnimations;
    [v restorePortraitKeyboardWithDuration:0.28 options:3UL<<16];
    NSUInteger restoreAnimation=ZNSAnimations;
    assert(restoreAnimation==beforeAnimations+1 && ZNSWithoutAnimations==beforeWithout);
    assert(fabs(ZNSLastAnimationDuration-0.28)<0.0001);
    assert((ZNSLastAnimationOptions&(3UL<<16))==(3UL<<16));
    assert(ZNSLastAnimationOptions&UIViewAnimationOptionBeginFromCurrentState);
    assert(ZNSLastAnimationOptions&UIViewAnimationOptionAllowUserInteraction);
    assert(!v.session.temporaryPortraitSettings && CGRectEqualToRect(v.frame,original));
    assert(v.frameAnimation==restoreAnimation && v.content.frameAnimation==restoreAnimation);
    assert(v.portraitKeyboardRestoring && !CGRectIsEmpty(v.portraitKeyboardSavedFrame));
    [v restorePortraitKeyboardWithDuration:0.28 options:3UL<<16];
    assert(ZNSAnimations==restoreAnimation && v.portraitKeyboardRestoring);
    Drain(ZNSAnimationEnds);
    assert(!v.portraitKeyboardRestoring && CGRectIsEmpty(v.portraitKeyboardSavedFrame) && CGRectIsEmpty(v.portraitKeyboardTarget));
    // Explicit drag/rotation restores remain immediate and never manufacture an animation.
    m=Manager(&p); v=m.floating; original=v.frame; Publish(m,p,NO); Ack(v.session);
    beforeAnimations=ZNSAnimations; beforeWithout=ZNSWithoutAnimations;
    [v restorePortraitKeyboardWithDuration:0 options:3UL<<16];
    assert(ZNSAnimations==beforeAnimations && ZNSWithoutAnimations==beforeWithout+1);
    assert(!v.portraitKeyboardRestoring && !v.portraitKeyboardExpanded && CGRectEqualToRect(v.frame,original));
    assert(CGRectIsEmpty(v.portraitKeyboardSavedFrame)); Original(v.session);
    VisualTests(); VisualSafetyTests(); RestoreOwnershipTests(); LayeredHandoffTests(); HideRetryTests(); HiddenProofTests(); HiddenSurfaceRecoveryTests();
    puts("PASS production event chain: legacy explicit force restore preserves duration/options and completion guard; normal DidHide requires client-size confirmation; zero-duration lifecycle restore and rejection retry remain covered. UIKit/layout transport MOCKED; NOT device verified.");
    return 0;
} }
