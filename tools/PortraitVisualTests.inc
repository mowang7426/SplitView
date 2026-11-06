// Included by PortraitEventTests after its transport helpers.
static CGRect VisualScreenRect(UIView *view) {
    CGRect r=view.bounds;
    for (UIView *v=view; v.superview; v=v.superview) {
        r=CGRectOffset(r,-CGRectGetMidX(v.bounds),-CGRectGetMidY(v.bounds));
        r=CGRectApplyAffineTransform(r,v.transform);
        r=CGRectOffset(r,v.center.x,v.center.y);
    }
    return r;
}
static void AssertVisualRect(CGRect a,CGRect b) {
    assert(fabs(CGRectGetMinX(a)-CGRectGetMinX(b))<=0.5);
    assert(fabs(CGRectGetMinY(a)-CGRectGetMinY(b))<=0.5);
    assert(fabs(CGRectGetMaxX(a)-CGRectGetMaxX(b))<=0.5);
    assert(fabs(CGRectGetMaxY(a)-CGRectGetMaxY(b))<=0.5);
}
static void VisualTests(void) {
    Drain(ZNSReady); Drain(ZNSAnimationEnds);
    ZNSKeyboardPlacement *p; ZNSWindowManager *m=Manager(&p); ZNSFloatingView *v=m.floating;
    CGRect original=v.frame;
    Publish(m,p,NO); Ack(v.session); Drain(ZNSReady); p.attached=YES; // UIKit remount after expansion (transport mock only).
    [p znsAcceptClientPhase:ZNSClientKeyboardShown];
    CGRect expanded=v.frame; CGSize canvas=v.session.canvasSize;
    CGPoint center=v.center; CGRect bounds=v.bounds,content=v.content.bounds;
    p.presentationDuration=0.31; p.presentationOptions=7UL<<16; p.presentationTimingKnown=YES;
    NSUInteger animations=ZNSAnimations,updates=v.session.scene.updates,restores=p.restores,layouts=v.layouts;
    NSUInteger publications=ZNSVisibilityPublications;
    [p znsAcceptClientPhase:ZNSClientKeyboardWillHide];
    assert(ZNSAnimations==animations && !v.portraitKeyboardVisualRestoring);
    assert(v.session.scene.updates==updates && p.restores==restores && p.attached);
    Drain(ZNSReady);
    assert(v.portraitKeyboardVisualRestoring && ZNSAnimations==animations+1);
    assert(v.transformAnimation==ZNSAnimations && v.content.superview==v);
    assert(fabs(ZNSLastAnimationDuration-0.31)<0.0001 && (ZNSLastAnimationOptions&(7UL<<16))==(7UL<<16));
    assert(ZNSLastAnimationOptions&UIViewAnimationOptionBeginFromCurrentState);
    assert(ZNSLastAnimationOptions&UIViewAnimationOptionAllowUserInteraction);
    assert(CGRectEqualToRect(v.frame,original)); // transformed footprint, not model resize
    assert(CGRectEqualToRect(v.bounds,bounds) && CGPointEqualToPoint(v.center,center));
    assert(CGRectEqualToRect(v.content.bounds,content) && v.layouts==layouts);
    assert(!v.content.userInteractionEnabled);
    CGRect bodyEnd=VisualScreenRect(v.bodyBackground),contentEnd=VisualScreenRect(v.content),canvasEnd=VisualScreenRect(v.canvasContainer);
    AssertVisualRect(bodyEnd,CGRectOffset(ZNSMainBody((CGRect){CGPointZero,original.size}),original.origin.x,original.origin.y));
    AssertVisualRect(contentEnd,CGRectOffset(ZNSMainContent((CGRect){CGPointZero,original.size}),original.origin.x,original.origin.y));
    assert(v.portraitKeyboardExpanded && CGRectEqualToRect(v.portraitKeyboardTarget,expanded));
    assert(CGSizeEqualToSize(v.session.canvasSize,canvas) && v.session.temporaryPortraitSettings);
    assert(p.attached && p.restores==restores && v.session.scene.updates==updates);
    assert(ZNSVisibilityPublications==publications);
    [p znsClientWillHide]; Drain(ZNSReady);
    [v beginPortraitKeyboardVisualRestoreWithDuration:0.31 options:0];
    assert(ZNSAnimations==animations+1); // duplicate delivery cannot restart
    Drain(ZNSAnimationEnds); assert(v.portraitKeyboardVisualRestoreCompleted);
    [p znsClientDidHide]; Publish(m,p,YES);
    assert(v.session.scene.updates==updates+1 && v.session.temporaryPortraitSettings);
    assert(v.session.znsPortraitRestorePending && v.portraitKeyboardVisualRestoring);
    assert(v.layouts==layouts && CGSizeEqualToSize(v.session.hostView.referenceSize,canvas));
    Ack(v.session); // scene acknowledgment cannot release old client layout
    assert(v.portraitKeyboardExpanded && v.portraitKeyboardVisualRestoring);
    ClientLayout(v.session);
    assert(!v.session.temporaryPortraitSettings);
    assert(ZNSAnimations==animations+2 && CGRectEqualToRect(v.frame,original));
    AssertVisualRect(bodyEnd,VisualScreenRect(v.bodyBackground));
    AssertVisualRect(contentEnd,VisualScreenRect(v.content));
    AssertVisualRect(canvasEnd,VisualScreenRect(v.canvasContainer));
    assert(CGAffineTransformIsIdentity(v.bodyBackground.transform) && CGAffineTransformIsIdentity(v.content.transform));
    assert(v.toolbar.alpha==1 && v.topBar.alpha==1 && v.bottomBar.alpha==1);
    assert(CGAffineTransformIsIdentity(v.transform) && !v.portraitKeyboardExpanded);
    assert(!v.portraitKeyboardVisualRestoring && !v.portraitKeyboardRestoring);
    assert(!v.portraitKeyboardVisualFinalizePending && CGRectIsEmpty(v.portraitKeyboardSavedFrame));
    Ack(v.session); Original(v.session);
    // DidHide arrives before visual completion: one animation, one restore,
    // actual scene restore waits for that animation, never precedes DidHide.
    m=Manager(&p); v=m.floating; original=v.frame; Publish(m,p,NO); Ack(v.session); Drain(ZNSReady); p.attached=YES; // UIKit remount after expansion (transport mock only).
    [p znsAcceptClientPhase:ZNSClientKeyboardShown]; updates=v.session.scene.updates;
    [p znsClientWillHide]; Drain(ZNSReady); animations=ZNSAnimations;
    [p znsClientDidHide]; Publish(m,p,YES);
    assert(v.portraitKeyboardVisualFinalizePending && v.portraitKeyboardExpanded);
    assert(v.session.scene.updates==updates && ZNSAnimations==animations);
    Drain(ZNSAnimationEnds);
    assert(v.session.scene.updates==updates+1 && ZNSAnimations==animations);
    assert(v.portraitKeyboardVisualRestoring && v.session.znsPortraitRestorePending);
    ClientLayout(v.session);
    assert(!v.portraitKeyboardVisualRestoring && !v.portraitKeyboardRestoring);
    assert(CGRectEqualToRect(v.frame,original) && CGAffineTransformIsIdentity(v.transform));
    Ack(v.session);
    // Cancel hide, then hide again before the return completion. Old callbacks
    // must not clear the new generation. Repeated Shown cannot lose cancellation.
    m=Manager(&p); v=m.floating; Publish(m,p,NO); Ack(v.session); Drain(ZNSReady); p.attached=YES; // UIKit remount after expansion (transport mock only).
    [p znsAcceptClientPhase:ZNSClientKeyboardShown]; updates=v.session.scene.updates;
    [p znsClientWillHide]; Drain(ZNSReady); animations=ZNSAnimations;
    [p znsAcceptClientPhase:ZNSClientKeyboardShown]; [p znsAcceptClientPhase:ZNSClientKeyboardShown];
    assert(ZNSAnimations==animations); Drain(ZNSReady);
    assert(ZNSAnimations==animations+1 && v.portraitKeyboardVisualReturning);
    assert(CGAffineTransformIsIdentity(v.transform) && v.session.scene.updates==updates && p.attached);
    [p znsClientWillHide]; Drain(ZNSReady); assert(ZNSAnimations==animations+2);
    Drain(ZNSAnimationEnds);
    assert(v.portraitKeyboardVisualRestoring && !v.portraitKeyboardVisualReturning && v.portraitKeyboardVisualRestoreCompleted);
    [p znsAcceptClientPhase:ZNSClientKeyboardShown]; Drain(ZNSReady); Drain(ZNSAnimationEnds);
    assert(!v.portraitKeyboardVisualRestoring && CGAffineTransformIsIdentity(v.transform));
    assert(v.portraitKeyboardExpanded && v.session.scene.updates==updates && v.session.temporaryPortraitSettings);
    // Cancelling before queue delivery must cause no visual animation at all.
    animations=ZNSAnimations;
    [p znsClientWillHide]; [p znsAcceptClientPhase:ZNSClientKeyboardShown]; Drain(ZNSReady);
    assert(ZNSAnimations==animations && !v.portraitKeyboardVisualRestoring);
    // Zero-duration hide still maps all descendants without layout/scene work.
    p.presentationDuration=0; p.presentationTimingKnown=YES;
    [p znsClientWillHide]; Drain(ZNSReady);
    assert(ZNSAnimations==animations && v.portraitKeyboardVisualRestoreCompleted);
    [p znsClientDidHide]; Publish(m,p,YES);
    assert(v.session.znsPortraitRestorePending); ClientLayout(v.session);
    assert(!v.portraitKeyboardVisualRestoring && CGAffineTransformIsIdentity(v.transform));
    assert(v.session.scene.updates==updates+1); Ack(v.session);
}
static void VisualSafetyTests(void) {
    // Rejected manager states must not turn a visual event into model restore.
    for (NSUInteger gate=0;gate<8;gate++) {
        ZNSKeyboardPlacement *p; ZNSWindowManager *m=Manager(&p); ZNSFloatingView *v=m.floating;
        Publish(m,p,NO); Ack(v.session); Drain(ZNSReady); p.attached=YES; // UIKit remount after expansion (transport mock only).
        [p znsAcceptClientPhase:ZNSClientKeyboardShown];
        NSUInteger animations=ZNSAnimations,updates=v.session.scene.updates,restores=p.restores;
        if(gate==0) v.session.bundleIdentifier=@"other.app";
        if(gate==1) v.closing=YES;
        if(gate==2) v.activeManipulation=@1;
        if(gate==3) v.session.landscape=YES;
        if(gate==4) v.session.layoutInFlight=YES;
        if(gate==5) v.transform=CGAffineTransformMakeScale(0.9,0.9);
        if(gate==6) p.clientPID=43;
        if(gate==7) v.session.keyboardPlacement=[ZNSTempKeyboard new];
        CGAffineTransform existing=v.transform;
        [p znsClientWillHide]; Drain(ZNSReady);
        assert(!v.portraitKeyboardVisualRestoring && ZNSAnimations==animations);
        assert(v.session.scene.updates==updates && p.restores==restores && p.attached);
        assert(CGAffineTransformEqualToTransform(existing,v.transform));
    }
    // Close/drag/rotation while already collapsing: zero-duration cleanup,
    // no extra UIView animation, and stale completion cannot alter final frame.
    for(NSUInteger state=0;state<3;state++) {
        ZNSKeyboardPlacement *p; ZNSWindowManager *m=Manager(&p); ZNSFloatingView *v=m.floating;
        CGRect original=v.frame; Publish(m,p,NO); Ack(v.session); Drain(ZNSReady); p.attached=YES; // UIKit remount after expansion (transport mock only).
        [p znsAcceptClientPhase:ZNSClientKeyboardShown];
        [p znsClientWillHide]; Drain(ZNSReady); NSUInteger animations=ZNSAnimations;
        if(state==0) v.closing=YES;
        if(state==1) v.activeManipulation=@1;
        if(state==2) v.session.landscape=YES;
        [v restorePortraitKeyboardWithDuration:0 options:0];
        assert(ZNSAnimations==animations && !v.portraitKeyboardExpanded);
        assert(!v.portraitKeyboardVisualRestoring && !v.portraitKeyboardRestoring);
        assert(CGAffineTransformIsIdentity(v.transform) && CGRectEqualToRect(v.frame,original));
        Drain(ZNSAnimationEnds); assert(CGRectEqualToRect(v.frame,original)); Ack(v.session);
    }
    // Execute the production .inc cancellation used by BOTH manager close
    // entries (their call order is source-checked). UIKit close is simulated:
    // once close owns a nonidentity transform, queued keyboard completions must
    // not touch it, model state, scene updates, or generation, even on rejection.
    for(NSUInteger mode=0;mode<4;mode++) {
        ZNSKeyboardPlacement *cp; ZNSWindowManager *cm=Manager(&cp); ZNSFloatingView *cv=cm.floating;
        Publish(cm,cp,NO); Ack(cv.session); Drain(ZNSReady); cp.attached=YES;
        [cp znsAcceptClientPhase:ZNSClientKeyboardShown];
        [cp znsClientWillHide]; Drain(ZNSReady);
        if(mode==1) { [cp znsClientDidHide]; Publish(cm,cp,YES); assert(cv.portraitKeyboardVisualFinalizePending); }
        if(mode==2) { [cp znsAcceptClientPhase:ZNSClientKeyboardShown]; Drain(ZNSReady); assert(cv.portraitKeyboardVisualReturning); }
        if(mode==3) cv.session.hostView.rejectNext=YES;
        NSUInteger oldGeneration=cv.portraitKeyboardVisualRestoreGeneration;
        cv.closing=YES;
        [cv restorePortraitKeyboardWithDuration:0 options:0];
        assert(cv.portraitKeyboardVisualRestoreGeneration>oldGeneration);
        assert(!cv.portraitKeyboardVisualRestoring && !cv.portraitKeyboardVisualFinalizePending);
        CGAffineTransform closeTransform=CGAffineTransformMakeScale(0.04,0.006);
        cv.transform=closeTransform;
        CGRect closeFrame=cv.frame,saved=cv.portraitKeyboardSavedFrame;
        NSUInteger generation=cv.portraitKeyboardVisualRestoreGeneration,updates=cv.session.scene.updates;
        BOOL expanded=cv.portraitKeyboardExpanded,suppressed=cv.portraitKeyboardSuppressed;
        Drain(ZNSAnimationEnds);
        assert(CGAffineTransformEqualToTransform(cv.transform,closeTransform));
        assert(CGRectEqualToRect(cv.frame,closeFrame) && CGRectEqualToRect(cv.portraitKeyboardSavedFrame,saved));
        assert(cv.portraitKeyboardVisualRestoreGeneration==generation && cv.session.scene.updates==updates);
        assert(cv.closing && cv.portraitKeyboardExpanded==expanded && cv.portraitKeyboardSuppressed==suppressed);
        assert(!cv.portraitKeyboardVisualRestoreCompleted && !cv.portraitKeyboardVisualReturning && !cv.portraitKeyboardRestoring);
        Ack(cv.session);
    }
    puts("PASS keyboard9 close takeover: stale hide/return/DidHide-pending completions preserve closing transform and model; restore rejection also cancels generation (production .inc, mocked UIKit close).");
    // Canvas restore rejection clears our transform, keeps saved model state
    // for retry, and cannot leave an expanded scene stuck in the tiny footprint.
    ZNSKeyboardPlacement *p; ZNSWindowManager *m=Manager(&p); ZNSFloatingView *v=m.floating;
    CGRect original=v.frame; Publish(m,p,NO); Ack(v.session); Drain(ZNSReady); p.attached=YES; // UIKit remount after expansion (transport mock only).
    [p znsAcceptClientPhase:ZNSClientKeyboardShown];
    // An explicitly requested dismiss is still allowed when App WillHide is proven.
    p.dismissPending=YES;
    [p znsClientWillHide]; Drain(ZNSReady); assert(v.portraitKeyboardVisualRestoring);
    Drain(ZNSAnimationEnds); v.session.hostView.rejectNext=YES;
    [p znsClientDidHide]; Publish(m,p,YES);
    ClientLayout(v.session); // only now does host rejection occur
    assert(v.portraitKeyboardExpanded && v.session.temporaryPortraitSettings);
    assert(!v.portraitKeyboardVisualRestoring && !v.portraitKeyboardRestoring);
    assert(CGAffineTransformIsIdentity(v.transform) && CGRectEqualToRect(v.portraitKeyboardSavedFrame,original));
    [v restorePortraitKeyboardWithDuration:0 options:0]; Ack(v.session);
    assert(CGRectEqualToRect(v.frame,original) && !v.portraitKeyboardExpanded);
    // Hidden or PID replaced before dispatch invalidates the queued visual.
    for(NSUInteger mode=0;mode<2;mode++) {
        m=Manager(&p); v=m.floating; Publish(m,p,NO); Ack(v.session); Drain(ZNSReady); p.attached=YES; // UIKit remount after expansion (transport mock only).
        [p znsAcceptClientPhase:ZNSClientKeyboardShown]; NSUInteger animations=ZNSAnimations;
        [p znsClientWillHide];
        if(mode==0) [p znsClientDidHide]; else p.clientPID=43;
        Drain(ZNSReady); assert(!v.portraitKeyboardVisualRestoring && ZNSAnimations==animations);
    }
    puts("PASS keyboard9 actual async publisher + notification + manager + floating: visual-only WillHide, whole-view mapping, no layout/scene/detach before DidHide, duration/options, duplicate/cancel/early DidHide, generation, owner/PID gates, lifecycle and failed-restore cleanup. UIKit/rendering MOCKED; NOT device verified.");
}

