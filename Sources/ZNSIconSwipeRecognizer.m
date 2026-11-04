#import "ZNSIconSwipeRecognizer.h"
#import <UIKit/UIGestureRecognizerSubclass.h>

@implementation ZNSIconSwipeRecognizer
- (void)reset {
    [super reset];
    self.sourceIconView=nil;
    self.sourceBundleIdentifier=nil;
}
- (BOOL)canBePreventedByGestureRecognizer:(UIGestureRecognizer *)other {
    // Protect only this enabled icon swipe against local/ancestor scrolling.
    // Native UISwipeGestureRecognizer owns direction, timing and recognition.
    // Once it rejects the swipe, ordinary paging is free to proceed.
    UIView *origin=self.sourceIconView ?: self.view;
    if (self.enabled && (self.state==UIGestureRecognizerStatePossible ||
                         self.state==UIGestureRecognizerStateRecognized) &&
        [other isKindOfClass:UIPanGestureRecognizer.class] && other.view &&
        (origin==other.view || [origin isDescendantOfView:other.view])) return NO;
    return [super canBePreventedByGestureRecognizer:other];
}
@end
