#import "ZNSKeyboardPlacement.h"
#import "ZNSKeyboardPolicy.h"
#import "ZNSPrivate.h"
#import "ZNSLayerInput.h"
#import "ZNSKeyboardClient.h"
#import <notify.h>
#import <unistd.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <math.h>
#import <string.h>

@interface ZNSKeyboardRootController : UIViewController
@end
@implementation ZNSKeyboardRootController
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAllButUpsideDown; }
@end

NSNotificationName const ZNSExternalKeyboardVisibilityDidChangeNotification=@"ZNSExternalKeyboardVisibilityDidChange";

@interface ZNSKeyboardClipView : UIView
@property(nonatomic,strong) UIBezierPath *visiblePath;
@end
@implementation ZNSKeyboardClipView
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return [super pointInside:point withEvent:event] &&
        (!self.visiblePath || [self.visiblePath containsPoint:point]);
}
@end

@interface ZNSKeyboardWindow : UIWindow
@property(nonatomic,weak) UIView *keyboard;
@property(nonatomic,weak) UIView *keyboardContainer;
@property(nonatomic,weak) UIView *dragHandle;
@end
@implementation ZNSKeyboardWindow
- (BOOL)canBecomeKeyWindow { return NO; }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *keyboard=self.keyboard;
    UIView *handle=self.dragHandle,*container=self.keyboardContainer;
    if (handle && !handle.hidden && [handle pointInside:[handle convertPoint:point fromView:self] withEvent:event]) return [super hitTest:point withEvent:event];
    if (!keyboard || keyboard.hidden || keyboard.alpha<0.01 || !container ||
        ![container pointInside:[container convertPoint:point fromView:self] withEvent:event]) return nil;
    return [super hitTest:point withEvent:event];
}
@end

@interface ZNSKeyboardPlacement ()
@property(nonatomic,weak) UIView *host;
@property(nonatomic,weak) id scene;
@property(nonatomic,copy) NSString *bundleIdentifier;
@property(nonatomic,weak) id attachedDelegate;
@property(nonatomic) BOOL independent;
@property(nonatomic) BOOL keyboardHidden;
@property(nonatomic) BOOL clientKeyboardShown;
@property(nonatomic) BOOL clientVisibilityKnown;
@property(nonatomic) CFTimeInterval hiddenAt;
@property(nonatomic) BOOL nativeScreenKeyboard;
@property(nonatomic) NSTimeInterval presentationDuration;
@property(nonatomic) UIViewAnimationOptions presentationOptions;
@property(nonatomic) CFTimeInterval lastDiagnostic;
@property(nonatomic) CFTimeInterval lastRejectionDiagnostic;
@property(nonatomic,copy) NSString *lastRejectionReason;
@property(nonatomic,strong) NSMutableArray *observers;
@property(nonatomic) CGSize canvas;
@property(nonatomic,readwrite) BOOL external;
@property(nonatomic) BOOL portraitExternal;
@property(nonatomic) BOOL landscapeExternal;
@property(nonatomic) BOOL landscapeMove;
@property(nonatomic) UIInterfaceOrientation lastOrientation;
@property(nonatomic) CGSize lastScreenSize;
@property(nonatomic) BOOL active;
@property(nonatomic) BOOL invalidated;
@property(nonatomic) BOOL suspended;
@property(nonatomic) BOOL queued;
@property(nonatomic) BOOL mutating;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic,strong) ZNSKeyboardWindow *window;
@property(nonatomic,strong) UIView *keyboardContainer;
@property(nonatomic,strong) UIView *dragHandle;
@property(nonatomic,weak) UIView *geometryKeyboard;
@property(nonatomic) CGRect geometryBounds;
@property(nonatomic) CGRect geometryContent;
@property(nonatomic,weak) id geometryDelegate;
@property(nonatomic,strong) NSMutableArray<NSNumber *> *clientTokens;
@property(nonatomic) pid_t clientPID;
@property(nonatomic) CGRect clientKeyboardRegion;
@property(nonatomic) CGSize clientKeyboardCanvas;
@property(nonatomic) BOOL dismissPending;
@property(nonatomic) BOOL explicitlyDismissed;
@property(nonatomic) NSUInteger dismissGeneration;
@property(nonatomic) CGAffineTransform presentationTransform;
@property(nonatomic) CGRect contentRect;
@property(nonatomic) CGRect reportedKeyboardFrame;
@property(nonatomic,weak) id frameDelegate;
@property(nonatomic) CGPoint normalizedPosition;
@property(nonatomic) BOOL hasDragged;
@property(nonatomic) CGSize layoutScreenSize;
@property(nonatomic) CGPoint keyboardLayoutCenter;
@property(nonatomic,strong) UIView *keyboard;
@property(nonatomic,weak) UIView *originalParent;
@property(nonatomic) NSUInteger originalIndex;
@property(nonatomic) CGRect savedBounds;
@property(nonatomic) CGPoint savedCenter;
@property(nonatomic) CGAffineTransform savedTransform;
@property(nonatomic) UIViewAutoresizing savedAutoresizing;
@property(nonatomic) BOOL savedTranslates;
@property(nonatomic,strong) NSArray<NSLayoutConstraint *> *savedConstraints;
@property(nonatomic) BOOL loggedUnsupported;
- (void)restore;
- (void)reconcile;
- (void)reconcileSafely;
- (void)schedule;
- (void)clearShowProof;
- (void)stopClientObservation;
- (void)observeClient;
- (void)dismissKeyboard;
- (BOOL)layoutKeyboard;
- (BOOL)hasVerifiedAttachment;
- (BOOL)externalKeyboardVisible;
- (BOOL)mixedOrientationFloating;
- (BOOL)keyboardMovable;
@end

static void ZNSPublishKeyboardVisibility(void) {
    // Coalesce restore/re-attach during one UIKit layout; do not re-enter the
    // manager from inside a setFrame/show hook or publish transient detachments.
    static BOOL queued;
    static NSString *lastBundle;
    if (queued) return;
    queued=YES;
    dispatch_async(dispatch_get_main_queue(),^{
        queued=NO;
        NSString *bundle=[ZNSKeyboardPlacement visibleExternalKeyboardBundleIdentifier];
        if ((!lastBundle && !bundle) || [lastBundle isEqualToString:bundle]) return;
        lastBundle=[bundle copy];
        [NSNotificationCenter.defaultCenter postNotificationName:ZNSExternalKeyboardVisibilityDidChangeNotification object:nil];
    });
}

