// Compile the actual teardown implementation against mock scene/host objects.
// No live process assertions, scene updates, injection or UI are exercised.
#import "../Sources/ZNSSceneSession.m"
#include <assert.h>
static unsigned releases;
@implementation ZNSProcessKeepAlive
- (instancetype)initWithBundleIdentifier:(NSString *)identifier { (void)identifier; return [super init]; }
- (void)invalidate { releases++; }
@end
@implementation ZNSKeyboardFocus
- (instancetype)initWithScene:(id)scene { (void)scene; return [super init]; }
- (void)setActive:(BOOL)active { (void)active; }
- (void)invalidate {}
@end
@interface ZNSTestSettings : NSObject
@property(nonatomic) CGRect frame;
@property(nonatomic) NSInteger interfaceOrientation;
@property(nonatomic) NSInteger deviceOrientation;
@property(nonatomic,getter=isBackgrounded) BOOL backgrounded;
@end
@implementation ZNSTestSettings
@end
@interface ZNSTestScene : NSObject
@property(nonatomic,strong) ZNSTestSettings *settings;
@property(nonatomic) unsigned updates;
@end
@implementation ZNSTestScene
- (void)updateSettingsWithBlock:(void (^)(id))block {
    assert(!objc_getAssociatedObject(self,&ZNSSceneLeaseKey));
    self.updates++; block(self.settings);
}
@end
@interface ZNSTestHost : NSObject
@property(nonatomic) BOOL failDetach;
@property(nonatomic) BOOL failInvalidate;
@property(nonatomic) unsigned invalidations;
@end
@implementation ZNSTestHost
- (void)removeFromSuperview { if(self.failDetach) [NSException raise:@"TestDetach" format:@"test"]; }
- (void)invalidate { self.invalidations++; if(self.failInvalidate) [NSException raise:@"TestInvalidate" format:@"test"]; }
@end
int main(void) { @autoreleasepool {
    unsigned cases=0;
    for(unsigned fullscreen=0;fullscreen<2;fullscreen++)
    for(unsigned savedForeground=0;savedForeground<2;savedForeground++)
    for(unsigned exceptions=0;exceptions<4;exceptions++)
    for(unsigned hasSaved=0;hasSaved<2;hasSaved++) {
        ZNSSceneSession *session=[[ZNSSceneSession alloc] initWithBundleIdentifier:@"test.mock.app"];
        ZNSTestScene *scene=[ZNSTestScene new]; scene.settings=[ZNSTestSettings new];
        scene.settings.backgrounded=fullscreen; // Start opposite to target.
        ZNSTestSettings *saved=[ZNSTestSettings new];
        saved.frame=CGRectMake(0,0,428,926); saved.interfaceOrientation=1; saved.deviceOrientation=1;
        saved.backgrounded=!savedForeground;
        ZNSTestHost *host=[ZNSTestHost new]; host.failDetach=exceptions&1; host.failInvalidate=exceptions&2;
        session.scene=scene; session.savedSettings=hasSaved?saved:nil; session.changedSettings=hasSaved;
        session.hostView=(id)host;
        session.keepAlive=[[ZNSProcessKeepAlive alloc] initWithBundleIdentifier:@"test.mock.app"];
        session.lease=[ZNSSceneLease new];
        objc_setAssociatedObject(scene,&ZNSSceneLeaseKey,session.lease,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        session.layoutInFlight=YES;
        unsigned before=releases;
        [session stopForFullscreen:fullscreen];
        assert(scene.updates==1 && scene.settings.backgrounded==!fullscreen);
        assert(host.invalidations==1 && releases==before+1);
        assert(session.stopped && !session.layoutInFlight && !session.lease && !session.keepAlive && !session.scene && !session.hostView);
        if(hasSaved) assert(CGRectEqualToRect(scene.settings.frame,saved.frame));
        [session stopForFullscreen:fullscreen];
        assert(scene.updates==1 && releases==before+1);
        cases++;
    }
    printf("PASS: %u production teardown mock cases (foreground/background saved state, fullscreen/close, detach/invalidate exceptions, missing saved state, idempotence).\n",cases);
    return 0;
} }
