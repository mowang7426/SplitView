#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "ZNSFineParticlePolicy.h"
@interface ZNSFineParticleSurface : UIView
@property(nonatomic,strong) CAEmitterLayer *znsEmitter;
@property(nonatomic,weak) UIView *znsFrozen;
- (void)znsStop;
@end
static void ZNSFineReleaseData(void *info,const void *data,size_t size) { (void)info;(void)size;free((void *)data); }
// Procedural alpha only in meaning, RGBA for predictable CoreAnimation support.
// Fixed 2,228,224-byte transient mask budget; never reads App pixels.
static NSArray *ZNSFineMasks(void) {
    NSMutableArray *frames=[NSMutableArray new];
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
    if(!space) return nil;
    for(unsigned f=0;f<ZNSFineMaskFrames;f++) {
        size_t bytes=ZNSFineMaskWidth*ZNSFineMaskHeight*4;
        uint8_t *data=calloc(1,bytes);
        if(!data) { CGColorSpaceRelease(space);return nil; }
        for(unsigned y=0;y<ZNSFineMaskHeight;y++) for(unsigned x=0;x<ZNSFineMaskWidth;x++) {
            unsigned i=(y*ZNSFineMaskWidth+x)*4;
            uint8_t a=ZNSFineAlpha(x,y,f);
            data[i]=data[i+1]=data[i+2]=data[i+3]=a;
        }
        CGDataProviderRef provider=CGDataProviderCreateWithData(NULL,data,bytes,ZNSFineReleaseData);
        if(!provider) { free(data);CGColorSpaceRelease(space);return nil; }
        CGImageRef image=CGImageCreate(ZNSFineMaskWidth,ZNSFineMaskHeight,8,32,ZNSFineMaskWidth*4,space,kCGImageAlphaPremultipliedLast,provider,NULL,false,kCGRenderingIntentDefault);
        CGDataProviderRelease(provider);
        if(!image) { CGColorSpaceRelease(space);return nil; }
        [frames addObject:(__bridge id)image];CGImageRelease(image);
    }
    CGColorSpaceRelease(space);return frames;
}
@implementation ZNSFineParticleSurface
- (void)znsStop {
    self.znsEmitter.birthRate=ZNSFineRate(0,false);
    [self.znsEmitter removeAllAnimations];self.znsEmitter.emitterCells=nil;
    [self.znsEmitter removeFromSuperlayer];self.znsEmitter=nil;
    [self.znsFrozen.layer.mask removeAllAnimations];self.znsFrozen.layer.mask=nil;
}
- (void)removeFromSuperview { [self znsStop];[super removeFromSuperview]; }
- (void)layoutSubviews {
    [super layoutSubviews];
    // Never stretch an in-flight mask after a geometry change.
    if(self.znsFrozen && !CGSizeEqualToSize(self.bounds.size,self.znsFrozen.bounds.size)) {
        [self znsStop];self.hidden=YES;
    }
}
@end
static ZNSFineParticleSurface *ZNSFineCreate(UIView *frozen,CGFloat screenScale) {
    CGSize size=frozen.bounds.size;
    if(!frozen || !ZNSFineGeometry(size.width,size.height,screenScale)) return nil;
    NSArray *frames=ZNSFineMasks();if(frames.count!=ZNSFineMaskFrames) return nil;
    // Tiny shared round neutral dust, NOT content-derived colored pixels.
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(12,12),NO,1);
    CGContextRef context=UIGraphicsGetCurrentContext();
    if(!context) { UIGraphicsEndImageContext();return nil; }
    CGContextSetRGBFillColor(context,.65,.68,.72,.72);
    CGContextFillEllipseInRect(context,CGRectMake(1,1,10,10));
    UIImage *dot=UIGraphicsGetImageFromCurrentImageContext();UIGraphicsEndImageContext();
    if(!dot.CGImage) return nil;
    ZNSFineParticleSurface *surface=[[ZNSFineParticleSurface alloc] initWithFrame:frozen.frame];
    surface.userInteractionEnabled=NO;surface.backgroundColor=UIColor.clearColor;surface.znsFrozen=frozen;
    [surface addSubview:frozen];frozen.frame=surface.bounds;
    CALayer *mask=[CALayer layer];mask.frame=frozen.bounds;
    mask.magnificationFilter=kCAFilterNearest;mask.minificationFilter=kCAFilterNearest;
    mask.contents=frames.lastObject;frozen.layer.mask=mask;
    CAKeyframeAnimation *erosion=[CAKeyframeAnimation animationWithKeyPath:@"contents"];
    erosion.values=frames;erosion.duration=ZNSFineEmitDuration;erosion.calculationMode=kCAAnimationDiscrete;
    [mask addAnimation:erosion forKey:@"zns.fine.erosion"];
    CAEmitterLayer *emitter=[CAEmitterLayer layer];surface.znsEmitter=emitter;
    emitter.frame=surface.bounds;emitter.emitterShape=kCAEmitterLayerRectangle;emitter.emitterMode=kCAEmitterLayerVolume;
    emitter.emitterSize=CGSizeMake(1,size.height);emitter.emitterPosition=CGPointMake(size.width,size.height*.5);
    emitter.renderMode=kCAEmitterLayerUnordered;emitter.seed=0x71ab9;
    emitter.beginTime=CACurrentMediaTime();emitter.birthRate=0;
    CAEmitterCell *cell=[CAEmitterCell emitterCell];cell.contents=(__bridge id)dot.CGImage;
    cell.birthRate=ZNSFineRate(0,true);cell.lifetime=ZNSFineLifetime;cell.lifetimeRange=ZNSFineLifetimeRange;
    cell.scale=ZNSFineDiameter/12;cell.scaleRange=ZNSFineDiameterRange/12;
    cell.velocity=100;cell.velocityRange=35;cell.emissionLongitude=0;cell.emissionRange=.45;
    cell.xAcceleration=80;cell.yAcceleration=-12;cell.alphaSpeed=-2.8;
    emitter.emitterCells=@[cell];[surface.layer addSublayer:emitter];
    CABasicAnimation *wind=[CABasicAnimation animationWithKeyPath:@"emitterPosition"];
    wind.fromValue=[NSValue valueWithCGPoint:CGPointMake(0,size.height*.5)];
    wind.toValue=[NSValue valueWithCGPoint:emitter.emitterPosition];wind.duration=ZNSFineEmitDuration;
    [emitter addAnimation:wind forKey:@"zns.fine.front"];
    CAKeyframeAnimation *gate=[CAKeyframeAnimation animationWithKeyPath:@"birthRate"];
    gate.values=@[@1,@0,@0];gate.keyTimes=@[@0,@(ZNSFineEmitDuration/ZNSFineDuration),@1];
    gate.duration=ZNSFineDuration;gate.calculationMode=kCAAnimationDiscrete;
    [emitter addAnimation:gate forKey:@"zns.fine.gate"];
    return surface;
}
