"""Run the actual production canvas hook blocks with a bounded mock UIKit scheduler.
Foundation/runtime host test, NOT private SpringBoard or appearance device proof.
"""
import pathlib, subprocess, tempfile
p=pathlib.Path(__file__).resolve().parents[1]
s=(p/'Sources/ZNSLandscapeIconGrid.m').read_text()
hook=s[s.index('static void ZNSCanvasHook('):s.index('static BOOL ZNSCanvasOwnsGeometry(')]
pre=r'''#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <assert.h>
#include <string.h>
@interface UIView : NSObject
@property(nonatomic) BOOL hidden,dirty,userInteractionEnabled,accessibilityElementsHidden;
@property(nonatomic) double alpha;
@property(nonatomic,strong) id window;
@property(nonatomic,weak) UIView *dockOwner;
@property(nonatomic) NSUInteger layouts;
- (void)layoutSubviews;
- (void)setNeedsLayout;
- (void)didMoveToWindow;
+ (void)performWithoutAnimation:(void (^)(void))block;
@end
@implementation UIView
- (void)layoutSubviews { self.layouts++; }
- (void)setNeedsLayout { self.dirty=YES; }
- (void)didMoveToWindow {}
+ (void)performWithoutAnimation:(void (^)(void))block { block(); }
@end
@interface SBIconListView : UIView @end
@implementation SBIconListView @end
@interface SBDockView : UIView
@property(nonatomic,strong) SBIconListView *list;
@end
@implementation SBDockView
- (void)layoutSubviews {
 [super layoutSubviews];
 // Model UIKit internal child dirtiness, not an external setNeedsLayout send.
 self.list.dirty=YES;
}
@end
@interface ZNSCanvasState : NSObject
@property(nonatomic) double alpha;
@property(nonatomic,strong) UIView *canvas;
@end
@implementation ZNSCanvasState @end
static char ZNSCanvasBusyKey,ZNSCanvasStateKey;
static NSHashTable *ZNSCanvasOwners;
static NSUInteger restored,applied;
static BOOL ZNSCanvasRootList(UIView *v) { return !v.dockOwner; }
static UIView *ZNSCanvasDock(UIView *v) { return v.dockOwner; }
static void ZNSCanvasRestore(UIView *v) { (void)v; restored++; }
static NSArray *ZNSCanvasFind(UIView *v,NSString *name) { (void)name; return @[((SBDockView *)v).list]; }
static void ZNSCanvasApply(UIView *v,UIView *list,BOOL dock) { (void)v;(void)list;(void)dock;applied++; }
static void MSHookMessageEx(Class cls,SEL sel,IMP replacement,IMP *original) {
 Method m=class_getInstanceMethod(cls,sel); *original=method_getImplementation(m);
 if(!class_addMethod(cls,sel,replacement,method_getTypeEncoding(m))) method_setImplementation(class_getInstanceMethod(cls,sel),replacement);
}
'''
post=r'''
static NSUInteger drain(SBDockView *dock) {
 NSUInteger count=0;
 while((dock.dirty || dock.list.dirty) && count<32) {
  if(dock.dirty) { dock.dirty=NO; [dock layoutSubviews]; count++; }
  if(dock.list.dirty) { dock.list.dirty=NO; [dock.list layoutSubviews]; count++; }
 }
 assert(!dock.dirty && !dock.list.dirty); // catches the old cross-pass cycle
 return count;
}
int main(void) { @autoreleasepool {
 ZNSCanvasOwners=[NSHashTable weakObjectsHashTable];
 ZNSCanvasHook(@"SBIconListView",NO); ZNSCanvasHook(@"SBDockView",YES);
 SBDockView *dock=[SBDockView new]; SBIconListView *list=[SBIconListView new];
 dock.list=list; list.dockOwner=dock;
 // Appearance-induced native list layout must not invalidate the Dock.
 [list setNeedsLayout]; assert(!dock.dirty); assert(drain(dock)==1);
 // Native Dock -> list pass must settle even when there is NO active canvas.
 [dock setNeedsLayout]; assert(drain(dock)==2);
 ZNSCanvasState *state=[ZNSCanvasState new]; state.canvas=[UIView new];
 objc_setAssociatedObject(dock,&ZNSCanvasStateKey,state,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
 // A real external child mutation must still invalidate the mounted owner.
 [list setNeedsLayout]; assert(dock.dirty); assert(drain(dock)==2);
 // Repeated appearance invalidation must settle, not defer an endless loop.
 for(NSUInteger i=0;i<100;i++) { [dock setNeedsLayout]; assert(drain(dock)==2); }
 assert(!objc_getAssociatedObject(dock,&ZNSCanvasBusyKey));
 // Mutation during restore/layout/apply cannot schedule another pass.
 objc_setAssociatedObject(dock,&ZNSCanvasBusyKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
 [list setNeedsLayout]; assert(!list.dirty && !dock.dirty);
 objc_setAssociatedObject(dock,&ZNSCanvasBusyKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
 // Teardown returns to native, non-propagating invalidation.
 objc_setAssociatedObject(dock,&ZNSCanvasStateKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
 [list setNeedsLayout]; assert(!dock.dirty); assert(drain(dock)==1);
 assert(restored>0 && applied>0 && list.layouts>100);
 puts("PASS production hook: appearance/no canvas, mounted external invalidation, 100 settled passes, busy suppression, teardown");
 } return 0; }
'''
with tempfile.TemporaryDirectory() as td:
 d=pathlib.Path(td)
 for name,body,should_pass in [('current',hook,True),('old-layout-feedback',hook.replace('            // Native child layout is an effect, not an invalidation request.', '            UIView *dockOwner=ZNSCanvasDock(view);\n            if(dockOwner && ![objc_getAssociatedObject(dockOwner,&ZNSCanvasBusyKey) boolValue]) [dockOwner setNeedsLayout];\n            // Native child layout is an effect, not an invalidation request.'),False),('lost-external-invalidation',hook.replace('            [dockOwner setNeedsLayout];','            (void)dockOwner;'),False)]:
  f=d/(name+'.m');exe=d/name;f.write_text(pre+body+post)
  subprocess.run(['xcrun','clang','-Wall','-Wextra','-Werror','-fobjc-arc',str(f),'-framework','Foundation','-o',str(exe)],check=True)
  r=subprocess.run([str(exe)],capture_output=True,text=True,timeout=10)
  (p/'build').mkdir(exist_ok=True)
  (p/'build'/('dark-mode-'+name+'.log')).write_text(r.stdout+r.stderr)
  if should_pass:
   assert r.returncode==0,r.stderr
   print(r.stdout,end='')
  else:
   assert r.returncode!=0 and 'Assertion' in r.stderr,(name,r.returncode,r.stderr)
   print('PASS mutation detector rejects',name,'with assertion failure')
