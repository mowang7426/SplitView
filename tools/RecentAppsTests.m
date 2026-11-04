// Isolated production-helper tests. No SpringBoard loading or UI actions.
#import "../Sources/ZNSRecentApps.m"
#include <assert.h>
@interface SBDisplayItem : NSObject
@property(nonatomic,copy) NSString *bundleIdentifier;
@property(nonatomic,copy) NSString *uniqueIdentifier;
+ (id)displayItemWithType:(NSInteger)type bundleIdentifier:(id)bundle uniqueIdentifier:(id)identifier;
@end
@implementation SBDisplayItem
+ (id)displayItemWithType:(NSInteger)type bundleIdentifier:(id)bundle uniqueIdentifier:(id)identifier {
    assert(type==0); SBDisplayItem *item=[self new]; item.bundleIdentifier=bundle; item.uniqueIdentifier=identifier; return item;
}
@end
@interface SBAppLayout : NSObject <ZNSRecentLayoutFactory>
@property(nonatomic,strong) id allItems;
@end
@implementation SBAppLayout
- (instancetype)initWithItemsForLayoutRoles:(id)items configuration:(NSInteger)c environment:(NSInteger)e preferredDisplayOrdinal:(NSInteger)o {
    assert(c==1 && e==1 && o==0 && [items count]==1 && items[@1]);
    if((self=[super init])) self.allItems=@[items[@1]]; return self;
}
- (instancetype)initWithItemsForLayoutRoles:(id)items configuration:(NSInteger)c environment:(NSInteger)e {
    return [self initWithItemsForLayoutRoles:items configuration:c environment:e preferredDisplayOrdinal:0];
}
@end
@interface SBMainSwitcherControllerCoordinator : NSObject
@property(nonatomic,strong) NSMutableArray *recentAppLayouts;
@property(nonatomic) BOOL isAnySwitcherVisible;
@property(nonatomic) NSUInteger adds;
+ (id)sharedInstance;
- (void)_addAppLayoutToFront:(id)layout;
@end
@implementation SBMainSwitcherControllerCoordinator
+ (id)sharedInstance { static id v; if(!v) { v=[self new]; [v setRecentAppLayouts:[NSMutableArray new]]; } return v; }
- (void)_addAppLayoutToFront:(id)layout { self.adds++; [self.recentAppLayouts removeObject:layout]; [self.recentAppLayouts insertObject:layout atIndex:0]; }
@end
@interface SBLockScreenManager : NSObject
@property(nonatomic) BOOL isUILocked;
+ (id)sharedInstance;
@end
@implementation SBLockScreenManager
+ (id)sharedInstance { static id v; if(!v) v=[self new]; return v; }
@end
@interface ZNSMockScene : NSObject
@property(nonatomic,copy) NSString *identifier;
@property(nonatomic,strong) id clientProcess;
@end
@implementation ZNSMockScene
@end
@interface ZNSMockSession : NSObject
@property(nonatomic,copy) NSString *bundleIdentifier;
@property(nonatomic,strong) id hostView;
@property(nonatomic,strong) ZNSMockScene *scene;
@end
@implementation ZNSMockSession
@end
static ZNSMockSession *Session(NSString *bundle) {
    ZNSMockSession *s=[ZNSMockSession new]; s.bundleIdentifier=bundle; s.hostView=[NSObject new];
    s.scene=[ZNSMockScene new]; s.scene.identifier=[bundle stringByAppendingString:@".scene"];
    s.scene.clientProcess=[SBDisplayItem displayItemWithType:0 bundleIdentifier:bundle uniqueIdentifier:nil]; return s;
}
static BOOL Apply(id c,id s) { return ZNSRecentApply(c,(ZNSSceneSession *)s); }
static void Pump(void) { [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.04]]; }
int main(void) { @autoreleasepool {
    SBMainSwitcherControllerCoordinator *c=[SBMainSwitcherControllerCoordinator sharedInstance];
    ZNSMockSession *a=Session(@"test.a"),*b=Session(@"test.b");
    assert(ZNSRecentController()==c);
    assert(ZNSRecentCanMutate(c));
    c.isAnySwitcherVisible=YES; assert(!ZNSRecentCanMutate(c)); c.isAnySwitcherVisible=NO;
    SBLockScreenManager *lock=[SBLockScreenManager sharedInstance];
    lock.isUILocked=YES; assert(!ZNSRecentCanMutate(c)); lock.isUILocked=NO;
    assert(Apply(c,a)); id first=c.recentAppLayouts.firstObject;
    assert(c.recentAppLayouts.count==1);
    SBDisplayItem *display=[[first allItems] firstObject];
    assert([display.uniqueIdentifier isEqual:a.scene.identifier]);
    assert(Apply(c,b) && c.recentAppLayouts.firstObject!=first);
    assert(Apply(c,a) && c.recentAppLayouts.firstObject==first && c.recentAppLayouts.count==2);
    a.hostView=nil; assert(!Apply(c,a)); a.hostView=[NSObject new];
    a.scene.identifier=nil; assert(!Apply(c,a)); a.scene.identifier=@"test.a.scene";
    a.scene.clientProcess=b.scene.clientProcess; assert(!Apply(c,a)); a.scene.clientProcess=[SBDisplayItem displayItemWithType:0 bundleIdentifier:@"test.a" uniqueIdentifier:nil];
    [c.recentAppLayouts removeAllObjects];
    SBAppLayout *mixed=[SBAppLayout new]; mixed.allItems=@[a.scene.clientProcess,b.scene.clientProcess];
    [c.recentAppLayouts addObject:mixed]; assert(!Apply(c,a));
    mixed.allItems=@[[NSObject new]]; assert(!Apply(c,a));
    mixed.allItems=@"bad"; assert(!Apply(c,a));
    [c.recentAppLayouts removeAllObjects];
    ZNSPromoteRecentApp((id)a); ZNSPromoteRecentApp((id)b); ZNSPromoteRecentApp((id)a);
    assert(ZNSRecentPending.count==2); Pump();
    assert(c.recentAppLayouts.count==2);
    assert([[[c.recentAppLayouts.firstObject allItems] firstObject] bundleIdentifier]==a.bundleIdentifier);
    NSUInteger calls=c.adds;
    ZNSPromoteRecentApp((id)a); a.hostView=nil; Pump(); assert(c.adds==calls);
    a.hostView=[NSObject new]; c.isAnySwitcherVisible=YES;
    ZNSPromoteRecentApp((id)a); Pump(); assert(c.adds==calls);
    c.isAnySwitcherVisible=NO;
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.15]];
    assert(c.adds==calls+1 && !ZNSRecentScheduled);
    puts("PASS: recent-app production helpers: creation arguments, scene identity, reuse/order, unknown/multi-App rejection, FIFO coalescing, cancellation and switcher deferral. No real SpringBoard/UI verified.");
} return 0; }
