#pragma once
#include <CoreGraphics/CoreGraphics.h>
#include <math.h>

// Solve the host's LOCAL bounds from its existing quarter-turn/axis-aligned
// transform, not by assigning the oriented canvas as bounds (or using frame
// with a nonidentity transform). Preserve the system transform and bounds origin.
// position is CALayer.position, including anchor and transform translation.
// Reject intermediate/non-axis-aligned transforms rather than stretching them.
static inline unsigned ZNSHostGeometryForCanvas(CGSize canvas,CGAffineTransform t,
        CGPoint anchor,CGSize *localSize,CGPoint *position) {
    if(!localSize || !position || !isfinite(canvas.width) || !isfinite(canvas.height) ||
       canvas.width<=0 || canvas.height<=0 || !isfinite(t.a) || !isfinite(t.b) ||
       !isfinite(t.c) || !isfinite(t.d) || !isfinite(t.tx) || !isfinite(t.ty) ||
       !isfinite(anchor.x) || !isfinite(anchor.y)) return 0;
    CGFloat a=fabs(t.a),b=fabs(t.b),c=fabs(t.c),d=fabs(t.d);
    CGSize size;
    const CGFloat epsilon=1e-8;
    if(b<epsilon && c<epsilon && a>epsilon && d>epsilon)
        size=CGSizeMake(canvas.width/a,canvas.height/d);
    else if(a<epsilon && d<epsilon && b>epsilon && c>epsilon)
        size=CGSizeMake(canvas.height/b,canvas.width/c);
    else return 0;
    CGFloat dx=(0.5-anchor.x)*size.width,dy=(0.5-anchor.y)*size.height;
    CGPoint p=CGPointMake(canvas.width/2-t.a*dx-t.c*dy-t.tx,
                         canvas.height/2-t.b*dx-t.d*dy-t.ty);
    if(!isfinite(size.width) || !isfinite(size.height) || !isfinite(p.x) || !isfinite(p.y)) return 0;
    *localSize=size; *position=p; return 1;
}

// canvas is the oriented App-content size used by the presentation host.
// FBScene's frame is in fixed coordinates: undo the landscape axis swap once
// at the scene-settings boundary, never in the host/reference-size path.
// Do not sort the dimensions: arbitrary/asymmetric canvases must round-trip.
static inline CGRect ZNSSceneFrameForCanvas(CGSize canvas,unsigned landscape) {
    CGSize fixedSize=landscape?CGSizeMake(canvas.height,canvas.width):canvas;
    return (CGRect){CGPointZero,fixedSize};
}
