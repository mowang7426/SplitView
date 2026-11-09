// Public UIKit evidence is sampled ONLY inside the owning .app on main queue.
// A DidHide alone, offscreen frame alone, or empty guide alone is insufficient.
#include "ZNSClientHideLifecycle.inc"
static ZNSClientHideLifecycle ZNSClientNativeHide;
static __weak UIWindow *ZNSClientHideWindow;
static CGRect ZNSClientHideBounds,ZNSClientHideSceneBounds,ZNSClientHideScreenBounds;
static uint64_t ZNSClientHideLayoutEpoch;
static BOOL ZNSClientGuideWasVisible;
static BOOL ZNSClientInputAmbiguous;
static UIWindow *ZNSClientUniqueInputWindow(void) {
    ZNSClientInputAmbiguous=NO;
    UIWindowScene *single=nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState==UISceneActivationStateUnattached) continue;
        if (single) { ZNSClientInputAmbiguous=YES; return nil; }
        single=(UIWindowScene *)scene;
    }
    UIWindow *selected=nil; NSUInteger budget=4096;
    for (UIWindow *window in single.windows) {
        if (window.hidden || window.alpha<0.01 || window.windowLevel!=UIWindowLevelNormal) continue;
        if (ZNSClientFirstResponder(window,&budget)) {
            if (selected) { ZNSClientInputAmbiguous=YES; return nil; }
            selected=window;
        }
        if (!budget) { ZNSClientInputAmbiguous=YES; return nil; }
    }
    return selected;
}
static uintptr_t ZNSClientObserveHideOwner(void) {
    UIWindow *window=ZNSClientHideWindow; UIWindowScene *scene=window.windowScene;
    if (!window || window.hidden || window.alpha<0.01 || !scene ||
        (scene.activationState!=UISceneActivationStateForegroundActive &&
         scene.activationState!=UISceneActivationStateForegroundInactive)) return 0;
    NSUInteger scenes=0;
    for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes)
        if ([candidate isKindOfClass:UIWindowScene.class] && candidate.activationState!=UISceneActivationStateUnattached) ++scenes;
    if (scenes!=1) return 0;
    CGRect bounds=window.bounds,space=scene.coordinateSpace.bounds,screen=window.screen.coordinateSpace.bounds;
    if (!CGRectEqualToRect(bounds,ZNSClientHideBounds) || !CGRectEqualToRect(space,ZNSClientHideSceneBounds) ||
        !CGRectEqualToRect(screen,ZNSClientHideScreenBounds)) {
        ++ZNSClientHideLayoutEpoch;
        ZNSClientGuideWasVisible=NO; // old-canvas guide visibility cannot prove this layout
        ZNSClientHideBounds=bounds; ZNSClientHideSceneBounds=space; ZNSClientHideScreenBounds=screen;
    }
    UIWindow *current=ZNSClientUniqueInputWindow();
    if (ZNSClientInputAmbiguous || (current && current!=window)) return 0;
    return (uintptr_t)(__bridge void *)window;
}
static NSInteger ZNSClientKeyboardGuideVisibility(void) {
    UIWindow *window=ZNSClientHideWindow;
    if (!window || !ZNSClientObserveHideOwner()) return 0;
    UIKeyboardLayoutGuide *guide=window.keyboardLayoutGuide;
    if (guide.owningView!=window) return 0;
    CGRect frame=guide.layoutFrame;
    if (!isfinite(frame.origin.x) || !isfinite(frame.origin.y) || !isfinite(frame.size.width) ||
        !isfinite(frame.size.height) || frame.size.width<0 || frame.size.height<0) return 0;
    CGRect overlap=CGRectIntersection(window.bounds,frame);
    BOOL visible=!CGRectIsNull(overlap) && overlap.size.width>1 && overlap.size.height>window.safeAreaInsets.bottom+1;
    if (visible) { ZNSClientGuideWasVisible=YES; return 1; }
    // An uninitialized/default-empty guide is NOT proof. It must have tracked
    // the docked keyboard in this very show generation before completing hide.
    return ZNSClientGuideWasVisible?2:0;
}
static BOOL ZNSClientNoteOffscreen(NSNotification *note,BOOL beginDocked) {
    NSValue *value=note.userInfo[beginDocked?UIKeyboardFrameBeginUserInfoKey:UIKeyboardFrameEndUserInfoKey];
    if (![value isKindOfClass:NSValue.class] || !ZNSClientObserveHideOwner()) return NO;
    CGRect frame=value.CGRectValue,screen=ZNSClientHideWindow.screen.coordinateSpace.bounds;
    if (!isfinite(frame.origin.x)||!isfinite(frame.origin.y)||!isfinite(frame.size.width)||
        !isfinite(frame.size.height)||frame.size.width<=1||frame.size.height<=1) return NO;
    if (!beginDocked) return !CGRectIntersectsRect(frame,screen);
    CGRect owned=[ZNSClientHideWindow convertRect:ZNSClientHideWindow.bounds toCoordinateSpace:ZNSClientHideWindow.screen.coordinateSpace];
    return frame.size.width>=screen.size.width*0.8 && CGRectIntersectsRect(frame,owned);
}
static void ZNSClientObserveNativeHide(NSNotification *note,BOOL willHide,BOOL didHide,BOOL show) {
    NSNumber *local=note.userInfo[UIKeyboardIsLocalUserInfoKey];
    if (![local isKindOfClass:NSNumber.class] || !local.boolValue) {
        ZNSClientHideReset(&ZNSClientNativeHide);
        return;
    }
    if (show) {
        ZNSClientHideReset(&ZNSClientNativeHide);
        UIWindow *window=ZNSClientUniqueInputWindow();
        if (window!=ZNSClientHideWindow || [note.name isEqual:UIKeyboardWillShowNotification]) ZNSClientGuideWasVisible=NO;
        ZNSClientHideWindow=window;
        (void)ZNSClientObserveHideOwner();
        (void)ZNSClientKeyboardGuideVisibility();
    } else if (willHide) {
        uintptr_t owner=ZNSClientObserveHideOwner();
        (void)ZNSClientKeyboardGuideVisibility();
        BOOL exit=ZNSClientNoteOffscreen(note,YES) && ZNSClientNoteOffscreen(note,NO);
        ZNSClientHideWill(&ZNSClientNativeHide,owner,ZNSClientHideLayoutEpoch,exit);
    } else if (didHide) {
        uintptr_t owner=ZNSClientObserveHideOwner();
        ZNSClientHideDid(&ZNSClientNativeHide,ZNSReadClientKeyboardPhaseWord(getpid()),owner,
            ZNSClientHideLayoutEpoch,ZNSClientNoteOffscreen(note,NO));
    } else {
        // A frame notification is never Shown authority, but it can revoke a
        // previous completion if UIKit reports a keyboard back on screen.
        (void)ZNSClientObserveHideOwner();
        if (ZNSClientNativeHide.completed && !ZNSClientNoteOffscreen(note,NO))
            ZNSClientHideReset(&ZNSClientNativeHide);
        (void)ZNSClientKeyboardGuideVisibility();
    }
}
static NSInteger ZNSClientNativeHiddenProof(uint64_t expected,NSInteger live) {
    uintptr_t owner=ZNSClientObserveHideOwner();
    NSInteger guide=ZNSClientKeyboardGuideVisibility();
    NSInteger proof=ZNSClientCompletedHideProof(&ZNSClientNativeHide,expected,
        ZNSReadClientKeyboardPhaseWord(getpid()),live,owner,ZNSClientHideLayoutEpoch,guide);
    // Numeric evidence only: no text, responder identities, bundle, or geometry.
    static os_log_t log; static dispatch_once_t once;
    dispatch_once(&once,^{ log=os_log_create(APELIN_PACKAGE_ID,"keyboard-hide-proof"); });
    static uint64_t lastPhase; static NSInteger lastProof=-1,lastLive=-1,lastGuide=-1;
    if (lastPhase!=expected || lastProof!=proof || lastLive!=live || lastGuide!=guide) {
        os_log(log,"hide proof phase=%llu reader=%ld guide=%ld owner=%d completed=%d result=%ld",
            (unsigned long long)expected,(long)live,(long)guide,owner!=0,ZNSClientNativeHide.completed,(long)proof);
        lastPhase=expected; lastProof=proof; lastLive=live; lastGuide=guide;
    }
    return proof;
}
