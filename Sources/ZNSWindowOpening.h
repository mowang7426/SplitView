#pragma once
#import <UIKit/UIKit.h>
#import "ZNSWindowAnimationPolicy.h"
// A fresh view calls ready once after host attachment, never from layout/restore.
void ZNSWindowOpeningReady(UIView *view, ZNSEntryStyle style, BOOL hostReady, BOOL eligible);
void ZNSWindowOpeningCancel(UIView *view);
void ZNSWindowOpeningCancelAll(void);
