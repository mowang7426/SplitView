#pragma once
#import <Foundation/Foundation.h>

// Project-owned policy, adapted from the supplied time-code principle.
// This is an offline convenience gate, NOT a tamper-resistant licence system.
#define ZNSAuthorizationKey CFSTR("AuthorizationGranted")

static inline BOOL ZNSAuthorizationValueIsGranted(id value) {
    // Do not accept strings, numeric 1, or malformed legacy preferences.
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID() &&
        CFBooleanGetValue((__bridge CFBooleanRef)value);
}

static inline NSArray<NSString *> *ZNSFeatureSwitchKeys(void) {
    return @[@"Enabled",@"FollowDeviceRotation",@"DipEnabled",@"StatusBarLeftHold",@"StatusBarRightHold",
             @"KeyboardLandscapeMovable",@"SwitcherGesturesEnabled",@"NotificationFloating",@"DanmuEnabled",@"DesktopRotationEnabled",@"NoLockAfterRespring"];
}
// Save OFF for these legacy switches. DynamicDipEnabled is deliberately NOT
// listed: authorization gates it at runtime without overwriting the user's
// choice. Its missing-value default is YES, including the first grant; reset
// and regrant preserve an explicit YES or NO.
static inline BOOL ZNSDisableFeatureSwitches(void) {
    BOOL changed=NO;
    for(NSString *key in ZNSFeatureSwitchKeys()) {
        id value=CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key,CFSTR(APELIN_PACKAGE_ID)));
        if(![value isKindOfClass:NSNumber.class] || [value boolValue]) {
            CFPreferencesSetAppValue((__bridge CFStringRef)key,kCFBooleanFalse,CFSTR(APELIN_PACKAGE_ID));
            changed=YES;
        }
    }
    id notificationMode=CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("NotificationOpenMode"),CFSTR(APELIN_PACKAGE_ID)));
    if(![notificationMode isKindOfClass:NSString.class] || ![notificationMode isEqualToString:@"off"]) {
        CFPreferencesSetAppValue(CFSTR("NotificationOpenMode"),CFSTR("off"),CFSTR(APELIN_PACKAGE_ID));
        changed=YES;
    }
    if(changed) CFPreferencesAppSynchronize(CFSTR(APELIN_PACKAGE_ID));
    return changed;
}

static inline BOOL ZNSReadAuthorization(BOOL synchronize) {
    if(synchronize && !CFPreferencesAppSynchronize(CFSTR(APELIN_PACKAGE_ID))) return NO;
    id value=CFBridgingRelease(CFPreferencesCopyAppValue(ZNSAuthorizationKey,CFSTR(APELIN_PACKAGE_ID)));
    return ZNSAuthorizationValueIsGranted(value);
}

static inline BOOL ZNSAuthorizationMatchesTime(NSString *input,NSInteger hour,NSInteger minute) {
    if(![input isKindOfClass:NSString.class] || input.length!=4 || hour<0 || hour>23 || minute<0 || minute>59) return NO;
    NSInteger entered=0;
    for(NSUInteger index=0;index<4;index++) {
        unichar digit=[input characterAtIndex:index];
        if(digit<'0' || digit>'9') return NO;
        entered=entered*10+digit-'0';
    }
    NSInteger clockMinute=(hour*60+minute+10)%(24*60);
    return entered==(clockMinute/60)*100+clockMinute%60;
}

static inline BOOL ZNSAuthorizationMatchesNow(NSString *input) {
    // Capture exactly once on confirmation, independent of 12/24h UI format.
    NSCalendar *calendar=[[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone=NSTimeZone.localTimeZone;
    NSDateComponents *parts=[calendar components:NSCalendarUnitHour|NSCalendarUnitMinute fromDate:NSDate.date];
    return ZNSAuthorizationMatchesTime(input,parts.hour,parts.minute);
}
