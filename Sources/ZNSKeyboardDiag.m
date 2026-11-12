#import "ZNSKeyboardDiag.h"
#import <CoreFoundation/CoreFoundation.h>
#import <unistd.h>
#import <math.h>

static os_log_t ZNSKeyboardDiagLog(void) {
    static os_log_t log; static dispatch_once_t once;
    dispatch_once(&once, ^{ log=os_log_create("com.zengniu.splitview", "keyboard-diag"); });
    return log;
}
BOOL ZNSKeyboardDiagEnabled(void) {
    CFPreferencesAppSynchronize(CFSTR("com.zengniu.splitview"));
    id value=CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("KeyboardDiagnosticsEnabled"),CFSTR("com.zengniu.splitview")));
    return value ? ([value respondsToSelector:@selector(boolValue)] && [value boolValue]) :
#if defined(ZNS_KEYBOARD_DIAG_DEFAULT_ON)
        YES;
#else
        NO;
#endif
}
static NSString *ZNSDiagSafe(id value) {
    if ([value isKindOfClass:NSNumber.class]) return [NSString stringWithFormat:@"%@",value];
    if (![value isKindOfClass:NSString.class]) return @"invalid";
    NSString *s=(NSString *)value;
    if (s.length>32) return @"invalid";
    NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.:"];
    if ([s rangeOfCharacterFromSet:allowed.invertedSet].location!=NSNotFound) return @"invalid";
    return s.length?s:@"unknown";
}
static BOOL ZNSDiagAllow(void) {
    static NSMutableDictionary *last; static dispatch_once_t once;
    dispatch_once(&once,^{last=[NSMutableDictionary new];});
    NSString *key=[NSString stringWithFormat:@"%d",getpid()]; NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
    NSNumber *previous=last[key];
    if (previous && now-previous.doubleValue<0.12) return NO;
    last[key]=@(now); return YES;
}
static void ZNSKeyboardDiagWrite(NSString *event, NSUInteger generation, NSUInteger serial, NSDictionary *fields) {
    if (!ZNSKeyboardDiagEnabled() || !ZNSDiagAllow()) return;
    NSMutableArray *parts=[NSMutableArray arrayWithObjects:@"ZNSKeyboardDiag",event,
      [NSString stringWithFormat:@"pid=%d",getpid()], [NSString stringWithFormat:@"gen=%lu",(unsigned long)generation],
      [NSString stringWithFormat:@"serial=%lu",(unsigned long)serial], nil];
    for (NSString *key in @[@"visibleProof",@"ownerMatch",@"focusMatch",@"sceneCount",@"activeSceneCount",@"sceneMatch",@"windowMatch",@"canvasMatch",@"frameInScreen",@"placementVisible",@"expanded",@"restoreAuth",@"restoreReason",@"pollAttempt",@"ack",@"sceneApplied",@"handoff",@"layoutEpoch",@"swipe",@"animation"]) {
        id value=fields[key]; if (value) [parts addObject:[NSString stringWithFormat:@"%@=%@",key,ZNSDiagSafe(value)]];
    }
    os_log(ZNSKeyboardDiagLog(), "%{public}s", [parts componentsJoinedByString:@" "].UTF8String);
}
void ZNSKeyboardDiagEmit(ZNSKeyboardDiagPhase phase, NSUInteger generation, NSUInteger serial, NSDictionary *fields) {
    static NSString *names[]={@"",@"WillShow",@"DidShow",@"WillChange",@"DidChange",@"WillHide",@"DidHide"};
    if (phase>=1 && phase<=6) ZNSKeyboardDiagWrite(names[phase],generation,serial,fields?:@{});
}
void ZNSKeyboardDiagDecision(NSString *decision, NSUInteger generation, NSDictionary *fields) {
    ZNSKeyboardDiagWrite([NSString stringWithFormat:@"Decision_%@",ZNSDiagSafe(decision)],generation,0,fields?:@{});
}
