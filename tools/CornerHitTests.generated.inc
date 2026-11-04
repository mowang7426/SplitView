@interface ZNSCornerHitView : UIView
@property(nonatomic,strong) NSArray<UIView *> *hitStrips;
- (void)setHorizontalRegion:(CGRect)horizontal sideRegion:(CGRect)side enabled:(BOOL)enabled;
@end
@implementation ZNSCornerHitView
- (instancetype)initWithFrame:(CGRect)frame {
    if(!(self=[super initWithFrame:frame])) return nil;
    UIView *horizontal=[UIView new],*side=[UIView new];
    self.hitStrips=@[horizontal,side];
    for(UIView *strip in self.hitStrips) {
        ZNSSetLayerInputOpaque(strip.layer,YES);
        [self addSubview:strip];
    }
    return self;
}
- (void)setHorizontalRegion:(CGRect)horizontal sideRegion:(CGRect)side enabled:(BOOL)enabled {
    CGRect regions[]={horizontal,side};
    CGRect enclosing=CGRectNull;
    for(unsigned i=0;i<2;i++) if(!CGRectIsNull(regions[i]) && !CGRectIsEmpty(regions[i]))
        enclosing=CGRectUnion(enclosing,regions[i]);
    BOOL active=enabled && !CGRectIsNull(enclosing) && !CGRectIsEmpty(enclosing);
    self.hidden=!active; self.userInteractionEnabled=active;
    self.frame=active?enclosing:CGRectZero;
    for(unsigned i=0;i<2;i++) {
        UIView *strip=self.hitStrips[i];
        BOOL valid=active && !CGRectIsNull(regions[i]) && !CGRectIsEmpty(regions[i]);
        strip.frame=valid?CGRectOffset(regions[i],-enclosing.origin.x,-enclosing.origin.y):CGRectZero;
        strip.hidden=!valid; strip.userInteractionEnabled=valid;
        ZNSSetLayerInputEnabled(strip.layer,valid);
    }
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    (void)event;
    if(self.hidden || !self.userInteractionEnabled) return NO;
    for(UIView *strip in self.hitStrips)
        if(!strip.hidden && CGRectContainsPoint(strip.frame,point)) return YES;
    return NO;
}
@end
