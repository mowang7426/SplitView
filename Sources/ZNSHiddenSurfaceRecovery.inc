// Called by reconcile, and executed verbatim in the host event suite.
// A render-server layer/inputViews can outlive UIKit dismissal. In portrait,
// only a NEW App Shown phase may resurrect a hidden placement; a stale native
// surface is not a second source of truth that can undo the hidden proof.
- (void)znsRecoverHiddenNativeSurface {
    if (self.portraitExpansion &&
        ZNSReadClientKeyboardPhase(self.clientPID)!=ZNSClientKeyboardShown) return;
    if (self.keyboardHidden && !self.explicitlyDismissed && self.external && !self.invalidated &&
        self.active && !self.suspended && self.host.window && ZNSKeyboardHookReady &&
        self.clientPID>0 && self.clientPID==ZNSKeyboardClientPID(self) &&
        CACurrentMediaTime()-self.hiddenAt>0.4 && ZNSKeyboardMatchesFocus(self) &&
        ZNSKeyboardInputPresent(ZNSKeyboardObject(ZNSActiveKeyboardDelegate(),@"inputViews"))) {
        UIView *liveKeyboard=[self findKeyboard];
        if (liveKeyboard && liveKeyboard.window && ZNSKeyboardVisible(liveKeyboard) &&
            ZNSFiniteRect(liveKeyboard.bounds)) self.keyboardHidden=NO;
    }
}
