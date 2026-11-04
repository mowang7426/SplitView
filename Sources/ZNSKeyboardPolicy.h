#import <UIKit/UIKit.h>

// Missing preference follows the new screen-bottom default. Explicit inner
// remains an opt-out; malformed values stay conservative and retain native UI.
static inline BOOL ZNSKeyboardExternalValue(id value) {
    return !value || ([value isKindOfClass:NSString.class] && [value isEqualToString:@"outer"]);
}
static inline BOOL ZNSKeyboardMoveValue(id value) {
    return [value isKindOfClass:NSNumber.class] && [value boolValue];
}
static inline BOOL ZNSKeyboardExternalForDirection(BOOL landscape, BOOL portraitExternal, BOOL landscapeExternal) {
    return landscape ? landscapeExternal : portraitExternal;
}
static inline BOOL ZNSKeyboardCanMove(BOOL landscape, BOOL external, BOOL enabled) {
    return landscape && external && enabled;
}
