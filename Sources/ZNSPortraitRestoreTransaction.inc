// Normal DidHide only. Lifecycle restoration remains synchronous and cancels
// this generation. Scene application is mandatory; client size ack has bounded grace.
- (void)znsCancelPortraitRestore {
    if (!self.znsPortraitRestorePending) return;
    self.znsPortraitRestorePending=NO;
    self.znsPortraitRestorePrepareVisual=nil;
    self.znsPortraitRestoreOwnership=nil;
    ++self.temporaryPortraitGeneration;
    self.znsPortraitRestoreCompletion=nil;
    // Original scene may already have applied: force next expansion submission.
    self.temporaryPortraitFrame=CGRectZero;
}
- (void)znsPollPortraitRestore:(NSUInteger)generation attempt:(NSUInteger)attempt {
    // Scene completion and the immediate state poll may both arrive for the
    // same restore. UIKit/host setters below can also synchronously re-enter
    // this poll. Only one caller may perform the scene-to-canvas handoff;
    // otherwise the same restore can configure the host and finalize twice,
    // producing a visible one-frame split-window jump after keyboard dismissal.
    if (self.znsPortraitHandoffInFlight || !self.znsPortraitRestorePending ||
        self.temporaryPortraitGeneration!=generation) return;
    if (self.znsPortraitRestoreOwnership && !self.znsPortraitRestoreOwnership()) {
        [self znsCancelPortraitRestore];
        return; // a fresh Shown/lifecycle/owner epoch must never hand off late
    }
    BOOL owns=[self znsOwnsTemporaryPortraitGeneration:generation];
    BOOL sceneMatches=NO;
    @try {
        id applied=ZNSGet(self.scene,@"settings");
        sceneMatches=owns && ZNSSettingsReadAPI(applied) && ZNSGeometryRectNear([applied frame],[self.temporaryPortraitSettings frame]);
    } @catch (__unused NSException *exception) {}
    BOOL sizeAcknowledged=[self.keyboardPlacement znsRestoreSizeMatches:self.znsPortraitRestoreRequest];
    // Strict client enumeration can remain ambiguous (e.g. extra app windows).
    // After 30 scheduled ticks (~0.5s), degrade SIZE CONFIRMATION only. Applied
    // scene matching remains mandatory. Neither path is a client pixel fence.
    BOOL sizeGraceExpired=attempt>=30;
    if (sceneMatches && (sizeAcknowledged || sizeGraceExpired)) {
        if (!sizeAcknowledged) os_log_error(ZNSLog(),"P12_SIZE_ACK_DEGRADED scene=matched grace=expired; not a pixel fence");
        self.znsPortraitHandoffInFlight=YES;
        @try { ZNSRunPortraitHandoff(^{
            if (![self znsOwnsTemporaryPortraitGeneration:generation] || !self.znsPortraitRestorePending) return;
            void (^prepareVisual)(void)=self.znsPortraitRestorePrepareVisual;
            self.znsPortraitRestorePrepareVisual=nil;
            if (prepareVisual) prepareVisual();
            CGSize canvas=self.temporaryPortraitCanvas;
            BOOL configured=ZNSConfigureHostCanvas(self.hostView,canvas,UIInterfaceOrientationPortrait);
            if (![self znsOwnsTemporaryPortraitGeneration:generation] || !self.znsPortraitRestorePending) return;
            if (!configured) { [self znsFailPortraitRestore:generation]; return; }
            self.canvasSize=canvas;
            [self.keyboardPlacement updateTemporaryPortraitCanvas:canvas];
            if (![self znsOwnsTemporaryPortraitGeneration:generation] || !self.znsPortraitRestorePending) return;
            void (^done)(BOOL)=self.znsPortraitRestoreCompletion;
            self.znsPortraitRestoreCompletion=nil;
            self.znsPortraitRestorePending=NO;
            self.znsPortraitRestoreOwnership=nil;
            self.temporaryPortraitSettings=nil;
            self.temporaryPortraitCanvas=CGSizeZero;
            self.temporaryPortraitFrame=CGRectZero;
            // Same no-animation transaction: caller clears transform and lays
            // out normal floating chrome. This is NOT a client pixel fence.
            self.znsPortraitHandoffInFlight=NO;
            if (done) done(YES);
        }); } @catch (__unused NSException *exception) {
            [self znsFailPortraitRestore:generation];
        } @finally { self.znsPortraitHandoffInFlight=NO; }
        return;
    }
    if (attempt>=120) { [self znsFailPortraitRestore:generation]; return; }
    __weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/60),dispatch_get_main_queue(),^{
        [weakSelf znsPollPortraitRestore:generation attempt:attempt+1];
    });
}
- (void)znsFailPortraitRestore:(NSUInteger)generation {
    if (!self.znsPortraitRestorePending || self.temporaryPortraitGeneration!=generation) return;
    CGRect expanded=self.znsPortraitRestoreExpandedFrame;
    void (^done)(BOOL)=self.znsPortraitRestoreCompletion;
    [self znsCancelPortraitRestore];
    // No blind collapse on timeout. Re-submit expanded geometry, retain original
    // snapshot for retry; caller returns transform to expanded presentation.
    NSUInteger rollbackGeneration=self.temporaryPortraitGeneration;
    if ([self znsPortraitRestoreGateBusy] || self.stopped || self.deviceLockRequested ||
        self.switcherRemovalRequested || self.landscape) {
        os_log_error(ZNSLog(),"P12_ROLLBACK_DEFERRED lifecycle/layout owns host; retained recovery snapshot");
        if (done) done(NO);
        return;
    }
    self.temporaryPortraitRestoring=YES;
    @try {
        id current=ZNSGet(self.scene,@"settings");
        if (ZNSSettingsReadAPI(current) && ZNSRequireABI(current,@selector(mutableCopy),"@",NULL,0,@"P10R")) {
            id desired=[current mutableCopy];
            if (ZNSSettingsWriteAPI(desired)) {
                [desired setFrame:expanded];
                BOOL configured=ZNSHostCanvasMatches(self.hostView,expanded.size,UIInterfaceOrientationPortrait) ||
                    ZNSConfigureHostCanvas(self.hostView,expanded.size,UIInterfaceOrientationPortrait);
                if (configured && [self znsOwnsTemporaryPortraitGeneration:rollbackGeneration]) {
                    self.canvasSize=expanded.size;
                    [self.keyboardPlacement updateTemporaryPortraitCanvas:expanded.size];
                    if ([self znsOwnsTemporaryPortraitGeneration:rollbackGeneration]) {
                        self.lease.settings=desired;
                        [self.scene updateSettings:desired withTransitionContext:nil completion:nil];
                        if ([self znsOwnsTemporaryPortraitGeneration:rollbackGeneration]) self.temporaryPortraitFrame=expanded;
                    }
                }
            }
        }
    } @catch (__unused NSException *exception) {
        os_log_error(ZNSLog(),"P10_EXPANDED_ROLLBACK_FAILED retained snapshot for forced retry");
    } @finally { self.temporaryPortraitRestoring=NO; }
    os_log_error(ZNSLog(),"P10_RESTORE_UNCONFIRMED kept recovery snapshot; layout confirmation unavailable, retry required");
    if (done && !self.stopped && self.temporaryPortraitGeneration==rollbackGeneration) done(NO);
}
- (BOOL)znsRestorePortraitAfterHide:(void (^)(BOOL))completion {
    if (!NSThread.isMainThread || self.znsPortraitRestorePending || self.temporaryPortraitRestoring ||
        self.stopped || self.layoutInFlight || self.deviceLockRequested || self.switcherRemovalRequested ||
        !self.temporaryPortraitSettings) return NO;
    @try {
        id current=ZNSGet(self.scene,@"settings");
        if (!ZNSSettingsReadAPI(current) || !ZNSRequireABI(current,@selector(mutableCopy),"@",NULL,0,@"P10")) return NO;
        id desired=[current mutableCopy];
        if (!ZNSSettingsWriteAPI(desired)) return NO;
        [desired setFrame:[self.temporaryPortraitSettings frame]];
        uint64_t request=[self.keyboardPlacement znsRequestRestoreSize:[desired frame].size];
        if (!request) return NO;
        self.znsPortraitRestoreRequest=request;
        self.znsPortraitRestoreExpandedFrame=self.temporaryPortraitFrame;
        NSUInteger generation=++self.temporaryPortraitGeneration;
        self.temporaryPortraitPending=NO;
        self.temporaryPortraitFailure=nil;
        self.znsPortraitRestorePending=YES;
        self.znsPortraitRestoreCompletion=completion;
        self.lease.settings=desired;
        // Callback merely re-checks both conditions; it is not a pixel fence.
        __weak typeof(self) weakSelf=self;
        [self.scene updateSettings:desired withTransitionContext:nil completion:^{
            dispatch_async(dispatch_get_main_queue(),^{
                [weakSelf znsPollPortraitRestore:generation attempt:0];
            });
        }];
        [self znsPollPortraitRestore:generation attempt:0];
        return YES;
    } @catch (__unused NSException *exception) {
        [self znsFailPortraitRestore:self.temporaryPortraitGeneration];
        return NO;
    }
}
