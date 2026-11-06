// Production restore; shared verbatim with host transport tests.
- (void)restore {
    if (self.mutating) return;
    if (self.portraitExpansion && !self.clientKeyboardWillHide) ZNSPortraitRestoreTiming=@{
        @"duration":@(self.presentationTimingKnown?self.presentationDuration:0.25), @"options":@(self.presentationOptions),
        @"bundle":self.bundleIdentifier?:@"",
        @"clientHidden":@(self.clientVisibilityKnown && self.keyboardHidden && self.active &&
            !self.suspended && !self.invalidated && ZNSKeyboardMatchesFocus(self)),
        @"ended":@(self.keyboardHidden || !self.active || self.suspended || self.invalidated)};
    self.mutating=YES;
    self.nativeScreenKeyboard=NO;
    [self.keyboardContainer.layer removeAllAnimations];
    [self.dragHandle.layer removeAllAnimations];
    UIView *keyboard=self.keyboard,*parent=self.originalParent;
    self.window.hidden=YES; self.window.keyboard=nil;
    // If UIKit took the view elsewhere already, do not steal it back or write
    // stale geometry into a new presentation. Only undo our own attachment.
    @try {
    if (keyboard && (keyboard.superview==self.keyboardContainer || !keyboard.superview)) {
        [keyboard removeFromSuperview];
        keyboard.transform=self.savedTransform;
        keyboard.bounds=self.savedBounds; keyboard.center=self.savedCenter;
        keyboard.autoresizingMask=self.savedAutoresizing;
        keyboard.translatesAutoresizingMaskIntoConstraints=self.savedTranslates;
        if (parent) {
            [parent insertSubview:keyboard atIndex:MIN(self.originalIndex,parent.subviews.count)];
            [NSLayoutConstraint activateConstraints:self.savedConstraints?:@[]];
        }
        os_log(ZNSLog(),"keyboard external attachment restored parentAlive=%d",parent!=nil);
    }
    } @catch (NSException *exception) {
        self.invalidated=YES;
        [self.timer invalidate]; self.timer=nil;
        os_log_error(ZNSLog(),"keyboard restore exception=%{public}@; placement disabled for this session",exception.name);
    } @finally {
        self.keyboard=nil; self.originalParent=nil;
        self.window=nil; self.keyboardContainer=nil; self.dragHandle=nil;
        self.savedConstraints=nil;
        self.attachedDelegate=nil; self.independent=NO;
        self.mutating=NO;
        ZNSPublishKeyboardVisibility();
    }
}
