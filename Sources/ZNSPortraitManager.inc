// Production implementation; also executed verbatim by PortraitEventTests.
- (void)portraitKeyboardWillHideVisual:(NSNotification *)notification {
    NSDictionary *event=notification.userInfo;
    ZNSFloatingView *owner=self.floating;
    if (!self.enabled || self.window.hidden || !owner || ![self.windows containsObject:owner] ||
        notification.object!=owner.session.keyboardPlacement ||
        ![owner.session.bundleIdentifier isEqual:event[@"bundle"]] ||
        !owner.ready || owner.hidden || owner.closing || owner.docked || owner.thumbnail ||
        owner.dipped || owner.dismissing || owner.rebounding || owner.fullscreenExpanding ||
        owner.activeManipulation || owner.session.layoutInFlight || owner.session.landscape ||
        !owner.portraitKeyboardExpanded || owner.portraitKeyboardRestoring ||
        owner.portraitKeyboardSuppressed) return;
    NSTimeInterval duration=[event[@"duration"] doubleValue];
    UIViewAnimationOptions options=[event[@"options"] unsignedIntegerValue];
    if ([event[@"hiding"] boolValue])
        [owner beginPortraitKeyboardVisualRestoreWithDuration:duration options:options];
    else [owner cancelPortraitKeyboardVisualRestoreWithDuration:duration options:options];
}
- (void)portraitKeyboardGeometryChanged:(NSNotification *)notification {
    NSDictionary *event=notification.userInfo;
    NSTimeInterval duration=[event[@"duration"] doubleValue];
    UIViewAnimationOptions options=[event[@"options"] unsignedIntegerValue];
    ZNSFloatingView *owner=self.floating;
    BOOL eligible=self.enabled && !self.window.hidden && owner.ready && !owner.hidden &&
        !owner.closing && !owner.docked && !owner.thumbnail && !owner.dipped &&
        !owner.dismissing && !owner.rebounding && !owner.fullscreenExpanding &&
        !owner.activeManipulation && !owner.session.layoutInFlight && !owner.session.landscape &&
        [owner.session.bundleIdentifier isEqual:event[@"bundle"]];
    CGRect target=CGRectZero;
    UIView *root=owner.superview;
    UIWindow *source=event[@"window"];
    if (eligible && root && source && [event[@"frame"] isKindOfClass:NSValue.class]) {
        CGRect keyboard=[root convertRect:[event[@"frame"] CGRectValue] fromView:source];
        eligible=ZNSPortraitKeyboardTarget(keyboard,root.bounds,root.safeAreaInsets.top,&target);
    } else eligible=NO;
    // Keep only the SAME live, focused App's already-expanded scene through
    // transient host/window remount, in-flight layout or invalid conversion.
    // Explicit end, close, drag, park, rotation and non-owner still restore.
    BOOL holdUnknown=!eligible && ![event[@"ended"] boolValue] &&
        [event[@"continuity"] boolValue] && owner.portraitKeyboardExpanded &&
        [owner.session.bundleIdentifier isEqual:event[@"bundle"]] && self.enabled &&
        !self.window.hidden && !owner.hidden && !owner.closing && !owner.docked &&
        !owner.thumbnail && !owner.dipped && !owner.dismissing &&
        !owner.rebounding && !owner.fullscreenExpanding &&
        !owner.activeManipulation && !owner.session.landscape;
    // Scene/host callbacks can synchronously remove windows during recovery.
    for (ZNSFloatingView *view in [self.windows copy]) {
        BOOL suppressed=view.portraitKeyboardSuppressed;
        if (view!=owner || (!eligible && !holdUnknown)) {
            if (view==owner && [event[@"clientHidden"] boolValue] && [event[@"ended"] boolValue] &&
                [owner.session.bundleIdentifier isEqual:event[@"bundle"]] &&
                !owner.closing && !owner.dismissing && !owner.activeManipulation &&
                !owner.docked && !owner.thumbnail && !owner.dipped && !owner.rebounding &&
                !owner.fullscreenExpanding && !owner.session.landscape) {
                __weak typeof(self) weakManager=self;
                __weak ZNSFloatingView *weakOwner=owner;
                __weak ZNSSceneSession *weakSession=owner.session;
                __weak typeof(owner.session.keyboardPlacement) weakPlacement=owner.session.keyboardPlacement;
                BOOL (^sessionGuard)(void)=[owner.session znsPortraitRestoreSessionGuard];
                BOOL (^hiddenGuard)(void)=[owner.session.keyboardPlacement znsPortraitHiddenRestoreGuard];
                owner.portraitKeyboardHideRetryGuard=^BOOL{
                    typeof(self) manager=weakManager;
                    ZNSFloatingView *live=weakOwner;
                    return manager && live && manager.enabled && !manager.window.hidden &&
                        manager.floating==live && [manager.windows containsObject:live] &&
                        live.session==weakSession && live.session.keyboardPlacement==weakPlacement && sessionGuard() &&
                        live.ready && !live.hidden && !live.closing && !live.dismissing &&
                        !live.activeManipulation && !live.docked && !live.thumbnail && !live.dipped &&
                        !live.rebounding && !live.fullscreenExpanding && !live.session.landscape &&
                        hiddenGuard();
                };
                [view znsRestorePortraitKeyboardAfterHide];
            }
            else [view restorePortraitKeyboardWithDuration:duration options:options];
            // Transport/eligibility loss is not an explicit drag or API failure.
            // Preserve an existing user suppression, but do not create one.
            view.portraitKeyboardSuppressed=suppressed;
        }
        if ([event[@"ended"] boolValue]) view.portraitKeyboardSuppressed=NO;
    }
    if (!eligible) {
        static CFTimeInterval lastDiagnostic;
        if (holdUnknown && CACurrentMediaTime()-lastDiagnostic>2) {
            lastDiagnostic=CACurrentMediaTime();
            os_log(ZNSLog(),"P6_RESUME_UNKNOWN reason=manager-transient inFlight=%d ready=%d geometry=%d",owner.session.layoutInFlight,owner.ready,source!=nil);
        }
        if (event[@"bundle"] && CACurrentMediaTime()-lastDiagnostic>2) {
            lastDiagnostic=CACurrentMediaTime();
            os_log(ZNSLog(),"P3_MANAGER_GATE enabled=%d visible=%d ready=%d parked=%d gesture=%d inFlight=%d landscape=%d ownerMatch=%d target=%.1fx%.1f",self.enabled,!self.window.hidden,owner.ready,owner.docked||owner.thumbnail||owner.dipped,owner.activeManipulation!=nil,owner.session.layoutInFlight,owner.session.landscape,[owner.session.bundleIdentifier isEqual:event[@"bundle"]],target.size.width,target.size.height);
        }
        return;
    }
    if (owner!=self.floating || ![self.windows containsObject:owner] || owner.closing ||
        owner.dismissing || !owner.ready || !self.enabled || self.window.hidden) return;
    [owner expandPortraitKeyboardToFrame:target duration:duration options:options];
}
