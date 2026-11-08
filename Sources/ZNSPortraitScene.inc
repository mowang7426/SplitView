// Included inside ZNSSceneSession's implementation; also executed by the
// macOS mock tests. This path owns ONLY frame/reference size, never focus,
// foreground activation, orientation, keyboard inset or persistent defaults.
- (BOOL (^)(void))znsPortraitRestoreSessionGuard {
    NSUInteger layout=self.layoutGeneration;
    __weak typeof(self) weakSelf=self;
    return [^BOOL{
        typeof(self) owner=weakSelf;
        return owner && owner.layoutGeneration==layout && !owner.stopped &&
            !owner.deviceLockRequested && !owner.switcherRemovalRequested && !owner.landscape;
    } copy];
}
- (BOOL)znsPortraitExpansionNeedsResubmission {
    return self.temporaryPortraitSettings && CGRectIsEmpty(self.temporaryPortraitFrame);
}
- (BOOL)znsPortraitRestoreGateBusy {
    return self.layoutInFlight || self.temporaryPortraitRestoring;
}
- (BOOL)znsOwnsTemporaryPortraitGeneration:(NSUInteger)generation {
    return self.temporaryPortraitGeneration==generation && self.temporaryPortraitSettings &&
        (!self.znsPortraitRestoreOwnership || self.znsPortraitRestoreOwnership()) && !self.stopped && !self.deviceLockRequested && !self.switcherRemovalRequested && !self.layoutInFlight;
}
- (BOOL)znsTemporaryPortraitStateMatchesFrame:(CGRect)frame {
    @try {
        id applied=ZNSGet(self.scene,@"settings");
        return ZNSSettingsReadAPI(applied) && ZNSGeometryRectNear([applied frame],frame) &&
            [applied interfaceOrientation]==UIInterfaceOrientationPortrait &&
            ZNSGeometrySizeNear(self.canvasSize,frame.size) &&
            ZNSHostCanvasMatches(self.hostView,frame.size,UIInterfaceOrientationPortrait);
    } @catch (__unused NSException *exception) { return NO; }
}
- (BOOL)applyTemporaryPortraitFrame:(CGRect)frame failure:(void (^)(void))failure {
    [self znsCancelPortraitRestore];
    if (!NSThread.isMainThread || self.temporaryPortraitRestoring || self.stopped || self.deviceLockRequested || self.switcherRemovalRequested ||
        self.layoutInFlight || self.landscape || !self.hostView || !self.lease.settings ||
        !isfinite(frame.origin.x) || !isfinite(frame.origin.y) || !ZNSValidCanvasSize(frame.size) ||
        frame.size.height<=frame.size.width) {
        os_log_error(ZNSLog(),"P3_SCENE_GATE stopped=%d lock=%d removal=%d inFlight=%d landscape=%d host=%d lease=%d",self.stopped,self.deviceLockRequested,self.switcherRemovalRequested,self.layoutInFlight,self.landscape,self.hostView!=nil,self.lease.settings!=nil);
        return NO;
    }
    if (self.temporaryPortraitSettings && ZNSGeometryRectNear(frame,self.temporaryPortraitFrame)) return YES;
    SEL update=@selector(updateSettings:withTransitionContext:completion:);
    if (!ZNSSceneUpdateSignature(object_getClass(self.scene),update,5)) {
        os_log_error(ZNSLog(),"P3_SCENE_UPDATE_ABI_REJECT"); return NO;
    }
    if (!ZNSHostCanvasAPI(self.hostView)) {
        os_log_error(ZNSLog(),"P3_HOST_CANVAS_ABI_REJECT"); return NO;
    }
    @try {
        id current=ZNSGet(self.scene,@"settings");
        if (!ZNSSettingsReadAPI(current) || !ZNSRequireABI(current,@selector(mutableCopy),"@",NULL,0,@"TP0")) return NO;
        id desired=[current mutableCopy];
        if (!ZNSSettingsWriteAPI(desired)) return NO;
        if (!self.temporaryPortraitSettings) {
            self.temporaryPortraitSettings=self.lease.settings;
            self.temporaryPortraitCanvas=self.canvasSize;
        }
        // A NONZERO scene origin is essential: native keyboard screen->window
        // conversion must subtract the same top offset as the displayed host.
        [desired setFrame:frame];
        self.lease.settings=desired;
        self.temporaryPortraitFrame=frame;
        self.temporaryPortraitFailure=failure;
        NSUInteger generation=++self.temporaryPortraitGeneration;
        self.temporaryPortraitPending=YES;
        self.changedSettings=YES;
        [self.keyboardPlacement znsBeginPortraitGeometryRefresh];
        BOOL configured=ZNSConfigureHostCanvas(self.hostView,frame.size,UIInterfaceOrientationPortrait);
        // Host setters can synchronously close/lock/restore this session.
        if (![self znsOwnsTemporaryPortraitGeneration:generation]) return NO;
        if (!configured) { [self restoreTemporaryPortraitCanvas]; return NO; }
        self.canvasSize=frame.size;
        // Unlike general rotation, do NOT invalidate keyboardFocus or suspend
        // placement. That would resign/reacquire the keyboard during its show.
        [self.keyboardPlacement updateTemporaryPortraitCanvas:frame.size];
        if (![self znsOwnsTemporaryPortraitGeneration:generation]) return NO;
        __weak typeof(self) weakSelf=self;
        [self.scene updateSettings:desired withTransitionContext:nil completion:^{
            dispatch_async(dispatch_get_main_queue(),^{
                ZNSSceneSession *owner=weakSelf;
                if (!owner || owner.stopped || owner.temporaryPortraitGeneration!=generation ||
                    !owner.temporaryPortraitSettings || !owner.temporaryPortraitPending) return;
                BOOL ok=[owner znsTemporaryPortraitStateMatchesFrame:frame];
                if (ok) {
                    owner.temporaryPortraitPending=NO;
                    owner.temporaryPortraitFailure=nil;
                    os_log(ZNSLog(),"P3_SCENE_ACK frame=(%.1f,%.1f %.1fx%.1f); settings acknowledgment only, not rendered pixels",frame.origin.x,frame.origin.y,frame.size.width,frame.size.height);
                    [owner.keyboardPlacement requestPortraitClientGeometry];
                } else {
                    void (^failed)(void)=owner.temporaryPortraitFailure;
                    [owner restoreTemporaryPortraitCanvas];
                    os_log_error(ZNSLog(),"temporary portrait scene/host acknowledgment rejected; original canvas restored");
                    if (failed) failed();
                }
            });
        }];
        if (![self znsOwnsTemporaryPortraitGeneration:generation]) return NO;
        // The callback can be delayed or lost after FrontBoard has already
        // applied the transaction. Read production scene/host state before
        // deciding whether the safety rollback is still necessary.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            ZNSSceneSession *owner=weakSelf;
            if (!owner || owner.stopped || owner.temporaryPortraitGeneration!=generation || !owner.temporaryPortraitPending) return;
            if ([owner znsTemporaryPortraitStateMatchesFrame:frame]) {
                owner.temporaryPortraitPending=NO;
                owner.temporaryPortraitFailure=nil;
                [owner.keyboardPlacement requestPortraitClientGeometry];
                static NSTimeInterval lastInferredLog=0;
                NSTimeInterval now=[NSDate timeIntervalSinceReferenceDate];
                if (lastInferredLog==0 || now-lastInferredLog>=30.0) {
                    lastInferredLog=now;
                    os_log(ZNSLog(),"P7_SCENE_ACK_INFERRED state=matched callback=timeout; settings acknowledgment only, not rendered pixels");
                }
                return;
            }
            void (^failed)(void)=owner.temporaryPortraitFailure;
            [owner restoreTemporaryPortraitCanvas];
            os_log_error(ZNSLog(),"temporary portrait scene acknowledgment timed out with mismatched state; original canvas restored");
            if (failed) failed();
        });
        return YES;
    } @catch (__unused NSException *exception) {
        [self restoreTemporaryPortraitCanvas];
        return NO;
    }
}

