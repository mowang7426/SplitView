#import <Foundation/Foundation.h>
#import <os/log.h>

typedef NS_ENUM(NSInteger, ZNSKeyboardDiagPhase) {
    ZNSKeyboardDiagWillShow=1, ZNSKeyboardDiagDidShow=2,
    ZNSKeyboardDiagWillChange=3, ZNSKeyboardDiagDidChange=4,
    ZNSKeyboardDiagWillHide=5, ZNSKeyboardDiagDidHide=6
};
BOOL ZNSKeyboardDiagEnabled(void);
void ZNSKeyboardDiagEmit(ZNSKeyboardDiagPhase phase, NSUInteger generation, NSUInteger serial,
                         NSDictionary<NSString *, id> *fields);
void ZNSKeyboardDiagDecision(NSString *decision, NSUInteger generation, NSDictionary<NSString *, id> *fields);
NSString *ZNSKeyboardDiagLogPath(void);
NSString *ZNSKeyboardDiagRead(void);
BOOL ZNSKeyboardDiagClear(void);
