#import "ZNSDanmuNotifications.h"
#import "ZNSWindowManager.h"
#import "ZNSAuthorization.h"
#import "ZNSLayerInput.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <notify.h>
#import <math.h>
#import <string.h>

// Independent implementation; no code from the supplied binary is loaded.
static BOOL ZNSDanmuEnabled, ZNSDanmuLight;
static CGFloat ZNSDanmuScale=1, ZNSDanmuOpacity=0.88;
static NSString *ZNSDanmuMode=@"main";
static NSUInteger ZNSDanmuGeneration;
static ZNSWindowActivation *ZNSDanmuPreparation;
static void (*ZNSDanmuOriginalPost)(id,SEL,id,id);

static NSMethodSignature *ZNSDanmuSignature(id object, SEL selector) {
    if(!object || ![object respondsToSelector:selector]) return nil;
    @try { return [object methodSignatureForSelector:selector]; }
    @catch(NSException *exception) { (void)exception; return nil; }
}
static id ZNSDanmuObject(id object,NSString *name) {
    SEL sel=NSSelectorFromString(name);
    NSMethodSignature *sig=ZNSDanmuSignature(object,sel);
    if(!sig || sig.numberOfArguments!=2 || sig.methodReturnType[0]!='@') return nil;
    @try { return ((id(*)(id,SEL))objc_msgSend)(object,sel); }
    @catch(NSException *exception) { (void)exception; return nil; }
}
static BOOL ZNSDanmuBool(id object,NSString *name,BOOL fallback) {
    SEL sel=NSSelectorFromString(name);
    NSMethodSignature *sig=ZNSDanmuSignature(object,sel);
    if(!sig || sig.numberOfArguments!=2 || (strcmp(sig.methodReturnType,"B") && strcmp(sig.methodReturnType,"c"))) return fallback;
    @try { return ((BOOL(*)(id,SEL))objc_msgSend)(object,sel); }
    @catch(NSException *exception) { (void)exception; return fallback; }
}
static BOOL ZNSDanmuUnlocked(void) {
    id lock=ZNSDanmuObject(NSClassFromString(@"SBLockScreenManager"),@"sharedInstance");
    return !ZNSDanmuBool(lock,@"isUILocked",YES);
}
static NSString *ZNSDanmuForeground(void) {
    id app=ZNSDanmuObject(UIApplication.sharedApplication,@"_accessibilityFrontMostApplication");
    id bundle=ZNSDanmuObject(app,@"bundleIdentifier");
    return [bundle isKindOfClass:NSString.class]?bundle:nil;
}
static UIWindowScene *ZNSDanmuScene(void) {
    id workspace=ZNSDanmuObject(NSClassFromString(@"SBMainWorkspace"),@"sharedInstance");
    id scene=ZNSDanmuObject(workspace,@"mainWindowScene");
    if([scene isKindOfClass:UIWindowScene.class] && [scene screen]==UIScreen.mainScreen) return scene;
    for(UIScene *candidate in UIApplication.sharedApplication.connectedScenes)
        if([candidate isKindOfClass:UIWindowScene.class] && [(UIWindowScene *)candidate screen]==UIScreen.mainScreen && candidate.activationState==UISceneActivationStateForegroundActive) return (UIWindowScene *)candidate;
    return nil;
}
static BOOL ZNSDanmuLandscape(void) {
    // Front-most interface orientation is authoritative, not the accelerometer.
    SEL selector=NSSelectorFromString(@"_frontMostAppOrientation");
    NSMethodSignature *sig=ZNSDanmuSignature(UIApplication.sharedApplication,selector);
    if(sig && sig.numberOfArguments==2 && (!strcmp(sig.methodReturnType,@encode(NSInteger)) || !strcmp(sig.methodReturnType,@encode(int)))) {
        NSInteger value=!strcmp(sig.methodReturnType,@encode(int))?
            ((int(*)(id,SEL))objc_msgSend)(UIApplication.sharedApplication,selector):
            ((NSInteger(*)(id,SEL))objc_msgSend)(UIApplication.sharedApplication,selector);
        if(value!=UIInterfaceOrientationUnknown) return UIInterfaceOrientationIsLandscape(value);
    }
    return UIInterfaceOrientationIsLandscape(ZNSDanmuScene().interfaceOrientation);
}
static id ZNSDanmuPreference(NSString *key) {
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key,CFSTR(APELIN_PACKAGE_ID)));
}
static CGFloat ZNSDanmuNumber(NSString *key,CGFloat fallback,CGFloat low,CGFloat high) {
    id value=ZNSDanmuPreference(key);
    double number=[value isKindOfClass:NSNumber.class]?[value doubleValue]:fallback;
    return isfinite(number)?MIN(high,MAX(low,number)):fallback;
}

