#import "ZNSExitShatter.h"
#import "ZNSExitShatterLifecycle.h"
#import "ZNSLayerInput.h"
#import "ZNSParticlePolicy.h"
#import <QuartzCore/QuartzCore.h>

@interface ZNSExitShatterWindow : UIWindow @end
@implementation ZNSExitShatterWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { (void)point; (void)event; return nil; }
- (BOOL)canBecomeKeyWindow { return NO; }
@end
@interface ZNSExitShatterController : UIViewController
@property(nonatomic,copy) void (^znsCancel)(void);
@end
@implementation ZNSExitShatterController
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    if(self.znsCancel) self.znsCancel();
}
@end

@interface ZNSExitShatterPresentation : NSObject {
@public
    ZNSShatterLifetime znsLife;
    ZNSShatterPolygon znsPolygons[ZNSShatterCount];
}
@property(nonatomic) ZNSExitStyle znsStyle;
@property(nonatomic,weak) UIView *znsSource;
@property(nonatomic,strong) ZNSExitShatterWindow *znsHost;
@property(nonatomic,strong) UIView *znsStage;
@property(nonatomic,strong) UIView *znsFrozen;
@property(nonatomic,strong) NSMutableArray<UIView *> *znsShards;
@property(nonatomic,strong) NSMutableArray *znsObservers;
@property(nonatomic) double znsPixelArea;
@property(nonatomic) double znsScale;
- (void)znsSchedule:(BOOL)scatter token:(uint64_t)token;
- (BOOL)znsCapture;
- (BOOL)znsMakeShard:(unsigned)index;
- (void)znsClearShards;
- (void)znsPlay:(BOOL)scatter token:(uint64_t)token;
- (void)znsDispose;
- (void)znsCancel;
- (BOOL)znsMakeParticle:(unsigned)index;
- (BOOL)znsBuildReference;
- (void)znsPlaySelected:(uint64_t)token;
@end
static NSMutableSet<ZNSExitShatterPresentation *> *ZNSExitShatterPresentations;
static BOOL ZNSExitShatterCapturing;
static ZNSExitShatterPresentation *ZNSShatterObject(void *p) { return (__bridge ZNSExitShatterPresentation *)p; }
static bool ZNSShatterCaptureOp(void *p) { return [ZNSShatterObject(p) znsCapture]; }
static bool ZNSShatterShardOp(void *p,unsigned i) { return [ZNSShatterObject(p) znsMakeShard:i]; }
static bool ZNSParticleShardOp(void *p,unsigned i) { return [ZNSShatterObject(p) znsMakeParticle:i]; }
static void ZNSShatterClearOp(void *p) { [ZNSShatterObject(p) znsClearShards]; }
static void ZNSShatterPlayOp(void *p,bool scatter,uint64_t token) { [ZNSShatterObject(p) znsPlay:scatter token:token]; }
static void ZNSShatterDisposeOp(void *p) { [ZNSShatterObject(p) znsDispose]; }
static void ZNSShatterScheduleOp(void *p,bool scatter,uint64_t token) { [ZNSShatterObject(p) znsSchedule:scatter token:token]; }
static const ZNSShatterOperations ZNSExitShatterOps={ZNSShatterCaptureOp,ZNSShatterShardOp,ZNSShatterClearOp,ZNSShatterPlayOp,ZNSShatterDisposeOp,ZNSShatterScheduleOp};

