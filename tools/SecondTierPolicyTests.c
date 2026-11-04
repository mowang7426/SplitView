// Source-only regression cases. Do not compile/run until the user permits it.
#include "../Sources/ZNSSecondTierPolicy.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    for(unsigned deviceLandscape=0;deviceLandscape<2;deviceLandscape++)
    for(unsigned landscape=0;landscape<2;landscape++) {
        for(unsigned right=0;right<2;right++) {
            for(int sign=-1;sign<=1;sign+=2) {
                CGPoint d=CGPointMake(sign*140,10),v=CGPointMake(sign*1000,30);
                ZNSSecondTierAction expected=ZNSSecondTierActionReturnFirst;
                assert(ZNSSecondTierActionForGesture(landscape,deviceLandscape,right,d,v,0.25)==expected);
                assert(ZNSSecondTierActionForGesture(landscape,deviceLandscape,right,d,v,0.56)==ZNSSecondTierActionNone);
                assert(ZNSSecondTierActionForGesture(landscape,deviceLandscape,right,CGPointMake(sign*59,0),v,0.25)==ZNSSecondTierActionNone);
                assert(ZNSSecondTierActionForGesture(landscape,deviceLandscape,right,d,CGPointMake(sign*549,0),0.25)==ZNSSecondTierActionNone);
                assert(ZNSSecondTierActionForGesture(landscape,deviceLandscape,right,d,CGPointMake(-sign*1000,0),0.25)==ZNSSecondTierActionNone);
            }
            assert(ZNSSecondTierActionForGesture(landscape,deviceLandscape,right,CGPointMake(0,-140),CGPointMake(0,-1000),0.25)==ZNSSecondTierActionClose);
            assert(ZNSSecondTierActionForGesture(landscape,deviceLandscape,right,CGPointMake(0,140),CGPointMake(0,1000),0.25)==(landscape?ZNSSecondTierActionAdvance:ZNSSecondTierActionNone));
            assert(ZNSSecondTierActionForGesture(landscape,deviceLandscape,right,CGPointMake(10,-120),CGPointMake(0,-900),0.4)==ZNSSecondTierActionClose);
            assert(ZNSSecondTierActionForGesture(landscape,deviceLandscape,right,CGPointMake(0,65),CGPointMake(0,600),0.5)==
                   ((landscape && deviceLandscape)?ZNSSecondTierActionAdvance:ZNSSecondTierActionNone));
            for(int dx=-240;dx<=240;dx+=20) for(int dy=-240;dy<=240;dy+=20)
                assert(ZNSSecondTierActionForGesture(landscape,deviceLandscape,right,CGPointMake(dx,dy),CGPointMake(dx,dy),1)==ZNSSecondTierActionNone);
        }
    }
    puts("PASS: second-tier flick directions, mirrored sides, portrait cap, threshold edges and ordinary drags.");
    return 0;
}
