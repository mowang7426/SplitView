#import "ZNSKeyboardClient.h"
#import "ZNSKeyboardDiag.h"
#import <UIKit/UIKit.h>
#import <notify.h>
#import <unistd.h>
#import <math.h>
#import <string.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>
#include "ZNSClientRestoreSize.inc"

// Prefer the keyboard's own dismissal action, but only after its current input
// delegate is proven to be the unique responder in this App. No global action,
// focus service, synthetic Return key, or forced endEditing:YES fallback.
static BOOL ZNSClientDismissNativeKeyboard(UIView *responder) {
    Class cls=NSClassFromString(@"UIKeyboardImpl");
    SEL active=NSSelectorFromString(@"activeInstance");
    Method method=class_getClassMethod(cls,active);
    char type[128]={0};
    if(method) method_getReturnType(method,type,sizeof(type));
    if(!method || method_getNumberOfArguments(method)!=2 || type[0]!='@') return NO;
    id keyboard=((id(*)(id,SEL))objc_msgSend)(cls,active);
    if(!keyboard) return NO;
    SEL delegate=NSSelectorFromString(@"inputDelegate");
    method=class_getInstanceMethod(object_getClass(keyboard),delegate);
    memset(type,0,sizeof(type));
    if(method) method_getReturnType(method,type,sizeof(type));
    if(!method || method_getNumberOfArguments(method)!=2 || type[0]!='@' ||
       ((id(*)(id,SEL))objc_msgSend)(keyboard,delegate)!=responder) return NO;
    SEL dismiss=NSSelectorFromString(@"dismissKeyboard");
    method=class_getInstanceMethod(object_getClass(keyboard),dismiss);
    memset(type,0,sizeof(type));
    if(method) method_getReturnType(method,type,sizeof(type));
    if(!method || method_getNumberOfArguments(method)!=2 || strcmp(type,@encode(void))) return NO;
    ((void(*)(id,SEL))objc_msgSend)(keyboard,dismiss);
    return YES; // dispatched, NOT proof of disappearance
}

// One atomic word: valid bit, UIKit curve and duration in microseconds.
// Written BEFORE geometry/visibility posts; no text or responder data is sent.
static int ZNSClientPhaseToken;
static BOOL ZNSClientPhaseReady;
ZNSClientKeyboardPhase ZNSReadClientKeyboardPhase(pid_t pid) {
    if (pid<=0) return ZNSClientKeyboardUnknown;
    int token; uint64_t word=0;
    if (notify_register_check(ZNSKeyboardClientEvent(pid,@"phase").UTF8String,&token)!=NOTIFY_STATUS_OK) return ZNSClientKeyboardUnknown;
    BOOL ok=notify_get_state(token,&word)==NOTIFY_STATUS_OK;
    notify_cancel(token);
    return ok?(ZNSClientKeyboardPhase)(word&3):ZNSClientKeyboardUnknown;
}
// App-wide keyboard notifications carry no scene identifier. In a multi-scene
// app they cannot authorize a process-wide hidden phase: another scene may be
// dismissing its input while QQ's owning scene remains visible. Fail closed on
// ambiguous scene ownership; native SpringBoard hide handling remains available.
static BOOL ZNSClientHasSingleActiveKeyboardScene(void) {
    UIWindowScene *active=nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState==UISceneActivationStateUnattached) continue;
        if (active) return NO;
        active=(UIWindowScene *)scene;
    }
    return active!=nil;
}
static void ZNSClientPublishPhase(ZNSClientKeyboardPhase phase) {
    if (ZNSClientPhaseReady) {
        uint64_t stamp=(uint64_t)(NSProcessInfo.processInfo.systemUptime*1000000);
        notify_set_state(ZNSClientPhaseToken,(stamp<<2)|phase);
    }
    // App-side proof is deliberately numeric and privacy-sanitized; it never
    // includes responder, bundle, scene address, or keyboard/input content.
    ZNSKeyboardDiagPhase diag=ZNSKeyboardDiagDidChange;
    if (phase==ZNSClientKeyboardWillHide) diag=ZNSKeyboardDiagWillHide;
    else if (phase==ZNSClientKeyboardHidden) diag=ZNSKeyboardDiagDidHide;
    else if (phase==ZNSClientKeyboardShown) diag=ZNSKeyboardDiagDidShow;
    ZNSKeyboardDiagEmit(diag, 0, (NSUInteger)stamp,
                        @{@"visibleProof": phase==ZNSClientKeyboardHidden?@"did_hide":@"uikit_notification"});
}
static int ZNSAnimationToken;
static BOOL ZNSAnimationReady;
BOOL ZNSReadClientKeyboardAnimation(pid_t pid,NSTimeInterval *duration,UIViewAnimationOptions *options) {
    if (pid<=0 || !duration || !options) return NO;
    int token; uint64_t value=0;
    if (notify_register_check(ZNSKeyboardClientEvent(pid,@"animation").UTF8String,&token)!=NOTIFY_STATUS_OK) return NO;
    BOOL ok=notify_get_state(token,&value)==NOTIFY_STATUS_OK;
    notify_cancel(token);
    if (!ok || !(value & (1ULL<<63)) || (value & 0xffffffffULL)>600000) return NO;
    *duration=(value & 0xffffffffULL)/1000000.0;
    *options=(UIViewAnimationOptions)(((value>>32)&7)<<16);
    return YES;
}
static void ZNSClientPublishAnimation(NSNotification *note) {
    if (!ZNSAnimationReady || ![note.name containsString:@"Will"]) return;
    NSNumber *duration=note.userInfo[UIKeyboardAnimationDurationUserInfoKey];
    NSNumber *curve=note.userInfo[UIKeyboardAnimationCurveUserInfoKey];
    if (![duration isKindOfClass:NSNumber.class] || !isfinite(duration.doubleValue)) return;
    uint64_t micros=(uint64_t)(MAX(0,MIN(0.6,duration.doubleValue))*1000000);
    NSInteger c=[curve isKindOfClass:NSNumber.class]?MAX(0,MIN(7,curve.integerValue)):0;
    notify_set_state(ZNSAnimationToken,(1ULL<<63)|((uint64_t)c<<32)|micros);
}

