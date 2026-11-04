// SPDX-License-Identifier: MIT
// Based on Apelin's Objective-C hook template.
#import <UIKit/UIKit.h>
#import <os/log.h>
#import <substrate.h>
#import <notify.h>
#import "ZNSPrivate.h"
#import "ZNSWindowManager.h"
#import "ZNSActivationHooks.h"
#import "ZNSSwitcherHooks.h"
#import "ZNSKeyboardClient.h"
#import "ZNSDesktopRotation.h"
#import "ZNSDanmuNotifications.h"

static os_log_t TweakLog(void) {
    static os_log_t log; static dispatch_once_t once;
    dispatch_once(&once, ^{ log=os_log_create(APELIN_PACKAGE_ID,"tweak"); });
    return log;
}
static void (*OriginalDidFinishLaunching)(id,SEL,id);
static void (*OriginalIconDidMoveToWindow)(id,SEL);
static void (*ZNSOriginalIconLayoutSubviews)(id,SEL);
static void (*OriginalLockUI)(id,SEL,NSInteger,id);
static int ZNSPreferencesToken;
static int ZNSLockToken;
static NSUInteger ZNSStartupCalls;
static NSUInteger ZNSIconMoveCalls;
static BOOL ZNSIconHookInstalled;
static void ZNSScheduleStartup(void);
static void ZNSCompleteStartup(void);