@implementation ZNSExitShatterPresentation
- (BOOL)znsCapture {
    UIView *source=self.znsSource;
    UIWindow *window=source.window;
    UIWindowScene *scene=window.windowScene;
    if(!source || !scene || window.hidden || source.hidden || source.alpha<0.01 ||
       scene.activationState==UISceneActivationStateUnattached || CGRectIsEmpty(source.bounds)) return NO;
    self.znsScale=window.screen.scale;
    double sourcePixels=0;
    if(!ZNSShatterSourcePixels(source.bounds.size.width,source.bounds.size.height,self.znsScale,&sourcePixels)) return NO;
    self.znsPixelArea=sourcePixels;
    // Frozen local compositor replica; NEVER renderInContext/drawViewHierarchy,
    // afterScreenUpdates:YES, a screenshot service, image readback or disk I/O.
    // UIKit can refuse remote/protected content. A nonnil replica is NOT proof
    // that every remote pixel was included; see README-shatter1.md.
    UIView *frozen=[source snapshotViewAfterScreenUpdates:NO];
    if(!frozen) return NO;
    self.znsFrozen=frozen;
    self.znsHost=[[ZNSExitShatterWindow alloc] initWithWindowScene:scene];
    self.znsHost.frame=scene.coordinateSpace.bounds;
    self.znsHost.windowLevel=window.windowLevel+1;
    self.znsHost.backgroundColor=UIColor.clearColor;
    self.znsHost.opaque=NO; self.znsHost.userInteractionEnabled=NO;
    self.znsHost.accessibilityElementsHidden=YES;
    ZNSSetLayerInputEnabled(self.znsHost.layer,NO);
    ZNSExitShatterController *controller=[ZNSExitShatterController new];
    controller.view.backgroundColor=UIColor.clearColor;
    controller.view.opaque=NO; controller.view.userInteractionEnabled=NO;
    self.znsHost.rootViewController=controller;
    controller.view.frame=self.znsHost.bounds;
    CGPoint origin=source.bounds.origin;
    CGPoint p=[source convertPoint:origin toCoordinateSpace:self.znsHost];
    CGPoint x=[source convertPoint:CGPointMake(origin.x+1,origin.y) toCoordinateSpace:self.znsHost];
    CGPoint y=[source convertPoint:CGPointMake(origin.x,origin.y+1) toCoordinateSpace:self.znsHost];
    if(!isfinite(p.x) || !isfinite(p.y) || !isfinite(x.x) || !isfinite(x.y) || !isfinite(y.x) || !isfinite(y.y)) return NO;
    UIView *stage=[[UIView alloc] initWithFrame:(CGRect){CGPointZero,source.bounds.size}];
    stage.layer.anchorPoint=CGPointZero;
    stage.layer.position=p;
    stage.transform=CGAffineTransformMake(x.x-p.x,x.y-p.y,y.x-p.x,y.y-p.y,0,0);
    stage.userInteractionEnabled=NO; stage.accessibilityElementsHidden=YES;
    stage.backgroundColor=UIColor.clearColor;
    [controller.view addSubview:stage]; self.znsStage=stage;
    frozen.frame=stage.bounds; frozen.userInteractionEnabled=NO;
    [stage addSubview:frozen];
    self.znsShards=[NSMutableArray new]; self.znsObservers=[NSMutableArray new];
    __weak typeof(self) weakSelf=self;
    controller.znsCancel=^{ [weakSelf znsCancel]; };
    NSNotificationCenter *center=NSNotificationCenter.defaultCenter;
    for(NSString *name in @[UISceneDidDisconnectNotification,UISceneWillDeactivateNotification,
                           UIApplicationWillResignActiveNotification,UIDeviceOrientationDidChangeNotification,
                           UIAccessibilityReduceMotionStatusDidChangeNotification]) {
        id observer=[center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            ZNSExitShatterPresentation *current=weakSelf;
            if(!current) return;
            if(([note.name isEqualToString:UISceneDidDisconnectNotification] || [note.name isEqualToString:UISceneWillDeactivateNotification]) &&
               note.object!=current.znsHost.windowScene) return;
            [current znsCancel];
        }];
        [self.znsObservers addObject:observer];
    }
    return YES;
}
- (BOOL)znsMakeShard:(unsigned)index {
    ZNSShatterPolygon poly=znsPolygons[index];
    CGFloat minX=CGFLOAT_MAX,minY=CGFLOAT_MAX,maxX=0,maxY=0;
    for(unsigned k=0;k<poly.count;k++) {
        minX=MIN(minX,poly.p[k].x); minY=MIN(minY,poly.p[k].y);
        maxX=MAX(maxX,poly.p[k].x); maxY=MAX(maxY,poly.p[k].y);
    }
    CGRect rect=CGRectMake(minX,minY,maxX-minX,maxY-minY);
    double pixels=self.znsPixelArea;
    if(!ZNSShatterReservePixels(&pixels,rect.size.width*rect.size.height*self.znsScale*self.znsScale)) return NO;
    self.znsPixelArea=pixels;
    // Derive bounded cropped replicas from ONE frozen source, not the App.
    // No CPU bitmap per shard. Backing-store sharing is controlled by UIKit.
    UIView *replica=[self.znsFrozen resizableSnapshotViewFromRect:rect afterScreenUpdates:NO withCapInsets:UIEdgeInsetsZero];
    if(!replica) return NO;
    replica.frame=rect; replica.userInteractionEnabled=NO;
    CAShapeLayer *mask=[CAShapeLayer layer];
    CGMutablePathRef path=CGPathCreateMutable();
    CGPathMoveToPoint(path,NULL,poly.p[0].x-minX,poly.p[0].y-minY);
    for(unsigned k=1;k<poly.count;k++) CGPathAddLineToPoint(path,NULL,poly.p[k].x-minX,poly.p[k].y-minY);
    CGPathCloseSubpath(path); mask.path=path; CGPathRelease(path);
    mask.frame=replica.bounds; replica.layer.mask=mask;
    [self.znsStage addSubview:replica]; [self.znsShards addObject:replica];
    return YES;
}
- (BOOL)znsMakeParticle:(unsigned)index {
    ZNSParticle p;
    if(!ZNSParticlePlan(self.znsFrozen.bounds.size.width,self.znsFrozen.bounds.size.height,self.znsScale,index,&p)) return NO;
    double pixels=self.znsPixelArea;
    if(!ZNSShatterReservePixels(&pixels,p.w*p.h*self.znsScale*self.znsScale)) return NO;
    self.znsPixelArea=pixels;
    CGRect rect=CGRectMake(p.x,p.y,p.w,p.h);
    UIView *tile=[self.znsFrozen resizableSnapshotViewFromRect:rect afterScreenUpdates:NO withCapInsets:UIEdgeInsetsZero];
    if(!tile) return NO;
    tile.frame=rect; tile.userInteractionEnabled=NO;
    [self.znsStage addSubview:tile]; [self.znsShards addObject:tile];
    return YES;
}
- (void)znsClearShards {
    for(UIView *shard in self.znsShards) { [shard.layer removeAllAnimations]; [shard removeFromSuperview]; }
    [self.znsShards removeAllObjects];
}
- (void)znsSchedule:(BOOL)scatter token:(uint64_t)token {
    self.znsSource=nil;
    self.znsHost.hidden=NO;
    __weak typeof(self) weakSelf=self;
    // One display opportunity for the frozen replica, NOT a synchronous render
    // fence. A stalled compositor is never waited on; a nil crop simply fades.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.02*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        ZNSExitShatterPresentation *current=weakSelf;
        if(!current || !current->znsLife.active || current->znsLife.generation!=token) return;
        @try {
            if(current.znsStyle==ZNSExitShatter) ZNSShatterBuild(&current->znsLife,(__bridge void *)current,ZNSExitShatterOps,scatter,token);
            else {
                if(current.znsStyle==ZNSExitReference && ![current znsBuildReference]) {
                    [current znsClearShards]; current.znsStyle=ZNSExitFade;
                }
                if(current.znsStyle==ZNSExitParticles) {
                    ZNSShatterOperations ops=ZNSExitShatterOps; ops.shard=ZNSParticleShardOp;
                    if(!ZNSParticleBuild(&current->znsLife,(__bridge void *)current,ops,token)) current.znsStyle=ZNSExitFade;
                }
                [current znsPlay:NO token:token];
            }
        }
        @catch(__unused NSException *exception) {
            // An unexpected crop exception still has a valid frozen root.
            [current znsClearShards]; current.znsStyle=ZNSExitFade;
            @try { [current znsPlay:NO token:token]; }
            @catch(__unused NSException *fallbackException) { [current znsCancel]; }
        }
    });
}
- (void)znsPlay:(BOOL)scatter token:(uint64_t)token {
    if(self.znsStyle!=ZNSExitShatter) { [self znsPlaySelected:token]; return; }
    self.znsSource=nil; // No retained live view/session in any animation callback.
    // Retain the single frozen provider until disposal, including when its view
    // is detached. Cropped replicas may share its compositor backing store.
    if(scatter) [self.znsFrozen removeFromSuperview];
    else if(self.znsFrozen.superview!=self.znsStage) {
        self.znsFrozen.alpha=1; [self.znsStage addSubview:self.znsFrozen];
    }
    self.znsHost.hidden=NO; // Never makeKeyAndVisible or change scene geometry.
    __weak typeof(self) weakSelf=self;
    [UIView animateWithDuration:scatter?ZNSShatterDuration:ZNSShatterFadeDuration delay:0
        options:UIViewAnimationOptionCurveEaseIn|UIViewAnimationOptionAllowUserInteraction animations:^{
        if(scatter) {
            for(unsigned i=0;i<self.znsShards.count;i++) {
                UIView *shard=self.znsShards[i]; ZNSShatterPolygon poly=self->znsPolygons[i];
                shard.transform=CGAffineTransformRotate(CGAffineTransformMakeTranslation(poly.dx,poly.dy),poly.angle);
                shard.alpha=0;
            }
        } else self.znsFrozen.alpha=0;
    } completion:^(BOOL finished) {
        (void)finished;
        ZNSExitShatterPresentation *current=weakSelf;
        if(current) ZNSShatterFinish(&current->znsLife,(__bridge void *)current,ZNSExitShatterOps,token);
    }];
    // Bounded fail-safe if UIKit drops a completion; only this token is affected.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.7*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        ZNSExitShatterPresentation *current=weakSelf;
        if(current) ZNSShatterFinish(&current->znsLife,(__bridge void *)current,ZNSExitShatterOps,token);
    });
}
// Reference-inspired approximation: horizontal frozen bands disappear towards
// the right with uneven phase. Not a claim of reproducing a private dust shader.
- (BOOL)znsBuildReference {
    CGFloat w=self.znsFrozen.bounds.size.width,h=self.znsFrozen.bounds.size.height;
    for(unsigned i=0;i<ZNSReferenceBands;i++) {
        CGFloat y=h*i/ZNSReferenceBands, end=h*(i+1)/ZNSReferenceBands;
        CGRect rect=CGRectMake(0,y,w,end-y);
        double pixels=self.znsPixelArea;
        if(!ZNSShatterReservePixels(&pixels,w*(end-y)*self.znsScale*self.znsScale)) return NO;
        self.znsPixelArea=pixels;
        UIView *band=[self.znsFrozen resizableSnapshotViewFromRect:rect afterScreenUpdates:NO withCapInsets:UIEdgeInsetsZero];
        if(!band) return NO;
        band.frame=rect;band.userInteractionEnabled=NO;
        [self.znsStage addSubview:band];[self.znsShards addObject:band];
    }
    return YES;
}
- (void)znsPlaySelected:(uint64_t)token {
    self.znsSource=nil; self.znsHost.hidden=NO;
    ZNSMotionPlan p=ZNSExitMotionPlan(self.znsStyle,self.znsFrozen.bounds.size.width,self.znsFrozen.bounds.size.height);
    if(self.znsStyle==ZNSExitParticles) {
        [self.znsFrozen removeFromSuperview];
        for(unsigned i=0;i<self.znsShards.count;i++) {
            ZNSParticle particle;
            if(!ZNSParticlePlan(self.znsFrozen.bounds.size.width,self.znsFrozen.bounds.size.height,self.znsScale,i,&particle)) { [self znsCancel]; return; }
            UIView *tile=self.znsShards[i];
            [UIView animateWithDuration:ZNSParticleDuration delay:particle.delay
                options:UIViewAnimationOptionCurveEaseIn|UIViewAnimationOptionAllowUserInteraction animations:^{
                CGAffineTransform t=CGAffineTransformMakeTranslation(particle.dx,particle.dy);
                t=CGAffineTransformRotate(t,particle.angle);
                tile.transform=CGAffineTransformScale(t,particle.scale,particle.scale);
                tile.alpha=0;
            } completion:nil];
        }
    } else if(self.znsStyle==ZNSExitReference) {
        [self.znsFrozen removeFromSuperview];
        for(unsigned i=0;i<self.znsShards.count;i++) {
            UIView *band=self.znsShards[i];
            [UIView animateWithDuration:p.duration delay:ZNSReferenceDelay(i)
                options:UIViewAnimationOptionCurveEaseIn|UIViewAnimationOptionAllowUserInteraction animations:^{
                // Center-based collapse plus translation keeps the vanishing
                // edge biased right, with a small alternating vertical drift.
                band.transform=CGAffineTransformMake(p.sx,0,0,1,p.dx*.5,(i%2?1:-1)*8);
                band.alpha=0;
            } completion:nil];
        }
    } else {
        if(self.znsFrozen.superview!=self.znsStage) [self.znsStage addSubview:self.znsFrozen];
        [UIView animateWithDuration:p.duration delay:0 options:UIViewAnimationOptionCurveEaseIn|UIViewAnimationOptionAllowUserInteraction animations:^{
            CATransform3D t=CATransform3DIdentity;
            if(p.angle) { t.m34=-1.0/800; t=CATransform3DRotate(t,p.angle,1,0,0); }
            t=CATransform3DTranslate(t,p.dx,p.dy,0);t=CATransform3DScale(t,p.sx,p.sy,1);
            self.znsFrozen.layer.transform=t;self.znsFrozen.alpha=0;
        } completion:nil];
    }
    __weak typeof(self) weakSelf=self;
    double duration=p.duration+(self.znsStyle==ZNSExitReference?.20:(self.znsStyle==ZNSExitParticles?ZNSParticleMaxDelay:0))+.03;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(duration*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        ZNSExitShatterPresentation *current=weakSelf;
        if(current) ZNSShatterFinish(&current->znsLife,(__bridge void *)current,ZNSExitShatterOps,token);
    });
}
- (void)znsCancel { ZNSShatterFinish(&znsLife,(__bridge void *)self,ZNSExitShatterOps,znsLife.generation); }
- (void)znsDispose {
    for(id observer in self.znsObservers) [NSNotificationCenter.defaultCenter removeObserver:observer];
    [self.znsObservers removeAllObjects];
    [self znsClearShards];
    [self.znsFrozen.layer removeAllAnimations]; [self.znsFrozen removeFromSuperview]; self.znsFrozen=nil;
    [self.znsStage removeFromSuperview]; self.znsStage=nil;
    ((ZNSExitShatterController *)self.znsHost.rootViewController).znsCancel=nil;
    self.znsHost.hidden=YES; self.znsHost.rootViewController=nil; self.znsHost=nil;
    self.znsSource=nil;
    [ZNSExitShatterPresentations removeObject:self];
}
@end

