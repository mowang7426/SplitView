#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <stdatomic.h>
#import <stdbool.h>
#import <string.h>
#import <stdlib.h>
#import "ZNSDesktopRotation.h"
#import "ZNSLandscapeStatusLayout.h"
#import "ZNSLandscapeIconGrid.h"
#import "ZNSAuthorization.h"
#import "ZNSPrivate.h"

// Only Home Screen policy is widened. Never rotate layers, spoof device type,
// rewrite system gesture edges, or force orientation on an App/Lock Screen.
static atomic_bool ZNSDesktopRotationEnabled;
static BOOL ZNSDesktopRotationCapable;
static NSHashTable<UIViewController *> *ZNSDesktopRotationControllers;

BOOL ZNSDesktopRotationIsEnabled(void) {
    return UIDevice.currentDevice.userInterfaceIdiom!=UIUserInterfaceIdiomPad &&
        atomic_load(&ZNSDesktopRotationEnabled);
}

static BOOL ZNSDesktopRotationPreference(NSString *key) {
    id value=CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key,CFSTR(APELIN_PACKAGE_ID)));
    return [value isKindOfClass:NSNumber.class] && [value boolValue];
}
static void ZNSReadDesktopRotationPolicy(void) {
    BOOL enabled=UIDevice.currentDevice.userInterfaceIdiom!=UIUserInterfaceIdiomPad &&
        ZNSDesktopRotationCapable && ZNSReadAuthorization(NO) &&
        ZNSDesktopRotationPreference(@"Enabled") && ZNSDesktopRotationPreference(@"DesktopRotationEnabled");
    atomic_store(&ZNSDesktopRotationEnabled,enabled);
}
static BOOL ZNSDesktopRotationGetter(Class cls,SEL selector,const char *type) {
    Method method=class_getInstanceMethod(cls,selector);
    if(!method || method_getNumberOfArguments(method)!=2) return NO;
    char *actual=method_copyReturnType(method);
    BOOL matches=actual && !strcmp(actual,type);
    free(actual);
    return matches;
}
static void ZNSTrackRotationController(id object) {
    if(NSThread.isMainThread && [object isKindOfClass:UIViewController.class])
        [ZNSDesktopRotationControllers addObject:object];
}
static BOOL ZNSHookDesktopRotationBoolean(NSString *name,NSString *methodName,BOOL trackController) {
    Class cls=NSClassFromString(name); SEL selector=NSSelectorFromString(methodName);
    if(!ZNSDesktopRotationGetter(cls,selector,@encode(BOOL))) return NO;
    __block IMP original=NULL;
    IMP replacement=imp_implementationWithBlock(^BOOL(id object){
        BOOL native=original?((BOOL(*)(id,SEL))original)(object,selector):NO;
        if(trackController) ZNSTrackRotationController(object);
        return atomic_load(&ZNSDesktopRotationEnabled)?YES:native;
    });
    MSHookMessageEx(cls,selector,replacement,&original);
    return original!=NULL;
}
static BOOL ZNSHookDesktopOrientationMask(NSString *className) {
    Class cls=NSClassFromString(className);
    if(!cls || ![cls isSubclassOfClass:UIViewController.class]) return NO;
    SEL selector=@selector(supportedInterfaceOrientations);
    if(!ZNSDesktopRotationGetter(cls,selector,@encode(UIInterfaceOrientationMask))) return NO;
    __block IMP original=NULL;
    IMP replacement=imp_implementationWithBlock(^UIInterfaceOrientationMask(id object){
        UIInterfaceOrientationMask native=original?((UIInterfaceOrientationMask(*)(id,SEL))original)(object,selector):UIInterfaceOrientationMaskPortrait;
        ZNSTrackRotationController(object);
        return atomic_load(&ZNSDesktopRotationEnabled)?(native|UIInterfaceOrientationMaskLandscape):native;
    });
    MSHookMessageEx(cls,selector,replacement,&original);
    return original!=NULL;
}
static void ZNSInstallSwitcherRotation(void) {
    // The switcher has a separate rotation policy from Home. Keep the real
    // controller/layout pipeline in charge of card geometry and hit testing.
    BOOL settings=ZNSHookDesktopRotationBoolean(@"SBAppSwitcherSettings",@"supportsRotation",NO);
    NSMutableArray<Class> *hooked=[NSMutableArray new];
    NSUInteger controllers=0;
    for(NSString *name in @[@"SBMainSwitcherViewController",@"SBFluidSwitcherViewController"]) {
        Class cls=NSClassFromString(name);
        if(!cls || ![cls isSubclassOfClass:UIViewController.class]) continue;
        BOOL covered=NO;
        for(Class base in hooked) if([cls isSubclassOfClass:base]) { covered=YES; break; }
        if(covered) continue;
        BOOL mask=ZNSHookDesktopOrientationMask(name);
        BOOL rotate=ZNSHookDesktopRotationBoolean(name,@"shouldAutorotate",YES);
        if(mask && rotate) { [hooked addObject:cls]; controllers++; }
    }
    os_log(ZNSLog(),"switcher native rotation hooks settings=%d controllers=%lu; card layout and gestures unverified",settings,(unsigned long)controllers);
}
void ZNSReloadDesktopRotationPreferences(void) {
    CFPreferencesAppSynchronize(CFSTR(APELIN_PACKAGE_ID));
    BOOL previous=atomic_load(&ZNSDesktopRotationEnabled);
    ZNSReadDesktopRotationPolicy();
    BOOL enabled=atomic_load(&ZNSDesktopRotationEnabled);
    if(previous==enabled) return;
    ZNSRefreshLandscapeStatusLayout();
    ZNSRefreshLandscapeIconGrid();
    // Ask only controllers already encountered through the Home Screen hooks.
    // UIKit/SpringBoard keeps responsibility for rotation lock, scene geometry,
    // Dock/icon layout and system panel gesture coordinates.
    dispatch_async(dispatch_get_main_queue(),^{
        for(UIViewController *controller in ZNSDesktopRotationControllers.allObjects) {
            if(@available(iOS 16.0,*)) [controller setNeedsUpdateOfSupportedInterfaceOrientations];
        }
    });
    os_log(ZNSLog(),"desktop native rotation enabled=%d; Home/Dock/system-panel behaviour unverified",enabled);
}
void ZNSInstallDesktopRotation(void) {
    // iPad already owns Home, Dock, system-panel and switcher rotation.
    // Do not install even dormant iPhone policy/layout hooks there.
    if(UIDevice.currentDevice.userInterfaceIdiom==UIUserInterfaceIdiomPad) return;
    static dispatch_once_t once;
    dispatch_once(&once,^{
        ZNSDesktopRotationControllers=[NSHashTable weakObjectsHashTable];
        BOOL platform=ZNSHookDesktopRotationBoolean(@"SBPlatformController",@"homeScreenSupportsRotation",NO);
        BOOL application=ZNSHookDesktopRotationBoolean(@"SpringBoard",@"homeScreenSupportsRotation",NO);
        BOOL mask=ZNSHookDesktopOrientationMask(@"SBHomeScreenViewController");
        BOOL autorotate=ZNSHookDesktopRotationBoolean(@"SBHomeScreenViewController",@"shouldAutorotate",YES);
        ZNSDesktopRotationCapable=(platform || application) && mask && autorotate;
        ZNSInstallLandscapeIconGrid();
        ZNSInstallLandscapeStatusLayout();
        ZNSInstallSwitcherRotation();
        // Leave native rotation policy in place until the post-launch reload.
        // CFPreferencesCopyAppValue may contact cfprefsd too: avoiding only
        // AppSynchronize was not enough to keep the loader path free of IPC.
        atomic_store(&ZNSDesktopRotationEnabled,false);
        os_log(ZNSLog(),"desktop rotation hooks platform=%d application=%d mask=%d autorotate=%d enabled=%d; unsupported sets retain native policy",platform,application,mask,autorotate,atomic_load(&ZNSDesktopRotationEnabled));
    });
}
