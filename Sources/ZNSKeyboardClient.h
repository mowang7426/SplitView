#pragma once
#import <Foundation/Foundation.h>
#import <sys/types.h>
#import <UIKit/UIKit.h>

// Native App-window coordinates. No text or responder data crosses processes.
BOOL ZNSReadClientKeyboardGeometry(pid_t pid, CGRect *rect, CGSize *canvas);
BOOL ZNSReadClientKeyboardMenuGeometry(pid_t pid, CGRect *rect, CGSize *canvas);

// Per-process names prevent a close in one floating App from hiding another
// App's keyboard. Darwin notifications carry no typed text or other payload.
static inline NSString *ZNSKeyboardClientEvent(pid_t pid, NSString *event) {
    if (pid<=0 || !event.length) return nil;
    return [NSString stringWithFormat:@"%s.keyboard.%d.%@",APELIN_PACKAGE_ID,(int)pid,event];
}
void ZNSInstallKeyboardClient(void);
