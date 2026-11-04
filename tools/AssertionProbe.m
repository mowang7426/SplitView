#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#include <stdio.h>
int main(void) { @autoreleasepool {
    void *framework=dlopen("/System/Library/PrivateFrameworks/AssertionServices.framework/AssertionServices",RTLD_LAZY);
    Class cls=NSClassFromString(@"BKSProcessAssertion");
    if (!framework || !cls) return 1;
    for (NSString *name in @[@"initWithPID:flags:reason:name:withHandler:",@"initWithBundleIdentifier:flags:reason:name:withHandler:",@"valid",@"invalidate"]) {
        Method method=class_getInstanceMethod(cls,NSSelectorFromString(name));
        printf("%s %s\n",name.UTF8String,method?method_getTypeEncoding(method):"MISSING");
    }
} return 0; }
