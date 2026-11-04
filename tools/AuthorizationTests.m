// Source-only regression cases for alpha33. Not compiled or run yet.
// Never writes preferences, changes authorization, or opens a screen.
#ifndef APELIN_PACKAGE_ID
#define APELIN_PACKAGE_ID "com.zengniu.splitview"
#endif
#import "../Sources/ZNSAuthorization.h"
#include <assert.h>
#include <stdio.h>

int main(void) { @autoreleasepool {
    unsigned cases=0;
    for(NSInteger hour=0;hour<24;hour++) for(NSInteger minute=0;minute<60;minute++) {
        NSInteger expectedMinute=minute+10;
        NSInteger expectedHour=hour;
        if(expectedMinute>=60) { expectedMinute-=60; expectedHour=(hour+1)%24; }
        NSString *code=[NSString stringWithFormat:@"%02ld%02ld",(long)expectedHour,(long)expectedMinute];
        assert(ZNSAuthorizationMatchesTime(code,hour,minute));
        NSString *wrong=[NSString stringWithFormat:@"%02ld%02ld",(long)hour,(long)minute];
        assert(!ZNSAuthorizationMatchesTime(wrong,hour,minute));
        cases++;
    }
    assert(ZNSAuthorizationMatchesTime(@"0005",23,55));
    assert(ZNSAuthorizationMatchesTime(@"0000",23,50));
    assert(ZNSAuthorizationMatchesTime(@"0109",0,59));
    assert(!ZNSAuthorizationMatchesTime(nil,0,0));
    for(NSString *bad in @[@"",@"10",@"00100",@" 0010",@"0010\n",@"００１０",@"٠٠١٠",@"00:10",@"+010",@"00a0"]) {
        assert(!ZNSAuthorizationMatchesTime(bad,0,0));
    }
    assert(!ZNSAuthorizationMatchesTime(@"0010",-1,0));
    assert(!ZNSAuthorizationMatchesTime(@"0010",24,0));
    assert(!ZNSAuthorizationMatchesTime(@"0010",0,-1));
    assert(!ZNSAuthorizationMatchesTime(@"0010",0,60));
    assert(ZNSAuthorizationValueIsGranted(@YES));
    assert(!ZNSAuthorizationValueIsGranted(@NO));
    assert(!ZNSAuthorizationValueIsGranted(nil));
    for(id value in @[@1,@0,@"YES",@"true",@"1",@[],@{},NSNull.null]) {
        assert(!ZNSAuthorizationValueIsGranted(value));
    }
    printf("PASS: %u local clock minutes, midnight rollover, invalid inputs and strict Boolean grant values; no persistence/UI/runtime gate tested.\n",cases);
    return 0;
} }
