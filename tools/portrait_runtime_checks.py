"""macOS-only execution tests; no claim about device/private UIKit behavior."""
import pathlib, subprocess, tempfile, shutil
p=pathlib.Path(__file__).resolve().parents[1]
def run(source,binary):
    subprocess.run(['xcrun','clang','-Wall','-Wextra','-Werror','-fobjc-arc',str(source),'-framework','Foundation','-framework','CoreGraphics','-o',str(binary)],check=True)
    return subprocess.run([str(binary)],capture_output=True,text=True)
with tempfile.TemporaryDirectory() as td:
    tmp=pathlib.Path(td)
    private=(p/'Sources/ZNSPrivate.h').read_text()
    types=private[private.index('static inline const char *ZNSSkipTypeQualifiers'):private.index('static inline NSMethodSignature *ZNSPrivateSignature')]
    scene=(p/'Sources/ZNSSceneSession.m').read_text()
    abi=scene[scene.index('static BOOL ZNSSceneUpdateSignature('):scene.index('static BOOL ZNSHostSetter(')]
    test='''#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <string.h>
#include <assert.h>
'''+types+abi+'''
@interface ZNSGood : NSObject
- (void)updateSettings:(id)s withTransitionContext:(id)c completion:(void (^)(void))b;
@end
@implementation ZNSGood
- (void)updateSettings:(id)s withTransitionContext:(id)c completion:(void (^)(void))b { (void)s; (void)c; (void)b; }
@end
@interface ZNSSubclass : ZNSGood @end
@implementation ZNSSubclass @end
@interface ZNSBadBlock : NSObject
- (void)updateSettings:(id)s withTransitionContext:(id)c completion:(id)b;
@end
@implementation ZNSBadBlock
- (void)updateSettings:(id)s withTransitionContext:(id)c completion:(id)b { (void)s; (void)c; (void)b; }
@end
@interface ZNSBadReturn : NSObject
- (BOOL)updateSettings:(id)s withTransitionContext:(id)c completion:(void (^)(void))b;
@end
@implementation ZNSBadReturn
- (BOOL)updateSettings:(id)s withTransitionContext:(id)c completion:(void (^)(void))b { (void)s; (void)c; (void)b; return YES; }
@end
int main(void) { @autoreleasepool {
 SEL sel=@selector(updateSettings:withTransitionContext:completion:);
 id instance=[ZNSSubclass new];
 assert(ZNSSceneUpdateSignature(object_getClass(instance),sel,5));
 assert(!ZNSSceneUpdateSignature(object_getClass(ZNSGood.class),sel,5));
 assert(!ZNSSceneUpdateSignature(ZNSBadBlock.class,sel,5));
 assert(!ZNSSceneUpdateSignature(ZNSBadReturn.class,sel,5));
 assert(!ZNSSceneUpdateSignature(ZNSGood.class,sel,4));
 assert(!ZNSSceneUpdateSignature(Nil,sel,5));
 puts("PASS actual production ABI: instance object_getClass, inherited method, metaclass rejection, exact block/return/arity; no relaxed validation");
} return 0; }
'''
    src=tmp/'ABI.m';src.write_text(test)
    r=run(src,tmp/'abi');print(r.stdout,end='');assert r.returncode==0,r.stderr
    # Execute the actual integration test with deliberate historical faults.
    # Each variant MUST fail an assertion (not compilation, crash, or timeout).
    (tmp/'tools').mkdir();(tmp/'Sources').mkdir()
    for name in ['PortraitEventTests.m','PortraitSceneTests.m','PortraitVisualTests.inc','PortraitRestoreTests.inc','PortraitHideRetryTests.inc']:
        shutil.copy2(p/'tools'/name,tmp/'tools'/name)
    for name in ['ZNSPortraitCompensation.inc','ZNSGeometry.h','ZNSPortraitRestoreTransaction.inc','ZNSPortraitKeyboardGeometry.h','ZNSPortraitPlacement.inc','ZNSPortraitFloating.inc','ZNSPortraitManager.inc','ZNSPortraitScene.inc','ZNSKeyboardRestore.inc','ZNSPortraitVisibilityEvent.inc','ZNSPortraitVisualEvent.inc']:
        shutil.copy2(p/'Sources'/name,tmp/'Sources'/name)
    faults=[('shown-race','ZNSPortraitPlacement.inc','BOOL continuous=self.portraitCanvasTransitionUntil>CACurrentMediaTime();','BOOL continuous=self.clientKeyboardShown && self.portraitCanvasTransitionUntil>CACurrentMediaTime();'),
            ('shown-expiry','ZNSPortraitPlacement.inc','return visible || self.portraitKeyboardVisibleLatch || continuous;','return visible || continuous;'),
            ('empty-geometry-detach','ZNSPortraitPlacement.inc','if (self.portraitExpansion && (!valid','if (NO && (!valid'),
            ('restore-frame-order','ZNSPortraitFloating.inc','if (ownsFrame) strongSelf.frame=saved;','if (ownsFrame) (void)saved;'),
            ('restore-saved-frame-lost','ZNSPortraitFloating.inc','        return;\n    }\n    CGRect saved=','        self.portraitKeyboardSavedFrame=CGRectZero; return;\n    }\n    CGRect saved='),
            ('restore-hard-jump','ZNSPortraitFloating.inc','if (visualRestore || !ownsFrame || effectiveDuration<=0) {','if (YES) {'),
            ('restore-ignore-options','ZNSPortraitFloating.inc','[UIView animateWithDuration:effectiveDuration delay:0\n            options:options|UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction','[UIView animateWithDuration:effectiveDuration delay:0\n            options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction'),
            ('will-hide-detach','ZNSPortraitPlacement.inc','    if (self.clientKeyboardWillHide) return;','    [self restore]; if (self.clientKeyboardWillHide) return;'),
            ('lifecycle-revalidation','ZNSPortraitScene.inc','if (![self znsOwnsTemporaryPortraitGeneration:generation]) return NO;\n        if (!configured)','if (!configured)'),
            ('window-enumeration-reentry','ZNSPortraitManager.inc','for (ZNSFloatingView *view in [self.windows copy])','for (ZNSFloatingView *view in self.windows)'),
            ('animation-restart','ZNSPortraitFloating.inc','if (self.portraitKeyboardExpanded && CGRectEqualToRect(frame,self.portraitKeyboardTarget)) return;','/* faulty repeated animation */')]
    faults += [
        ('restore-early-clear','ZNSPortraitRestoreTransaction.inc','if (sceneMatches && (sizeAcknowledged || sizeGraceExpired)) {','if (sceneMatches && (sizeAcknowledged || sizeGraceExpired || YES)) {'),
        ('restore-intermediate-host-layout','ZNSPortraitRestoreTransaction.inc','        self.znsPortraitRestoreCompletion=completion;','        self.znsPortraitRestoreCompletion=completion;\n        ZNSConfigureHostCanvas(self.hostView,[desired frame].size,UIInterfaceOrientationPortrait);'),
        ('visual-missing-willhide','ZNSPortraitPlacement.inc','    ZNSPublishPortraitVisualWillHideAsync(self,generation,pid,bundle,duration,options,YES);','    if (NO) ZNSPublishPortraitVisualWillHideAsync(self,generation,pid,bundle,duration,options,YES);'),
        ('visual-synchronous-delivery','ZNSPortraitVisualEvent.inc','dispatch_async(dispatch_get_main_queue(),^{','ZNSVisualSynchronousTest(^{'),
        ('visual-premature-scene-restore','ZNSPortraitFloating.inc','    CGAffineTransform visual=CGAffineTransformMake(','    [self.session restoreTemporaryPortraitCanvas];\n    CGAffineTransform visual=CGAffineTransformMake('),
        ('visual-repeated-animation','ZNSPortraitFloating.inc','(self.portraitKeyboardVisualRestoring && !self.portraitKeyboardVisualReturning)) return;','(NO && self.portraitKeyboardVisualRestoring && !self.portraitKeyboardVisualReturning)) return;'),
        ('visual-transform-not-cleared','ZNSPortraitFloating.inc','    // Own only our transform animation; never remove unrelated layer animations.\n    [self.layer removeAnimationForKey:@"transform"];\n    // Commit the root transform and the child-view counter-transforms in one\n    // no-animation transaction. Clearing compensation in a separate UIKit\n    // transaction exposes one frame where the content has expanded while the\n    // floating window is still visually scaled (the keyboard-dismiss jump).\n    [UIView performWithoutAnimation:^{\n        self.transform=CGAffineTransformIdentity;\n        [self znsClearPortraitCompensation];\n    }];','    // Own only our transform animation; never remove unrelated layer animations.\n    [self.layer removeAnimationForKey:@"transform"];\n    // Commit the root transform and the child-view counter-transforms in one\n    // no-animation transaction. Clearing compensation in a separate UIKit\n    // transaction exposes one frame where the content has expanded while the\n    // floating window is still visually scaled (the keyboard-dismiss jump).\n    [UIView performWithoutAnimation:^{\n        self.transform=self.transform;\n        [self znsClearPortraitCompensation];\n    }];'),
    ]
    faults += [
        ('visual-old-outer-endpoint','ZNSPortraitCompensation.inc','if (enabled) g=ZNSPortraitVisualGeometryMake','if (NO && enabled) g=ZNSPortraitVisualGeometryMake'),
        ('visual-uncleared-descendants','ZNSPortraitCompensation.inc','    [self znsSetPortraitCompensation:NO];','    /* missing compensation cleanup */'),
        ('visual-missing-canvas-fit','ZNSPortraitCompensation.inc','self.canvasContainer.transform=g.canvas;','self.canvasContainer.transform=CGAffineTransformIdentity;'),
        ('visual-prehost-compensation-clear','ZNSPortraitFloating.inc','owner.portraitKeyboardRestoreGeneration==generation)\n            [owner znsClearPortraitCompensation];','owner.portraitKeyboardRestoreGeneration==generation)\n            (void)owner;'),
        ('visual-chrome-pop','ZNSPortraitCompensation.inc','[self znsSetPortraitChromeAlpha:enabled?0:1];','[self znsSetPortraitChromeAlpha:1];'),
    ]
    faults += [
        ('restore-grace-skipped','ZNSPortraitRestoreTransaction.inc','BOOL sizeGraceExpired=attempt>=30;','BOOL sizeGraceExpired=YES;'),
        ('restore-grace-disabled','ZNSPortraitRestoreTransaction.inc','BOOL sizeGraceExpired=attempt>=30;','BOOL sizeGraceExpired=NO;'),
        ('restore-scene-bypassed','ZNSPortraitRestoreTransaction.inc','if (sceneMatches && (sizeAcknowledged || sizeGraceExpired)) {','if ((sceneMatches && sizeAcknowledged) || sizeGraceExpired) {'),
        ('hide-retry-missing','ZNSPortraitFloating.inc','[owner znsAttemptPortraitHideRestore:attempt+1 token:token];','(void)attempt;'),
        ('hide-retry-stale-owner','ZNSPortraitFloating.inc','!guard || !guard()) return;','!guard) return;'),
        ('hide-retry-exhaustion-fake-success','ZNSPortraitFloating.inc','[self restorePortraitKeyboardWithDuration:0 options:0];\n        return;\n    }\n    NSUInteger generation=self.portraitKeyboardRestoreGeneration;','self.portraitKeyboardExpanded=NO;\n        return;\n    }\n    NSUInteger generation=self.portraitKeyboardRestoreGeneration;'),
    ]
    for name,file,old,new in faults:
        f=tmp/'Sources'/file;original=f.read_text();assert original.count(old)==1
        f.write_text(original.replace(old,new))
        testfile='PortraitSceneTests.m' if name in ('restore-grace-skipped','restore-grace-disabled','restore-scene-bypassed','restore-early-clear') else 'PortraitEventTests.m'
        r=run(tmp/'tools'/testfile,tmp/name)
        (p/'build'/('mutation-'+name+'.log')).write_text(r.stdout+r.stderr)
        assert r.returncode!=0 and 'Assertion' in r.stderr,(name,r.returncode,r.stderr)
        print('PASS regression detector rejects',name,'with assertion failure')
        f.write_text(original)
    scene_faults=[
        ('scene-unconditional-timeout-restore','if ([owner znsTemporaryPortraitStateMatchesFrame:frame]) {','if (NO) {'),
        ('scene-strict-frame-equality','ZNSGeometryRectNear([applied frame],frame)','CGRectEqualToRect([applied frame],frame)'),
    ]
    for name,old,new in scene_faults:
        f=tmp/'Sources/ZNSPortraitScene.inc';original=f.read_text();assert original.count(old)==1
        f.write_text(original.replace(old,new))
        r=run(tmp/'tools/PortraitSceneTests.m',tmp/name)
        (p/'build'/('mutation-'+name+'.log')).write_text(r.stdout+r.stderr)
        assert r.returncode!=0 and 'Assertion' in r.stderr,(name,r.returncode,r.stderr)
        print('PASS scene acknowledgment regression detector rejects',name,'with assertion failure')
        f.write_text(original)
