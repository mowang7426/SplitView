// Isolated tests of the production corner hit-view methods; no device UI.
#import <UIKit/UIKit.h>
#import "../Sources/ZNSGeometry.h"
#include <assert.h>
#include <stdio.h>

@interface ZNSCornerTestView : NSObject
@property(nonatomic) CGRect frame;
@property(nonatomic) BOOL hidden, userInteractionEnabled, inputEnabled, inputOpaque;
@property(nonatomic,strong) NSMutableArray *children;
@property(nonatomic,readonly) id layer;
- (instancetype)initWithFrame:(CGRect)frame;
- (void)addSubview:(id)view;
@end
@implementation ZNSCornerTestView
- (instancetype)initWithFrame:(CGRect)frame {
    if(!(self=[super init])) return nil;
    _frame=frame; _userInteractionEnabled=YES; _children=[NSMutableArray new];
    return self;
}
- (id)layer { return self; }
- (void)addSubview:(id)view { [self.children addObject:view]; }
@end
static BOOL ZNSSetLayerInputOpaque(ZNSCornerTestView *layer,BOOL enabled) { layer.inputOpaque=enabled; return YES; }
static BOOL ZNSSetLayerInputEnabled(ZNSCornerTestView *layer,BOOL enabled) { layer.inputEnabled=enabled; return YES; }
#define UIView ZNSCornerTestView
#include "CornerHitTests.generated.inc"
#undef UIView

static CGPoint localPoint(CGPoint p,CGRect frame) { return CGPointMake(p.x-frame.origin.x,p.y-frame.origin.y); }
static void checkFrame(CGRect frame,CGRect screen,unsigned expanded,unsigned *count) {
    CGRect bounds=(CGRect){CGPointZero,frame.size};
    CGRect localScreen=CGRectOffset(screen,-frame.origin.x,-frame.origin.y);
    CGRect body=ZNSMainBody(bounds),content=ZNSMainContent(bounds);
    for(unsigned corner=0;corner<4;corner++) {
        CGRect horizontal=ZNSMainCornerHandle(bounds,localScreen,corner,expanded);
        CGRect side=ZNSMainCornerSideHandle(bounds,localScreen,corner);
        assert(!CGRectIsEmpty(side) && !CGRectIsNull(side));
        assert(CGRectContainsRect(localScreen,side));
        assert(!CGRectIntersectsRect(side,content));
        assert(!CGRectIntersectsRect(side,ZNSMainToolsFrame(bounds,expanded)));
        for(unsigned bottom=0;bottom<2;bottom++)
            assert(!CGRectIntersectsRect(side,ZNSMainBarHitFrame(bounds,localScreen,expanded,bottom)));
        ZNSCornerHitView *view=[[ZNSCornerHitView alloc] initWithFrame:CGRectZero];
        [view setHorizontalRegion:horizontal sideRegion:side enabled:YES];
        CGPoint center=ZNSCornerCenter(body,corner);
        CGPoint sidePoint=CGPointMake(center.x+((corner&1)?-1:1),center.y+((corner&2)?-16:16));
        assert([view pointInside:localPoint(center,view.frame) withEvent:nil]);
        assert([view pointInside:localPoint(sidePoint,view.frame) withEvent:nil]);
        // A hit in the old rectangular enclosing box must never take App input.
        CGPoint appPoint=CGPointMake(center.x+((corner&1)?-10:10),center.y+((corner&2)?-12:12));
        assert(CGRectContainsPoint(content,appPoint));
        assert(![view pointInside:localPoint(appPoint,view.frame) withEvent:nil]);
        for(ZNSCornerTestView *strip in view.hitStrips) assert(strip.inputOpaque && strip.inputEnabled);
        // Both landscape directions, portrait and upside-down basis: round-trip
        // the same visual/control point, not UIScreen's portrait-sized bounds.
        for(unsigned turn=0;turn<4;turn++) {
            CGAffineTransform transform=CGAffineTransformMakeRotation(turn*M_PI_2);
            transform.tx=113; transform.ty=71;
            CGPoint rootPoint=CGPointMake(sidePoint.x+frame.origin.x,sidePoint.y+frame.origin.y);
            CGPoint displayPoint=CGPointApplyAffineTransform(rootPoint,transform);
            CGPoint restored=CGPointApplyAffineTransform(displayPoint,CGAffineTransformInvert(transform));
            restored=localPoint(restored,frame);
            assert(fabs(restored.x-sidePoint.x)<1e-7 && fabs(restored.y-sidePoint.y)<1e-7);
            assert([view pointInside:localPoint(restored,view.frame) withEvent:nil]);
            (*count)++;
        }
        // Clearing chrome for thumbnail/icon states removes both rendering-input
        // strips and UIKit hits; restoration reinstates only those exact strips.
        for(unsigned state=0;state<2;state++) {
            [view setHorizontalRegion:CGRectZero sideRegion:CGRectZero enabled:NO];
            assert(view.hidden && !view.userInteractionEnabled && CGRectEqualToRect(view.frame,CGRectZero));
            assert(![view pointInside:CGPointZero withEvent:nil]);
            for(ZNSCornerTestView *strip in view.hitStrips)
                assert(strip.hidden && !strip.inputEnabled && !strip.userInteractionEnabled && CGRectEqualToRect(strip.frame,CGRectZero));
            [view setHorizontalRegion:horizontal sideRegion:side enabled:YES];
            assert([view pointInside:localPoint(sidePoint,view.frame) withEvent:nil]);
        }
    }
}
int main(void) { @autoreleasepool {
    CGRect screens[]={CGRectMake(0,0,428,926),CGRectMake(0,0,926,428),CGRectMake(0,0,667,375)};
    unsigned count=0;
    for(unsigned s=0;s<3;s++) for(unsigned expanded=0;expanded<2;expanded++) {
        CGRect screen=screens[s];
        for(unsigned landscape=0;landscape<2;landscape++) {
            CGRect initial=ZNSDefaultMainWindow(screen,CGSizeMake(428,926),landscape);
            checkFrame(initial,screen,expanded,&count);
            // Same-sized windows moved to opposite edges must reclip both strips.
            initial.origin=screen.origin; checkFrame(initial,screen,expanded,&count);
            initial.origin=CGPointMake(CGRectGetMaxX(screen)-initial.size.width,CGRectGetMaxY(screen)-initial.size.height);
            checkFrame(initial,screen,expanded,&count);
        }
        checkFrame(CGRectMake(10,60,94,180),screen,expanded,&count);
    }
    printf("PASS: %u rotated corner-coordinate cases; production L-hit regions, App/tool/bar exclusion, edge clipping, parking release and restoration. No real gestures or render-server routing exercised.\n",count);
} return 0; }
