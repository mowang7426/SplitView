#pragma once
#import <UIKit/UIKit.h>
#import "ZNSWindowAnimationPolicy.h"
// Main-thread only. Presentation never owns a live session or a close callback.
// YES: frozen compositor content transferred to an independent, non-key host.
// NO: caller must still close normally (a short native-view fade is allowed).
BOOL ZNSExitShatterPresent(UIView *source);
void ZNSExitShatterCancelAll(void);

BOOL ZNSExitAnimationPresent(UIView *source, ZNSExitStyle style);
