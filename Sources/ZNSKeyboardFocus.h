#import <Foundation/Foundation.h>

// Archived SBS experiment stays disabled. Normal input uses native App focus
// and keyboard presentation only; the old persistent fuse is never reset.
#ifndef ZNS_ENABLE_SBS_KEYBOARD_EXPERIMENT
#define ZNS_ENABLE_SBS_KEYBOARD_EXPERIMENT 0
#endif

@interface ZNSKeyboardFocus : NSObject
+ (BOOL)experimentEnabled;
@property(nonatomic,readonly) BOOL screenKeyboardRequested;
@property(nonatomic,copy) void (^didEndExperiment)(void);
- (instancetype)initWithScene:(id)scene;
- (void)setActive:(BOOL)active;
- (void)invalidate;
@end
