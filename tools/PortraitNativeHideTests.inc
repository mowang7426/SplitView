// The actual lifecycle resolver feeds the existing production placement,
// floating manager, restore transaction and client-size-ACK degradation.
static void NativeHideClosureTests(void) {
    for (NSUInteger cycle=0;cycle<3;cycle++) {
        Drain(ZNSDeadlines); Drain(ZNSReady); Drain(ZNSAnimationEnds);
        ZNSKeyboardPlacement *p; ZNSWindowManager *m=Manager(&p); ZNSFloatingView *v=m.floating;
        Publish(m,p,NO); Ack(v.session); Drain(ZNSDeadlines);
        [p znsAcceptClientPhase:ZNSClientKeyboardShown];
        [p znsClientWillHide];
        ZNSMockPhase=103; ZNSMockLive=0; ZNSMockGuide=2;
        ZNSClientHideWill(&ZNSMockNativeHide,42,7,true);
        ZNSClientHideDid(&ZNSMockNativeHide,103,42,7,true);
        [p znsAcceptClientPhase:ZNSClientKeyboardHidden]; ZNSMockReply();
        // No live private reader will ever become available in this cycle.
        assert(ZNSMockLive==0 && ZNSMockReplyLive==2);
        [p znsAcceptClientPhase:ZNSClientKeyboardHidden]; Publish(m,p,YES);
        assert(p.keyboardHidden && v.session.znsPortraitRestorePending);
        [v.session znsPollPortraitRestore:v.session.temporaryPortraitGeneration attempt:30];
        assert(!v.portraitKeyboardExpanded && !v.session.znsPortraitRestorePending);
        if (ZNSClientMayPublishShow(false,ZNSMockPhase)) ZNSMockPhase=105;
        assert(ZNSMockPhase==103); // delayed DidShow has no new-show authority
        assert(ZNSClientMayPublishShow(true,ZNSMockPhase));
        Drain(ZNSDeadlines); Drain(ZNSReady); Drain(ZNSAnimationEnds);
        // Revoke cached proof with a real new App Shown, not stale surface.
        ZNSMockPhase=105; ZNSMockLive=0; ZNSMockGuide=1;
        ZNSClientHideReset(&ZNSMockNativeHide);
        [p znsAcceptClientPhase:ZNSClientKeyboardShown];
        assert(!p.keyboardHidden);
        ZNSMockGuide=0;
    }
    ZNSClientHideReset(&ZNSMockNativeHide); ZNSMockGuide=0;
    puts("PASS keyboard15 actual production unknown-reader close -> scene restore with missing size ACK -> new App Shown, repeated cycles. UIKit/transport mocked, not device validation.");
}
