#include "../Sources/ZNSPortraitKeyboardGeometry.h"
#include <assert.h>
#include <stdio.h>
#include "PortraitGeometryTests.inc"
int main(void) {
    LayeredGeometryTests();
    unsigned cases=0;
    for (int w=320;w<=500;w+=10) for (int h=640;h<=1000;h+=20)
    for (int k=180;k<=400;k+=10) {
        CGRect screen=CGRectMake(0,0,w,h), keyboard=CGRectMake(0,h-k,w,k);
        ZNSPortraitKeyboardLayout layout;
        int ok=ZNSPortraitKeyboardLayoutMake(keyboard,screen,54,&layout);
        CGFloat top=fmax(54,round(h*0.18));
        assert(ok==(h-k-top>=120));
        if(ok) {
            assert(layout.canvas.width==w && layout.canvas.height==h-top);
            assert(CGRectGetMaxY(layout.frame)==h);
            assert(CGRectGetMinY(layout.frame)==top);
            assert(layout.keyboardInScene.size.height==k);
            assert(layout.inputBottom==h-k-top);
            assert(layout.inputBottom+layout.frame.origin.y==keyboard.origin.y);
            assert(layout.canvas.height-k==layout.inputBottom); // only ONE inset
            assert(CGAffineTransformIsIdentity(ZNSPortraitCanvasTransform()));
            CGPoint left=ZNSPortraitScreenToScene(CGPointMake(0,h-k),layout.frame);
            CGPoint right=ZNSPortraitScreenToScene(CGPointMake(w,h-k),layout.frame);
            assert(left.x==0 && right.x==w && left.y==layout.inputBottom);
            CGRect target; assert(ZNSPortraitKeyboardTarget(keyboard,screen,54,&target));
            assert(CGRectEqualToRect(target,layout.frame));
        }
        cases++;
    }
    CGRect screen=CGRectMake(0,0,390,844), target;
    assert(!ZNSPortraitKeyboardTarget(CGRectMake(0,790,390,54),screen,47,&target));
    assert(!ZNSPortraitKeyboardTarget(CGRectMake(90,400,200,250),screen,47,&target));
    assert(!ZNSPortraitKeyboardTarget(CGRectMake(0,500,390,250),screen,47,&target));
    assert(!ZNSPortraitKeyboardTarget(CGRectMake(0,0,844,200),CGRectMake(0,0,844,390),0,&target));
    assert(!ZNSPortraitKeyboardTarget(CGRectMake(NAN,500,390,344),screen,47,&target));
    assert(!ZNSPortraitKeyboardTarget(CGRectMake(0,500,390,INFINITY),screen,47,&target));
    assert(!ZNSPortraitKeyboardTarget(CGRectMake(0,500,390,344),screen,47,NULL));
    ZNSPortraitKeyboardLayout offset;
    assert(ZNSPortraitKeyboardLayoutMake(CGRectMake(20,520,390,334),CGRectMake(20,10,390,844),47,&offset));
    assert(offset.frame.origin.x==20 && offset.frame.origin.y==162);
    assert(offset.inputBottom+offset.frame.origin.y==520);
    printf("PASS %u native-width canvas, point scale, single avoidance and input mapping cases plus 8 edge cases\n",cases);
}
