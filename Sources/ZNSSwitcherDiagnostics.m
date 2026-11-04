#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <os/log.h>

// Read class metadata only, inside SpringBoard where these frameworks may load.
// No singleton creation, object inspection, screen access or state mutation.
#if DEBUG
static void ZNSCardABITick(NSUInteger remaining) {
    static os_log_t log;
    if (!log) log=os_log_create(APELIN_PACKAGE_ID,"switcher-abi");
    NSDictionary<NSString *,NSArray<NSString *> *> *checks=@{
        @"SBFluidSwitcherItemContainer":@[@"layoutSubviews",@"didMoveToWindow",@"appLayout",@"killingProgress",@"_updateTransformForCurrentHighlight"],
        @"SBReusableSnapshotItemContainer":@[@"layoutSubviews",@"didMoveToWindow",@"appLayout",@"killingProgress",@"_updateTransformForCurrentHighlight"],
        @"SBAppLayout":@[@"homeScreenAppLayout",@"bundleIdentifier",@"continuousExposeIdentifier",@"allItems",@"rolesToLayoutItemsMap"],
        @"SBAppLayoutItem":@[@"bundleIdentifier",@"displayItem"],
        @"SBDisplayItem":@[@"bundleIdentifier",@"displayIdentifier"],
        @"SBMainSwitcherControllerCoordinator":@[@"sharedInstance",@"coordinatedSwitcherControllers",@"isAnySwitcherVisible",@"isMainSwitcherVisible",@"_dismissSwitcherNoninteractivelyToAppLayout:dismissFloatingSwitcher:animated:"],
        @"SBMainSwitcherViewController":@[@"sharedInstance",@"coordinatedSwitcherControllers",@"isAnySwitcherVisible",@"isMainSwitcherVisible",@"_dismissSwitcherNoninteractivelyToAppLayout:dismissFloatingSwitcher:animated:"],
        @"SBMainSwitcherController":@[@"sharedInstance",@"isAnySwitcherVisible",@"isMainSwitcherVisible",@"_dismissSwitcherNoninteractivelyToAppLayout:dismissFloatingSwitcher:animated:"],
        @"SBApplicationController":@[@"sharedInstance",@"applicationWithBundleIdentifier:"],
        @"SBLockScreenManager":@[@"sharedInstance",@"isUILocked"]
    };
    os_log(log,"card ABI build=%{public}s remaining=%lu",APELIN_BUILD_ID,(unsigned long)remaining);
    for (NSString *name in checks) {
        Class cls=NSClassFromString(name);
        if (!cls) { os_log(log,"card ABI class=%{public}@ missing",name); continue; }
        for (NSString *s in checks[name]) {
            SEL selector=NSSelectorFromString(s);
            Method instance=class_getInstanceMethod(cls,selector),meta=class_getClassMethod(cls,selector);
            os_log(log,"card ABI %{public}@ %{public}@ instance=%{public}s class=%{public}s",name,s,
                instance?method_getTypeEncoding(instance):"missing",meta?method_getTypeEncoding(meta):"missing");
        }
        if ([name isEqualToString:@"SBAppLayout"]) {
            Ivar ivar=class_getInstanceVariable(cls,"_rolesToLayoutItemsMap");
            os_log(log,"card ABI layout map=%{public}s",ivar?ivar_getTypeEncoding(ivar):"missing");
        }
    }
    if (remaining>1) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),dispatch_get_main_queue(),^{ZNSCardABITick(remaining-1);});
}
__attribute__((constructor)) static void ZNSCardABIStart(void) {
    if (!NSClassFromString(@"SpringBoard")) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),dispatch_get_main_queue(),^{ZNSCardABITick(8);});
}
#endif