#include "ZNSPortraitRestoreTransaction.inc"
- (BOOL)restoreTemporaryPortraitCanvas {
    [self znsCancelPortraitRestore];
    return [self restoreTemporaryPortraitCanvasWithDuration:0 options:0];
}
- (BOOL)restoreTemporaryPortraitCanvasWithDuration:(NSTimeInterval)duration options:(NSUInteger)options {
    (void)duration; (void)options; // native hide synchronization is not supported
    [self znsCancelPortraitRestore];
    if (self.temporaryPortraitRestoring) return NO;
    if (!self.temporaryPortraitSettings) return YES;
    id original=self.temporaryPortraitSettings;
    CGSize canvas=self.temporaryPortraitCanvas;
    NSUInteger generation=++self.temporaryPortraitGeneration;
    self.temporaryPortraitPending=NO;
    self.temporaryPortraitFailure=nil;
    // Do not clear the snapshot until a synchronous submission succeeds.
    // Keeping it on failure lets an explicit later restore/rotation retry.
    if (self.stopped || self.deviceLockRequested || self.switcherRemovalRequested) {
        self.temporaryPortraitSettings=nil;
        self.temporaryPortraitFrame=CGRectZero;
        self.temporaryPortraitCanvas=CGSizeZero;
        return YES; // lifecycle owner restores original pre-host settings
    }
    self.temporaryPortraitRestoring=YES;
    NSUInteger normalGeneration=self.layoutGeneration;
    @try {
        id current=ZNSGet(self.scene,@"settings");
        if (!ZNSSettingsReadAPI(current) || !ZNSRequireABI(current,@selector(mutableCopy),"@",NULL,0,@"TPR")) return NO;
        id restored=[current mutableCopy];
        if (!ZNSSettingsWriteAPI(restored)) return NO;
        [restored setFrame:[original frame]];
        self.lease.settings=restored;
        if (!ZNSConfigureHostCanvas(self.hostView,canvas,UIInterfaceOrientationPortrait)) return NO;
        if (![self znsOwnsTemporaryPortraitGeneration:generation] || self.layoutGeneration!=normalGeneration) return NO;
        self.canvasSize=canvas;
        [self.keyboardPlacement updateTemporaryPortraitCanvas:canvas];
        if (![self znsOwnsTemporaryPortraitGeneration:generation] || self.layoutGeneration!=normalGeneration) return NO;
        __weak typeof(self) weakSelf=self;
        [self.scene updateSettings:restored withTransitionContext:nil completion:^{
            dispatch_async(dispatch_get_main_queue(),^{
                ZNSSceneSession *owner=weakSelf;
                if (!owner || owner.stopped || owner.temporaryPortraitGeneration!=generation ||
                    owner.layoutGeneration!=normalGeneration || owner.deviceLockRequested || owner.switcherRemovalRequested) return;
                @try {
                    id applied=ZNSGet(owner.scene,@"settings");
                    if (!ZNSSettingsReadAPI(applied) || !CGRectEqualToRect([applied frame],[restored frame]))
                        os_log_error(ZNSLog(),"temporary portrait restore scene acknowledgment mismatch; device inspection required");
                } @catch (__unused NSException *exception) {
                    os_log_error(ZNSLog(),"temporary portrait restore acknowledgment unavailable");
                }
            });
        }];
        if (![self znsOwnsTemporaryPortraitGeneration:generation] || self.layoutGeneration!=normalGeneration) return NO;
        self.temporaryPortraitSettings=nil;
        self.temporaryPortraitFrame=CGRectZero;
        self.temporaryPortraitCanvas=CGSizeZero;
        return YES;
    } @catch (__unused NSException *exception) {
        os_log_error(ZNSLog(),"temporary portrait restore submission failed; settings retained for retry");
        return NO;
    } @finally {
        self.temporaryPortraitRestoring=NO;
    }
}
