#import "ZNSActivationHooks.h"
#import "ZNSSwitcherHooks.h"
#import "ZNSWindowManager.h"
#import "ZNSAuthorization.h"
#import <UIKit/UIKit.h>
#import <UIKit/UIGestureRecognizerSubclass.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <os/log.h>
#import <string.h>

static void (*ZNSOriginalIconHandleTap)(id, SEL);

static BOOL ZNSActivationEnabled;
static BOOL ZNSLeftHoldEnabled;
static BOOL ZNSRightHoldEnabled;
static NSString *ZNSLeftHoldMode = @"main";
static NSString *ZNSRightHoldMode = @"main";
static ZNSWindowActivation *ZNSStatusPreparation;
static NSString *ZNSNotificationOpenMode = @"off";
static NSUInteger ZNSNotificationGeneration;
static __weak id ZNSNotificationTapOwner;
static void (*ZNSOriginalNotificationTap)(id, SEL, id);
static void (*ZNSOriginalNotificationDefault)(id, SEL, BOOL);
static ZNSWindowActivation *ZNSNotificationPreparation;
static char ZNSStatusHoldAssociation;
// Main-thread generation: a new touch or preferences reload invalidates old work.
static NSUInteger ZNSStatusHoldGeneration;
typedef void (*ZNSStatusLifecycleIMP)(id, SEL);
typedef struct {
    __unsafe_unretained Class viewClass;
    ZNSStatusLifecycleIMP originalLayout;
    ZNSStatusLifecycleIMP originalMove;
} ZNSStatusHook;
static ZNSStatusHook ZNSStatusHooks[3];
static UIView *ZNSStatusHoldOwner(UIView *view);
static void ZNSAttachStatusHold(UIView *view);

static os_log_t ZNSActivationLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create(APELIN_PACKAGE_ID, "activation"); });
    return log;
}

// Validate each private message before using its typed objc_msgSend cast. A
// selector existing alone is not enough to assume its ABI on another iOS build.
static BOOL ZNSActivationMethodMatches(id receiver, SEL selector, const char *result,
                                       NSUInteger arguments) {
    if (!receiver || ![receiver respondsToSelector:selector]) return NO;
    NSMethodSignature *signature = [receiver methodSignatureForSelector:selector];
    return signature && signature.numberOfArguments == arguments &&
           strcmp(signature.methodReturnType, result) == 0;
}

