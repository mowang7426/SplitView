#import "ZNSKeyboardFocus.h"
#if ZNS_ENABLE_SBS_KEYBOARD_EXPERIMENT
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>
#include <string.h>
#include <unistd.h>

// These selectors/ABI are preserved from the archived alpha25 source, NOT a
// newly verified service contract. In particular @? does not prove the block's
// payload contract. SIGTRAP cannot be caught by @catch. Never enable by default.
static os_log_t ZNSFocusLog(void) {
    static os_log_t log; static dispatch_once_t once;
    dispatch_once(&once,^{ log=os_log_create(APELIN_PACKAGE_ID,"keyboard-focus-experiment"); });
    return log;
}
static const char *ZNSFocusType(const char *type) {
    while (*type && strchr("rnNoORV",*type)) ++type;
    return type;
}
static BOOL ZNSFocusSignature(id object,SEL selector,const char *result,NSArray<NSString *> *arguments) {
    if (!object) return NO;
    Method method=class_getInstanceMethod(object_getClass(object),selector);
    if (!method) return NO;
    NSMethodSignature *sig=[NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if (sig.numberOfArguments!=arguments.count+2 || strcmp(ZNSFocusType(sig.methodReturnType),result)) return NO;
    for (NSUInteger i=0;i<arguments.count;i++)
        if (strcmp(ZNSFocusType([sig getArgumentTypeAtIndex:i+2]),arguments[i].UTF8String)) return NO;
    return YES;
}
static SEL ZNSFocusRequest(void) { return NSSelectorFromString(@"requestKeyboardFocusForSceneIdentity:processID:completion:"); }
static SEL ZNSFocusRemove(void) { return NSSelectorFromString(@"removeKeyboardFocusFromSceneIdentity:processID:"); }
static BOOL ZNSFocusClaimFuse(void) {
    // Main-thread serialized, persistent across versions and crashes. Existing
    // alpha46 consumption is intentionally NOT reset or given a new key.
    static BOOL claimed;
    if (!NSThread.isMainThread || claimed) return NO;
    claimed=YES;
    CFStringRef domain=CFSTR(APELIN_PACKAGE_ID);
    CFStringRef key=CFSTR("LegacySBSFocusTrialConsumedV1");
    if (!CFPreferencesAppSynchronize(domain)) return NO;
    id previous=CFBridgingRelease(CFPreferencesCopyAppValue(key,domain));
    if (previous) return NO;
    CFPreferencesSetAppValue(key,kCFBooleanTrue,domain);
    if (!CFPreferencesAppSynchronize(domain)) return NO;
    id saved=CFBridgingRelease(CFPreferencesCopyAppValue(key,domain));
    return [saved isEqual:@YES];
}
static void ZNSFocusRelease(id service,id identity,int pid) {
    if (!service || !identity || pid<=0) return;
    @try {
        ((void(*)(id,SEL,id,int))objc_msgSend)(service,ZNSFocusRemove(),identity,pid);
    } @catch (NSException *exception) {
        os_log_error(ZNSFocusLog(),"scoped SBS removal exception=%{public}@",exception.name);
    }
}
@interface ZNSKeyboardFocus ()
@property(nonatomic,weak) id scene;
@property(nonatomic,strong) id identity;
@property(nonatomic,strong) id process;
@property(nonatomic,strong) id service;
@property(nonatomic) int processID;
@property(nonatomic) BOOL attempted;
@property(nonatomic) BOOL invalidated;
@property(nonatomic) BOOL callbackSeen;
@property(nonatomic,readwrite) BOOL screenKeyboardRequested;
@end
@implementation ZNSKeyboardFocus
+ (BOOL)experimentEnabled { return YES; }
- (instancetype)initWithScene:(id)scene {
    if (!NSThread.isMainThread || !scene) return nil;
    if ((self=[super init])) _scene=scene;
    return self;
}
- (BOOL)captureIdentity {
    id scene=self.scene;
    SEL identitySelector=NSSelectorFromString(@"identity");
    SEL processSelector=NSSelectorFromString(@"clientProcess");
    SEL pidSelector=NSSelectorFromString(@"pid");
    if (!ZNSFocusSignature(scene,identitySelector,"@",@[]) ||
        !ZNSFocusSignature(scene,processSelector,"@",@[])) return NO;
    id identity=((id(*)(id,SEL))objc_msgSend)(scene,identitySelector);
    id process=((id(*)(id,SEL))objc_msgSend)(scene,processSelector);
    if (![identity isKindOfClass:NSClassFromString(@"FBSSceneIdentity")] ||
        !ZNSFocusSignature(process,pidSelector,@encode(int),@[])) return NO;
    int pid=((int(*)(id,SEL))objc_msgSend)(process,pidSelector);
    if (pid<=0 || pid==getpid()) return NO;
    self.identity=identity; self.process=process; self.processID=pid;
    return YES;
}
- (void)setActive:(BOOL)active {
    if (!NSThread.isMainThread || self.invalidated) return;
    if (!active) { [self invalidate]; return; }
    if (self.attempted) return;
    self.attempted=YES;
    @try {
        if (![self captureIdentity]) { [self invalidate]; return; }
        // Check instance ABI without constructing a service before the fuse.
        Class cls=NSClassFromString(@"SBSKeyboardFocusService");
        Method request=class_getInstanceMethod(cls,ZNSFocusRequest());
        Method remove=class_getInstanceMethod(cls,ZNSFocusRemove());
        if (!request || !remove || !ZNSFocusClaimFuse()) {
            os_log_error(ZNSFocusLog(),"SBS experiment blocked: unavailable ABI or consumed persistent fuse");
            [self invalidate]; return;
        }
        id service=[cls new];
        if (!ZNSFocusSignature(service,ZNSFocusRequest(),@encode(void),@[@"@",@(@encode(int)),@"@?"]) ||
            !ZNSFocusSignature(service,ZNSFocusRemove(),@encode(void),@[@"@",@(@encode(int))])) {
            [self invalidate]; return;
        }
        self.service=service;
        self.screenKeyboardRequested=YES; // Submitted only, never "granted".
        id identity=self.identity; int pid=self.processID;
        __weak typeof(self) weakSelf=self;
        __weak id weakService=service;
        void (^completion)(void)=^{
            dispatch_async(dispatch_get_main_queue(),^{
                ZNSKeyboardFocus *owner=weakSelf;
                // Same identity/PID only. No retry, even after a late callback.
                if (!owner || owner.invalidated) { ZNSFocusRelease(weakService,identity,pid); return; }
                owner.callbackSeen=YES;
                os_log(ZNSFocusLog(),"SBS callback received; focus grant, fullscreen keyboard and text delivery UNVERIFIED");
            });
        };
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),dispatch_get_main_queue(),^{
            ZNSKeyboardFocus *owner=weakSelf;
            if (owner && !owner.callbackSeen) [owner invalidate];
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC),dispatch_get_main_queue(),^{
            [weakSelf invalidate];
        });
        // Focus the hosted App scene, not our overlay window. Do not fabricate
        // an input field, force first responder, launch fullscreen, or send text.
        ((void(*)(id,SEL,id,int,id))objc_msgSend)(service,ZNSFocusRequest(),identity,pid,completion);
    } @catch (NSException *exception) {
        os_log_error(ZNSFocusLog(),"SBS experiment exception=%{public}@ (SIGTRAP is NOT catchable)",exception.name);
        [self invalidate];
    }
}
- (void)invalidate {
    if (!NSThread.isMainThread || self.invalidated) return;
    self.invalidated=YES;
    BOOL submitted=self.screenKeyboardRequested;
    self.screenKeyboardRequested=NO;
    id service=self.service; self.service=nil;
    if (submitted) ZNSFocusRelease(service,self.identity,self.processID);
    void (^ended)(void)=self.didEndExperiment; self.didEndExperiment=nil;
    if (ended) ended();
}
- (void)dealloc {
    // A late service callback has its own identity-scoped cleanup above.
    if (_screenKeyboardRequested) {
        id service=_service,identity=_identity; int pid=_processID;
        if (NSThread.isMainThread) ZNSFocusRelease(service,identity,pid);
        else dispatch_async(dispatch_get_main_queue(),^{ ZNSFocusRelease(service,identity,pid); });
    }
}
@end
#else
// Normal builds keep the exact inert behavior: no service, preferences, timers
// or request/removal selectors are touched by this compatibility implementation.
@implementation ZNSKeyboardFocus
+ (BOOL)experimentEnabled { return NO; }
- (instancetype)initWithScene:(id)scene { (void)scene; return nil; }
- (BOOL)screenKeyboardRequested { return NO; }
- (void)setActive:(BOOL)active { (void)active; }
- (void)invalidate {}
@end
#endif
