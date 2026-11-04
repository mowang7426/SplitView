#pragma once
#include <CoreGraphics/CoreGraphics.h>
#include <math.h>
static inline CGFloat ZNSClamp(CGFloat v, CGFloat lo, CGFloat hi) { return fmin(fmax(v,lo),fmax(lo,hi)); }
static inline CGRect ZNSConstrain(CGRect r, CGRect safe) {
    r.size.width=ZNSClamp(r.size.width,fmin(220,safe.size.width),safe.size.width);
    r.size.height=ZNSClamp(r.size.height,fmin(180,safe.size.height),safe.size.height);
    r.origin.x=ZNSClamp(r.origin.x,CGRectGetMinX(safe),CGRectGetMaxX(safe)-r.size.width);
    r.origin.y=ZNSClamp(r.origin.y,CGRectGetMinY(safe),CGRectGetMaxY(safe)-r.size.height);
    return r;
}
// Keep an icon's size unchanged while clamping its position.
static inline CGRect ZNSConstrainIcon(CGRect r, CGRect safe) {
    r.origin.x=ZNSClamp(r.origin.x,CGRectGetMinX(safe),CGRectGetMaxX(safe)-r.size.width);
    r.origin.y=ZNSClamp(r.origin.y,CGRectGetMinY(safe),CGRectGetMaxY(safe)-r.size.height);
    return r;
}
// Compact phone/narrow multitasking surfaces retain the current sizes.
static inline CGFloat ZNSSurfaceScale(CGRect bounds) {
    CGFloat shortSide=fmin(bounds.size.width,bounds.size.height);
    return isfinite(shortSide) && shortSide>=600?shortSide/428.0:1.0;
}
// Unbounded reference without a fake 10000pt surface. No border/gutter:
// keep the current live-content-only footprint when adding tablet adaptation.
static inline CGRect ZNSThumbnailReferenceFrame(CGSize canvas) {
    if (!isfinite(canvas.width) || !isfinite(canvas.height) || canvas.width<=0 || canvas.height<=0) return CGRectZero;
    CGFloat factor=canvas.width>canvas.height?1.2:1.0;
    CGFloat scale=fmin(82*factor/canvas.width,126*factor/canvas.height);
    return CGRectMake(0,0,canvas.width*scale,canvas.height*scale);
}
// Parked windows have no main-window chrome or transparent gutter.
// Preserve the former live-content scale, not the old padded outer size.
static inline CGFloat ZNSFirstTierSizeBoost(CGSize canvas) {
    return canvas.width>canvas.height?1.25:1.10;
}
static inline CGRect ZNSThumbnailFrame(CGSize canvas, CGRect safe) {
    CGRect base=ZNSThumbnailReferenceFrame(canvas);
    if (CGRectIsEmpty(base) || safe.size.width<=0 || safe.size.height<=0) return CGRectZero;
    CGFloat scale=fmin(ZNSSurfaceScale(safe)*ZNSFirstTierSizeBoost(canvas),fmin(safe.size.width/base.size.width,safe.size.height/base.size.height));
    return CGRectMake(safe.origin.x,safe.origin.y,base.size.width*scale,base.size.height*scale);
}

// Side 0=left, 1=right. Outward swipe docks, inward swipe crosses sides.
static inline unsigned ZNSThumbnailSwipeDocks(unsigned rightSide,unsigned swipeRight) {
    return !!rightSide==!!swipeRight;
}
// First-tier gestures retain their original thresholds.
static inline unsigned ZNSThumbnailHorizontalSwipeRecognized(CGPoint delta,CGPoint velocity,unsigned rightSide) {
    if(!isfinite(delta.x) || !isfinite(delta.y) || !isfinite(velocity.x) || !isfinite(velocity.y)) return 0;
    CGFloat dx=fabs(delta.x),dy=fabs(delta.y);
    unsigned outward=ZNSThumbnailSwipeDocks(rightSide,delta.x>0);
    if(!outward) return dx>=40 && dx>1.5*dy;
    return (dx>=22 && dx>=1.2*dy) ||
        (dx>=12 && delta.x*velocity.x>0 && fabs(velocity.x)>=280 && fabs(velocity.x)>1.5*fabs(velocity.y));
}
static inline CGRect ZNSThumbnailFrameAtSide(CGSize canvas,CGRect safe,unsigned rightSide) {
    CGRect frame=ZNSThumbnailFrame(canvas,safe);
    if (!CGRectIsEmpty(frame) && rightSide) frame.origin.x=CGRectGetMaxX(safe)-frame.size.width;
    return frame;
}