static NSHashTable<ZNSKeyboardPlacement *> *ZNSKeyboardOwners;
static NSHashTable<UIView *> *ZNSKeyboardCandidates;
static NSMapTable<UIView *,id> *ZNSKeyboardDelegates;
static NSMapTable<UIView *,ZNSKeyboardPlacement *> *ZNSKeyboardShowProof;
static Class ZNSKeyboardLayerClass;
static BOOL ZNSCollectKeyboardLayers(UIView *root,NSMutableSet<UIView *> *views);
static void ZNSCaptureKeyboard(UIView *view,id delegate);
static void ZNSProofKeyboard(UIView *view);
static BOOL ZNSKeyboardDelegateOwnsView(id delegate,UIView *view);
static BOOL ZNSKeyboardCandidateOwnership(id delegate,UIView *view,ZNSKeyboardPlacement *owner);
static __weak id ZNSShowingKeyboardDelegate;
static BOOL (*ZNSKeyboardOriginalShow)(id,SEL,id,id,id);
// Only zero-argument, object-returning getters. No KVC, focus requests, XPC
// service construction or mutation of Apple's focus controller is allowed here.
static id ZNSKeyboardObject(id object,NSString *name) {
    SEL sel=NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:sel]) return nil;
    NSMethodSignature *sig=[object methodSignatureForSelector:sel];
    if (sig.numberOfArguments!=2 || sig.methodReturnType[0]!='@') return nil;
    @try { return ((id(*)(id,SEL))objc_msgSend)(object,sel); }
    @catch (__unused NSException *exception) { return nil; }
}
static BOOL ZNSKeyboardInputPresent(id input) {
    SEL sel=NSSelectorFromString(@"isEmpty");
    if (!input || ![input respondsToSelector:sel]) return NO;
    NSMethodSignature *sig=[input methodSignatureForSelector:sel];
    if (sig.numberOfArguments!=2 || (strcmp(sig.methodReturnType,@encode(BOOL)) && strcmp(sig.methodReturnType,"B"))) return NO;
    @try { return !((BOOL(*)(id,SEL))objc_msgSend)(input,sel); }
    @catch (__unused NSException *exception) { return NO; }
}
static id ZNSActiveKeyboardDelegate(void) {
    return ZNSKeyboardObject(NSClassFromString(@"UIKeyboardSceneDelegate"),@"activeKeyboardSceneDelegate");
}
static BOOL ZNSKeyboardMatchesFocus(ZNSKeyboardPlacement *owner) {
    id workspace=ZNSKeyboardObject(NSClassFromString(@"SBMainWorkspace"),@"sharedInstance");
    id focus=ZNSKeyboardObject(ZNSKeyboardObject(workspace,@"keyboardFocusController"),@"externalSceneWithFocus");
    if (!focus || !owner.scene) return NO;
    id bundle=ZNSKeyboardObject(ZNSKeyboardObject(focus,@"clientProcess"),@"bundleIdentifier");
    if (![bundle isKindOfClass:NSString.class] || ![bundle isEqual:owner.bundleIdentifier]) return NO;
    if (focus==owner.scene) return YES;
    id a=ZNSKeyboardObject(focus,@"identifier"),b=ZNSKeyboardObject(owner.scene,@"identifier");
    return [a isKindOfClass:NSString.class] && [b isKindOfClass:NSString.class] && [a length]>0 && [a isEqual:b];
}
static void ZNSKeyboardScheduleOwners(void) {
    for (ZNSKeyboardPlacement *owner in ZNSKeyboardOwners.allObjects) [owner schedule];
}
static BOOL ZNSKeyboardShow(id delegate,SEL cmd,id input,id placement,id scene) {
    if (!NSThread.isMainThread) return ZNSKeyboardOriginalShow(delegate,cmd,input,placement,scene);
    // Restore before UIKit replaces a surface. Always preserve original result.
    for (ZNSKeyboardPlacement *owner in ZNSKeyboardOwners.allObjects) {
        if (owner.keyboard) [owner restore];
        owner.geometryKeyboard=nil; owner.geometryDelegate=nil;
    }
    [ZNSKeyboardDelegates removeAllObjects];
    [ZNSKeyboardShowProof removeAllObjects];
    id previous=ZNSShowingKeyboardDelegate;
    ZNSShowingKeyboardDelegate=delegate;
    BOOL result=NO;
    @try { result=ZNSKeyboardOriginalShow(delegate,cmd,input,placement,scene); }
    @finally { ZNSShowingKeyboardDelegate=previous; }
    // FV's show hook keeps UIKit's call intact. Capture the concrete output
    // after it returns too: creation may not issue setFrame during this call.
    NSMutableSet<UIView *> *created=[NSMutableSet set];
    id nativeWindow=ZNSKeyboardObject(delegate,@"keyboardWindow");
    BOOL complete=YES;
    if ([nativeWindow isKindOfClass:UIWindow.class]) complete=ZNSCollectKeyboardLayers(nativeWindow,created);
    for (NSString *key in @[@"inputView",@"inputAccessoryView",@"keyboardView"]) {
        id root=ZNSKeyboardObject(input,key);
        if ([root isKindOfClass:UIView.class]) complete=ZNSCollectKeyboardLayers(root,created) && complete;
    }
    if (complete && result) for (UIView *view in created) {
        ZNSCaptureKeyboard(view,delegate);
        // Bind the concrete layer to the verified owner, not a global BOOL.
        ZNSProofKeyboard(view);
    }
    static CFTimeInterval lastShowDiagnostic;
    if (CACurrentMediaTime()-lastShowDiagnostic>2) {
        lastShowDiagnostic=CACurrentMediaTime();
        os_log(ZNSLog(),"keyboard show result=%d input=%d window=%d layers=%lu complete=%d; original presentation preserved",result,ZNSKeyboardInputPresent(input),[nativeWindow isKindOfClass:UIWindow.class],(unsigned long)created.count,complete);
    }
    for (ZNSKeyboardPlacement *owner in ZNSKeyboardOwners.allObjects) {
        if (!owner.dismissPending && !owner.explicitlyDismissed && ZNSKeyboardMatchesFocus(owner))
            owner.keyboardHidden=!result || !ZNSKeyboardInputPresent(input);
        [owner schedule];
    }
    return result;
}
static BOOL ZNSKeyboardHookReady;
static void ZNSCaptureKeyboard(UIView *view,id delegate) {
    if (![view isKindOfClass:ZNSKeyboardLayerClass]) return;
    [ZNSKeyboardCandidates addObject:view];
    if (delegate) [ZNSKeyboardDelegates setObject:delegate forKey:view];
}
// FV proves ownership at layer-display time: focused bundle + non-empty live
// inputViews + external mode. Recording the view then lets a later surface
// move keep the same keyboard without re-deriving ownership.
static void ZNSProofKeyboard(UIView *view) {
    id delegate=ZNSShowingKeyboardDelegate?:ZNSActiveKeyboardDelegate();
    if (!ZNSKeyboardDelegateOwnsView(delegate,view)) return;
    for (ZNSKeyboardPlacement *owner in ZNSKeyboardOwners.allObjects) {
        if (ZNSKeyboardMatchesFocus(owner) && owner.external && owner.active &&
            ZNSKeyboardInputPresent(ZNSKeyboardObject(delegate,@"inputViews"))) {
            [ZNSKeyboardShowProof setObject:owner forKey:view];
            return;
        }
    }
}
static BOOL ZNSKeyboardLayerInsideHost(UIView *view,UIView *host) {
    if (!view || !host) return NO;
    // Some remote keyboard surfaces are attached to the App's CA scene tree,
    // not to the delegate's UIWindow. Only this exact host ancestry is proof.
    id candidate=ZNSKeyboardObject(view,@"sceneLayer");
    if (![candidate isKindOfClass:CALayer.class]) return NO;
    CALayer *layer=candidate;
    for (NSUInteger depth=0;layer && depth<64;depth++,layer=layer.superlayer)
        if (layer==host.layer) return YES;
    return NO;
}
static BOOL ZNSKeyboardCandidateOwnership(id delegate,UIView *view,ZNSKeyboardPlacement *owner) {
    // Preserve exact show-time ownership; an unrelated owner's proof wins over
    // any fallback. A remote layer may also prove its current host ancestry.
    ZNSKeyboardPlacement *proven=[ZNSKeyboardShowProof objectForKey:view];
    if (proven && proven!=owner) return NO;
    return proven==owner || ZNSKeyboardDelegateOwnsView(delegate,view) ||
        ZNSKeyboardLayerInsideHost(view,owner.host);
}
static void (*ZNSKeyboardOriginalFrame)(UIView *,SEL,CGRect);
static void (*ZNSKeyboardOriginalMove)(UIView *,SEL);
static ZNSKeyboardPlacement *ZNSOwnerForKeyboard(UIView *view) {
    for (ZNSKeyboardPlacement *owner in ZNSKeyboardOwners) {
        if (owner.keyboard==view) return owner;
        UIView *host=owner.host;
        if (!host) continue;
        UIView *ancestor=view;
        for (NSUInteger i=0;ancestor && i<32;i++,ancestor=ancestor.superview)
            if (ancestor==host) return owner;
    }
    return nil;
}
static void ZNSKeyboardSetFrame(UIView *view,SEL cmd,CGRect frame) {
    // Never change unowned keyboards. UIKit retains its original display path.
    ZNSKeyboardPlacement *owner=NSThread.isMainThread?ZNSOwnerForKeyboard(view):nil;
    BOOL preserve=owner && !owner.mutating && owner.keyboard==view && owner.dismissPending;
    if (owner && !owner.mutating && owner.keyboard==view && !preserve) [owner restore];
    ZNSKeyboardOriginalFrame(view,cmd,frame);
    // A source-canvas frame cannot be used unchanged inside our external crop.
    // During dismissal keep that crop, without a restore/re-attach round trip.
    if (preserve && view.superview==owner.keyboardContainer) [owner layoutKeyboard];
    if (NSThread.isMainThread) {
        ZNSCaptureKeyboard(view,ZNSShowingKeyboardDelegate);
        ZNSProofKeyboard(view);
        ZNSKeyboardScheduleOwners();
    }
}
static void ZNSKeyboardDidMove(UIView *view,SEL cmd) {
    ZNSKeyboardOriginalMove(view,cmd);
    if (!NSThread.isMainThread) return;
    ZNSCaptureKeyboard(view,ZNSShowingKeyboardDelegate);
    ZNSProofKeyboard(view);
    ZNSKeyboardScheduleOwners();
}
static BOOL ZNSKeyboardMethod(Class cls,SEL sel,const char *argument) {
    Method method=class_getInstanceMethod(cls,sel);
    if (!method) return NO;
    NSMethodSignature *sig=[NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    return !strcmp(sig.methodReturnType,@encode(void)) && sig.numberOfArguments==(argument?3:2) &&
        (!argument || !strcmp([sig getArgumentTypeAtIndex:2],argument));
}
static void ZNSInstallKeyboardPlacementHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once,^{
        ZNSKeyboardOwners=[NSHashTable weakObjectsHashTable];
        ZNSKeyboardCandidates=[NSHashTable weakObjectsHashTable];
        ZNSKeyboardDelegates=[NSMapTable weakToWeakObjectsMapTable];
        ZNSKeyboardShowProof=[NSMapTable weakToWeakObjectsMapTable];
        Class delegateClass=NSClassFromString(@"UIKeyboardSceneDelegate");
        SEL show=NSSelectorFromString(@"_showKeyboardWindowForInputViewSet:placement:windowScene:");
        Method method=class_getInstanceMethod(delegateClass,show);
        if (method) {
            NSMethodSignature *sig=[NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
            BOOL valid=sig.numberOfArguments==5 && (!strcmp(sig.methodReturnType,@encode(BOOL)) || !strcmp(sig.methodReturnType,"B"));
            for (NSUInteger i=2;valid && i<5;i++) valid=[sig getArgumentTypeAtIndex:i][0]=='@';
            if (valid) MSHookMessageEx(delegateClass,show,(IMP)ZNSKeyboardShow,(IMP *)&ZNSKeyboardOriginalShow);
        }
        ZNSKeyboardLayerClass=NSClassFromString(@"_UIKeyboardLayerHostView");
        if (!ZNSKeyboardMethod(ZNSKeyboardLayerClass,@selector(setFrame:),@encode(CGRect)) ||
            !ZNSKeyboardMethod(ZNSKeyboardLayerClass,@selector(didMoveToSuperview),NULL)) return;
        MSHookMessageEx(ZNSKeyboardLayerClass,@selector(setFrame:),(IMP)ZNSKeyboardSetFrame,(IMP *)&ZNSKeyboardOriginalFrame);
        MSHookMessageEx(ZNSKeyboardLayerClass,@selector(didMoveToSuperview),(IMP)ZNSKeyboardDidMove,(IMP *)&ZNSKeyboardOriginalMove);
        ZNSKeyboardHookReady=ZNSKeyboardOriginalFrame && ZNSKeyboardOriginalMove;
        os_log(ZNSLog(),"keyboard placement hooks ready=%d; focus services untouched",ZNSKeyboardHookReady);
    });
}
static BOOL ZNSKeyboardVisible(UIView *view) {
    if (!view.window) return NO;
    for (UIView *v=view;v;v=v.superview) if (v.hidden || v.alpha<0.01) return NO;
    return YES;
}
static BOOL ZNSKeyboardDelegateOwnsView(id delegate,UIView *view) {
    if (!delegate || !view.window) return NO;
    if ([ZNSKeyboardDelegates objectForKey:view]==delegate) return YES;
    id keyboardWindow=ZNSKeyboardObject(delegate,@"keyboardWindow");
    if ([keyboardWindow isKindOfClass:UIWindow.class] && view.window==keyboardWindow) return YES;
    id input=ZNSKeyboardObject(delegate,@"inputViews");
    for (NSString *name in @[@"inputView",@"inputAccessoryView",@"keyboardView"]) {
        id container=ZNSKeyboardObject(input,name);
        if ([container isKindOfClass:UIView.class] && [view isDescendantOfView:container]) return YES;
    }
    return NO;
}
static BOOL ZNSFiniteRect(CGRect r) {
    return isfinite(r.origin.x)&&isfinite(r.origin.y)&&isfinite(r.size.width)&&isfinite(r.size.height)&&r.size.width>1&&r.size.height>1;
}
// Discover an already-created keyboard without relying on a future setFrame:
// hook. Call only for the verified active delegate's own keyboard/input roots.
static BOOL ZNSCollectKeyboardLayers(UIView *root,NSMutableSet<UIView *> *views) {
    if (!root) return YES;
    NSMutableArray<UIView *> *pending=[NSMutableArray arrayWithObject:root];
    NSUInteger visited=0;
    while (pending.count && visited++<256) {
        UIView *view=pending.lastObject; [pending removeLastObject];
        if ([view isKindOfClass:ZNSKeyboardLayerClass]) {
            ZNSCaptureKeyboard(view,nil);
            [views addObject:view];
        }
        else [pending addObjectsFromArray:view.subviews];
    }
    return pending.count==0;
}
static pid_t ZNSKeyboardClientPID(ZNSKeyboardPlacement *owner) {
    id process=ZNSKeyboardObject(owner.scene,@"clientProcess");
    id bundle=ZNSKeyboardObject(process,@"bundleIdentifier");
    if (![bundle isKindOfClass:NSString.class] || ![bundle isEqual:owner.bundleIdentifier]) return 0;
    for (NSString *name in @[@"processIdentifier",@"pid"]) {
        SEL sel=NSSelectorFromString(name);
        NSMethodSignature *sig=[process methodSignatureForSelector:sel];
        if (![process respondsToSelector:sel] || sig.numberOfArguments!=2 || strcmp(sig.methodReturnType,@encode(pid_t))) continue;
        @try {
            pid_t pid=((pid_t(*)(id,SEL))objc_msgSend)(process,sel);
            if (pid>0 && pid!=getpid()) return pid;
        } @catch (__unused NSException *exception) { return 0; }
    }
    return 0;
}
@implementation ZNSKeyboardPlacement
+ (ZNSKeyboardPlacement *)visibleExternalOwner {
    if (!NSThread.isMainThread) return nil;
    ZNSKeyboardPlacement *found=nil;
    for (ZNSKeyboardPlacement *owner in ZNSKeyboardOwners.allObjects) {
        if (![owner externalKeyboardVisible]) continue;
        if (found) return nil; // Ambiguous: never choose another App by order.
        found=owner;
    }
    return found;
}
+ (NSString *)visibleExternalKeyboardBundleIdentifier {
    return [[self visibleExternalOwner].bundleIdentifier copy];
}
+ (BOOL)consumeOutsideTapAtPoint:(CGPoint)point inView:(UIView *)view bundleIdentifier:(NSString * __autoreleasing *)identifier {
    if (identifier) *identifier=nil;
    if (!NSThread.isMainThread || !view.window || !isfinite(point.x) || !isfinite(point.y)) return NO;
    ZNSKeyboardPlacement *owner=[self visibleExternalOwner];
    if (!owner || view.window.windowScene!=owner.window.windowScene) return NO;
    for (UIView *region in @[owner.keyboardContainer,owner.dragHandle]) {
        if (!region.hidden && region.alpha>=0.01 &&
            [region pointInside:[region convertPoint:point fromView:view] withEvent:nil]) return NO;
    }
    if (identifier) *identifier=[owner.bundleIdentifier copy];
    [owner dismissKeyboard];
    // A failed/unsupported resign must not accidentally activate a Home icon or
    // park/close a window. This tap was exclusively a keyboard-dismiss request.
    return YES;
}
- (BOOL)hasVerifiedAttachment {
    if (!self.keyboard || !self.originalParent || !self.scene || !self.bundleIdentifier.length) return NO;
    if (self.independent) return self.attachedDelegate && self.attachedDelegate==ZNSActiveKeyboardDelegate() &&
        ZNSKeyboardMatchesFocus(self) && ZNSKeyboardInputPresent(ZNSKeyboardObject(self.attachedDelegate,@"inputViews"));
    return self.host && [self.originalParent isDescendantOfView:self.host];
}
- (BOOL)externalKeyboardVisible {
    return !self.invalidated && !self.suspended && self.active && !self.keyboardHidden &&
        !self.dismissPending && self.external && [self hasVerifiedAttachment] &&
        self.keyboard.superview==self.keyboardContainer && ZNSKeyboardVisible(self.keyboard);
}
- (instancetype)init {
    if ((self=[super init])) {
        ZNSInstallKeyboardPlacementHooks();
        [ZNSKeyboardOwners addObject:self];
        self.observers=[NSMutableArray new];
        __weak typeof(self) weakSelf=self;
        for (NSString *name in @[UIKeyboardWillShowNotification,UIKeyboardWillHideNotification,UIKeyboardDidHideNotification,UIKeyboardWillChangeFrameNotification,UIApplicationWillResignActiveNotification,UIApplicationDidBecomeActiveNotification]) {
            id token=[NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                ZNSKeyboardPlacement *owner=weakSelf;
                if (!owner || owner.invalidated) return;
                BOOL lifecycle=[note.name isEqual:UIApplicationWillResignActiveNotification] || [note.name isEqual:UIApplicationDidBecomeActiveNotification];
                if (lifecycle) {
                    // Notification Center temporarily changes SpringBoard's
                    // activity/focus; it is NOT the owning App dismissing input.
                    // Reconcile may restore while ownership is unavailable, then
                    // recapture the proven live layer when focus comes back.
                    [owner schedule];
                    return;
                }
                BOOL hide=[note.name isEqual:UIKeyboardWillHideNotification] || [note.name isEqual:UIKeyboardDidHideNotification];
                if (!ZNSKeyboardMatchesFocus(owner)) {
                    // A system overlay's hide/frame event cannot clear another
                    // App's visibility proof or poison its next attachment.
                    [owner schedule];
                    return;
                }
                if (owner.dismissPending) {
                    // Keep the external surface in place through will-hide/frame
                    // changes. Only the owning App's did-hide completes dismissal.
                    if (hide) { owner.keyboardHidden=YES; owner.hiddenAt=CACurrentMediaTime(); }
                    return;
                }
                if (owner.explicitlyDismissed && !hide) return;
                if (hide) {
                    owner.keyboardHidden=YES; owner.hiddenAt=CACurrentMediaTime();
                    owner.frameDelegate=nil; owner.reportedKeyboardFrame=CGRectZero;
                    owner.dismissPending=NO; owner.dismissGeneration++;
                    owner.presentationDuration=0;
                    [owner clearShowProof]; [owner restore]; [owner schedule];
                }
                else {
                    // Keep a verified local crop across main-window translation.
                    // A frame notification is a hint, not a reason to move the
                    // attached layer back beneath the floating App's clip chain.
                    id rect=note.userInfo[UIKeyboardFrameEndUserInfoKey];
                    if ([rect isKindOfClass:NSValue.class] && !strcmp([rect objCType],@encode(CGRect)) && ZNSKeyboardMatchesFocus(owner)) {
                        CGRect nextFrame=[rect CGRectValue];
                        if (ZNSFiniteRect(nextFrame) && ZNSFiniteRect(owner.reportedKeyboardFrame) &&
                            !CGSizeEqualToSize(nextFrame.size,owner.reportedKeyboardFrame.size)) {
                            // Emoji/prediction/accessory layout changed; an old
                            // crop is no longer valid. Translation alone is not
                            // a layout change and never triggers this path.
                            [owner restore];
                            owner.geometryKeyboard=nil; owner.geometryDelegate=nil;
                        }
                        owner.reportedKeyboardFrame=nextFrame;
                        owner.frameDelegate=ZNSActiveKeyboardDelegate();
                        NSNumber *duration=note.userInfo[UIKeyboardAnimationDurationUserInfoKey];
                        NSNumber *curve=note.userInfo[UIKeyboardAnimationCurveUserInfoKey];
                        owner.presentationDuration=[duration isKindOfClass:NSNumber.class] && isfinite(duration.doubleValue)?MAX(0,MIN(0.6,duration.doubleValue)):0;
                        NSInteger curveValue=[curve isKindOfClass:NSNumber.class]?curve.integerValue:0;
                        owner.presentationOptions=(UIViewAnimationOptions)((NSUInteger)MAX(0,MIN(7,curveValue))<<16);
                    }
                    owner.keyboardHidden=NO;
                    [owner schedule];
                }
            }];
            [self.observers addObject:token];
        }
    }
    return self;
}
- (void)clearShowProof {
    self.geometryKeyboard=nil; self.geometryDelegate=nil;
    self.geometryBounds=CGRectZero; self.geometryContent=CGRectZero;
    for (UIView *view in ZNSKeyboardShowProof.keyEnumerator.allObjects)
        if ([ZNSKeyboardShowProof objectForKey:view]==self) [ZNSKeyboardShowProof removeObjectForKey:view];
}
- (void)stopClientObservation {
    for (NSNumber *token in self.clientTokens) notify_cancel(token.intValue);
    self.clientTokens=nil; self.clientPID=0;
    self.clientKeyboardRegion=CGRectZero; self.clientKeyboardCanvas=CGSizeZero;
    self.clientVisibilityKnown=NO; self.clientKeyboardShown=NO;
    self.dismissGeneration++; self.dismissPending=NO; self.explicitlyDismissed=NO;
}
- (void)observeClient {
    pid_t pid=ZNSKeyboardClientPID(self);
    if (pid==self.clientPID) return;
    [self stopClientObservation];
    if (!pid || self.invalidated) return;
    self.clientPID=pid; self.clientTokens=[NSMutableArray new];
    __weak typeof(self) weakSelf=self;
    for (NSString *event in @[@"shown",@"hidden",@"hide-finished",@"geometry-changed"]) {
        int token=0;
        NSString *name=ZNSKeyboardClientEvent(pid,event);
        uint32_t status=notify_register_dispatch(name.UTF8String,&token,dispatch_get_main_queue(),^(int unused){
            (void)unused;
            ZNSKeyboardPlacement *owner=weakSelf;
            if (!owner || owner.invalidated || owner.clientPID!=pid || ZNSKeyboardClientPID(owner)!=pid) return;
            BOOL focused=ZNSKeyboardMatchesFocus(owner);
            if ([event isEqualToString:@"hide-finished"]) {
                if (!owner.dismissPending) return;
                owner.dismissPending=NO; owner.dismissGeneration++;
                owner.keyboardHidden=YES; owner.hiddenAt=CACurrentMediaTime();
                owner.clientVisibilityKnown=YES; owner.clientKeyboardShown=NO;
                owner.reportedKeyboardFrame=CGRectZero; owner.frameDelegate=nil;
                [owner clearShowProof]; [owner restore];
                return;
            }
            if (owner.dismissPending) {
                if ([event isEqualToString:@"hidden"]) {
                    owner.keyboardHidden=YES; owner.hiddenAt=CACurrentMediaTime();
                    owner.clientVisibilityKnown=YES; owner.clientKeyboardShown=NO;
                }
                // A transient frame/show while dismissing must not remount it.
                return;
            }
            if ([event isEqualToString:@"geometry-changed"]) {
                if (owner.explicitlyDismissed) return;
                CGRect region=CGRectZero; CGSize canvas=CGSizeZero;
                BOOL valid=ZNSReadClientKeyboardGeometry(pid,&region,&canvas);
                if (!CGRectEqualToRect(region,owner.clientKeyboardRegion) || !CGSizeEqualToSize(canvas,owner.clientKeyboardCanvas)) {
                    [owner restore];
                    owner.geometryKeyboard=nil; owner.geometryDelegate=nil;
                    owner.clientKeyboardRegion=region; owner.clientKeyboardCanvas=canvas;
                }
                if (valid && focused && !owner.dismissPending) {
                    owner.clientVisibilityKnown=YES; owner.clientKeyboardShown=YES; owner.keyboardHidden=NO;
                }
                [owner schedule]; return;
            }
            BOOL hidden=[event isEqualToString:@"hidden"];
            owner.clientVisibilityKnown=YES; owner.clientKeyboardShown=!hidden;
            if (hidden) {
                if (!focused && !owner.keyboard && !owner.dismissPending) return;
                owner.keyboardHidden=YES; owner.hiddenAt=CACurrentMediaTime();
                owner.dismissPending=NO; owner.dismissGeneration++;
                owner.reportedKeyboardFrame=CGRectZero; owner.frameDelegate=nil;
                [owner clearShowProof];
                [owner restore];
            } else {
                // A process notification is only a scheduling hint, never proof
                // of scene/surface ownership. findKeyboard still proves both.
                // Keep the hint across a temporary Notification Center focus
                // loss; the timer will retry only after exact focus returns.
                if (focused && !owner.dismissPending) {
                    owner.explicitlyDismissed=NO;
                    owner.keyboardHidden=NO;
                }
                [owner schedule];
            }
        });
        if (status==NOTIFY_STATUS_OK) [self.clientTokens addObject:@(token)];
    }
}
- (void)dismissKeyboard {
    if (![self externalKeyboardVisible] || self.dismissPending || self.invalidated) return;
    BOOL owned=[self hasVerifiedAttachment];
    pid_t pid=ZNSKeyboardClientPID(self);
    if (!owned || pid<=0 || pid!=self.clientPID) return;
    NSString *name=ZNSKeyboardClientEvent(pid,@"dismiss");
    self.dismissPending=YES; self.explicitlyDismissed=YES;
    NSUInteger generation=++self.dismissGeneration;
    // Do not first put a still-visible keyboard inside the App. Keep its owned
    // surface external until UIKit acknowledges did-hide. No retry timer sends
    // additional dismissal requests or requests focus.
    if (notify_post(name.UTF8String)!=NOTIFY_STATUS_OK) {
        self.dismissPending=NO; self.explicitlyDismissed=NO;
        return;
    }
    __weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.2*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        ZNSKeyboardPlacement *owner=weakSelf;
        if (!owner || owner.dismissGeneration!=generation || owner.invalidated) return;
        owner.dismissPending=NO;
        // On refusal/no acknowledgement leave the live keyboard external. If a
        // hide started, keep automatic overlay recovery suppressed until shown.
        if (!owner.keyboardHidden) owner.explicitlyDismissed=NO;
        [owner schedule];
    });
}
- (void)updateScene:(id)scene bundleIdentifier:(NSString *)identifier {
    if (self.scene!=scene || ![self.bundleIdentifier isEqual:identifier]) {
        [self restore]; [self clearShowProof]; [self stopClientObservation];
        self.keyboardHidden=NO;
        self.frameDelegate=nil; self.reportedKeyboardFrame=CGRectZero;
        self.hasDragged=NO;
    }
    self.scene=scene; self.bundleIdentifier=identifier;
    [self observeClient];
}
- (BOOL)applied {
    return self.external && (self.nativeScreenKeyboard || (self.keyboard && self.keyboard.superview==self.keyboardContainer && !self.window.hidden));
}
- (void)updateHost:(UIView *)host canvas:(CGSize)canvas {
    if (self.host!=host || !CGSizeEqualToSize(self.canvas,canvas)) {
        [self restore]; [self clearShowProof];
        self.frameDelegate=nil; self.reportedKeyboardFrame=CGRectZero;
        self.hasDragged=NO;
    }
    self.host=host; self.canvas=canvas; self.suspended=NO;
    [self schedule];
}
- (void)configurePortraitExternal:(BOOL)portrait landscapeExternal:(BOOL)landscape move:(BOOL)move {
    self.portraitExternal=portrait; self.landscapeExternal=landscape;
    self.landscapeMove=move;
    if (!move && ![self mixedOrientationFloating]) self.hasDragged=NO;
    [self reconcileSafely];
}
- (BOOL)deviceLandscape {
    UIInterfaceOrientation orientation=self.host.window.windowScene.interfaceOrientation;
    if (orientation!=UIInterfaceOrientationUnknown) return UIInterfaceOrientationIsLandscape(orientation);
    CGSize size=self.host.window.bounds.size;
    return size.width>size.height;
}
- (BOOL)mixedOrientationFloating {
    // The canvas is the App's unscaled scene, not the resized window frame.
    // Unknown/transitioning host geometry must not opt into this mode.
    CGSize screen=self.host.window.bounds.size;
    if (!self.active || self.suspended || !self.host.window ||
        !isfinite(screen.width) || !isfinite(screen.height) ||
        screen.width<=0 || screen.height<=0 ||
        !isfinite(self.canvas.width) || !isfinite(self.canvas.height) ||
        self.canvas.width<=0 || self.canvas.height<=0) return NO;
    BOOL deviceLandscape=[self deviceLandscape];
    BOOL portraitDeviceLandscapeApp=!deviceLandscape && screen.height>screen.width &&
        self.canvas.width>self.canvas.height;
    BOOL landscapeDevicePortraitApp=deviceLandscape && screen.width>screen.height &&
        self.canvas.height>self.canvas.width;
    return portraitDeviceLandscapeApp || landscapeDevicePortraitApp;
}
- (BOOL)keyboardMovable {
    return self.external && ([self mixedOrientationFloating] ||
        ZNSKeyboardCanMove([self deviceLandscape],self.external,self.landscapeMove));
}
- (void)setPlacementActive:(BOOL)active {
    self.active=active;
    if (!active) { [self clearShowProof]; [self restore]; }
    if (active && !self.invalidated && !self.timer) {
        __weak typeof(self) weakSelf=self;
        self.timer=[NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
            ZNSKeyboardPlacement *owner=weakSelf;
            if (!owner) { [timer invalidate]; return; }
            [owner reconcileSafely];
        }];
        [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    } else if (!active) {
        [self.timer invalidate]; self.timer=nil;
    }
    [self schedule];
}
- (void)suspend { self.suspended=YES; [self clearShowProof]; [self restore]; }
- (void)schedule {
    if (self.queued || self.invalidated || self.mutating) return;
    self.queued=YES;
    __weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_main_queue(),^{
        ZNSKeyboardPlacement *owner=weakSelf;
        owner.queued=NO; [owner reconcileSafely];
    });
}
- (void)restore {
    if (self.mutating) return;
    self.mutating=YES;
    self.nativeScreenKeyboard=NO;
    [self.keyboardContainer.layer removeAllAnimations];
    [self.dragHandle.layer removeAllAnimations];
    UIView *keyboard=self.keyboard,*parent=self.originalParent;
    self.window.hidden=YES; self.window.keyboard=nil;
    // If UIKit took the view elsewhere already, do not steal it back or write
    // stale geometry into a new presentation. Only undo our own attachment.
    @try {
    if (keyboard && (keyboard.superview==self.keyboardContainer || !keyboard.superview)) {
        [keyboard removeFromSuperview];
        keyboard.transform=self.savedTransform;
        keyboard.bounds=self.savedBounds; keyboard.center=self.savedCenter;
        keyboard.autoresizingMask=self.savedAutoresizing;
        keyboard.translatesAutoresizingMaskIntoConstraints=self.savedTranslates;
        if (parent) {
            [parent insertSubview:keyboard atIndex:MIN(self.originalIndex,parent.subviews.count)];
            [NSLayoutConstraint activateConstraints:self.savedConstraints?:@[]];
        }
        os_log(ZNSLog(),"keyboard external attachment restored parentAlive=%d",parent!=nil);
    }
    } @catch (NSException *exception) {
        self.invalidated=YES;
        [self.timer invalidate]; self.timer=nil;
        os_log_error(ZNSLog(),"keyboard restore exception=%{public}@; placement disabled for this session",exception.name);
    } @finally {
        self.keyboard=nil; self.originalParent=nil;
        self.window=nil; self.keyboardContainer=nil; self.dragHandle=nil;
        self.savedConstraints=nil;
        self.attachedDelegate=nil; self.independent=NO;
        self.mutating=NO;
        ZNSPublishKeyboardVisibility();
    }
}
- (void)rejectExternal:(NSString *)reason {
    CFTimeInterval now=CACurrentMediaTime();
    BOOL same=[self.lastRejectionReason isEqualToString:reason];
    if (now-self.lastRejectionDiagnostic<(same?8:1)) return;
    self.lastRejectionDiagnostic=now; self.lastRejectionReason=reason;
    // Reasons are fixed internal labels, never App identifiers or typed text.
    os_log(ZNSLog(),"keyboard external rejected reason=%{public}@ external=%d active=%d suspended=%d hidden=%d dismiss=%d hooks=%d hostWindow=%d focus=%d clientKnown=%d clientShown=%d",reason,self.external,self.active,self.suspended,self.keyboardHidden,self.dismissPending,ZNSKeyboardHookReady,self.host.window!=nil,ZNSKeyboardMatchesFocus(self),self.clientVisibilityKnown,self.clientKeyboardShown);
}
- (UIView *)findKeyboard {
    // Bounded traversal of our own scene only; never scan another App/window.
    NSMutableArray<UIView *> *pending=[NSMutableArray arrayWithObject:self.host];
    UIView *found=nil;
    NSUInteger visited=0;
    while (pending.count && visited++<192) {
        UIView *view=pending.lastObject; [pending removeLastObject];
        if ([view isKindOfClass:ZNSKeyboardLayerClass] && ZNSKeyboardVisible(view)) {
            if (found) { [self rejectExternal:@"host-multiple-keyboard-surfaces"]; return nil; }
            found=view;
        } else [pending addObjectsFromArray:view.subviews];
    }
    if (pending.count) { [self rejectExternal:@"host-traversal-limit"]; return nil; }
    if (found) { self.independent=NO; self.attachedDelegate=nil; return found; }
    id delegate=ZNSActiveKeyboardDelegate();
    BOOL focused=ZNSKeyboardMatchesFocus(self);
    if (focused && ZNSKeyboardInputPresent(ZNSKeyboardObject(delegate,@"inputViews"))) {
        NSMutableSet<UIView *> *candidates=[NSMutableSet setWithArray:ZNSKeyboardCandidates.allObjects];
        id keyboardWindow=ZNSKeyboardObject(delegate,@"keyboardWindow");
        if ([keyboardWindow isKindOfClass:UIWindow.class] &&
            !ZNSCollectKeyboardLayers(keyboardWindow,candidates)) {
            [self rejectExternal:@"delegate-window-traversal-limit"]; return nil;
        }
        id input=ZNSKeyboardObject(delegate,@"inputViews");
        for (NSString *name in @[@"inputView",@"inputAccessoryView",@"keyboardView"]) {
            id root=ZNSKeyboardObject(input,name);
            if ([root isKindOfClass:UIView.class] && !ZNSCollectKeyboardLayers(root,candidates)) {
                [self rejectExternal:@"delegate-input-traversal-limit"]; return nil;
            }
        }
        for (UIView *view in candidates) {
            if (!ZNSKeyboardVisible(view) || [ZNSOwnerForKeyboard(view) keyboard]==view) continue;
            BOOL owned=ZNSKeyboardCandidateOwnership(delegate,view,self);
            // Only a show-time proven view, or one the active delegate owns
            // now, is taken. Loose candidates stay native.
            if (!focused || !delegate || !owned) continue;
            if (found) { [self rejectExternal:@"delegate-multiple-keyboard-surfaces"]; return nil; }
            found=view;
        }
    }
    if (found) { self.independent=YES; self.attachedDelegate=delegate; }
    else {
        NSString *reason=!focused?@"scene-focus-not-matched":!delegate?@"active-delegate-missing":
            !ZNSKeyboardInputPresent(ZNSKeyboardObject(delegate,@"inputViews"))?@"delegate-input-empty-or-unsupported":@"no-visible-owned-surface";
        [self rejectExternal:reason];
        if (CACurrentMediaTime()-self.lastDiagnostic>8) {
            self.lastDiagnostic=CACurrentMediaTime();
            NSUInteger visible=0,delegateOwned=0,showProven=0;
            for (UIView *candidate in ZNSKeyboardCandidates.allObjects) {
                if (ZNSKeyboardVisible(candidate)) visible++;
                if (ZNSKeyboardDelegateOwnsView(delegate,candidate)) delegateOwned++;
                if ([ZNSKeyboardShowProof objectForKey:candidate]==self) showProven++;
            }
            os_log(ZNSLog(),"keyboard candidate unresolved focusMatch=%d delegate=%d input=%d candidates=%lu visible=%lu delegateOwned=%lu showProven=%lu showHook=%d; native placement retained",focused,delegate!=nil,ZNSKeyboardInputPresent(ZNSKeyboardObject(delegate,@"inputViews")),(unsigned long)ZNSKeyboardCandidates.count,(unsigned long)visible,(unsigned long)delegateOwned,(unsigned long)showProven,ZNSKeyboardOriginalShow!=NULL);
        }
    }
    return found;
}
- (CGRect)inputSwitcherContentRect {
    if(!self.keyboard || ![self hasVerifiedAttachment] || !ZNSKeyboardMatchesFocus(self)) return CGRectNull;
    // Prefer a concrete menu in this exact owned surface; never search unrelated
    // SpringBoard windows and assume that their menus belong to this App.
    Class cls=NSClassFromString(@"UIInputSwitcherView");
    NSMutableArray<UIView *> *pending=[NSMutableArray arrayWithArray:self.keyboard.subviews];
    UIView *menu=nil; NSUInteger budget=512;
    while(pending.count && budget) {
        --budget;
        UIView *view=pending.lastObject; [pending removeLastObject];
        if(view.hidden || view.alpha<0.01) continue;
        if(cls && [view isKindOfClass:cls]) {
            if(menu) return CGRectNull;
            menu=view;
        } else [pending addObjectsFromArray:view.subviews];
    }
    if(pending.count) return CGRectNull;
    if(menu) {
        CGRect rect=[menu convertRect:menu.bounds toView:self.keyboard];
        return ZNSFiniteRect(rect)?rect:CGRectNull;
    }
    // Remote surfaces have no local menu UIView. Require the current App's
    // fresh geometry and an exact match to its full unscaled source canvas.
    CGRect rect=CGRectZero; CGSize canvas=CGSizeZero;
    if(self.clientPID<=0 || self.clientPID!=ZNSKeyboardClientPID(self) ||
       !ZNSReadClientKeyboardMenuGeometry(self.clientPID,&rect,&canvas) ||
       fabs(canvas.width-self.canvas.width)>1 || fabs(canvas.height-self.canvas.height)>1 ||
       fabs(canvas.width-self.savedBounds.size.width)>1 || fabs(canvas.height-self.savedBounds.size.height)>1) return CGRectNull;
    return CGRectOffset(rect,self.savedBounds.origin.x,self.savedBounds.origin.y);
}
- (BOOL)layoutKeyboard {
    UIView *keyboard=self.keyboard;
    if (!keyboard || !self.window || !self.keyboardContainer) return NO;
    CGRect extent=CGRectApplyAffineTransform(self.contentRect,self.presentationTransform);
    CGRect screen=self.host.window.bounds;
    if (!ZNSFiniteRect(extent)||!ZNSFiniteRect(screen)) return NO;
    // Full width at the device bottom. A narrow split window's keyboard is
    // scaled to the screen width; if that overflows the usable screen height,
    // shrink it proportionally and center it above the bottom instead of
    // failing back into the App window.
    BOOL floating=[self mixedOrientationFloating];
    UIEdgeInsets safe=self.host.window.safeAreaInsets;
    // This mixed-orientation mode leaves horizontal travel space and reserves
    // the notch, home indicator and the handle. Other modes keep their sizing.
    CGFloat left=floating?safe.left+12:0;
    CGFloat right=floating?safe.right+12:0;
    CGFloat bottom=floating?safe.bottom+12:0;
    CGFloat availableWidth=screen.size.width-left-right;
    CGFloat targetWidth=floating?availableWidth*0.86:screen.size.width;
    CGFloat scale=targetWidth/extent.size.width;
    CGFloat height=extent.size.height*scale;
    CGFloat maxTop=safe.top;
    CGFloat usable=screen.size.height-maxTop-44-bottom;
    if (!isfinite(scale)||scale<=0 || height<=0 || usable<=0) return NO;
    if (height>usable) { scale*=usable/height; height=usable; }
    if (extent.size.width*scale>availableWidth) { scale=availableWidth/extent.size.width; height=extent.size.height*scale; }
    self.window.frame=CGRectMake(0,0,screen.size.width,screen.size.height);
    UIView *root=self.window.rootViewController.view;
    root.frame=self.window.bounds;
    self.layoutScreenSize=screen.size;
    CGFloat width=extent.size.width*scale;
    CGFloat minX=left+width/2,maxX=screen.size.width-right-width/2;
    CGFloat minY=height/2+safe.top+34,maxY=screen.size.height-bottom-height/2;
    BOOL movable=[self keyboardMovable];
    if (!movable) self.hasDragged=NO;
    CGPoint center=CGPointMake(screen.size.width/2,maxY);
    if (self.hasDragged) center=CGPointMake(self.normalizedPosition.x*screen.size.width,self.normalizedPosition.y*screen.size.height);
    center.x=MAX(minX,MIN(maxX,center.x)); center.y=MAX(minY,MIN(maxY,center.y));
    self.keyboardContainer.bounds=CGRectMake(0,0,width,height);
    self.keyboardContainer.center=center;
    self.dragHandle.hidden=!movable;
    self.dragHandle.userInteractionEnabled=movable;
    self.dragHandle.frame=CGRectMake(center.x-40,center.y-height/2-30,80,28);
    self.mutating=YES;
    CGAffineTransform transform=CGAffineTransformScale(self.presentationTransform,scale,scale);
    keyboard.transform=transform;
    keyboard.bounds=self.savedBounds;
    CGPoint offset=CGPointMake(CGRectGetMidX(self.contentRect)-CGRectGetMidX(self.savedBounds),CGRectGetMidY(self.contentRect)-CGRectGetMidY(self.savedBounds));
    // Apply the linear transform only: translation is already part of UIView's
    // transform and must be compensated separately when positioning the crop.
    CGPoint delta=CGPointMake(transform.a*offset.x+transform.c*offset.y+transform.tx,transform.b*offset.x+transform.d*offset.y+transform.ty);
    keyboard.center=CGPointMake(width/2-delta.x,height/2-delta.y);
    self.keyboardLayoutCenter=center;
    CGRect base=CGRectMake(0,0,width,height),menu=CGRectNull,expanded=base;
    // Extend only the crop, never the keyboard scale or its screen position.
    // Limit this correction to the reported portrait external-keyboard case.
    if(![self deviceLandscape] && !self.dismissPending) {
        CGRect sourceMenu=[self inputSwitcherContentRect];
        if(ZNSFiniteRect(sourceMenu)) {
            CGRect transformedBase=CGRectApplyAffineTransform(self.contentRect,transform);
            menu=CGRectApplyAffineTransform(sourceMenu,transform);
            menu=CGRectOffset(menu,width/2-CGRectGetMidX(transformedBase),height/2-CGRectGetMidY(transformedBase));
            CGRect visible=CGRectMake(-center.x+width/2+safe.left,
                -center.y+height/2+safe.top,screen.size.width-safe.left-safe.right,
                screen.size.height-safe.top-safe.bottom);
            menu=CGRectIntersection(menu,visible);
            if(ZNSFiniteRect(menu)) expanded=CGRectUnion(base,menu);
            else menu=CGRectNull;
        }
    }
    ZNSKeyboardClipView *clip=(ZNSKeyboardClipView *)self.keyboardContainer;
    BOOL hadMenuCrop=clip.layer.mask!=nil;
    if(ZNSFiniteRect(menu)) {
        CGRect localBase=CGRectOffset(base,-expanded.origin.x,-expanded.origin.y);
        CGRect localMenu=CGRectOffset(menu,-expanded.origin.x,-expanded.origin.y);
        UIBezierPath *path=[UIBezierPath bezierPathWithRect:localBase];
        [path appendPath:[UIBezierPath bezierPathWithRect:localMenu]];
        clip.bounds=(CGRect){CGPointZero,expanded.size};
        clip.center=CGPointMake(center.x+CGRectGetMidX(expanded)-width/2,
            center.y+CGRectGetMidY(expanded)-height/2);
        keyboard.center=CGPointMake(keyboard.center.x-expanded.origin.x,keyboard.center.y-expanded.origin.y);
        CAShapeLayer *mask=[CAShapeLayer layer];
        mask.frame=clip.bounds; mask.path=path.CGPath; mask.fillColor=UIColor.blackColor.CGColor;
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        clip.layer.mask=mask; [CATransaction commit];
        clip.visiblePath=path;
    } else {
        clip.layer.mask=nil; clip.visiblePath=nil;
    }
    if(hadMenuCrop!=(clip.layer.mask!=nil))
        os_log(ZNSLog(),"keyboard menu crop active=%d build=%{public}s; base scale and position retained",clip.layer.mask!=nil,APELIN_BUILD_ID);
    self.mutating=NO;
    return YES;
}
- (void)dragKeyboard:(UIPanGestureRecognizer *)pan {
    if (!self.applied || ![self keyboardMovable] ||
        self.layoutScreenSize.width<=0 || self.layoutScreenSize.height<=0) return;
    if (pan.state!=UIGestureRecognizerStateBegan && pan.state!=UIGestureRecognizerStateChanged) return;
    CGPoint translation=[pan translationInView:self.window.rootViewController.view];
    CGPoint center=self.keyboardLayoutCenter;
    self.normalizedPosition=CGPointMake((center.x+translation.x)/self.layoutScreenSize.width,(center.y+translation.y)/self.layoutScreenSize.height);
    self.hasDragged=YES;
    [pan setTranslation:CGPointZero inView:self.window.rootViewController.view];
    [self reconcileSafely];
}
- (void)reconcileSafely {
    @try { [self reconcile]; }
    @catch (NSException *exception) {
        self.mutating=NO;
        self.invalidated=YES;
        [self.timer invalidate]; self.timer=nil;
        [self restore];
        os_log_error(ZNSLog(),"keyboard placement exception=%{public}@; session disabled",exception.name);
    } @finally {
        ZNSPublishKeyboardVisibility();
    }
}
- (void)reconcile {
    if (!NSThread.isMainThread || self.mutating) return;
    UIInterfaceOrientation orientation=self.host.window.windowScene.interfaceOrientation;
    CGSize screenSize=self.host.window.bounds.size;
    BOOL rotated=self.lastScreenSize.width>0 &&
        (orientation!=self.lastOrientation || !CGSizeEqualToSize(screenSize,self.lastScreenSize));
    self.lastOrientation=orientation; self.lastScreenSize=screenSize;
    BOOL landscape=[self deviceLandscape];
    BOOL external=[self mixedOrientationFloating] ||
        ZNSKeyboardExternalForDirection(landscape,self.portraitExternal,self.landscapeExternal);
    if (rotated || external!=self.external) {
        [self restore];
        self.hasDragged=NO;
    }
    if (rotated) {
        // Notification rectangles from the old coordinate space are not reusable.
        [self clearShowProof];
        self.frameDelegate=nil; self.reportedKeyboardFrame=CGRectZero;
    }
    self.external=external;
    if (![self keyboardMovable]) self.hasDragged=NO;
    if (rotated) { [self schedule]; return; }
    if (self.dismissPending) {
        // Freeze only our reparent/layout work, not UIKit input or animation.
        // Losing ownership, leaving the main window, rotation or switching to
        // inner placement still returns the surface immediately.
        BOOL retain=self.external && self.active && !self.suspended && !self.invalidated &&
            self.host.window && self.clientPID==ZNSKeyboardClientPID(self) &&
            ZNSKeyboardMatchesFocus(self) && [self hasVerifiedAttachment];
        if (!retain) [self restore];
        return;
    }
    if (self.keyboardHidden && !self.explicitlyDismissed && self.external && !self.invalidated &&
        self.active && !self.suspended && self.host.window && ZNSKeyboardHookReady &&
        self.clientPID>0 && self.clientPID==ZNSKeyboardClientPID(self) &&
        CACurrentMediaTime()-self.hiddenAt>0.4 && ZNSKeyboardMatchesFocus(self) &&
        ZNSKeyboardInputPresent(ZNSKeyboardObject(ZNSActiveKeyboardDelegate(),@"inputViews"))) {
        // Overlay hide events can set both visibility hints to hidden without
        // a matching App show event on return. Require a currently visible,
        // uniquely owned native surface instead of waiting on that stale hint.
        // No focus request, responder change or old crop is used to recover.
        UIView *liveKeyboard=[self findKeyboard];
        if (liveKeyboard && liveKeyboard.window && ZNSKeyboardVisible(liveKeyboard) &&
            ZNSFiniteRect(liveKeyboard.bounds)) {
            self.keyboardHidden=NO;
        }
    }
    NSString *gate=self.invalidated?@"session-invalidated":self.suspended?@"session-suspended":
        !self.external?@"current-orientation-set-to-inner":!self.active?@"placement-inactive":
        self.dismissPending?@"dismiss-awaiting-hide":self.keyboardHidden?@"keyboard-marked-hidden":
        !ZNSKeyboardHookReady?@"layer-hooks-unavailable":!self.host.window?@"host-window-missing":nil;
    if (gate) { [self rejectExternal:gate]; [self restore]; return; }
    [self observeClient];
    if (self.keyboard) {
        // The source scene may clip/hide its host during a drag or system
        // overlay. That hierarchy is no longer the keyboard's presentation
        // hierarchy. Validate ownership/liveness, not the old parent's alpha
        // or intersection with the floating App's frame.
        if (![self hasVerifiedAttachment]) {
            [self rejectExternal:@"attachment-ownership-lost"]; [self restore]; return;
        }
        if (self.keyboard.superview!=self.keyboardContainer || self.keyboard.hidden || self.keyboard.alpha<0.01) {
            [self rejectExternal:@"attached-surface-moved-or-hidden"]; [self restore]; return;
        }
        if (![self layoutKeyboard]) { [self rejectExternal:@"attached-layout-invalid"]; [self restore]; }
        return;
    }
    self.nativeScreenKeyboard=NO;
    UIView *keyboard=[self findKeyboard];
    if (!keyboard) return; // Discovery already recorded its specific refusal.
    if (!keyboard.superview || !self.host.window.windowScene) {
        [self rejectExternal:@"surface-parent-or-window-scene-missing"]; return;
    }
    CGRect bounds=keyboard.bounds;
    // The App canvas is screen-sized even for a small floating window. Decide
    // from the real surface and a proven keyboard region, not canvas/window ratio.
    BOOL fullScene=self.canvas.height>0 && bounds.size.height>self.canvas.height*0.80;
    CGRect content=bounds;
    BOOL cropped=NO;
    id delegate=self.attachedDelegate?:ZNSActiveKeyboardDelegate();
    // A crop is in surface-local coordinates, never in the moving main window's
    // screen rectangle. Reuse it only for the same concrete layer, bounds and
    // verified delegate; a replacement surface must prove its region anew.
    if (fullScene && self.geometryKeyboard==keyboard && self.geometryDelegate==delegate &&
        CGRectEqualToRect(self.geometryBounds,bounds) && ZNSFiniteRect(self.geometryContent)) {
        content=self.geometryContent; cropped=YES;
    }
    if (fullScene && !cropped && self.clientPID>0 && self.clientPID==ZNSKeyboardClientPID(self) &&
        ZNSKeyboardMatchesFocus(self) && ([keyboard isDescendantOfView:self.host] ||
        ZNSKeyboardCandidateOwnership(delegate,keyboard,self))) {
        CGRect clientRegion=CGRectZero; CGSize clientCanvas=CGSizeZero;
        if (ZNSReadClientKeyboardGeometry(self.clientPID,&clientRegion,&clientCanvas) &&
            fabs(clientCanvas.width-self.canvas.width)<1 && fabs(clientCanvas.height-self.canvas.height)<1 &&
            fabs(clientCanvas.width-bounds.size.width)<1 && fabs(clientCanvas.height-bounds.size.height)<1) {
            // App coordinates already describe the unscaled remote canvas. Do
            // NOT convert through the moving/scaled SpringBoard host window.
            CGRect region=CGRectOffset(clientRegion,bounds.origin.x,bounds.origin.y);
            if (ZNSFiniteRect(region) && CGRectContainsRect(CGRectInset(bounds,-1,-1),region)) {
                content=CGRectIntersection(bounds,region); cropped=YES;
                self.clientKeyboardRegion=clientRegion; self.clientKeyboardCanvas=clientCanvas;
                os_log(ZNSLog(),"keyboard region supplied by App canvas=%.0fx%.0f region=%.0fx%.0f; native input retained",clientCanvas.width,clientCanvas.height,content.size.width,content.size.height);
            }
        }
    }
    if (fullScene && !cropped && ZNSKeyboardMatchesFocus(self)) {
        // A concrete input view from the verified delegate is another native
        // source of geometry. Never guess a transparent surface's lower half.
        id input=ZNSKeyboardObject(delegate,@"inputViews");
        for (NSString *key in @[@"keyboardView",@"inputView"]) {
            id candidate=ZNSKeyboardObject(input,key);
            if (![candidate isKindOfClass:UIView.class]) continue;
            UIView *inputView=candidate;
            if (inputView==keyboard || !inputView.window || inputView.window!=keyboard.window) continue;
            CGRect region=[inputView convertRect:inputView.bounds toView:keyboard];
            if (ZNSFiniteRect(region) && CGRectContainsRect(CGRectInset(bounds,-1,-1),region) &&
                region.size.width*region.size.height<bounds.size.width*bounds.size.height*0.95) {
                content=CGRectIntersection(bounds,region); cropped=YES; break;
            }
        }
    }
    if (fullScene && !cropped && delegate && self.frameDelegate==delegate &&
        ZNSKeyboardMatchesFocus(self) && ZNSFiniteRect(self.reportedKeyboardFrame)) {
        UIWindow *sourceWindow=keyboard.window;
        // The verified surface may live in the App host (UIView or CA tree),
        // rather than delegate.keyboardWindow. Window pointer equality is not
        // an ownership test and used to exclude this supported presentation.
        BOOL owned=[keyboard isDescendantOfView:self.host] ||
            ZNSKeyboardCandidateOwnership(delegate,keyboard,self);
        if (owned && sourceWindow && sourceWindow.screen==self.host.window.screen) {
            // Isolation round 3: restore the historical UIWindow conversion
            // for native notification frames; keep the accepted intersection.
            CGRect inWindow=[sourceWindow convertRect:self.reportedKeyboardFrame fromWindow:nil];
            CGRect region=[keyboard convertRect:inWindow fromView:sourceWindow];
            // A verified native keyboard notification may extend beyond its
            // layer. Retain round 1's finite-intersection acceptance.
            if (ZNSFiniteRect(region)) {
                CGRect visibleRegion=CGRectIntersection(bounds,region);
                if (ZNSFiniteRect(visibleRegion) &&
                    visibleRegion.size.width*visibleRegion.size.height<bounds.size.width*bounds.size.height*0.95) {
                    content=visibleRegion; cropped=YES;
                }
            }
        }
    }
    BOOL compact=ZNSFiniteRect(bounds) && (!fullScene || cropped);
    if (!compact) {
        NSString *reason=!ZNSFiniteRect(bounds)?@"surface-bounds-invalid":
            !ZNSKeyboardMatchesFocus(self)?@"full-surface-without-focus-proof":
            !delegate?@"full-surface-without-delegate":
            !ZNSFiniteRect(self.reportedKeyboardFrame)?@"full-surface-without-keyboard-region":
            self.frameDelegate!=delegate?@"keyboard-region-delegate-mismatch":@"keyboard-region-outside-surface-or-unowned";
        [self rejectExternal:reason];
        if (!self.loggedUnsupported || CACurrentMediaTime()-self.lastDiagnostic>8) {
            self.lastDiagnostic=CACurrentMediaTime();
            os_log(ZNSLog(),"keyboard external region unresolved surface=%.0fx%.0f focus=%d independent=%d frameKnown=%d frameDelegateMatch=%d hostLayerOwned=%d; native retained",bounds.size.width,bounds.size.height,ZNSKeyboardMatchesFocus(self),self.independent,ZNSFiniteRect(self.reportedKeyboardFrame),delegate && self.frameDelegate==delegate,ZNSKeyboardLayerInsideHost(keyboard,self.host));
        }
        self.loggedUnsupported=YES; return;
    }
    self.loggedUnsupported=NO;
    // Keep UIKit's keyboard-surface transform: the user confirmed this fixes
    // reversed orientation. Test notification coordinates independently.
    self.presentationTransform=keyboard.transform;
    self.geometryKeyboard=keyboard; self.geometryDelegate=delegate;
    self.geometryBounds=bounds; self.geometryContent=content;
    NSMutableArray<NSLayoutConstraint *> *constraints=[NSMutableArray new];
    for (UIView *ancestor=keyboard.superview;ancestor;ancestor=ancestor.superview)
        for (NSLayoutConstraint *constraint in ancestor.constraints)
            if (constraint.active && (constraint.firstItem==keyboard || constraint.secondItem==keyboard)) [constraints addObject:constraint];
    self.savedConstraints=constraints;
    self.contentRect=content;
    self.savedBounds=bounds; self.savedCenter=keyboard.center; self.savedTransform=keyboard.transform;
    self.savedAutoresizing=keyboard.autoresizingMask; self.savedTranslates=keyboard.translatesAutoresizingMaskIntoConstraints;
    self.originalParent=keyboard.superview;
    self.originalIndex=[keyboard.superview.subviews indexOfObjectIdenticalTo:keyboard];
    ZNSKeyboardWindow *window=[[ZNSKeyboardWindow alloc] initWithWindowScene:self.host.window.windowScene];
    window.backgroundColor=UIColor.clearColor;
    window.windowLevel=self.host.window.windowLevel+1;
    window.rootViewController=[ZNSKeyboardRootController new];
    window.rootViewController.view.backgroundColor=UIColor.clearColor;
    window.rootViewController.view.accessibilityIdentifier=@"ZNSExternalKeyboardContainer";
    // Render-server hit testing must pass through our empty window/background.
    UIView *container=[ZNSKeyboardClipView new];
    container.clipsToBounds=YES; container.backgroundColor=UIColor.clearColor;
    [window.rootViewController.view addSubview:container];
    UILabel *handle=[UILabel new];
    handle.text=@"━"; handle.textAlignment=NSTextAlignmentCenter;
    handle.textColor=UIColor.whiteColor; handle.backgroundColor=[UIColor.blackColor colorWithAlphaComponent:0.5];
    handle.layer.cornerRadius=12; handle.clipsToBounds=YES; handle.userInteractionEnabled=YES;
    handle.accessibilityLabel=@"移动分屏键盘";
    [handle addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragKeyboard:)]];
    [window.rootViewController.view addSubview:handle];
    // No floating dismiss control. The manager's outside-tap shield calls the
    // consuming API before it performs any pre-existing outside operation.
    NSString *inputFailure=nil;
    if (!ZNSSetLayerInputOpaque(window.layer,NO)) inputFailure=@"window-hit-test-setup-failed";
    else if (!ZNSSetLayerInputOpaque(window.rootViewController.view.layer,NO)) inputFailure=@"root-hit-test-setup-failed";
    else if (!ZNSSetLayerInputOpaque(container.layer,NO)) inputFailure=@"container-hit-test-setup-failed";
    else if (!ZNSSetLayerInputOpaque(handle.layer,YES)) inputFailure=@"drag-handle-hit-test-setup-failed";
    if (inputFailure) {
        [self rejectExternal:inputFailure]; self.originalParent=nil; self.savedConstraints=nil; return;
    }
    self.window=window; self.keyboard=keyboard; window.keyboard=keyboard;
    self.keyboardContainer=container; window.keyboardContainer=container;
    self.dragHandle=handle; window.dragHandle=handle;
    self.mutating=YES;
    [NSLayoutConstraint deactivateConstraints:self.savedConstraints];
    keyboard.translatesAutoresizingMaskIntoConstraints=YES;
    keyboard.autoresizingMask=UIViewAutoresizingNone;
    [keyboard removeFromSuperview];
    [container addSubview:keyboard];
    self.mutating=NO;
    if (![self layoutKeyboard]) { [self rejectExternal:@"initial-external-layout-invalid"]; [self restore]; return; }
    self.lastRejectionReason=nil;
    window.hidden=NO; // Never makeKeyWindow/becomeFirstResponder.
    if (!UIAccessibilityIsReduceMotionEnabled()) {
        CGFloat travel=self.keyboardContainer.bounds.size.height;
        self.keyboardContainer.transform=CGAffineTransformMakeTranslation(0,travel);
        self.dragHandle.transform=CGAffineTransformMakeTranslation(0,travel);
        NSTimeInterval duration=self.presentationDuration>0?self.presentationDuration:0.25;
        [UIView animateWithDuration:duration delay:0 options:self.presentationOptions|UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{
            container.transform=CGAffineTransformIdentity;
            handle.transform=CGAffineTransformIdentity;
        } completion:nil];
    }
    os_log(ZNSLog(),"keyboard externally attached at screen bottom surface=%.0fx%.0f; text delivery unverified",bounds.size.width,bounds.size.height);
}
- (void)invalidate {
    self.invalidated=YES;
    [self stopClientObservation]; [self clearShowProof];
    [self.timer invalidate]; self.timer=nil;
    [self restore]; self.host=nil; self.scene=nil;
    for (id token in self.observers) [NSNotificationCenter.defaultCenter removeObserver:token];
    [self.observers removeAllObjects];
    [ZNSKeyboardOwners removeObject:self];
}
- (void)dealloc {
    for (NSNumber *token in _clientTokens) notify_cancel(token.intValue);
    [_timer invalidate];
    for (id token in _observers) [NSNotificationCenter.defaultCenter removeObserver:token];
}
@end
