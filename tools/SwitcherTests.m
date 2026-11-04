// Production helper regression tests with isolated mocks, no UI/system actions.
#import "../Sources/ZNSSwitcherHooks.m"
#include <assert.h>

@implementation ZNSWindowActivation
- (BOOL)commit { abort(); }
- (void)cancel {}
@end
@implementation ZNSWindowManager
+ (instancetype)shared { abort(); }
- (void)reloadPreferences { abort(); }
- (BOOL)openBundleIdentifier:(NSString *)b { (void)b; abort(); }
- (BOOL)canOpenBundleIdentifier:(NSString *)b { (void)b; abort(); }
- (ZNSWindowActivation *)prepareSwitcherBundleIdentifier:(NSString *)b whenReady:(void (^)(BOOL))c { (void)b; (void)c; abort(); }
- (BOOL)openBundleIdentifier:(NSString *)b whenReady:(void (^)(BOOL))c { (void)b; (void)c; abort(); }
- (BOOL)handleDesktopIconTap:(UIView *)v { (void)v; abort(); }
- (void)emitDiagnostics { abort(); }
- (void)attachGesturesToIconView:(UIView *)v { (void)v; abort(); }
- (void)closeForLock { abort(); }
- (void)observeEvent:(UIEvent *)e { (void)e; abort(); }
@end
@interface ZNSTestDisplayItem : NSObject
@property(nonatomic,copy) NSString *bundleIdentifier;
@end
@implementation ZNSTestDisplayItem
@end
@interface SBApplicationController : NSObject
+ (instancetype)sharedInstance;
- (id)applicationWithBundleIdentifier:(NSString *)bundle;
@end
@implementation SBApplicationController
+ (instancetype)sharedInstance { static id controller; if (!controller) controller=[self new]; return controller; }
- (id)applicationWithBundleIdentifier:(NSString *)bundle {
    if (![@[@"test.app.a",@"test.app.b"] containsObject:bundle]) return nil;
    ZNSTestDisplayItem *item=[ZNSTestDisplayItem new]; item.bundleIdentifier=bundle; return item;
}
@end
@interface SBAppLayout : NSObject
@property(nonatomic,strong) id allItems;
@property(nonatomic,copy) NSString *continuousExposeIdentifier;
+ (id)homeScreenAppLayout;
@end
@implementation SBAppLayout
+ (id)homeScreenAppLayout { return [self new]; }
@end
@interface SBMainSwitcherControllerCoordinator : NSObject
+ (instancetype)sharedInstance;
- (BOOL)_dismissSwitcherNoninteractivelyToAppLayout:(id)layout dismissFloatingSwitcher:(BOOL)floating animated:(BOOL)animated;
@end
@implementation SBMainSwitcherControllerCoordinator
+ (instancetype)sharedInstance { static id controller; if (!controller) controller=[self new]; return controller; }
- (BOOL)_dismissSwitcherNoninteractivelyToAppLayout:(id)layout dismissFloatingSwitcher:(BOOL)floating animated:(BOOL)animated {
    (void)layout; (void)floating; (void)animated; abort(); // ABI check only, never call an action.
}
@end
static id item(NSString *bundle) { ZNSTestDisplayItem *v=[ZNSTestDisplayItem new]; v.bundleIdentifier=bundle; return v; }
int main(void) { @autoreleasepool {
    SEL dismiss=NSSelectorFromString(@"_dismissSwitcherNoninteractivelyToAppLayout:dismissFloatingSwitcher:animated:");
    NSArray *args=@[@(@encode(id)),@(@encode(BOOL)),@(@encode(BOOL))];
    id controller=[SBMainSwitcherControllerCoordinator sharedInstance];
    assert(!ZNSCardSignature(controller,dismiss,@encode(void),args));
    assert(ZNSCardSignature(controller,dismiss,@encode(BOOL),args));
    assert(ZNSCardHomeController()==controller);
    assert([ZNSCardHomeLayout() isKindOfClass:SBAppLayout.class]);
    SBAppLayout *layout=[SBAppLayout new];
    layout.continuousExposeIdentifier=@"scene:not-an-app";
    layout.allItems=@[item(@"test.app.a")];
    assert([ZNSCardBundle(layout) isEqualToString:@"test.app.a"]);
    layout.allItems=[NSSet setWithArray:@[item(@"test.app.a"),item(@"test.app.a")]];
    assert([ZNSCardBundle(layout) isEqualToString:@"test.app.a"]);
    layout.allItems=[NSOrderedSet orderedSetWithObject:item(@"test.app.b")];
    assert([ZNSCardBundle(layout) isEqualToString:@"test.app.b"]);
    layout.allItems=@[item(@"test.app.a"),item(@"test.app.b")];
    assert(ZNSCardBundle(layout)==nil);
    layout.allItems=@[item(@"test.app.a"),[NSObject new]];
    assert(ZNSCardBundle(layout)==nil);
    layout.allItems=@[item(@"not.installed")];
    assert(ZNSCardBundle(layout)==nil);
    layout.allItems=@{@"unexpected":item(@"test.app.a")};
    assert(ZNSCardBundle(layout)==nil);
    layout.allItems=@[];
    assert(ZNSCardBundle(layout)==nil);
    layout.continuousExposeIdentifier=@"test.app.b";
    assert([ZNSCardBundle(layout) isEqualToString:@"test.app.b"]);
    assert(ZNSCardBundle([NSObject new])==nil);
    puts("PASS: 14 production-helper assertions: BOOL dismissal ABI, controller admission, allItems collections, single/multiple/unknown App rejection and fallback. No gestures, scenes or Home actions executed.");
} return 0; }