static void RestoreOwnershipTests(void) {
    // Pending DidHide, then a fresh Shown with no delivered visual-return event.
    ZNSKeyboardPlacement *p; ZNSWindowManager *m=Manager(&p); ZNSFloatingView *v=m.floating;
    Publish(m,p,NO); Ack(v.session); p.attached=YES;
    [p znsAcceptClientPhase:ZNSClientKeyboardShown];
    [p znsClientWillHide]; Drain(ZNSReady); Drain(ZNSAnimationEnds);
    [p znsClientDidHide]; Publish(m,p,YES);
    assert(v.session.znsPortraitRestorePending && v.portraitKeyboardVisualRestoring);
    NSUInteger stale=v.session.temporaryPortraitGeneration,updates=v.session.scene.updates;
    CGRect expanded=v.portraitKeyboardTarget;
    // Exercise actual floating entry, not just scene cancellation.
    [v expandPortraitKeyboardToFrame:expanded duration:0.2 options:0];
    assert(!v.session.znsPortraitRestorePending && v.session.scene.updates==updates+1);
    assert(CGRectEqualToRect(v.session.scene.settings.frame,expanded));
    Drain(ZNSAnimationEnds);
    assert(CGAffineTransformIsIdentity(v.transform) && v.portraitKeyboardExpanded);
    [v.session znsPollPortraitRestore:stale attempt:0];
    assert(v.portraitKeyboardExpanded && v.session.temporaryPortraitSettings);
    // Close/drag/rotation take over AFTER submission but BEFORE client layout.
    for(NSUInteger mode=0;mode<3;mode++) {
        m=Manager(&p); v=m.floating; Publish(m,p,NO); Ack(v.session); p.attached=YES;
        [p znsAcceptClientPhase:ZNSClientKeyboardShown];
        [p znsClientWillHide]; Drain(ZNSReady); Drain(ZNSAnimationEnds);
        [p znsClientDidHide]; Publish(m,p,YES);
        assert(v.session.znsPortraitRestorePending);
        stale=v.session.temporaryPortraitGeneration;
        if(mode==0) v.closing=YES;
        if(mode==1) v.activeManipulation=@1;
        if(mode==2) v.session.landscape=YES;
        [v restorePortraitKeyboardWithDuration:0 options:0];
        assert(!v.session.znsPortraitRestorePending && !v.portraitKeyboardExpanded);
        CGRect normal=v.frame; updates=v.session.scene.updates;
        [v.session znsPollPortraitRestore:stale attempt:0]; ClientLayout(v.session); Ack(v.session);
        assert(CGRectEqualToRect(v.frame,normal) && v.session.scene.updates==updates);
    }
    puts("PASS keyboard10 floating ownership: same-frame re-show resubmits expanded scene and returns visual; pending close/drag/rotate invalidate old client and FB completions");
}

