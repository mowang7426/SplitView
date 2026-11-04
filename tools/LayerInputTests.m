#import <Foundation/Foundation.h>
#import "../Sources/ZNSLayerInput.h"
#include <stdio.h>
int main(void) {
    @autoreleasepool {
        CALayer *layer=[CALayer layer];
        BOOL input=NO,opaque=NO;
        if (!ZNSReadLayerHitFlag(layer,NSSelectorFromString(@"allowsHitTesting"),&input) ||
            !ZNSReadLayerHitFlag(layer,NSSelectorFromString(@"hitTestsAsOpaque"),&opaque)) {
            fprintf(stderr,"FAIL: layer input flags unavailable\n"); return 1;
        }
        for (int i=0;i<100;i++) {
            if (!ZNSSetLayerInputEnabled(layer,NO) || !ZNSSetLayerInputOpaque(layer,YES) ||
                !ZNSSetLayerInputEnabled(layer,YES) || !ZNSSetLayerInputOpaque(layer,NO)) {
                fprintf(stderr,"FAIL: layer input flag roundtrip\n"); return 2;
            }
        }
        if (!ZNSSetLayerInputEnabled(layer,input) || !ZNSSetLayerInputOpaque(layer,opaque)) return 3;
        puts("PASS: device CALayer input flags support 100 roundtrips and restoration. This is not a cross-app touch test.");
    }
    return 0;
}
