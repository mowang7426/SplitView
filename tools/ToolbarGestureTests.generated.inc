- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    if (gesture.view!=self.toolbar) return YES;
    // A pan may start on any tool, cancelling its button touch once dragging
    // begins. A stationary tap still belongs exclusively to that button.
    if ([gesture isKindOfClass:UIPanGestureRecognizer.class]) return YES;
    for (UIView *view=touch.view; view && view!=self.toolbar; view=view.superview)
        if ([view isKindOfClass:UIControl.class]) return NO;
    return YES;
}
- (void)drag:(UIPanGestureRecognizer *)gesture {
    if(self.closing || (self.activeManipulation && self.activeManipulation!=gesture)) return;
    if (gesture.state==UIGestureRecognizerStateBegan) {
        self.activeManipulation=gesture; self.gestureFrame=self.frame;
        ++self.toolsGeneration; // Invalidate the idle collapse while dragging.
    }
    CGPoint delta=[gesture translationInView:self.superview];
    CGRect next=CGRectOffset(self.gestureFrame,delta.x,delta.y);
    self.frame=ZNSConstrainIcon(next,[self safe]);
    [self setNeedsLayout];
    if (gesture.state==UIGestureRecognizerStateCancelled || gesture.state==UIGestureRecognizerStateFailed) self.frame=self.gestureFrame;
    if (gesture.state==UIGestureRecognizerStateEnded || gesture.state==UIGestureRecognizerStateCancelled || gesture.state==UIGestureRecognizerStateFailed) {
        self.activeManipulation=nil;
        if(self.tools.userInteractionEnabled) [self expandTools]; // Start a fresh idle interval.
    }
}