static inline unsigned ZNSThumbnailMaxTier(unsigned landscape) { return landscape?2:1; }
static inline unsigned ZNSThumbnailNextTier(unsigned tier,unsigned landscape) {
    unsigned maximum=ZNSThumbnailMaxTier(landscape); return tier<maximum?tier+1:maximum;
}
static inline unsigned ZNSThumbnailReturnsFirst(unsigned tier,unsigned right,unsigned swipeRight) {
    return tier==1 && ZNSThumbnailSwipeDocks(right,swipeRight);
}
// Third tier fills the supplied screen bounds, without a fixed multiplier cap.
static inline CGFloat ZNSThumbnailTierScale(unsigned tier) { return tier==0?1.0:(tier==1?3.0:INFINITY); }
static inline CGRect ZNSThumbnailTierFrame(CGSize canvas,CGRect safe,unsigned rightSide,unsigned tier) {
    CGRect base=ZNSThumbnailReferenceFrame(canvas);
    if (CGRectIsEmpty(base) || safe.size.width<=0 || safe.size.height<=0) return CGRectZero;
    // Tier three uses the content aspect ratio itself: no scaled outer gutter.
    // Keep the whole live canvas visible when an unusually short screen limits it.
    if (tier>=2) {
        CGFloat scale=fmin(safe.size.width/canvas.width,safe.size.height/canvas.height);
        if(safe.size.width>safe.size.height)
            scale=fmin(scale,sqrt((safe.size.width*safe.size.height*0.5)/(canvas.width*canvas.height)));
        CGRect r=CGRectMake(safe.origin.x,safe.origin.y,canvas.width*scale,canvas.height*scale);
        if (rightSide) r.origin.x=CGRectGetMaxX(safe)-r.size.width;
        return r;
    }
    CGFloat boost=tier==0?ZNSFirstTierSizeBoost(canvas):1.0;
    CGFloat factor=fmin(ZNSThumbnailTierScale(tier)*ZNSSurfaceScale(safe)*boost,fmin(safe.size.width/base.size.width,safe.size.height/base.size.height));
    CGRect r=CGRectMake(safe.origin.x,safe.origin.y,base.size.width*factor,base.size.height*factor);
    if (rightSide) r.origin.x=CGRectGetMaxX(safe)-r.size.width;
    return r;
}
static inline CGRect ZNSThumbnailContentFrame(CGSize canvas,CGRect bounds,unsigned tier) {
    (void)canvas; (void)tier;
    return bounds;
}
// A deliberate flick, not an ordinary long/slow drag. Delta and velocity must
// agree, remain strongly axial, and cross all distance/time/speed thresholds.
static inline unsigned ZNSThumbnailDeliberateFlick(CGPoint delta,CGPoint velocity,double elapsed,unsigned horizontal) {
    CGFloat axis=horizontal?delta.x:delta.y,cross=horizontal?delta.y:delta.x;
    CGFloat speed=horizontal?velocity.x:velocity.y,crossSpeed=horizontal?velocity.y:velocity.x;
    return isfinite(elapsed) && elapsed>0 && elapsed<=0.40 && fabs(axis)>=120 &&
        fabs(axis)>=3*fabs(cross) && fabs(speed)>=900 && fabs(speed)>=2*fabs(crossSpeed) && axis*speed>0;
}

// More accessible second-tier horizontal / second- and third-tier close swipes.
// Retain time, direction and speed gates so ordinary slow dragging stays movement.
static inline unsigned ZNSThumbnailSensitiveFlick(CGPoint delta,CGPoint velocity,double elapsed,unsigned horizontal) {
    if(!isfinite(delta.x) || !isfinite(delta.y) || !isfinite(velocity.x) || !isfinite(velocity.y)) return 0;
    CGFloat axis=horizontal?delta.x:delta.y,cross=horizontal?delta.y:delta.x;
    CGFloat speed=horizontal?velocity.x:velocity.y,crossSpeed=horizontal?velocity.y:velocity.x;
    return isfinite(elapsed) && elapsed>0 && elapsed<=0.60 && fabs(axis)>=44 &&
        fabs(axis)>=1.8*fabs(cross) && fabs(speed)>=420 && fabs(speed)>=1.4*fabs(crossSpeed) && axis*speed>0;
}