@interface ZNSDanmuEntry : NSObject
@property(nonatomic,strong) id request;
@property(nonatomic,strong) id runner;
@property(nonatomic,copy) NSString *bundle;
@property(nonatomic,copy) NSString *text;
@property(nonatomic,copy) NSString *identifier;
@property(nonatomic) BOOL test;
@end
@implementation ZNSDanmuEntry @end

// Keep the request and its real default action. Never fabricate a response or
// launch URL. Only supported object-argument runner signatures are invoked.
static SEL ZNSDanmuNativeSelector(id runner) {
    for(NSString *name in @[@"executeAction:fromOrigin:withParameters:completion:",@"executeAction:fromOrigin:withParameters:"]) {
        SEL selector=NSSelectorFromString(name);
        NSMethodSignature *sig=ZNSDanmuSignature(runner,selector);
        NSUInteger count=[name hasSuffix:@"completion:"]?6:5;
        if(!sig || sig.numberOfArguments!=count || strcmp(sig.methodReturnType,"v")) continue;
        BOOL valid=YES;
        for(NSUInteger i=2;i<count;i++) if([sig getArgumentTypeAtIndex:i][0]!='@') valid=NO;
        if(count==6 && strcmp([sig getArgumentTypeAtIndex:5],"@?")) valid=NO;
        if(valid) return selector;
    }
    return NULL;
}
static BOOL ZNSDanmuNativeOpen(ZNSDanmuEntry *entry) {
    SEL selector=ZNSDanmuNativeSelector(entry.runner);
    id action=ZNSDanmuObject(entry.request,@"defaultAction");
    if(!selector || !action || !ZNSDanmuUnlocked()) return NO;
    @try {
        NSMethodSignature *sig=ZNSDanmuSignature(entry.runner,selector);
        NSInvocation *call=[NSInvocation invocationWithMethodSignature:sig];
        call.target=entry.runner; call.selector=selector;
        id origin=@"BulletinDestinationBanner", parameters=@{}, completion=nil;
        [call setArgument:&action atIndex:2]; [call setArgument:&origin atIndex:3];
        [call setArgument:&parameters atIndex:4];
        if(sig.numberOfArguments==6) [call setArgument:&completion atIndex:5];
        [call invoke]; return YES;
    } @catch(NSException *exception) { (void)exception; return NO; }
}

@interface ZNSDanmuWindow : UIWindow @end
@implementation ZNSDanmuWindow
- (BOOL)canBecomeKeyWindow { return NO; }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit=[super hitTest:point withEvent:event];
    return hit==self || hit==self.rootViewController.view?nil:hit;
}
@end
@interface ZNSDanmuRoot : UIViewController
@property(nonatomic,copy) void (^geometryChanged)(void);
@end
@implementation ZNSDanmuRoot
- (void)loadView { self.view=[UIView new]; self.view.backgroundColor=UIColor.clearColor; }
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAllButUpsideDown; }
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; if(self.geometryChanged) self.geometryChanged(); }
@end
@interface ZNSDanmuBubble : UIControl
@property(nonatomic,strong) ZNSDanmuEntry *entry;
@property(nonatomic,strong) UILabel *label;
@property(nonatomic) NSUInteger lane;
@property(nonatomic) CFTimeInterval birth;
@end
@implementation ZNSDanmuBubble @end

