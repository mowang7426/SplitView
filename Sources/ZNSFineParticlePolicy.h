#pragma once
#include "ZNSExitShatterGeometry.h"
#define ZNSFineMaskWidth 128
#define ZNSFineMaskHeight 256
#define ZNSFineMaskFrames 17
#define ZNSFineBirthRate 1800
#define ZNSFineEmitDuration .64
#define ZNSFineLifetime .32
#define ZNSFineLifetimeRange .08
#define ZNSFineDuration 1.08
#define ZNSFineDiameter 3.0
#define ZNSFineDiameterRange 1.0
#define ZNSFineMaxLive 720
#define ZNSFineMaskBytes (ZNSFineMaskWidth*ZNSFineMaskHeight*ZNSFineMaskFrames*4)
static inline bool ZNSFineGeometry(double w,double h,double scale) {
    double pixels=0;
    return ZNSShatterSourcePixels(w,h,scale,&pixels) && w<=640 && h<=1280;
}
static inline unsigned char ZNSFineAlpha(unsigned x,unsigned y,unsigned frame) {
    if(frame==0) return 255;
    if(frame>=ZNSFineMaskFrames-1) return 0;
    uint32_t seed=0x71ab9u+x*7919u+y*104729u;
    double threshold=.72*(x+.5)/ZNSFineMaskWidth+.28*ZNSShatterUnit(&seed);
    return threshold>(double)frame/(ZNSFineMaskFrames-1)?255:0;
}
static inline bool ZNSFineMayStart(bool active,uint64_t generation,uint64_t token,bool captured,bool reduce,double w,double h,double scale) {
    return active && generation==token && captured && !reduce && ZNSFineGeometry(w,h,scale);
}
static inline double ZNSFineRate(double elapsed,bool active) {
    return active && elapsed>=0 && elapsed<ZNSFineEmitDuration ? ZNSFineBirthRate : 0;
}
