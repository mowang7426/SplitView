#pragma once
#include <CoreGraphics/CoreGraphics.h>
#include <math.h>
#include "ZNSGeometry.h"

// Single source for normal aspect-fit and layered restore endpoints. Rectangles
// are local, so window/screen origins affect only the root mapping.
static inline CGRect ZNSPortraitFittedCanvas(CGRect content, CGSize canvas) {
    CGFloat s=fmin(content.size.width/canvas.width,content.size.height/canvas.height);
    return CGRectMake(CGRectGetMidX(content)-canvas.width*s/2,
        CGRectGetMidY(content)-canvas.height*s/2,canvas.width*s,canvas.height*s);
}
static inline CGAffineTransform ZNSPortraitRectTransform(CGRect source, CGRect destination) {
    return CGAffineTransformMake(destination.size.width/source.size.width,0,0,
        destination.size.height/source.size.height,
        CGRectGetMidX(destination)-CGRectGetMidX(source),
        CGRectGetMidY(destination)-CGRectGetMidY(source));
}
typedef struct {
    CGAffineTransform body,content,canvas;
} ZNSPortraitVisualGeometry;
static inline ZNSPortraitVisualGeometry ZNSPortraitVisualGeometryMake(CGSize expanded, CGSize saved, CGSize nativeCanvas) {
    CGRect bounds=(CGRect){CGPointZero,expanded}, normal=(CGRect){CGPointZero,saved};
    CGRect body=ZNSMainBody(normal), content=ZNSMainContent(normal);
    CGRect fit=ZNSPortraitFittedCanvas((CGRect){CGPointZero,content.size},nativeCanvas);
    CGFloat sx=expanded.width/saved.width, sy=expanded.height/saved.height;
    CGRect bodyTarget=CGRectMake(body.origin.x*sx,body.origin.y*sy,body.size.width*sx,body.size.height*sy);
    CGRect contentTarget=CGRectMake(content.origin.x*sx,content.origin.y*sy,content.size.width*sx,content.size.height*sy);
    // Expanded canvas and content have identical bounds/centers. Counter the
    // content transform to retain normal canvas aspect-fit letterboxing.
    CGRect canvasTarget=CGRectMake(fit.origin.x/content.size.width*expanded.width,
        fit.origin.y/content.size.height*expanded.height,
        fit.size.width/content.size.width*expanded.width,
        fit.size.height/content.size.height*expanded.height);
    return (ZNSPortraitVisualGeometry){ZNSPortraitRectTransform(bounds,bodyTarget),
        ZNSPortraitRectTransform(bounds,contentTarget),ZNSPortraitRectTransform(bounds,canvasTarget)};
}

// The reference video leaves roughly 18% of the desktop visible. The scene
// includes the keyboard area: UIKit owns avoidance ONCE, not this container.
// Scene points and screen points have unit scale; never fit a full-height
// portrait canvas into the shorter chat-only region.
typedef struct {
    CGRect frame;
    CGSize canvas;
    CGRect keyboardInScene;
    CGFloat inputBottom;
} ZNSPortraitKeyboardLayout;

static inline int ZNSPortraitKeyboardLayoutMake(CGRect keyboard, CGRect screen, CGFloat safeTop,
                                               ZNSPortraitKeyboardLayout *layout) {
    if (!layout || !isfinite(keyboard.origin.x) || !isfinite(keyboard.origin.y) ||
        !isfinite(keyboard.size.width) || !isfinite(keyboard.size.height) ||
        !isfinite(screen.origin.x) || !isfinite(screen.origin.y) ||
        !isfinite(screen.size.width) || !isfinite(screen.size.height) || !isfinite(safeTop) || safeTop<0 ||
        screen.size.width<=0 || screen.size.height<=screen.size.width ||
        keyboard.size.height<100 || keyboard.size.width<=0 ||
        fabs(keyboard.size.width-screen.size.width)>2 ||
        fabs(CGRectGetMinX(keyboard)-CGRectGetMinX(screen))>2 ||
        fabs(CGRectGetMaxY(keyboard)-CGRectGetMaxY(screen))>2) return 0;
    CGFloat top=CGRectGetMinY(screen)+fmax(safeTop,round(screen.size.height*0.18));
    if (CGRectGetMinY(keyboard)-top<120) return 0;
    CGRect frame=CGRectMake(screen.origin.x,top,screen.size.width,CGRectGetMaxY(screen)-top);
    layout->frame=frame;
    layout->canvas=frame.size;
    layout->keyboardInScene=CGRectOffset(keyboard,-frame.origin.x,-frame.origin.y);
    layout->inputBottom=CGRectGetMinY(layout->keyboardInScene);
    return 1;
}
static inline int ZNSPortraitKeyboardTarget(CGRect keyboard, CGRect screen, CGFloat top, CGRect *target) {
    ZNSPortraitKeyboardLayout layout;
    if (!target || !ZNSPortraitKeyboardLayoutMake(keyboard,screen,top,&layout)) return 0;
    *target=layout.frame;
    return 1;
}

// Shared by production layout and host tests: a temporary scene is presented
// at native point size, with no extra translation, crop or avoidance inset.
static inline CGAffineTransform ZNSPortraitCanvasTransform(void) {
    return CGAffineTransformIdentity;
}
static inline CGPoint ZNSPortraitScreenToScene(CGPoint point,CGRect frame) {
    return CGPointMake(point.x-frame.origin.x,point.y-frame.origin.y);
}
