#import <UIKit/UIKit.h>
#import "ZNSScreenEffectPolicy.h"
// Retains the provider; crops share UIKit backing stores until cancellation.
@interface ZNSScreenEffectSurface : UIView
@property(nonatomic,strong) UIView *znsProvider;
@end
FOUNDATION_EXPORT ZNSScreenEffectSurface *ZNSScreenEffectCreate(UIView *frozen,int effect,BOOL entry,CGFloat scale);
