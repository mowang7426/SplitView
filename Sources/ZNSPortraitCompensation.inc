// Presentation only: no frame/bounds/host/reference setters in these methods.
- (void)znsSetPortraitCompensation:(BOOL)enabled {
    ZNSPortraitVisualGeometry g={CGAffineTransformIdentity,CGAffineTransformIdentity,CGAffineTransformIdentity};
    if (enabled) g=ZNSPortraitVisualGeometryMake(self.portraitKeyboardTarget.size,
        self.portraitKeyboardSavedFrame.size,self.session.temporaryPortraitCanvas);
    self.bodyBackground.transform=g.body;
    self.content.transform=g.content;
    self.canvasContainer.transform=g.canvas;
    // The one visible expanded top bar fades out; final chrome fades in only
    // after normal layout, never moving visible hit regions during WillHide.
    [self znsSetPortraitChromeAlpha:enabled?0:1];
    // Rounded silhouette follows the shrink; do not replace masks or add layers.
    CGFloat rootScale=enabled?self.portraitKeyboardSavedFrame.size.width/self.portraitKeyboardTarget.size.width:1;
    self.bodyBackground.layer.cornerRadius=16/(rootScale*g.body.a);
    self.content.layer.cornerRadius=12/(rootScale*g.content.a);
    self.content.layer.maskedCorners=enabled?15:3; // all four vs top two CACornerMask bits
}
- (void)znsClearPortraitCompensation {
    for (UIView *chrome in @[self.toolbar,self.topBar,self.bottomBar])
        [chrome.layer removeAnimationForKey:@"opacity"];
    for (UIView *view in @[self.bodyBackground,self.content,self.canvasContainer]) {
        [view.layer removeAnimationForKey:@"transform"];
        [view.layer removeAnimationForKey:@"cornerRadius"];
    }
    [self znsSetPortraitCompensation:NO];
}
- (void)znsClearPortraitChrome {
    if (!self.portraitKeyboardChromeFading) return;
    self.portraitKeyboardChromeFading=NO;
    for (UIView *view in @[self.toolbar,self.topBar,self.bottomBar]) {
        [view.layer removeAnimationForKey:@"opacity"];
        view.alpha=1;
    }
}
- (void)znsSetPortraitChromeAlpha:(CGFloat)alpha {
    self.toolbar.alpha=alpha;
    self.topBar.alpha=alpha;
    self.bottomBar.alpha=alpha;
}
