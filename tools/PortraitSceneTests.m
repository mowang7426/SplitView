// Host-native executable: runs the SAME production .inc, not a second model.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <CoreGraphics/CoreGraphics.h>
#import "../Sources/ZNSPortraitKeyboardGeometry.h"
#include <assert.h>
#include <stdio.h>
static NSMutableArray *ZNSReady,*ZNSDeadlines;
static void ZNSEnqueue(void (^block)(void),BOOL timeout) {
    [(timeout?ZNSDeadlines:ZNSReady) addObject:[block copy]];
}
#define dispatch_async(queue,block) ZNSEnqueue(block,NO)
#define dispatch_after(when,queue,block) ZNSEnqueue(block,YES)
#define os_log_error(...) do {} while(0)
#define os_log(...) do {} while(0)
#define UIInterfaceOrientationPortrait 1
@interface ZNSTempSettings : NSObject <NSCopying,NSMutableCopying>
@property(nonatomic) CGRect frame;
@property(nonatomic) NSInteger interfaceOrientation;
@property(nonatomic) BOOL backgrounded;
@property(nonatomic) NSInteger unrelated;
@end
@implementation ZNSTempSettings
- (id)copyWithZone:(NSZone *)zone {
    ZNSTempSettings *copy=[[[self class] allocWithZone:zone] init];
    copy.frame=self.frame; copy.interfaceOrientation=self.interfaceOrientation;
    copy.backgrounded=self.backgrounded; copy.unrelated=self.unrelated; return copy;
}
- (id)mutableCopyWithZone:(NSZone *)zone { return [self copyWithZone:zone]; }
@end
@interface ZNSTempScene : NSObject
@property(nonatomic,strong) ZNSTempSettings *settings;
@property(nonatomic,strong) NSMutableArray *pending;
@property(nonatomic) BOOL throwNext,dropApplyNext,deferApply;
@property(nonatomic,strong) ZNSTempSettings *submittedSettings;
@property(nonatomic) NSUInteger updates;
@property(nonatomic,strong) id lastContext;
@property(nonatomic,copy) void (^onUpdate)(void);
- (void)updateSettings:(id)settings withTransitionContext:(id)context completion:(void (^)(void))done;
@end
@implementation ZNSTempScene
- (instancetype)init { if((self=[super init])) _pending=[NSMutableArray new]; return self; }
- (void)updateSettings:(id)settings withTransitionContext:(id)context completion:(void (^)(void))done {
    self.lastContext=context; self.updates++;
    if (self.onUpdate) self.onUpdate();
    if(self.throwNext) { self.throwNext=NO; [NSException raise:@"test.submit" format:@"rejected"]; }
    self.submittedSettings=[settings copy];
    if(self.dropApplyNext) self.dropApplyNext=NO; else if(!self.deferApply) self.settings=[settings copy];
    if(done) [self.pending addObject:[done copy]];
}
@end
@interface ZNSTempHost : NSObject
@property(nonatomic) CGSize referenceSize;
@property(nonatomic) NSInteger orientation;
@property(nonatomic) CGRect bounds;
@property(nonatomic) CGPoint position;
@property(nonatomic) CGAffineTransform transform;
@property(nonatomic) BOOL rejectNext;
@property(nonatomic,copy) void (^onConfigure)(void);
@end
@implementation ZNSTempHost @end
@interface ZNSTempLease : NSObject
@property(nonatomic,strong) ZNSTempSettings *settings;
@end
@implementation ZNSTempLease @end
@interface ZNSTempKeyboard : NSObject
@property(nonatomic) CGSize canvas,clientWindowSize,expectedRestoreSize;
@property(nonatomic) uint64_t restoreRequest,restoreReply;
- (uint64_t)znsRequestRestoreSize:(CGSize)size;
- (BOOL)znsRestoreSizeMatches:(uint64_t)request;
@property(nonatomic) NSUInteger requests;
@property(nonatomic,strong) id focusProof;
- (void)updateTemporaryPortraitCanvas:(CGSize)canvas;
- (void)requestPortraitClientGeometry;
- (void)znsBeginPortraitGeometryRefresh;
@end
@implementation ZNSTempKeyboard
- (uint64_t)znsRequestRestoreSize:(CGSize)size {
    self.expectedRestoreSize=size; return ++self.restoreRequest;
}
- (BOOL)znsRestoreSizeMatches:(uint64_t)request {
    return request && request==self.restoreReply && request==self.restoreRequest && CGSizeEqualToSize(self.clientWindowSize,self.expectedRestoreSize);
}
- (void)znsBeginPortraitGeometryRefresh {}
- (void)updateTemporaryPortraitCanvas:(CGSize)canvas { self.canvas=canvas; self.requests++; }
- (void)requestPortraitClientGeometry { self.requests++; }
@end
static void ZNSRunPortraitHandoff(void (^block)(void)) { block(); }
static BOOL ZNSValidCanvasSize(CGSize s) { return isfinite(s.width)&&isfinite(s.height)&&s.width>0&&s.height>0; }
static id ZNSGet(id obj,NSString *key) { return [obj valueForKey:key]; }
static BOOL ZNSSettingsReadAPI(id obj) { return [obj isKindOfClass:ZNSTempSettings.class]; }
static BOOL ZNSSettingsWriteAPI(id obj) { return ZNSSettingsReadAPI(obj); }
static BOOL ZNSRequireABI(id obj,SEL selector,const char *result,const char *const *args,NSUInteger count,NSString *stage) {
    (void)result; (void)args; (void)count; (void)stage; return [obj respondsToSelector:selector];
}
static BOOL ZNSSceneUpdateSignature(Class cls,SEL sel,NSUInteger args) {
    return args==5 && [cls instancesRespondToSelector:sel];
}
static BOOL ZNSHostCanvasAPI(ZNSTempHost *host) { return host!=nil; }
static BOOL ZNSGeometryScalarNear(CGFloat actual,CGFloat desired) {
    return isfinite(actual) && isfinite(desired) && fabs(actual-desired)<=0.5;
}
static BOOL ZNSGeometrySizeNear(CGSize actual,CGSize desired) {
    return ZNSGeometryScalarNear(actual.width,desired.width) && ZNSGeometryScalarNear(actual.height,desired.height);
}
static BOOL ZNSGeometryRectNear(CGRect actual,CGRect desired) {
    return ZNSGeometryScalarNear(actual.origin.x,desired.origin.x) && ZNSGeometryScalarNear(actual.origin.y,desired.origin.y) &&
        ZNSGeometrySizeNear(actual.size,desired.size);
}
static BOOL ZNSHostCanvasMatches(ZNSTempHost *host,CGSize size,NSInteger orientation) {
    CGRect projection=CGRectApplyAffineTransform((CGRect){CGPointZero,host.bounds.size},host.transform);
    CGSize projected=CGSizeMake(fabs(projection.size.width),fabs(projection.size.height));
    return host && host.orientation==orientation && ZNSGeometrySizeNear(host.referenceSize,size) && ZNSGeometrySizeNear(projected,size);
}
static BOOL ZNSConfigureHostCanvas(ZNSTempHost *host,CGSize size,NSInteger orientation) {
    assert(orientation==1);
    if(host.rejectNext) { host.rejectNext=NO; return NO; }
    if(host.onConfigure) { void (^callback)(void)=host.onConfigure; host.onConfigure=nil; callback(); }
    host.referenceSize=size; host.orientation=orientation; host.bounds=(CGRect){CGPointZero,size};
    host.position=CGPointMake(size.width/2,size.height/2); return YES;
}
@interface ZNSSceneSession : NSObject
@property(nonatomic,copy) NSString *bundleIdentifier;
@property(nonatomic) BOOL stopped,deviceLockRequested,switcherRemovalRequested,layoutInFlight,landscape,changedSettings;
@property(nonatomic,strong) ZNSTempHost *hostView;
@property(nonatomic,strong) ZNSTempLease *lease;
@property(nonatomic,strong) ZNSTempScene *scene;
@property(nonatomic,strong) ZNSTempKeyboard *keyboardPlacement;
@property(nonatomic) CGSize canvasSize,temporaryPortraitCanvas;
@property(nonatomic,copy) void (^znsPortraitRestorePrepareVisual)(void);
@property(nonatomic) CGRect temporaryPortraitFrame;
@property(nonatomic) BOOL znsPortraitHandoffInFlight;
@property(nonatomic) BOOL znsPortraitRestorePending;
@property(nonatomic) uint64_t znsPortraitRestoreRequest;
@property(nonatomic) CGRect znsPortraitRestoreExpandedFrame;
@property(nonatomic,copy) void (^znsPortraitRestoreCompletion)(BOOL);
- (BOOL)znsRestorePortraitAfterHide:(void (^)(BOOL))completion;
- (BOOL (^)(void))znsPortraitRestoreSessionGuard;
- (BOOL)znsPortraitRestoreGateBusy;
- (void)znsCancelPortraitRestore;
- (void)znsPollPortraitRestore:(NSUInteger)generation attempt:(NSUInteger)attempt;
- (void)znsFailPortraitRestore:(NSUInteger)generation;
@property(nonatomic,strong) id temporaryPortraitSettings;
@property(nonatomic) NSUInteger temporaryPortraitGeneration,layoutGeneration;
@property(nonatomic) BOOL temporaryPortraitPending,temporaryPortraitRestoring;
@property(nonatomic,copy) void (^temporaryPortraitFailure)(void);
- (BOOL)znsTemporaryPortraitStateMatchesFrame:(CGRect)frame;
- (BOOL)applyTemporaryPortraitFrame:(CGRect)frame failure:(void (^)(void))failure;
- (BOOL)restoreTemporaryPortraitCanvas;
- (BOOL)restoreTemporaryPortraitCanvasWithDuration:(NSTimeInterval)duration options:(NSUInteger)options;
@end
@implementation ZNSSceneSession
#include "../Sources/ZNSPortraitScene.inc"
@end
static void Drain(NSMutableArray *queue) {
    while(queue.count) { void (^block)(void)=queue.firstObject; [queue removeObjectAtIndex:0]; block(); }
}
static void Ack(ZNSSceneSession *s) { Drain(s.scene.pending); Drain(ZNSReady); }
static ZNSSceneSession *New(void) {
    ZNSSceneSession *s=[ZNSSceneSession new]; s.scene=[ZNSTempScene new];
    ZNSTempSettings *settings=[ZNSTempSettings new]; settings.frame=CGRectMake(0,0,390,844);
    settings.interfaceOrientation=1; settings.backgrounded=NO; settings.unrelated=77;
    s.scene.settings=[settings copy]; s.lease=[ZNSTempLease new]; s.lease.settings=[settings copy];
    s.hostView=[ZNSTempHost new]; s.hostView.transform=CGAffineTransformIdentity;
    s.canvasSize=settings.frame.size; ZNSConfigureHostCanvas(s.hostView,s.canvasSize,1);
    s.keyboardPlacement=[ZNSTempKeyboard new]; s.keyboardPlacement.focusProof=[NSObject new];
    return s;
}
static void Original(ZNSSceneSession *s) {
    assert(CGRectEqualToRect(s.scene.settings.frame,CGRectMake(0,0,390,844)));
    assert(CGSizeEqualToSize(s.canvasSize,CGSizeMake(390,844)));
    assert(CGSizeEqualToSize(s.hostView.referenceSize,s.canvasSize));
    assert(CGAffineTransformIsIdentity(s.hostView.transform));
    assert(!s.temporaryPortraitSettings && !s.temporaryPortraitPending);
}
#include "PortraitRestoreTests.inc"
int main(void) { @autoreleasepool {
    ZNSReady=[NSMutableArray new]; ZNSDeadlines=[NSMutableArray new];
    RestoreTransactionTests();
    ZNSPortraitKeyboardLayout layout;
    CGRect keyboard=CGRectMake(0,510,390,334), screen=CGRectMake(0,0,390,844);
    assert(ZNSPortraitKeyboardLayoutMake(keyboard,screen,47,&layout));
    assert(layout.frame.origin.y==152 && layout.canvas.width==390 && layout.canvas.height==692);
    ZNSSceneSession *s=New(); id proof=s.keyboardPlacement.focusProof;
    __block unsigned failures=0;
    assert([s applyTemporaryPortraitFrame:layout.frame failure:^{failures++;}]);
    assert(s.temporaryPortraitPending && s.temporaryPortraitSettings);
    assert(CGRectEqualToRect(s.scene.settings.frame,layout.frame));
    assert(CGSizeEqualToSize(s.hostView.referenceSize,layout.canvas));
    assert(s.scene.settings.unrelated==77 && !s.scene.settings.backgrounded);
    assert(s.keyboardPlacement.focusProof==proof);
    Ack(s); assert(!failures && !s.temporaryPortraitPending);
    assert(s.keyboardPlacement.requests>=2);
    // Native keyboard avoidance owns the only keyboard-height subtraction.
    // A responder/input bar at this scene y maps EXACTLY to screen keyboard top.
    CGPoint input=ZNSPortraitScreenToScene(CGPointMake(195,510),s.scene.settings.frame);
    assert(input.y==layout.inputBottom && input.y+s.scene.settings.frame.origin.y==510);
    assert(layout.canvas.height-layout.keyboardInScene.size.height==input.y);
    assert(CGAffineTransformIsIdentity(ZNSPortraitCanvasTransform()));
    assert(layout.canvas.width==screen.size.width); // real content width, not just frame
    // Prediction/emoji changes do not change the scene or subtract height twice.
    ZNSPortraitKeyboardLayout emoji;
    assert(ZNSPortraitKeyboardLayoutMake(CGRectMake(0,470,390,374),screen,47,&emoji));
    assert(CGRectEqualToRect(emoji.frame,layout.frame));
    NSUInteger generation=s.temporaryPortraitGeneration;
    assert([s applyTemporaryPortraitFrame:emoji.frame failure:nil]);
    assert(s.temporaryPortraitGeneration==generation);
    assert(emoji.inputBottom+emoji.frame.origin.y==470);
    assert([s restoreTemporaryPortraitCanvas]); Ack(s); Original(s);
    assert(s.keyboardPlacement.focusProof==proof);
    Drain(ZNSDeadlines); Drain(ZNSReady); assert(!failures);
    // Hide/drag/rotation before ack: stale show callback cannot re-expand.
    s=New(); assert([s applyTemporaryPortraitFrame:layout.frame failure:^{failures++;}]);
    assert([s restoreTemporaryPortraitCanvas]); Ack(s); Original(s);
    Drain(ZNSDeadlines); assert(!failures);
    // A normal callback accepts bounded system frame normalization.
    s=New(); assert([s applyTemporaryPortraitFrame:layout.frame failure:^{failures++;}]);
    s.scene.settings.frame=CGRectMake(layout.frame.origin.x+0.5,layout.frame.origin.y-0.25,
        layout.frame.size.width-0.25,layout.frame.size.height+0.5);
    Ack(s); assert(!s.temporaryPortraitPending && failures==0);
    assert([s restoreTemporaryPortraitCanvas]); Ack(s); Original(s);
    // Lost/delayed callback with already-applied production state is inferred
    // at timeout and kept expanded. A later mismatching callback is obsolete.
    s=New(); assert([s applyTemporaryPortraitFrame:layout.frame failure:^{failures++;}]);
    Drain(ZNSDeadlines); Drain(ZNSReady);
    assert(!s.temporaryPortraitPending && s.temporaryPortraitSettings && failures==0);
    s.scene.settings.frame=CGRectMake(0,0,390,844);
    Ack(s); assert(s.temporaryPortraitSettings && failures==0);
    assert([s restoreTemporaryPortraitCanvas]); Ack(s); Original(s);
    // A truly unapplied transaction still takes the safe timeout rollback.
    s=New(); s.scene.dropApplyNext=YES;
    assert([s applyTemporaryPortraitFrame:layout.frame failure:^{failures++;}]);
    Drain(ZNSDeadlines); Drain(ZNSReady); Ack(s); Original(s); assert(failures==1);
    // A callback outside the bounded normalization tolerance still rolls back.
    s=New(); assert([s applyTemporaryPortraitFrame:layout.frame failure:^{failures++;}]);
    s.scene.settings.frame=CGRectMake(layout.frame.origin.x,layout.frame.origin.y+0.51,
        layout.frame.size.width,layout.frame.size.height);
    Ack(s); Original(s); assert(failures==2);
    // Host API refuses: no half-applied temporary canvas remains.
    s=New(); s.hostView.rejectNext=YES;
    assert(![s applyTemporaryPortraitFrame:layout.frame failure:nil]); Ack(s); Original(s);
    // Submit exception during show rolls back.
    s=New(); s.scene.throwNext=YES;
    assert(![s applyTemporaryPortraitFrame:layout.frame failure:nil]); Ack(s); Original(s);
    // Restore submission fails: retain exact snapshot and allow explicit retry.
    s=New(); assert([s applyTemporaryPortraitFrame:layout.frame failure:nil]); Ack(s);
    s.scene.throwNext=YES; assert(![s restoreTemporaryPortraitCanvas]);
    assert(s.temporaryPortraitSettings); assert([s restoreTemporaryPortraitCanvas]); Ack(s); Original(s);
    // Lifecycle changes supersede temporary callbacks and clear snapshots.
    for(unsigned kind=0;kind<3;kind++) {
        s=New(); assert([s applyTemporaryPortraitFrame:layout.frame failure:^{failures++;}]);
        if(kind==0) s.stopped=YES;
        if(kind==1) s.deviceLockRequested=YES;
        if(kind==2) s.switcherRemovalRequested=YES;
        assert([s restoreTemporaryPortraitCanvas]); Ack(s);
        assert(!s.temporaryPortraitSettings && !s.temporaryPortraitPending);
    }
    Drain(ZNSDeadlines); assert(failures==2);
    // Synchronous host lifecycle callback must not be followed by an obsolete
    // scene update. These execute production checks, not a success-only stub.
    for(unsigned kind=0;kind<3;kind++) {
        s=New(); __weak ZNSSceneSession *weakSession=s;
        s.hostView.onConfigure=^{
            ZNSSceneSession *owner=weakSession;
            if(kind==0) owner.stopped=YES;
            if(kind==1) owner.deviceLockRequested=YES;
            if(kind==2) owner.switcherRemovalRequested=YES;
        };
        assert(![s applyTemporaryPortraitFrame:layout.frame failure:nil]);
        assert(s.scene.updates==0 && CGSizeEqualToSize(s.canvasSize,CGSizeMake(390,844)));
        assert([s restoreTemporaryPortraitCanvas]);
        assert(!s.temporaryPortraitSettings && !s.temporaryPortraitPending);
    }
    // Restore host callbacks cannot recursively submit restore or expansion.
    s=New(); assert([s applyTemporaryPortraitFrame:layout.frame failure:nil]); Ack(s);
    __weak ZNSSceneSession *weakSession=s;
    NSUInteger before=s.scene.updates;
    s.hostView.onConfigure=^{
        ZNSSceneSession *owner=weakSession;
        assert(![owner restoreTemporaryPortraitCanvas]);
        assert(![owner applyTemporaryPortraitFrame:layout.frame failure:nil]);
    };
    assert([s restoreTemporaryPortraitCanvas]); Ack(s); Original(s);
    assert(s.scene.updates==before+1 && !s.temporaryPortraitRestoring && !s.scene.lastContext);
    // A lock during restore submission must not clear recovery state or report
    // success. Unlocked explicit retry is still possible.
    s=New(); assert([s applyTemporaryPortraitFrame:layout.frame failure:nil]); Ack(s);
    weakSession=s;
    s.scene.onUpdate=^{ weakSession.deviceLockRequested=YES; };
    assert(![s restoreTemporaryPortraitCanvas]);
    assert(s.temporaryPortraitSettings && !s.temporaryPortraitRestoring);
    s.scene.onUpdate=nil; s.deviceLockRequested=NO;
    assert([s restoreTemporaryPortraitCanvas]); Ack(s); Original(s);
    // Landscape, in-flight normal resize, invalid frame: never enter temp path.
    s=New(); s.landscape=YES; assert(![s applyTemporaryPortraitFrame:layout.frame failure:nil]);
    s.landscape=NO; s.layoutInFlight=YES; assert(![s applyTemporaryPortraitFrame:layout.frame failure:nil]);
    s.layoutInFlight=NO; assert(![s applyTemporaryPortraitFrame:CGRectMake(NAN,0,390,692) failure:nil]);
    Original(s);
    puts("PASS production temporary scene transaction: tolerant callback ack, inferred applied-state timeout, true stale rollback, obsolete late callback, lifecycle cancellation, content/reference width and preserved focus; mock host only, NOT device rendering");
    return 0;
} }
