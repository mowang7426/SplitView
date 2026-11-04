#import <Foundation/Foundation.h>
@interface ZNSProcessKeepAlive : NSObject
- (instancetype)initWithBundleIdentifier:(NSString *)identifier;
- (void)invalidate;
@end
