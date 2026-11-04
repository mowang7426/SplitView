#import "ZNSRecentApps.h"
#import "ZNSSceneSession.h"
#import <objc/message.h>
#import <os/log.h>
#import <string.h>

// FV 1.6.0-6 main-arm64 0x147f0..0x14ad8: display item type 0,
// actual FBScene.identifier, role @1, configuration/environment 1, ordinal 0.
// Metadata/signature checks below are mandatory; this is NOT runtime validation
// of the private API's semantics. No launch, screenshot or scene mutation here.
@protocol ZNSRecentLayoutFactory
- (instancetype)initWithItemsForLayoutRoles:(id)items configuration:(NSInteger)configuration environment:(NSInteger)environment preferredDisplayOrdinal:(NSInteger)ordinal;
- (instancetype)initWithItemsForLayoutRoles:(id)items configuration:(NSInteger)configuration environment:(NSInteger)environment;
@end

static os_log_t ZNSRecentLog(void) {
    static os_log_t log; static dispatch_once_t once;
    dispatch_once(&once,^{ log=os_log_create(APELIN_PACKAGE_ID,"recent-apps"); });
    return log;
}
static BOOL ZNSRecentSignature(id object,SEL selector,const char *result,NSArray<NSString *> *args) {
    if(!object || ![object respondsToSelector:selector]) return NO;
    NSMethodSignature *sig=[object methodSignatureForSelector:selector];
    if(!sig || strcmp(sig.methodReturnType,result) || sig.numberOfArguments!=args.count+2) return NO;
    for(NSUInteger i=0;i<args.count;i++) {
        const char *actual=[sig getArgumentTypeAtIndex:i+2],*expected=args[i].UTF8String;
        // Signed and unsigned native integers have the same calling convention.
        if(!strcmp(expected,@encode(NSInteger)) && !strcmp(actual,@encode(NSUInteger))) continue;
        if(strcmp(actual,expected)) return NO;
    }
    return YES;
}
static id ZNSRecentGet(id object,NSString *name) {
    SEL sel=NSSelectorFromString(name);
    return ZNSRecentSignature(object,sel,@encode(id),@[])?((id(*)(id,SEL))objc_msgSend)(object,sel):nil;
}
static BOOL ZNSRecentCollection(id value) {
    return [value isKindOfClass:NSArray.class] || [value isKindOfClass:NSSet.class] || [value isKindOfClass:NSOrderedSet.class];
}
static id ZNSRecentController(void) {
    for(NSString *name in @[@"SBMainSwitcherControllerCoordinator",@"SBMainSwitcherViewController"]) {
        id controller=ZNSRecentGet(NSClassFromString(name),@"sharedInstance");
        if(ZNSRecentSignature(controller,NSSelectorFromString(@"_addAppLayoutToFront:"),@encode(void),@[@(@encode(id))]) &&
           ZNSRecentSignature(controller,NSSelectorFromString(@"recentAppLayouts"),@encode(id),@[])) return controller;
    }
    return nil;
}
static BOOL ZNSRecentCanMutate(id controller) {
    id lock=ZNSRecentGet(NSClassFromString(@"SBLockScreenManager"),@"sharedInstance");
    SEL locked=NSSelectorFromString(@"isUILocked"),visible=NSSelectorFromString(@"isAnySwitcherVisible");
    if(!ZNSRecentSignature(lock,locked,@encode(BOOL),@[]) ||
       ((BOOL(*)(id,SEL))objc_msgSend)(lock,locked)) return NO;
    if(!ZNSRecentSignature(controller,visible,@encode(BOOL),@[])) return NO;
    return !((BOOL(*)(id,SEL))objc_msgSend)(controller,visible);
}
static id ZNSRecentNewLayout(NSString *bundle,NSString *sceneID) {
    Class itemClass=NSClassFromString(@"SBDisplayItem");
    SEL make=NSSelectorFromString(@"displayItemWithType:bundleIdentifier:uniqueIdentifier:");
    if(!ZNSRecentSignature(itemClass,make,@encode(id),@[@(@encode(NSInteger)),@(@encode(id)),@(@encode(id))])) return nil;
    id item=((id(*)(id,SEL,NSInteger,id,id))objc_msgSend)(itemClass,make,0,bundle,sceneID);
    if(!item) return nil;
    id<ZNSRecentLayoutFactory> allocated=[NSClassFromString(@"SBAppLayout") alloc];
    NSDictionary *roles=@{@1:item};
    SEL modern=@selector(initWithItemsForLayoutRoles:configuration:environment:preferredDisplayOrdinal:);
    if(ZNSRecentSignature(allocated,modern,@encode(id),@[@(@encode(id)),@(@encode(NSInteger)),@(@encode(NSInteger)),@(@encode(NSInteger))]))
        return [allocated initWithItemsForLayoutRoles:roles configuration:1 environment:1 preferredDisplayOrdinal:0];
    SEL legacy=@selector(initWithItemsForLayoutRoles:configuration:environment:);
    if(ZNSRecentSignature(allocated,legacy,@encode(id),@[@(@encode(id)),@(@encode(NSInteger)),@(@encode(NSInteger))]))
        return [allocated initWithItemsForLayoutRoles:roles configuration:1 environment:1];
    return nil;
}
// Reuse an existing single-App layout, rather than manufacturing duplicates.
// An unreadable or multi-App target layout prevents new-card creation.
static BOOL ZNSRecentApply(id controller,ZNSSceneSession *session) {
    NSString *bundle=session.bundleIdentifier;
    id scene=ZNSRecentGet(session,@"scene");
    NSString *sceneID=ZNSRecentGet(scene,@"identifier");
    NSString *owner=ZNSRecentGet(ZNSRecentGet(scene,@"clientProcess"),@"bundleIdentifier");
    if(!session.hostView || !bundle.length || ![sceneID isKindOfClass:NSString.class] || !sceneID.length || ![owner isEqual:bundle]) return NO;
    id layouts=ZNSRecentGet(controller,@"recentAppLayouts"),chosen=nil;
    if(!ZNSRecentCollection(layouts)) return NO;
    BOOL unreadable=NO;
    for(id layout in layouts) {
        id items=ZNSRecentGet(layout,@"allItems");
        if(!ZNSRecentCollection(items)) { unreadable=YES; continue; }
        BOOL target=NO,other=NO;
        for(id item in items) {
            id identifier=ZNSRecentGet(item,@"bundleIdentifier");
            if(![identifier isKindOfClass:NSString.class] || ![identifier length]) { unreadable=YES; other=YES; continue; }
            if([identifier isEqual:bundle]) target=YES; else other=YES;
        }
        if(target) {
            if(other) return NO; // Never rewrite a multi-App layout.
            if(!chosen) chosen=layout;
        }
    }
    BOOL reused=chosen!=nil;
    if(!chosen && !unreadable) chosen=ZNSRecentNewLayout(bundle,sceneID);
    if(!chosen) return NO;
    ((void(*)(id,SEL,id))objc_msgSend)(controller,NSSelectorFromString(@"_addAppLayoutToFront:"),chosen);
    id after=ZNSRecentGet(controller,@"recentAppLayouts");
    id first=([after isKindOfClass:NSArray.class] || [after isKindOfClass:NSOrderedSet.class])?[after firstObject]:nil;
    BOOL firstConfirmed=first==chosen || [first isEqual:chosen];
    os_log(ZNSRecentLog(),"recent card submitted reused=%d firstInModel=%d; visual order unverified",reused,firstConfirmed);
    return YES;
}

