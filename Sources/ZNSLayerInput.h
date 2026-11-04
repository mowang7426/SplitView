#pragma once
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>

// Render-server hit testing is independent of UIView's local hitTest path.
// Only operate on layers owned by our floating UI; never global CA defaults.
static inline BOOL ZNSReadLayerHitFlag(CALayer *layer, SEL getter, BOOL *value) {
    if (!layer || ![layer respondsToSelector:getter]) return NO;
    @try {
        *value=((BOOL(*)(id,SEL))objc_msgSend)(layer,getter);
        return YES;
    } @catch (__unused NSException *exception) { return NO; }
}
static inline BOOL ZNSWriteLayerHitFlag(CALayer *layer, SEL setter, SEL getter, BOOL value) {
    if (!layer || ![layer respondsToSelector:setter]) return NO;
    @try {
        ((void(*)(id,SEL,BOOL))objc_msgSend)(layer,setter,value);
        BOOL actual=NO;
        return ZNSReadLayerHitFlag(layer,getter,&actual) && actual==value;
    } @catch (__unused NSException *exception) { return NO; }
}
static inline BOOL ZNSSetLayerInputEnabled(CALayer *layer, BOOL enabled) {
    return ZNSWriteLayerHitFlag(layer,NSSelectorFromString(@"setAllowsHitTesting:"),NSSelectorFromString(@"allowsHitTesting"),enabled);
}
static inline BOOL ZNSSetLayerInputOpaque(CALayer *layer, BOOL opaque) {
    return ZNSWriteLayerHitFlag(layer,NSSelectorFromString(@"setHitTestsAsOpaque:"),NSSelectorFromString(@"hitTestsAsOpaque"),opaque);
}
