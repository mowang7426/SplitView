#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <math.h>
#import <string.h>
#import <os/log.h>
#import "ZNSDesktopRotation.h"
#import "ZNSLandscapeIconGrid.h"

static char ZNSCanvasStateKey,ZNSCanvasItemKey,ZNSCanvasBusyKey;
static NSHashTable<UIView *> *ZNSCanvasOwners;
@interface ZNSIconCanvas : UIView
@end
@implementation ZNSIconCanvas
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit=[super hitTest:point withEvent:event];
    return hit==self?nil:hit;
}
@end
@interface ZNSCanvasItem : NSObject
@property(nonatomic,weak) UIView *view;
@property(nonatomic,weak) UIView *parent;
@property(nonatomic) NSUInteger index;
@property(nonatomic) CGRect bounds,placedBounds;
@property(nonatomic) CGPoint center,placedCenter;
@property(nonatomic) CGAffineTransform transform,placedTransform;
@property(nonatomic) UIViewAutoresizing autoresizing;
@property(nonatomic) BOOL translates;
@property(nonatomic,strong) NSArray<NSLayoutConstraint *> *constraints;
@property(nonatomic,weak) UIView *owner;
@end
@implementation ZNSCanvasItem
@end
@interface ZNSCanvasState : NSObject
@property(nonatomic,strong) ZNSIconCanvas *canvas;
@property(nonatomic,strong) NSArray<ZNSCanvasItem *> *items;
@property(nonatomic) CGFloat alpha;
@property(nonatomic) BOOL interaction,accessibilityHidden;
@end
@implementation ZNSCanvasState
@end
static BOOL ZNSCanvasIs(id object,NSString *name) {
    Class cls=NSClassFromString(name); return cls && [object isKindOfClass:cls];
}
static id ZNSCanvasObject(id object,NSString *name) {
    if(!object) return nil;
    SEL sel=NSSelectorFromString(name);
    Method method=class_getInstanceMethod(object_getClass(object),sel);
    char type[128]={0}; if(method) method_getReturnType(method,type,sizeof(type));
    if(!method || method_getNumberOfArguments(method)!=2 || type[0]!='@') return nil;
    return ((id(*)(id,SEL))objc_msgSend)(object,sel);
}
static BOOL ZNSCanvasEditing(id object) {
    SEL sel=NSSelectorFromString(@"isEditing");
    Method method=class_getInstanceMethod(object_getClass(object),sel);
    char type[32]={0}; if(method) method_getReturnType(method,type,sizeof(type));
    return method && method_getNumberOfArguments(method)==2 &&
        (!strcmp(type,@encode(BOOL)) || !strcmp(type,"B")) && ((BOOL(*)(id,SEL))objc_msgSend)(object,sel);
}
static BOOL ZNSCanvasEnabled(UIView *view) {
    UIWindowScene *scene=view.window.windowScene;
    return NSThread.isMainThread && ZNSDesktopRotationIsEnabled() && scene &&
        scene.screen==UIScreen.mainScreen && UIInterfaceOrientationIsLandscape(scene.interfaceOrientation) &&
        scene.coordinateSpace.bounds.size.width>scene.coordinateSpace.bounds.size.height;
}
static BOOL ZNSCanvasRect(CGRect r) {
    return isfinite(r.origin.x)&&isfinite(r.origin.y)&&isfinite(r.size.width)&&isfinite(r.size.height)&&r.size.width>1&&r.size.height>1;
}
static UIView *ZNSCanvasDock(UIView *list) {
    for(UIView *v=list.superview;v;v=v.superview) if(ZNSCanvasIs(v,@"SBDockView")) return v;
    return nil;
}
static BOOL ZNSCanvasRootList(UIView *list) {
    if(!ZNSCanvasIs(list,@"SBIconListView") || ZNSCanvasDock(list)) return NO;
    id location=ZNSCanvasObject(list,@"iconLocation");
    if([location isKindOfClass:NSString.class] && [location isEqualToString:@"SBIconLocationRoot"]) return YES;
    for(UIView *v=list.superview;v;v=v.superview) {
        if(ZNSCanvasIs(v,@"SBRootFolderView")) return YES;
        if(ZNSCanvasIs(v,@"SBFolderView") || ZNSCanvasIs(v,@"SBHLibraryView")) return NO;
    }
    return NO;
}
static NSArray<UIView *> *ZNSCanvasFind(UIView *root,NSString *name) {
    NSMutableArray *found=[NSMutableArray new],*pending=[NSMutableArray arrayWithArray:root.subviews];
    NSUInteger budget=2048;
    while(pending.count && budget) {
        --budget; UIView *v=pending.lastObject; [pending removeLastObject];
        if([v isKindOfClass:ZNSIconCanvas.class]) continue;
        if(ZNSCanvasIs(v,name)) [found addObject:v]; else [pending addObjectsFromArray:v.subviews];
    }
    return pending.count?nil:found;
}
static NSArray<UIView *> *ZNSCanvasOrdered(UIView *list) {
    id model=ZNSCanvasObject(list,@"model");
    id icons=ZNSCanvasObject(model,@"icons");
    if([icons isKindOfClass:NSOrderedSet.class]) icons=[icons array];
    if(![icons isKindOfClass:NSArray.class] || ![icons count] || [icons count]>120) return nil;
    NSArray *views=ZNSCanvasFind(list,@"SBIconView");
    NSMutableArray *ordered=[NSMutableArray new];
    for(id icon in icons) {
        UIView *match=nil;
        for(UIView *view in views) if(ZNSCanvasObject(view,@"icon")==icon) {
            if(match) return nil; match=view;
        }
        if(!match || ZNSCanvasEditing(match) || !ZNSCanvasRect(match.bounds) || !match.superview) return nil;
        [ordered addObject:match];
    }
    // Do not hide a partially supported page (widgets/placeholders/unmapped icons).
    if(ordered.count!=views.count) return nil;
    return ordered;
}
static void ZNSCanvasRestore(UIView *owner) {
    ZNSCanvasState *state=objc_getAssociatedObject(owner,&ZNSCanvasStateKey);
    if(!state) return;
    objc_setAssociatedObject(owner,&ZNSCanvasStateKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSArray *items=[state.items sortedArrayUsingComparator:^NSComparisonResult(ZNSCanvasItem *a,ZNSCanvasItem *b){
        return a.index<b.index?NSOrderedAscending:a.index>b.index?NSOrderedDescending:NSOrderedSame;
    }];
    for(ZNSCanvasItem *item in items) {
        UIView *view=item.view;
        objc_setAssociatedObject(view,&ZNSCanvasItemKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if(view.superview!=state.canvas) continue; // UIKit has reclaimed it.
        UIView *parent=item.parent;
        if(!parent) { [view removeFromSuperview]; continue; }
        [parent insertSubview:view atIndex:MIN(item.index,parent.subviews.count)];
        view.transform=item.transform; view.bounds=item.bounds; view.center=item.center;
        view.autoresizingMask=item.autoresizing; view.translatesAutoresizingMaskIntoConstraints=item.translates;
        [NSLayoutConstraint activateConstraints:item.constraints];
    }
    [state.canvas removeFromSuperview];
    if(owner.alpha==0) owner.alpha=state.alpha;
    owner.userInteractionEnabled=state.interaction;
    owner.accessibilityElementsHidden=state.accessibilityHidden;
}
static void ZNSCanvasReport(UIView *owner,NSString *reason,NSUInteger count) {
    static CFAbsoluteTime last; CFAbsoluteTime now=CFAbsoluteTimeGetCurrent();
    if(now-last<3) return; last=now;
    static os_log_t log; static dispatch_once_t once;
    dispatch_once(&once,^{log=os_log_create(APELIN_PACKAGE_ID,"landscape-grid");});
    os_log(log,"canvas build=%{public}s class=%{public}@ result=%{public}@ icons=%lu",APELIN_BUILD_ID,NSStringFromClass(owner.class),reason,(unsigned long)count);
}
static CGRect ZNSCanvasFootprint(UIView *view) {
    CGRect result=view.bounds;
    for(UIView *child in view.subviews) if(!child.hidden && child.alpha>0.01) {
        CGRect r=[child convertRect:child.bounds toView:view];
        if(ZNSCanvasRect(r)) result=CGRectUnion(result,r);
    }
    return result;
}
static void ZNSCanvasApply(UIView *owner,UIView *list,BOOL dock) {
    if(!ZNSCanvasEnabled(owner) || !owner.superview || owner.hidden || owner.alpha<0.01 ||
        ZNSCanvasEditing(owner) || ZNSCanvasEditing(list)) return;
    NSArray<UIView *> *icons=ZNSCanvasOrdered(list);
    if(!icons.count) { ZNSCanvasReport(owner,@"model-or-views-unavailable",0); return; }
    UIWindowScene *scene=owner.window.windowScene;
    CGRect screen=scene.coordinateSpace.bounds;
    UIEdgeInsets safe=owner.window.safeAreaInsets;
    CGRect rect;
    if(dock) {
        CGFloat width=MIN(screen.size.width-safe.left-safe.right-48,MAX(220,icons.count*62+28));
        CGRect target=CGRectMake(CGRectGetMidX(screen)-width/2,CGRectGetMaxY(screen)-safe.bottom-82,width,72);
        rect=[owner.superview convertRect:target fromCoordinateSpace:scene.coordinateSpace];
    } else {
        // Sibling of this page, in the native paging scroll view. X never uses
        // the visible screen origin, so neighbouring pages cannot pile together.
        CGRect page=[owner.superview convertRect:owner.bounds fromView:owner];
        CGPoint top=[owner.superview convertPoint:CGPointMake(CGRectGetMidX(screen),safe.top+40) fromCoordinateSpace:scene.coordinateSpace];
        CGPoint bottom=[owner.superview convertPoint:CGPointMake(CGRectGetMidX(screen),CGRectGetMaxY(screen)-safe.bottom-110) fromCoordinateSpace:scene.coordinateSpace];
        CGFloat margin=24;
        rect=CGRectMake(page.origin.x+safe.left+margin,top.y,
            MIN(page.size.width,screen.size.width)-safe.left-safe.right-2*margin,bottom.y-top.y);
    }
    if(!ZNSCanvasRect(rect)) { ZNSCanvasReport(owner,@"invalid-canvas-area",icons.count); return; }
    NSUInteger columns=dock?icons.count:MIN((NSUInteger)8,MAX((NSUInteger)4,(NSUInteger)floor(rect.size.width/88)));
    NSUInteger rows=(icons.count+columns-1)/columns;
    CGFloat cellW=rect.size.width/columns,cellH=rect.size.height/rows,scale=0.68;
    for(UIView *view in icons) {
        CGRect ink=ZNSCanvasFootprint(view);
        if(!ZNSCanvasRect(ink)) return;
        scale=MIN(scale,MIN((cellW-14)/ink.size.width,(cellH-12)/ink.size.height));
    }
    if(!isfinite(scale) || scale<=0) return;
    ZNSCanvasState *state=[ZNSCanvasState new];
    state.alpha=owner.alpha; state.interaction=owner.userInteractionEnabled;
    state.accessibilityHidden=owner.accessibilityElementsHidden;
    state.canvas=[[ZNSIconCanvas alloc] initWithFrame:rect];
    state.canvas.alpha=state.alpha;
    state.canvas.clipsToBounds=YES;
    state.canvas.accessibilityIdentifier=dock?@"ZNSLandscapeDockCanvas":@"ZNSLandscapePageCanvas";
    if(dock) { state.canvas.backgroundColor=[UIColor.secondarySystemBackgroundColor colorWithAlphaComponent:0.8]; state.canvas.layer.cornerRadius=24; }
    NSMutableArray *items=[NSMutableArray new];
    // Snapshot all sibling indices before moving any icon.
    for(UIView *view in icons) {
        ZNSCanvasItem *item=[ZNSCanvasItem new]; item.view=view; item.parent=view.superview; item.owner=owner;
        item.index=[view.superview.subviews indexOfObjectIdenticalTo:view];
        item.bounds=view.bounds; item.center=view.center; item.transform=view.transform;
        item.autoresizing=view.autoresizingMask; item.translates=view.translatesAutoresizingMaskIntoConstraints;
        NSMutableArray *constraints=[NSMutableArray new];
        for(UIView *ancestor=view.superview;ancestor;ancestor=ancestor.superview)
            for(NSLayoutConstraint *c in ancestor.constraints)
                if(c.active && (c.firstItem==view || c.secondItem==view)) [constraints addObject:c];
        item.constraints=constraints; [items addObject:item];
    }
    state.items=items;
    objc_setAssociatedObject(owner,&ZNSCanvasStateKey,state,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [owner.superview insertSubview:state.canvas aboveSubview:owner];
    @try {
        for(NSUInteger i=0;i<items.count;i++) {
            ZNSCanvasItem *item=items[i]; UIView *view=item.view;
            CGRect ink=ZNSCanvasFootprint(view);
            [NSLayoutConstraint deactivateConstraints:item.constraints];
            view.translatesAutoresizingMaskIntoConstraints=YES; view.autoresizingMask=UIViewAutoresizingNone;
            [state.canvas addSubview:view];
            item.placedBounds=item.bounds; item.placedTransform=CGAffineTransformMakeScale(scale,scale);
            item.placedCenter=CGPointMake(((i%columns)+0.5)*cellW-scale*(CGRectGetMidX(ink)-CGRectGetMidX(item.bounds)),
                ((i/columns)+0.5)*cellH-scale*(CGRectGetMidY(ink)-CGRectGetMidY(item.bounds)));
            view.transform=item.placedTransform; view.bounds=item.placedBounds; view.center=item.placedCenter;
            objc_setAssociatedObject(view,&ZNSCanvasItemKey,item,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        // Original canvas is neither visible, tappable nor accessible. The
        // native icon objects now exist only in our sibling canvas, not copies.
        owner.alpha=0; owner.userInteractionEnabled=NO; owner.accessibilityElementsHidden=YES;
        ZNSCanvasReport(owner,@"canvas-mounted",icons.count);
    } @catch(NSException *exception) {
        ZNSCanvasRestore(owner); ZNSCanvasReport(owner,@"mount-rolled-back",icons.count);
    }
}
static void ZNSCanvasHook(NSString *name,BOOL dock) {
    Class cls=NSClassFromString(name); SEL selector=@selector(layoutSubviews);
    Method method=class_getInstanceMethod(cls,selector); char type[32]={0};
    if(method) method_getReturnType(method,type,sizeof(type));
    if(!cls || !method || method_getNumberOfArguments(method)!=2 || strcmp(type,@encode(void))) return;
    __block IMP original=NULL;
    IMP replacement=imp_implementationWithBlock(^(UIView *view){
        if([objc_getAssociatedObject(view,&ZNSCanvasBusyKey) boolValue]) {
            if(original) ((void(*)(id,SEL))original)(view,selector); return;
        }
        BOOL managed=dock || ZNSCanvasRootList(view) || objc_getAssociatedObject(view,&ZNSCanvasStateKey)!=nil;
        if(!managed) {
            if(original) ((void(*)(id,SEL))original)(view,selector);
            // Native child layout is an effect, not an invalidation request.
            // Marking its Dock dirty here makes Dock -> list -> Dock repeat,
            // including portrait/appearance-only passes with no mounted canvas.
            return;
        }
        objc_setAssociatedObject(view,&ZNSCanvasBusyKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        @try {
            [ZNSCanvasOwners addObject:view]; ZNSCanvasRestore(view);
            if(original) ((void(*)(id,SEL))original)(view,selector);
            [UIView performWithoutAnimation:^{
                if(dock) {
                    NSArray *lists=ZNSCanvasFind(view,@"SBIconListView");
                    if(lists.count==1) ZNSCanvasApply(view,lists.firstObject,YES);
                } else ZNSCanvasApply(view,view,NO);
            }];
        } @finally { objc_setAssociatedObject(view,&ZNSCanvasBusyKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    });
    MSHookMessageEx(cls,selector,replacement,&original);
    __block IMP needsLayout=NULL;
    MSHookMessageEx(cls,@selector(setNeedsLayout),imp_implementationWithBlock(^(UIView *view){
        UIView *dockOwner=ZNSCanvasDock(view);
        // Reparenting inside our layout must not schedule an endless new native
        // layout -> return -> reparent loop. Outside mutations still invalidate.
        if([objc_getAssociatedObject(view,&ZNSCanvasBusyKey) boolValue] ||
           [objc_getAssociatedObject(dockOwner,&ZNSCanvasBusyKey) boolValue]) return;
        if(needsLayout) ((void(*)(id,SEL))needsLayout)(view,@selector(setNeedsLayout));
        // Forward genuine external invalidation only for a mounted Dock canvas.
        // Native invalidation during Dock restore/layout/apply is suppressed by
        // the busy check above; never feed layout completion back into layout.
        if(dockOwner && objc_getAssociatedObject(dockOwner,&ZNSCanvasStateKey))
            [dockOwner setNeedsLayout];
    }),&needsLayout);
    __block IMP moved=NULL;
    MSHookMessageEx(cls,@selector(didMoveToWindow),imp_implementationWithBlock(^(UIView *view){
        if(moved) ((void(*)(id,SEL))moved)(view,@selector(didMoveToWindow));
        if(!view.window && ![objc_getAssociatedObject(view,&ZNSCanvasBusyKey) boolValue]) ZNSCanvasRestore(view);
    }),&moved);
    __block IMP alpha=NULL,hidden=NULL;
    MSHookMessageEx(cls,@selector(setAlpha:),imp_implementationWithBlock(^(UIView *view,CGFloat value){
        ZNSCanvasState *state=objc_getAssociatedObject(view,&ZNSCanvasStateKey);
        if(state && ![objc_getAssociatedObject(view,&ZNSCanvasBusyKey) boolValue]) {
            state.alpha=value; state.canvas.alpha=value; value=0;
        }
        if(alpha) ((void(*)(id,SEL,CGFloat))alpha)(view,@selector(setAlpha:),value);
    }),&alpha);
    MSHookMessageEx(cls,@selector(setHidden:),imp_implementationWithBlock(^(UIView *view,BOOL value){
        ZNSCanvasState *state=objc_getAssociatedObject(view,&ZNSCanvasStateKey);
        if(state) state.canvas.hidden=value;
        if(hidden) ((void(*)(id,SEL,BOOL))hidden)(view,@selector(setHidden:),value);
    }),&hidden);
}
static BOOL ZNSCanvasOwnsGeometry(UIView *icon) {
    ZNSCanvasItem *item=objc_getAssociatedObject(icon,&ZNSCanvasItemKey);
    ZNSCanvasState *state=objc_getAssociatedObject(item.owner,&ZNSCanvasStateKey);
    return item && state && icon.superview==state.canvas && ZNSCanvasEnabled(icon) &&
        ![objc_getAssociatedObject(item.owner,&ZNSCanvasBusyKey) boolValue];
}
void ZNSRefreshLandscapeIconGrid(void) {
    dispatch_async(dispatch_get_main_queue(),^{
        for(UIView *owner in ZNSCanvasOwners.allObjects) {
            if(!ZNSCanvasEnabled(owner)) ZNSCanvasRestore(owner);
            [owner setNeedsLayout];
        }
    });
}
void ZNSInstallLandscapeIconGrid(void) {
    if(UIDevice.currentDevice.userInterfaceIdiom==UIUserInterfaceIdiomPad) return;
    static dispatch_once_t once; dispatch_once(&once,^{
        ZNSCanvasOwners=[NSHashTable weakObjectsHashTable];
        ZNSCanvasHook(@"SBIconListView",NO); ZNSCanvasHook(@"SBDockView",YES);
        Class cls=NSClassFromString(@"SBIconView");
        if(!cls) return;
        // Native list animations may write geometry after layoutSubviews. They
        // must not drag canvas-owned icons back to the broken original grid.
        __block IMP frame=NULL,center=NULL,transform=NULL,bounds=NULL;
        MSHookMessageEx(cls,@selector(setBounds:),imp_implementationWithBlock(^(UIView *v,CGRect r){
            if(!ZNSCanvasOwnsGeometry(v) && bounds) ((void(*)(id,SEL,CGRect))bounds)(v,@selector(setBounds:),r);
        }),&bounds);
        MSHookMessageEx(cls,@selector(setFrame:),imp_implementationWithBlock(^(UIView *v,CGRect r){
            if(!ZNSCanvasOwnsGeometry(v) && frame) ((void(*)(id,SEL,CGRect))frame)(v,@selector(setFrame:),r);
        }),&frame);
        MSHookMessageEx(cls,@selector(setCenter:),imp_implementationWithBlock(^(UIView *v,CGPoint p){
            if(!ZNSCanvasOwnsGeometry(v) && center) ((void(*)(id,SEL,CGPoint))center)(v,@selector(setCenter:),p);
        }),&center);
        MSHookMessageEx(cls,@selector(setTransform:),imp_implementationWithBlock(^(UIView *v,CGAffineTransform t){
            if(!ZNSCanvasOwnsGeometry(v) && transform) ((void(*)(id,SEL,CGAffineTransform))transform)(v,@selector(setTransform:),t);
        }),&transform);
        __block IMP layout=NULL;
        MSHookMessageEx(cls,@selector(layoutSubviews),imp_implementationWithBlock(^(UIView *v){
            if(layout) ((void(*)(id,SEL))layout)(v,@selector(layoutSubviews));
            ZNSCanvasItem *item=objc_getAssociatedObject(v,&ZNSCanvasItemKey);
            if(item && (ZNSCanvasEditing(v) || !ZNSCanvasEnabled(v))) {
                UIView *owner=item.owner; ZNSCanvasRestore(owner); [owner setNeedsLayout];
            }
        }),&layout);
    });
}
