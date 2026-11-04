// Foundation stand-ins execute extracted production packing/stack methods.
// No UIKit views, scenes, screen access, real gestures or animations are created.
#import <UIKit/UIKit.h>
#import "../Sources/ZNSGeometry.h"
#include <assert.h>
#include <stdio.h>
@interface ZNSTestView : NSObject
@property(nonatomic) CGRect frame;
@property(nonatomic,readonly) CGRect bounds;
@property(nonatomic,readonly) CGPoint center;
@property(nonatomic,weak) ZNSTestView *superview;
@property(nonatomic,strong) NSMutableArray *subviews;
@property(nonatomic,copy) NSString *accessibilityLabel;
- (void)bringSubviewToFront:(id)view;
- (void)setNeedsLayout;
- (void)layoutIfNeeded;
+ (void)animateWithDuration:(NSTimeInterval)duration delay:(NSTimeInterval)delay options:(NSUInteger)options animations:(void (^)(void))animations completion:(void (^)(BOOL))completion;
@end
@implementation ZNSTestView
- (instancetype)init { if((self=[super init])) _subviews=[NSMutableArray new]; return self; }
- (CGRect)bounds { return (CGRect){CGPointZero,self.frame.size}; }
- (CGPoint)center { return CGPointMake(CGRectGetMidX(self.frame),CGRectGetMidY(self.frame)); }
- (void)bringSubviewToFront:(id)view { if([self.subviews containsObject:view]) { [self.subviews removeObject:view]; [self.subviews addObject:view]; } }
- (void)setNeedsLayout {}
- (void)layoutIfNeeded {}
+ (void)animateWithDuration:(NSTimeInterval)d delay:(NSTimeInterval)t options:(NSUInteger)o animations:(void (^)(void))a completion:(void (^)(BOOL))c { (void)d;(void)t;(void)o; a(); if(c)c(YES); }
@end
@interface ZNSTestSession : NSObject
@property(nonatomic) CGSize canvasSize;
@property(nonatomic) BOOL landscape;
@end
@implementation ZNSTestSession
@end
@interface ZNSTestTap : NSObject
@property(nonatomic) UIGestureRecognizerState state;
@end
@implementation ZNSTestTap
@end
@interface ZNSFloatingView : ZNSTestView
@property(nonatomic) BOOL stackCovered;
@property(nonatomic) NSUInteger restoreCalls;
@property(nonatomic,copy) void (^requestFront)(void);
@property(nonatomic,copy) void (^parkedSelected)(void);
@property(nonatomic,strong) id parkedPan;
- (BOOL)applyPendingDeviceOrientation;
- (void)thumbnailTapped:(ZNSTestTap *)gesture;
- (void)restore;
@property(nonatomic) BOOL closing, docked, thumbnail, thumbnailFree, thumbnailRight;
@property(nonatomic) BOOL restoringPosition, rotationOverflow, restoreOnNextArrange, portraitSaved;
@property(nonatomic) BOOL dockedFromThumbnail, wasParkedIcon;
@property(nonatomic) NSUInteger stackOrder, thumbnailTier, portraitTier;
@property(nonatomic) CGRect portraitFrame;
@property(nonatomic) CGSize portraitCanvas;
@property(nonatomic,strong) ZNSTestSession *session;
@property(nonatomic,strong) ZNSTestView *restoreButton;
- (BOOL)isStackParticipant;
- (CGRect)thumbnailFrameInSafe:(CGRect)safe;
- (void)cancelInteraction;
- (void)updateContentInputGate;
@end
@implementation ZNSFloatingView
- (instancetype)init { if((self=[super init])) { _session=[ZNSTestSession new]; _restoreButton=[ZNSTestView new]; } return self; }
- (void)cancelInteraction {}
- (BOOL)applyPendingDeviceOrientation { return NO; }
- (void)updateContentInputGate {}
- (void)restore { self.restoreCalls++; }
#define UITapGestureRecognizer ZNSTestTap
#define ZNS_TEST_FLOATING
#include "WindowStackTests.generated.inc"
#undef ZNS_TEST_FLOATING
#undef UITapGestureRecognizer
@end
@interface ZNSTestController : NSObject
@property(nonatomic,strong) ZNSTestView *view;
@end
@implementation ZNSTestController
@end
@interface ZNSTestManager : NSObject
@property(nonatomic,strong) ZNSTestView *window;
@property(nonatomic,strong) ZNSTestController *controller;
@property(nonatomic,strong) NSMutableArray<ZNSFloatingView *> *windows, *parkedOrder;
@property(nonatomic,strong) ZNSFloatingView *floating;
@property(nonatomic) BOOL arranging;
@property(nonatomic) NSUInteger nextStackOrder, maxParkedApps;
@property(nonatomic) CGRect safe;
- (void)raiseWindow:(ZNSFloatingView *)view;
- (void)updateWindowStack;
- (void)arrangeParked;
- (void)collapseParkedToIcon:(ZNSFloatingView *)view;
@end
@implementation ZNSTestManager
- (CGRect)availableFrame { return self.safe; }
- (void)updateOutsideButton {}
#define UIView ZNSTestView
#define UIAccessibilityIsReduceMotionEnabled() YES
#define ZNS_TEST_MANAGER
#include "WindowStackTests.generated.inc"
#undef ZNS_TEST_MANAGER
#undef UIAccessibilityIsReduceMotionEnabled
#undef UIView
@end
static BOOL sameFrame(CGRect a, CGRect b) {
    return fabs(a.origin.x-b.origin.x)<1e-7 && fabs(a.origin.y-b.origin.y)<1e-7 && fabs(a.size.width-b.size.width)<1e-7 && fabs(a.size.height-b.size.height)<1e-7;
}
static unsigned checks;
#define CHECK(x) do { checks++; assert(x); } while(0)
static ZNSTestManager *manager(CGSize screen) {
    ZNSTestManager *m=[ZNSTestManager new]; m.controller=[ZNSTestController new];
    m.controller.view=[ZNSTestView new]; m.controller.view.frame=(CGRect){CGPointZero,screen};
    m.window=m.controller.view; m.safe=CGRectMake(6,54,screen.width-12,screen.height-80);
    m.windows=[NSMutableArray new]; m.parkedOrder=[NSMutableArray new]; m.maxParkedApps=8;
    return m;
}
static ZNSFloatingView *add(ZNSTestManager *m, unsigned kind) {
    ZNSFloatingView *v=[ZNSFloatingView new]; v.session.canvasSize=CGSizeMake(926,428); v.session.landscape=YES;
    v.thumbnail=kind==1||kind==2; v.thumbnailFree=kind==2; v.thumbnailTier=kind==2?2:0; v.docked=kind==3;
    v.superview=m.controller.view; v.frame=CGRectMake(60,150,250,125);
    if(v.thumbnail) v.frame=[v thumbnailFrameInSafe:m.safe];
    [m.windows addObject:v]; [m.controller.view.subviews addObject:v];
    if(kind) [m.parkedOrder addObject:v]; else m.floating=v;
    return v;
}
static void verifyFixedClear(ZNSTestManager *m) {
    NSMutableArray *fixed=[NSMutableArray new];
    for(ZNSFloatingView *v in m.parkedOrder) if(!v.closing && !(v.thumbnail&&v.thumbnailFree)) [fixed addObject:v];
    for(NSUInteger i=0;i<fixed.count;i++) {
        ZNSFloatingView *a=fixed[i]; CHECK(CGRectContainsRect(m.window.bounds,a.frame));
        for(NSUInteger j=0;j<i;j++) { ZNSFloatingView *b=fixed[j]; CHECK(!CGRectIntersectsRect(a.frame,b.frame)); }
    }
}
int main(void) { @autoreleasepool {
    // Foundation parses the shipping resources without opening Settings.
    for(NSString *path in @[@"Preferences/Info.plist",@"Preferences/Resources/Root.plist"]) {
        NSData *data=[NSData dataWithContentsOfFile:path]; NSError *error=nil;
        id plist=data?[NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:&error]:nil;
        CHECK([plist isKindOfClass:NSDictionary.class] && !error);
    }
    CGSize screens[]={ {428,926},{926,428},{834,1194},{1194,834} };
    for(unsigned s=0;s<4;s++) {
        ZNSTestManager *m=manager(screens[s]);
        ZNSFloatingView *main=add(m,0), *low=add(m,1), *free=add(m,2), *icon=add(m,3), *free2=add(m,2);
        free.frame=ZNSConstrainIcon(CGRectMake(0,54,free.frame.size.width,free.frame.size.height),m.window.bounds);
        free2.frame=free.frame;
        CGRect before=free.frame;
        [m raiseWindow:main]; [m raiseWindow:free];
        CHECK(m.controller.view.subviews.lastObject==free);
        CHECK(main.stackCovered && !free.stackCovered && !low.stackCovered && !icon.stackCovered);
        if(screens[s].width<screens[s].height) {
            CHECK(fabs(free.frame.size.width-screens[s].width)<1e-7);
            CHECK(fabs(free.frame.origin.x)<1e-7);
        }
        ZNSTestTap *tap=[ZNSTestTap new]; tap.state=UIGestureRecognizerStateRecognized;
        __weak ZNSTestManager *weakManager=m;
        __weak ZNSFloatingView *weakFree=free;
        free.requestFront=^{ [weakManager raiseWindow:weakFree]; };
        [m raiseWindow:main]; CHECK(!main.stackCovered);
        [free thumbnailTapped:tap];
        CHECK(m.controller.view.subviews.lastObject==free && main.stackCovered);
        [free thumbnailTapped:tap]; // Repeated selection must never restore.
        CHECK(free.restoreCalls==0 && free.thumbnail && free.thumbnailFree && m.floating==main);
        CHECK(sameFrame(free.frame,before));
        // A moved second tier selects on its first rear tap, restores on the next.
        free.thumbnailTier=1;
        [m raiseWindow:main]; CHECK(free.stackCovered);
        [free thumbnailTapped:tap]; CHECK(free.restoreCalls==0 && !free.stackCovered);
        [free thumbnailTapped:tap]; CHECK(free.restoreCalls==1);
        free.restoreCalls=0; free.thumbnailTier=2;
        [low thumbnailTapped:tap]; CHECK(low.restoreCalls==1);
        tap.state=UIGestureRecognizerStateCancelled;
        [low thumbnailTapped:tap]; CHECK(low.restoreCalls==1);
        [m arrangeParked];
        CHECK(m.controller.view.subviews.lastObject==free);
        CHECK(sameFrame(free.frame,before));
        CHECK(CGRectIntersectsRect(free.frame,low.frame));
        CHECK(CGRectIntersectsRect(free.frame,free2.frame));
        CHECK(CGRectIntersectsRect(free.frame,icon.frame));
        CHECK(free.thumbnail && free.thumbnailFree);
        verifyFixedClear(m);
        [m raiseWindow:main]; [m arrangeParked]; CHECK(m.controller.view.subviews.lastObject==main);
        [m raiseWindow:free2]; [m arrangeParked]; CHECK(m.controller.view.subviews.lastObject==free2);
        [m raiseWindow:icon]; CHECK(m.controller.view.subviews.lastObject==free2);
        [m raiseWindow:low]; CHECK(m.controller.view.subviews.lastObject==free2);
        free2.closing=YES; [m raiseWindow:main]; [m raiseWindow:free2]; CHECK(m.controller.view.subviews.lastObject==main);
        // Rotation bounds clamp, retaining free-tier identity and stack order.
        m.controller.view.frame=CGRectMake(0,0,screens[s].height,screens[s].width);
        m.safe=CGRectMake(6,54,screens[s].height-12,screens[s].width-80);
        [m arrangeParked]; CHECK(CGRectContainsRect(m.window.bounds,free.frame)); CHECK(free.thumbnailFree && free.thumbnail);
        CHECK(m.controller.view.subviews.lastObject==main);
        // Return to the first tier re-enters fixed packing.
        free.thumbnailFree=NO; free.thumbnailTier=0; [m arrangeParked]; verifyFixedClear(m);
        // A third-tier oldest item still counts toward the configured cap.
        ZNSTestManager *cap=manager(screens[s]); ZNSFloatingView *oldest=add(cap,2);
        add(cap,2); add(cap,2); add(cap,2); cap.maxParkedApps=3; [cap arrangeParked];
        CHECK(oldest.docked && !oldest.thumbnail);
        unsigned live=0; for(ZNSFloatingView *v in cap.windows) if(v.thumbnail) live++; CHECK(live==3);
        // Stress icon columns/fallback; free overlays must survive every plan.
        for(unsigned count=1;count<=80;count++) {
            ZNSTestManager *stress=manager(screens[s]); ZNSFloatingView *overlay=add(stress,2);
            CGRect keep=overlay.frame;
            for(unsigned i=0;i<count;i++) add(stress,3);
            [stress arrangeParked]; CHECK(overlay.thumbnail && overlay.thumbnailFree);
            CHECK(sameFrame(overlay.frame,keep)); verifyFixedClear(stress);
        }
    }
    printf("PASS %u assertions: extracted production packing/stack methods; no live UIKit gestures/scenes tested\n",checks);
} return 0; }
