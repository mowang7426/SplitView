#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <math.h>
#import <string.h>
#import "ZNSDesktopRotation.h"
#import "ZNSLandscapeStatusLayout.h"

static NSHashTable<UIView *> *ZNSLandscapeStatusBars;
static char ZNSStatusPositionKey,ZNSStatusLayoutBusyKey;

@interface ZNSStatusPosition : NSObject
@property(nonatomic,weak) UIView *parent;
@property(nonatomic) CGPoint nativeCenter;
@property(nonatomic) CGPoint placedCenter;
@end
@implementation ZNSStatusPosition
@end

// Read only explicit object-valued status-region accessors/ivars. No KVC,
// text matching, duplicate clock/battery views, or device-type spoofing.
static id ZNSStatusMember(id object,NSString *name) {
    if(!object) return nil;
    @try {
        SEL selector=NSSelectorFromString(name);
        Method method=class_getInstanceMethod(object_getClass(object),selector);
        char type[32]={0};
        if(method) method_getReturnType(method,type,sizeof(type));
        if(method && method_getNumberOfArguments(method)==2 && type[0]=='@')
            return ((id(*)(id,SEL))objc_msgSend)(object,selector);
        Ivar ivar=class_getInstanceVariable(object_getClass(object),name.UTF8String);
        const char *encoding=ivar?ivar_getTypeEncoding(ivar):NULL;
        if(encoding && encoding[0]=='@') return object_getIvar(object,ivar);
    } @catch(NSException *exception) { (void)exception; }
    return nil;
}
static UIView *ZNSStatusRegionView(UIView *bar,BOOL leading) {
    NSArray<NSString *> *names=leading?
        @[@"leadingRegion",@"_leadingRegion",@"leadingView",@"_leadingView"]:
        @[@"trailingRegion",@"_trailingRegion",@"trailingView",@"_trailingView"];
    for(NSString *name in names) {
        id region=ZNSStatusMember(bar,name);
        if([region isKindOfClass:UIView.class] && region!=bar && [region isDescendantOfView:bar]) return region;
        for(NSString *key in @[@"contentView",@"_contentView",@"containerView",@"_containerView",@"view",@"_view"]) {
            id view=ZNSStatusMember(region,key);
            if([view isKindOfClass:UIView.class] && view!=bar && [view isDescendantOfView:bar]) return view;
        }
    }
    return nil;
}
static void ZNSRestoreStatusRegion(UIView *view) {
    ZNSStatusPosition *saved=objc_getAssociatedObject(view,&ZNSStatusPositionKey);
    if(!saved) return;
    // Do not overwrite geometry already changed by UIKit or another tweak.
    if(view.superview==saved.parent && CGPointEqualToPoint(view.center,saved.placedCenter))
        view.center=saved.nativeCenter;
    objc_setAssociatedObject(view,&ZNSStatusPositionKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static BOOL ZNSStatusRectValid(CGRect rect) {
    return !CGRectIsNull(rect) && !CGRectIsInfinite(rect) &&
        isfinite(rect.origin.x) && isfinite(rect.origin.y) &&
        isfinite(rect.size.width) && isfinite(rect.size.height) && rect.size.width>1 && rect.size.height>1;
}
static BOOL ZNSStatusTargetVisible(UIView *view,CGRect target,UIWindowScene *scene) {
    for(UIView *ancestor=view.superview;ancestor;ancestor=ancestor.superview) {
        if(ancestor.hidden || ancestor.alpha<0.01) return NO;
        if(ancestor.clipsToBounds) {
            CGRect clip=[ancestor convertRect:ancestor.bounds toCoordinateSpace:scene.coordinateSpace];
            if(!CGRectContainsRect(CGRectInset(clip,-1,-1),target)) return NO;
        }
    }
    return YES;
}
static void ZNSPlaceStatusRegion(UIView *view,CGRect current,CGRect target,UIWindowScene *scene) {
    UIView *parent=view.superview;
    CGPoint oldPoint=[parent convertPoint:CGPointMake(CGRectGetMidX(current),CGRectGetMidY(current)) fromCoordinateSpace:scene.coordinateSpace];
    CGPoint newPoint=[parent convertPoint:CGPointMake(CGRectGetMidX(target),CGRectGetMidY(target)) fromCoordinateSpace:scene.coordinateSpace];
    ZNSStatusPosition *saved=[ZNSStatusPosition new];
    saved.parent=parent; saved.nativeCenter=view.center;
    saved.placedCenter=CGPointMake(view.center.x+newPoint.x-oldPoint.x,view.center.y+newPoint.y-oldPoint.y);
    objc_setAssociatedObject(view,&ZNSStatusPositionKey,saved,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    view.center=saved.placedCenter;
}
static void ZNSLayoutLandscapeStatus(UIView *bar) {
    UIWindow *window=bar.window; UIWindowScene *scene=window.windowScene;
    if(!ZNSDesktopRotationIsEnabled() || !scene || window.screen!=UIScreen.mainScreen ||
       !UIInterfaceOrientationIsLandscape(scene.interfaceOrientation) || bar.hidden || bar.alpha<0.01) return;
    // Do not touch the plugin's App host, keyboard window, or the Lock Screen.
    for(NSString *name in @[@"ZNSOverlayWindow",@"ZNSKeyboardWindow"]) {
        Class cls=NSClassFromString(name);
        if(cls && [window isKindOfClass:cls]) return;
    }
    id lock=ZNSStatusMember(NSClassFromString(@"SBLockScreenManager"),@"sharedInstance");
    SEL locked=NSSelectorFromString(@"isUILocked");
    Method lockMethod=lock?class_getInstanceMethod(object_getClass(lock),locked):NULL;
    char lockType[16]={0}; if(lockMethod) method_getReturnType(lockMethod,lockType,sizeof(lockType));
    if(!lockMethod || method_getNumberOfArguments(lockMethod)!=2 || strcmp(lockType,@encode(BOOL)) ||
       ((BOOL(*)(id,SEL))objc_msgSend)(lock,locked)) return;
    UIView *left=ZNSStatusRegionView(bar,YES),*right=ZNSStatusRegionView(bar,NO);
    if(!left || !right || left==right || [left isDescendantOfView:right] || [right isDescendantOfView:left] ||
       left.hidden || right.hidden || left.alpha<0.01 || right.alpha<0.01) return;
    CGRect screen=scene.coordinateSpace.bounds;
    CGRect l=[left convertRect:left.bounds toCoordinateSpace:scene.coordinateSpace];
    CGRect r=[right convertRect:right.bounds toCoordinateSpace:scene.coordinateSpace];
    if(!ZNSStatusRectValid(screen) || screen.size.width<=screen.size.height ||
       !ZNSStatusRectValid(l) || !ZNSStatusRectValid(r) ||
       l.size.width>screen.size.width*0.45 || r.size.width>screen.size.width*0.45 ||
       l.size.height>60 || r.size.height>60) return;
    UIEdgeInsets safe=window.safeAreaInsets;
    for(UIWindow *candidate in scene.windows) {
        if(candidate.hidden || candidate.screen!=window.screen) continue;
        CGRect area=[candidate convertRect:candidate.bounds toCoordinateSpace:scene.coordinateSpace];
        if(area.size.width<screen.size.width*0.9 || area.size.height<screen.size.height*0.9) continue;
        safe.left=MAX(safe.left,candidate.safeAreaInsets.left);
        safe.right=MAX(safe.right,candidate.safeAreaInsets.right);
        safe.top=MAX(safe.top,candidate.safeAreaInsets.top);
    }
    CGFloat usable=screen.size.width-safe.left-safe.right;
    CGFloat margin=MAX(12,usable*0.025);
    CGFloat centerY=CGRectGetMinY(screen)+safe.top+4+MAX(l.size.height,r.size.height)/2;
    CGRect targetLeft=CGRectMake(CGRectGetMinX(screen)+safe.left+margin,centerY-l.size.height/2,l.size.width,l.size.height);
    CGRect targetRight=CGRectMake(CGRectGetMaxX(screen)-safe.right-margin-r.size.width,centerY-r.size.height/2,r.size.width,r.size.height);
    if(usable<=0 || CGRectGetMaxX(targetLeft)+12>CGRectGetMinX(targetRight) ||
       !CGRectContainsRect(screen,targetLeft) || !CGRectContainsRect(screen,targetRight) ||
       !ZNSStatusTargetVisible(left,targetLeft,scene) || !ZNSStatusTargetVisible(right,targetRight,scene)) return;
    // Move whole native groups: time remains live on the left; signal, Wi-Fi,
    // battery and charging updates retain their native internal layout on right.
    [UIView performWithoutAnimation:^{
        ZNSPlaceStatusRegion(left,l,targetLeft,scene);
        ZNSPlaceStatusRegion(right,r,targetRight,scene);
    }];
}
void ZNSRefreshLandscapeStatusLayout(void) {
    dispatch_async(dispatch_get_main_queue(),^{
        for(UIView *bar in ZNSLandscapeStatusBars.allObjects) [bar setNeedsLayout];
    });
}
void ZNSInstallLandscapeStatusLayout(void) {
    if(UIDevice.currentDevice.userInterfaceIdiom==UIUserInterfaceIdiomPad) return;
    static dispatch_once_t once;
    dispatch_once(&once,^{
        ZNSLandscapeStatusBars=[NSHashTable weakObjectsHashTable];
        NSMutableArray<Class> *hooked=[NSMutableArray new];
        for(NSString *name in @[@"_UIStatusBar",@"STUIStatusBar"]) {
            Class cls=NSClassFromString(name);
            if(!cls || ![cls isSubclassOfClass:UIView.class]) continue;
            BOOL inherited=NO;
            for(Class parent in hooked) if([cls isSubclassOfClass:parent]) { inherited=YES; break; }
            if(inherited) continue;
            SEL selector=@selector(layoutSubviews);
            Method method=class_getInstanceMethod(cls,selector); char type[16]={0};
            if(method) method_getReturnType(method,type,sizeof(type));
            if(!method || method_getNumberOfArguments(method)!=2 || strcmp(type,@encode(void))) continue;
            __block IMP original=NULL;
            IMP replacement=imp_implementationWithBlock(^(UIView *bar){
                if([objc_getAssociatedObject(bar,&ZNSStatusLayoutBusyKey) boolValue]) {
                    if(original) ((void(*)(id,SEL))original)(bar,selector);
                    return;
                }
                objc_setAssociatedObject(bar,&ZNSStatusLayoutBusyKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                @try {
                    [ZNSLandscapeStatusBars addObject:bar];
                    ZNSRestoreStatusRegion(ZNSStatusRegionView(bar,YES));
                    ZNSRestoreStatusRegion(ZNSStatusRegionView(bar,NO));
                    if(original) ((void(*)(id,SEL))original)(bar,selector);
                    ZNSLayoutLandscapeStatus(bar);
                } @finally {
                    objc_setAssociatedObject(bar,&ZNSStatusLayoutBusyKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
            });
            MSHookMessageEx(cls,selector,replacement,&original);
            [hooked addObject:cls];
        }
    });
}
