#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#include <stdio.h>
int main(void) { @autoreleasepool {
    void *library=dlopen("/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore",RTLD_LAZY);
    if (!library) { fprintf(stderr,"Framework load failed: %s\n",dlerror()); return 1; }
    for (NSString *name in @[@"UIMutableApplicationSceneSettings",@"UIApplicationSceneSettings",@"FBSMutableSceneSettings",@"UIApplicationSceneClientSettings"]) {
        Class base=NSClassFromString(name);
        printf("CLASS %s %s\n",name.UTF8String,base?"present":"missing");
        for (Class cls=base;cls && cls!=NSObject.class;cls=class_getSuperclass(cls)) {
            if ([NSStringFromClass(cls) isEqualToString:@"UIView"]) break;
            unsigned count=0; Method *methods=class_copyMethodList(cls,&count);
            for (unsigned i=0;i<count;i++) {
                NSString *selector=NSStringFromSelector(method_getName(methods[i]));
                if ([selector localizedCaseInsensitiveContainsString:@"orient"] || [selector localizedCaseInsensitiveContainsString:@"reference"] || [selector localizedCaseInsensitiveContainsString:@"transform"] || [selector localizedCaseInsensitiveContainsString:@"device"]) {
                    printf("%s %s %s\n",class_getName(cls),selector.UTF8String,method_getTypeEncoding(methods[i]));
                }
            }
            free(methods);
        }
    }
} return 0; }