// Track only SpringBoard chrome classes. Remember the system's requested
// hidden state, not our override, so releasing the policy never forces a view on.
static NSHashTable<UIView *> *ZNSDesktopViews;
static NSMutableDictionary<NSString *,NSNumber *> *ZNSDesktopClasses;
static char ZNSDesktopRequestedHiddenKey, ZNSDesktopRoleKey;
static BOOL ZNSDesktopApplying, ZNSDesktopRefreshQueued;
static BOOL ZNSDesktopReportingDock;
static BOOL ZNSDesktopForceHidden(NSUInteger role) {
    ZNSWindowManager *manager=[ZNSWindowManager shared];
    if(role==1) return [manager shouldHideDesktopDock];
    if(role==3) return [manager shouldHideDesktopPageControls];
    return [manager shouldHideDesktopIconsAndStatusBar];
}
static void ZNSTrackDesktopView(UIView *view,NSUInteger role) {
    if(!objc_getAssociatedObject(view,&ZNSDesktopRequestedHiddenKey))
        objc_setAssociatedObject(view,&ZNSDesktopRequestedHiddenKey,@(view.hidden),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view,&ZNSDesktopRoleKey,@(role),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [ZNSDesktopViews addObject:view];
    // Discovery and the existing post-layout path both report the actual Dock.
    // Reporting must only track/read geometry, never force a desktop layout.
    if(role==1 && NSThread.isMainThread && !ZNSDesktopReportingDock) {
        ZNSDesktopReportingDock=YES;
        @try { [[ZNSWindowManager shared] trackDesktopDockView:view]; }
        @finally { ZNSDesktopReportingDock=NO; }
    }
}
static void ZNSApplyDesktopView(UIView *view) {
    NSNumber *requested=objc_getAssociatedObject(view,&ZNSDesktopRequestedHiddenKey);
    if(!requested) return;
    NSUInteger role=[objc_getAssociatedObject(view,&ZNSDesktopRoleKey) unsignedIntegerValue];
    BOOL hidden=requested.boolValue || ZNSDesktopForceHidden(role);
    if(view.hidden==hidden) return;
    BOOL wasApplying=ZNSDesktopApplying; ZNSDesktopApplying=YES;
    view.hidden=hidden;
    ZNSDesktopApplying=wasApplying;
}
static void ZNSDiscoverDesktopViews(UIView *view) {
    Class iconClass=NSClassFromString(@"SBIconView");
    if (iconClass && [view isKindOfClass:iconClass] && view.window)
        [[ZNSWindowManager shared] attachGesturesToIconView:view];
    for(Class cls=view.class;cls && cls!=UIView.class;cls=class_getSuperclass(cls)) {
        NSNumber *role=ZNSDesktopClasses[NSStringFromClass(cls)];
        if(role) { ZNSTrackDesktopView(view,role.unsignedIntegerValue); break; }
    }
    for(UIView *child in view.subviews) ZNSDiscoverDesktopViews(child);
}
static void ZNSRefreshDesktopVisibility(void) {
    if(ZNSDesktopRefreshQueued) return;
    ZNSDesktopRefreshQueued=YES;
    dispatch_async(dispatch_get_main_queue(),^{
        ZNSDesktopRefreshQueued=NO;
        // Includes views created before hooks and new status-bar windows.
        for(UIScene *scene in UIApplication.sharedApplication.connectedScenes)
            if([scene isKindOfClass:UIWindowScene.class])
                for(UIWindow *window in ((UIWindowScene *)scene).windows) ZNSDiscoverDesktopViews(window);
        for(UIView *view in ZNSDesktopViews.allObjects) ZNSApplyDesktopView(view);
    });
}
static void ZNSHookDesktopClass(NSString *name,NSUInteger role) {
    Class cls=NSClassFromString(name);
    if(!cls || ![cls isSubclassOfClass:UIView.class]) return;
    // A hooked superclass already covers this class; don't chain our own override twice.
    for(Class parent=class_getSuperclass(cls);parent;parent=class_getSuperclass(parent))
        if(ZNSDesktopClasses[NSStringFromClass(parent)]) return;
    SEL hiddenSelector=@selector(setHidden:),layoutSelector=@selector(layoutSubviews);
    if(!class_getInstanceMethod(cls,hiddenSelector) || !class_getInstanceMethod(cls,layoutSelector)) return;
    __block IMP originalHidden=NULL,originalLayout=NULL;
    IMP hiddenHook=imp_implementationWithBlock(^(UIView *view,BOOL hidden){
        ZNSTrackDesktopView(view,role);
        if(!ZNSDesktopApplying)
            objc_setAssociatedObject(view,&ZNSDesktopRequestedHiddenKey,@(hidden),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        BOOL effective=ZNSDesktopApplying?hidden:(hidden || ZNSDesktopForceHidden(role));
        if(originalHidden) ((void(*)(id,SEL,BOOL))originalHidden)(view,hiddenSelector,effective);
        if(role==1) ZNSTrackDesktopView(view,role);
    });
    IMP layoutHook=imp_implementationWithBlock(^(UIView *view){
        if(originalLayout) ((void(*)(id,SEL))originalLayout)(view,layoutSelector);
        ZNSTrackDesktopView(view,role); ZNSApplyDesktopView(view);
        if(role==1) ZNSTrackDesktopView(view,role);
    });
    MSHookMessageEx(cls,hiddenSelector,hiddenHook,&originalHidden);
    MSHookMessageEx(cls,layoutSelector,layoutHook,&originalLayout);
    ZNSDesktopClasses[name]=@(role);
}
static void ZNSInstallDesktopVisibility(void) {
    ZNSDesktopViews=[NSHashTable weakObjectsHashTable];
    ZNSDesktopClasses=[NSMutableDictionary new];
    ZNSHookDesktopClass(@"SBDockView",1);
    ZNSHookDesktopClass(@"SBFloatingDockView",1);
    // Home-specific containers include the pill background, magnifier and page
    // dots, not only the search text. No generic UIPageControl/search field hook.
    ZNSHookDesktopClass(@"SBHPageControl",3);
    ZNSHookDesktopClass(@"SBIconListPageControl",3);
    ZNSHookDesktopClass(@"SBHSearchPillView",3);
    ZNSHookDesktopClass(@"SBIconListView",2);
    ZNSHookDesktopClass(@"UIStatusBar",2);
    ZNSHookDesktopClass(@"UIStatusBar_Modern",2);
    ZNSHookDesktopClass(@"_UIStatusBar",2);
    ZNSHookDesktopClass(@"SBStatusBarView",2);
    [[NSNotificationCenter defaultCenter] addObserverForName:@"ZNSDesktopVisibilityChanged" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){
        (void)note; ZNSRefreshDesktopVisibility();
    }];
}

static void ZNSDiagnosticTick(NSUInteger remaining) {
    os_log(TweakLog(),"ZNS diag build=%{public}s startup=%lu iconClass=%d iconHook=%d iconCallbacks=%lu",APELIN_BUILD_ID,(unsigned long)ZNSStartupCalls,NSClassFromString(@"SBIconView")!=Nil,ZNSIconHookInstalled,(unsigned long)ZNSIconMoveCalls);
    [[ZNSWindowManager shared] emitDiagnostics];
    if (remaining%2==0) {
        for (NSString *name in @[@"SBApplicationSceneHandle",@"FBScene",@"SBSceneView",@"UIApplicationSceneSettings",@"UIApplicationSceneClientSettings"]) {
            for (Class cls=NSClassFromString(name); cls && cls!=NSObject.class; cls=class_getSuperclass(cls)) {
                unsigned count=0;
                Method *methods=class_copyMethodList(cls,&count);
                for (unsigned i=0;i<count;i++) {
                    NSString *selector=NSStringFromSelector(method_getName(methods[i]));
                    if ([selector hasPrefix:@"newSceneView"] || [selector hasPrefix:@"updateSettings"] || [selector localizedCaseInsensitiveContainsString:@"orientation"] || [selector localizedCaseInsensitiveContainsString:@"referenceSize"])
                        os_log(TweakLog(),"ZNS runtime API %{public}@ %{public}@ %{public}s",NSStringFromClass(cls),selector,method_getTypeEncoding(methods[i]));
                }
                free(methods);
            }
        }
    }
    if (remaining>1) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),dispatch_get_main_queue(),^{ ZNSDiagnosticTick(remaining-1); });
}