static id ZNSActivationObject(id receiver, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (!ZNSActivationMethodMatches(receiver, selector, @encode(id), 2)) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static BOOL ZNSActivationUnlocked(void) {
    id manager = ZNSActivationObject(NSClassFromString(@"SBLockScreenManager"), @"sharedInstance");
    SEL selector = NSSelectorFromString(@"isUILocked");
    if (!ZNSActivationMethodMatches(manager, selector, @encode(BOOL), 2)) return NO;
    return !((BOOL (*)(id, SEL))objc_msgSend)(manager, selector);
}

static NSString *ZNSActivationForegroundBundle(void) {
    if (!ZNSActivationUnlocked()) return nil;
    id application = ZNSActivationObject(UIApplication.sharedApplication,
                                          @"_accessibilityFrontMostApplication");
    Class applicationClass = NSClassFromString(@"SBApplication");
    if (!applicationClass || ![application isKindOfClass:applicationClass]) return nil;
    id bundle = ZNSActivationObject(application, @"bundleIdentifier");
    if (![bundle isKindOfClass:NSString.class] || ![bundle length] ||
        [bundle isEqualToString:@"com.apple.springboard"]) return nil;
    return bundle;
}

static BOOL ZNSHomeReturnAvailable(void) {
    id app=UIApplication.sharedApplication;
    SEL selector=NSSelectorFromString(@"_simulateHomeButtonPressWithCompletion:");
    if (!ZNSActivationMethodMatches(app,selector,@encode(void),3)) return NO;
    return strcmp([[app methodSignatureForSelector:selector] getArgumentTypeAtIndex:2],"@?")==0;
}

static void ZNSReturnHomeForBundle(NSString *bundle) {
    // Do not dismiss a different App, unlock the device, or go Home on failure.
    if (!ZNSActivationEnabled || !ZNSReadAuthorization(YES) || !ZNSHomeReturnAvailable() ||
        ![ZNSActivationForegroundBundle() isEqualToString:bundle]) return;
    @try {
        ((void (*)(id,SEL,id))objc_msgSend)(UIApplication.sharedApplication,
            NSSelectorFromString(@"_simulateHomeButtonPressWithCompletion:"),nil);
        os_log(ZNSActivationLog(),"status hold requested Home after scene readiness");
    } @catch (NSException *exception) {
        os_log_error(ZNSActivationLog(),"Home request failed: %{public}@",exception.name);
    }
}

static BOOL ZNSActivationBool(id receiver,NSString *name) {
    SEL selector=NSSelectorFromString(name);
    if (!ZNSActivationMethodMatches(receiver,selector,@encode(BOOL),2)) return NO;
    return ((BOOL (*)(id,SEL))objc_msgSend)(receiver,selector);
}

static void ZNSIconHandleTap(id object,SEL selector) {
    if (NSThread.isMainThread && ZNSActivationEnabled && ZNSActivationUnlocked() &&
        ZNSActivationBool(UIApplication.sharedApplication,@"isShowingHomescreen") &&
        ZNSActivationBool(object,@"isEnabled") &&
        [object isKindOfClass:UIView.class] && ((UIView *)object).window &&
        [ZNSWindowManager.shared handleDesktopIconTap:object]) return;
    if (ZNSOriginalIconHandleTap) ZNSOriginalIconHandleTap(object,selector);
}

// alpha41 trapped inside SpringBoard's URL-open implementation after the
// expansion completed. Matching Objective-C types does not validate nil URL,
// origin/settings/result semantics; SIGTRAP is not caught by @catch.
// Quarantine both entry points, not just the gesture caller. Do not guess new
// arguments or route around another tweak's chained IMP as a crash workaround.
BOOL ZNSCanOpenFullscreenWithoutAnimation(NSString *bundle) {
    (void)bundle;
    return NO;
}
BOOL ZNSOpenFullscreenWithoutAnimation(NSString *bundle) {
    (void)bundle;
    return NO;
}

static BOOL ZNSActivationReadBool(CFStringRef key, BOOL fallback) {
    id value = CFBridgingRelease(CFPreferencesCopyAppValue(key, CFSTR(APELIN_PACKAGE_ID)));
    return [value isKindOfClass:NSNumber.class] ? [value boolValue] : fallback;
}

static NSString *ZNSStatusReadMode(CFStringRef key) {
    id value=CFBridgingRelease(CFPreferencesCopyAppValue(key,CFSTR(APELIN_PACKAGE_ID)));
    if(!value) return @"main"; // Preserve existing enabled users' main-window route.
    return [value isKindOfClass:NSString.class] &&
        [@[@"off",@"main",@"parked",@"parked2",@"dip"] containsObject:value] ? [value copy] : @"off";
}

// Only ordinary short-look taps in SpringBoard's banner window qualify. The
// default-action hook is scoped to the original tap's stack, never replies,
// action buttons, Notification Center, or an expanded content extension.
static BOOL ZNSNotificationIsBannerTap(id object, id gesture) {
    if (![object isKindOfClass:UIViewController.class] ||
        ![gesture isKindOfClass:UITapGestureRecognizer.class] ||
        ((UITapGestureRecognizer *)gesture).state != UIGestureRecognizerStateRecognized) return NO;
    UIView *view=((UIViewController *)object).viewIfLoaded;
    Class bannerWindow=NSClassFromString(@"SBBannerWindow");
    if (!bannerWindow || ![view.window isKindOfClass:bannerWindow] ||
        view.window.screen!=UIScreen.mainScreen || view.window.hidden) return NO;
    for (UIView *ancestor=view; ancestor; ancestor=ancestor.superview)
        if (ancestor.hidden || ancestor.alpha<0.01) return NO;
    return !ZNSActivationBool(object,@"isCoalescedNotificationBundle") &&
        !ZNSActivationObject(object,@"_presentedLongLookViewController");
}

static BOOL ZNSNotificationRequestCurrent(NSUInteger generation, NSString *mode) {
    return generation==ZNSNotificationGeneration && ZNSActivationEnabled &&
        [mode isEqualToString:ZNSNotificationOpenMode] && ZNSActivationUnlocked() &&
        ZNSReadAuthorization(YES);
}

static BOOL ZNSNotificationForegroundUnchanged(NSString *previous) {
    NSString *front=ZNSActivationForegroundBundle();
    return front==previous || [front isEqualToString:previous];
}

// The selected window route REPLACES the default foreground action. Calling
// that action first starts a workspace fullscreen transaction; rehosting its
// scene afterwards can leave an empty fullscreen surface behind our window.
// Never repair that race with Home (which also dismisses the unrelated App).
// This route opens the App, not the notification's native deep-link response.
// The native banner owns its ordinary lifetime; do not hide its UIWindow or
// synthesize an action/completion merely to dismiss it.
static void ZNSNotificationOpenWindow(NSString *bundle, NSString *mode,
                                      NSString *previous, NSUInteger generation) {
    if (!ZNSNotificationRequestCurrent(generation,mode) ||
        !ZNSNotificationForegroundUnchanged(previous)) return;
    // Do not detach the scene currently used by the fullscreen workspace.
    // Notifications for that same foreground App retain their native action.
    if ([previous isEqualToString:bundle]) return;
    if (![ZNSWindowManager.shared canOpenNotificationBundleIdentifier:bundle mode:mode]) return;
    NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+5.0;
    ZNSNotificationPreparation=[ZNSWindowManager.shared prepareNotificationBundleIdentifier:bundle mode:mode whenReady:^(BOOL ready) {
        if (generation!=ZNSNotificationGeneration) return;
        ZNSWindowActivation *request=ZNSNotificationPreparation;
        ZNSNotificationPreparation=nil;
        if (!ready || !ZNSNotificationRequestCurrent(generation,mode) ||
            NSProcessInfo.processInfo.systemUptime>deadline ||
            !ZNSNotificationForegroundUnchanged(previous)) {
            [request cancel]; return;
        }
        BOOL committed=[request commit];
        if (!committed) [request cancel];
        // No native default-action replay on failure: it would bring back the
        // very fullscreen launch this setting is meant to replace.
        os_log(ZNSActivationLog(),"notification direct window committed=%d; foreground preserved",committed);
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(5.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        if (generation!=ZNSNotificationGeneration) return;
        [ZNSNotificationPreparation cancel]; ZNSNotificationPreparation=nil;
    });
}

static void ZNSNotificationDefault(id object, SEL selector, BOOL animated) {
    if (NSThread.isMainThread && object==ZNSNotificationTapOwner && ZNSActivationEnabled &&
        ![ZNSNotificationOpenMode isEqualToString:@"off"] && ZNSActivationUnlocked() &&
        ZNSReadAuthorization(YES)) {
        id request=ZNSActivationObject(object,@"notificationRequest");
        id identifier=ZNSActivationObject(request,@"sectionIdentifier");
        NSString *previous=ZNSActivationForegroundBundle();
        if ([identifier isKindOfClass:NSString.class] &&
            ![previous isEqualToString:identifier] &&
            ZNSActivationObject(request,@"defaultAction") &&
            [ZNSWindowManager.shared canOpenBundleIdentifier:identifier]) {
            NSString *bundle=[identifier copy], *mode=[ZNSNotificationOpenMode copy];
            NSUInteger generation=++ZNSNotificationGeneration;
            [ZNSNotificationPreparation cancel]; ZNSNotificationPreparation=nil;
            // Consume selected routes even while an existing window is busy.
            // Falling through in that case would activate the hosted App full
            // screen and recreate the black workspace surface.
            dispatch_async(dispatch_get_main_queue(),^{
                ZNSNotificationOpenWindow(bundle,mode,previous,generation);
            });
            return;
        }
    }
    // Disabled, excluded, same-foreground-App and non-banner actions stay native.
    if (ZNSOriginalNotificationDefault) ZNSOriginalNotificationDefault(object,selector,animated);
}

static void ZNSNotificationTap(id object, SEL selector, id gesture) {
    if (!NSThread.isMainThread) {
        if (ZNSOriginalNotificationTap) ZNSOriginalNotificationTap(object,selector,gesture);
        return;
    }
    ++ZNSNotificationGeneration;
    [ZNSNotificationPreparation cancel]; ZNSNotificationPreparation=nil;
    id previous=ZNSNotificationTapOwner;
    ZNSNotificationTapOwner=ZNSNotificationIsBannerTap(object,gesture)?object:nil;
    @try {
        if (ZNSOriginalNotificationTap) ZNSOriginalNotificationTap(object,selector,gesture);
    } @finally { ZNSNotificationTapOwner=previous; }
}

// Do not make a system recognizer fail, cancel the original view's touch, or
// delay delivery. In particular, a short tap still reaches scroll-to-top and a
// moving touch can still start Notification Center / Control Center normally.
@interface ZNSStatusBarHold : UILongPressGestureRecognizer <UIGestureRecognizerDelegate>
@property(nonatomic, copy) NSString *znsCandidateBundle;
@property(nonatomic) BOOL znsLeftSide;
@property(nonatomic) BOOL znsArmed;
@property(nonatomic) CGPoint znsInitialPoint;
@property(nonatomic) NSUInteger znsGeneration;
- (void)znsDidHold:(UILongPressGestureRecognizer *)recognizer;
@end

static NSHashTable<ZNSStatusBarHold *> *ZNSStatusHolds;

@implementation ZNSStatusBarHold
- (instancetype)init {
    self = [super initWithTarget:nil action:NULL];
    if (self) {
        [self addTarget:self action:@selector(znsDidHold:)];
        self.delegate = self;
        self.minimumPressDuration = 0.55;
        self.allowableMovement = 8.0;
        self.numberOfTouchesRequired = 1;
        self.cancelsTouchesInView = NO;
        self.delaysTouchesBegan = NO;
        self.delaysTouchesEnded = NO;
    }
    return self;
}
- (BOOL)canPreventGestureRecognizer:(UIGestureRecognizer *)other {
    (void)other;
    return NO;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    (void)recognizer; (void)other;
    return YES;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    (void)recognizer;
    self.znsCandidateBundle = nil;
    self.znsArmed = NO;
    self.znsGeneration = ++ZNSStatusHoldGeneration;
    [ZNSStatusPreparation cancel]; ZNSStatusPreparation=nil;
    if (!ZNSActivationEnabled || (!ZNSLeftHoldEnabled && !ZNSRightHoldEnabled) ||
        !self.view || ZNSStatusHoldOwner(self.view) != self.view) return NO;
    for (UIView *ancestor = self.view; ancestor; ancestor = ancestor.superview)
        if (ancestor.hidden || ancestor.alpha < 0.01) return NO;
    // Never repurpose an actual status-bar button's long press.
    for (UIView *view = touch.view; view && view != self.view; view = view.superview)
        if ([view isKindOfClass:UIControl.class]) return NO;
    CGRect bounds = self.view.bounds;
    CGPoint point = [touch locationInView:self.view];
    if (CGRectIsEmpty(bounds) || !CGRectContainsPoint(bounds, point)) return NO;
    CGFloat fraction = (point.x - CGRectGetMinX(bounds)) / CGRectGetWidth(bounds);
    // Leave the notch / Dynamic Island and the central status text untouched.
    if (fraction >= 0.42 && fraction <= 0.58) return NO;
    self.znsLeftSide = fraction < 0.42;
    if (!(self.znsLeftSide ? ZNSLeftHoldEnabled : ZNSRightHoldEnabled)) return NO;
    self.znsInitialPoint = point;
    self.znsCandidateBundle = ZNSActivationForegroundBundle();
    return self.znsCandidateBundle.length > 0 &&
        [ZNSWindowManager.shared canOpenBundleIdentifier:self.znsCandidateBundle];
}
- (void)znsDidHold:(UILongPressGestureRecognizer *)recognizer {
    UIGestureRecognizerState state=recognizer.state;
    if (state==UIGestureRecognizerStateCancelled || state==UIGestureRecognizerStateFailed) {
        self.znsArmed=NO;
        return;
    }
    BOOL valid=ZNSActivationEnabled && self.znsGeneration==ZNSStatusHoldGeneration &&
        (self.znsLeftSide ? ZNSLeftHoldEnabled : ZNSRightHoldEnabled) &&
        self.view && ZNSStatusHoldOwner(self.view)==self.view;
    CGPoint point=[recognizer locationInView:self.view];
    CGFloat dx=point.x-self.znsInitialPoint.x, dy=point.y-self.znsInitialPoint.y;
    valid=valid && dx*dx+dy*dy<=64.0 &&
        [ZNSActivationForegroundBundle() isEqualToString:self.znsCandidateBundle];
    if (state==UIGestureRecognizerStateBegan) {
        // Never rehost the foreground scene or synthesize Home while the status
        // bar still owns the finger. Other consumers may have delayed tap work.
        self.znsArmed=valid;
        os_log(ZNSActivationLog(),"status hold armed=%d; waiting for touch release",valid);
        return;
    }
    if (!valid) self.znsArmed=NO;
    if (state!=UIGestureRecognizerStateEnded) return;
    BOOL submit=self.znsArmed;
    self.znsArmed=NO;
    if (!submit) return;

    NSString *bundle=[self.znsCandidateBundle copy];
    BOOL left=self.znsLeftSide;
    NSString *mode=[(left ? ZNSLeftHoldMode : ZNSRightHoldMode) copy];
    NSUInteger generation=self.znsGeneration;
    NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+5.0;
    __weak UIView *owner=self.view;
    // Leave UIKit's touch-ended/recognizer delivery stack before changing the
    // scene. This is ordering, not a guessed delay that declares a scene ready.
    dispatch_async(dispatch_get_main_queue(),^{
        UIView *view=owner;
        if (generation!=ZNSStatusHoldGeneration || !ZNSActivationEnabled ||
            !(left ? ZNSLeftHoldEnabled : ZNSRightHoldEnabled) ||
            !view || ZNSStatusHoldOwner(view)!=view ||
            ![ZNSActivationForegroundBundle() isEqualToString:bundle] ||
            ![ZNSWindowManager.shared canOpenBundleIdentifier:bundle]) return;
        if (!ZNSHomeReturnAvailable()) {
            os_log_error(ZNSActivationLog(),"status hold unavailable: no compatible Home return API");
            return;
        }
        if(![mode isEqualToString:@"main"]) {
            if(![mode isEqualToString:(left ? ZNSLeftHoldMode : ZNSRightHoldMode)] ||
               ![ZNSWindowManager.shared canOpenNotificationBundleIdentifier:bundle mode:mode]) return;
            // Reuse the existing prepared presentation routes, but retain this
            // entry's foreground/lock/generation checks and return-Home policy.
            ZNSStatusPreparation=[ZNSWindowManager.shared prepareNotificationBundleIdentifier:bundle mode:mode whenReady:^(BOOL ready){
                if(generation!=ZNSStatusHoldGeneration) return;
                ZNSWindowActivation *request=ZNSStatusPreparation;
                ZNSStatusPreparation=nil;
                if(!ready || !ZNSActivationEnabled || NSProcessInfo.processInfo.systemUptime>deadline ||
                   !(left ? ZNSLeftHoldEnabled : ZNSRightHoldEnabled) ||
                   ![mode isEqualToString:(left ? ZNSLeftHoldMode : ZNSRightHoldMode)] ||
                   ![ZNSActivationForegroundBundle() isEqualToString:bundle] || !ZNSReadAuthorization(YES)) {
                    [request cancel]; return;
                }
                BOOL committed=[request commit];
                if(committed) ZNSReturnHomeForBundle(bundle);
                else [request cancel];
                os_log(ZNSActivationLog(),"status hold mode=%{public}@ committed=%d",mode,committed);
            }];
            __weak ZNSWindowActivation *pending=ZNSStatusPreparation;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),dispatch_get_main_queue(),^{
                ZNSWindowActivation *request=pending;
                if(request && generation==ZNSStatusHoldGeneration && ZNSStatusPreparation==request) {
                    [request cancel]; ZNSStatusPreparation=nil;
                }
            });
            return;
        }
        BOOL accepted=[ZNSWindowManager.shared openBundleIdentifier:bundle whenReady:^(BOOL ready) {
            if (!ready || generation!=ZNSStatusHoldGeneration ||
                NSProcessInfo.processInfo.systemUptime>deadline ||
                !(left ? ZNSLeftHoldEnabled : ZNSRightHoldEnabled)) {
                os_log(ZNSActivationLog(),"status hold Home cancelled: stale or unready request");
                return;
            }
            // Manager also verifies this is still the active, undocked live
            // window; ReturnHome checks authorization, lock and foreground.
            ZNSReturnHomeForBundle(bundle);
        }];
        os_log(ZNSActivationLog(),"status hold released side=%{public}s accepted=%d",
               left ? "left" : "right",accepted);
    });
}
- (void)reset {
    [super reset];
    self.znsCandidateBundle = nil;
    self.znsArmed = NO;
}
@end

