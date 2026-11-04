#import "ZNSProcessKeepAlive.h"
#import "ZNSPrivate.h"
#import <dlfcn.h>
#import <objc/runtime.h>

// AssertionServices on this iOS uses uint32_t flags/reason (runtime checked).
// Values documented by theos/headers AssertionServices/BKSProcessAssertion.h:
// PreventSuspend=1, PreventThrottleDownCPU=2, AllowIdleSleep=4, BackgroundUI=7.
@interface NSObject (ZNSAssertionAPI)
- (instancetype)initWithBundleIdentifier:(NSString *)identifier flags:(uint32_t)flags reason:(uint32_t)reason name:(NSString *)name withHandler:(void (^)(BOOL))handler;
@end
@interface ZNSProcessKeepAlive ()
@property(nonatomic,strong) id assertion;
@end
@implementation ZNSProcessKeepAlive
- (instancetype)initWithBundleIdentifier:(NSString *)identifier {
    if (!(self=[super init])) return nil;
    static void *framework;
    static dispatch_once_t once;
    dispatch_once(&once,^{ framework=dlopen("/System/Library/PrivateFrameworks/AssertionServices.framework/AssertionServices",RTLD_LAZY); });
    Class cls=NSClassFromString(@"BKSProcessAssertion");
    SEL selector=@selector(initWithBundleIdentifier:flags:reason:name:withHandler:);
    Method method=class_getInstanceMethod(cls,selector);
    NSMethodSignature *sig=method?[NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)]:nil;
    if (!framework || sig.numberOfArguments!=7 || strcmp([sig getArgumentTypeAtIndex:3],@encode(uint32_t)) || strcmp([sig getArgumentTypeAtIndex:4],@encode(uint32_t))) {
        os_log_error(ZNSLog(),"process keepalive API unavailable"); return self;
    }
    @try {
        _assertion=[[cls alloc] initWithBundleIdentifier:identifier flags:7 reason:7 name:@"ZengNiu visible hosted app" withHandler:^(BOOL acquired){
            os_log(ZNSLog(),"process keepalive acquisition granted=%d",acquired);
        }];
        os_log(ZNSLog(),"process keepalive requested object=%d",_assertion!=nil);
    } @catch (NSException *exception) {
        os_log_error(ZNSLog(),"process keepalive rejected: %{public}@",exception.name);
    }
    return self;
}
- (void)invalidate {
    id assertion=_assertion; _assertion=nil;
    @try { if ([assertion respondsToSelector:@selector(invalidate)]) [assertion invalidate]; }
    @catch (NSException *exception) { os_log_error(ZNSLog(),"process keepalive release failed: %{public}@",exception.name); }
    if (assertion) os_log(ZNSLog(),"process keepalive released");
}
- (void)dealloc { [self invalidate]; }
@end
