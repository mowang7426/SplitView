#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <os/log.h>
#include <stdlib.h>

// Debug-only metadata inventory. Never creates a private object, obtains a
// singleton, reads a scene/window instance, requests focus, or changes routing.
// In particular, the old SBSKeyboardFocusService is not instantiated or called.
#if DEBUG
static BOOL ZNSKeyboardDiagnosticClass(NSString *name) {
    if ([name containsString:@"Keyboard"] &&
        ([name containsString:@"Focus"] || [name containsString:@"SceneLayer"] ||
         [name containsString:@"LayerHost"] || [name containsString:@"PresentationContext"])) return YES;
    return [@[@"SBMainWorkspace", @"FBScene", @"FBSSceneIdentity", @"FBSceneLayerManager",
              @"FBSceneLayer", @"FBSSceneLayer", @"SBSceneView", @"_UISceneLayerHostContainerView",
              @"_UISceneLayerHostView", @"_UISceneLayerPresentationContext",
              @"_UISceneLayerMutablePresentationContext", @"FBSSceneSettings"] containsObject:name];
}
static BOOL ZNSKeyboardDiagnosticSelector(NSString *name, NSString *selector) {
    if ([name containsString:@"Keyboard"]) return YES;
    for (NSString *term in @[@"keyboard", @"focus", @"layer", @"presentation", @"context",
                            @"observer", @"identity", @"valid", @"scene", @"shared"])
        if ([selector localizedCaseInsensitiveContainsString:term]) return YES;
    return NO;
}
static void ZNSKeyboardDiagnosticMethods(Class cls, NSMutableArray<NSString *> *rows) {
    NSString *name=NSStringFromClass(cls);
    Class parent=class_getSuperclass(cls);
    [rows addObject:[NSString stringWithFormat:@"class=%@ super=%s",name,parent?class_getName(parent):"none"]];
    for (NSUInteger meta=0;meta<2;meta++) {
        unsigned count=0;
        Method *methods=class_copyMethodList(meta?object_getClass(cls):cls,&count);
        for (unsigned i=0;i<count;i++) {
            NSString *selector=NSStringFromSelector(method_getName(methods[i]));
            if (ZNSKeyboardDiagnosticSelector(name,selector))
                [rows addObject:[NSString stringWithFormat:@"%@ %c%@ %s",name,meta?'+':'-',selector,method_getTypeEncoding(methods[i])]];
        }
        free(methods);
    }
    unsigned count=0;
    Protocol *__unsafe_unretained *protocols=class_copyProtocolList(cls,&count);
    for (unsigned i=0;i<count;i++) {
        Protocol *protocol=protocols[i];
        [rows addObject:[NSString stringWithFormat:@"%@ adopts=%s",name,protocol_getName(protocol)]];
        for (NSUInteger required=0;required<2;required++) {
            unsigned methodCount=0;
            struct objc_method_description *methods=protocol_copyMethodDescriptionList(protocol,required!=0,YES,&methodCount);
            for (unsigned j=0;j<methodCount;j++) {
                if (!methods[j].name || !methods[j].types) continue;
                NSString *selector=NSStringFromSelector(methods[j].name);
                if (ZNSKeyboardDiagnosticSelector(name,selector))
                    [rows addObject:[NSString stringWithFormat:@"protocol=%s required=%lu %@ %s",protocol_getName(protocol),(unsigned long)required,selector,methods[j].types]];
            }
            free(methods);
        }
    }
    free(protocols);
}
static void ZNSKeyboardDiagnosticEmit(NSArray<NSString *> *rows, NSUInteger cursor, NSUInteger remaining) {
    if (!remaining || !rows.count) return;
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once,^{log=os_log_create(APELIN_PACKAGE_ID,"keyboard-abi");});
    // Bounded batches make a 10-second live listener useful without dumping all
    // metadata on every layout. Metadata only; no identifiers of running apps.
    NSUInteger count=MIN((NSUInteger)16,rows.count);
    for (NSUInteger i=0;i<count;i++) {
        NSUInteger index=(cursor+i)%rows.count;
        os_log(log,"keyboard ABI build=%{public}s row=%lu/%lu %{public}@",APELIN_BUILD_ID,
            (unsigned long)index,(unsigned long)rows.count,rows[index]);
    }
    if (remaining>1)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{
            ZNSKeyboardDiagnosticEmit(rows,(cursor+count)%rows.count,remaining-1);
        });
}
__attribute__((constructor)) static void ZNSKeyboardDiagnosticStart(void) {
    // A SpringBoard-only guard remains necessary even if the project later adds
    // an App-side keyboard bridge. No foreign process should enumerate this set.
    if (!NSClassFromString(@"SpringBoard")) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,8*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        NSMutableArray<NSString *> *rows=[NSMutableArray new];
        unsigned count=0;
        Class *classes=objc_copyClassList(&count);
        NSMutableArray<NSString *> *names=[NSMutableArray new];
        for (unsigned i=0;i<count;i++) {
            NSString *name=NSStringFromClass(classes[i]);
            if (ZNSKeyboardDiagnosticClass(name)) [names addObject:name];
        }
        free(classes);
        [names sortUsingSelector:@selector(compare:)];
        for (NSString *name in names) ZNSKeyboardDiagnosticMethods(NSClassFromString(name),rows);
        if (!rows.count) [rows addObject:@"no matching classes; routing remains unsupported"];
        ZNSKeyboardDiagnosticEmit([rows copy],0,60);
    });
}
#endif