@interface ZNSRecentRequest : NSObject
@property(nonatomic,weak) ZNSSceneSession *session;
@end
@implementation ZNSRecentRequest
@end
static NSMutableArray<ZNSRecentRequest *> *ZNSRecentPending;
static BOOL ZNSRecentScheduled;
static void ZNSRecentDrain(NSUInteger attempts) {
    @try {
        id controller=ZNSRecentController();
        if(!controller) {
            os_log_error(ZNSRecentLog(),"recent card unavailable: controller ABI unsupported");
        } else if(!ZNSRecentCanMutate(controller) && attempts<30) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{ ZNSRecentDrain(attempts+1); });
            return;
        } else if(ZNSRecentCanMutate(controller)) {
            // FIFO: when several windows open during dismissal the last opened
            // App ends up first. Repeat requests for one session coalesce.
            NSArray *pending=[ZNSRecentPending copy];
            [ZNSRecentPending removeAllObjects];
            for(ZNSRecentRequest *request in pending) {
                ZNSSceneSession *session=request.session;
                if(session.hostView && !ZNSRecentApply(controller,session))
                    os_log_error(ZNSRecentLog(),"recent card skipped: identity/layout/API could not be verified");
            }
        } else os_log_error(ZNSRecentLog(),"recent card deferred request expired: locked or switcher visible");
    } @catch(NSException *exception) {
        os_log_error(ZNSRecentLog(),"recent card request failed: %{public}@",exception.name);
    }
    [ZNSRecentPending removeAllObjects]; ZNSRecentScheduled=NO;
}
void ZNSPromoteRecentApp(ZNSSceneSession *session) {
    if(!NSThread.isMainThread || !session.hostView) return;
    if(!ZNSRecentPending) ZNSRecentPending=[NSMutableArray new];
    for(ZNSRecentRequest *old in [ZNSRecentPending copy])
        if(!old.session || old.session==session) [ZNSRecentPending removeObject:old];
    ZNSRecentRequest *request=[ZNSRecentRequest new]; request.session=session;
    [ZNSRecentPending addObject:request];
    if(ZNSRecentScheduled) return;
    ZNSRecentScheduled=YES;
    // Never reorder the card inside its gesture/commit stack. The switcher
    // entry point gets to submit its Home dismissal before we inspect it.
    dispatch_async(dispatch_get_main_queue(),^{ ZNSRecentDrain(0); });
}
