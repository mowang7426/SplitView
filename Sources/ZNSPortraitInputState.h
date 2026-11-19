#pragma once

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSUInteger, ZNSPortraitInputState) {
    ZNSPortraitInputUnknown, ZNSPortraitInputPresent, ZNSPortraitInputEmpty
};
typedef NS_ENUM(NSUInteger, ZNSPortraitClose) {
    ZNSPortraitCloseNone, ZNSPortraitCloseClient, ZNSPortraitCloseNative
};
