#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <os/log.h>
#import <objc/runtime.h>
#import <string.h>

static inline os_log_t ZNSLog(void) {
    static os_log_t log; static dispatch_once_t once;
    dispatch_once(&once,^{ log=os_log_create(APELIN_PACKAGE_ID,"windows"); });
    return log;
}
static inline const char *ZNSSkipTypeQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV",*type)) ++type;
    return type;
}
static inline BOOL ZNSObjectType(const char *type) {
    type=ZNSSkipTypeQualifiers(type);
    // Typed objects (including protocol-qualified objects) have the same ABI
    // as id. A block (@?) is deliberately not an ordinary object here.
    size_t length=strlen(type);
    return !strcmp(type,"@") || (length>=3 && type[0]=='@' && type[1]=='\"' && type[length-1]=='\"');
}
static inline BOOL ZNSTypeMatches(const char *actual,const char *expected) {
    actual=ZNSSkipTypeQualifiers(actual);
    return !strcmp(expected,"@") ? ZNSObjectType(actual) : !strcmp(actual,expected);
}
static inline NSMethodSignature *ZNSPrivateSignature(id object,SEL selector) {
    if (!object || !selector) return nil;
    @try {
        Method method=class_getInstanceMethod(object_getClass(object),selector);
        const char *encoding=method?method_getTypeEncoding(method):NULL;
        if (encoding) return [NSMethodSignature signatureWithObjCTypes:encoding];
        // A dynamic accessor may not have an IMP until resolution is requested.
        // A forwarding object can also advertise an exact method signature
        // without registering an IMP. Neither is proof that the API is absent.
        // Keep exact ABI checks even for dynamically forwarded scene accessors.
        // Never synthesize a signature from a property or guess a scalar type.
        BOOL responds=[object respondsToSelector:selector];
        method=class_getInstanceMethod(object_getClass(object),selector);
        encoding=method?method_getTypeEncoding(method):NULL;
        if (encoding) return [NSMethodSignature signatureWithObjCTypes:encoding];
        if (!responds) {
            // Only known scene presentation accessors may supply a forwarding
            // signature independently of respondsToSelector:. A nil signature
            // remains unsupported; this does not install a method or force a call.
            Class sceneSettings=NSClassFromString(@"FBSSceneSettings");
            NSString *name=NSStringFromSelector(selector);
            if (!sceneSettings || ![object isKindOfClass:sceneSettings] ||
                ![@[@"setBackgrounded:",@"isBackgrounded",@"setForeground:",@"isForeground"] containsObject:name]) return nil;
        }
        return [object methodSignatureForSelector:selector];
    } @catch (__unused NSException *exception) { return nil; }
}
static inline NSString *ZNSPrivateSignatureDescription(id object,SEL selector) {
    NSMethodSignature *signature=ZNSPrivateSignature(object,selector);
    if (!signature) return @"未取得可调用签名";
    NSMutableString *text=[NSMutableString stringWithFormat:@"返回=%s 参数=",signature.methodReturnType];
    for (NSUInteger i=0;i<signature.numberOfArguments;i++) {
        if(i) [text appendString:@","];
        [text appendFormat:@"%s",[signature getArgumentTypeAtIndex:i]];
    }
    return text;
}
static inline BOOL ZNSPrivateABI(id object,SEL selector,const char *result,
                                 const char * const *arguments,NSUInteger count) {
    NSMethodSignature *signature=ZNSPrivateSignature(object,selector);
    if (!signature || signature.numberOfArguments!=count+2 ||
        !ZNSTypeMatches(signature.methodReturnType,result)) return NO;
    for (NSUInteger i=0;i<count;i++)
        if (!ZNSTypeMatches([signature getArgumentTypeAtIndex:i+2],arguments[i])) return NO;
    return YES;
}
static inline void ZNSPrivateABIError(id object,SEL selector) {
    os_log_error(ZNSLog(),"private API missing or ABI incompatible class=%{public}@ selector=%{public}@",
                 object?NSStringFromClass(object_getClass(object)):@"nil",NSStringFromSelector(selector));
}
static inline id ZNSGet(id object, NSString *name) {
    SEL sel=NSSelectorFromString(name);
    if (ZNSPrivateABI(object,sel,"@",NULL,0)) return ((id(*)(id,SEL))objc_msgSend)(object,sel);
    if (object) ZNSPrivateABIError(object,sel);
    return nil;
}
static inline BOOL ZNSBool(id object, NSString *name) {
    SEL sel=NSSelectorFromString(name);
    if (ZNSPrivateABI(object,sel,"B",NULL,0)) return ((bool(*)(id,SEL))objc_msgSend)(object,sel);
    // Older Objective-C BOOL can be encoded as signed char. Call it with that
    // exact return type and normalize; never interpret an object/integer as BOOL.
    if (ZNSPrivateABI(object,sel,"c",NULL,0)) return ((signed char(*)(id,SEL))objc_msgSend)(object,sel)!=0;
    if (object) ZNSPrivateABIError(object,sel);
    return NO;
}
static inline id ZNSShared(NSString *name) { return ZNSGet(NSClassFromString(name),@"sharedInstance"); }
static inline void ZNSSetBool(id object, NSString *name, BOOL value) {
    SEL sel=NSSelectorFromString(name);
    const char *boolean[]={"B"},*character[]={"c"};
    if (ZNSPrivateABI(object,sel,"v",boolean,1)) ((void(*)(id,SEL,bool))objc_msgSend)(object,sel,value);
    else if (ZNSPrivateABI(object,sel,"v",character,1)) ((void(*)(id,SEL,signed char))objc_msgSend)(object,sel,value?1:0);
    else if (object) ZNSPrivateABIError(object,sel);
}
@interface NSObject (ZNSPrivateDeclarations)
- (BOOL)launchApplicationWithIdentifier:(NSString *)identifier suspended:(BOOL)suspended;
- (id)applicationWithBundleIdentifier:(NSString *)identifier;
- (void)enumerateScenesWithBlock:(void (^)(id scene))block;
- (void)updateSettingsWithBlock:(void (^)(id settings))block;
// Checked at runtime for v@:@@@? before use. The callback is consumed only as
// an event: no undocumented success flag or object payload is read from it.
- (void)updateSettings:(id)settings withTransitionContext:(id)context completion:(void (^)(void))completion;
- (void)setBackgrounded:(BOOL)value;
- (void)setInterfaceOrientation:(NSInteger)value;
- (void)setFrame:(CGRect)frame;
- (CGRect)frame;
- (NSInteger)interfaceOrientation;
- (BOOL)isBackgrounded;
- (id)existingSceneHandleForScene:(id)scene;
- (id)newSceneViewWithReferenceSize:(CGSize)size orientation:(NSInteger)orientation hostRequester:(id)requester;
- (id)newSceneViewWithReferenceSize:(CGSize)size contentOrientation:(NSInteger)contentOrientation containerOrientation:(NSInteger)containerOrientation hostRequester:(id)requester;
- (void)setDisplayMode:(NSInteger)mode animationFactory:(id)factory completion:(id)completion;
- (void)invalidate;
@end
