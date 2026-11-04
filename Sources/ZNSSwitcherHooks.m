#import "ZNSSwitcherHooks.h"
#import "ZNSWindowManager.h"
#import "ZNSAuthorization.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <os/log.h>
#import <math.h>
#import <string.h>

// Reference: Banana 0.1.5, _updateTransformForCurrentHighlight hook at
// 0x6222c; killingProgress <= -0.10 fires once, > -0.05 rearms. We never
// change the system's progress, transform, dismissal or horizontal scrolling.
static BOOL ZNSSwitcherEnabled, ZNSSwitcherDown=YES;
static NSUInteger ZNSSwitcherGeneration;
static BOOL ZNSSwitcherOpening;
static Class ZNSSwitcherCardClass;
static char ZNSCardHoldKey, ZNSCardPullKey;
static NSHashTable<UILongPressGestureRecognizer *> *ZNSCardHolds;
static ZNSWindowActivation *ZNSCardActivation;
static void (*ZNSOriginalCardLayout)(id,SEL);
static void (*ZNSOriginalCardMove)(id,SEL);
static void (*ZNSOriginalCardHighlight)(id,SEL);

static os_log_t ZNSCardLog(void) {
    static os_log_t log; static dispatch_once_t once;
    dispatch_once(&once,^{log=os_log_create(APELIN_PACKAGE_ID,"switcher");});
    return log;
}
static BOOL ZNSCardSignature(id object,SEL selector,const char *result,NSArray<NSString *> *arguments) {
    if(!object || ![object respondsToSelector:selector]) return NO;
    NSMethodSignature *sig=[object methodSignatureForSelector:selector];
    if(!sig || strcmp(sig.methodReturnType,result) || sig.numberOfArguments!=arguments.count+2) return NO;
    for(NSUInteger i=0;i<arguments.count;i++)
        if(strcmp([sig getArgumentTypeAtIndex:i+2],arguments[i].UTF8String)) return NO;
    return YES;
}
static id ZNSCardObject(id object,NSString *name) {
    SEL sel=NSSelectorFromString(name);
    if(!ZNSCardSignature(object,sel,@encode(id),@[])) return nil;
    return ((id(*)(id,SEL))objc_msgSend)(object,sel);
}
static BOOL ZNSCardBool(id object,NSString *name) {
    SEL sel=NSSelectorFromString(name);
    return ZNSCardSignature(object,sel,@encode(BOOL),@[]) && ((BOOL(*)(id,SEL))objc_msgSend)(object,sel);
}
static BOOL ZNSCardUnlocked(void) {
    id lock=ZNSCardObject(NSClassFromString(@"SBLockScreenManager"),@"sharedInstance");
    SEL sel=NSSelectorFromString(@"isUILocked");
    return ZNSCardSignature(lock,sel,@encode(BOOL),@[]) && !((BOOL(*)(id,SEL))objc_msgSend)(lock,sel);
}
static BOOL ZNSCardReadBool(CFStringRef key,BOOL fallback) {
    id value=CFBridgingRelease(CFPreferencesCopyAppValue(key,CFSTR(APELIN_PACKAGE_ID)));
    return [value isKindOfClass:NSNumber.class]?[value boolValue]:fallback;
}
static NSArray *ZNSCardControllers(void) {
    NSMutableArray *result=[NSMutableArray array];
    for(NSString *name in @[@"SBMainSwitcherControllerCoordinator",@"SBMainSwitcherViewController"]) {
        id root=ZNSCardObject(NSClassFromString(name),@"sharedInstance");
        if(!root) continue;
        if(![result containsObject:root]) [result addObject:root];
        id children=ZNSCardObject(root,@"coordinatedSwitcherControllers");
        if([children isKindOfClass:NSArray.class] || [children isKindOfClass:NSSet.class])
            for(id child in children) if(![result containsObject:child]) [result addObject:child];
    }
    return result;
}
static BOOL ZNSCardSwitcherVisible(void) {
    for(id controller in ZNSCardControllers())
        if(ZNSCardBool(controller,@"isAnySwitcherVisible") || ZNSCardBool(controller,@"isMainSwitcherVisible")) return YES;
    return NO;
}
static BOOL ZNSCardVisible(UIView *card) {
    if(!card.window || card.window.screen!=UIScreen.mainScreen) return NO;
    for(UIView *view=card;view;view=view.superview)
        if(view.hidden || view.alpha<0.01 || !view.userInteractionEnabled) return NO;
    return CGRectIntersectsRect([card convertRect:card.bounds toView:card.window],card.window.bounds);
}
static BOOL ZNSCardAllowed(UIView *card) {
    return NSThread.isMainThread && ZNSSwitcherEnabled && ZNSCardUnlocked() &&
        ZNSReadAuthorization(YES) && ZNSCardVisible(card) && ZNSCardSwitcherVisible();
}
static NSString *ZNSCardKnownBundle(id value) {
    if(![value isKindOfClass:NSString.class] || ![value length] ||
       [value isEqualToString:@"com.apple.springboard"]) return nil;
    id controller=ZNSCardObject(NSClassFromString(@"SBApplicationController"),@"sharedInstance");
    SEL find=NSSelectorFromString(@"applicationWithBundleIdentifier:");
    if(!ZNSCardSignature(controller,find,@encode(id),@[@(@encode(id))])) return nil;
    id app=((id(*)(id,SEL,id))objc_msgSend)(controller,find,value);
    return [ZNSCardObject(app,@"bundleIdentifier") isEqual:value]?value:nil;
}
static NSString *ZNSCardBundle(id layout) {
    if(![layout isKindOfClass:NSClassFromString(@"SBAppLayout")]) return nil;
    NSMutableSet<NSString *> *bundles=[NSMutableSet set];
    // iOS 16.1.1 exposes allItems, not _rolesToLayoutItemsMap. Enumerate the
    // real layout items rather than treating continuousExposeIdentifier as an
    // App identifier. Never pick the first item of an ambiguous layout.
    id items=ZNSCardObject(layout,@"allItems");
    if (items) {
        if (![items isKindOfClass:NSArray.class] && ![items isKindOfClass:NSSet.class] &&
            ![items isKindOfClass:NSOrderedSet.class]) return nil;
        for (id item in items) {
            NSString *bundle=ZNSCardKnownBundle(ZNSCardObject(item,@"bundleIdentifier"));
            if (!bundle) return nil;
            [bundles addObject:bundle];
        }
        if ([items count]) return bundles.count==1?bundles.anyObject:nil;
    }
    Ivar ivar=class_getInstanceVariable(object_getClass(layout),"_rolesToLayoutItemsMap");
    const char *type=ivar?ivar_getTypeEncoding(ivar):NULL;
    id map=(type && type[0]=='@')?object_getIvar(layout,ivar):nil;
    if([map isKindOfClass:NSDictionary.class] && [map count]) {
        BOOL unresolved=NO;
        for(id item in [map allValues]) {
            NSString *bundle=ZNSCardKnownBundle(ZNSCardObject(item,@"bundleIdentifier"));
            if(bundle) [bundles addObject:bundle]; else unresolved=YES;
        }
        if(bundles.count>1) return nil;
        // Unknown roles in a multi-item layout might belong to another App.
        // A single unresolved item may still use the checked layout getters.
        if(unresolved && [map count]>1) return nil;
    } else if(map && ![map isKindOfClass:NSDictionary.class]) return nil;
    for(NSString *getter in @[@"bundleIdentifier",@"continuousExposeIdentifier"]) {
        NSString *bundle=ZNSCardKnownBundle(ZNSCardObject(layout,getter));
        if(bundle) [bundles addObject:bundle];
    }
    return bundles.count==1?bundles.anyObject:nil;
}
static BOOL ZNSCardMatches(UIView *card,id layout,NSString *bundle) {
    return ZNSCardAllowed(card) && ZNSCardObject(card,@"appLayout")==layout &&
        [ZNSCardBundle(layout) isEqualToString:bundle];
}
static id ZNSCardHomeController(void) {
    SEL sel=NSSelectorFromString(@"_dismissSwitcherNoninteractivelyToAppLayout:dismissFloatingSwitcher:animated:");
    for(id controller in ZNSCardControllers())
        if(ZNSCardSignature(controller,sel,@encode(BOOL),@[@(@encode(id)),@(@encode(BOOL)),@(@encode(BOOL))])) return controller;
    return nil;
}
static id ZNSCardHomeLayout(void) {
    return ZNSCardObject(NSClassFromString(@"SBAppLayout"),@"homeScreenAppLayout");
}
void ZNSCancelSwitcherActivation(void) {
    ZNSSwitcherGeneration++;
    ZNSSwitcherOpening=NO;
    ZNSWindowActivation *activation=ZNSCardActivation;
    ZNSCardActivation=nil;
    [activation cancel];
}
static void ZNSCardMonitor(UIView *card,id layout,NSString *bundle,NSUInteger generation) {
    __weak UIView *weakCard=card;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/10),dispatch_get_main_queue(),^{
        if(generation!=ZNSSwitcherGeneration || !ZNSSwitcherOpening) return;
        if(!ZNSCardMatches(weakCard,layout,bundle)) { ZNSCancelSwitcherActivation(); return; }
        ZNSCardMonitor(weakCard,layout,bundle,generation);
    });
}
static void ZNSCardOpen(UIView *card,id layout,NSString *bundle,NSUInteger generation) {
    if(generation!=ZNSSwitcherGeneration || ZNSSwitcherOpening || !ZNSCardMatches(card,layout,bundle)) return;
    if(!ZNSCardHomeController() || !ZNSCardHomeLayout()) {
        os_log_error(ZNSCardLog(),"card launch declined: no checked Home layout dismissal API");
        return;
    }
    ZNSSwitcherOpening=YES;
    __weak UIView *weakCard=card;
    // The manager guarantees an asynchronous completion so the token is stored
    // before readiness is reported. Preparation leaves existing windows untouched.
    ZNSCardActivation=[ZNSWindowManager.shared prepareSwitcherBundleIdentifier:bundle whenReady:^(BOOL ready){
        if(generation!=ZNSSwitcherGeneration) return;
        if(!ready || !ZNSCardMatches(weakCard,layout,bundle) ||
           ![ZNSWindowManager.shared canOpenBundleIdentifier:bundle]) {
            ZNSCancelSwitcherActivation(); return;
        }
        id controller=ZNSCardHomeController(),home=ZNSCardHomeLayout();
        if(!controller || !home) { ZNSCancelSwitcherActivation(); return; }
        ZNSWindowActivation *activation=ZNSCardActivation;
        if(!activation || ![activation commit]) { ZNSCancelSwitcherActivation(); return; }
        ZNSCardActivation=nil;
        ZNSSwitcherOpening=NO;
        @try {
            BOOL requested=((BOOL(*)(id,SEL,id,BOOL,BOOL))objc_msgSend)(controller,
                NSSelectorFromString(@"_dismissSwitcherNoninteractivelyToAppLayout:dismissFloatingSwitcher:animated:"),
                home,YES,!UIAccessibilityIsReduceMotionEnabled());
            os_log(ZNSCardLog(),"card scene committed; switcher dismissal accepted=%d",requested);
            if (!requested) os_log_error(ZNSCardLog(),"card dismissal declined after commit; window preserved, no forced Home fallback");
        } @catch(NSException *exception) {
            // Commit may have restored a user-owned window. Do not close it.
            os_log_error(ZNSCardLog(),"card dismissal exception after commit; window preserved: %{public}@",exception.name);
        }
    }];
    BOOL accepted=ZNSCardActivation!=nil;
    if(!accepted) ZNSCancelSwitcherActivation();
    else ZNSCardMonitor(card,layout,bundle,generation);
    os_log(ZNSCardLog(),"card split request accepted=%d direct=1",accepted);
    // Only expire stale work; never use a timer as proof of scene readiness.
    if(accepted) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,12*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        if(generation==ZNSSwitcherGeneration && ZNSSwitcherOpening) ZNSCancelSwitcherActivation();
    });
}
static void ZNSCardActivate(UIView *card) {
    BOOL allowed=ZNSCardAllowed(card);
    if(!allowed || ZNSSwitcherOpening) {
        os_log(ZNSCardLog(),"card trigger rejected allowed=%d busy=%d enabled=%d unlocked=%d visible=%d switcher=%d",
            allowed,ZNSSwitcherOpening,ZNSSwitcherEnabled,ZNSCardUnlocked(),ZNSCardVisible(card),ZNSCardSwitcherVisible());
        return;
    }
    id layout=ZNSCardObject(card,@"appLayout");
    NSString *bundle=ZNSCardBundle(layout);
    if(!bundle.length || ![ZNSWindowManager.shared canOpenBundleIdentifier:bundle]) {
        os_log(ZNSCardLog(),"card trigger rejected resolvedApp=%d admitted=0 layoutClass=%{public}@",bundle.length>0,NSStringFromClass([layout class]));
        return;
    }
    NSUInteger generation=++ZNSSwitcherGeneration;
    // Both supported gestures always open this card's App directly. Legacy
    // SwitcherDirectLaunch preferences are deliberately no longer consulted.
    ZNSCardOpen(card,layout,bundle,generation);
}

