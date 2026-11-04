#import "ZNSDipIconView.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <stdlib.h>

@interface ZNSDipIconView ()
@property(nonatomic,strong) UIImageView *appView;
@property(nonatomic,strong) CALayer *art;
@property(nonatomic,strong) CALayer *orbit;
@property(nonatomic,strong) CAShapeLayer *gold;
@property(nonatomic,strong) CAShapeLayer *outline;
@property(nonatomic,strong) CAShapeLayer *details;
@property(nonatomic,strong) CAShapeLayer *limbs;
@property(nonatomic,strong) CAShapeLayer *whiskers;
@property(nonatomic,strong) ZNSDipIconView *companionDragon;
- (void)refreshMotion;
@end

// Reference-inspired Chinese dragon: antlers, open muzzle, flowing mane,
// scales, dorsal fins, four clawed legs and a feathered tail. The long body
// wraps around the App rather than covering it. All geometry uses 128 units.
static CGFloat ZNSDragonAngle(CGFloat t) { return -2.10+t*4.72; }
static CGFloat ZNSDragonRadius(CGFloat t,CGFloat phase) {
    // A travelling wave, growing toward the tail; the head joint stays fixed.
    return 47+sin(t*M_PI*4-phase)*sin(t*M_PI_2)*(1.0+2.0*t);
}
static CGPoint ZNSDragonPoint(CGFloat t,CGFloat offset,CGFloat phase) {
    CGFloat angle=ZNSDragonAngle(t),r=ZNSDragonRadius(t,phase)+offset;
    return CGPointMake(64+cos(angle)*r,64+sin(angle)*r);
}
static CGFloat ZNSDragonWidth(CGFloat t) { return 4.1*(1-t)+0.35; }
static CGPoint ZNSDragonLocal(CGPoint origin,CGFloat angle,CGFloat x,CGFloat y) {
    return CGPointMake(origin.x+cos(angle)*x-sin(angle)*y,origin.y+sin(angle)*x+cos(angle)*y);
}
static UIBezierPath *ZNSDragonHead(void) {
    UIBezierPath *p=[UIBezierPath bezierPath];
    [p moveToPoint:CGPointMake(5,-4)];
    [p addCurveToPoint:CGPointMake(-6,-7) controlPoint1:CGPointMake(1,-7) controlPoint2:CGPointMake(-3,-9)];
    [p addQuadCurveToPoint:CGPointMake(-11,-4) controlPoint:CGPointMake(-9,-8)];
    [p addCurveToPoint:CGPointMake(-18,-3) controlPoint1:CGPointMake(-13,-3) controlPoint2:CGPointMake(-16,-6)];
    [p addQuadCurveToPoint:CGPointMake(-16,1) controlPoint:CGPointMake(-20,1)];
    [p addLineToPoint:CGPointMake(-7,0)];
    [p addLineToPoint:CGPointMake(-4,2)];
    [p addCurveToPoint:CGPointMake(-15,5) controlPoint1:CGPointMake(-7,6) controlPoint2:CGPointMake(-12,6)];
    [p addQuadCurveToPoint:CGPointMake(-9,8) controlPoint:CGPointMake(-14,9)];
    [p addCurveToPoint:CGPointMake(5,4) controlPoint1:CGPointMake(-2,8) controlPoint2:CGPointMake(1,5)];
    [p closePath];
    CGFloat a=ZNSDragonAngle(0)+M_PI_2;
    CGPoint h=ZNSDragonPoint(0,0,0);
    [p applyTransform:CGAffineTransformMake(cos(a),sin(a),-sin(a),cos(a),h.x,h.y)];
    return p;
}
static UIBezierPath *ZNSDragonBody(CGFloat phase) {
    UIBezierPath *p=[UIBezierPath bezierPath];
    const NSUInteger samples=72;
    [p moveToPoint:ZNSDragonPoint(0,ZNSDragonWidth(0),phase)];
    for(NSUInteger i=1;i<=samples;i++) {
        CGFloat t=(CGFloat)i/samples;
        [p addLineToPoint:ZNSDragonPoint(t,ZNSDragonWidth(t),phase)];
    }
    for(NSInteger i=samples;i>=0;i--) {
        CGFloat t=(CGFloat)i/samples;
        [p addLineToPoint:ZNSDragonPoint(t,-ZNSDragonWidth(t),phase)];
    }
    [p closePath]; [p appendPath:ZNSDragonHead()];
    // The tail fan articulates at the moving end of the spine.
    CGPoint root=ZNSDragonPoint(1,0,phase);
    CGFloat a=ZNSDragonAngle(1)+M_PI_2+0.26*sin(phase-1);
    for(NSInteger i=0;i<5;i++) {
        CGFloat y=(i-2)*1.5;
        CGPoint tip=ZNSDragonLocal(root,a,9+(2-labs(i-2))*1.6,y*1.5+sin(phase+i*0.55));
        [p moveToPoint:root];
        [p addQuadCurveToPoint:tip controlPoint:ZNSDragonLocal(root,a,4,y-1.7)];
        [p addQuadCurveToPoint:root controlPoint:ZNSDragonLocal(root,a,5,y+1.3)];
        [p closePath];
    }
    return p;
}
static UIBezierPath *ZNSDragonDetails(CGFloat phase) {
    UIBezierPath *p=[UIBezierPath bezierPath];
    // Swept dorsal fins follow the same body wave (never slide off the spine).
    for(NSUInteger i=0;i<23;i++) {
        CGFloat t=0.06+i*0.038,w=ZNSDragonWidth(t);
        [p moveToPoint:ZNSDragonPoint(t,w,phase)];
        [p addQuadCurveToPoint:ZNSDragonPoint(t+0.025,w+3.0*(1-t)+0.8,phase)
                 controlPoint:ZNSDragonPoint(t+0.005,w+1.5,phase)];
        [p addQuadCurveToPoint:ZNSDragonPoint(t+0.033,ZNSDragonWidth(t+0.033),phase)
                 controlPoint:ZNSDragonPoint(t+0.023,w+0.7,phase)];
    }
    // Sparse staggered scales and belly ribs remain legible at icon size.
    for(NSUInteger i=0;i<27;i++) {
        CGFloat t=0.035+i*0.031,w=ZNSDragonWidth(t);
        for(NSUInteger row=0;row<2;row++) {
            CGFloat u=t+row*0.012,offset=(row?0.35:-0.35)*w;
            [p moveToPoint:ZNSDragonPoint(u,offset-0.65,phase)];
            [p addQuadCurveToPoint:ZNSDragonPoint(u+0.02,offset-0.65,phase)
                     controlPoint:ZNSDragonPoint(u+0.01,offset+1.2,phase)];
        }
        [p moveToPoint:ZNSDragonPoint(t,-w,phase)];
        [p addQuadCurveToPoint:ZNSDragonPoint(t+0.013,-w+1.1,phase)
                 controlPoint:ZNSDragonPoint(t+0.014,-w-0.2,phase)];
    }
    CGPoint head=ZNSDragonPoint(0,0,phase);
    CGFloat a=ZNSDragonAngle(0)+M_PI_2;
    UIBezierPath *face=[UIBezierPath bezierPath];
    // Forked antlers and brow, rather than the old single triangular crest.
    for(NSUInteger i=0;i<2;i++) {
        CGFloat x=-3+i*5;
        [face moveToPoint:CGPointMake(x,-6)];
        [face addCurveToPoint:CGPointMake(x+8,-11) controlPoint1:CGPointMake(x+3,-10) controlPoint2:CGPointMake(x+3,-12)];
        [face moveToPoint:CGPointMake(x+3,-10)]; [face addLineToPoint:CGPointMake(x+3,-13)];
        [face moveToPoint:CGPointMake(x+5,-11)]; [face addLineToPoint:CGPointMake(x+7,-13)];
    }
    [face moveToPoint:CGPointMake(-10,-4)]; [face addQuadCurveToPoint:CGPointMake(-4,-5) controlPoint:CGPointMake(-7,-7)];
    [face appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectMake(-8,-4.8,2.4,1.9)]];
    [face moveToPoint:CGPointMake(-16,-2)]; [face addQuadCurveToPoint:CGPointMake(-13,-2) controlPoint:CGPointMake(-15,-4)];
    for(NSUInteger tooth=0;tooth<4;tooth++) {
        CGFloat x=-14+tooth*2.5;
        [face moveToPoint:CGPointMake(x,0.4)]; [face addLineToPoint:CGPointMake(x+0.6,2.3)];
        [face addLineToPoint:CGPointMake(x+1.4,0.6)];
    }
    [face applyTransform:CGAffineTransformMake(cos(a),sin(a),-sin(a),cos(a),head.x,head.y)];
    [p appendPath:face];
    // Flowing cheek mane/beard; small phase-shifted tips echo the reference.
    for(NSUInteger i=0;i<7;i++) {
        CGFloat x=-6+i*1.8,y=5.0-(i>3?1:0);
        [p moveToPoint:ZNSDragonLocal(head,a,x,y)];
        [p addQuadCurveToPoint:ZNSDragonLocal(head,a,x+6,10+sin(phase+i*0.5))
                 controlPoint:ZNSDragonLocal(head,a,x+0.5,9)];
        [p addQuadCurveToPoint:ZNSDragonLocal(head,a,x+2.5,y)
                 controlPoint:ZNSDragonLocal(head,a,x+4,7)];
    }
    return p;
}
static UIBezierPath *ZNSDragonLegs(CGFloat phase) {
    UIBezierPath *p=[UIBezierPath bezierPath];
    // Two pairs, four independent strokes. Roots track the moving body,
    // elbows paddle and curled toes open/close in alternating phases.
    const CGFloat roots[4]={0.18,0.23,0.57,0.62};
    for(NSUInteger i=0;i<4;i++) {
        CGFloat t=roots[i],side=(i%2)?-1:1;
        CGFloat stroke=sin(phase+i*M_PI_2),curl=sin(phase+i*M_PI_2+0.8);
        CGPoint root=ZNSDragonPoint(t,side*(ZNSDragonWidth(t)-0.6),phase);
        CGFloat a=ZNSDragonAngle(t)+M_PI_2;
        CGPoint elbow=ZNSDragonLocal(root,a,-3+stroke*1.2,-side*3.1);
        CGPoint wrist=ZNSDragonLocal(root,a,0.8+stroke*2.1,-side*5.6);
        [p moveToPoint:root];
        [p addQuadCurveToPoint:elbow controlPoint:ZNSDragonLocal(root,a,-3,-side*1.0)];
        [p addQuadCurveToPoint:wrist controlPoint:ZNSDragonLocal(root,a,-2+stroke,-side*5)];
        [p moveToPoint:ZNSDragonLocal(root,a,1,0)];
        [p addQuadCurveToPoint:wrist controlPoint:ZNSDragonLocal(root,a,-1+stroke,-side*3.4)];
        for(NSInteger toe=-1;toe<=1;toe++) {
            CGPoint tip=ZNSDragonLocal(wrist,a,2.0+curl*0.4+toe*0.65,-side*(1.1+toe*1.25));
            [p moveToPoint:wrist];
            [p addQuadCurveToPoint:tip controlPoint:ZNSDragonLocal(wrist,a,1,-side*(2+toe))];
            [p addQuadCurveToPoint:ZNSDragonLocal(tip,a,-0.5,side*1.2)
                     controlPoint:ZNSDragonLocal(tip,a,1.2,side*0.5)];
        }
    }
    return p;
}
static UIBezierPath *ZNSDragonWhiskers(CGFloat phase) {
    UIBezierPath *p=[UIBezierPath bezierPath];
    CGPoint head=ZNSDragonPoint(0,0,phase);
    CGFloat a=ZNSDragonAngle(0)+M_PI_2;
    for(NSUInteger i=0;i<2;i++) {
        CGFloat y=i?3:-2,sway=sin(phase+i*1.4)*2.2;
        [p moveToPoint:ZNSDragonLocal(head,a,-16,y)];
        [p addCurveToPoint:ZNSDragonLocal(head,a,-21+sway,y+(i?9:-8))
            controlPoint1:ZNSDragonLocal(head,a,-25,y-1)
            controlPoint2:ZNSDragonLocal(head,a,-17-sway,y+(i?7:-6))];
    }
    return p;
}

