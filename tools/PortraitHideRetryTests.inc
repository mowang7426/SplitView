// Runs production manager/placement/floating/scene includes, mocked transports.
static void HideRetryStep(void) {
    assert(ZNSDeadlines.count);
    void (^block)(void)=ZNSDeadlines.firstObject;
    [ZNSDeadlines removeObjectAtIndex:0]; block();
}
static void HideRetryTests(void) {
    Drain(ZNSDeadlines); Drain(ZNSReady); Drain(ZNSAnimationEnds);
    ZNSKeyboardPlacement *p; ZNSWindowManager *m=Manager(&p); ZNSFloatingView *v=m.floating;
    CGRect original=v.frame;
    Publish(m,p,NO); Ack(v.session); Drain(ZNSDeadlines); p.attached=YES;
    [p znsAcceptClientPhase:ZNSClientKeyboardShown];
    [p znsClientDidHide]; v.session.layoutInFlight=YES; Publish(m,p,YES);
    assert(v.portraitKeyboardExpanded && !v.session.znsPortraitRestorePending && v.portraitKeyboardHideRetryActive);
    v.session.layoutInFlight=NO;
    HideRetryStep(); assert(v.session.znsPortraitRestorePending);
    ClientLayout(v.session); Ack(v.session);
    assert(!v.portraitKeyboardExpanded && CGRectEqualToRect(v.frame,original));
    Drain(ZNSDeadlines); Drain(ZNSReady);
    // Even before asynchronous manager Shown/close processing, the old retry
    // must not mutate the new phase, another owner, or a rotation epoch.
    for (NSUInteger mode=0;mode<5;mode++) {
        m=Manager(&p); v=m.floating; Publish(m,p,NO); Ack(v.session); Drain(ZNSDeadlines); p.attached=YES;
        [p znsAcceptClientPhase:ZNSClientKeyboardShown];
        [p znsClientDidHide]; v.session.layoutInFlight=YES; Publish(m,p,YES);
        assert(v.portraitKeyboardHideRetryActive);
        v.session.layoutInFlight=NO;
        NSUInteger updates=v.session.scene.updates;
        CGRect target=v.portraitKeyboardTarget;
        if(mode==0) [p znsAcceptClientPhase:ZNSClientKeyboardShown];
        if(mode==1) v.closing=YES;
        if(mode==2) v.session.landscape=YES;
        if(mode==3) m.floating=nil;
        if(mode==4) ++v.session.layoutGeneration;
        HideRetryStep();
        assert(!v.session.znsPortraitRestorePending && v.session.scene.updates==updates);
        assert(v.portraitKeyboardExpanded && CGRectEqualToRect(v.portraitKeyboardTarget,target));
        Drain(ZNSReady); Drain(ZNSAnimationEnds); Drain(ZNSDeadlines);
    }
    // Exhaust all four ordinary submissions behind the transient layout gate.
    // At the final bounded fallback the real host rejects: preserve snapshot,
    // expanded flags and saved geometry, never manufacture successful collapse.
    m=Manager(&p); v=m.floating; original=v.frame;
    Publish(m,p,NO); Ack(v.session); Drain(ZNSDeadlines); p.attached=YES;
    [p znsAcceptClientPhase:ZNSClientKeyboardShown];
    [p znsClientDidHide]; v.session.layoutInFlight=YES; Publish(m,p,YES);
    id snapshot=v.session.temporaryPortraitSettings;
    for(NSUInteger i=0;i<3;i++) HideRetryStep();
    v.session.layoutInFlight=NO; v.session.hostView.rejectNext=YES;
    HideRetryStep();
    assert(!v.portraitKeyboardHideRetryActive && !v.session.znsPortraitRestorePending);
    assert(v.portraitKeyboardExpanded && !v.portraitKeyboardRestoring);
    assert(v.session.temporaryPortraitSettings==snapshot && CGRectEqualToRect(v.portraitKeyboardSavedFrame,original));
    assert(!ZNSDeadlines.count);
    puts("PASS keyboard12 production hide retry: transient gate converges; fresh Shown/close/rotate/owner/layout epoch invalidate stale retries; exhaustion + real host failure retains snapshot and expanded state. Transport MOCKED, not device verified.");
}