static NSString *const ZNSGeometryFields[]={@"geometry.serial",@"geometry.x",@"geometry.y",@"geometry.w",@"geometry.h",@"geometry.cw",@"geometry.ch"};
static int ZNSGeometryTokens[7];
static NSNotification *ZNSLastKeyboardGeometryNote;
static int ZNSGeometryRequestToken;
static BOOL ZNSGeometryReady;
static uint64_t ZNSGeometrySerial;
static NSUInteger ZNSGeometryRefreshGeneration;
static void ZNSClientPublishGeometry(NSNotification *note);
static void ZNSClientRefreshGeometry(NSUInteger generation,NSUInteger attempt) {
    if (generation!=ZNSGeometryRefreshGeneration || !ZNSLastKeyboardGeometryNote) return;
    ZNSClientPublishGeometry(ZNSLastKeyboardGeometryNote);
    // Scene acknowledgment is not proof the App's UIWindow resized yet.
    // Four bounded re-samples use the original native note, never fake UIKit.
    if (attempt<4) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.08*(1U<<attempt)*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        ZNSClientRefreshGeometry(generation,attempt+1);
    });
}

static BOOL ZNSClientGeometryValid(CGRect rect,CGSize canvas) {
    return isfinite(canvas.width) && isfinite(canvas.height) && canvas.width>1 && canvas.height>1 &&
        isfinite(rect.origin.x) && isfinite(rect.origin.y) && isfinite(rect.size.width) && isfinite(rect.size.height) &&
        rect.size.width>1 && rect.size.height>1 && CGRectContainsRect(CGRectMake(-1,-1,canvas.width+2,canvas.height+2),rect) &&
        rect.size.width*rect.size.height<canvas.width*canvas.height*0.95;
}
BOOL ZNSReadClientKeyboardGeometry(pid_t pid,CGRect *rect,CGSize *canvas) {
    if (pid<=0 || !rect || !canvas) return NO;
    int tokens[7]; NSUInteger registered=0;
    uint64_t first=0,last=0,words[6]={0}; BOOL ok=YES;
    for (NSUInteger i=0;i<7;i++) {
        if (notify_register_check(ZNSKeyboardClientEvent(pid,ZNSGeometryFields[i]).UTF8String,&tokens[i])!=NOTIFY_STATUS_OK) { ok=NO; break; }
        registered++;
    }
    if (ok) ok=notify_get_state(tokens[0],&first)==NOTIFY_STATUS_OK && first && !(first&1);
    for (NSUInteger i=0;ok && i<6;i++) ok=notify_get_state(tokens[i+1],&words[i])==NOTIFY_STATUS_OK;
    if (ok) ok=notify_get_state(tokens[0],&last)==NOTIFY_STATUS_OK && first==last;
    for (NSUInteger i=0;i<registered;i++) notify_cancel(tokens[i]);
    if (!ok) return NO;
    double values[6]; memcpy(values,words,sizeof(values));
    CGRect r=CGRectMake(values[0],values[1],values[2],values[3]);
    CGSize c=CGSizeMake(values[4],values[5]);
    if (!ZNSClientGeometryValid(r,c)) return NO;
    *rect=r; *canvas=c; return YES;
}
static void ZNSClientWriteGeometry(CGRect rect,CGSize canvas,BOOL valid) {
    if (!ZNSGeometryReady) return;
    // Odd/even serial prevents the reader from combining different layouts.
    uint64_t serial=(ZNSGeometrySerial+=2);
    if (notify_set_state(ZNSGeometryTokens[0],serial|1)!=NOTIFY_STATUS_OK) return;
    double values[6]={rect.origin.x,rect.origin.y,rect.size.width,rect.size.height,canvas.width,canvas.height};
    uint64_t words[6]; memcpy(words,values,sizeof(words));
    for (NSUInteger i=0;i<6;i++)
        if (notify_set_state(ZNSGeometryTokens[i+1],words[i])!=NOTIFY_STATUS_OK) valid=NO;
    notify_set_state(ZNSGeometryTokens[0],valid?serial:0);
    notify_post(ZNSKeyboardClientEvent(getpid(),@"geometry-changed").UTF8String);
}

