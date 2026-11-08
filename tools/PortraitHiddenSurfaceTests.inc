// Regression reconstructed from OCR: dismiss -> small -> stale surface rebound.
static void HiddenSurfaceRecoveryTests(void) {
    Drain(ZNSDeadlines); Drain(ZNSReady); Drain(ZNSAnimationEnds);
    ZNSKeyboardPlacement *p; ZNSWindowManager *m=Manager(&p); ZNSFloatingView *v=m.floating;
    CGRect original=v.frame;
    Publish(m,p,NO); Ack(v.session); Drain(ZNSDeadlines);
    p.external=YES;
    p.nativeCandidate=[UIView new]; p.nativeCandidate.alpha=1;
    p.nativeCandidate.window=m.window; p.nativeCandidate.bounds=CGRectMake(0,0,390,334);
    ConfirmHidden(p); Publish(m,p,YES);
    [v.session znsPollPortraitRestore:v.session.temporaryPortraitGeneration attempt:30];
    assert(!v.portraitKeyboardExpanded && CGRectEqualToRect(v.frame,original));
    NSUInteger updates=v.session.scene.updates;
    // Stale layer + inputViews remain live well past the old 0.4s recovery.
    ZNSNow+=0.6;
    for (NSUInteger tick=0;tick<20;tick++) {
        [p znsRecoverHiddenNativeSurface];
        assert(p.keyboardHidden);
        [p znsAcceptClientGeometry:CGRectMake(0,510,390,334) canvas:p.canvas valid:YES focused:YES];
        assert(p.keyboardHidden && !p.clientKeyboardShown);
        Publish(m,p,YES); ZNSNow+=0.25;
        assert(!v.portraitKeyboardExpanded && v.session.scene.updates==updates);
    }
    // Unknown and WillHide cannot reopen it either; a real new Shown can.
    for (NSUInteger phase=0;phase<=2;phase++) {
        ZNSMockPhase=200+phase;
        [p znsRecoverHiddenNativeSurface];
        assert(p.keyboardHidden==(phase!=ZNSClientKeyboardShown));
        p.keyboardHidden=YES;
    }
    // Existing nonportrait overlay recovery is not globally disabled.
    p.portraitExpansion=NO; ZNSMockPhase=203;
    [p znsRecoverHiddenNativeSurface]; assert(!p.keyboardHidden);
    p.portraitExpansion=YES; p.keyboardHidden=YES;
    // Even Shown cannot bypass a lost PID, focus, close/suspend or dead host.
    ZNSMockPhase=205;
    for (NSUInteger mode=0;mode<7;mode++) {
        p.clientPID=mode==0?43:42; ZNSVerifiedPID=mode==1?43:42;
        ZNSFocus=mode!=2; p.active=mode!=3; p.suspended=mode==4;
        p.invalidated=mode==5; p.host.window=mode==6?nil:m.window;
        [p znsRecoverHiddenNativeSurface]; assert(p.keyboardHidden);
    }
    p.clientPID=42; ZNSVerifiedPID=42; ZNSFocus=YES;
    p.active=YES; p.suspended=NO; p.invalidated=NO; p.host.window=m.window;
    [p znsRecoverHiddenNativeSurface]; assert(!p.keyboardHidden);
    [p znsAcceptClientPhase:ZNSClientKeyboardShown]; p.attached=YES;
    Publish(m,p,NO); assert(v.portraitKeyboardExpanded);
    ConfirmHidden(p); Publish(m,p,YES);
    [v.session znsPollPortraitRestore:v.session.temporaryPortraitGeneration attempt:30];
    assert(!v.portraitKeyboardExpanded);
    Drain(ZNSDeadlines); Drain(ZNSReady); Drain(ZNSAnimationEnds);
    puts("PASS keyboard14 actual production recovery: genuine close + missing size ack -> small; 20 stale native surface/geometry ticks cannot rebound; new Shown and nonportrait overlay still recover; PID/focus/lifecycle gates retained. Transport MOCKED.");
}
