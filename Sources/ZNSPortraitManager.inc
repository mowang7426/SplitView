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
    ZNSKeyboardPlacement *placement=(ZNSKeyboardPlacement *)owner.session.keyboardPlacement;
    BOOL ownerMatch=owner && notification.object==placement &&
        [owner.session.bundleIdentifier isEqual:event[@"bundle"]];
    BOOL identityMatch=ownerMatch && [placement znsPortraitOwnerIdentityCurrent];
    BOOL ended=[event[@"ended"] boolValue];
    ZNSPortraitClose close=[event[@"closeKind"] unsignedIntegerValue];
    BOOL verifiedClose=ownerMatch && ended && close!=ZNSPortraitCloseNone;
    NSString *exitReason=!ownerMatch?@"owner_mismatch":!identityMatch?@"owner_identity_changed":
        ([placement znsPortraitExplicitExit] && !verifiedClose)?@"placement_exit":
        !self.enabled?@"manager_disabled":
        self.window.hidden||owner.hidden?@"window_hidden":
        owner.closing||owner.dismissing?@"window_closing":
        owner.docked||owner.thumbnail||owner.dipped?@"window_parked":
        owner.rebounding||owner.fullscreenExpanding?@"window_transition":
        owner.activeManipulation?@"user_manipulation":owner.session.landscape?@"landscape":nil;
    CGRect target=CGRectZero;
    UIView *root=owner.superview;
    UIWindow *source=event[@"window"];
    NSString *geometryReason=!owner.ready?@"not_ready":owner.session.layoutInFlight?@"layout_in_flight":
        !root?@"root_missing":!source?@"source_missing":
        ![event[@"frame"] isKindOfClass:NSValue.class]?@"frame_missing":nil;
    BOOL eligible=!ended && !exitReason && !geometryReason;
    if (eligible) {
        CGRect keyboard=[root convertRect:[event[@"frame"] CGRectValue] fromView:source];
        eligible=ZNSPortraitKeyboardTarget(keyboard,root.bounds,root.safeAreaInsets.top,&target);
        if (!eligible) geometryReason=@"target_invalid";
    }
    // A matched, still-expanded owner survives transient geometry loss. Never
    // hold across an owner change or terminal hide. Scene rollback is separate.
    BOOL holdUnknown=!eligible && ownerMatch && !exitReason && !ended && !verifiedClose &&
        [placement znsPortraitCanPreserveUnknown] && owner.portraitKeyboardExpanded;
    if (!eligible && owner.portraitKeyboardExpanded)
        ZNSKeyboardDiagDecision(@"portrait_geometry", 0,
            @{@"restoreReason":holdUnknown?@"preserve_matched_owner":ended?@"owner_ended":exitReason?:@"input_unproven",
              @"geometryReason":geometryReason?:@"none", @"restoreAuth":@(verifiedClose),
              @"ownerMatch":@(ownerMatch), @"identityMatch":@(identityMatch), @"expanded":@YES, @"windowMatch":@(source!=nil),
              @"continuity":@([event[@"continuity"] boolValue]), @"ended":@(ended), @"closeKind":@(close),
              @"layoutInFlight":@(owner.session.layoutInFlight), @"ready":@(owner.ready),
              @"preservedExistingExpansion":@(holdUnknown)});
    // Scene/host callbacks can synchronously remove windows during recovery.
    for (ZNSFloatingView *view in [self.windows copy]) {
        BOOL suppressed=view.portraitKeyboardSuppressed;
        if (view!=owner || (!eligible && !holdUnknown)) {
            BOOL verifiedClose=view==owner && ownerMatch && ended && close!=ZNSPortraitCloseNone;
            BOOL normalClose=verifiedClose && !exitReason && !owner.session.layoutInFlight;
            if (view.portraitKeyboardExpanded)
                ZNSKeyboardDiagDecision(normalClose?@"portrait_verified_restore":@"portrait_generic_restore", 0,
                    @{@"restoreReason":view!=owner?@"non_owner":exitReason?:
                        verifiedClose?(close==ZNSPortraitCloseClient?@"client_did_hide":@"native_paired_empty"):
                        ended?@"lifecycle_end":@"input_unproven",
                      @"geometryReason":geometryReason?:@"none", @"windowMatch":@(source!=nil),
                      @"ownerMatch":@(view==owner && ownerMatch), @"identityMatch":@(view==owner && identityMatch), @"expanded":@YES,
                      @"restoreAuth":@(verifiedClose), @"ended":@(ended), @"closeKind":@(close),
                      @"continuity":@([event[@"continuity"] boolValue]),
                      @"layoutInFlight":@(view.session.layoutInFlight), @"ready":@(view.ready)});
            if (normalClose) [view znsRestorePortraitKeyboardAfterHide];
            else [view restorePortraitKeyboardWithDuration:duration options:options];
            // Transport/eligibility loss is not an explicit drag or API failure.
            // Preserve an existing user suppression, but do not create one.
            view.portraitKeyboardSuppressed=suppressed;
        }
        if (notification.object==view.session.keyboardPlacement && [event[@"ended"] boolValue])
            view.portraitKeyboardSuppressed=NO;
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