static void ZNSReloadStartupPreferences(void) {
    os_log(TweakLog(),"ZNS startup preferences manager begin");
    [[ZNSWindowManager shared] reloadPreferences];
    os_log(TweakLog(),"ZNS startup preferences activation begin");
    ZNSReloadActivationPreferences();
    os_log(TweakLog(),"ZNS startup preferences rotation begin");
    ZNSReloadDesktopRotationPreferences();
    os_log(TweakLog(),"ZNS startup preferences danmu begin");
    ZNSReloadDanmuPreferences();
    os_log(TweakLog(),"ZNS startup preferences complete");
}
static void HookedDidFinishLaunching(id self,SEL cmd,id application) {
    ZNSStartupCalls++;
    if (OriginalDidFinishLaunching) OriginalDidFinishLaunching(self,cmd,application);
    os_log(TweakLog(),"ApelinHooked %{public}s -[SpringBoard applicationDidFinishLaunching:]",APELIN_BUILD_ID);
    ZNSScheduleStartup();
}
static void ZNSCompleteStartup(void) {
    ZNSReloadStartupPreferences();
    ZNSRefreshDesktopVisibility(); // Attach to icons already on screen.
    notify_register_dispatch("com.zengniu.splitview/changed",&ZNSPreferencesToken,dispatch_get_main_queue(),^(int token){
        (void)token; ZNSReloadStartupPreferences();
    });
    notify_register_dispatch("com.apple.springboard.lockstate",&ZNSLockToken,dispatch_get_main_queue(),^(int token){
        (void)token;
        if (ZNSBool(ZNSShared(@"SBLockScreenManager"),@"isUILocked")) {
            ZNSClearDanmuNotifications();
            [[ZNSWindowManager shared] closeForDeviceLock];
            ZNSCancelSwitcherActivation();
        }
    });
    BOOL handle=class_getInstanceMethod(NSClassFromString(@"SBSceneManager"),@selector(existingSceneHandleForScene:))!=NULL;
    BOOL view=class_getInstanceMethod(NSClassFromString(@"SBSceneView"),@selector(setDisplayMode:animationFactory:completion:))!=NULL;
    os_log(TweakLog(),"ZNS capability sceneHandle=%d liveView=%d",handle,view);
}
static void ZNSIconDidMoveToWindow(id self,SEL cmd) {
    ZNSIconMoveCalls++;
    if (OriginalIconDidMoveToWindow) OriginalIconDidMoveToWindow(self,cmd);
    if ([(UIView *)self window]) [[ZNSWindowManager shared] attachGesturesToIconView:self];
}
static void ZNSIconLayoutSubviews(id self,SEL cmd) {
    if (ZNSOriginalIconLayoutSubviews) ZNSOriginalIconLayoutSubviews(self,cmd);
    if ([(UIView *)self window]) [[ZNSWindowManager shared] attachGesturesToIconView:self];
}
static void ZNSLockUI(id self,SEL cmd,NSInteger source,id options) {
    // Release all remote content before the lock screen becomes visible.
    ZNSClearDanmuNotifications();
    [[ZNSWindowManager shared] closeForDeviceLock];
    ZNSCancelSwitcherActivation();
    if (OriginalLockUI) OriginalLockUI(self,cmd,source,options);
}
static id ZNSLaunchObserver;
static void ZNSScheduleStartup(void) {
    // Never install feature hooks or read preferences inside dyld's constructor
    // or the system's launch callback. Return first, then initialize once on the
    // main queue. No synchronous dispatch, semaphore, sleep or polling loop.
    dispatch_async(dispatch_get_main_queue(),^{
        static BOOL started;
        if(started) return;
        started=YES;
        if(ZNSLaunchObserver) {
            [NSNotificationCenter.defaultCenter removeObserver:ZNSLaunchObserver];
            ZNSLaunchObserver=nil;
        }
        os_log(TweakLog(),"ZNS startup rotation hooks begin build=%{public}s",APELIN_BUILD_ID);
        ZNSInstallDesktopRotation();
        os_log(TweakLog(),"ZNS startup desktop hooks begin");
        ZNSInstallDesktopVisibility();
        os_log(TweakLog(),"ZNS startup activation hooks begin");
        ZNSInstallActivationHooks();
        os_log(TweakLog(),"ZNS startup danmu hooks begin");
        ZNSInstallDanmuNotifications();
        Class icon=NSClassFromString(@"SBIconView");
        if (class_getInstanceMethod(icon,@selector(didMoveToWindow))) {
            MSHookMessageEx(icon,@selector(didMoveToWindow),(IMP)ZNSIconDidMoveToWindow,(IMP *)&OriginalIconDidMoveToWindow);
            ZNSIconHookInstalled=OriginalIconDidMoveToWindow!=NULL;
        }
        if (class_getInstanceMethod(icon,@selector(layoutSubviews)))
            MSHookMessageEx(icon,@selector(layoutSubviews),(IMP)ZNSIconLayoutSubviews,(IMP *)&ZNSOriginalIconLayoutSubviews);
        Class lock=NSClassFromString(@"SBLockScreenManager");
        SEL selector=NSSelectorFromString(@"lockUIFromSource:withOptions:");
        if (class_getInstanceMethod(lock,selector))
            MSHookMessageEx(lock,selector,(IMP)ZNSLockUI,(IMP *)&OriginalLockUI);
        ZNSCompleteStartup();
        os_log(TweakLog(),"ZNS startup complete build=%{public}s",APELIN_BUILD_ID);
#if DEBUG
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),dispatch_get_main_queue(),^{ ZNSDiagnosticTick(36); });
#endif
    });
}
__attribute__((constructor)) static void TweakInitialize(void) {
    os_log(TweakLog(),"ApelinLoaded %{public}s in %{public}s",APELIN_BUILD_ID,getprogname());
    Class springBoard=objc_getClass("SpringBoard");
    if (!springBoard) {
        dispatch_async(dispatch_get_main_queue(),^{ ZNSInstallKeyboardClient(); });
        return;
    }
    // The public launch notification is also a fallback when a private launch
    // selector disappears or changes ABI on another iOS release.
    ZNSLaunchObserver=[NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:nil usingBlock:^(NSNotification *note){
        (void)note; ZNSScheduleStartup();
    }];
    SEL selector=@selector(applicationDidFinishLaunching:);
    Method method=class_getInstanceMethod(springBoard,selector);
    char result[16]={0},argument[16]={0};
    if(method) {
        method_getReturnType(method,result,sizeof(result));
        method_getArgumentType(method,2,argument,sizeof(argument));
    }
    if(method && method_getNumberOfArguments(method)==3 && result[0]=='v' && argument[0]=='@')
        MSHookMessageEx(springBoard,selector,(IMP)HookedDidFinishLaunching,(IMP *)&OriginalDidFinishLaunching);
    else os_log(TweakLog(),"ZNS launch selector unavailable or ABI changed; waiting for application launch notification");
}