@interface ZNSDanmuPresenter : NSObject
@property(nonatomic,strong) ZNSDanmuWindow *window;
@property(nonatomic,strong) ZNSDanmuRoot *root;
@property(nonatomic,strong) NSMutableArray<ZNSDanmuEntry *> *pending;
@property(nonatomic,strong) NSMutableArray<ZNSDanmuBubble *> *active;
@property(nonatomic,strong) CADisplayLink *clock;
@property(nonatomic) CGSize lastSize;
+ (instancetype)shared;
- (BOOL)enqueue:(ZNSDanmuEntry *)entry;
- (void)clear;
- (void)tick:(CADisplayLink *)clock;
- (void)tapped:(ZNSDanmuBubble *)bubble;
@end
@implementation ZNSDanmuPresenter
+ (instancetype)shared {
    static ZNSDanmuPresenter *value; static dispatch_once_t once;
    dispatch_once(&once,^{ value=[self new]; value.pending=[NSMutableArray new]; value.active=[NSMutableArray new]; });
    return value;
}
- (void)clear {
    [self.clock invalidate]; self.clock=nil;
    [self.pending removeAllObjects];
    for(ZNSDanmuBubble *bubble in self.active) [bubble removeFromSuperview];
    [self.active removeAllObjects];
    self.window.hidden=YES; self.root.geometryChanged=nil;
    self.window.rootViewController=nil; self.window=nil; self.root=nil;
    self.lastSize=CGSizeZero;
}
- (BOOL)enqueue:(ZNSDanmuEntry *)entry {
    if(!ZNSDanmuEnabled || !ZNSDanmuUnlocked() || !ZNSDanmuLandscape()) return NO;
    for(ZNSDanmuEntry *other in self.pending) if([other.identifier isEqual:entry.identifier]) return YES;
    for(ZNSDanmuBubble *other in self.active) if([other.entry.identifier isEqual:entry.identifier]) return YES;
    if(self.pending.count>=12) return NO; // Native banner remains available on overflow.
    if(!self.window) {
        UIWindowScene *scene=ZNSDanmuScene(); if(!scene) return NO;
        self.root=[ZNSDanmuRoot new];
        self.window=[[ZNSDanmuWindow alloc] initWithWindowScene:scene];
        self.window.frame=scene.coordinateSpace.bounds;
        self.window.backgroundColor=UIColor.clearColor;
        self.window.windowLevel=UIWindowLevelStatusBar+20;
        self.window.rootViewController=self.root;
        ZNSSetLayerInputOpaque(self.window.layer,NO);
        ZNSSetLayerInputOpaque(self.root.view.layer,NO);
        __weak typeof(self) weakSelf=self;
        self.root.geometryChanged=^{
            ZNSDanmuPresenter *self=weakSelf;
            CGSize size=self.root.view.bounds.size;
            if(self.lastSize.width>0 && !CGSizeEqualToSize(size,self.lastSize)) [self clear];
        };
        self.window.hidden=NO;
        [self.root.view layoutIfNeeded];
        self.lastSize=self.root.view.bounds.size;
        if(self.lastSize.width<=self.lastSize.height) { [self clear]; return NO; }
    }
    [self.pending addObject:entry];
    if(!self.clock) {
        self.clock=[CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
        self.clock.preferredFramesPerSecond=30;
        [self.clock addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    return YES;
}
- (void)tick:(CADisplayLink *)clock {
    if(!ZNSDanmuEnabled || !ZNSDanmuUnlocked() || !ZNSDanmuLandscape()) { [self clear]; return; }
    CGRect safe=UIEdgeInsetsInsetRect(self.root.view.bounds,self.root.view.safeAreaInsets);
    CGFloat height=44*ZNSDanmuScale, gap=8;
    NSUInteger lanes=MAX(1,MIN(3,(NSUInteger)floor(MAX(1,safe.size.height-16)/(height+gap))));
    CFTimeInterval now=clock.timestamp;
    for(ZNSDanmuBubble *bubble in [self.active copy]) {
        double progress=(now-bubble.birth)/8.0;
        if(progress>=1) { [bubble removeFromSuperview]; [self.active removeObject:bubble]; continue; }
        CGRect frame=bubble.frame;
        frame.origin.x=UIAccessibilityIsReduceMotionEnabled()?CGRectGetMidX(safe)-frame.size.width/2:
            CGRectGetMaxX(safe)-(safe.size.width+frame.size.width)*progress;
        bubble.frame=frame; // Model and touch frames move together, no stale CA hit area.
    }
    for(NSUInteger lane=0;lane<lanes && self.pending.count;lane++) {
        BOOL busy=NO;
        for(ZNSDanmuBubble *bubble in self.active) if(bubble.lane==lane) busy=YES;
        if(busy) continue;
        ZNSDanmuEntry *entry=self.pending.firstObject; [self.pending removeObjectAtIndex:0];
        ZNSDanmuBubble *bubble=[ZNSDanmuBubble new]; bubble.entry=entry;
        bubble.lane=lane; bubble.birth=now;
        bubble.label=[UILabel new]; bubble.label.font=[UIFont systemFontOfSize:15*ZNSDanmuScale weight:UIFontWeightMedium];
        bubble.label.text=entry.text; bubble.label.textColor=ZNSDanmuLight?UIColor.blackColor:UIColor.whiteColor;
        bubble.label.lineBreakMode=NSLineBreakByTruncatingTail;
        CGFloat width=MIN(safe.size.width-16,MAX(160*ZNSDanmuScale,[bubble.label sizeThatFits:CGSizeMake(800,height)].width+28*ZNSDanmuScale));
        bubble.frame=CGRectMake(CGRectGetMaxX(safe),CGRectGetMinY(safe)+8+lane*(height+gap),width,height);
        bubble.label.frame=CGRectInset(bubble.bounds,14*ZNSDanmuScale,0);
        bubble.backgroundColor=[UIColor colorWithWhite:ZNSDanmuLight?0.96:0.08 alpha:1];
        bubble.alpha=ZNSDanmuOpacity; bubble.layer.cornerRadius=height/2; bubble.clipsToBounds=YES;
        bubble.isAccessibilityElement=YES; bubble.accessibilityLabel=entry.text;
        bubble.accessibilityTraits=UIAccessibilityTraitButton;
        [bubble addSubview:bubble.label]; [bubble addTarget:self action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.root.view addSubview:bubble]; ZNSSetLayerInputOpaque(bubble.layer,YES);
        [self.active addObject:bubble];
    }
    if(!self.active.count && !self.pending.count) [self clear];
}
- (void)tapped:(ZNSDanmuBubble *)bubble {
    if(!ZNSDanmuEnabled || !ZNSDanmuUnlocked() || !ZNSReadAuthorization(YES)) return;
    ZNSDanmuEntry *entry=bubble.entry;
    if(entry.test) { [bubble removeFromSuperview]; [self.active removeObject:bubble]; return; }
    NSString *mode=[ZNSDanmuMode copy], *front=ZNSDanmuForeground();
    if([mode isEqual:@"system"] || [front isEqual:entry.bundle]) {
        if(ZNSDanmuNativeOpen(entry)) { [bubble removeFromSuperview]; [self.active removeObject:bubble]; }
        return;
    }
    if(![ZNSWindowManager.shared canOpenNotificationBundleIdentifier:entry.bundle mode:mode]) return;
    NSUInteger generation=++ZNSDanmuGeneration;
    [ZNSDanmuPreparation cancel]; ZNSDanmuPreparation=nil;
    __weak typeof(self) weakSelf=self;
    ZNSDanmuPreparation=[ZNSWindowManager.shared prepareNotificationBundleIdentifier:entry.bundle mode:mode whenReady:^(BOOL ready) {
        if(generation!=ZNSDanmuGeneration) return;
        ZNSWindowActivation *request=ZNSDanmuPreparation; ZNSDanmuPreparation=nil;
        NSString *current=ZNSDanmuForeground();
        BOOL same=current==front || [current isEqual:front];
        if(!ready || !same || !ZNSDanmuEnabled || !ZNSDanmuUnlocked() || ![mode isEqual:ZNSDanmuMode] || !ZNSReadAuthorization(YES)) { [request cancel]; return; }
        if([request commit]) { [bubble removeFromSuperview]; [weakSelf.active removeObject:bubble]; }
        else [request cancel];
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        if(generation!=ZNSDanmuGeneration) return;
        ++ZNSDanmuGeneration; [ZNSDanmuPreparation cancel]; ZNSDanmuPreparation=nil;
    });
}
@end

static NSString *ZNSDanmuText(id object,NSString *key) {
    id value=ZNSDanmuObject(object,key);
    return [value isKindOfClass:NSString.class]?value:nil;
}
static void ZNSDanmuPost(id destination,SEL selector,id request,id coalesced) {
    BOOL handled=NO;
    if(NSThread.isMainThread && ZNSDanmuEnabled && ZNSDanmuUnlocked() && ZNSDanmuLandscape()) {
        id content=ZNSDanmuObject(request,@"content");
        id bulletin=ZNSDanmuObject(request,@"bulletin");
        NSString *bundle=ZNSDanmuText(request,@"sectionIdentifier");
        NSString *title=ZNSDanmuText(content,@"title") ?: ZNSDanmuText(content,@"header");
        NSString *message=ZNSDanmuText(content,@"message");
        // Alarms and critical alerts are never replaced. Only banner-destination
        // delivery is intercepted: notification storage and sounds remain native.
        BOOL critical=ZNSDanmuBool(request,@"isCriticalAlert",NO) || ZNSDanmuBool(content,@"isCriticalAlert",NO) || ZNSDanmuBool(bulletin,@"isCriticalAlert",NO);
        if(!critical && ![bundle isEqual:@"com.apple.mobiletimer"] &&
           bundle.length && [ZNSWindowManager.shared canOpenBundleIdentifier:bundle] &&
           (title.length || message.length) && ZNSDanmuObject(request,@"defaultAction")) {
            ZNSDanmuEntry *entry=[ZNSDanmuEntry new]; entry.request=request;
            entry.runner=ZNSDanmuObject(destination,@"actionRunner");
            if(!ZNSDanmuNativeSelector(entry.runner)) entry.runner=ZNSDanmuObject(ZNSDanmuObject(destination,@"notificationDispatcher"),@"actionRunner");
            if(!ZNSDanmuNativeSelector(entry.runner)) entry.runner=ZNSDanmuObject(ZNSDanmuObject(NSClassFromString(@"NCNotificationDispatcher"),@"sharedInstance"),@"actionRunner");
            entry.bundle=bundle;
            entry.text=title.length && message.length?[NSString stringWithFormat:@"%@：%@",title,message]:(title.length?title:message);
            if(entry.text.length>500) entry.text=[entry.text substringToIndex:500];
            entry.identifier=ZNSDanmuText(request,@"notificationIdentifier") ?: ZNSDanmuText(request,@"requestIdentifier") ?: NSUUID.UUID.UUIDString;
            // If native opening cannot be preserved, leave the original banner.
            if(ZNSDanmuNativeSelector(entry.runner)) handled=[ZNSDanmuPresenter.shared enqueue:entry];
        }
    }
    if(!handled && ZNSDanmuOriginalPost) ZNSDanmuOriginalPost(destination,selector,request,coalesced);
}
void ZNSClearDanmuNotifications(void) {
    ++ZNSDanmuGeneration; [ZNSDanmuPreparation cancel]; ZNSDanmuPreparation=nil;
    [ZNSDanmuPresenter.shared clear];
}
void ZNSReloadDanmuPreferences(void) {
    ZNSClearDanmuNotifications();
    BOOL synced=CFPreferencesAppSynchronize(CFSTR(APELIN_PACKAGE_ID));
    id enabled=ZNSDanmuPreference(@"DanmuEnabled"), total=ZNSDanmuPreference(@"Enabled");
    ZNSDanmuEnabled=synced && ZNSReadAuthorization(NO) && [total boolValue] && (!enabled || [enabled boolValue]);
    ZNSDanmuLight=[ZNSDanmuPreference(@"DanmuLight") boolValue];
    ZNSDanmuScale=ZNSDanmuNumber(@"DanmuScale",100,60,160)/100;
    ZNSDanmuOpacity=ZNSDanmuNumber(@"DanmuOpacity",88,20,100)/100;
    id mode=ZNSDanmuPreference(@"DanmuOpenMode");
    ZNSDanmuMode=[@[@"main",@"parked",@"parked2",@"dip",@"system"] containsObject:mode]?mode:@"main";
}
void ZNSInstallDanmuNotifications(void) {
    static dispatch_once_t once;
    dispatch_once(&once,^{
        Class cls=NSClassFromString(@"SBNotificationBannerDestination");
        SEL selector=NSSelectorFromString(@"postNotificationRequest:forCoalescedNotification:");
        Method method=class_getInstanceMethod(cls,selector);
        if(method) {
            NSMethodSignature *sig=[NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
            if(sig.numberOfArguments==4 && !strcmp(sig.methodReturnType,"v") &&
               [sig getArgumentTypeAtIndex:2][0]=='@' && [sig getArgumentTypeAtIndex:3][0]=='@')
                MSHookMessageEx(cls,selector,(IMP)ZNSDanmuPost,(IMP *)&ZNSDanmuOriginalPost);
        }
        static int testToken;
        notify_register_dispatch(APELIN_PACKAGE_ID "/danmu-test",&testToken,dispatch_get_main_queue(),^(int token){
            (void)token;
            NSUInteger generation=ZNSDanmuGeneration;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),dispatch_get_main_queue(),^{
                if(generation!=ZNSDanmuGeneration || !ZNSReadAuthorization(YES)) return;
                ZNSDanmuEntry *entry=[ZNSDanmuEntry new]; entry.test=YES;
                entry.text=@"曾牛分屏：横屏弹幕测试通知，轻点关闭"; entry.identifier=NSUUID.UUID.UUIDString;
                [ZNSDanmuPresenter.shared enqueue:entry];
            });
        });
    });
}
