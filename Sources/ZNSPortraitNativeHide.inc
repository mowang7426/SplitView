// Shared by the SpringBoard notification observer and the host event tests.
- (void)znsHandlePortraitNativeHide:(BOOL)didHide phase:(ZNSClientKeyboardPhase)phase
                           delegate:(id)delegate input:(ZNSPortraitInputState)input {
    BOOL current=[self znsPortraitInputScopeCurrent];
    BOOL delegateMatch=current && delegate && delegate==self.portraitInputDelegate;
    BOOL armed=self.portraitNativeWillHide;
    BOOL active=self.portraitExpansion && self.active && !self.invalidated && !self.suspended &&
        ZNSKeyboardMatchesFocus(self);
    BOOL clientEnd=active && phase==ZNSClientKeyboardHidden;
    BOOL clientWill=active && phase==ZNSClientKeyboardWillHide;
    // Missing/unsupported inputViews is not an observed empty input set.
    // Native fallback requires a present -> empty transition observed on the
    // same delegate that owned a verified presentation, and a paired hide.
    BOOL nativeEnd=active && didHide && !self.mutating && delegateMatch && armed &&
        input==ZNSPortraitInputEmpty && phase==ZNSClientKeyboardUnknown &&
        !self.clientKeyboardWillHide && !(self.clientVisibilityKnown && self.clientKeyboardShown);
    if (didHide) self.portraitNativeWillHide=NO;
    else self.portraitNativeWillHide=active && delegateMatch && !self.mutating &&
        input==ZNSPortraitInputPresent && !clientEnd && !clientWill;
    ZNSKeyboardDiagDecision(didHide?@"portrait_native_did_hide":@"portrait_native_will_hide",
        self.dismissGeneration, @{
        @"restoreReason":clientEnd?@"client_did_hide":clientWill?@"client_will_hide":
            nativeEnd?@"native_paired_empty":@"native_hint_only",
        @"restoreAuth":@(clientEnd || clientWill || nativeEnd), @"clientPhase":@(phase),
        @"inputState":@(input), @"scopeMatch":@(current), @"delegateMatch":@(delegateMatch),
        @"hideArmed":@(armed), @"focusMatch":@(active), @"mutating":@(self.mutating),
        @"dismissPending":@(self.dismissPending), @"windowMatch":@(self.host.window!=nil)});
    if (clientEnd || clientWill) [self znsAcceptClientPhase:phase];
    else if (nativeEnd) [self znsFinishPortraitHide:ZNSPortraitCloseNative];
    [self schedule];
}
