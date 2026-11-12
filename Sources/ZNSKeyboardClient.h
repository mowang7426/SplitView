#pragma once
#import <Foundation/Foundation.h>
#import <sys/types.h>
#import <UIKit/UIKit.h>
#import "ZNSKeyboardDiag.h"

// Current PID state, not the name of a possibly delayed/coalesced Darwin post.
typedef NS_ENUM(NSUInteger,ZNSClientKeyboardPhase) {
    ZNSClientKeyboardUnknown=0, ZNSClientKeyboardShown=1,
    ZNSClientKeyboardWillHide=2, ZNSClientKeyboardHidden=3
};
ZNSClientKeyboardPhase ZNSReadClientKeyboardPhase(pid_t pid);

// Native App-window coordinates. No text or responder data crosses processes.
BOOL ZNSReadClientKeyboardAnimation(pid_t pid, NSTimeInterval *duration, UIViewAnimationOptions *options);
BOOL ZNSReadClientKeyboardGeometry(pid_t pid, CGRect *rect, CGSize *canvas);
BOOL ZNSReadClientKeyboardMenuGeometry(pid_t pid, CGRect *rect, CGSize *canvas);

// Per-process names prevent a close in one floating App from hiding another
// App's keyboard. Darwin notifications carry no typed text or other payload.
static inline NSString *ZNSKeyboardClientEvent(pid_t pid, NSString *event) {
    if (pid<=0 || !event.length) return nil;
    return [NSString stringWithFormat:@"%s.keyboard.%d.%@",APELIN_PACKAGE_ID,(int)pid,event];
}
uint64_t ZNSRequestClientRestoreSize(pid_t pid, CGSize size);
BOOL ZNSClientRestoreSizeMatches(pid_t pid, uint64_t request);
void ZNSInstallKeyboardClient(void);
