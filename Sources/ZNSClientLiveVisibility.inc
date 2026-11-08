#include <stdbool.h>
// Runtime-checked, read-only UIKit inspection; also compiled against fake
// Objective-C runtime classes by host tests. Never instantiate a keyboard.
static NSInteger ZNSClientLiveKeyboardVisibilityForClass(Class cls) {
    SEL active=NSSelectorFromString(@"activeInstance");
    Method method=class_getClassMethod(cls,active); char type[128]={0};
    if (method) method_getReturnType(method,type,sizeof(type));
    if (!method || method_getNumberOfArguments(method)!=2 || strcmp(type,"@")) return 0;
    id keyboard=((id(*)(id,SEL))objc_msgSend)(cls,active);
    // A missing active instance is NOT proof of no remote keyboard.
    if (!keyboard) return 0;
    NSInteger evidence=0;
    for (NSString *name in @[@"isVisible",@"isOnScreen"]) {
        SEL selector=NSSelectorFromString(name);
        method=class_getInstanceMethod(object_getClass(keyboard),selector);
        memset(type,0,sizeof(type));
        if (method) method_getReturnType(method,type,sizeof(type));
        if (!method || method_getNumberOfArguments(method)!=2) continue;
        NSInteger sample=0;
        // UIKit BOOL encodings vary by architecture/header generation. Do not
        // call an integer/object getter through a BOOL function pointer.
        if (!strcmp(type,"B")) sample=((bool(*)(id,SEL))objc_msgSend)(keyboard,selector)?1:2;
        else if (!strcmp(type,"c")) sample=((signed char(*)(id,SEL))objc_msgSend)(keyboard,selector)?1:2;
        else continue;
        if (sample==1) return 1; // any live visible evidence vetoes collapse
        evidence=sample;
    }
    return evidence;
}
static NSInteger ZNSClientLiveKeyboardVisibility(void) {
    return ZNSClientLiveKeyboardVisibilityForClass(NSClassFromString(@"UIKeyboardImpl"));
}