static BOOL ZNSIsKnownStatusView(UIView *view) {
    for (NSUInteger index = 0; index < 3; index++) {
        Class cls = ZNSStatusHooks[index].viewClass;
        if (cls && [view isKindOfClass:cls]) return YES;
    }
    return NO;
}

static UIView *ZNSStatusHoldOwner(UIView *view) {
    UIWindow *window = view.window;
    if (!window || window.screen != UIScreen.mainScreen) return nil;
    // The modern SpringBoard status-bar host need not live in UIStatusBarWindow.
    // Restrict by the three known view classes instead, and explicitly reject
    // this tweak's hosted/mirrored hierarchy, including subclasses of its window.
    Class overlayClass = NSClassFromString(@"ZNSOverlayWindow");
    if (overlayClass && [window isKindOfClass:overlayClass]) return nil;
    UIView *owner = nil;
    for (UIView *ancestor = view; ancestor; ancestor = ancestor.superview) {
        if (ancestor.hidden || ancestor.alpha < 0.01 || !ancestor.userInteractionEnabled) return nil;
        if (ZNSIsKnownStatusView(ancestor)) owner = ancestor;
    }
    // A nested STUIStatusBar / _UIStatusBar and its SpringBoard host must share
    // one recognizer: choose the outermost known host, not one per child view.
    return owner;
}