// Main window chrome: four-point horizontal borders and 80 points vertically.
// Fit by one scale on the content, never by independently clamping width/height.
static inline CGRect ZNSFitCanvasWindow(CGRect r, CGRect safe) {
    CGFloat cw=r.size.width-8,ch=r.size.height-80;
    if (cw<=0 || ch<=0 || safe.size.width<=8 || safe.size.height<=80) return CGRectZero;
    CGFloat scale=fmin(1,fmin((safe.size.width-8)/cw,(safe.size.height-80)/ch));
    r.size=CGSizeMake(cw*scale+8,ch*scale+80);
    return ZNSConstrainIcon(r,safe);
}
static inline CGSize ZNSScreenCanvas(CGSize screen,unsigned landscape) {
    if (!isfinite(screen.width) || !isfinite(screen.height) || screen.width<=0 || screen.height<=0) return CGSizeZero;
    CGFloat shortSide=fmin(screen.width,screen.height),longSide=fmax(screen.width,screen.height);
    return landscape?CGSizeMake(longSide,shortSide):CGSizeMake(shortSide,longSide);
}
static inline CGRect ZNSInitialCanvasWindow(CGRect safe,CGSize screen) {
    CGSize portrait=ZNSScreenCanvas(screen,0);
    if (portrait.width<=0) return CGRectZero;
    CGFloat cw=fmax(1,fmin(320,safe.size.width*0.78)-8);
    CGFloat ch=cw*portrait.height/portrait.width;
    CGFloat scale=fmin(1,fmax(1,safe.size.height*0.76-80)/ch);
    CGRect r=CGRectMake(0,0,cw*scale+8,ch*scale+80);
    r=ZNSFitCanvasWindow(r,safe);
    r.origin=CGPointMake(CGRectGetMidX(safe)-r.size.width/2,CGRectGetMidY(safe)-r.size.height/2);
    return r;
}
static inline CGRect ZNSResizeCanvasWindow(CGRect start, CGPoint delta, unsigned corner, CGRect safe) {
    CGFloat cw=start.size.width-8,ch=start.size.height-80;
    if (cw<=0 || ch<=0) return start;
    CGFloat sx=(corner&1)?1:-1,sy=(corner&2)?1:-1;
    CGFloat ax=(corner&1)?CGRectGetMinX(start):CGRectGetMaxX(start);
    CGFloat ay=(corner&2)?CGRectGetMinY(start):CGRectGetMaxY(start);
    CGFloat aw=(corner&1)?CGRectGetMaxX(safe)-ax:ax-CGRectGetMinX(safe);
    CGFloat ah=(corner&2)?CGRectGetMaxY(safe)-ay:ay-CGRectGetMinY(safe);
    CGFloat maximum=fmax(0,fmin((aw-8)/cw,(ah-80)/ch));
    // Landscape presentation has a wider continuous zoom range; App canvas
    // remains untouched and the content aspect ratio stays fixed.
    CGFloat minimum=fmin(maximum,fmin(1,fmax((cw>ch?120:150)/cw,(cw>ch?55:90)/ch)));
    CGFloat scale=ZNSClamp(1+(sx*delta.x*cw+sy*delta.y*ch)/(cw*cw+ch*ch),minimum,maximum);
    CGFloat w=cw*scale+8,h=ch*scale+80;
    return CGRectMake((corner&1)?ax:ax-w,(corner&2)?ay:ay-h,w,h);
}