static void LayeredHandoffTests(void) {
    CGSize screens[]={{320,568},{390,844},{768,1024}};
    CGSize native[]={{320,568},{428,926},{1024,768}};
    unsigned cases=0;
    for (unsigned s=0;s<3;s++) for (unsigned n=0;n<3;n++) for (int offset=-40;offset<=80;offset+=60) {
        Drain(ZNSReady); Drain(ZNSAnimationEnds);
        ZNSKeyboardPlacement *p; ZNSWindowManager *m=Manager(&p); ZNSFloatingView *v=m.floating;
        CGRect original=CGRectMake(offset+50,offset+170,260+s*30,420+n*50);
        v.frame=original; v.expandedFrame=original;
        v.superview.bounds=(CGRect){CGPointZero,screens[s]};
        v.session.scene.settings.frame=(CGRect){CGPointZero,native[n]};
        v.session.lease.settings.frame=v.session.scene.settings.frame;
        v.session.canvasSize=native[n]; p.canvas=native[n];
        assert(ZNSConfigureHostCanvas(v.session.hostView,native[n],1));
        [v layoutIfNeeded];
        CGRect normalBody=VisualScreenRect(v.bodyBackground),normalContent=VisualScreenRect(v.content),normalCanvas=VisualScreenRect(v.canvasContainer);
        CGRect expanded=CGRectMake(offset,offset+screens[s].height*0.18,screens[s].width,screens[s].height*0.82);
        [v expandPortraitKeyboardToFrame:expanded duration:0.25 options:0]; Ack(v.session); Drain(ZNSReady);
        p.attached=YES;
        [p znsAcceptClientPhase:ZNSClientKeyboardShown];
        [p znsClientWillHide];
        assert(!v.portraitKeyboardVisualRestoring);
        Drain(ZNSReady); Drain(ZNSAnimationEnds);
        assert(v.portraitKeyboardVisualRestoreCompleted);
        assert(v.toolbar.alpha==0 && v.topBar.alpha==0 && v.bottomBar.alpha==0);
        AssertVisualRect(v.frame,original);
        AssertVisualRect(VisualScreenRect(v.bodyBackground),normalBody);
        AssertVisualRect(VisualScreenRect(v.content),normalContent);
        AssertVisualRect(VisualScreenRect(v.canvasContainer),normalCanvas);
        assert(CGSizeEqualToSize(v.session.hostView.referenceSize,expanded.size));
        NSUInteger layouts=v.layouts;
        [p znsClientDidHide]; [v znsRestorePortraitKeyboardAfterHide];
        assert(v.session.znsPortraitRestorePending);
        [v layoutIfNeeded]; assert(v.layouts==layouts); // pending gate retains compensation
        Ack(v.session); assert(v.session.znsPortraitRestorePending);
        __weak ZNSFloatingView *weak=v;
        v.session.hostView.onConfigure=^{
            // The expanded child counter-maps must survive the host canvas
            // mutation; otherwise content grows before the root visual restore
            // and flashes one frame. They are cleared atomically with root
            // transform only after the successful host handoff completes.
            assert(!CGAffineTransformIsIdentity(weak.content.transform));
            assert(!CGAffineTransformIsIdentity(weak.bodyBackground.transform));
            assert(!CGAffineTransformIsIdentity(weak.canvasContainer.transform));
        };
        ClientLayout(v.session);
        assert(CGAffineTransformIsIdentity(v.content.transform));
        assert(CGAffineTransformIsIdentity(v.bodyBackground.transform));
        assert(CGAffineTransformIsIdentity(v.canvasContainer.transform));
        assert(!v.session.znsPortraitRestorePending && !v.portraitKeyboardVisualRestoring);
        assert(v.layouts==layouts+1);
        AssertVisualRect(v.frame,original);
        AssertVisualRect(VisualScreenRect(v.bodyBackground),normalBody);
        AssertVisualRect(VisualScreenRect(v.content),normalContent);
        AssertVisualRect(VisualScreenRect(v.canvasContainer),normalCanvas);
        assert(CGSizeEqualToSize(v.session.hostView.referenceSize,native[n]));
        assert(CGAffineTransformIsIdentity(v.session.hostView.transform));
        assert(v.portraitKeyboardChromeFading);
        v.closing=YES; [v restorePortraitKeyboardWithDuration:0 options:0];
        assert(!v.portraitKeyboardChromeFading && v.toolbar.alpha==1);
        Drain(ZNSAnimationEnds); assert(!v.portraitKeyboardChromeFading);
        cases++;
    }
    printf("PASS keyboard11 %u production async layered handoffs: screen/window offsets, native canvas ratios, <=0.5pt corners, pending freeze, pre-host cleanup, one normal layout, chrome close cleanup\n",cases);
}
