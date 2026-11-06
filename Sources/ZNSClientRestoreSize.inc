// A single atomic notify word binds request id + quarter-point dimensions.
// This acknowledges UIWindow layout, NEVER pixels or a render fence.
static uint64_t ZNSRestoreWord(CGSize size) {
    if (!isfinite(size.width)||!isfinite(size.height)||size.width<=0||size.height<=0||size.width>16383||size.height>16383) return 0;
    static uint32_t serial;
    if (!serial) serial=(uint32_t)(NSProcessInfo.processInfo.systemUptime*1000000);
    if (!++serial) ++serial;
    return ((uint64_t)serial<<32)|((uint64_t)llround(size.width*4)<<16)|(uint64_t)llround(size.height*4);
}
static BOOL ZNSRestoreState(pid_t pid,NSString *field,uint64_t *word,BOOL write) {
    if(pid<=0) return NO;
    int token;
    if(notify_register_check(ZNSKeyboardClientEvent(pid,field).UTF8String,&token)!=NOTIFY_STATUS_OK) return NO;
    BOOL ok=(write?notify_set_state(token,*word):notify_get_state(token,word))==NOTIFY_STATUS_OK;
    notify_cancel(token); return ok;
}
uint64_t ZNSRequestClientRestoreSize(pid_t pid,CGSize size) {
    uint64_t word=ZNSRestoreWord(size);
    if(!word || !ZNSRestoreState(pid,@"restore.request",&word,YES)) return 0;
    notify_post(ZNSKeyboardClientEvent(pid,@"restore.requested").UTF8String);
    return word;
}
BOOL ZNSClientRestoreSizeMatches(pid_t pid,uint64_t request) {
    uint64_t reply=0,current=0;
    return request && ZNSRestoreState(pid,@"restore.request",&current,NO) && current==request &&
        ZNSRestoreState(pid,@"restore.reply",&reply,NO) && reply==request;
}
static void ZNSClientSampleRestore(uint64_t request,NSUInteger attempt) {
    uint64_t current=0;
    if(!ZNSRestoreState(getpid(),@"restore.request",&current,NO)||current!=request) return;
    CGSize expected=CGSizeMake(((request>>16)&65535)/4.0,(request&65535)/4.0);
    UIWindowScene *selected=nil; NSUInteger scenes=0;
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if(![scene isKindOfClass:UIWindowScene.class] ||
           (scene.activationState!=UISceneActivationStateForegroundActive && scene.activationState!=UISceneActivationStateForegroundInactive)) continue;
        selected=(UIWindowScene *)scene; scenes++;
    }
    UIWindow *window=nil; NSUInteger windows=0;
    for(UIWindow *candidate in selected.windows) {
        if(candidate.hidden || candidate.windowLevel!=UIWindowLevelNormal || candidate.windowScene!=selected) continue;
        window=candidate; windows++;
    }
    CGSize bounds=window.bounds.size,space=selected.coordinateSpace.bounds.size;
    BOOL matches=scenes==1 && windows==1 && window &&
        fabs(bounds.width-expected.width)<=0.5 && fabs(bounds.height-expected.height)<=0.5 &&
        fabs(space.width-expected.width)<=0.5 && fabs(space.height-expected.height)<=0.5;
    if(matches) {
        // Re-read after UIKit getters: a superseding request must never be acked.
        if(ZNSRestoreState(getpid(),@"restore.request",&current,NO)&&current==request)
            ZNSRestoreState(getpid(),@"restore.reply",&request,YES);
        return;
    }
    if(attempt<120) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/60),dispatch_get_main_queue(),^{
        ZNSClientSampleRestore(request,attempt+1);
    });
}
static void ZNSInstallClientRestoreSize(void) {
    // Retain both state-name registrations for this process lifetime. A
    // register/set/cancel-only writer must not depend on notifyd keeping an
    // unreferenced name (and its state) alive until the other process reads it.
    static int requestState,replyState,token;
    if (notify_register_check(ZNSKeyboardClientEvent(getpid(),@"restore.request").UTF8String,&requestState)!=NOTIFY_STATUS_OK) return;
    if (notify_register_check(ZNSKeyboardClientEvent(getpid(),@"restore.reply").UTF8String,&replyState)!=NOTIFY_STATUS_OK) {
        notify_cancel(requestState); return;
    }
    notify_set_state(requestState,0); notify_set_state(replyState,0);
    notify_register_dispatch(ZNSKeyboardClientEvent(getpid(),@"restore.requested").UTF8String,&token,dispatch_get_main_queue(),^(int unused){
        (void)unused; uint64_t request=0;
        if(ZNSRestoreState(getpid(),@"restore.request",&request,NO)&&request) ZNSClientSampleRestore(request,0);
    });
}
