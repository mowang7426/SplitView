// Fresh App-side visibility evidence. Shared with host tests; transport and
// UIKit inspection are injected, not a second model of the state machine.
static NSInteger ZNSClientResolveHiddenProof(uint64_t expected, uint64_t current,
    NSInteger liveVisibility) {
    if (!expected || expected!=current || (current&3)!=ZNSClientKeyboardHidden) return 0;
    // 1 = currently visible, 2 = currently absent, 0 = unsupported/unknown.
    return liveVisibility==1?1:liveVisibility==2?2:0;
}
