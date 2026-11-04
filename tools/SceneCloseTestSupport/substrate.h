#pragma once
#import <objc/runtime.h>
#include <stdlib.h>
// Test-only stub. Teardown tests must never attempt to install a hook.
static inline void MSHookMessageEx(Class cls,SEL sel,IMP replacement,IMP *original) {
    (void)cls; (void)sel; (void)replacement; (void)original; abort();
}