// Both device orientations keep controls above/below the body, never in a side rail.
// 3pt side clearance keeps 6pt corner dots visible even against a screen edge.
static inline CGSize ZNSMainChrome(unsigned fullHeight) { (void)fullHeight; return CGSizeMake(14,54); }
static inline CGRect ZNSMainBody(CGRect bounds) {
    return CGRectMake(bounds.origin.x+3,bounds.origin.y+38,bounds.size.width-6,bounds.size.height-46);
}
static inline CGRect ZNSMainContent(CGRect bounds) { return CGRectInset(ZNSMainBody(bounds),4,4); }
// Decoration scale follows the live content relative to this orientation's
// default window. Keep the App canvas and the fixed gesture regions unchanged.
static inline CGFloat ZNSMainDecorationScale(CGRect bounds,CGRect reference) {
    CGRect content=ZNSMainContent(bounds),base=ZNSMainContent(reference);
    if(CGRectIsEmpty(content) || CGRectIsEmpty(base)) return 1;
    CGFloat scale=fmin(content.size.width/base.size.width,content.size.height/base.size.height);
    return isfinite(scale) && scale>0?fmin(1,scale):1;
}
static inline CGFloat ZNSMainToolScale(CGFloat width,unsigned expanded) {
    return fmin(expanded?0.63:0.5,width/(expanded?150:116));
}
static inline CGRect ZNSMainToolsFrame(CGRect bounds,unsigned expanded) {
    CGFloat width=fmin(expanded?94.5:58,fmax(1,bounds.size.width-60));
    CGFloat scale=ZNSMainToolScale(width,expanded);
    CGFloat height=16+16*scale;
    return CGRectMake(bounds.origin.x+8,bounds.origin.y+38-(expanded?6:2)-height,width,height);
}
// Corner arcs retain the former dots' midpoint and radial distance to the body.
static inline CGFloat ZNSCornerArcRadius(void) { return 16.0*sqrt(2.0); }
static inline CGFloat ZNSBarThickness(void) { return 3.0; }
static inline CGRect ZNSMainBarFrame(CGRect bounds,unsigned expanded,unsigned bottom) {
    CGRect body=ZNSMainBody(bounds),tools=ZNSMainToolsFrame(bounds,expanded);
    CGFloat width=bottom?fmin(68,fmax(1,bounds.size.width-20)):
        fmin(68,fmax(1,CGRectGetMaxX(bounds)-CGRectGetMaxX(tools)-25));
    CGFloat x=bottom?CGRectGetMidX(bounds)-width/2:
        fmax(CGRectGetMidX(bounds)-width/2,CGRectGetMaxX(tools)+8);
    // Same 4pt centre distance on both sides, independent of toolbar expansion.
    CGFloat y=bottom?CGRectGetMaxY(body):CGRectGetMinY(body)-8;
    return CGRectMake(x,y,width,8);
}
// Separate from the visible 8pt frame: expand outward, never into App content.
// Clip to the physical screen expressed in the same coordinates as bounds.
static inline CGRect ZNSMainBarHitFrame(CGRect bounds,CGRect screen,unsigned expanded,unsigned bottom) {
    CGRect bar=ZNSMainBarFrame(bounds,expanded,bottom);
    CGFloat left=fmax(CGRectGetMinX(bounds)+10,CGRectGetMinX(bar)-12);
    CGFloat right=fmin(CGRectGetMaxX(bounds)-10,CGRectGetMaxX(bar)+12);
    CGFloat top=bottom?CGRectGetMinY(bar):CGRectGetMinY(bar)-20;
    CGFloat end=bottom?CGRectGetMaxY(bar)+24:fmin(CGRectGetMaxY(bar)+8,CGRectGetMinY(ZNSMainContent(bounds))-1);
    if(!bottom) left=fmax(left,CGRectGetMaxX(ZNSMainToolsFrame(bounds,expanded))+1);
    return CGRectIntersection(CGRectMake(left,top,fmax(0,right-left),fmax(0,end-top)),screen);
}
static inline CGRect ZNSCenterFrame(CGRect r,CGRect bounds) {
    r.origin=CGPointMake(CGRectGetMidX(bounds)-r.size.width/2,CGRectGetMidY(bounds)-r.size.height/2); return r;
}
static inline CGRect ZNSFitMainWindow(CGRect r,CGRect bounds,unsigned side) {
    CGSize c=ZNSMainChrome(side); CGFloat w=r.size.width-c.width,h=r.size.height-c.height;
    if(w<=0 || h<=0 || bounds.size.width<=c.width || bounds.size.height<=c.height) return CGRectZero;
    CGFloat scale=fmin(1,fmin((bounds.size.width-c.width)/w,(bounds.size.height-c.height)/h));
    r.size=CGSizeMake(w*scale+c.width,h*scale+c.height); return ZNSConstrainIcon(r,bounds);
}
// Stable pre-reduction reference for both App presentation and decoration scale.
static inline CGRect ZNSMainReferenceWindow(CGRect bounds,CGSize screen,unsigned landscape) {
    CGSize canvas=ZNSScreenCanvas(screen,landscape);
    unsigned side=bounds.size.width>bounds.size.height && !landscape;
    if(canvas.width<=0 || canvas.height<=0) return CGRectZero;
    CGSize c=ZNSMainChrome(side);
    // On a portrait device a landscape App opens edge-to-edge horizontally.
    // Chrome stays inside the window; only the content is uniformly scaled.
    unsigned fillWidth=landscape && bounds.size.width<=bounds.size.height;
    CGFloat landscapeWidth=fmin(screen.width>screen.height?screen.width*0.60:fmax(screen.width,screen.height)*0.60,bounds.size.width);
    CGFloat scale=side?(bounds.size.height-c.height)/canvas.height:
        (fillWidth?fmin((bounds.size.width-c.width)/canvas.width,(bounds.size.height-c.height)/canvas.height):
         (landscape?fmin((landscapeWidth-c.width)/canvas.width,(bounds.size.height-c.height)/canvas.height):
          fmin(312*ZNSSurfaceScale(bounds)/canvas.width,(bounds.size.height*0.76-c.height)/canvas.height)));
    scale=fmin(scale,(bounds.size.width-c.width)/canvas.width);
    if(scale<=0) return CGRectZero;
    return ZNSCenterFrame(CGRectMake(0,0,canvas.width*scale+c.width,canvas.height*scale+c.height),bounds);
}
static inline CGRect ZNSDefaultMainWindow(CGRect bounds,CGSize screen,unsigned landscape) {
    CGRect frame=ZNSMainReferenceWindow(bounds,screen,landscape);
    // Only portrait-device / portrait-App defaults shrink. Landscape Apps
    // retain their edge-to-edge default and landscape-device sizing is unchanged.
    if(!landscape && bounds.size.width<=bounds.size.height && !CGRectIsEmpty(frame)) {
        CGSize chrome=ZNSMainChrome(0);
        frame.size=CGSizeMake((frame.size.width-chrome.width)*0.85+chrome.width,
                              (frame.size.height-chrome.height)*0.85+chrome.height);
        frame=ZNSCenterFrame(frame,bounds);
    }
    if(bounds.size.width<=bounds.size.height && !CGRectIsEmpty(frame)) {
        // Enlarge the previous portrait-device default by 10%, retaining App ratio.
        CGSize chrome=ZNSMainChrome(0);
        frame.size=CGSizeMake((frame.size.width-chrome.width)*1.10+chrome.width,
                              (frame.size.height-chrome.height)*1.10+chrome.height);
        frame=ZNSCenterFrame(ZNSFitMainWindow(frame,bounds,0),bounds);
    }
    // Increase both defaults by a further 10% in content dimensions; fit the
    // complete window when an orientation already uses the available width/height.
    if(!CGRectIsEmpty(frame)) {
        CGSize chrome=ZNSMainChrome(0);
        frame.size=CGSizeMake((frame.size.width-chrome.width)*1.10+chrome.width,
                              (frame.size.height-chrome.height)*1.10+chrome.height);
        frame=ZNSCenterFrame(ZNSFitMainWindow(frame,bounds,0),bounds);
    }
    return frame;
}
static inline CGRect ZNSResizeWindowWithChrome(CGRect start,CGPoint delta,unsigned corner,CGRect bounds,CGSize c) {
    CGFloat w=start.size.width-c.width,h=start.size.height-c.height;
    if(w<=0 || h<=0) return start;
    CGFloat sx=(corner&1)?1:-1,sy=(corner&2)?1:-1;
    CGFloat ax=(corner&1)?CGRectGetMinX(start):CGRectGetMaxX(start),ay=(corner&2)?CGRectGetMinY(start):CGRectGetMaxY(start);
    CGFloat aw=(corner&1)?CGRectGetMaxX(bounds)-ax:ax-CGRectGetMinX(bounds),ah=(corner&2)?CGRectGetMaxY(bounds)-ay:ay-CGRectGetMinY(bounds);
    // Landscape may translate while growing: an edge-adjacent opposite corner
    // must not lock the size when unused space exists on the other side.
    unsigned movableAnchor=bounds.size.width>bounds.size.height;
    if(movableAnchor) { aw=bounds.size.width; ah=bounds.size.height; }
    CGFloat maximum=fmax(0,fmin((aw-c.width)/w,(ah-c.height)/h));
    CGFloat minimum=fmin(maximum,fmin(1,fmax((w>h?120:80)/w,90/h)));
    CGFloat scale=ZNSClamp(1+(sx*delta.x*w+sy*delta.y*h)/(w*w+h*h),minimum,maximum);
    CGFloat nw=w*scale+c.width,nh=h*scale+c.height;
    CGRect frame=CGRectMake((corner&1)?ax:ax-nw,(corner&2)?ay:ay-nh,nw,nh);
    return movableAnchor?ZNSConstrainIcon(frame,bounds):frame;
}
static inline CGRect ZNSResizeMainWindow(CGRect start,CGPoint delta,unsigned corner,CGRect bounds,unsigned side) {
    return ZNSResizeWindowWithChrome(start,delta,corner,bounds,ZNSMainChrome(side));
}
static inline CGPoint ZNSCornerCenter(CGRect body,unsigned corner) {
    return CGPointMake((corner&1)?CGRectGetMaxX(body):CGRectGetMinX(body),
                       (corner&2)?CGRectGetMaxY(body):CGRectGetMinY(body));
}
static inline CGRect ZNSCornerHandle(CGRect body,CGRect screen,unsigned corner) {
    CGPoint center=ZNSCornerCenter(body,corner);
    // A 44x28 strip: 24pt outward and only the existing 4pt border inward.
    // A single CGRect cannot also extend down the side without covering content.
    return CGRectIntersection(CGRectMake(center.x-22,center.y-((corner&2)?4:24),44,28),screen);
}
static inline CGRect ZNSMainCornerHandle(CGRect bounds,CGRect screen,unsigned corner,unsigned expanded) {
    CGRect handle=ZNSCornerHandle(ZNSMainBody(bounds),screen,corner);
    if(CGRectIsNull(handle) || CGRectIsEmpty(handle)) return handle;
    CGRect tools=ZNSMainToolsFrame(bounds,expanded);
    if(corner==0 && CGRectIntersectsRect(handle,tools))
        handle.size.width=fmax(0,CGRectGetMinX(tools)-1-handle.origin.x);
    // Reserve bar hit regions too, so gesture priority cannot steal either target.
    CGRect bar=ZNSMainBarHitFrame(bounds,screen,expanded,!!(corner&2));
    if(CGRectIntersectsRect(handle,bar)) {
        if(corner&1) {
            CGFloat end=CGRectGetMaxX(handle);
            handle.origin.x=CGRectGetMaxX(bar)+1;
            handle.size.width=fmax(0,end-handle.origin.x);
        } else handle.size.width=fmax(0,CGRectGetMinX(bar)-1-handle.origin.x);
    }
    return handle;
}
// Complete the L-shaped target along the side of each visible corner arc.
// Kept separate from the horizontal strip: the union's bounding box would
// otherwise steal App content touches. All coordinates are floating-view local.
static inline CGRect ZNSMainCornerSideHandle(CGRect bounds,CGRect screen,unsigned corner) {
    CGPoint center=ZNSCornerCenter(ZNSMainBody(bounds),corner);
    return CGRectIntersection(CGRectMake(center.x-((corner&1)?4:24),
                                        center.y-((corner&2)?24:4),28,28),screen);
}
static inline CGFloat ZNSFullscreenProgress(CGFloat deltaY) { return ZNSClamp(-deltaY/180.0,0,1); }
static inline unsigned ZNSShouldEnterFullscreen(CGFloat deltaY,CGFloat velocityY) {
    return ZNSFullscreenProgress(deltaY)>=0.55 || (deltaY<=-45 && velocityY<=-700);
}
// Fit the unchanged App canvas into the screen by one scale and translation.
// The temporary chrome may extend beyond the screen and fades during handoff.
static inline CGAffineTransform ZNSFullscreenTransform(CGRect frame,CGRect screen,CGFloat progress) {
    CGRect content=ZNSMainContent(CGRectMake(0,0,frame.size.width,frame.size.height));
    if(CGRectIsEmpty(content) || CGRectIsEmpty(screen)) return CGAffineTransformIdentity;
    CGFloat p=ZNSClamp(progress,0,1);
    CGFloat target=fmax(1,fmin(screen.size.width/content.size.width,screen.size.height/content.size.height));
    CGFloat scale=1+(target-1)*p;
    CGFloat dx=CGRectGetMidX(content)-frame.size.width/2,dy=CGRectGetMidY(content)-frame.size.height/2;
    CGFloat tx=CGRectGetMidX(screen)-(CGRectGetMidX(frame)+target*dx);
    CGFloat ty=CGRectGetMidY(screen)-(CGRectGetMidY(frame)+target*dy);
    return CGAffineTransformMake(scale,0,0,scale,tx*p,ty*p);
}
static inline CGFloat ZNSDismissProgress(CGFloat deltaY,CGFloat height) {
    return ZNSClamp(-deltaY/fmax(100,height*0.45),0,1);
}
static inline unsigned ZNSShouldDismiss(CGFloat deltaY,CGFloat velocityY,CGFloat height) {
    return ZNSDismissProgress(deltaY,height)>=0.55 || (deltaY<=-45 && velocityY<=-700);
}

