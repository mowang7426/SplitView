// Production publisher shared verbatim with PortraitEventTests. No scene,
// layout, visibility publication or surface mutation is allowed in this path.
static void ZNSPublishPortraitVisualWillHideAsync(ZNSKeyboardPlacement *placement,
    NSUInteger generation, pid_t pid, NSString *bundle, NSTimeInterval duration,
    UIViewAnimationOptions options, BOOL hiding) {
    __weak ZNSKeyboardPlacement *weakPlacement=placement;
    dispatch_async(dispatch_get_main_queue(),^{
        ZNSKeyboardPlacement *owner=weakPlacement;
        if (!owner || owner.invalidated || owner.suspended || !owner.active ||
            owner.portraitKeyboardVisualPhaseGeneration!=generation ||
            owner.clientPID!=pid || pid<=0 || ZNSKeyboardClientPID(owner)!=pid ||
            owner.clientKeyboardWillHide!=hiding || (!hiding && !owner.clientKeyboardShown) ||
            owner.keyboardHidden || (!hiding && owner.dismissPending) ||
            !owner.portraitExpansion || !owner.portraitKeyboardVisibleLatch ||
            !owner.host.window || !ZNSKeyboardMatchesFocus(owner) ||
            ![owner.bundleIdentifier isEqualToString:bundle]) return;
        NSDictionary *event=@{ @"hiding":@(hiding), @"bundle":bundle, @"pid":@(pid),
            @"generation":@(generation), @"duration":@(duration), @"options":@(options) };
        [NSNotificationCenter.defaultCenter postNotificationName:ZNSPortraitKeyboardWillHideVisualNotification
            object:owner userInfo:event];
    });
}
