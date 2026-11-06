// Production implementation; also executed verbatim by PortraitEventTests.
#include "ZNSPortraitCompensation.inc"
- (void)clearPortraitKeyboardVisualRestore {
    [self znsClearPortraitChrome];
    if (!self.portraitKeyboardVisualRestoring) return;
    self.portraitKeyboardVisualRestoreGeneration++;
    // Own only our transform animation; never remove unrelated layer animations.
    [self.layer removeAnimationForKey:@"transform"];
    // Commit the root transform and the child-view counter-transforms in one
    // no-animation transaction. Clearing compensation in a separate UIKit
    // transaction exposes one frame where the content has expanded while the
    // floating window is still visually scaled (the keyboard-dismiss jump).
    [UIView performWithoutAnimation:^{
        self.transform=CGAffineTransformIdentity;
        [self znsClearPortraitCompensation];
    }];
    self.portraitKeyboardVisualRestoring=NO;
    [self updateContentInputGate];
    self.portraitKeyboardVisualReturning=NO;
    self.portraitKeyboardVisualRestoreCompleted=NO;
    self.portraitKeyboardVisualFinalizePending=NO;
}
- (void)beginPortraitKeyboardVisualRestoreWithDuration:(NSTimeInterval)duration options:(UIViewAnimationOptions)options {
    if (!self.portraitKeyboardExpanded || self.portraitKeyboardRestoring ||
        self.portraitKeyboardSuppressed ||
        (self.portraitKeyboardVisualRestoring && !self.portraitKeyboardVisualReturning)) return;
    CGRect target=self.portraitKeyboardTarget,saved=self.portraitKeyboardSavedFrame;
    // The root transform belongs to other gesture/rotation features too. Never
    // take it over unless it is identity (or already belongs to this transition).
    if ((!self.portraitKeyboardVisualRestoring && !CGAffineTransformIsIdentity(self.transform)) ||
        !isfinite(target.origin.x) || !isfinite(target.origin.y) ||
        !isfinite(target.size.width) || !isfinite(target.size.height) ||
        !isfinite(saved.origin.x) || !isfinite(saved.origin.y) ||
        !isfinite(saved.size.width) || !isfinite(saved.size.height) ||
        self.session.temporaryPortraitCanvas.width<=0 || self.session.temporaryPortraitCanvas.height<=0 ||
        target.size.width<=0 || target.size.height<=0 || saved.size.width<=0 || saved.size.height<=0 ||
        !CGSizeEqualToSize(self.bounds.size,target.size) ||
        !CGPointEqualToPoint(self.center,CGPointMake(CGRectGetMidX(target),CGRectGetMidY(target)))) return;
    NSUInteger generation=++self.portraitKeyboardVisualRestoreGeneration;
    self.portraitKeyboardVisualRestoring=YES;
    [self updateContentInputGate];
    self.portraitKeyboardVisualReturning=NO;
    self.portraitKeyboardVisualRestoreCompleted=NO;
    self.portraitKeyboardVisualFinalizePending=NO;
    CGAffineTransform visual=CGAffineTransformMake(saved.size.width/target.size.width,0,0,
        saved.size.height/target.size.height,CGRectGetMidX(saved)-CGRectGetMidX(target),
        CGRectGetMidY(saved)-CGRectGetMidY(target));
    __weak typeof(self) weakSelf=self;
    void (^finish)(BOOL)=^(BOOL finished){
        (void)finished;
        typeof(self) owner=weakSelf;
        if (!owner || owner.portraitKeyboardVisualRestoreGeneration!=generation) return;
        owner.portraitKeyboardVisualRestoreCompleted=YES;
        if (owner.portraitKeyboardVisualFinalizePending) {
            BOOL suppressed=owner.portraitKeyboardSuppressed;
            [owner znsRestorePortraitKeyboardAfterHide];
            owner.portraitKeyboardSuppressed=suppressed;
        }
    };
    NSTimeInterval effectiveDuration=UIAccessibilityIsReduceMotionEnabled()?0:(isfinite(duration)?MAX(0,duration):0);
    // No frame/bounds/center setters, layoutIfNeeded, snapshots or scene calls.
    // Body/content/canvas counter-map their own endpoints; native keyboard still hides
    // under UIKit's own animation in its existing surface hierarchy.
    if (effectiveDuration<=0) {
        [UIView performWithoutAnimation:^{ self.transform=visual; [self znsSetPortraitCompensation:YES]; }]; finish(YES);
    } else [UIView animateWithDuration:effectiveDuration delay:0
        options:options|UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction
        animations:^{ self.transform=visual; [self znsSetPortraitCompensation:YES]; } completion:finish];
}
- (void)znsResumePortraitAfterHide {
    if (!self.session.znsPortraitRestorePending) return;
    [self.session znsCancelPortraitRestore];
    CGRect frame=[self.superview convertRect:self.portraitKeyboardTarget toView:self.window];
    [self.session applyTemporaryPortraitFrame:frame failure:nil];
}
- (void)znsRestorePortraitKeyboardAfterHide {
    if (!self.portraitKeyboardExpanded || self.portraitKeyboardRestoring || self.session.znsPortraitRestorePending) return;
    if (self.portraitKeyboardVisualRestoring && !self.portraitKeyboardVisualReturning &&
        !self.portraitKeyboardVisualRestoreCompleted) {
        self.portraitKeyboardVisualFinalizePending=YES;
        return;
    }
    NSUInteger generation=self.portraitKeyboardRestoreGeneration;
    __weak typeof(self) weakSelf=self;
    // Child counter-maps are removed inside the same no-animation host handoff,
    // immediately before ZNSConfigureHostCanvas observes the restored canvas.
    // The completion clears the root transform before normal UIKit layout.
    self.session.znsPortraitRestorePrepareVisual=^{
        typeof(self) owner=weakSelf;
        if (owner && owner.portraitKeyboardVisualRestoring &&
            owner.portraitKeyboardRestoreGeneration==generation)
            [owner znsClearPortraitCompensation];
    };
    BOOL accepted=[self.session znsRestorePortraitAfterHide:^(BOOL success) {
        typeof(self) owner=weakSelf;
        if (!owner || owner.portraitKeyboardRestoreGeneration!=generation) return;
        if (success) {
            BOOL suppressed=owner.portraitKeyboardSuppressed;
            [owner restorePortraitKeyboardWithDuration:0 options:0];
            owner.portraitKeyboardSuppressed=suppressed;
        } else {
            [owner clearPortraitKeyboardVisualRestore];
        }
    }];
    if (!accepted) {
        self.session.znsPortraitRestorePrepareVisual=nil;
        [self clearPortraitKeyboardVisualRestore];
    }
}
- (void)cancelPortraitKeyboardVisualRestoreWithDuration:(NSTimeInterval)duration options:(UIViewAnimationOptions)options {
    [self znsResumePortraitAfterHide];
    if (!self.portraitKeyboardVisualRestoring || self.portraitKeyboardVisualReturning) return;
    NSUInteger generation=++self.portraitKeyboardVisualRestoreGeneration;
    self.portraitKeyboardVisualReturning=YES;
    self.portraitKeyboardVisualFinalizePending=NO;
    self.portraitKeyboardVisualRestoreCompleted=NO;
    __weak typeof(self) weakSelf=self;
    void (^finish)(BOOL)=^(BOOL finished){
        (void)finished;
        typeof(self) owner=weakSelf;
        if (!owner || owner.portraitKeyboardVisualRestoreGeneration!=generation) return;
        [owner clearPortraitKeyboardVisualRestore];
    };
    NSTimeInterval effectiveDuration=UIAccessibilityIsReduceMotionEnabled()?0:(isfinite(duration)?MAX(0,duration):0);
    if (effectiveDuration<=0) {
        [UIView performWithoutAnimation:^{ self.transform=CGAffineTransformIdentity; [self znsSetPortraitCompensation:NO]; }]; finish(YES);
    } else [UIView animateWithDuration:effectiveDuration delay:0
        options:options|UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction
        animations:^{ self.transform=CGAffineTransformIdentity; [self znsSetPortraitCompensation:NO]; } completion:finish];
}
- (void)expandPortraitKeyboardToFrame:(CGRect)frame duration:(NSTimeInterval)duration options:(UIViewAnimationOptions)options {
    [self znsClearPortraitChrome];
    if (self.session.znsPortraitRestorePending)
        [self cancelPortraitKeyboardVisualRestoreWithDuration:duration options:options];
    [self znsResumePortraitAfterHide];
    if (self.portraitKeyboardSuppressed || self.portraitKeyboardRestoring || self.portraitKeyboardVisualRestoring) return;
    if (self.portraitKeyboardExpanded && CGRectEqualToRect(frame,self.portraitKeyboardTarget)) return;
    self.portraitKeyboardRestoreGeneration++;
    if (!self.portraitKeyboardExpanded) {
        self.portraitKeyboardSavedFrame=self.frame;
        self.portraitKeyboardSavedExpandedFrame=self.expandedFrame;
    }
    self.portraitKeyboardExpanded=YES;
    self.portraitKeyboardTarget=frame;
    CGRect screenFrame=[self.superview convertRect:frame toView:self.window];
    __weak typeof(self) weakSelf=self;
    [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled()?0:duration delay:0
        options:options|UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{
            BOOL accepted=[self.session applyTemporaryPortraitFrame:screenFrame failure:^{
                [weakSelf restorePortraitKeyboardWithDuration:duration options:options];
            }];
            if (!accepted) {
                [self restorePortraitKeyboardWithDuration:0 options:0];
                return;
            }
            // A synchronous host callback may have cancelled this expansion.
            if (!self.portraitKeyboardExpanded || !CGRectEqualToRect(self.portraitKeyboardTarget,frame)) return;
            self.frame=frame; [self setNeedsLayout]; [self layoutIfNeeded];
        } completion:nil];
}
- (void)restorePortraitKeyboardWithDuration:(NSTimeInterval)duration options:(UIViewAnimationOptions)options {
    if (self.session.znsPortraitHandoffInFlight) return;
    [self znsClearPortraitChrome];
    [self.session znsCancelPortraitRestore];
    if (!self.portraitKeyboardExpanded || self.portraitKeyboardRestoring) return;
    // DidHide can race the visual completion by one run-loop turn. Finish that
    // same animation instead of creating a second collapse. Lifecycle callers
    // pass zero (or fail the normal-state gate) and finalize immediately.
    if (self.portraitKeyboardVisualRestoring && !self.portraitKeyboardVisualReturning &&
        !self.portraitKeyboardVisualRestoreCompleted && duration>0 &&
        !self.closing && !self.dismissing && !self.activeManipulation &&
        !self.docked && !self.thumbnail && !self.dipped && !self.rebounding &&
        !self.fullscreenExpanding && !self.session.landscape) {
        self.portraitKeyboardVisualFinalizePending=YES;
        return;
    }
    BOOL visualRestore=self.portraitKeyboardVisualRestoring;
    BOOL ownsVisualFrame=visualRestore && CGSizeEqualToSize(self.bounds.size,self.portraitKeyboardTarget.size) &&
        CGPointEqualToPoint(self.center,CGPointMake(CGRectGetMidX(self.portraitKeyboardTarget),CGRectGetMidY(self.portraitKeyboardTarget)));
    NSUInteger generation=++self.portraitKeyboardRestoreGeneration;
    self.portraitKeyboardRestoring=YES;
    self.portraitKeyboardSuppressed=YES;
    // Safety downgrade: no remote-surface snapshot or private animation context.
    // Restore native canvas BEFORE switching out of unit-scale expanded layout.
    // Keep the saved frame on submission failure so an explicit retry can work.
    if (visualRestore) [self clearPortraitKeyboardVisualRestore];
    BOOL restored=NO;
    @try { restored=[self.session restoreTemporaryPortraitCanvas]; }
    @catch (NSException *exception) {
        os_log_error(ZNSLog(),"P5_RESTORE_EXCEPTION %{public}@; saved floating frame retained",exception.name);
    }
    if (!restored) {
        os_log_error(ZNSLog(),"P5_RESTORE_RETRY; saved floating frame retained");
        if (self.portraitKeyboardRestoreGeneration==generation) self.portraitKeyboardRestoring=NO;
        [self clearPortraitKeyboardVisualRestore];
        return;
    }
    CGRect saved=self.portraitKeyboardSavedFrame;
    BOOL ownsFrame=visualRestore?ownsVisualFrame:CGRectEqualToRect(self.frame,self.portraitKeyboardTarget);
    self.portraitKeyboardExpanded=NO;
    self.expandedFrame=self.portraitKeyboardSavedExpandedFrame;
    __weak typeof(self) weakSelf=self;
    void (^finish)(void)=^{
        typeof(self) strongSelf=weakSelf;
        if (!strongSelf || strongSelf.portraitKeyboardRestoreGeneration!=generation) return;
        strongSelf.portraitKeyboardTarget=CGRectZero;
        strongSelf.portraitKeyboardSavedFrame=CGRectZero;
        strongSelf.portraitKeyboardSavedExpandedFrame=CGRectZero;
        strongSelf.portraitKeyboardRestoring=NO;
    };
    void (^layout)(void)=^{
        typeof(self) strongSelf=weakSelf;
        if (!strongSelf || strongSelf.portraitKeyboardRestoreGeneration!=generation) return;
        [strongSelf clearPortraitKeyboardVisualRestore];
        if (ownsFrame) strongSelf.frame=saved;
        [strongSelf setNeedsLayout]; [strongSelf layoutIfNeeded];
    };
    NSTimeInterval effectiveDuration=UIAccessibilityIsReduceMotionEnabled()?0:MAX(0,duration);
    if (visualRestore || !ownsFrame || effectiveDuration<=0) {
        @try { [UIView performWithoutAnimation:layout]; }
        @finally { finish(); }
        if (visualRestore && !self.closing && !self.dismissing && !self.activeManipulation &&
            !self.docked && !self.thumbnail && !self.dipped && !self.rebounding &&
            !self.fullscreenExpanding && !self.session.landscape) {
            self.portraitKeyboardChromeFading=YES;
            NSUInteger chromeGeneration=self.portraitKeyboardVisualRestoreGeneration;
            [UIView performWithoutAnimation:^{ [self znsSetPortraitChromeAlpha:0]; }];
            [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled()?0:0.15 delay:0
                options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction
                animations:^{ [self znsSetPortraitChromeAlpha:1]; } completion:^(__unused BOOL done){
                    if (self.portraitKeyboardVisualRestoreGeneration==chromeGeneration) self.portraitKeyboardChromeFading=NO;
                }];
        }
        return;
    }
    @try {
        [UIView animateWithDuration:effectiveDuration delay:0
            options:options|UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction
            animations:layout completion:^(__unused BOOL finished){ finish(); }];
    } @catch (NSException *exception) {
        os_log_error(ZNSLog(),"P8_RESTORE_ANIMATION_EXCEPTION %{public}@; completing without animation",exception.name);
        @try { [UIView performWithoutAnimation:layout]; }
        @finally { finish(); }
    }
}
