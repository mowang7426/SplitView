// Actual placement / manager / floating / restore transaction includes above.
// Only Darwin state, UIKit visibility and render-server transport are mocked.
static void HiddenProofTests(void) {
    assert(ZNSClientResolveHiddenProof(103,103,1)==1);
    assert(ZNSClientResolveHiddenProof(103,103,2)==2);
    assert(ZNSClientResolveHiddenProof(103,103,0)==0);
    assert(ZNSClientResolveHiddenProof(103,107,2)==0);
    assert(ZNSClientResolveHiddenProof(103,105,2)==0);
    for (NSInteger evidence=0;evidence<=1;evidence++) {
        Drain(ZNSDeadlines); Drain(ZNSReady); Drain(ZNSAnimationEnds);
        ZNSKeyboardPlacement *p; ZNSWindowManager *m=Manager(&p); ZNSFloatingView *v=m.floating;
        Publish(m,p,NO); Ack(v.session); Drain(ZNSDeadlines);
        [p znsAcceptClientPhase:ZNSClientKeyboardShown];
        CGRect expanded=v.frame; NSUInteger updates=v.session.scene.updates;
        // QQ resize/remount: App issues a hide while its live keyboard is still
        // visible or its native API temporarily cannot answer. No grace timer
        // is allowed to manufacture permission to submit the small scene.
        [p znsClientWillHide];
        ZNSMockPhase=103; ZNSMockLive=evidence;
        [p znsAcceptClientPhase:ZNSClientKeyboardHidden];
        assert(p.znsHiddenProofRequest && !p.keyboardHidden);
        ZNSMockResponse=ZNSMockRequest;
        [p znsAcceptClientPhase:ZNSClientKeyboardHidden];
        Publish(m,p,NO); Drain(ZNSReady); Drain(ZNSAnimationEnds);
        assert(v.portraitKeyboardExpanded && !v.session.znsPortraitRestorePending);
        assert(v.session.scene.updates==updates && CGRectEqualToRect(v.frame,expanded));
        assert([p znsPortraitKeyboardContinuity]);
        // No new UIKit shown notification is needed: subsequent live absence
        // for the SAME raw hide phase must still converge on real dismissal.
        [p znsResampleHiddenProof]; ZNSMockLive=2;
        [p znsAcceptClientPhase:ZNSClientKeyboardHidden]; ZNSMockResponse=ZNSMockRequest;
        [p znsAcceptClientPhase:ZNSClientKeyboardHidden]; Publish(m,p,YES);
        assert(v.session.znsPortraitRestorePending);
        // keyboard12 missing size ack remains usable, but only after real hide
        // proof and an applied matching scene; no fake client-layout evidence.
        [v.session znsPollPortraitRestore:v.session.temporaryPortraitGeneration attempt:30];
        assert(!v.portraitKeyboardExpanded && !v.session.znsPortraitRestorePending);
        Drain(ZNSDeadlines); Drain(ZNSReady); Drain(ZNSAnimationEnds);
    }
    // A late old Darwin hide delivered after Shown reads the CURRENT phase;
    // a previous absent reply cannot authorize a new phase or an old retry.
    ZNSKeyboardPlacement *p; ZNSWindowManager *m=Manager(&p); ZNSFloatingView *v=m.floating;
    Publish(m,p,NO); Ack(v.session); Drain(ZNSDeadlines);
    [p znsAcceptClientPhase:ZNSClientKeyboardShown];
    ZNSMockPhase=105;
    [p znsAcceptClientPhase:ZNSClientKeyboardHidden]; Publish(m,p,NO);
    assert(!p.keyboardHidden && v.portraitKeyboardExpanded && !v.session.znsPortraitRestorePending);
    ConfirmHidden(p); Publish(m,p,YES);
    assert(v.session.znsPortraitRestorePending);
    NSUInteger generation=v.session.temporaryPortraitGeneration;
    CGSize canvas=v.session.hostView.referenceSize;
    // No manager Shown callback yet: raw phase itself revokes the old proof.
    ZNSMockPhase+=4;
    [v.session znsPollPortraitRestore:generation attempt:30];
    assert(!v.session.znsPortraitRestorePending && v.portraitKeyboardExpanded);
    assert(CGSizeEqualToSize(v.session.hostView.referenceSize,canvas));
    Drain(ZNSDeadlines); Drain(ZNSReady); Drain(ZNSAnimationEnds);
    puts("PASS keyboard13 production hidden proof: transient hide/remount, visible/unknown do not collapse, late old hide/current phase, stale reply at 30-tick handoff rejected; genuine close without new Shown + missing size ack restores. Native visibility / Darwin / render server MOCKED, not device verified.");
}
