#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#include <stdio.h>
// Metadata-only experiment: no singleton creation, UI access or hooks.
// UNSUPPORTED on iOS 16.1.1: dlopen triggers SpringBoardUI +load assertion
// and aborts this helper (exit 134). Kept as a failed experiment; use the
// injected DEBUG-only ZNSSwitcherDiagnostics instead. Do not run routinely.
int main(void) { @autoreleasepool {
    void *handle=dlopen("/System/Library/PrivateFrameworks/SpringBoard.framework/SpringBoard",RTLD_LAZY);
    if (!handle) { fprintf(stderr,"SpringBoard framework: %s\n",dlerror()); return 1; }
    NSArray *names=@[@"SBFluidSwitcherItemContainer",@"SBReusableSnapshotItemContainer",@"SBAppLayout",@"SBDisplayItem",@"SBAppLayoutItem",@"SBMainSwitcherControllerCoordinator",@"SBMainSwitcherViewController",@"SBMainSwitcherController",@"SBApplicationController",@"SBLockScreenManager"];
    for (NSString *name in names) {
        Class cls=NSClassFromString(name);
        printf("CLASS %s super=%s\n",name.UTF8String,cls?class_getName(class_getSuperclass(cls)):"MISSING");
        for (Class c=cls;c && c!=NSObject.class;c=class_getSuperclass(c)) {
            for (int meta=0;meta<2;meta++) {
                unsigned count=0; Method *methods=class_copyMethodList(meta?object_getClass(c):c,&count);
                for (unsigned i=0;i<count;i++) {
                    NSString *s=NSStringFromSelector(method_getName(methods[i]));
                    if ([s localizedCaseInsensitiveContainsString:@"layout"] || [s localizedCaseInsensitiveContainsString:@"switcher"] || [s localizedCaseInsensitiveContainsString:@"progress"] || [s localizedCaseInsensitiveContainsString:@"highlight"] || [s localizedCaseInsensitiveContainsString:@"bundle"] || [s localizedCaseInsensitiveContainsString:@"identifier"] || [s localizedCaseInsensitiveContainsString:@"shared"] || [s localizedCaseInsensitiveContainsString:@"locked"] || [s localizedCaseInsensitiveContainsString:@"displayItems"])
                        printf("%s %c%s %s\n",class_getName(c),meta?'+':'-',s.UTF8String,method_getTypeEncoding(methods[i]));
                }
                free(methods);
            }
            unsigned count=0; Ivar *ivars=class_copyIvarList(c,&count);
            for (unsigned i=0;i<count;i++) printf("IVAR %s %s %s\n",class_getName(c),ivar_getName(ivars[i]),ivar_getTypeEncoding(ivars[i]));
            free(ivars);
        }
    }
} return 0; }
