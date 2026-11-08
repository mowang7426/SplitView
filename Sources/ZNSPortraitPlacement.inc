// Shared production methods, executed verbatim by PortraitEventTests.
// A reparent/canvas refresh is NOT a keyboard hide. Keep only an already
// ownership-proven presentation. Bounded grace is for an unconfirmed remount;
// an App-confirmed shown latch is NOT expired by that deadline.
- (BOOL (^)(void))znsPortraitHiddenRestoreGuard {
    NSUInteger phase=self.portraitKeyboardVisualPhaseGeneration;
    pid_t pid=self.clientPID;
    NSString *bundle=[self.bundleIdentifier copy];
    __weak typeof(self) weakSelf=self;
    return [^BOOL{
        typeof(self) owner=weakSelf;
        return owner && owner.clientPID==pid && pid>0 &&
            [owner.bundleIdentifier isEqual:bundle] && owner.portraitKeyboardVisualPhaseGeneration==phase &&
            owner.portraitExpansion && owner.active && !owner.suspended && !owner.invalidated &&
            owner.clientVisibilityKnown && owner.keyboardHidden && !owner.clientKeyboardShown &&
            !owner.clientKeyboardWillHide && ZNSKeyboardMatchesFocus(owner) &&
            ZNSReadClientHiddenProof(pid,owner.znsHiddenProofRequest,owner.znsHiddenProofPhase)==2;
    } copy];
}
- (BOOL)znsPortraitKeyboardContinuity {
    // PID-validated App phase + same focused scene survive temporary UIKit
    // host/surface/geometry loss; only DidHide or lifecycle/focus loss ends it.
    return self.portraitExpansion && self.active && !self.suspended &&
        !self.invalidated && !self.dismissPending && !self.explicitlyDismissed &&
        !self.keyboardHidden && self.clientVisibilityKnown &&
        (self.clientKeyboardShown || self.clientKeyboardWillHide) &&
        ZNSKeyboardMatchesFocus(self);
}
- (BOOL)znsPortraitPresentationEligible {
    if (!self.portraitExpansion || !self.active || self.suspended ||
        self.invalidated || self.keyboardHidden || self.dismissPending || !self.host.window ||
        !ZNSKeyboardMatchesFocus(self) || !ZNSFiniteRect(self.portraitKeyboardFrame)) return NO;
    BOOL visible=[self externalKeyboardVisible];
    if (visible && self.clientVisibilityKnown && self.clientKeyboardShown) self.portraitKeyboardVisibleLatch=YES;
    BOOL continuous=self.portraitCanvasTransitionUntil>CACurrentMediaTime();
    return visible || self.portraitKeyboardVisibleLatch || continuous;
}
- (void)znsBeginPortraitGeometryRefresh {
    if (!self.portraitExpansion || ![self externalKeyboardVisible]) return;
    if (ZNSKeyboardMatchesFocus(self) && self.clientVisibilityKnown && self.clientKeyboardShown)
        self.portraitKeyboardVisibleLatch=YES;
    if (self.portraitCanvasTransitionUntil<=CACurrentMediaTime()) {
        self.portraitCanvasTransitionUntil=CACurrentMediaTime()+1.2;
        [self rejectExternal:@"P3_REFRESH_BEGIN"];
    }
}
- (void)znsReparentForNativeKeyboardUpdate {
    // Existing show/setFrame hooks must arm continuity BEFORE detaching too,
    // not only the scene transaction and notification-driven geometry path.
    [self znsBeginPortraitGeometryRefresh];
    [self restore];
}
- (BOOL)znsMayAcceptNativeShown {
    return !self.portraitExpansion || !self.keyboardHidden ||
        ZNSReadClientKeyboardPhase(self.clientPID)==ZNSClientKeyboardShown;
}
- (void)znsApplyNativeShowResult:(BOOL)result inputPresent:(BOOL)inputPresent {
    if (self.dismissPending || self.explicitlyDismissed || !ZNSKeyboardMatchesFocus(self)) return;
    BOOL hidden=!result || !inputPresent;
    if (!hidden && ![self znsMayAcceptNativeShown]) return;
    if (hidden && [self znsDeferPortraitSystemHide]) {
        [self rejectExternal:@"P3_SHOW_HINT_DURING_REPARENT"];
        return;
    }
    self.keyboardHidden=hidden;
}
- (void)znsResampleHiddenProof {
    if (ZNSReadClientHiddenProof(self.clientPID,
        self.znsHiddenProofRequest,self.znsHiddenProofPhase)!=2)
        self.znsHiddenProofRequest=0; // retry unknown/visible, never fabricate absence
}
- (void)znsAcceptClientPhase:(ZNSClientKeyboardPhase)phase {
    if (phase==ZNSClientKeyboardHidden) {
        // A PID-valid DidHide is still only a notification, not live absence.
        // QQ scene resize/remount may emit it while the keyboard remains shown.
        uint64_t current=ZNSReadClientKeyboardPhaseWord(self.clientPID);
        if ((current&3)!=ZNSClientKeyboardHidden || !ZNSKeyboardMatchesFocus(self)) return;
        NSInteger proof=ZNSReadClientHiddenProof(self.clientPID,self.znsHiddenProofRequest,current);
        if (self.znsHiddenProofPhase==current && proof==2) {
            if (!self.clientVisibilityKnown || !self.keyboardHidden || self.clientKeyboardWillHide) [self znsClientDidHide];
            return;
        }
        // Visible or unknown is continuity, never permission to restore scene.
        // Keep polling via the existing active placement timer, not a timeout
        // that converts uncertainty into success. A fresh Shown supersedes it.
        if (self.clientKeyboardWillHide || self.keyboardHidden) {
            [self znsAcceptClientPhase:ZNSClientKeyboardShown];
        }
        if (self.znsHiddenProofPhase==current && self.znsHiddenProofRequest) return;
        self.znsHiddenProofPhase=current;
        self.znsHiddenProofRequest=ZNSRequestClientHiddenProof(self.clientPID,current);
        return;
    }
    if (phase==ZNSClientKeyboardWillHide) { [self znsClientWillHide]; return; }
    if (phase!=ZNSClientKeyboardShown || self.dismissPending) return;
    BOOL cancelledHide=self.clientKeyboardWillHide || self.keyboardHidden;
    self.clientVisibilityKnown=YES; self.clientKeyboardShown=YES;
    self.clientKeyboardWillHide=NO;
    // Invalidate queued hide delivery; reversing an active transform is also
    // asynchronous so no UIKit native setter can enter manager on this stack.
    NSUInteger generation=cancelledHide?++self.portraitKeyboardVisualPhaseGeneration:self.portraitKeyboardVisualPhaseGeneration;
    if (cancelledHide) ZNSPublishPortraitVisualWillHideAsync(self,generation,self.clientPID,
        [self.bundleIdentifier copy],self.presentationTimingKnown?self.presentationDuration:0.25,
        self.presentationOptions,NO);
    if (ZNSKeyboardMatchesFocus(self)) {
        self.explicitlyDismissed=NO; self.keyboardHidden=NO;
        if ([self externalKeyboardVisible] || self.portraitCanvasTransitionUntil>CACurrentMediaTime())
            self.portraitKeyboardVisibleLatch=YES;
    }
    [self schedule];
}
- (void)znsClientWillHide {
    if (self.clientKeyboardWillHide) return;
    self.clientKeyboardWillHide=YES;
    self.clientVisibilityKnown=YES; self.clientKeyboardShown=NO;
    // Never enter manager/scene/placement synchronously from the App phase or
    // native UIKit notification stack. Publish only after a main-queue turn,
    // bound to the same owner PID, bundle and phase generation.
    NSUInteger generation=++self.portraitKeyboardVisualPhaseGeneration;
    pid_t pid=self.clientPID;
    NSString *bundle=[self.bundleIdentifier copy];
    NSTimeInterval duration=self.presentationTimingKnown?self.presentationDuration:0.25;
    UIViewAnimationOptions options=self.presentationOptions;
    ZNSPublishPortraitVisualWillHideAsync(self,generation,pid,bundle,duration,options,YES);
}
- (void)znsClientDidHide {
    self.portraitKeyboardVisualPhaseGeneration++;
    self.portraitCanvasTransitionUntil=0;
    self.clientKeyboardWillHide=NO; self.portraitKeyboardVisibleLatch=NO;
    self.keyboardHidden=YES; self.hiddenAt=CACurrentMediaTime();
    self.clientVisibilityKnown=YES; self.clientKeyboardShown=NO;
    self.dismissPending=NO; self.dismissGeneration++;
    self.reportedKeyboardFrame=CGRectZero; self.frameDelegate=nil;
    [self clearShowProof]; [self restore];
    [self rejectExternal:@"P3_CLIENT_HIDE"];
}
- (BOOL)znsDeferPortraitSystemHide {
    // SpringBoard notifications caused by our own detach/reparent are not
    // authoritative App dismissal. The PID-validated client hidden event is
    // always honored, including during this interval; no synthetic events.
    return self.portraitExpansion && !self.dismissPending && !self.explicitlyDismissed &&
        !self.clientKeyboardWillHide &&
        (self.mutating || self.portraitKeyboardVisibleLatch || self.portraitCanvasTransitionUntil>CACurrentMediaTime()) &&
        ZNSKeyboardMatchesFocus(self) &&
        ZNSKeyboardInputPresent(ZNSKeyboardObject(ZNSActiveKeyboardDelegate(),@"inputViews"));
}
- (void)znsAcceptClientGeometry:(CGRect)region canvas:(CGSize)canvas valid:(BOOL)valid focused:(BOOL)focused {
    if (self.clientKeyboardWillHide || self.dismissPending) return;
    // A queued geometry callback may outlive DidHide and the small-scene
    // handoff. Geometry cannot resurrect a confirmed hidden portrait owner.
    if (self.portraitExpansion && self.keyboardHidden &&
        ZNSReadClientKeyboardPhase(self.clientPID)!=ZNSClientKeyboardShown) {
        [self rejectExternal:@"P3_GEOMETRY_AFTER_HIDE"]; return;
    }
    if (self.portraitExpansion && (!valid || fabs(canvas.width-self.canvas.width)>1 ||
                                  fabs(canvas.height-self.canvas.height)>1)) {
        // A zero serial, old canvas, or partial scene/window resize is unknown,
        // NOT hidden. Never tear down the last good surface for this sample.
        [self rejectExternal:valid?@"P3_GEOMETRY_OLD_CANVAS":@"P3_GEOMETRY_PENDING"];
        [self schedule]; return;
    }
    if (!CGRectEqualToRect(region,self.clientKeyboardRegion) || !CGSizeEqualToSize(canvas,self.clientKeyboardCanvas)) {
        [self znsBeginPortraitGeometryRefresh];
        [self restore];
        self.geometryKeyboard=nil; self.geometryDelegate=nil;
        self.clientKeyboardRegion=region; self.clientKeyboardCanvas=canvas;
    }
    if (valid && focused && !self.dismissPending) {
        self.clientVisibilityKnown=YES; self.clientKeyboardShown=YES; self.clientKeyboardWillHide=NO;
        self.portraitKeyboardVisibleLatch=YES; self.keyboardHidden=NO;
    }
    [self schedule];
}
- (void)updateTemporaryPortraitCanvas:(CGSize)canvas {
    if (!CGSizeEqualToSize(self.canvas,canvas)) {
        [self znsBeginPortraitGeometryRefresh];
        [self restore];
        self.geometryKeyboard=nil; self.geometryDelegate=nil;
        self.geometryBounds=CGRectZero; self.geometryContent=CGRectZero;
        self.clientKeyboardRegion=CGRectZero; self.clientKeyboardCanvas=CGSizeZero;
        self.frameDelegate=nil; self.reportedKeyboardFrame=CGRectZero;
        self.canvas=canvas;
    }
    [self requestPortraitClientGeometry];
    [self schedule];
}
