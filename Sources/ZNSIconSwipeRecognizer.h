#import <UIKit/UIKit.h>

// Native discrete swipe, attached to the actual Home Screen icon.
@interface ZNSIconSwipeRecognizer : UISwipeGestureRecognizer
// Snapshot the real icon and bundle for the current touch sequence.
@property(nonatomic,weak) UIView *sourceIconView;
@property(nonatomic,copy) NSString *sourceBundleIdentifier;
@end
