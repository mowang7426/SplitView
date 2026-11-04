// Exercise extracted production methods with Foundation stand-ins, no screen.
#import <UIKit/UIKit.h>
#import "../Sources/ZNSGeometry.h"
#include <assert.h>
#include <stdio.h>
@interface ZNSToolTestView : NSObject
@property(nonatomic) CGRect frame;
@property(nonatomic,readonly) CGRect bounds;
@property(nonatomic,weak) ZNSToolTestView *superview;
@property(nonatomic) BOOL userInteractionEnabled;
- (void)setNeedsLayout;
@end
@implementation ZNSToolTestView
- (CGRect)bounds { return (CGRect){CGPointZero,self.frame.size}; }
- (void)setNeedsLayout {}
@end
@interface ZNSToolTestControl : ZNSToolTestView @end
@implementation ZNSToolTestControl @end
@interface ZNSToolTestTouch : NSObject
@property(nonatomic,strong) ZNSToolTestView *view;
@end
@implementation ZNSToolTestTouch @end
@interface ZNSToolTestGesture : NSObject
@property(nonatomic,strong) ZNSToolTestView *view;
@property(nonatomic) UIGestureRecognizerState state;
@end
@implementation ZNSToolTestGesture @end
@interface ZNSToolTestPan : ZNSToolTestGesture
@property(nonatomic) CGPoint delta;
- (CGPoint)translationInView:(id)view;
@end
@implementation ZNSToolTestPan
- (CGPoint)translationInView:(id)view { (void)view; return self.delta; }
@end
@interface ZNSToolTestWindow : ZNSToolTestView
@property(nonatomic,strong) ZNSToolTestView *toolbar, *tools;
@property(nonatomic,strong) ZNSToolTestGesture *activeManipulation;
@property(nonatomic) CGRect gestureFrame;
@property(nonatomic) BOOL closing;
@property(nonatomic) NSUInteger toolsGeneration, idleRestarts;
- (void)expandTools;
- (void)drag:(ZNSToolTestPan *)gesture;
- (BOOL)gestureRecognizer:(ZNSToolTestGesture *)gesture shouldReceiveTouch:(ZNSToolTestTouch *)touch;
@end
@implementation ZNSToolTestWindow
- (CGRect)safe { return self.superview.bounds; }
- (void)expandTools { assert(!self.activeManipulation); self.idleRestarts++; self.toolsGeneration++; }
#define UIView ZNSToolTestView
#define UIControl ZNSToolTestControl
#define UITouch ZNSToolTestTouch
#define UIGestureRecognizer ZNSToolTestGesture
#define UIPanGestureRecognizer ZNSToolTestPan
#include "ToolbarGestureTests.generated.inc"
#undef UIView
#undef UIControl
#undef UITouch
#undef UIGestureRecognizer
#undef UIPanGestureRecognizer
@end
int main(void) { @autoreleasepool {
    ZNSToolTestWindow *w=[ZNSToolTestWindow new];
    w.toolbar=[ZNSToolTestView new]; w.tools=[ZNSToolTestView new];
    ZNSToolTestView *screen=[ZNSToolTestView new]; screen.frame=CGRectMake(0,0,428,926); w.superview=screen;
    ZNSToolTestPan *pan=[ZNSToolTestPan new]; pan.view=w.toolbar;
    ZNSToolTestGesture *tap=[ZNSToolTestGesture new]; tap.view=w.toolbar;
    ZNSToolTestControl *button=[ZNSToolTestControl new]; button.superview=w.toolbar;
    ZNSToolTestView *glyph=[ZNSToolTestView new]; glyph.superview=button;
    ZNSToolTestTouch *touch=[ZNSToolTestTouch new];
    for(ZNSToolTestView *v in @[button,glyph]) {
        touch.view=v;
        assert([w gestureRecognizer:pan shouldReceiveTouch:touch]);
        assert(![w gestureRecognizer:tap shouldReceiveTouch:touch]);
    }
    touch.view=w.toolbar;
    assert([w gestureRecognizer:tap shouldReceiveTouch:touch]);
    for(unsigned expanded=0;expanded<2;expanded++) {
        w.tools.userInteractionEnabled=expanded; w.idleRestarts=0;
        CGRect start=CGRectMake(60,150,250,500); w.frame=start;
        NSUInteger before=w.toolsGeneration;
        pan.state=UIGestureRecognizerStateBegan; pan.delta=CGPointZero; [w drag:pan];
        assert(w.activeManipulation==pan && w.toolsGeneration==before+1);
        pan.state=UIGestureRecognizerStateChanged; pan.delta=CGPointMake(20,30); [w drag:pan];
        assert(CGRectEqualToRect(w.frame,CGRectOffset(start,20,30)));
        assert(!w.idleRestarts && w.tools.userInteractionEnabled==expanded);
        pan.state=UIGestureRecognizerStateEnded; [w drag:pan];
        assert(!w.activeManipulation && w.idleRestarts==expanded);
        for(unsigned failed=0;failed<2;failed++) {
            w.frame=start; pan.state=UIGestureRecognizerStateBegan; pan.delta=CGPointZero; [w drag:pan];
            pan.state=failed?UIGestureRecognizerStateFailed:UIGestureRecognizerStateCancelled;
            pan.delta=CGPointMake(1000,-1000); [w drag:pan];
            assert(CGRectEqualToRect(w.frame,start) && !w.activeManipulation);
        }
    }
    puts("PASS: extracted toolbar pan/tap admission, nested button hits, expanded/collapsed drag, idle invalidation/restart, cancellation. No real UI gestures exercised.");
} return 0; }