static void ZNSUpdateStatusHold(ZNSStatusBarHold *hold) {
    BOOL enabled = ZNSActivationEnabled && (ZNSLeftHoldEnabled || ZNSRightHoldEnabled) &&
                   hold.view && ZNSStatusHoldOwner(hold.view) == hold.view;
    if (hold.enabled != enabled) hold.enabled = enabled;
}

static void ZNSAttachStatusHold(UIView *view) {
    // If a formerly independent bar is now nested, stop its old recognizer.
    ZNSStatusBarHold *previous = objc_getAssociatedObject(view, &ZNSStatusHoldAssociation);
    if (previous) ZNSUpdateStatusHold(previous);
    UIView *owner = ZNSStatusHoldOwner(view);
    if (!owner) return;
    ZNSStatusBarHold *hold = objc_getAssociatedObject(owner, &ZNSStatusHoldAssociation);
    if (!hold) {
        hold = [ZNSStatusBarHold new];
        if (!ZNSStatusHolds) ZNSStatusHolds = [NSHashTable weakObjectsHashTable];
        [ZNSStatusHolds addObject:hold];
        [owner addGestureRecognizer:hold];
        objc_setAssociatedObject(owner, &ZNSStatusHoldAssociation, hold, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        os_log(ZNSActivationLog(), "ZNS status hold attached class=%{public}s",
               class_getName(owner.class));
    }
    ZNSUpdateStatusHold(hold);
}

// Separate original IMPs are essential: these classes may inherit each other's
// lifecycle methods. Never reuse a single original for several hooks.
#define ZNS_STATUS_LIFECYCLE(Name, Index) \
static void ZNSStatusLayout##Name(id object, SEL selector) { \
    ZNSStatusLifecycleIMP original = ZNSStatusHooks[Index].originalLayout; \
    if (original) original(object, selector); \
    ZNSAttachStatusHold(object); \
} \
static void ZNSStatusMove##Name(id object, SEL selector) { \
    ZNSStatusLifecycleIMP original = ZNSStatusHooks[Index].originalMove; \
    if (original) original(object, selector); \
    ZNSAttachStatusHold(object); \
}
ZNS_STATUS_LIFECYCLE(System, 0)
ZNS_STATUS_LIFECYCLE(UIKit, 1)
ZNS_STATUS_LIFECYCLE(Legacy, 2)
#undef ZNS_STATUS_LIFECYCLE