// Independent width/height for legacy geometry regression only; not used by UI.
static inline CGRect ZNSResizeFreeWindow(CGRect start,CGPoint delta,unsigned corner,CGRect safe) {
    CGFloat ax=(corner&1)?CGRectGetMinX(start):CGRectGetMaxX(start);
    CGFloat ay=(corner&2)?CGRectGetMinY(start):CGRectGetMaxY(start);
    CGFloat aw=(corner&1)?CGRectGetMaxX(safe)-ax:ax-CGRectGetMinX(safe);
    CGFloat ah=(corner&2)?CGRectGetMaxY(safe)-ay:ay-CGRectGetMinY(safe);
    CGFloat w=ZNSClamp(start.size.width+((corner&1)?delta.x:-delta.x),128,aw);
    CGFloat h=ZNSClamp(start.size.height+((corner&2)?delta.y:-delta.y),101,ah);
    w=fmin(w,aw); h=fmin(h,ah);
    return CGRectMake((corner&1)?ax:ax-w,(corner&2)?ay:ay-h,w,h);
}
static inline unsigned ZNSFrameClear(CGRect frame,const CGRect *occupied,unsigned count) {
    for(unsigned i=0;i<count;i++) if(CGRectIntersectsRect(CGRectInset(frame,-3,-3),occupied[i])) return 0;
    return 1;
}
// Finite packing search. Prefer exact current position for freely dragged items.
static inline CGFloat ZNSParkedIconSize(void) { return 56.0*1.08*1.06; }
// Horizontal columns keep 6pt. Only same-kind vertical gaps halve to 3pt.
static inline unsigned ZNSParkedPairClear(CGRect a,CGRect b,unsigned sameKind) {
    CGFloat gapY=sameKind?3:6;
    const CGFloat eps=0.00001;
    return CGRectGetMaxX(a)+6<=CGRectGetMinX(b)+eps || CGRectGetMaxX(b)+6<=CGRectGetMinX(a)+eps ||
        CGRectGetMaxY(a)+gapY<=CGRectGetMinY(b)+eps || CGRectGetMaxY(b)+gapY<=CGRectGetMinY(a)+eps;
}
static inline unsigned ZNSFindParkedFrame(CGRect desired,CGRect safe,const CGRect *occupied,unsigned count,unsigned right,unsigned preserve,CGRect *result) {
    if (desired.size.width>safe.size.width || desired.size.height>safe.size.height || CGRectIsEmpty(desired)) return 0;
    desired=ZNSConstrainIcon(desired,safe);
    unsigned clear=1;
    for(unsigned i=0;i<count;i++) if(!ZNSParkedPairClear(desired,occupied[i],1)) { clear=0; break; }
    if(preserve && clear) { *result=desired; return 1; }
    // Finite candidate edges instead of an 8pt scan that rounds away small gaps.
    for(unsigned column=0;column<=count;column++) {
        CGFloat x=right?CGRectGetMaxX(safe)-desired.size.width:CGRectGetMinX(safe);
        if(column) x=right?CGRectGetMinX(occupied[column-1])-6-desired.size.width:CGRectGetMaxX(occupied[column-1])+6;
        if(x<CGRectGetMinX(safe) || x+desired.size.width>CGRectGetMaxX(safe)) continue;
        CGFloat y=CGRectGetMinY(safe),maxY=CGRectGetMaxY(safe)-desired.size.height;
        for(unsigned pass=0;pass<=count && y<=maxY;pass++) {
            CGRect candidate=CGRectMake(x,y,desired.size.width,desired.size.height);
            CGFloat next=y;
            for(unsigned i=0;i<count;i++) if(!ZNSParkedPairClear(candidate,occupied[i],1)) next=fmax(next,CGRectGetMaxY(occupied[i])+3);
            if(next==y) { *result=candidate; return 1; }
            y=next;
        }
    }
    return 0;
}