@interface ZNSCardHold : UILongPressGestureRecognizer <UIGestureRecognizerDelegate>
@property(nonatomic,strong) id znsStartingLayout;
@end
@implementation ZNSCardHold
- (instancetype)init {
    if((self=[super initWithTarget:nil action:NULL])) {
        [self addTarget:self action:@selector(znsHold:)]; self.delegate=self;
        self.minimumPressDuration=0.55; self.allowableMovement=8;
        self.cancelsTouchesInView=YES; self.delaysTouchesBegan=NO; self.delaysTouchesEnded=NO;
    } return self;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    (void)recognizer;
    self.znsStartingLayout=nil;
    if(ZNSSwitcherDown || ZNSSwitcherOpening || !ZNSCardAllowed(self.view)) return NO;
    for(UIView *view=touch.view;view && view!=self.view;view=view.superview)
        if([view isKindOfClass:UIControl.class]) return NO;
    id layout=ZNSCardObject(self.view,@"appLayout");
    NSString *bundle=ZNSCardBundle(layout);
    if(!bundle || ![ZNSWindowManager.shared canOpenBundleIdentifier:bundle]) return NO;
    self.znsStartingLayout=layout;
    return YES;
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    (void)recognizer;
    if(ZNSSwitcherDown || ZNSSwitcherOpening || !ZNSCardAllowed(self.view) ||
       ZNSCardObject(self.view,@"appLayout")!=self.znsStartingLayout) return NO;
    NSString *bundle=ZNSCardBundle(self.znsStartingLayout);
    return bundle && [ZNSWindowManager.shared canOpenBundleIdentifier:bundle];
}
- (void)znsHold:(UILongPressGestureRecognizer *)gesture {
    if(gesture.state==UIGestureRecognizerStateBegan && !ZNSSwitcherDown &&
       ZNSCardObject(self.view,@"appLayout")==self.znsStartingLayout) ZNSCardActivate(self.view);
}
- (void)reset { [super reset]; self.znsStartingLayout=nil; }
@end
static void ZNSCardAttach(UIView *card) {
    ZNSCardHold *hold=objc_getAssociatedObject(card,&ZNSCardHoldKey);
    if(!card.window) {
        hold.enabled=NO; objc_setAssociatedObject(card,&ZNSCardPullKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if(!hold) {
        hold=[ZNSCardHold new];
        if(!ZNSCardHolds) ZNSCardHolds=[NSHashTable weakObjectsHashTable];
        [ZNSCardHolds addObject:hold]; [card addGestureRecognizer:hold];
        objc_setAssociatedObject(card,&ZNSCardHoldKey,hold,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    BOOL enabled=ZNSSwitcherEnabled && !ZNSSwitcherDown;
    if(hold.enabled!=enabled) hold.enabled=enabled;
}
static void ZNSCardLayout(id object,SEL selector) {
    if(ZNSOriginalCardLayout) ZNSOriginalCardLayout(object,selector);
    ZNSCardAttach(object);
}
static void ZNSCardMove(id object,SEL selector) {
    if(ZNSOriginalCardMove) ZNSOriginalCardMove(object,selector);
    ZNSCardAttach(object);
}
static void ZNSCardHighlight(id object,SEL selector) {
    if(ZNSOriginalCardHighlight) ZNSOriginalCardHighlight(object,selector);
    if(!NSThread.isMainThread || !ZNSSwitcherEnabled || !ZNSSwitcherDown) return;
    SEL progressSelector=NSSelectorFromString(@"killingProgress");
    if(!ZNSCardSignature(object,progressSelector,@encode(double),@[])) return;
    double progress=((double(*)(id,SEL))objc_msgSend)(object,progressSelector);
    if(!isfinite(progress)) return;
    if(progress>-.05) {
        objc_setAssociatedObject(object,&ZNSCardPullKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if(progress<=-.10 && !objc_getAssociatedObject(object,&ZNSCardPullKey)) {
        id layout=ZNSCardObject(object,@"appLayout");
        os_log(ZNSCardLog(),"card pull threshold progress=%.3f",progress);
        objc_setAssociatedObject(object,&ZNSCardPullKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        __weak UIView *weakCard=object;
        NSUInteger generation=ZNSSwitcherGeneration;
        dispatch_async(dispatch_get_main_queue(),^{
            if(generation==ZNSSwitcherGeneration && ZNSSwitcherDown &&
               ZNSCardObject(weakCard,@"appLayout")==layout) ZNSCardActivate(weakCard);
        });
    }
}
static BOOL ZNSCardGetterMethod(Class cls,SEL selector,const char *result) {
    Method method=class_getInstanceMethod(cls,selector);
    if(!method) return NO;
    NSMethodSignature *sig=[NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    return sig.numberOfArguments==2 && !strcmp(sig.methodReturnType,result);
}
static BOOL ZNSCardVoidMethod(Class cls,SEL selector) {
    return ZNSCardGetterMethod(cls,selector,@encode(void));
}
static void ZNSCardScan(UIView *view) {
    if(ZNSSwitcherCardClass && [view isKindOfClass:ZNSSwitcherCardClass]) ZNSCardAttach(view);
    for(UIView *child in view.subviews) ZNSCardScan(child);
}
void ZNSReloadSwitcherPreferences(BOOL enabled) {
    ZNSCancelSwitcherActivation();
    ZNSSwitcherEnabled=enabled && ZNSCardReadBool(CFSTR("SwitcherGesturesEnabled"),NO);
    id gesture=CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("SwitcherGesture"),CFSTR(APELIN_PACKAGE_ID)));
    ZNSSwitcherDown=![gesture isKindOfClass:NSString.class] || ![gesture isEqualToString:@"hold"];
    for(UILongPressGestureRecognizer *hold in ZNSCardHolds) hold.enabled=ZNSSwitcherEnabled && !ZNSSwitcherDown && hold.view.window;
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes)
        if([scene isKindOfClass:UIWindowScene.class])
            for(UIWindow *window in ((UIWindowScene *)scene).windows)
                if(window.screen==UIScreen.mainScreen) ZNSCardScan(window);
}
void ZNSInstallSwitcherHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once,^{
        // Prefer a complete host, then explicitly degrade to long press only.
        // Install one class, avoiding nested inherited callbacks/duplicate holds.
        SEL update=NSSelectorFromString(@"_updateTransformForCurrentHighlight");
        Class chosen=Nil,fallback=Nil;
        for(NSString *name in @[@"SBFluidSwitcherItemContainer",@"SBReusableSnapshotItemContainer"]) {
            Class cls=NSClassFromString(name);
            if(!cls || ![cls isSubclassOfClass:UIView.class] ||
               !ZNSCardVoidMethod(cls,@selector(layoutSubviews)) ||
               !ZNSCardVoidMethod(cls,@selector(didMoveToWindow)) ||
               !ZNSCardGetterMethod(cls,NSSelectorFromString(@"appLayout"),@encode(id))) continue;
            if(!fallback) fallback=cls;
            if(ZNSCardVoidMethod(cls,update) &&
               ZNSCardGetterMethod(cls,NSSelectorFromString(@"killingProgress"),@encode(double))) {
                chosen=cls; break;
            }
        }
        BOOL nativePull=chosen!=Nil;
        if(!chosen) chosen=fallback;
        if(!chosen) { os_log_error(ZNSCardLog(),"no compatible switcher card host"); return; }
        ZNSSwitcherCardClass=chosen;
        MSHookMessageEx(chosen,@selector(layoutSubviews),(IMP)ZNSCardLayout,(IMP *)&ZNSOriginalCardLayout);
        MSHookMessageEx(chosen,@selector(didMoveToWindow),(IMP)ZNSCardMove,(IMP *)&ZNSOriginalCardMove);
        if(nativePull) MSHookMessageEx(chosen,update,(IMP)ZNSCardHighlight,(IMP *)&ZNSOriginalCardHighlight);
        os_log(ZNSCardLog(),"card hooks class=%{public}@ longPress=%d nativePull=%d",NSStringFromClass(chosen),
            ZNSOriginalCardLayout!=NULL,ZNSOriginalCardHighlight!=NULL);
        if(!nativePull) os_log_error(ZNSCardLog(),"native pull unsupported; long press is available but gesture preference is unchanged");
    });
}
