#import "ZNSSceneSession.h"
#import "ZNSSceneGeometry.h"
#import <QuartzCore/QuartzCore.h>
#import "ZNSPrivate.h"
#import "ZNSProcessKeepAlive.h"
#import "ZNSKeyboardFocus.h"
#import "ZNSKeyboardPlacement.h"
#import "ZNSKeyboardPolicy.h"
#import <substrate.h>
#import <objc/runtime.h>
#import <math.h>
#import <string.h>
#import <dispatch/dispatch.h>
#import <sys/types.h>
#import <unistd.h>

@interface ZNSSceneLease : NSObject
@property(atomic,copy) id settings;
@end
@implementation ZNSSceneLease
@end

static NSString *ZNSLastSceneFailure;
static BOOL ZNSCompatibilityFailure(id object,SEL selector,NSString *code) {
    ZNSPrivateABIError(object,selector);
    ZNSLastSceneFailure=[NSString stringWithFormat:@"私有接口缺失或 ABI 不兼容（%@）：%@ / %@；%@",
        code,object?NSStringFromClass(object_getClass(object)):@"nil",NSStringFromSelector(selector),
        ZNSPrivateSignatureDescription(object,selector)];
    return NO;
}
static BOOL ZNSRequireABI(id object,SEL selector,const char *result,
                          const char * const *arguments,NSUInteger count,NSString *code) {
    return ZNSPrivateABI(object,selector,result,arguments,count) || ZNSCompatibilityFailure(object,selector,code);
}
// Read only registered handles through ABI-checked getters/lookups.
static id ZNSHandleLookupRead(id object,SEL selector,id argument,BOOL takesArgument,
                              NSString *stage,NSMutableArray<NSString *> *trace) {
    const char *arguments[]={"@"};
    NSString *state=nil;
    id result=nil;
    if (!object) state=@"对象为空";
    else if (!ZNSPrivateSignature(object,selector)) state=@"无接口";
    else if (!ZNSPrivateABI(object,selector,"@",takesArgument?arguments:NULL,takesArgument?1:0)) state=@"ABI不符";
    else {
        @try {
            result=takesArgument?((id(*)(id,SEL,id))objc_msgSend)(object,selector,argument):
                                 ((id(*)(id,SEL))objc_msgSend)(object,selector);
            state=result?@"正常":@"返回空";
        } @catch (NSException *exception) { state=[@"异常:" stringByAppendingString:exception.name]; }
    }
    NSString *owner=object?NSStringFromClass(object_getClass(object)):@"nil";
    NSString *entry=[NSString stringWithFormat:@"%@=%@(%@)",stage,state,owner];
    [trace addObject:entry];
    Method method=object?class_getInstanceMethod(object_getClass(object),selector):NULL;
    const char *encoding=method?method_getTypeEncoding(method):NULL;
    os_log(ZNSLog(),"handle lookup %{public}@ selector=%{public}@ encoding=%{public}s resultClass=%{public}@",
        entry,NSStringFromSelector(selector),encoding?:"missing",result?NSStringFromClass(object_getClass(result)):@"nil");
    return result;
}
static id ZNSRegisteredHandle(id scene,id workspaceClass,NSArray *connectedScenes,
                               id coordinatorClass,NSMutableArray<NSString *> *trace) {
    if (!scene) { [trace addObject:@"S=场景为空"]; return nil; }
    id workspace=ZNSHandleLookupRead(workspaceClass,NSSelectorFromString(@"sharedInstance"),nil,NO,@"W",trace);
    id mainScene=ZNSHandleLookupRead(workspace,NSSelectorFromString(@"mainWindowScene"),nil,NO,@"M",trace);
    NSMutableArray *windowScenes=[NSMutableArray new];
    if (mainScene) [windowScenes addObject:mainScene];
    for (id candidate in connectedScenes)
        if ([windowScenes indexOfObjectIdenticalTo:candidate]==NSNotFound) [windowScenes addObject:candidate];
    NSUInteger index=0;
    for (id windowScene in windowScenes) {
        NSString *managerStage=[NSString stringWithFormat:@"G%lu",(unsigned long)index];
        NSString *handleStage=[NSString stringWithFormat:@"H%lu",(unsigned long)index++];
        id manager=ZNSHandleLookupRead(windowScene,NSSelectorFromString(@"sceneManager"),nil,NO,managerStage,trace);
        id handle=ZNSHandleLookupRead(manager,@selector(existingSceneHandleForScene:),scene,YES,handleStage,trace);
        if (handle) return handle;
    }
    // Historical iOS 14.5 declarations, a candidate for iOS 15, not runtime proof.
    // Check the class-method ABI too; never guess alloc/ivar/sharedInstance routes.
    id manager=ZNSHandleLookupRead(coordinatorClass,NSSelectorFromString(@"mainDisplaySceneManager"),nil,NO,@"C",trace);
    return ZNSHandleLookupRead(manager,@selector(existingSceneHandleForScene:),scene,YES,@"L",trace);
}
static BOOL ZNSSceneLookupCanRetry(NSUInteger attempt) { return attempt<24; }
static BOOL ZNSSettingsReadAPI(id settings);
static BOOL ZNSSettingsWriteAPI(id settings);
static SEL ZNSScenePresentationGetter(id mutableSettings);
static BOOL ZNSSetSceneBackgrounded(id settings,BOOL backgrounded);
static BOOL ZNSCopyDeviceOrientation(id target,id source);
static char ZNSSceneLeaseKey;
static void (*ZNSOriginalSceneUpdate)(id,SEL,id,id,id);
static void (*ZNSOriginalSceneUpdateShort)(id,SEL,id,id);
static BOOL ZNSSceneLeaseHookInstalled;

