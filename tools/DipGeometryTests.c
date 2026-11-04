// Source-only cases: do not compile or run without the user's permission.
#include "../Sources/ZNSDipGeometry.h"
#include <assert.h>
int main(void) {
    CGRect screen=CGRectMake(0,0,428,926),safe=CGRectMake(0,54,428,872);
    CGRect source=CGRectMake(50,150,320,650);
    CGRect below=source; below.origin.y=926-source.size.height+source.size.height*0.29;
    assert(!ZNSDipShouldSettle(below,screen));
    below.origin.y+=source.size.height*0.02;
    assert(ZNSDipShouldSettle(below,screen));
    CGRect over=source; over.origin.y=1500;
    CGRect dragged=ZNSDipDraggedFrame(over,safe,screen);
    assert(dragged.origin.y<=926-44);
    assert(dragged.origin.y>926-source.size.height*0.30);
    assert(ZNSDipShouldSettle(dragged,screen));
    for(unsigned count=1;count<=3;count++) for(unsigned index=0;index<count;index++) {
        CGRect card=ZNSDipCardFrame(source,safe,screen,index,count);
        assert(fabs((926-card.origin.y)/card.size.height-0.30)<1e-7);
        assert(fabs((card.size.width-14)/(card.size.height-54)-(source.size.width-14)/(source.size.height-54))<1e-7);
        assert(ZNSDipReservedTop(card)<card.origin.y);
        assert(card.origin.x>=0 && CGRectGetMaxX(card)<=428);
        // Positive rotation in UIKit's downward Y coordinates raises the left edge.
        assert(ZNSDipAngle()>0);
    }
    CGRect outside=source; outside.origin.x=-300; outside.origin.y=-300;
    dragged=ZNSDipDraggedFrame(outside,safe,screen);
    assert(dragged.origin.x==0 && dragged.origin.y==54);
    return 0;
}
