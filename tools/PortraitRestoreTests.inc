static void ClientLayout(ZNSSceneSession *s) {
    s.keyboardPlacement.clientWindowSize=s.keyboardPlacement.expectedRestoreSize;
    s.keyboardPlacement.restoreReply=s.keyboardPlacement.restoreRequest;
    [s znsPollPortraitRestore:s.temporaryPortraitGeneration attempt:0];
}
static void RestoreTransactionTests(void) {
    CGRect expanded=CGRectMake(0,152,390,692);
    ZNSSceneSession *s=New();
    assert([s applyTemporaryPortraitFrame:expanded failure:nil]); Ack(s);
    __block NSUInteger completions=0;
    s.scene.deferApply=YES;
    assert([s znsRestorePortraitAfterHide:^(BOOL ok){assert(ok); completions++;}]);
    assert(s.znsPortraitRestorePending && s.temporaryPortraitSettings);
    assert(CGSizeEqualToSize(s.canvasSize,expanded.size));
    // Client can lead scene; neither alone permits host mutation.
    ClientLayout(s); assert(completions==0);
    s.keyboardPlacement.clientWindowSize=expanded.size;
    s.scene.settings=s.scene.submittedSettings;
    Ack(s); // callback is neither required nor sufficient
    [s znsPollPortraitRestore:s.temporaryPortraitGeneration attempt:0];
    assert(completions==0 && s.temporaryPortraitSettings);
    assert(CGSizeEqualToSize(s.hostView.referenceSize,expanded.size));
    s.keyboardPlacement.restoreReply=0;
    s.keyboardPlacement.clientWindowSize=CGSizeMake(390,844);
    [s znsPollPortraitRestore:s.temporaryPortraitGeneration attempt:0];
    assert(completions==0); // stale request id
    ClientLayout(s); assert(completions==1); Original(s);
    ClientLayout(s); assert(completions==1);
    // No client reply: attempt zero MUST wait, then size-only degradation.
    s=New(); assert([s applyTemporaryPortraitFrame:expanded failure:nil]); Ack(s);
    __block NSUInteger degraded=0;
    assert([s znsRestorePortraitAfterHide:^(BOOL ok){assert(ok); degraded++;}]);
    NSUInteger graceGeneration=s.temporaryPortraitGeneration;
    [s znsPollPortraitRestore:graceGeneration attempt:0];
    assert(!degraded && s.znsPortraitRestorePending);
    [s znsPollPortraitRestore:graceGeneration attempt:29];
    assert(!degraded && s.temporaryPortraitSettings);
    [s znsPollPortraitRestore:graceGeneration attempt:30];
    assert(degraded==1 && !s.znsPortraitRestorePending); Original(s);
    Drain(ZNSDeadlines); Ack(s); assert(degraded==1);
    // Rapid show must explicitly re-submit expanded scene, not same-frame skip.
    s=New(); assert([s applyTemporaryPortraitFrame:expanded failure:nil]); Ack(s);
    assert([s znsRestorePortraitAfterHide:^(BOOL ok){(void)ok; assert(0);}]);
    NSUInteger old=s.temporaryPortraitGeneration,updates=s.scene.updates;
    assert([s applyTemporaryPortraitFrame:expanded failure:nil]);
    assert(s.scene.updates==updates+1 && CGRectEqualToRect(s.scene.settings.frame,expanded));
    [s znsPollPortraitRestore:old attempt:0]; assert(s.temporaryPortraitSettings);
    // Lifecycle takeover and old confirmation cannot change its final model.
    assert([s znsRestorePortraitAfterHide:^(BOOL ok){(void)ok; assert(0);}]);
    old=s.temporaryPortraitGeneration;
    assert([s restoreTemporaryPortraitCanvas]); Original(s);
    [s znsPollPortraitRestore:old attempt:0]; Original(s);
    // Timeout safely returns to expanded, snapshot retained; retry succeeds.
    s=New(); assert([s applyTemporaryPortraitFrame:expanded failure:nil]); Ack(s);
    __block NSUInteger failures=0;
    s.scene.deferApply=YES;
    assert([s znsRestorePortraitAfterHide:^(BOOL ok){assert(!ok); failures++;}]);
    [s znsPollPortraitRestore:s.temporaryPortraitGeneration attempt:120];
    assert(failures==1 && !s.znsPortraitRestorePending && s.temporaryPortraitSettings);
    assert(CGRectEqualToRect(s.scene.settings.frame,expanded)); Ack(s);
    s.scene.deferApply=NO;
    assert([s znsRestorePortraitAfterHide:^(BOOL ok){assert(ok);}]); ClientLayout(s); Original(s);
    // Submission exception also preserves retry state and releases ownership.
    s=New(); assert([s applyTemporaryPortraitFrame:expanded failure:nil]); Ack(s);
    s.scene.throwNext=YES;
    assert(![s znsRestorePortraitAfterHide:^(BOOL ok){assert(!ok);}]);
    assert(!s.znsPortraitRestorePending && s.temporaryPortraitSettings);
    assert([s znsRestorePortraitAfterHide:^(BOOL ok){assert(ok);}]); ClientLayout(s); Original(s);
    puts("PASS keyboard10 production restore: separately submitted/applied scene and client layout, stale response, no callback, single handoff, rapid-show resubmit, lifecycle takeover, timeout and retry; NOT pixel fence");
}