static void ZNSRefreshStatusViews(UIView *view) {
    if (ZNSIsKnownStatusView(view)) ZNSAttachStatusHold(view);
    for (UIView *child in view.subviews) ZNSRefreshStatusViews(child);
}

static BOOL ZNSStatusLifecycleMatches(Class cls, SEL selector) {
    Method method = class_getInstanceMethod(cls, selector);
    char result[16] = {0};
    if (method) method_getReturnType(method, result, sizeof(result));
    return method && method_getNumberOfArguments(method) == 2 &&
           strcmp(result, @encode(void)) == 0;
}

void ZNSReloadActivationPreferences(void) {
    NSCAssert(NSThread.isMainThread, @"Activation preferences must reload on the main thread");
    ++ZNSStatusHoldGeneration;
    [ZNSStatusPreparation cancel]; ZNSStatusPreparation=nil;
    ++ZNSNotificationGeneration;
    [ZNSNotificationPreparation cancel]; ZNSNotificationPreparation=nil;
    BOOL preferencesReady=CFPreferencesAppSynchronize(CFSTR(APELIN_PACKAGE_ID));
    ZNSActivationEnabled = preferencesReady && ZNSReadAuthorization(NO) && ZNSActivationReadBool(CFSTR("Enabled"), NO);
    ZNSLeftHoldMode=ZNSStatusReadMode(CFSTR("StatusBarLeftOpenMode"));
    ZNSRightHoldMode=ZNSStatusReadMode(CFSTR("StatusBarRightOpenMode"));
    ZNSLeftHoldEnabled = ZNSActivationReadBool(CFSTR("StatusBarLeftHold"), NO) && ![ZNSLeftHoldMode isEqualToString:@"off"];
    ZNSRightHoldEnabled = ZNSActivationReadBool(CFSTR("StatusBarRightHold"), NO) && ![ZNSRightHoldMode isEqualToString:@"off"];
    id mode=CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("NotificationOpenMode"),CFSTR(APELIN_PACKAGE_ID)));
    ZNSNotificationOpenMode=ZNSActivationEnabled && [mode isKindOfClass:NSString.class] &&
        [@[@"main",@"parked",@"parked2",@"dip"] containsObject:mode] ? [mode copy] : @"off";
    ZNSReloadSwitcherPreferences(ZNSActivationEnabled);
    for (ZNSStatusBarHold *hold in ZNSStatusHolds) ZNSUpdateStatusHold(hold);
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.screen == UIScreen.mainScreen) ZNSRefreshStatusViews(window);
        }
    }
    os_log(ZNSActivationLog(), "ZNS activation enabled=%d leftHold=%d rightHold=%d notificationMode=%{public}@ notificationHook=%d",
           ZNSActivationEnabled, ZNSLeftHoldEnabled, ZNSRightHoldEnabled, ZNSNotificationOpenMode,
           ZNSOriginalNotificationTap!=NULL && ZNSOriginalNotificationDefault!=NULL);
}

void ZNSInstallActivationHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ZNSInstallSwitcherHooks();
        Class iconClass=objc_getClass("SBIconView");
        SEL tapSelector=NSSelectorFromString(@"_handleTap");
        if (iconClass && ZNSStatusLifecycleMatches(iconClass,tapSelector))
            MSHookMessageEx(iconClass,tapSelector,(IMP)ZNSIconHandleTap,(IMP *)&ZNSOriginalIconHandleTap);
        os_log(ZNSActivationLog(),"desktop icon tap hook installed=%d",ZNSOriginalIconHandleTap!=NULL);
        // These candidate class names are present together beside the reference's
        // "MTStatusBar hooks system/uikit/legacy" strings. Their private methods
        // are NOT inferred from that evidence: only UIView lifecycle ABI is used.
        const char *names[] = { "SBMainDisplaySceneLayoutStatusBarView", "STUIStatusBar", "_UIStatusBar" };
        IMP layouts[] = { (IMP)ZNSStatusLayoutSystem, (IMP)ZNSStatusLayoutUIKit, (IMP)ZNSStatusLayoutLegacy };
        IMP moves[] = { (IMP)ZNSStatusMoveSystem, (IMP)ZNSStatusMoveUIKit, (IMP)ZNSStatusMoveLegacy };
        for (NSUInteger index = 0; index < 3; index++) {
            Class cls = objc_getClass(names[index]);
            BOOL valid = cls && [cls isSubclassOfClass:UIView.class] &&
                         ZNSStatusLifecycleMatches(cls, @selector(layoutSubviews)) &&
                         ZNSStatusLifecycleMatches(cls, @selector(didMoveToWindow));
            if (valid) {
                ZNSStatusHooks[index].viewClass = cls;
                MSHookMessageEx(cls, @selector(layoutSubviews), layouts[index],
                               (IMP *)&ZNSStatusHooks[index].originalLayout);
                MSHookMessageEx(cls, @selector(didMoveToWindow), moves[index],
                               (IMP *)&ZNSStatusHooks[index].originalMove);
            }
            os_log(ZNSActivationLog(), "ZNS status hold hook class=%{public}s layout=%d move=%d",
                   names[index], ZNSStatusHooks[index].originalLayout != NULL,
                   ZNSStatusHooks[index].originalMove != NULL);
        }
        // Publicly dumped NC selectors, guarded against runtime ABI changes.
        // No action-runner/completion ABI is guessed and no NC payload is copied.
        Class shortLook=NSClassFromString(@"NCNotificationShortLookViewController");
        SEL bannerTap=NSSelectorFromString(@"_handleTapOnView:");
        SEL defaultAction=NSSelectorFromString(@"_executeDefaultAction:");
        Method tapMethod=class_getInstanceMethod(shortLook,bannerTap);
        Method actionMethod=class_getInstanceMethod(shortLook,defaultAction);
        char tapReturn[16]={0}, tapArgument[16]={0}, actionReturn[16]={0}, actionArgument[16]={0};
        if(tapMethod) {
            method_getReturnType(tapMethod,tapReturn,sizeof(tapReturn));
            method_getArgumentType(tapMethod,2,tapArgument,sizeof(tapArgument));
        }
        if(actionMethod) {
            method_getReturnType(actionMethod,actionReturn,sizeof(actionReturn));
            method_getArgumentType(actionMethod,2,actionArgument,sizeof(actionArgument));
        }
        if(shortLook && [shortLook isSubclassOfClass:UIViewController.class] && tapMethod && actionMethod &&
           method_getNumberOfArguments(tapMethod)==3 && method_getNumberOfArguments(actionMethod)==3 &&
           strcmp(tapReturn,@encode(void))==0 && strcmp(tapArgument,@encode(id))==0 &&
           strcmp(actionReturn,@encode(void))==0 && strcmp(actionArgument,@encode(BOOL))==0) {
            MSHookMessageEx(shortLook,defaultAction,(IMP)ZNSNotificationDefault,(IMP *)&ZNSOriginalNotificationDefault);
            MSHookMessageEx(shortLook,bannerTap,(IMP)ZNSNotificationTap,(IMP *)&ZNSOriginalNotificationTap);
        }
    });
}
