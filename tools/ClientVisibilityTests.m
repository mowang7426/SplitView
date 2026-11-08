#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdbool.h>
#include <string.h>
#include <assert.h>
#include "../Sources/ZNSClientLiveVisibility.inc"
static id ZNSLiveInstance;
static bool ZNSBoolValue;
static signed char ZNSCharValue;
@interface ZNSActive : NSObject
+ (id)activeInstance;
@end
@implementation ZNSActive
+ (id)activeInstance { return ZNSLiveInstance; }
@end
@interface ZNSBoolVisibility : NSObject
- (bool)isVisible;
@end
@implementation ZNSBoolVisibility
- (bool)isVisible { return ZNSBoolValue; }
@end
@interface ZNSCharVisibility : NSObject
- (signed char)isOnScreen;
@end
@implementation ZNSCharVisibility
- (signed char)isOnScreen { return ZNSCharValue; }
@end
@interface ZNSConflictingVisibility : ZNSBoolVisibility
- (signed char)isOnScreen;
@end
@implementation ZNSConflictingVisibility
- (signed char)isOnScreen { return ZNSCharValue; }
@end
@interface ZNSWrongVisibility : NSObject
- (int)isVisible;
@end
@implementation ZNSWrongVisibility
- (int)isVisible { assert(!"wrong return ABI must not be invoked"); return 0; }
@end
@interface ZNSWrongActive : NSObject
+ (NSInteger)activeInstance;
@end
@implementation ZNSWrongActive
+ (NSInteger)activeInstance { assert(!"wrong activeInstance ABI must not be invoked"); return 0; }
@end
int main(void) { @autoreleasepool {
    assert(ZNSClientLiveKeyboardVisibility()==0); // no UIKit on host
    assert(ZNSClientLiveKeyboardVisibilityForClass(Nil)==0);
    assert(ZNSClientLiveKeyboardVisibilityForClass(NSObject.class)==0);
    assert(ZNSClientLiveKeyboardVisibilityForClass(ZNSWrongActive.class)==0);
    ZNSLiveInstance=nil; assert(ZNSClientLiveKeyboardVisibilityForClass(ZNSActive.class)==0);
    for (NSUInteger value=0;value<2;value++) {
        ZNSBoolValue=value; ZNSLiveInstance=[ZNSBoolVisibility new];
        assert(ZNSClientLiveKeyboardVisibilityForClass(ZNSActive.class)==(value?1:2));
        ZNSCharValue=(signed char)value; ZNSLiveInstance=[ZNSCharVisibility new];
        assert(ZNSClientLiveKeyboardVisibilityForClass(ZNSActive.class)==(value?1:2));
    }
    ZNSLiveInstance=[ZNSWrongVisibility new];
    assert(ZNSClientLiveKeyboardVisibilityForClass(ZNSActive.class)==0);
    ZNSLiveInstance=[NSObject new]; assert(ZNSClientLiveKeyboardVisibilityForClass(ZNSActive.class)==0);
    ZNSLiveInstance=[ZNSConflictingVisibility new];
    ZNSBoolValue=false; ZNSCharValue=1;
    assert(ZNSClientLiveKeyboardVisibilityForClass(ZNSActive.class)==1);
    ZNSBoolValue=true; ZNSCharValue=0;
    assert(ZNSClientLiveKeyboardVisibilityForClass(ZNSActive.class)==1);
    ZNSBoolValue=false;
    assert(ZNSClientLiveKeyboardVisibilityForClass(ZNSActive.class)==2);
    puts("PASS keyboard14 actual runtime visibility reader: B/c BOOL, missing class/selector/instance unknown, wrong return ABI never called, any visible getter vetoes absence. Fake classes, NOT target UIKit verified.");
} return 0; }