// Only runs in an ordinary UIKit App. SpringBoard keeps the placement logic;
// the App alone asks its own responder to resign, preserving native text input.
static void ZNSClientPost(NSString *event) {
    NSString *name=ZNSKeyboardClientEvent(getpid(),event);
    if (name) notify_post(name.UTF8String);
}
static UIView *ZNSClientFirstResponder(UIView *root, NSUInteger *budget) {
    if (!root || !*budget) return nil;
    --*budget;
    if (root.isFirstResponder) return root;
    for (UIView *child in root.subviews) {
        UIView *found=ZNSClientFirstResponder(child,budget);
        if (found) return found;
    }
    return nil;
}
static NSString *const ZNSMenuFields[]={@"menu.serial",@"menu.x",@"menu.y",@"menu.w",@"menu.h",@"menu.cw",@"menu.ch",@"menu.time"};
static int ZNSMenuTokens[8];
static BOOL ZNSMenuReady;
static uint64_t ZNSMenuSerial;
static NSTimer *ZNSMenuTimer;
static int ZNSMenuRequestToken;
static BOOL ZNSMenuRequestReady;

BOOL ZNSReadClientKeyboardMenuGeometry(pid_t pid,CGRect *rect,CGSize *canvas) {
    if(pid<=0 || !rect || !canvas) return NO;
    int request;
    if(notify_register_check(ZNSKeyboardClientEvent(pid,@"menu.request").UTF8String,&request)==NOTIFY_STATUS_OK) {
        notify_set_state(request,(uint64_t)(NSProcessInfo.processInfo.systemUptime*1000));
        notify_cancel(request);
    }
    int tokens[8]; NSUInteger registered=0;
    uint64_t first=0,last=0,words[7]={0}; BOOL ok=YES;
    for(NSUInteger i=0;i<8;i++) {
        if(notify_register_check(ZNSKeyboardClientEvent(pid,ZNSMenuFields[i]).UTF8String,&tokens[i])!=NOTIFY_STATUS_OK) { ok=NO; break; }
        registered++;
    }
    if(ok) ok=notify_get_state(tokens[0],&first)==NOTIFY_STATUS_OK && first && !(first&1);
    for(NSUInteger i=0;ok && i<7;i++) ok=notify_get_state(tokens[i+1],&words[i])==NOTIFY_STATUS_OK;
    if(ok) ok=notify_get_state(tokens[0],&last)==NOTIFY_STATUS_OK && first==last;
    for(NSUInteger i=0;i<registered;i++) notify_cancel(tokens[i]);
    if(!ok) return NO;
    double values[7]; memcpy(values,words,sizeof(values));
    CGRect r=CGRectMake(values[0],values[1],values[2],values[3]);
    CGSize c=CGSizeMake(values[4],values[5]);
    double age=NSProcessInfo.processInfo.systemUptime-values[6];
    if(!ZNSClientGeometryValid(r,c) || !isfinite(age) || age<0 || age>0.5) return NO;
    *rect=r; *canvas=c; return YES;
}
static void ZNSClientClearMenu(void) {
    if(ZNSMenuReady) notify_set_state(ZNSMenuTokens[0],0);
}
static void ZNSClientPublishMenu(void) {
    if(!ZNSMenuReady) return;
    uint64_t request=0,now=(uint64_t)(NSProcessInfo.processInfo.systemUptime*1000);
    if(!ZNSMenuRequestReady || notify_get_state(ZNSMenuRequestToken,&request)!=NOTIFY_STATUS_OK ||
       !request || now<request || now-request>1000) { ZNSClientClearMenu(); return; }
    Class menuClass=NSClassFromString(@"UIInputSwitcherView");
    if(!menuClass) { ZNSClientClearMenu(); return; }
    UIWindowScene *scene=nil; UIView *responder=nil,*menu=nil;
    NSUInteger budget=4096;
    for(UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
        if(![candidate isKindOfClass:UIWindowScene.class] || candidate.activationState==UISceneActivationStateUnattached) continue;
        if(scene) { ZNSClientClearMenu(); return; }
        scene=(UIWindowScene *)candidate;
    }
    for(UIWindow *window in scene.windows) {
        if(window.hidden || window.alpha<0.01) continue;
        UIView *candidate=ZNSClientFirstResponder(window,&budget);
        if(!budget || (candidate && responder && candidate!=responder)) { ZNSClientClearMenu(); return; }
        if(candidate) responder=candidate;
        NSMutableArray<UIView *> *pending=[NSMutableArray arrayWithObject:window];
        while(pending.count && budget) {
            --budget;
            UIView *view=pending.lastObject; [pending removeLastObject];
            if(view.hidden || view.alpha<0.01) continue;
            if([view isKindOfClass:menuClass]) {
                if(menu && menu!=view) { ZNSClientClearMenu(); return; }
                menu=view;
            } else [pending addObjectsFromArray:view.subviews];
        }
        if(!budget) { ZNSClientClearMenu(); return; }
    }
    UIWindow *window=responder.window;
    if(!menu.window || !window || menu.window.windowScene!=window.windowScene) { ZNSClientClearMenu(); return; }
    CGRect region=[menu convertRect:menu.bounds toView:window];
    region=CGRectOffset(region,-window.bounds.origin.x,-window.bounds.origin.y);
    CGSize canvas=window.bounds.size;
    CGSize sceneSize=scene.coordinateSpace.bounds.size;
    if(fabs(canvas.width-sceneSize.width)>1 || fabs(canvas.height-sceneSize.height)>1 ||
       !ZNSClientGeometryValid(region,canvas)) { ZNSClientClearMenu(); return; }
    uint64_t serial=(ZNSMenuSerial+=2);
    if(notify_set_state(ZNSMenuTokens[0],serial|1)!=NOTIFY_STATUS_OK) return;
    double values[7]={region.origin.x,region.origin.y,region.size.width,region.size.height,canvas.width,canvas.height,NSProcessInfo.processInfo.systemUptime};
    uint64_t words[7]; memcpy(words,values,sizeof(words));
    BOOL ok=YES;
    for(NSUInteger i=0;i<7;i++) if(notify_set_state(ZNSMenuTokens[i+1],words[i])!=NOTIFY_STATUS_OK) ok=NO;
    notify_set_state(ZNSMenuTokens[0],ok?serial:0);
}
static void ZNSClientPublishGeometry(NSNotification *note) {
    // A process-wide message is accepted only for a single connected App scene
    // and its unique live responder. Multi-scene Apps keep native placement.
    UIView *responder=nil; UIWindowScene *singleScene=nil; NSUInteger budget=4096;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState==UISceneActivationStateUnattached) continue;
        if (singleScene) { ZNSClientWriteGeometry(CGRectZero,CGSizeZero,NO); return; }
        singleScene=(UIWindowScene *)scene;
    }
    for (UIWindow *window in singleScene.windows) {
        if (window.hidden || window.alpha<0.01) continue;
        UIView *candidate=ZNSClientFirstResponder(window,&budget);
        if (!budget || (candidate && responder && candidate!=responder)) { ZNSClientWriteGeometry(CGRectZero,CGSizeZero,NO); return; }
        if (candidate) responder=candidate;
    }
    UIWindow *window=responder.window;
    NSValue *value=note.userInfo[UIKeyboardFrameEndUserInfoKey];
    if (!window || ![value isKindOfClass:NSValue.class] || strcmp(value.objCType,@encode(CGRect))) {
        ZNSClientWriteGeometry(CGRectZero,CGSizeZero,NO); return;
    }
    CGRect region=[window convertRect:value.CGRectValue fromCoordinateSpace:window.screen.coordinateSpace];
    region=CGRectOffset(region,-window.bounds.origin.x,-window.bounds.origin.y);
    CGSize canvas=window.bounds.size;
    BOOL coversScene=fabs(canvas.width-singleScene.coordinateSpace.bounds.size.width)<1 &&
        fabs(canvas.height-singleScene.coordinateSpace.bounds.size.height)<1;
    ZNSClientWriteGeometry(region,canvas,coversScene && ZNSClientGeometryValid(region,canvas));
}
void ZNSInstallKeyboardClient(void) {
    static dispatch_once_t once;
    dispatch_once(&once,^{
        // UIKit is also linked by services and extensions. Only a real .app
        // gets this bridge; those other processes must not register listeners
        // or create the recurring menu timer merely because UIKit was loaded.
        if (NSClassFromString(@"SpringBoard") ||
            ![NSBundle.mainBundle.bundlePath.pathExtension isEqualToString:@"app"]) return;
        ZNSInstallClientRestoreSize();
        static NSMutableArray *observers;
        static int dismissToken;
        observers=[NSMutableArray new];
        NSNotificationCenter *center=NSNotificationCenter.defaultCenter;
        ZNSClientPhaseReady=notify_register_check(ZNSKeyboardClientEvent(getpid(),@"phase").UTF8String,&ZNSClientPhaseToken)==NOTIFY_STATUS_OK;
        if (ZNSClientPhaseReady) notify_set_state(ZNSClientPhaseToken,0);
        ZNSAnimationReady=notify_register_check(ZNSKeyboardClientEvent(getpid(),@"animation").UTF8String,&ZNSAnimationToken)==NOTIFY_STATUS_OK;
        if (ZNSAnimationReady) notify_set_state(ZNSAnimationToken,0);
        ZNSGeometryReady=YES;
        for (NSUInteger i=0;i<7;i++) {
            if (notify_register_check(ZNSKeyboardClientEvent(getpid(),ZNSGeometryFields[i]).UTF8String,&ZNSGeometryTokens[i])!=NOTIFY_STATUS_OK) {
                for (NSUInteger j=0;j<i;j++) notify_cancel(ZNSGeometryTokens[j]);
                ZNSGeometryReady=NO; break;
            }
        }
        if (ZNSGeometryReady) notify_set_state(ZNSGeometryTokens[0],0);
        ZNSMenuReady=YES;
        for(NSUInteger i=0;i<8;i++) {
            if(notify_register_check(ZNSKeyboardClientEvent(getpid(),ZNSMenuFields[i]).UTF8String,&ZNSMenuTokens[i])!=NOTIFY_STATUS_OK) {
                for(NSUInteger j=0;j<i;j++) notify_cancel(ZNSMenuTokens[j]);
                ZNSMenuReady=NO; break;
            }
        }
        ZNSClientClearMenu();
        ZNSMenuRequestReady=notify_register_check(ZNSKeyboardClientEvent(getpid(),@"menu.request").UTF8String,&ZNSMenuRequestToken)==NOTIFY_STATUS_OK;
        for (NSString *name in @[UIKeyboardWillShowNotification,UIKeyboardDidShowNotification,UIKeyboardWillChangeFrameNotification,UIKeyboardDidChangeFrameNotification,UIKeyboardWillHideNotification,UIKeyboardDidHideNotification]) {
            id token=[center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                NSNumber *local=note.userInfo[UIKeyboardIsLocalUserInfoKey];
                if (local && !local.boolValue) return;
                ZNSClientPublishAnimation(note);
                BOOL willHide=[note.name isEqual:UIKeyboardWillHideNotification];
                BOOL didHide=[note.name isEqual:UIKeyboardDidHideNotification];
                BOOL hide=willHide || didHide;
                BOOL show=[note.name isEqual:UIKeyboardWillShowNotification] || [note.name isEqual:UIKeyboardDidShowNotification];
                // Publish phase BEFORE any geometry event. A late shown/geometry
                // callback must never cancel a newer WillHide transaction.
                // These notifications are process-wide, not scene-scoped. A
                // multi-scene app's hide event is ambiguous and must not clear
                // the owning scene's visible latch. Geometry still independently
                // requires a unique responder and matching full-scene canvas.
                if ((hide || show) && ZNSClientHasSingleActiveKeyboardScene())
                    ZNSClientPublishPhase(willHide?ZNSClientKeyboardWillHide:didHide?ZNSClientKeyboardHidden:ZNSClientKeyboardShown);
                // WillHide carries the only transition timing shared by UIKit,
                // but is not disappearance. Keep the last valid geometry/live
                // responder through that transaction; clearing it here made the
                // App input bar reflow before SpringBoard could shrink its frame.
                if (didHide) {
                    ++ZNSGeometryRefreshGeneration;
                    ZNSLastKeyboardGeometryNote=nil;
                    ZNSClientWriteGeometry(CGRectZero,CGSizeZero,NO);
                } else if (!willHide) {
                    ZNSLastKeyboardGeometryNote=note;
                    ZNSClientPublishGeometry(note);
                }
                if(hide) {
                    [ZNSMenuTimer invalidate]; ZNSMenuTimer=nil; ZNSClientClearMenu();
                } else if(show && ZNSMenuReady && !ZNSMenuTimer) {
                    // The globe menu does not emit keyboard-frame notifications.
                    ZNSMenuTimer=[NSTimer timerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *timer) {
                        ZNSClientPublishMenu();
                    }];
                    [NSRunLoop.mainRunLoop addTimer:ZNSMenuTimer forMode:NSRunLoopCommonModes];
                }
                if (willHide) ZNSClientPost(@"will-hide");
                else if (didHide) {
                    ZNSClientPost(@"hidden");
                    ZNSClientPost(@"hide-finished");
                } else if (show) ZNSClientPost(@"shown");
            }];
            [observers addObject:token];
        }
        // A scene frame update need not emit another keyboard notification.
        // Re-convert the last native SCREEN rectangle through the live window;
        // never post synthetic UIKeyboard notifications or mutate App insets.
        notify_register_dispatch(ZNSKeyboardClientEvent(getpid(),@"geometry.request").UTF8String,
            &ZNSGeometryRequestToken,dispatch_get_main_queue(),^(int token){
                (void)token;
                ZNSClientRefreshGeometry(++ZNSGeometryRefreshGeneration,0);
            });
        NSString *name=ZNSKeyboardClientEvent(getpid(),@"dismiss");
        notify_register_dispatch(name.UTF8String,&dismissToken,dispatch_get_main_queue(),^(int token){
            (void)token;
            // SpringBoard sends this only for its verified visible attachment.
            // A stale App will-hide from Notification Center must not veto it;
            // inspect the live unique responder below instead. No focus request
            // or text routing is introduced by this dismiss-only path.
            // Ambiguous multi-scene input is deliberately not dismissed. Do not
            // send a global UIApplication action that could select another scene.
            UIView *responder=nil;
            NSUInteger budget=4096;
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState==UISceneActivationStateUnattached) continue;
                for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                    if (window.hidden || window.alpha<0.01) continue;
                    UIView *candidate=ZNSClientFirstResponder(window,&budget);
                    if (!budget) return;
                    if (candidate) {
                        if (responder && responder!=candidate) return;
                        responder=candidate;
                    }
                }
            }
            if (!responder) return;
            BOOL native=ZNSClientDismissNativeKeyboard(responder);
            BOOL resigned=NO;
            if (!native) resigned=[responder resignFirstResponder];
            // Never force a whole window to end editing after a refusal, and
            // never dispatch a second dismiss when the native action was sent.
            static os_log_t dismissLog;
            static dispatch_once_t logOnce;
            dispatch_once(&logOnce,^{ dismissLog=os_log_create(APELIN_PACKAGE_ID,"keyboard-client"); });
            os_log(dismissLog,"keyboard dismiss native=%d responderFallback=%d; awaiting UIKit hide",native,resigned);
        });
    });
}
