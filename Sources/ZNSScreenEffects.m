#import "ZNSScreenEffects.h"
#import "ZNSExitShatterGeometry.h"
#import "ZNSLayerInput.h"
#import <QuartzCore/QuartzCore.h>
#include <limits.h>
typedef bool (^ZNSScreenMakeBlock)(unsigned);
@implementation ZNSScreenEffectSurface
@end
static bool ZNSScreenTileOp(void *context,unsigned i) { return ((__bridge ZNSScreenMakeBlock)context)(i); }
static void ZNSScreenDiscardOp(void *context) { ((__bridge ZNSScreenMakeBlock)context)(UINT_MAX); }
ZNSScreenEffectSurface *ZNSScreenEffectCreate(UIView *frozen,int effect,BOOL entry,CGFloat scale) {
    double w=frozen.bounds.size.width,h=frozen.bounds.size.height;
    __block double pixels=0;
    unsigned count=ZNSScreenTiles(effect);
    if(!frozen || !count || !ZNSShatterSourcePixels(w,h,scale,&pixels)) return nil;
    ZNSScreenEffectSurface *surface=[[ZNSScreenEffectSurface alloc] initWithFrame:CGRectMake(0,0,w,h)];
    surface.znsProvider=frozen;surface.userInteractionEnabled=NO;surface.accessibilityElementsHidden=YES;
    surface.backgroundColor=UIColor.clearColor;surface.opaque=NO;
    ZNSSetLayerInputEnabled(surface.layer,NO);
    @try {
        bool (^make)(unsigned)=^bool(unsigned i) {
            if(i==UINT_MAX) { for(UIView *tile in surface.subviews) [tile removeFromSuperview];return false; }
            ZNSScreenRect r;
            if(!ZNSScreenRectAt(effect,i,w,h,&r) || !ZNSShatterReservePixels(&pixels,r.w*r.h*scale*scale)) return false;
            UIView *tile=[frozen resizableSnapshotViewFromRect:CGRectMake(r.x,r.y,r.w,r.h) afterScreenUpdates:NO withCapInsets:UIEdgeInsetsZero];
            if(!tile) return false; // Builder discards every partial crop before fallback.
            tile.frame=CGRectMake(r.x,r.y,r.w,r.h);tile.userInteractionEnabled=NO;
            [surface addSubview:tile];
            NSMutableArray *transforms=[NSMutableArray new],*alphas=[NSMutableArray new],*times=[NSMutableArray new];
            for(unsigned f=0;f<ZNSScreenFrames;f++) {
                double t=(double)f/(ZNSScreenFrames-1);
                ZNSScreenPose p=ZNSScreenPoseAt(effect,i,w,h,t,entry);
                CATransform3D m=CATransform3DIdentity;m.m34=-1.0/900;
                m=CATransform3DTranslate(m,p.dx,p.dy,0);
                m=CATransform3DRotate(m,p.rz,0,0,1);m=CATransform3DRotate(m,p.ry,0,1,0);
                m=CATransform3DScale(m,p.sx,p.sy,1);
                [transforms addObject:[NSValue valueWithCATransform3D:m]];
                [alphas addObject:@(p.alpha)];[times addObject:@(t)];
            }
            CAKeyframeAnimation *motion=[CAKeyframeAnimation animationWithKeyPath:@"transform"];
            motion.values=transforms;motion.keyTimes=times;motion.duration=ZNSScreenDuration;
            CAKeyframeAnimation *fade=[CAKeyframeAnimation animationWithKeyPath:@"opacity"];
            fade.values=alphas;fade.keyTimes=times;fade.duration=ZNSScreenDuration;
            CAAnimationGroup *group=[CAAnimationGroup animation];group.animations=@[motion,fade];group.duration=ZNSScreenDuration;
            group.fillMode=kCAFillModeBoth;group.removedOnCompletion=NO;
            [tile.layer addAnimation:group forKey:@"ZNSScreenEffect"];
            return true;
        };
        ZNSScreenBuildOps ops={ZNSScreenTileOp,ZNSScreenDiscardOp};
        if(!ZNSScreenBuild((__bridge void *)make,effect,ops)) return nil;
    } @catch(__unused NSException *exception) { return nil; }
    return surface;
}
