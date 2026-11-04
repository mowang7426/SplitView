#pragma once
#include "ZNSGeometry.h"

// Geometry stays in the device's current coordinate space; App canvas is independent.
static inline CGFloat ZNSDipAngle(void) { return 0.065; } // Left/tool side rises.
static inline CGFloat ZNSDipCardAngle(unsigned landscape) {
    (void)landscape;
    return ZNSDipAngle(); // Tray presentation is identical for every source type.
}
// Visible rounded top-left corner after rotation about the window center.
static inline CGPoint ZNSDipVisibleCorner(CGRect frame,CGFloat angle) {
    CGRect content=ZNSMainContent((CGRect){CGPointZero,frame.size});
    CGFloat radius=fmax(0,fmin(12,fmin(content.size.width,content.size.height)*0.5));
    CGFloat inset=radius*(1-M_SQRT1_2);
    CGPoint delta=CGPointMake(CGRectGetMinX(content)+inset-frame.size.width/2,
                             CGRectGetMinY(content)+inset-frame.size.height/2);
    delta=CGPointApplyAffineTransform(delta,CGAffineTransformMakeRotation(angle));
    return CGPointMake(CGRectGetMidX(frame)+delta.x,CGRectGetMidY(frame)+delta.y);
}
static inline CGRect ZNSDipDraggedFrame(CGRect proposed,CGRect safe,CGRect screen) {
    proposed.origin.x=ZNSClamp(proposed.origin.x,CGRectGetMinX(safe),CGRectGetMaxX(safe)-proposed.size.width);
    proposed.origin.y=fmax(CGRectGetMinY(safe),proposed.origin.y);
    CGFloat stop=CGRectGetMaxY(screen)-proposed.size.height*0.30;
    if(proposed.origin.y>stop) proposed.origin.y=stop+fmin(40,(proposed.origin.y-stop)*0.25);
    // Always retain a reachable tool, even at the end of rubber-band travel.
    proposed.origin.y=fmin(proposed.origin.y,CGRectGetMaxY(screen)-44);
    return proposed;
}
static inline unsigned ZNSDipShouldSettle(CGRect frame,CGRect screen) {
    return frame.size.height>0 && CGRectGetMaxY(frame)-CGRectGetMaxY(screen)>frame.size.height*0.30;
}
// Movable parked cards stop at the physical bottom before any dip admission.
// Only the visual surface compresses; neither the canvas nor the hit frame shrinks.
static inline CGRect ZNSDipSqueezedFrame(CGRect proposed,CGRect safe,CGRect screen) {
    proposed.origin.x=ZNSClamp(proposed.origin.x,CGRectGetMinX(safe),CGRectGetMaxX(safe)-proposed.size.width);
    CGFloat bottom=CGRectGetMaxY(screen)-proposed.size.height;
    proposed.origin.y=ZNSClamp(proposed.origin.y,fmin(CGRectGetMinY(safe),bottom),bottom);
    return proposed;
}
static inline CGFloat ZNSDipSqueezeProgress(CGRect proposed,CGRect screen) {
    if(!isfinite(proposed.size.height) || proposed.size.height<=0) return 0;
    CGFloat excess=CGRectGetMaxY(proposed)-CGRectGetMaxY(screen);
    // Mild gain leaves usable finger travel after contact. The threshold refers
    // to the actual visual height reduction, not the original offscreen overlap.
    return ZNSClamp(excess*1.5/proposed.size.height,0,0.72);
}
static inline CGRect ZNSDipCardFrame(CGRect expanded,CGRect safe,CGRect screen,unsigned index,unsigned count) {
    CGRect fit=safe;
    // Reserve a bounded fan span for up to five cards. Every card shares one
    // movable toolbar, so each exposed left corner remains a snap destination.
    CGFloat span=count>1?fmin(168,fit.size.width*0.42):0;
    fit.origin.x+=span/2; fit.size.width=fmax(1,fit.size.width-span);
    // Admission geometry belongs only to restoration, never to tray sizing.
    // All cards share the same portrait reference for this container, including
    // while a formerly landscape scene is awaiting its portrait transaction.
    (void)expanded;
    CGRect reference=ZNSDefaultMainWindow(safe,screen.size,0);
    CGRect frame=ZNSFitMainWindow(reference,fit,0);
    frame=ZNSCenterFrame(frame,fit);
    if(count>1) frame.origin.x+=((CGFloat)index/((CGFloat)count-1)-0.5)*span;
    frame.origin.y=CGRectGetMaxY(screen)-frame.size.height*0.30;
    return frame;
}
static inline CGFloat ZNSDipReservedTop(CGRect frame) {
    // Include the final tilted bounding box and a gap for parked windows/icons.
    return CGRectGetMidY(frame)-(frame.size.height*cos(ZNSDipAngle())+frame.size.width*sin(ZNSDipAngle()))/2-10;
}
