#import "ZNSWindowOpening.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

@interface ZNSWindowOpeningState : NSObject {
@public ZNSOpeningLifetime znsLife;
}
@property(nonatomic,weak) UIView *znsView;
@property(nonatomic,strong) NSMutableArray *znsObservers;
- (void)znsCancel;
- (void)znsClear;
@end
static char ZNSWindowOpeningKey;
static NSHashTable<ZNSWindowOpeningState *> *ZNSWindowOpenings;
@implementation ZNSWindowOpeningState
- (void)znsClear {
    // Only our presentation animations. Model alpha/transform were NEVER changed.
    [self.znsView.layer removeAnimationForKey:@"ZNSWindowOpening"];
    for(id observer in self.znsObservers) [NSNotificationCenter.defaultCenter removeObserver:observer];
    [self.znsObservers removeAllObjects];
    [ZNSWindowOpenings removeObject:self];
}
- (void)znsCancel { ZNSOpeningCancel(&znsLife); [self znsClear]; }
- (void)dealloc {
    for(id observer in _znsObservers) [NSNotificationCenter.defaultCenter removeObserver:observer];
}
@end
void ZNSWindowOpeningCancel(UIView *view) {
    ZNSWindowOpeningState *s=objc_getAssociatedObject(view,&ZNSWindowOpeningKey);
    [s znsCancel];
}
void ZNSWindowOpeningCancelAll(void) {
    if(!NSThread.isMainThread) return;
    for(ZNSWindowOpeningState *s in ZNSWindowOpenings.allObjects) [s znsCancel];
}
void ZNSWindowOpeningReady(UIView *view,ZNSEntryStyle style,BOOL hostReady,BOOL eligible) {
    if(!NSThread.isMainThread || !view) return;
    ZNSWindowOpeningState *s=objc_getAssociatedObject(view,&ZNSWindowOpeningKey);
    if(!s) {
        s=[ZNSWindowOpeningState new]; s.znsView=view;
        objc_setAssociatedObject(view,&ZNSWindowOpeningKey,s,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    style=ZNSResolveEntryStyle(style,UIAccessibilityIsReduceMotionEnabled());
    uint64_t token=ZNSOpeningReady(&s->znsLife,true,hostReady,eligible && view.window && !view.hidden,style);
    if(!token) return;
    ZNSMotionPlan p=ZNSEntryMotionPlan(style);
    CATransform3D base=view.layer.transform;
    CATransform3D from=CATransform3DTranslate(base,p.dx,p.dy,0);
    from=CATransform3DScale(from,p.sx,p.sy,1);
    CAAnimation *motion;
    if(p.spring) {
        CAKeyframeAnimation *pop=[CAKeyframeAnimation animationWithKeyPath:@"transform"];
        pop.values=@[[NSValue valueWithCATransform3D:from],
                     [NSValue valueWithCATransform3D:CATransform3DScale(base,1.025,1.025,1)],
                     [NSValue valueWithCATransform3D:base]];
        pop.keyTimes=@[@0,@0.72,@1]; motion=pop;
    } else {
        CABasicAnimation *expand=[CABasicAnimation animationWithKeyPath:@"transform"];
        expand.fromValue=[NSValue valueWithCATransform3D:from];
        expand.toValue=[NSValue valueWithCATransform3D:base]; motion=expand;
    }
    motion.duration=p.duration;
    CABasicAnimation *fade=[CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue=@0; fade.toValue=@(view.layer.opacity);fade.duration=p.duration;
    CAAnimationGroup *group=[CAAnimationGroup animation];group.animations=@[motion,fade];group.duration=p.duration;
    group.timingFunction=[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [view.layer addAnimation:group forKey:@"ZNSWindowOpening"];
    if(!ZNSWindowOpenings) ZNSWindowOpenings=[NSHashTable weakObjectsHashTable];
    [ZNSWindowOpenings addObject:s];s.znsObservers=[NSMutableArray new];
    __weak ZNSWindowOpeningState *weakState=s;
    for(NSString *name in @[UIDeviceOrientationDidChangeNotification,UISceneWillDeactivateNotification,
                           UISceneDidDisconnectNotification,UIApplicationWillResignActiveNotification,
                           UIAccessibilityReduceMotionStatusDidChangeNotification]) {
        id observer=[NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            ZNSWindowOpeningState *current=weakState;
            if(!current) return;
            if(([note.name isEqualToString:UISceneWillDeactivateNotification] || [note.name isEqualToString:UISceneDidDisconnectNotification]) && note.object!=current.znsView.window.windowScene) return;
            [current znsCancel];
        }];
        [s.znsObservers addObject:observer];
    }
    // No delayed host polling and no pixel fence. This only removes our token.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)((p.duration+.05)*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        ZNSWindowOpeningState *current=weakState;
        if(current && ZNSOpeningFinish(&current->znsLife,token)) [current znsClear];
    });
}