// Edge-first vertical columns. All columns share the topmost same-side
// thumbnail's lower edge as their anchor; desired supplies size, never priority.
static inline unsigned ZNSFindIconFrame(CGRect desired,CGRect safe,const CGRect *occupied,unsigned count,unsigned thumbnailCount,unsigned right,CGRect *result) {
    if(CGRectIsEmpty(desired) || CGRectIsEmpty(safe) || desired.size.width>safe.size.width || desired.size.height>safe.size.height) return 0;
    CGFloat anchor=CGRectGetMinY(safe),firstY=INFINITY;
    for(unsigned i=0;i<thumbnailCount && i<count;i++) {
        CGRect r=occupied[i];
        if(CGRectIsEmpty(r) || !CGRectIntersectsRect(r,safe)) continue;
        CGFloat mid=CGRectGetMidX(r),middle=CGRectGetMidX(safe);
        if(right?mid<middle:mid>middle) continue;
        // Equal top edges choose the shorter obstruction, independent of order.
        if(CGRectGetMinY(r)<firstY || (CGRectGetMinY(r)==firstY && CGRectGetMaxY(r)+6<anchor)) {
            firstY=CGRectGetMinY(r); anchor=fmax(CGRectGetMinY(safe),CGRectGetMaxY(r)+6);
        }
    }
    CGFloat maxY=CGRectGetMaxY(safe)-desired.size.height;
    for(CGFloat step=0;step+desired.size.width<=safe.size.width;step+=desired.size.width+6) {
        CGFloat x=right?CGRectGetMaxX(safe)-desired.size.width-step:CGRectGetMinX(safe)+step;
        CGFloat y=anchor;
        // Every blocked pass advances below at least one obstacle. No pixel scan.
        for(unsigned pass=0;pass<=count && y<=maxY;pass++) {
            CGRect candidate=CGRectMake(x,y,desired.size.width,desired.size.height);
            CGFloat next=y;
            for(unsigned i=0;i<count;i++) if(!ZNSParkedPairClear(candidate,occupied[i],i>=thumbnailCount))
                next=fmax(next,CGRectGetMaxY(occupied[i])+(i<thumbnailCount?6:3));
            if(next==y) { *result=candidate; return 1; }
            y=next;
        }
    }
    return 0;
}

