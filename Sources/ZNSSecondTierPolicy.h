#pragma once
#include "ZNSGeometry.h"

// Tier indices are zero-based. Ordinary drags deliberately return no action.
typedef enum {
    ZNSSecondTierActionNone,
    ZNSSecondTierActionClose,
    ZNSSecondTierActionAdvance,
    ZNSSecondTierActionReturnFirst
} ZNSSecondTierAction;

static inline ZNSSecondTierAction ZNSSecondTierActionForGesture(
    unsigned landscape, unsigned deviceLandscape, unsigned rightSide, CGPoint delta, CGPoint velocity, double elapsed) {
    (void)rightSide; // Swipe direction selects the destination, independent of origin.
    if (ZNSThumbnailSensitiveFlick(delta,velocity,elapsed,1))
        return ZNSSecondTierActionReturnFirst;
    if (delta.y<0 && ZNSThumbnailSensitiveFlick(delta,velocity,elapsed,0))
        return ZNSSecondTierActionClose;
    (void)deviceLandscape;
    // Both device directions share the upward-close threshold. Portrait content
    // returns to tier one; landscape content can advance to tier three.
    if (delta.y>0 && ZNSThumbnailSensitiveFlick(delta,velocity,elapsed,0))
        return landscape?ZNSSecondTierActionAdvance:ZNSSecondTierActionReturnFirst;
    return ZNSSecondTierActionNone;
}