// Preserve the caller's other scene settings, changing only the fields owned
// by our currently hosted session. No bundle-wide or global background hook.
static id ZNSSettingsForHostedScene(id scene,id incoming) {
    ZNSSceneLease *lease=objc_getAssociatedObject(scene,&ZNSSceneLeaseKey);
    id owned=lease.settings;
    if (!owned || !incoming) return incoming;
    @try {
        if (!ZNSRequireABI(incoming,@selector(mutableCopy),"@",NULL,0,@"S4")) return incoming;
        id adjusted=[incoming mutableCopy];
        if (!ZNSSettingsReadAPI(owned) || !ZNSSettingsWriteAPI(adjusted)) return incoming;
        SEL presentationGetter=ZNSScenePresentationGetter(adjusted);
        BOOL previousValue=ZNSBool(adjusted,NSStringFromSelector(presentationGetter));
        BOOL backgrounded=presentationGetter==NSSelectorFromString(@"isForeground")?!previousValue:previousValue;
        if (!ZNSSetSceneBackgrounded(adjusted,NO)) return incoming;
        [adjusted setFrame:[owned frame]];
        [adjusted setInterfaceOrientation:[owned interfaceOrientation]];
        ZNSCopyDeviceOrientation(adjusted,owned);
        if (backgrounded) os_log(ZNSLog(),"hosted scene prevented background transition; live canvas retained");
        return adjusted;
    } @catch (NSException *exception) {
        os_log_error(ZNSLog(),"hosted scene settings guard failed: %{public}@",exception.name);
        return incoming;
    }
}
static void ZNSSceneUpdate(id scene,SEL cmd,id settings,id context,id completion) {
    ZNSOriginalSceneUpdate(scene,cmd,ZNSSettingsForHostedScene(scene,settings),context,completion);
}
static void ZNSSceneUpdateShort(id scene,SEL cmd,id settings,id context) {
    ZNSOriginalSceneUpdateShort(scene,cmd,ZNSSettingsForHostedScene(scene,settings),context);
}
static BOOL ZNSSceneUpdateSignature(Class cls,SEL selector,NSUInteger arguments) {
    if (arguments!=4 && arguments!=5) return NO;
    Method method=class_getInstanceMethod(cls,selector);
    if (!method) return NO;
    @try {
        NSMethodSignature *signature=[NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
        if (signature.numberOfArguments!=arguments || !ZNSTypeMatches(signature.methodReturnType,"v")) return NO;
        for (NSUInteger index=2;index<arguments;index++) {
            const char *expected=arguments==5 && index==4?"@?":"@";
            if (!ZNSTypeMatches([signature getArgumentTypeAtIndex:index],expected)) return NO;
        }
        return YES;
    } @catch (__unused NSException *exception) { return NO; }
}
static BOOL ZNSHostSetter(id host,SEL selector,const char *argumentType) {
    const char *arguments[]={argumentType};
    return ZNSPrivateABI(host,selector,"v",arguments,1);
}
static BOOL ZNSGetter(id object,SEL selector,const char *returnType) {
    return ZNSPrivateABI(object,selector,returnType,NULL,0);
}
static BOOL ZNSDisplayModeAPI(id host) {
    NSMethodSignature *signature=ZNSPrivateSignature(host,@selector(setDisplayMode:animationFactory:completion:));
    if (!signature || signature.numberOfArguments!=5 || !ZNSTypeMatches(signature.methodReturnType,"v") ||
        !ZNSTypeMatches([signature getArgumentTypeAtIndex:2],@encode(NSInteger))) return NO;
    // Both trailing arguments are nil: object or block, not guessed callbacks.
    for (NSUInteger index=3;index<5;index++) {
        const char *type=[signature getArgumentTypeAtIndex:index];
        if (!ZNSTypeMatches(type,"@") && !ZNSTypeMatches(type,"@?")) return NO;
    }
    return YES;
}
static BOOL ZNSSettingsReadAPI(id settings) {
    return ZNSRequireABI(settings,@selector(frame),@encode(CGRect),NULL,0,@"S4") &&
        ZNSRequireABI(settings,@selector(interfaceOrientation),@encode(NSInteger),NULL,0,@"S4") &&
        ZNSRequireABI(settings,NSSelectorFromString(@"deviceOrientation"),@encode(NSInteger),NULL,0,@"S4");
}
// iOS 17 runtime declarations and the reference binary expose both pairs.
// Preserve the existing backgrounded route where available; otherwise require
// a complete foreground pair with a real BOOL ABI. This is capability-based,
// not a claim that all iOS 17 releases have identical scene implementations.
static BOOL ZNSSceneBoolGetterAPI(id settings,SEL getter) {
    return ZNSGetter(settings,getter,"B") || ZNSGetter(settings,getter,"c");
}
static SEL ZNSScenePresentationGetter(id settings) {
    SEL backgroundSetter=NSSelectorFromString(@"setBackgrounded:");
    SEL backgroundGetter=NSSelectorFromString(@"isBackgrounded");
    if ((ZNSHostSetter(settings,backgroundSetter,"B") || ZNSHostSetter(settings,backgroundSetter,"c")) &&
        ZNSSceneBoolGetterAPI(settings,backgroundGetter)) return backgroundGetter;
    SEL foregroundSetter=NSSelectorFromString(@"setForeground:");
    SEL foregroundGetter=NSSelectorFromString(@"isForeground");
    if ((ZNSHostSetter(settings,foregroundSetter,"B") || ZNSHostSetter(settings,foregroundSetter,"c")) &&
        ZNSSceneBoolGetterAPI(settings,foregroundGetter)) return foregroundGetter;
    return NULL;
}
static BOOL ZNSScenePresentationFailure(id settings) {
    ZNSLastSceneFailure=[NSString stringWithFormat:@"场景前后台接口不可用（S5）：%@；background setter=%@ getter=%@；foreground setter=%@ getter=%@",
        settings?NSStringFromClass(object_getClass(settings)):@"nil",
        ZNSPrivateSignatureDescription(settings,NSSelectorFromString(@"setBackgrounded:")),
        ZNSPrivateSignatureDescription(settings,NSSelectorFromString(@"isBackgrounded")),
        ZNSPrivateSignatureDescription(settings,NSSelectorFromString(@"setForeground:")),
        ZNSPrivateSignatureDescription(settings,NSSelectorFromString(@"isForeground"))];
    os_log_error(ZNSLog(),"%{public}@",ZNSLastSceneFailure);
    return NO;
}
static BOOL ZNSSetSceneBackgrounded(id settings,BOOL backgrounded) {
    SEL getter=ZNSScenePresentationGetter(settings);
    if (!getter) return ZNSScenePresentationFailure(settings);
    BOOL usesForeground=getter==NSSelectorFromString(@"isForeground");
    NSString *setter=usesForeground?@"setForeground:":@"setBackgrounded:";
    BOOL expected=usesForeground?!backgrounded:backgrounded;
    ZNSSetBool(settings,setter,expected);
    // Verify this mutable copy before submitting it. This does not prove that
    // the scene accepted the transaction or that the client rendered a frame.
    if (ZNSBool(settings,NSStringFromSelector(getter))!=expected) {
        ZNSLastSceneFailure=[NSString stringWithFormat:@"场景前后台写入未生效（S5W）：%@",setter];
        os_log_error(ZNSLog(),"%{public}@",ZNSLastSceneFailure);
        return NO;
    }
    return YES;
}
static BOOL ZNSSettingsWriteAPI(id settings) {
    const char *frame[]={@encode(CGRect)},*direction[]={@encode(NSInteger)};
    if (!ZNSScenePresentationGetter(settings)) return ZNSScenePresentationFailure(settings);
    return ZNSRequireABI(settings,@selector(setFrame:),"v",frame,1,@"S5") &&
        ZNSRequireABI(settings,@selector(setInterfaceOrientation:),"v",direction,1,@"S5") &&
        ZNSRequireABI(settings,NSSelectorFromString(@"setDeviceOrientation:"),"v",direction,1,@"S5");
}
static void ZNSInvalidateHost(id host) {
    if (host && ZNSRequireABI(host,@selector(invalidate),"v",NULL,0,@"H5")) [host invalidate];
}
static BOOL ZNSCopyDeviceOrientation(id target,id source) {
    SEL getter=NSSelectorFromString(@"deviceOrientation"),setter=NSSelectorFromString(@"setDeviceOrientation:");
    if (!ZNSGetter(source,getter,@encode(NSInteger)) || !ZNSHostSetter(target,setter,@encode(NSInteger))) return NO;
    NSInteger orientation=((NSInteger(*)(id,SEL))objc_msgSend)(source,getter);
    ((void(*)(id,SEL,NSInteger))objc_msgSend)(target,setter,orientation);
    // Do not own deviceOrientationEventsEnabled. It is system/client event
    // policy, not an acknowledgment that this hosted scene can be displayed.
    return YES;
}
static void ZNSLogClientDirection(id scene,NSInteger expected,const char *stage) {
    id client=ZNSGet(scene,@"clientSettings"),settings=ZNSGet(scene,@"settings");
    NSInteger direction=-1,mode=-1;
    NSUInteger supported=0;
    BOOL disabled=NO,events=NO;
    BOOL directionKnown=ZNSGetter(client,@selector(interfaceOrientation),@encode(NSInteger));
    BOOL maskKnown=ZNSGetter(client,NSSelectorFromString(@"supportedInterfaceOrientations"),@encode(NSUInteger));
    BOOL disabledKnown=ZNSGetter(client,NSSelectorFromString(@"interfaceOrientationChangesDisabled"),@encode(BOOL));
    BOOL eventsKnown=ZNSGetter(settings,NSSelectorFromString(@"deviceOrientationEventsEnabled"),@encode(BOOL));
    if(directionKnown) direction=((NSInteger(*)(id,SEL))objc_msgSend)(client,@selector(interfaceOrientation));
    if(maskKnown) supported=((NSUInteger(*)(id,SEL))objc_msgSend)(client,NSSelectorFromString(@"supportedInterfaceOrientations"));
    if(disabledKnown) disabled=((BOOL(*)(id,SEL))objc_msgSend)(client,NSSelectorFromString(@"interfaceOrientationChangesDisabled"));
    if(eventsKnown) events=((BOOL(*)(id,SEL))objc_msgSend)(settings,NSSelectorFromString(@"deviceOrientationEventsEnabled"));
    if(ZNSGetter(settings,NSSelectorFromString(@"interfaceOrientationMode"),@encode(NSInteger)))
        mode=((NSInteger(*)(id,SEL))objc_msgSend)(settings,NSSelectorFromString(@"interfaceOrientationMode"));
    os_log(ZNSLog(),"client direction stage=%{public}s expected=%ld actual=%ld known=%d supportedMask=%lu maskKnown=%d changesDisabled=%d disabledKnown=%d events=%d eventsKnown=%d mode=%ld; not a pixel-render acknowledgment",
        stage,(long)expected,(long)direction,directionKnown,(unsigned long)supported,maskKnown,disabled,disabledKnown,events,eventsKnown,(long)mode);
}
static BOOL ZNSHostFactoryAPI(id handle,BOOL separateOrientations) {
    SEL selector=separateOrientations?
        @selector(newSceneViewWithReferenceSize:contentOrientation:containerOrientation:hostRequester:):
        @selector(newSceneViewWithReferenceSize:orientation:hostRequester:);
    const char *combined[]={@encode(CGSize),@encode(NSInteger),"@"};
    const char *separate[]={@encode(CGSize),@encode(NSInteger),@encode(NSInteger),"@"};
    return ZNSPrivateABI(handle,selector,"@",separateOrientations?separate:combined,separateOrientations?4:3);
}
static BOOL ZNSHostCombinedCanvasAPI(UIView *host) {
    const char *arguments[]={@encode(CGSize),@encode(NSInteger)};
    return ZNSPrivateABI(host,NSSelectorFromString(@"_updateReferenceSize:andOrientation:"),"v",arguments,2);
}
static BOOL ZNSHostSeparateCanvasAPI(UIView *host) {
    // Capability-based fallback, not a claim that every iOS 17 host has these.
    // Both setters must have exact ABI; never use KVC or write private ivars.
    return ZNSHostSetter(host,NSSelectorFromString(@"setReferenceSize:"),@encode(CGSize)) &&
        ZNSHostSetter(host,NSSelectorFromString(@"setOrientation:"),@encode(NSInteger));
}
static BOOL ZNSHostCanvasAPI(UIView *host) {
    if (!ZNSRequireABI(host,NSSelectorFromString(@"referenceSize"),@encode(CGSize),NULL,0,@"H2") ||
        !ZNSRequireABI(host,NSSelectorFromString(@"orientation"),@encode(NSInteger),NULL,0,@"H2")) return NO;
    if (ZNSHostCombinedCanvasAPI(host) || ZNSHostSeparateCanvasAPI(host)) return YES;
    return ZNSCompatibilityFailure(host,NSSelectorFromString(@"_updateReferenceSize:andOrientation:"),@"H2：亦无成对尺寸/方向setter");
}
static BOOL ZNSGeometryScalarNear(CGFloat actual,CGFloat desired) {
    return isfinite(actual) && isfinite(desired) && fabs(actual-desired)<=0.5;
}
static BOOL ZNSGeometrySizeNear(CGSize actual,CGSize desired) {
    return ZNSGeometryScalarNear(actual.width,desired.width) && ZNSGeometryScalarNear(actual.height,desired.height);
}
static BOOL ZNSGeometryRectNear(CGRect actual,CGRect desired) {
    return ZNSGeometryScalarNear(actual.origin.x,desired.origin.x) && ZNSGeometryScalarNear(actual.origin.y,desired.origin.y) &&
        ZNSGeometrySizeNear(actual.size,desired.size);
}
static BOOL ZNSHostCanvasMatches(UIView *host,CGSize size,NSInteger orientation) {
    if (!ZNSHostCanvasAPI(host)) return NO;
    CGSize reference=((CGSize(*)(id,SEL))objc_msgSend)(host,NSSelectorFromString(@"referenceSize"));
    NSInteger direction=((NSInteger(*)(id,SEL))objc_msgSend)(host,NSSelectorFromString(@"orientation"));
    CGRect projection=CGRectApplyAffineTransform((CGRect){CGPointZero,host.bounds.size},host.transform);
    CGSize projected=CGSizeMake(fabs(projection.size.width),fabs(projection.size.height));
    return direction==orientation && ZNSGeometrySizeNear(reference,size) && ZNSGeometrySizeNear(projected,size);
}
static void ZNSLogHostGeometry(UIView *host,const char *stage,CGSize expected,NSInteger orientation) {
    if (!host) return;
    CGRect bounds=host.bounds;
    CGAffineTransform transform=host.transform;
    CGRect projection=CGRectApplyAffineTransform((CGRect){CGPointZero,bounds.size},transform);
    os_log(ZNSLog(),"host geometry stage=%{public}s expected=%.1fx%.1f orientation=%ld bounds=(%.1f,%.1f %.1fx%.1f) projected=%.1fx%.1f matrix=[%.3f %.3f %.3f %.3f %.1f %.1f] attached=%d; geometry only, not rendered pixels",
        stage,expected.width,expected.height,(long)orientation,bounds.origin.x,bounds.origin.y,bounds.size.width,bounds.size.height,
        projection.size.width,projection.size.height,transform.a,transform.b,transform.c,transform.d,transform.tx,transform.ty,host.superview!=nil);
}
static BOOL ZNSAlignHostCanvas(UIView *host,CGSize size) {
    if(!host || !CATransform3DIsAffine(host.layer.transform)) return NO;
    CGSize localSize; CGPoint position;
    if(!ZNSHostGeometryForCanvas(size,host.transform,host.layer.anchorPoint,&localSize,&position)) return NO;
    CGRect bounds=host.bounds;
    bounds.size=localSize;
    // Never set frame under a rotation, reset transform, or touch remote layers.
    // Retain a nonzero bounds origin: it is part of the host's internal space.
    if(!CGRectEqualToRect(host.bounds,bounds)) host.bounds=bounds;
    if(!CGPointEqualToPoint(host.layer.position,position)) host.layer.position=position;
    return YES;
}
static BOOL ZNSConfigureHostCanvas(UIView *host,CGSize size,NSInteger orientation) {
    // Prefer the combined updater verified on iOS 16. Only fall back when the
    // actual host exposes both ABI-checked setters and both readback getters.
    if (!ZNSHostCanvasAPI(host)) return NO;
    ZNSLogHostGeometry(host,"before-canvas-update",size,orientation);
    if (ZNSHostCombinedCanvasAPI(host)) {
        ((void(*)(id,SEL,CGSize,NSInteger))objc_msgSend)(host,NSSelectorFromString(@"_updateReferenceSize:andOrientation:"),size,orientation);
    } else {
        ((void(*)(id,SEL,NSInteger))objc_msgSend)(host,NSSelectorFromString(@"setOrientation:"),orientation);
        ((void(*)(id,SEL,CGSize))objc_msgSend)(host,NSSelectorFromString(@"setReferenceSize:"),size);
        CGSize actual=((CGSize(*)(id,SEL))objc_msgSend)(host,NSSelectorFromString(@"referenceSize"));
        NSInteger direction=((NSInteger(*)(id,SEL))objc_msgSend)(host,NSSelectorFromString(@"orientation"));
        if (!CGSizeEqualToSize(actual,size) || direction!=orientation) {
            ZNSLastSceneFailure=@"托管视图尺寸/方向setter回读不一致（H2R）";
            os_log_error(ZNSLog(),"host separate canvas setters rejected size/direction");
            return NO;
        }
        os_log(ZNSLog(),"host canvas used ABI-checked separate setters; pixels unverified");
    }
    ZNSLogHostGeometry(host,"after-canvas-update",size,orientation);
    // System rotation is authoritative; solve local bounds from its projection
    // so the host fills the oriented container without rotating/scaling twice.
    [host setNeedsLayout];
    [host layoutIfNeeded];
    BOOL aligned=ZNSAlignHostCanvas(host,size);
    if(!aligned) os_log_error(ZNSLog(),"host coordinate alignment deferred: unsupported transform; system geometry retained");
    ZNSLogHostGeometry(host,"after-coordinate-alignment",size,orientation);
    CGSize actual=((CGSize(*)(id,SEL))objc_msgSend)(host,NSSelectorFromString(@"referenceSize"));
    NSInteger applied=((NSInteger(*)(id,SEL))objc_msgSend)(host,NSSelectorFromString(@"orientation"));
    BOOL matches=CGSizeEqualToSize(actual,size) && applied==orientation;
    os_log(ZNSLog(),"host coordinate update reference=%.0fx%.0f orientation=%ld matched=%d",actual.width,actual.height,(long)applied,matches);
    return matches;
}
static void ZNSInstallSceneLeaseHook(void) {
    static dispatch_once_t once;
    dispatch_once(&once,^{
        Class cls=NSClassFromString(@"FBScene");
        SEL full=NSSelectorFromString(@"updateSettings:withTransitionContext:completion:");
        SEL shortSelector=NSSelectorFromString(@"updateSettings:withTransitionContext:");
        if (ZNSSceneUpdateSignature(cls,full,5)) {
            MSHookMessageEx(cls,full,(IMP)ZNSSceneUpdate,(IMP *)&ZNSOriginalSceneUpdate);
            ZNSSceneLeaseHookInstalled=ZNSOriginalSceneUpdate!=NULL;
        }
        if (ZNSSceneUpdateSignature(cls,shortSelector,4)) {
            MSHookMessageEx(cls,shortSelector,(IMP)ZNSSceneUpdateShort,(IMP *)&ZNSOriginalSceneUpdateShort);
            ZNSSceneLeaseHookInstalled |= ZNSOriginalSceneUpdateShort!=NULL;
        }
        os_log(ZNSLog(),"hosted scene settings guard installed=%d",ZNSSceneLeaseHookInstalled);
    });
}

// SBSceneViewPresentationConfiguring requires an object implementing these
// callbacks, not a requester-name string. Keep it independent of the session
// so a scene view retaining its requester cannot retain the session in a cycle.
@interface ZNSSceneHostRequester : NSObject
@property(nonatomic,copy) NSString *presentationIdentifier;
@end
@implementation ZNSSceneHostRequester
- (instancetype)init {
    if ((self=[super init])) _presentationIdentifier=[@"com.zengniu.splitview.host." stringByAppendingString:NSUUID.UUID.UUIDString];
    return self;
}
- (NSString *)sceneViewPresentationIdentifier:(id)view {
    (void)view; return self.presentationIdentifier;
}
- (long long)sceneViewPresentationPriority:(id)view {
    (void)view; return 1;
}
@end

@interface ZNSSceneSession ()
- (BOOL)znsTemporaryPortraitStateMatchesFrame:(CGRect)frame;
@property(nonatomic,strong) ZNSSceneHostRequester *hostRequester;
@property(nonatomic,copy,readwrite) NSString *bundleIdentifier;
@property(nonatomic,strong,readwrite) UIView *hostView;
@property(nonatomic,readwrite) BOOL landscape;
@property(nonatomic,readwrite) CGSize canvasSize;
@property(nonatomic) BOOL keyboardPreferenceRead;
@property(nonatomic) BOOL keyboardPortraitExternal;
@property(nonatomic) BOOL keyboardLandscapeExternal;
@property(nonatomic) BOOL keyboardLandscapeMove;
@property(nonatomic,strong) id scene;
@property(nonatomic) BOOL sceneSelectionAmbiguous;
@property(nonatomic,strong) id handle;
@property(nonatomic,strong) id savedSettings;
@property(nonatomic,strong) ZNSSceneLease *lease;
@property(nonatomic,strong) ZNSProcessKeepAlive *keepAlive;
@property(nonatomic,strong) ZNSKeyboardFocus *keyboardFocus;
@property(nonatomic,strong) ZNSKeyboardPlacement *keyboardPlacement;
@property(nonatomic) BOOL keyboardPlacementActive;
@property(nonatomic) BOOL keyboardFocusUnavailable;
@property(nonatomic) BOOL stopped;
@property(nonatomic) BOOL switcherRemovalRequested;
@property(nonatomic) BOOL deviceLockRequested;
@property(nonatomic) BOOL changedSettings;
@property(nonatomic,readwrite) BOOL layoutInFlight;
@property(nonatomic) NSUInteger layoutGeneration;
- (void)znsPollPortraitRestore:(NSUInteger)generation attempt:(NSUInteger)attempt;
- (void)znsFailPortraitRestore:(NSUInteger)generation;
@property(nonatomic,readwrite) BOOL znsPortraitHandoffInFlight;
@property(nonatomic,readwrite) BOOL znsPortraitRestorePending;
@property(nonatomic) uint64_t znsPortraitRestoreRequest;
@property(nonatomic) CGRect znsPortraitRestoreExpandedFrame;
@property(nonatomic,copy) void (^znsPortraitRestoreCompletion)(BOOL);
@property(nonatomic,strong) id temporaryPortraitSettings;
@property(nonatomic) CGSize temporaryPortraitCanvas;
@property(nonatomic) CGRect temporaryPortraitFrame;
@property(nonatomic) NSUInteger temporaryPortraitGeneration;
@property(nonatomic) BOOL temporaryPortraitPending;
@property(nonatomic) BOOL temporaryPortraitRestoring;
@property(nonatomic,copy) void (^temporaryPortraitFailure)(void);
@property(nonatomic,copy) void (^layoutCompletion)(BOOL,NSString *);
@property(nonatomic,copy) void (^completion)(BOOL,NSString *);
@property(nonatomic,strong) dispatch_source_t processExitSource;
@property(nonatomic,strong) id monitoredProcess;
@property(nonatomic) NSUInteger processExitGeneration;
@property(nonatomic,readwrite) BOOL clientProcessExited;
@end

static void ZNSRunPortraitHandoff(void (^block)(void)) {
    [UIView performWithoutAnimation:block];
}
static BOOL ZNSValidCanvasSize(CGSize size) {
    return isfinite(size.width) && isfinite(size.height) && size.width>0 && size.height>0;
}

// This reader is deliberately stricter than the general scene discovery path:
// only checked object getters may establish ownership of a watched PID.
static id ZNSProcessExitObject(id object,NSString *name) {
    SEL selector=NSSelectorFromString(name);
    if (!ZNSGetter(object,selector,@encode(id))) return nil;
    return ((id(*)(id,SEL))objc_msgSend)(object,selector);
}

@implementation ZNSSceneSession
#include "ZNSPortraitScene.inc"
- (void)cancelProcessExitObservation {
    ++self.processExitGeneration;
    dispatch_source_t source=self.processExitSource;
    self.processExitSource=nil;
    self.monitoredProcess=nil;
    self.processDidExit=nil;
    if (source) dispatch_source_cancel(source);
}
- (void)beginProcessExitObservation {
    if (!NSThread.isMainThread || self.stopped || !self.scene || !self.hostView || self.processExitSource) return;
    id process=nil;
    SEL pidSelector=NULL;
    pid_t pid=0;
    @try {
        process=ZNSProcessExitObject(self.scene,@"clientProcess");
        id bundle=ZNSProcessExitObject(process,@"bundleIdentifier");
        if (!bundle) bundle=ZNSProcessExitObject(ZNSProcessExitObject(process,@"applicationInfo"),@"bundleIdentifier");
        if (![bundle isKindOfClass:NSString.class] || ![bundle isEqualToString:self.bundleIdentifier]) {
            os_log_error(ZNSLog(),"process exit observation unsupported: client ownership not confirmed");
            return;
        }
        for (NSString *name in @[@"processIdentifier",@"pid"]) {
            SEL candidate=NSSelectorFromString(name);
            if (!ZNSGetter(process,candidate,@encode(pid_t))) continue;
            pid_t value=((pid_t(*)(id,SEL))objc_msgSend)(process,candidate);
            if (value>0 && value!=getpid()) { pid=value; pidSelector=candidate; break; }
        }
    } @catch (NSException *exception) {
        os_log_error(ZNSLog(),"process exit observation unsupported: getter exception %{public}@",exception.name);
        return;
    }
    if (!pidSelector) {
        os_log_error(ZNSLog(),"process exit observation unsupported: no checked positive external pid_t getter");
        return;
    }
    // SDK dispatch/source.h: PROC takes pid_t, EXIT reports actual termination
    // (including crashes); the source is inactive until dispatch_activate.
    // Never poll kill(pid,0), infer death from a black frame, or rearm a PID.
    dispatch_source_t source=dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC,(uintptr_t)pid,
        DISPATCH_PROC_EXIT,dispatch_get_main_queue());
    if (!source) {
        os_log_error(ZNSLog(),"process exit observation unsupported: dispatch source unavailable");
        return;
    }
    self.monitoredProcess=process;
    self.processExitSource=source;
    NSUInteger generation=++self.processExitGeneration;
    __weak typeof(self) weakSelf=self;
    dispatch_source_set_registration_handler(source,^{
        ZNSSceneSession *session=weakSelf;
        if (!session || session.stopped || session.processExitGeneration!=generation || !session.processExitSource) return;
        os_log(ZNSLog(),"hosted client exit source registered; no exit inferred from registration");
    });
    dispatch_source_set_event_handler(source,^{
        ZNSSceneSession *session=weakSelf;
        if (!session || session.stopped || session.processExitGeneration!=generation) return;
        dispatch_source_t current=session.processExitSource;
        if (!current || !(dispatch_source_get_data(current)&DISPATCH_PROC_EXIT)) return;
        BOOL sameProcess=YES;
        @try {
            id currentProcess=ZNSProcessExitObject(session.scene,@"clientProcess");
            // A dead scene may already have cleared clientProcess; a different
            // nonnil process, or a rebound PID, must never close a new client.
            if (currentProcess && currentProcess!=session.monitoredProcess) sameProcess=NO;
            if (ZNSGetter(session.monitoredProcess,pidSelector,@encode(pid_t))) {
                pid_t now=((pid_t(*)(id,SEL))objc_msgSend)(session.monitoredProcess,pidSelector);
                if (now>0 && now!=pid) sameProcess=NO;
            } else sameProcess=NO;
        } @catch (NSException *exception) {
            sameProcess=NO;
            os_log_error(ZNSLog(),"process exit identity check failed: %{public}@",exception.name);
        }
        if (sameProcess) session.clientProcessExited=YES;
        void (^callback)(void)=sameProcess?[session.processDidExit copy]:nil;
        // Invalidate before invoking user code: closing the window re-enters
        // stopForFullscreen:. A source retains only weakSelf, never the session.
        [session cancelProcessExitObservation];
        // Resource lifetime must not depend on the owner's presentation mode or
        // whether it installed a callback. A dead client must never keep a scene
        // guard or assertion alive while a stale window waits to be removed.
        if (sameProcess) [session stopForFullscreen:NO];
        os_log(ZNSLog(),"hosted client process exited; original session identity matched=%d",sameProcess);
        if (callback) callback(); // Already on main; no extra delayed lookup.
    });
    dispatch_activate(source);
}
- (void)layoutHostInCanvas {
    if(self.stopped || self.layoutInFlight || self.znsPortraitRestorePending || !self.hostView) return;
    [self.hostView layoutIfNeeded];
    ZNSAlignHostCanvas(self.hostView,self.canvasSize);
}
+ (void)emitDiagnostics {
    if (ZNSLastSceneFailure) os_log_error(ZNSLog(),"last scene failure: %{public}@",ZNSLastSceneFailure);
}
- (instancetype)initWithBundleIdentifier:(NSString *)identifier {
    if ((self=[super init])) {
        _bundleIdentifier=[identifier copy];
        _hostRequester=[ZNSSceneHostRequester new];
    }
    return self;
}
- (void)applyKeyboardPlacementPreference {
    // Placement only: App first responder and system text routing stay native.
    [self.keyboardPlacement configurePortraitExternal:self.keyboardPortraitExternal
        landscapeExternal:self.keyboardLandscapeExternal move:self.keyboardLandscapeMove];
}
- (void)setKeyboardFocusActive:(BOOL)active {
    if (!NSThread.isMainThread || self.stopped) return;
    self.keyboardPlacementActive=active;
    if (!self.keyboardPlacement) self.keyboardPlacement=[ZNSKeyboardPlacement new];
    // Eligibility updates never submit SBS. Only the dedicated focus dot may
    // start the one-shot experiment; losing eligibility still revokes it.
    if (!active || self.layoutInFlight || !self.hostView.window || !self.scene)
        [self.keyboardFocus invalidate];
    [self.keyboardPlacement setPlacementActive:active];
    [self.keyboardPlacement updateScene:self.scene bundleIdentifier:self.bundleIdentifier];
    if (!self.layoutInFlight) [self.keyboardPlacement updateHost:self.hostView canvas:self.canvasSize];
    [self applyKeyboardPlacementPreference];
}
- (NSString *)keyboardMode { return self.keyboardPlacement.external ? @"external" : @"window"; }
- (BOOL)keyboardModeApplied { return self.keyboardPlacement.applied; }
- (BOOL)reloadKeyboardPreference {
    if (!NSThread.isMainThread || self.stopped) return NO;
    CFPreferencesAppSynchronize(CFSTR(APELIN_PACKAGE_ID));
    id portrait=CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("KeyboardPortraitPlacement"),CFSTR(APELIN_PACKAGE_ID)));
    id landscape=CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("KeyboardLandscapePlacement"),CFSTR(APELIN_PACKAGE_ID)));
    id movable=CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("KeyboardLandscapeMovable"),CFSTR(APELIN_PACKAGE_ID)));
    BOOL p=ZNSKeyboardExternalValue(portrait),l=ZNSKeyboardExternalValue(landscape),m=ZNSKeyboardMoveValue(movable);
    BOOL changed=!self.keyboardPreferenceRead || p!=self.keyboardPortraitExternal || l!=self.keyboardLandscapeExternal || m!=self.keyboardLandscapeMove;
    self.keyboardPortraitExternal=p; self.keyboardLandscapeExternal=l; self.keyboardLandscapeMove=m;
    self.keyboardPreferenceRead=YES;
    [self applyKeyboardPlacementPreference];
    if (changed) os_log(ZNSLog(),"keyboard preferences portraitExternal=%d landscapeExternal=%d movable=%d attached=%d; native focus unchanged",p,l,m,self.keyboardModeApplied);
    return self.keyboardModeApplied;
}
- (id)findScene {
    self.sceneSelectionAmbiguous=NO;
    id manager=ZNSShared(@"FBSceneManager");
    const char *arguments[]={"@?"};
    if (!ZNSRequireABI(manager,@selector(enumerateScenesWithBlock:),"v",arguments,1,@"S0")) return nil;
    __block id match=nil;
    __block NSUInteger matches=0;
    [manager enumerateScenesWithBlock:^(id candidate) {
        id process=ZNSGet(candidate,@"clientProcess");
        NSString *bundle=ZNSGet(process,@"bundleIdentifier");
        if (!bundle) bundle=ZNSGet(ZNSGet(process,@"applicationInfo"),@"bundleIdentifier");
        NSString *identifier=ZNSGet(candidate,@"identifier");
        BOOL same=[bundle isKindOfClass:NSString.class] && [bundle isEqualToString:self.bundleIdentifier];
        if (!bundle && [identifier isKindOfClass:NSString.class]) {
            same=[identifier isEqualToString:self.bundleIdentifier] || [identifier hasPrefix:[@"sceneID:" stringByAppendingFormat:@"%@-",self.bundleIdentifier]];
        }
        id settings=ZNSGet(candidate,@"settings");
        if (same && ZNSGetter(settings,@selector(frame),@encode(CGRect))) {
            if(candidate!=match) matches++;
            if(!match) match=candidate;
        }
    }];
    self.sceneSelectionAmbiguous=matches>1;
    return self.sceneSelectionAmbiguous?nil:match;
}
- (id)existingHandleForScene:(id)scene {
    // Reuse SpringBoard's registered handle; constructing a second handle
    // bypasses its scene-manager ownership and lifecycle.
    NSMutableArray<NSString *> *trace=[NSMutableArray new];
    id handle=ZNSRegisteredHandle(scene,NSClassFromString(@"SBMainWorkspace"),
        UIApplication.sharedApplication.connectedScenes.allObjects,NSClassFromString(@"SBSceneManagerCoordinator"),trace);
    if (handle) {
        ZNSLastSceneFailure=nil;
        os_log(ZNSLog(),"registered handle resolved via %{public}@",trace.lastObject);
        return handle;
    }
    ZNSLastSceneFailure=[NSString stringWithFormat:@"场景句柄诊断\n%@\nC/L为旧版主显示入口；请反馈完整诊断。",
        [trace componentsJoinedByString:@"; "]];
    os_log_error(ZNSLog(),"registered handle lookup failed: %{public}@",ZNSLastSceneFailure);
    return nil;
}
- (void)finish:(BOOL)ok message:(NSString *)message {
    void (^done)(BOOL,NSString *)=self.completion; self.completion=nil;
    if (!ok) [self stopForFullscreen:NO];
    else [self beginProcessExitObservation];
    if (done) done(ok,message);
}
- (void)startWithSize:(CGSize)size completion:(void (^)(BOOL,NSString *))completion {
    if (!NSThread.isMainThread || self.stopped || self.scene || self.completion) {
        if (completion) completion(NO,@"场景已启动、已释放或调用线程不正确");
        return;
    }
    if (!ZNSValidCanvasSize(size)) {
        if (completion) completion(NO,@"场景尺寸必须是有限的正数");
        return;
    }
    ZNSLastSceneFailure=nil;
    [self reloadKeyboardPreference];
    self.canvasSize=size; self.completion=completion;
    const char *launchArguments[]={"@",@encode(BOOL)};
    if (!ZNSRequireABI(UIApplication.sharedApplication,@selector(launchApplicationWithIdentifier:suspended:),@encode(BOOL),launchArguments,2,@"L1")) {
        [self finish:NO message:ZNSLastSceneFailure]; return;
    }
    @try {
        [UIApplication.sharedApplication launchApplicationWithIdentifier:self.bundleIdentifier suspended:YES];
        [self awaitScene:0];
    } @catch (NSException *exception) {
        os_log_error(ZNSLog(),"launch rejected: %{public}@",exception.name);
        [self finish:NO message:@"系统拒绝启动此应用，请关闭小窗后重试"];
    }
}
- (void)awaitScene:(NSUInteger)attempt {
    if (self.stopped || self.deviceLockRequested || self.switcherRemovalRequested) return;
    NSString *stage=@"find-scene";
    @try {
        ZNSLastSceneFailure=nil;
        id scene=[self findScene];
        if (!scene && ZNSLastSceneFailure) {
            [self finish:NO message:ZNSLastSceneFailure]; return;
        }
        if(self.sceneSelectionAmbiguous) {
            [self finish:NO message:@"此 App 有多个系统窗口，无法安全确定要托管的窗口。请先只保留一个窗口，再启动分屏。"];
            return;
        }
        if (scene) {
            stage=@"registered-handle";
            id handle=[self existingHandleForScene:scene];
            if (!handle) {
                // Registration can lag discovery. Retry before retaining the
                // scene, editing settings, acquiring assertions or installing hooks.
                if (ZNSSceneLookupCanRetry(attempt)) [self scheduleSceneRetryAfterAttempt:attempt];
                else [self finish:NO message:ZNSLastSceneFailure ?: @"场景句柄查找超时。"];
                return;
            }
            self.scene=scene;
            self.handle=handle;
            stage=@"save-settings";
            id settings=ZNSGet(scene,@"settings");
            if (!ZNSRequireABI(settings,@selector(copy),"@",NULL,0,@"S4")) {
                [self finish:NO message:ZNSLastSceneFailure]; return;
            }
            self.savedSettings=[settings copy];
            if (!ZNSSettingsReadAPI(self.savedSettings)) {
                [self finish:NO message:ZNSLastSceneFailure]; return;
            }
            {
                CGRect originalFrame=[self.savedSettings frame];
                BOOL hasDeviceDirection=ZNSGetter(self.savedSettings,NSSelectorFromString(@"deviceOrientation"),@encode(NSInteger));
                NSInteger originalDevice=hasDeviceDirection?((NSInteger(*)(id,SEL))objc_msgSend)(self.savedSettings,NSSelectorFromString(@"deviceOrientation")):0;
                os_log(ZNSLog(),"native scene before hosting frame=(%.1f,%.1f %.1fx%.1f) interface=%ld device=%ld deviceKnown=%d; preserve evidence of system frame/orientation convention",
                    originalFrame.origin.x,originalFrame.origin.y,originalFrame.size.width,originalFrame.size.height,
                    (long)[self.savedSettings interfaceOrientation],(long)originalDevice,hasDeviceDirection);
            }
            os_log(ZNSLog(),"scene registered handle found=1");
            BOOL canHost=ZNSHostFactoryAPI(self.handle,NO) || ZNSHostFactoryAPI(self.handle,YES);
            BOOL canUpdate=ZNSSceneUpdateSignature(object_getClass(scene),@selector(updateSettings:withTransitionContext:completion:),5);
            os_log(ZNSLog(),"scene API handleClass=%{public}@ sceneClass=%{public}@ host=%d update=%d",NSStringFromClass([self.handle class]),NSStringFromClass([scene class]),canHost,canUpdate);
            if (!canHost || !canUpdate) {
                [self finish:NO message:!canHost?@"实时场景接口不兼容：缺少视图创建接口（H1）":@"实时场景接口不兼容：缺少场景更新接口（S1）"]; return;
            }
            if (!ZNSRequireABI(scene,@selector(updateSettingsWithBlock:),"v",(const char * const[]){"@?"},1,@"S6")) {
                [self finish:NO message:ZNSLastSceneFailure]; return;
            }
            ZNSInstallSceneLeaseHook();
            if (!ZNSSceneLeaseHookInstalled) {
                [self finish:NO message:@"此系统缺少场景保持接口，无法安全维持实时空挂"]; return;
            }
            self.keepAlive=[[ZNSProcessKeepAlive alloc] initWithBundleIdentifier:self.bundleIdentifier];
            self.lease=[ZNSSceneLease new];
            objc_setAssociatedObject(scene,&ZNSSceneLeaseKey,self.lease,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            __weak typeof(self) weakSelf=self;
            if (![self resize:self.canvasSize landscape:NO completion:^(BOOL success,NSString *message) {
                ZNSSceneSession *self=weakSelf;
                if (!self || self.stopped) return;
                if (success) os_log(ZNSLog(),"scene update callback received; host retained; visual/touch verification still required");
                [self finish:success message:message];
            }]) {
                NSString *failure=ZNSLastSceneFailure ?: @"系统未提供失败细节";
                [ZNSSceneSession emitDiagnostics];
                [self finish:NO message:[NSString stringWithFormat:@"无法提交实时场景布局，已释放托管：%@",failure]]; return;
            }
            return;
        }
    } @catch (NSException *exception) {
        os_log_error(ZNSLog(),"scene attach exception stage=%{public}@ name=%{public}@",stage,exception.name);
        [self finish:NO message:@"场景托管失败，已尝试还原应用状态"]; return;
    }
    if (!ZNSSceneLookupCanRetry(attempt)) {
        [self finish:NO message:@"未找到应用场景。请先全屏打开此 App 一次，返回桌面后再按设置的方向滑动图标。"]; return;
    }
    [self scheduleSceneRetryAfterAttempt:attempt];
}
- (void)scheduleSceneRetryAfterAttempt:(NSUInteger)attempt {
    if (self.stopped || self.deviceLockRequested || self.switcherRemovalRequested || !ZNSSceneLookupCanRetry(attempt)) return;
    __weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,200*NSEC_PER_MSEC),dispatch_get_main_queue(),^{ [weakSelf awaitScene:attempt+1]; });
}
- (UIView *)newHostWithSize:(CGSize)size orientation:(NSInteger)orientation requester:(ZNSSceneHostRequester *)requester {
    UIView *view=nil;
    @try {
        // These are the same factories used by initial hosting, not guessed
        // setters. A replacement is created only after the real scene callback.
        if (ZNSHostFactoryAPI(self.handle,NO)) {
            view=[self.handle newSceneViewWithReferenceSize:size orientation:orientation hostRequester:requester];
        } else if (ZNSHostFactoryAPI(self.handle,YES)) {
            view=[self.handle newSceneViewWithReferenceSize:size contentOrientation:orientation containerOrientation:orientation hostRequester:requester];
        }
        if (view && view==self.hostView) return view; // Replacement caller rejects reuse without touching it.
        if (![view isKindOfClass:UIView.class]) {
            ZNSLastSceneFailure=@"场景工厂未返回托管视图（H0）";
            ZNSInvalidateHost(view);
            return nil;
        }
        BOOL compatible=ZNSHostCanvasAPI(view);
        if (compatible && !ZNSDisplayModeAPI(view))
            compatible=ZNSCompatibilityFailure(view,@selector(setDisplayMode:animationFactory:completion:),@"H3");
        if (compatible) compatible=ZNSRequireABI(view,@selector(invalidate),"v",NULL,0,@"H5");
        if (!compatible) {
            NSString *failure=ZNSLastSceneFailure;
            ZNSInvalidateHost(view);
            ZNSLastSceneFailure=failure;
            return nil;
        }
        ZNSSetBool(view,@"setPlaceholderContentEnabled:",NO);
        // Presentation scaling never implicitly changes the remote scene size.
        ZNSSetBool(view,@"setResizesHostedContext:",NO);
        [view setDisplayMode:4 animationFactory:nil completion:nil];
        view.userInteractionEnabled=YES;
        return view;
    } @catch (NSException *exception) {
        @try { ZNSInvalidateHost(view); }
        @catch (NSException *cleanupException) { os_log_error(ZNSLog(),"new host cleanup failed: %{public}@",cleanupException.name); }
        @throw exception;
    }
}
- (BOOL)replaceHostWithSize:(CGSize)size orientation:(NSInteger)orientation generation:(NSUInteger)generation {
    UIView *candidate=nil;
    @try {
        ZNSSceneHostRequester *requester=[ZNSSceneHostRequester new];
        candidate=[self newHostWithSize:size orientation:orientation requester:requester];
        if (candidate && candidate==self.hostView) {
            // A factory that reuses its existing view is not a fresh-host API.
            // Never detach/invalidate the current host through failure cleanup.
            candidate=nil;
            os_log_error(ZNSLog(),"orientation factory reused current host; safe replacement refused");
            return NO;
        }
        if (!candidate || self.stopped || self.layoutGeneration!=generation ||
            !ZNSConfigureHostCanvas(candidate,size,orientation)) return NO;
        if (self.stopped || self.layoutGeneration!=generation) return NO;
        UIView *previous=self.hostView;
        // Preserve the containing view even for callers without a completion.
        // Do not restart/reparent the App's scene, only replace its presentation.
        candidate.userInteractionEnabled=previous.userInteractionEnabled;
        if (previous.superview) [previous.superview insertSubview:candidate aboveSubview:previous];
        if (self.stopped || self.layoutGeneration!=generation) return NO;
        self.hostView=candidate;
        self.hostRequester=requester;
        candidate=nil; // Ownership committed; finally cleans up only failures.
        [previous removeFromSuperview];
        @try { ZNSInvalidateHost(previous); }
        @catch (NSException *exception) { os_log_error(ZNSLog(),"old orientation host invalidate failed: %{public}@",exception.name); }
        os_log(ZNSLog(),"orientation host recreated after scene callback; same App scene retained; visual completeness unverified");
        return YES;
    } @finally {
        if (candidate) {
            [candidate removeFromSuperview];
            @try { ZNSInvalidateHost(candidate); }
            @catch (NSException *exception) { os_log_error(ZNSLog(),"replacement host cleanup failed: %{public}@",exception.name); }
        }
    }
}
- (BOOL)resize:(CGSize)size landscape:(BOOL)landscape {
    return [self resize:size landscape:landscape completion:nil];
}
- (BOOL)resize:(CGSize)size landscape:(BOOL)landscape completion:(void (^)(BOOL,NSString *))completion {
    ZNSLastSceneFailure=nil;
    if (!NSThread.isMainThread || self.stopped || self.deviceLockRequested || self.switcherRemovalRequested || !self.scene || self.layoutInFlight ||
        !ZNSValidCanvasSize(size)) {
        ZNSLastSceneFailure=@"布局请求状态无效：线程、场景、处理中状态或画布尺寸（S0L）";
        return NO;
    }
    // A normal rotation/resize supersedes any temporary keyboard transaction.
    // Restore synchronously before capturing previousSize/lease for rollback.
    if (![self restoreTemporaryPortraitCanvas]) {
        ZNSLastSceneFailure=@"临时输入场景恢复提交失败（TPR）";
        return NO;
    }
    SEL update=@selector(updateSettings:withTransitionContext:completion:);
    if (!ZNSSceneUpdateSignature(object_getClass(self.scene),update,5)) {
        ZNSLastSceneFailure=@"Scene completion API missing or ABI incompatible (S2)";
        [ZNSSceneSession emitDiagnostics];
        return NO;
    }
    NSInteger orientation=landscape?UIInterfaceOrientationLandscapeRight:UIInterfaceOrientationPortrait;
    // The App/host canvas remains oriented; only the FBScene frame is fixed-space.
    // Keep this immutable value for submission AND acknowledgment validation.
    CGRect sceneFrame=ZNSSceneFrameForCanvas(size,landscape);
    NSString *stage=@"prepare-settings";
    id previousOwned=self.lease.settings;
    CGSize previousSize=self.canvasSize;
    BOOL previousLandscape=self.landscape;
    BOOL replaceOrientationHost=self.hostView!=nil && previousLandscape!=landscape;
    @try {
        id settings=ZNSGet(self.scene,@"settings");
        if (!ZNSRequireABI(settings,@selector(mutableCopy),"@",NULL,0,@"S4")) return NO;
        id desired=[settings mutableCopy];
        if (!ZNSSettingsReadAPI(desired) || !ZNSSettingsWriteAPI(desired)) return NO;
        SEL presentationGetter=ZNSScenePresentationGetter(desired);
        if (!ZNSSetSceneBackgrounded(desired,NO)) return NO;
        os_log(ZNSLog(),"scene presentation route=%{public}@",NSStringFromSelector(presentationGetter));
        [desired setFrame:sceneFrame];
        [desired setInterfaceOrientation:orientation];
        // UIInterfaceOrientationLandscapeRight maps to UIDeviceOrientationLandscapeLeft.
        // Only this App's scene receives the virtual device direction.
        SEL deviceSetter=NSSelectorFromString(@"setDeviceOrientation:");
        if (!ZNSHostSetter(desired,deviceSetter,@encode(NSInteger))) return NO;
        NSInteger deviceOrientation=landscape?UIDeviceOrientationLandscapeLeft:UIDeviceOrientationPortrait;
        ((void(*)(id,SEL,NSInteger))objc_msgSend)(desired,deviceSetter,deviceOrientation);
        // Keep the system's event-subscription policy. On the reproduced iOS
        // 16.1.1 failure, the callback reports eventsEnabled=NO; requiring YES
        // rejected even the initial portrait host before any rotation attempt.
        ZNSLogClientDirection(self.scene,orientation,"before-submit");
        if (self.hostView && !ZNSHostCanvasAPI(self.hostView)) return NO;
        // Publish desired settings to our scene-scoped guard before any host
        // setter can cause a nested system update. No other scene is affected.
        // Restore the keyboard before the old presentation can be resized or
        // invalidated. Reattach only after the scene/host update completes.
        [self.keyboardFocus invalidate];
        [self.keyboardPlacement suspend];
        self.changedSettings=YES;
        self.lease.settings=desired;
        stage=@"create-initial-host";
        if (!self.hostView) {
            UIView *view=[self newHostWithSize:size orientation:orientation requester:self.hostRequester];
            if (!view) {
                self.lease.settings=previousOwned;
                return NO;
            }
            self.hostView=view;
            os_log(ZNSLog(),"created scene host=%{public}@ combinedCanvasUpdater=%d",
                NSStringFromClass(view.class),ZNSHostCombinedCanvasAPI(view));
        }
        // Observe as soon as a host exists, not only after layout completion:
        // the client may exit while the initial scene transaction is pending.
        [self beginProcessExitObservation];
        self.layoutInFlight=YES;
        NSUInteger generation=++self.layoutGeneration;
        self.layoutCompletion=completion;
        stage=@"submit-scene-update";
        __weak typeof(self) weakSelf=self;
        // A no-payload event block deliberately does not interpret undocumented
        // arguments as BOOL success. Method ABI verification above confirms @?.
        // nil context lets FBScene create its normal scene transition context.
        // Never infer completion from a timer, CATransaction or settings writes.
        [self.scene updateSettings:desired withTransitionContext:nil completion:^{
            dispatch_async(dispatch_get_main_queue(),^{
                ZNSSceneSession *self=weakSelf;
                if (!self || self.stopped || !self.layoutInFlight || self.layoutGeneration!=generation) return;
                BOOL ok=YES;
                NSString *message=nil;
                @try {
                    id applied=ZNSGet(self.scene,@"settings");
                    CGRect expectedFrame=sceneFrame;
                    BOOL frameKnown=ZNSGetter(applied,@selector(frame),@encode(CGRect));
                    BOOL interfaceKnown=ZNSGetter(applied,@selector(interfaceOrientation),@encode(NSInteger));
                    BOOL deviceKnown=ZNSGetter(applied,NSSelectorFromString(@"deviceOrientation"),@encode(NSInteger));
                    CGRect actualFrame=frameKnown?[applied frame]:CGRectNull;
                    NSInteger actualInterface=interfaceKnown?[applied interfaceOrientation]:-1;
                    NSInteger actualDevice=deviceKnown?((NSInteger(*)(id,SEL))objc_msgSend)(applied,NSSelectorFromString(@"deviceOrientation")):-1;
                    BOOL frameMatches=frameKnown && CGRectEqualToRect(actualFrame,expectedFrame);
                    BOOL interfaceMatches=interfaceKnown && actualInterface==orientation;
                    BOOL deviceMatches=deviceKnown && actualDevice==deviceOrientation;
                    // Event subscription is diagnostic only. NO is a legitimate
                    // policy and must not tear down an otherwise valid host.
                    os_log(ZNSLog(),"scene ack frameKnown=%d actual=(%.1f,%.1f %.1fx%.1f) expectedFixed=(0,0 %.1fx%.1f) displayCanvas=%.1fx%.1f frameMatches=%d interfaceKnown=%d interface=%ld expectedInterface=%ld interfaceMatches=%d deviceKnown=%d device=%ld expectedDevice=%ld deviceMatches=%d",
                        frameKnown,actualFrame.origin.x,actualFrame.origin.y,actualFrame.size.width,actualFrame.size.height,expectedFrame.size.width,expectedFrame.size.height,size.width,size.height,frameMatches,
                        interfaceKnown,(long)actualInterface,(long)orientation,interfaceMatches,deviceKnown,(long)actualDevice,(long)deviceOrientation,deviceMatches);
                    BOOL presentationKnown=ZNSSceneBoolGetterAPI(applied,presentationGetter);
                    BOOL presentationValue=presentationKnown?ZNSBool(applied,NSStringFromSelector(presentationGetter)):NO;
                    BOOL presentationMatches=presentationKnown &&
                        (presentationGetter==NSSelectorFromString(@"isForeground")?presentationValue:!presentationValue);
                    os_log(ZNSLog(),"scene presentation ack getter=%{public}@ known=%d value=%d matches=%d",
                        NSStringFromSelector(presentationGetter),presentationKnown,presentationValue,presentationMatches);
                    BOOL matches=frameMatches && interfaceMatches && deviceMatches && presentationMatches;
                    if (!matches) {
                        ok=NO;
                        NSMutableArray<NSString *> *fields=[NSMutableArray new];
                        if(!frameMatches) [fields addObject:@"场景固定坐标尺寸"];
                        if(!interfaceMatches) [fields addObject:@"界面方向"];
                        if(!deviceMatches) [fields addObject:@"设备方向"];
                        if(!presentationMatches) [fields addObject:@"场景前台状态"];
                        message=[NSString stringWithFormat:@"系统回执不匹配：%@；请关闭小窗后重试",[fields componentsJoinedByString:@"、"]];
                        ZNSLastSceneFailure=[NSString stringWithFormat:@"Scene acknowledgment mismatch (S3): frame=%d interface=%d device=%d presentation=%d",frameMatches,interfaceMatches,deviceMatches,presentationMatches];
                        [ZNSSceneSession emitDiagnostics];
                    } else {
                        // A fresh presentation avoids carrying a portrait host's
                        // cached context into landscape (reported half-black
                        // Safari). This is a compatibility attempt, not proof of
                        // client redraw. Never synthesize a scene callback.
                        ok=replaceOrientationHost?
                            [self replaceHostWithSize:size orientation:orientation generation:generation]:
                            ZNSConfigureHostCanvas(self.hostView,size,orientation);
                        if (self.stopped || self.layoutGeneration!=generation) return;
                        if (ok) {
                            self.canvasSize=size;
                            self.landscape=landscape;
                            ZNSLastSceneFailure=nil;
                        } else {
                            message=@"托管视图坐标方向未同步，已停止本次布局";
                            ZNSLastSceneFailure=@"Host reference size/orientation readback mismatch (H2)";
                            [ZNSSceneSession emitDiagnostics];
                        }
                        id client=ZNSGet(self.scene,@"clientSettings");
                        if (ZNSGetter(client,@selector(interfaceOrientation),@encode(NSInteger))) {
                            NSInteger clientOrientation=[client interfaceOrientation];
                            os_log(ZNSLog(),"rotation sceneDevice=%ld sceneInterface=%ld clientInterface=%ld clientDirectionMatches=%d canvas=%.1fx%.1f freshHost=%d; client rendering/touch unverified",
                                (long)deviceOrientation,(long)orientation,(long)clientOrientation,clientOrientation==orientation,size.width,size.height,replaceOrientationHost && ok);
                            if (clientOrientation!=orientation)
                                os_log_error(ZNSLog(),"scene settings acknowledged but client direction differs; do not infer full landscape rendering");
                        } else {
                            os_log(ZNSLog(),"client direction unavailable; scene/host geometry acknowledgment is not a rendered-frame acknowledgment");
                        }
                    }
                } @catch (NSException *exception) {
                    ok=NO;
                    message=@"系统已回执方向更新，但托管视图布局失败；请关闭小窗后重试";
                    ZNSLastSceneFailure=[NSString stringWithFormat:@"host-layout %@: %@",exception.name,exception.reason ?: @"no reason"];
                    [ZNSSceneSession emitDiagnostics];
                }
                if (self.stopped || !self.layoutInFlight || self.layoutGeneration!=generation) return;
                @try { ZNSLogClientDirection(self.scene,orientation,"scene-callback"); }
                @catch(NSException *exception) { os_log_error(ZNSLog(),"client direction probe failed: %{public}@",exception.name); }
                if(ok) {
                    // Diagnostics only: timers never complete or approve rotation.
                    for(NSNumber *delay in @[@0.35,@1.0]) {
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay.doubleValue*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
                            ZNSSceneSession *current=weakSelf;
                            if(!current || current.stopped || current.layoutGeneration!=generation) return;
                            @try { ZNSLogClientDirection(current.scene,orientation,"after-callback"); }
                            @catch(NSException *exception) { os_log_error(ZNSLog(),"client direction probe failed: %{public}@",exception.name); }
                        });
                    }
                }
                self.layoutInFlight=NO;
                if (ok) [self.keyboardPlacement updateHost:self.hostView canvas:self.canvasSize];
                void (^done)(BOOL,NSString *)=self.layoutCompletion;
                self.layoutCompletion=nil;
                os_log(ZNSLog(),"scene update callback generation=%lu canvas=%.0fx%.0f orientation=%ld localLayout=%d; client rendering unverified",
                    (unsigned long)generation,size.width,size.height,(long)orientation,ok);
                if (done) done(ok,message);
            });
        }];
        os_log(ZNSLog(),"scene update submitted generation=%lu displayCanvas=%.0fx%.0f fixedFrame=%.0fx%.0f orientation=%ld",(unsigned long)generation,size.width,size.height,sceneFrame.size.width,sceneFrame.size.height,(long)orientation);
        return YES;
    } @catch (NSException *exception) {
        // Any queued callback from a partially submitted transaction is stale.
        ++self.layoutGeneration;
        self.layoutInFlight=NO;
        self.layoutCompletion=nil;
        self.lease.settings=previousOwned;
        if (previousOwned) {
            @try {
                // Best-effort rollback only, never reported as a completed
                // rotation. Keep the same scene and host even on failure.
                [self.scene updateSettings:previousOwned withTransitionContext:nil completion:nil];
                ZNSConfigureHostCanvas(self.hostView,previousSize,previousLandscape?UIInterfaceOrientationLandscapeRight:UIInterfaceOrientationPortrait);
            } @catch (NSException *rollbackException) {
                os_log_error(ZNSLog(),"scene rollback failed: %{public}@",rollbackException.name);
            }
        }
        ZNSLastSceneFailure=[NSString stringWithFormat:@"stage=%@ %@: %@",stage,exception.name,exception.reason ?: @"no reason"];
        [ZNSSceneSession emitDiagnostics];
        return NO;
    }
}
- (void)dealloc {
    if (_processExitSource) dispatch_source_cancel(_processExitSource);
    [_keyboardPlacement invalidate];
    [_keyboardFocus invalidate];
    _lease.settings=nil;
    if (_scene && objc_getAssociatedObject(_scene,&ZNSSceneLeaseKey)==_lease)
        objc_setAssociatedObject(_scene,&ZNSSceneLeaseKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (void)releaseHostedSceneLeaseAndKeepAlive {
    [self znsCancelPortraitRestore];
    ++self.temporaryPortraitGeneration;
    self.temporaryPortraitPending=NO;
    self.temporaryPortraitSettings=nil;
    self.temporaryPortraitFailure=nil;
    self.temporaryPortraitCanvas=CGSizeZero;
    self.temporaryPortraitFrame=CGRectZero;
    self.lease.settings=nil;
    if (self.scene && objc_getAssociatedObject(self.scene,&ZNSSceneLeaseKey)==self.lease)
        objc_setAssociatedObject(self.scene,&ZNSSceneLeaseKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    self.lease=nil;
    [self.keepAlive invalidate]; self.keepAlive=nil;
}
- (void)prepareForSwitcherRemoval {
    if (!NSThread.isMainThread || self.stopped || self.deviceLockRequested || self.switcherRemovalRequested) return;
    self.switcherRemovalRequested=YES;
    ++self.layoutGeneration;
    self.layoutInFlight=NO;
    self.layoutCompletion=nil;
    self.completion=nil;
    [self releaseHostedSceneLeaseAndKeepAlive];
}
- (void)prepareForDeviceLock {
    if (!NSThread.isMainThread || self.stopped || self.deviceLockRequested) return;
    self.deviceLockRequested=YES;
    ++self.layoutGeneration;
    self.layoutInFlight=NO;
    self.layoutCompletion=nil;
    self.completion=nil;
    [self cancelProcessExitObservation];
    // Remove the foreground lease before native lock/background transactions.
    [self releaseHostedSceneLeaseAndKeepAlive];
}
- (void)stopForFullscreen:(BOOL)fullscreen {
    [self cancelProcessExitObservation];
    if (self.stopped) return;
    self.stopped=YES;
    [self.keyboardPlacement invalidate]; self.keyboardPlacement=nil;
    [self.keyboardFocus invalidate]; self.keyboardFocus=nil;
    ++self.layoutGeneration;
    self.layoutInFlight=NO;
    self.layoutCompletion=nil;
    self.completion=nil;
    // Drop the guard BEFORE restoring settings or launching fullscreen.
    [self releaseHostedSceneLeaseAndKeepAlive];
    // A host invalidation failure must not skip the background transition.
    @try { [self.hostView removeFromSuperview]; }
    @catch (NSException *exception) { os_log_error(ZNSLog(),"host detach exception: %{public}@",exception.name); }
    @try { ZNSInvalidateHost(self.hostView); }
    @catch (NSException *exception) { os_log_error(ZNSLog(),"host invalidate exception: %{public}@",exception.name); }
    @try {
        // A dead client or committed switcher removal has nothing to restore;
        // submitting another transaction can race the system's scene teardown.
        // On device lock the system owns backgrounding and geometry. Do not
        // race that transition with a second FBScene settings transaction.
        if (!self.deviceLockRequested && !self.clientProcessExited && !self.switcherRemovalRequested && self.scene &&
            ZNSRequireABI(self.scene,@selector(updateSettingsWithBlock:),"v",(const char * const[]){"@?"},1,@"S6")) {
            id original=self.savedSettings;
            BOOL restoreGeometry=self.changedSettings && original!=nil;
            [self.scene updateSettingsWithBlock:^(id settings) {
                if (restoreGeometry) {
                    if (ZNSGetter(original,@selector(frame),@encode(CGRect)) && ZNSHostSetter(settings,@selector(setFrame:),@encode(CGRect))) [settings setFrame:[original frame]];
                    if (ZNSGetter(original,@selector(interfaceOrientation),@encode(NSInteger)) && ZNSHostSetter(settings,@selector(setInterfaceOrientation:),@encode(NSInteger))) [settings setInterfaceOrientation:[original interfaceOrientation]];
                    ZNSCopyDeviceOrientation(settings,original);
                }
                // The saved state may be foreground (e.g. status-bar activation).
                // Closing must NOT resurrect that state after releasing our lease.
                // Fullscreen is the only exit that requests foreground here.
                if (!ZNSSetSceneBackgrounded(settings,!fullscreen))
                    os_log_error(ZNSLog(),"scene teardown presentation write rejected; system lifecycle remains authoritative");
            }];
            os_log(ZNSLog(),"scene teardown update requested backgrounded=%d; not an acknowledgment; suspension remains system-managed",!fullscreen);
        }
    } @catch (NSException *exception) { os_log_error(ZNSLog(),"scene release exception: %{public}@",exception.name); }
    self.hostView=nil; self.scene=nil; self.handle=nil; self.savedSettings=nil;
    os_log(ZNSLog(),"scene host released fullscreen=%d",fullscreen);
}
@end