// Deterministic fallback when preserving individual icon anchors fragments space.
static inline CGRect ZNSIconGridFrame(CGRect safe,unsigned count,unsigned index) {
    if(!count || index>=count || CGRectIsEmpty(safe)) return CGRectZero;
    CGFloat size=fmin(ZNSParkedIconSize(),fmin(safe.size.width,safe.size.height)),gapX=6,gapY=3;
    unsigned columns=1,rows=1;
    for(unsigned attempt=0;attempt<64;attempt++) {
        columns=(unsigned)fmax(1,floor((safe.size.width+gapX)/(size+gapX)));
        rows=(unsigned)fmax(1,floor((safe.size.height+gapY)/(size+gapY)));
        if((double)columns*rows>=count) break;
        size*=0.8; gapX=fmin(6,size/3); gapY=fmin(3,size/6);
    }
    // Emergency repacking follows the same top-to-bottom, then inward order.
    return CGRectMake(safe.origin.x+(index/rows)*(size+gapX),safe.origin.y+(index%rows)*(size+gapY),size,size);
}

// Corner: 0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right.
// Project the dragged corner onto the original diagonal. The opposite
// corner stays fixed and one scale applies to both dimensions.
static inline CGRect ZNSResize(CGRect start, CGPoint delta, unsigned corner, CGRect safe) {
    CGFloat w=start.size.width,h=start.size.height;
    if (w<=0 || h<=0) return start;
    CGFloat sx=(corner&1)?1:-1,sy=(corner&2)?1:-1;
    CGFloat ax=(corner&1)?CGRectGetMinX(start):CGRectGetMaxX(start);
    CGFloat ay=(corner&2)?CGRectGetMinY(start):CGRectGetMaxY(start);
    CGFloat availableW=(corner&1)?CGRectGetMaxX(safe)-ax:ax-CGRectGetMinX(safe);
    CGFloat availableH=(corner&2)?CGRectGetMaxY(safe)-ay:ay-CGRectGetMinY(safe);
    CGFloat maxScale=fmax(0,fmin(availableW/w,availableH/h));
    CGFloat minScale=fmin(maxScale,fmin(1,fmax(220/w,180/h)));
    CGFloat scale=ZNSClamp(1+(sx*delta.x*w+sy*delta.y*h)/(w*w+h*h),minScale,maxScale);
    CGFloat newW=w*scale,newH=h*scale;
    return CGRectMake((corner&1)?ax:ax-newW,(corner&2)?ay:ay-newH,newW,newH);
}