typedef UIBezierPath *(*ZNSDragonPathBuilder)(CGFloat);
static void ZNSDragonAnimatePath(CAShapeLayer *layer,ZNSDragonPathBuilder builder,NSString *key,CFTimeInterval epoch) {
    if([layer animationForKey:key]) return;
    NSMutableArray *frames=[NSMutableArray new];
    // Identical path element topology for every phase, with an explicit closed
    // cycle. One shared clock keeps scales, fill and feet attached to the body.
    for(NSUInteger i=0;i<=16;i++) [frames addObject:(__bridge id)builder((i%16)*M_PI*2/16).CGPath];
    CAKeyframeAnimation *motion=[CAKeyframeAnimation animationWithKeyPath:@"path"];
    motion.values=frames; motion.duration=2.8; motion.repeatCount=HUGE_VALF;
    motion.calculationMode=kCAAnimationLinear; motion.beginTime=[layer convertTime:epoch fromLayer:nil];
    [layer addAnimation:motion forKey:key];
}
@implementation ZNSDipIconView
- (instancetype)initWithFrame:(CGRect)frame {
    if(!(self=[super initWithFrame:frame])) return nil;
    self.accessibilityIdentifier=@"ZNSDipIcon";
    self.isAccessibilityElement=YES; self.accessibilityTraits=UIAccessibilityTraitButton;
    self.accessibilityLabel=@"下探窗口转为二档空挂";
    self.accessibilityHint=@"轻点将对应窗口放到首排；拖动靠近窗口角可切换对应应用";
    self.backgroundColor=[UIColor colorWithWhite:0.12 alpha:0.85];
    self.layer.cornerRadius=17; self.layer.borderWidth=1.25;
    self.layer.borderColor=[UIColor colorWithWhite:1 alpha:0.85].CGColor;
    self.clipsToBounds=YES;
    _appView=[UIImageView new]; _appView.userInteractionEnabled=NO;
    _appView.contentMode=UIViewContentModeScaleAspectFit;
    _appView.layer.cornerRadius=7; _appView.clipsToBounds=YES;
    [self addSubview:_appView];
    _art=[CALayer layer]; _art.bounds=CGRectMake(0,0,128,128); [self.layer addSublayer:_art];
    _orbit=[CALayer layer]; _orbit.frame=_art.bounds; [_art addSublayer:_orbit];
    _gold=[CAShapeLayer layer]; _gold.path=ZNSDragonBody(0).CGPath;
    _gold.fillColor=[UIColor colorWithRed:1 green:0.75 blue:0.18 alpha:1].CGColor;
    _gold.opacity=0.55; [_orbit addSublayer:_gold];
    _outline=[CAShapeLayer layer]; _outline.path=_gold.path;
    _details=[CAShapeLayer layer]; _details.path=ZNSDragonDetails(0).CGPath;
    _limbs=[CAShapeLayer layer]; _limbs.path=ZNSDragonLegs(0).CGPath;
    _whiskers=[CAShapeLayer layer]; _whiskers.path=ZNSDragonWhiskers(0).CGPath;
    for(CAShapeLayer *line in @[_outline,_details,_limbs,_whiskers]) {
        line.fillColor=UIColor.clearColor.CGColor; line.strokeColor=UIColor.whiteColor.CGColor;
        line.lineWidth=line==_details?0.65:1.05;
        line.lineCap=kCALineCapRound; line.lineJoin=kCALineJoinRound;
        [_orbit addSublayer:line];
    }
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshMotion) name:UIAccessibilityReduceMotionStatusDidChangeNotification object:nil];
    return self;
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)setAppImage:(UIImage *)appImage { _appImage=appImage; self.appView.image=appImage; }
- (void)setShowsCompanionDragon:(BOOL)showsCompanionDragon {
    if(_showsCompanionDragon==showsCompanionDragon) return;
    _showsCompanionDragon=showsCompanionDragon;
    if(showsCompanionDragon && !self.companionDragon) {
        ZNSDipIconView *dragon=[[ZNSDipIconView alloc] initWithFrame:CGRectZero];
        dragon.userInteractionEnabled=NO; dragon.isAccessibilityElement=NO;
        dragon.backgroundColor=UIColor.clearColor; dragon.layer.borderWidth=0;
        dragon.appView.hidden=YES;
        self.companionDragon=dragon; [self addSubview:dragon];
    }
    self.companionDragon.hidden=!showsCompanionDragon;
    [self setNeedsLayout];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    // Mirroring reverses both the head direction and orbit, so the two
    // dragons approach each other rather than following tail-to-head.
    self.companionDragon.bounds=self.bounds;
    self.companionDragon.center=CGPointMake(CGRectGetMidX(self.bounds),CGRectGetMidY(self.bounds));
    self.companionDragon.transform=CGAffineTransformMakeScale(-0.82,0.82);
    CGFloat scale=MIN(self.bounds.size.width,self.bounds.size.height)/128.0;
    // Leave an annular lane for the dragon's body and articulated claws.
    self.appView.frame=CGRectInset(self.bounds,36*scale,36*scale);
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    self.art.position=CGPointMake(CGRectGetMidX(self.bounds),CGRectGetMidY(self.bounds));
    self.art.transform=CATransform3DMakeScale(scale,scale,1);
    [CATransaction commit];
    [self refreshMotion];
}
- (void)didMoveToWindow { [super didMoveToWindow]; [self refreshMotion]; }
- (void)setHidden:(BOOL)hidden { [super setHidden:hidden]; [self refreshMotion]; }
- (void)refreshMotion {
    [self.companionDragon refreshMotion];
    if(!self.orbit) return;
    BOOL animate=self.window && !self.hidden && !UIAccessibilityIsReduceMotionEnabled();
    for(UIView *parent=self.superview;animate && parent;parent=parent.superview)
        if(parent.hidden || parent.alpha<0.01) animate=NO;
    if(!animate) {
        for(CALayer *layer in @[self.orbit,self.gold,self.outline,self.details,self.limbs,self.whiskers]) [layer removeAllAnimations];
        return;
    }
    if([self.orbit animationForKey:@"ZNSDragonOrbit"]) return;
    CFTimeInterval epoch=CACurrentMediaTime();
    CABasicAnimation *orbit=[CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    // Head leads, trailing body/tail swim after it rather than travelling tail-first.
    orbit.fromValue=@0; orbit.toValue=@(-M_PI*2); orbit.duration=9; orbit.repeatCount=HUGE_VALF;
    orbit.beginTime=[self.orbit convertTime:epoch fromLayer:nil];
    [self.orbit addAnimation:orbit forKey:@"ZNSDragonOrbit"];
    CABasicAnimation *breath=[CABasicAnimation animationWithKeyPath:@"opacity"];
    breath.fromValue=@0; breath.toValue=@0.95; breath.duration=1.8;
    breath.autoreverses=YES; breath.repeatCount=HUGE_VALF;
    breath.timingFunction=[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    breath.beginTime=[self.gold convertTime:epoch fromLayer:nil];
    [self.gold addAnimation:breath forKey:@"ZNSDragonGoldBreath"];
    ZNSDragonAnimatePath(self.outline,ZNSDragonBody,@"ZNSDragonBodyTail",epoch);
    ZNSDragonAnimatePath(self.gold,ZNSDragonBody,@"ZNSDragonBodyTail",epoch);
    ZNSDragonAnimatePath(self.details,ZNSDragonDetails,@"ZNSDragonScalesMane",epoch);
    ZNSDragonAnimatePath(self.limbs,ZNSDragonLegs,@"ZNSDragonFourClaws",epoch);
    ZNSDragonAnimatePath(self.whiskers,ZNSDragonWhiskers,@"ZNSDragonWhiskers",epoch);
}
@end
