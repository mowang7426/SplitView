#import <UIKit/UIKit.h>

// Independent dip selector: only a tap and its manager-owned move recognizer.
@interface ZNSDipIconView : UIControl
@property(nonatomic,strong) UIImage *appImage;
@property(nonatomic) BOOL showsCompanionDragon;
@end
