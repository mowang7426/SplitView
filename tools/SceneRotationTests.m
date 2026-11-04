// Exercise the production resize/lease/ack/teardown code without UIKit windows,
// FBScene, injection, process assertions or any screen interaction.
#define main ZNSCloseRegressionMain
#import "SceneCloseTests.m"
#undef main

@interface ZNSRotationSettings : ZNSTestSettings <NSCopying, NSMutableCopying>
@property(nonatomic) NSInteger unrelated;
@end
@implementation ZNSRotationSettings
- (id)copyWithZone:(NSZone *)zone {
    ZNSRotationSettings *s=[[[self class] allocWithZone:zone] init];
    s.frame=self.frame; s.interfaceOrientation=self.interfaceOrientation;
    s.deviceOrientation=self.deviceOrientation; s.backgrounded=self.backgrounded;
    s.unrelated=self.unrelated; return s;
}
- (id)mutableCopyWithZone:(NSZone *)zone { return [self copyWithZone:zone]; }
@end
@interface ZNSRotationScene : ZNSTestScene
@property(nonatomic,copy) void (^pending)(void);
@property(nonatomic) BOOL throwNext;
@end
@implementation ZNSRotationScene
- (void)updateSettings:(id)settings withTransitionContext:(id)context completion:(void (^)(void))completion {
    (void)context;
    if(self.throwNext) { self.throwNext=NO; [NSException raise:@"MockSubmit" format:@"test"]; }
    self.settings=[settings copy]; self.pending=completion;
}
- (void)ack { void (^done)(void)=self.pending; self.pending=nil; if(done) done(); }
@end
@interface ZNSRotationHost : NSObject
@property(nonatomic) CGSize referenceSize;
@property(nonatomic) NSInteger orientation;
@property(nonatomic) CGRect bounds;
@property(nonatomic,readonly) CGPoint center;
@property(nonatomic,strong) CALayer *layer;
@property(nonatomic) BOOL userInteractionEnabled;
@end
@implementation ZNSRotationHost
- (instancetype)init { if((self=[super init])) _layer=[CALayer layer]; return self; }
- (void)_updateReferenceSize:(CGSize)size andOrientation:(NSInteger)orientation {
    self.referenceSize=size; self.orientation=orientation;
    // Model a stale small host with a system-owned quarter-turn and offset.
    self.bounds=CGRectMake(11,17,120,200);
    self.layer.affineTransform=UIInterfaceOrientationIsLandscape(orientation)?
        CGAffineTransformMake(0,1,-1,0,23,-31):CGAffineTransformIdentity;
}
- (CGPoint)center { return self.layer.position; }
- (CGAffineTransform)transform { return self.layer.affineTransform; }
- (UIView *)superview { return nil; }
- (void)setNeedsLayout {}
- (void)layoutIfNeeded {}
- (void)removeFromSuperview {}
- (void)invalidate {}
@end
@interface ZNSRotationSession : ZNSSceneSession
@property(nonatomic) NSUInteger replacements;
@end
@implementation ZNSRotationSession
- (UIView *)newHostWithSize:(CGSize)size orientation:(NSInteger)orientation requester:(ZNSSceneHostRequester *)requester {
    (void)size; (void)orientation; (void)requester;
    return (id)[ZNSRotationHost new];
}
- (BOOL)replaceHostWithSize:(CGSize)size orientation:(NSInteger)orientation generation:(NSUInteger)generation {
    assert(generation==self.layoutGeneration && !self.stopped);
    self.replacements++;
    // The actual host factory is outside this test. The production coordinate
    // updater and its ABI/readback checks still run on the mock host.
    return ZNSConfigureHostCanvas(self.hostView,size,orientation);
}
@end
static void Drain(void) {
    NSDate *until=[NSDate dateWithTimeIntervalSinceNow:0.025];
    while(until.timeIntervalSinceNow>0) [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
}
static ZNSRotationSession *Session(void) {
    ZNSRotationSession *s=[[ZNSRotationSession alloc] initWithBundleIdentifier:@"test.mock.rotation"];
    ZNSRotationScene *scene=[ZNSRotationScene new];
    ZNSRotationSettings *settings=[ZNSRotationSettings new];
    settings.frame=CGRectMake(7,9,428,926); settings.interfaceOrientation=1; settings.deviceOrientation=1;
    settings.backgrounded=YES; settings.unrelated=71;
    scene.settings=settings; s.scene=scene; s.savedSettings=[settings copy];
    s.lease=[ZNSSceneLease new];
    objc_setAssociatedObject(scene,&ZNSSceneLeaseKey,s.lease,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return s;
}
static void ResizeOK(ZNSRotationSession *s,CGSize canvas,BOOL landscape,CGSize expectedFixed) {
    ZNSRotationScene *scene=s.scene;
    __block unsigned calls=0;
    assert([s resize:canvas landscape:landscape completion:^(BOOL ok,NSString *message){ assert(ok && !message); calls++; }]);
    assert(s.layoutInFlight && !calls);
    assert(![s resize:canvas landscape:landscape completion:nil]); // No overlapping transaction.
    assert(CGRectEqualToRect(scene.settings.frame,(CGRect){CGPointZero,expectedFixed}));
    assert(CGRectEqualToRect([s.lease.settings frame],scene.settings.frame));
    assert(scene.settings.interfaceOrientation==(landscape?UIInterfaceOrientationLandscapeRight:UIInterfaceOrientationPortrait));
    assert(scene.settings.deviceOrientation==(landscape?UIDeviceOrientationLandscapeLeft:UIDeviceOrientationPortrait));
    assert(!scene.settings.backgrounded);
    [scene ack]; Drain();
    assert(calls==1 && !s.layoutInFlight);
    assert(CGSizeEqualToSize(s.canvasSize,canvas) && s.landscape==landscape);
    ZNSRotationHost *host=(id)s.hostView;
    assert(CGSizeEqualToSize(host.referenceSize,canvas));
    assert(host.orientation==(landscape?UIInterfaceOrientationLandscapeRight:UIInterfaceOrientationPortrait));
    CGAffineTransform expected=landscape?CGAffineTransformMake(0,1,-1,0,23,-31):CGAffineTransformIdentity;
    assert(CGAffineTransformEqualToTransform(host.transform,expected));
    assert(CGPointEqualToPoint(host.bounds.origin,CGPointMake(11,17)));
    CGSize expectedLocal=landscape?CGSizeMake(canvas.height,canvas.width):canvas;
    assert(CGSizeEqualToSize(host.bounds.size,expectedLocal));
    assert(CGPointEqualToPoint(host.center,CGPointMake(canvas.width/2-expected.tx,canvas.height/2-expected.ty)));
    host.bounds=CGRectMake(11,17,90,60);
    [s layoutHostInCanvas];
    assert(CGSizeEqualToSize(host.bounds.size,expectedLocal));
    assert(CGAffineTransformEqualToTransform(host.transform,expected));
    // Later system settings must preserve the already-fixed frame verbatim,
    // not swap it a second time, and must preserve fields not owned by us.
    ZNSRotationSettings *incoming=[ZNSRotationSettings new];
    incoming.frame=CGRectMake(10,20,100,200); incoming.backgrounded=YES; incoming.unrelated=93;
    ZNSRotationSettings *guarded=ZNSSettingsForHostedScene(scene,incoming);
    assert(CGRectEqualToRect(guarded.frame,(CGRect){CGPointZero,expectedFixed}));
    assert(guarded.interfaceOrientation==scene.settings.interfaceOrientation);
    assert(guarded.deviceOrientation==scene.settings.deviceOrientation);
    assert(!guarded.backgrounded && guarded.unrelated==93 && incoming.backgrounded);
}
int main(void) { @autoreleasepool {
    assert(NSThread.isMainThread);
    assert(ZNSCloseRegressionMain()==0);
    unsigned transitions=0;
    CGSize sizes[]={ {428,926},{390,844},{320.5,701.25},{600,600} };
    for(unsigned i=0;i<4;i++) {
        ZNSRotationSession *s=Session();
        CGSize p=sizes[i],l=CGSizeMake(p.height,p.width);
        ResizeOK(s,p,NO,p); transitions++;
        ResizeOK(s,l,YES,p); transitions++;
        ResizeOK(s,l,YES,p); transitions++;
        ResizeOK(s,p,NO,p); transitions++;
        assert(s.replacements==2);
        ZNSRotationScene *scene=s.scene;
        [s stopForFullscreen:NO];
        assert(CGRectEqualToRect(scene.settings.frame,CGRectMake(7,9,428,926)));
    }
    // Contract depends on orientation, NOT sorting the dimensions.
    ZNSRotationSession *odd=Session();
    ResizeOK(odd,CGSizeMake(280,640),YES,CGSizeMake(640,280)); transitions++;
    [odd stopForFullscreen:NO];
    for(unsigned mismatch=0;mismatch<3;mismatch++) {
        ZNSRotationSession *s=Session(); ResizeOK(s,CGSizeMake(428,926),NO,CGSizeMake(428,926));
        ZNSRotationScene *scene=s.scene; __block unsigned failed=0;
        assert([s resize:CGSizeMake(926,428) landscape:YES completion:^(BOOL ok,NSString *message){assert(!ok && message.length);failed++;}]);
        if(mismatch==0) scene.settings.frame=CGRectMake(0,0,926,428); // Old oriented-frame bug.
        if(mismatch==1) scene.settings.interfaceOrientation=1;
        if(mismatch==2) scene.settings.deviceOrientation=1;
        [scene ack]; Drain();
        assert(failed==1 && !s.layoutInFlight && !s.landscape && s.replacements==0);
        [s stopForFullscreen:NO];
    }
    ZNSRotationSession *s=Session(); ResizeOK(s,CGSizeMake(428,926),NO,CGSizeMake(428,926));
    ZNSRotationScene *scene=s.scene; scene.throwNext=YES;
    assert(![s resize:CGSizeMake(926,428) landscape:YES completion:nil]);
    assert(!s.layoutInFlight && !s.landscape);
    assert(CGRectEqualToRect(scene.settings.frame,CGRectMake(0,0,428,926)));
    assert([s.lease.settings interfaceOrientation]==1);
    assert(CGSizeEqualToSize(((ZNSRotationHost *)(id)s.hostView).referenceSize,CGSizeMake(428,926)));
    __block unsigned late=0;
    assert([s resize:CGSizeMake(926,428) landscape:YES completion:^(BOOL ok,NSString *message){(void)ok;(void)message;late++;}]);
    [s stopForFullscreen:NO]; [scene ack]; Drain();
    assert(!late && !s.hostView && !s.layoutInFlight);
    printf("PASS: %u canvas transitions, fixed-space submission/ack, unchanged host canvas, lease copying, 3 mismatches, rollback, late callback; no real App rendering tested.\n",transitions);
    return 0;
} }