BOOL ZNSExitShatterPresent(UIView *source) { return ZNSExitAnimationPresent(source,ZNSExitShatter); }
BOOL ZNSExitAnimationPresent(UIView *source,ZNSExitStyle style) {
    style=ZNSResolveExitStyle(style,UIAccessibilityIsReduceMotionEnabled());
    if(style==ZNSExitNone) return NO;
    if(!NSThread.isMainThread || !source.window || ZNSExitShatterCapturing) return NO;
    // At most one presentation: rapid closing cannot accumulate textures/hosts.
    ZNSExitShatterCancelAll();
    ZNSExitShatterCapturing=YES;
    ZNSExitShatterPresentation *presentation=[ZNSExitShatterPresentation new];
    presentation.znsSource=source; presentation.znsStyle=style;
    if(!ZNSExitShatterPresentations) ZNSExitShatterPresentations=[NSMutableSet new];
    [ZNSExitShatterPresentations addObject:presentation];
    BOOL accepted=NO;
    @try {
        BOOL scatter=style==ZNSExitShatter && !UIAccessibilityIsReduceMotionEnabled() &&
            ZNSShatterGeometry(source.bounds.size.width,source.bounds.size.height,source.window.screen.scale,
                               arc4random(),presentation->znsPolygons);
        accepted=ZNSShatterStart(&presentation->znsLife,(__bridge void *)presentation,ZNSExitShatterOps,scatter);
    } @catch(__unused NSException *exception) {
        presentation->znsLife.active=false; [presentation znsDispose];
    } @finally { ZNSExitShatterCapturing=NO; }
    return accepted;
}
void ZNSExitShatterCancelAll(void) {
    if(!NSThread.isMainThread) return;
    for(ZNSExitShatterPresentation *presentation in [ZNSExitShatterPresentations copy]) [presentation znsCancel];
}
