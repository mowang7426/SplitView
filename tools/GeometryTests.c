#include "../Sources/ZNSGeometry.h"
#include "../Sources/ZNSSceneGeometry.h"
#include <assert.h>
#include <stdio.h>
static void check(CGRect start, CGRect safe) {
    for (unsigned corner=0;corner<4;corner++) {
        for (int x=-2000;x<=2000;x+=100) for (int y=-2000;y<=2000;y+=100) {
            CGRect r=ZNSResize(start,CGPointMake(x,y),corner,safe);
            const double eps=1e-7;
            assert(CGRectGetMinX(r)>=CGRectGetMinX(safe)-eps);
            assert(CGRectGetMinY(r)>=CGRectGetMinY(safe)-eps);
            assert(CGRectGetMaxX(r)<=CGRectGetMaxX(safe)+eps);
            assert(CGRectGetMaxY(r)<=CGRectGetMaxY(safe)+eps);
            assert(r.size.width>0 && r.size.height>0);
            assert(fabs(r.size.width/r.size.height-start.size.width/start.size.height)<eps);
            assert(fabs(((corner&1)?CGRectGetMinX(r):CGRectGetMaxX(r))-((corner&1)?CGRectGetMinX(start):CGRectGetMaxX(start)))<eps);
            assert(fabs(((corner&2)?CGRectGetMinY(r):CGRectGetMaxY(r))-((corner&2)?CGRectGetMinY(start):CGRectGetMaxY(start)))<eps);
        }
        CGRect same=ZNSResize(start,CGPointZero,corner,safe);
        assert(fabs(same.size.width-start.size.width)<1e-7);
        assert(fabs(same.size.height-start.size.height)<1e-7);
    }
}
static void checkCanvas(CGRect safe,CGSize screen) {
    CGRect initial=ZNSInitialCanvasWindow(safe,screen);
    CGSize portrait=ZNSScreenCanvas(screen,0);
    const double eps=1e-7;
    assert(CGRectContainsRect(safe,initial));
    assert(fabs((initial.size.width-8)/(initial.size.height-80)-portrait.width/portrait.height)<eps);
    for(unsigned landscape=0;landscape<2;landscape++) {
        CGRect start=initial;
        if(landscape) {
            start.size=CGSizeMake(initial.size.height-80+8,initial.size.width-8+80);
            start=ZNSFitCanvasWindow(start,safe);
        }
        double ratio=landscape?portrait.height/portrait.width:portrait.width/portrait.height;
        for(unsigned corner=0;corner<4;corner++) {
            for(int x=-1500;x<=1500;x+=75) for(int y=-1500;y<=1500;y+=75) {
                CGRect r=ZNSResizeCanvasWindow(start,CGPointMake(x,y),corner,safe);
                assert(r.size.width>8 && r.size.height>80);
                assert(fabs((r.size.width-8)/(r.size.height-80)-ratio)<eps);
                assert(CGRectGetMinX(r)>=CGRectGetMinX(safe)-eps && CGRectGetMaxX(r)<=CGRectGetMaxX(safe)+eps);
                assert(CGRectGetMinY(r)>=CGRectGetMinY(safe)-eps && CGRectGetMaxY(r)<=CGRectGetMaxY(safe)+eps);
                assert(fabs(((corner&1)?CGRectGetMinX(r):CGRectGetMaxX(r))-((corner&1)?CGRectGetMinX(start):CGRectGetMaxX(start)))<eps);
                assert(fabs(((corner&2)?CGRectGetMinY(r):CGRectGetMaxY(r))-((corner&2)?CGRectGetMinY(start):CGRectGetMaxY(start)))<eps);
            }
            CGRect same=ZNSResizeCanvasWindow(start,CGPointZero,corner,safe);
            assert(fabs(same.size.width-start.size.width)<eps && fabs(same.size.height-start.size.height)<eps);
        }
        CGRect thumb=ZNSThumbnailFrame(CGSizeMake(start.size.width-8,start.size.height-80),safe);
        assert(CGRectContainsRect(safe,thumb));
        double factor=landscape?1.2:1.0;
        assert(thumb.size.width<=82*factor+eps && thumb.size.height<=126*factor+eps);
        assert(fabs(thumb.size.width/thumb.size.height-ratio)<eps);
        if (landscape && safe.size.width>=98.4 && safe.size.height>=151.2) {
            double oldScale=fmin(82/(start.size.width-8),126/(start.size.height-80));
            assert(fabs(thumb.size.width-(start.size.width-8)*oldScale*1.2)<eps);
            assert(fabs(thumb.size.height-(start.size.height-80)*oldScale*1.2)<eps);
        }
        assert(thumb.origin.x==safe.origin.x && thumb.origin.y==safe.origin.y);
        CGRect right=ZNSThumbnailFrameAtSide(CGSizeMake(start.size.width-8,start.size.height-80),safe,1);
        assert(fabs(CGRectGetMaxX(right)-CGRectGetMaxX(safe))<eps);
        assert(CGSizeEqualToSize(right.size,thumb.size));
        assert(right.origin.y==safe.origin.y);
        assert(CGRectContainsRect(safe,right));
    }
}
static void checkThumbnailTiers(CGSize canvas,CGRect safe) {
    CGRect base=ZNSThumbnailFrame(canvas,CGRectMake(0,0,10000,10000));
    for(unsigned tier=0;tier<3;tier++) for(unsigned side=0;side<2;side++) {
        CGRect r=ZNSThumbnailTierFrame(canvas,safe,side,tier);
        const double eps=1e-7;
        assert(CGRectContainsRect(safe,r));
        CGRect content=ZNSThumbnailContentFrame(canvas,r,tier);
        assert(fabs(content.size.width/content.size.height-canvas.width/canvas.height)<eps);
        if(tier>=2) {
            assert(CGRectEqualToRect(content,r));
            double scale=fmin(safe.size.width/canvas.width,safe.size.height/canvas.height);
            if(safe.size.width>safe.size.height)
                scale=fmin(scale,sqrt(0.5*safe.size.width*safe.size.height/(canvas.width*canvas.height)));
            assert(fabs(r.size.width-canvas.width*scale)<eps);
            assert(fabs(r.size.height-canvas.height*scale)<eps);
            if(safe.size.width<=safe.size.height && safe.size.width/canvas.width<=safe.size.height/canvas.height) {
                assert(fabs(CGRectGetMinX(content)-CGRectGetMinX(safe))<eps);
                assert(fabs(CGRectGetMaxX(content)-CGRectGetMaxX(safe))<eps);
            }
        } else {
            double factor=fmin(ZNSThumbnailTierScale(tier),fmin(safe.size.width/base.size.width,safe.size.height/base.size.height));
            assert(fabs(r.size.width-base.size.width*factor)<eps);
            assert(fabs(r.size.height-base.size.height*factor)<eps);
        }
        assert(fabs((side?CGRectGetMaxX(r):CGRectGetMinX(r))-(side?CGRectGetMaxX(safe):CGRectGetMinX(safe)))<eps);
        for (int x=-1000;x<=1000;x+=100) for(int y=-1000;y<=1000;y+=100) {
            CGRect moved=ZNSConstrainIcon(CGRectOffset(r,x,y),safe);
            assert(CGRectContainsRect(safe,moved));
            assert(CGSizeEqualToSize(moved.size,r.size));
        }
    }
}
static void checkHorizontalSwipes(void) {
    unsigned cases=0;
    for(unsigned right=0;right<2;right++) {
        CGFloat sign=right?1:-1;
        struct { CGFloat x,y,vx,vy; unsigned expected; } rows[]={
            {22,0,0,0,1},{21.99,0,0,0,0},{24,20,0,0,1},{24,20.01,0,0,0},
            {12,0,280,0,1},{11.99,0,1000,0,0},{12,0,279.99,0,0},
            {12,0,-300,0,0},{12,0,300,200,0},{12,0,300,199,1},
            {-39.99,0,-1000,0,0},{-40,0,0,0,1},{-45,30,0,0,0},{-45,29.99,0,0,1},
            {0,0,1000,0,0},{22,NAN,0,0,0},{22,0,INFINITY,0,0}
        };
        for(unsigned i=0;i<sizeof(rows)/sizeof(rows[0]);i++) {
            assert(ZNSThumbnailHorizontalSwipeRecognized(CGPointMake(sign*rows[i].x,rows[i].y),CGPointMake(sign*rows[i].vx,rows[i].vy),right)==rows[i].expected);
            cases++;
        }
    }
    printf("PASS: %u mirrored inward/outward swipe threshold cases.\n",cases);
}
static void checkFlicks(void) {
    assert(ZNSThumbnailDeliberateFlick(CGPointMake(140,10),CGPointMake(1000,50),0.25,1));
    assert(ZNSThumbnailDeliberateFlick(CGPointMake(-140,10),CGPointMake(-1000,50),0.25,1));
    assert(!ZNSThumbnailDeliberateFlick(CGPointMake(200,0),CGPointMake(300,0),1.2,1));
    assert(!ZNSThumbnailDeliberateFlick(CGPointMake(80,0),CGPointMake(1200,0),0.1,1));
    assert(!ZNSThumbnailDeliberateFlick(CGPointMake(140,100),CGPointMake(1000,500),0.25,1));
    assert(!ZNSThumbnailDeliberateFlick(CGPointMake(140,0),CGPointMake(-1000,0),0.25,1));
    assert(!ZNSThumbnailDeliberateFlick(CGPointMake(140,0),CGPointMake(1000,0),0.6,1));
    assert(!ZNSThumbnailDeliberateFlick(CGPointMake(10,180),CGPointMake(50,1200),0.25,1));
    assert(ZNSThumbnailDeliberateFlick(CGPointMake(10,-180),CGPointMake(50,-1200),0.25,0));
    for (int dx=-250;dx<=250;dx+=10) for(int dy=-250;dy<=250;dy+=10)
        assert(!ZNSThumbnailDeliberateFlick(CGPointMake(dx,dy),CGPointMake(dx,dy),1.0,1));
}
static void checkFreeAndPacking(void) {
    CGRect screens[]={CGRectMake(0,0,428,926),CGRectMake(0,0,926,428)};
    for(unsigned s=0;s<2;s++) {
        CGRect screen=screens[s],start=CGRectMake(40,50,280,200);
        for(unsigned corner=0;corner<4;corner++) for(int x=-1000;x<=1000;x+=25) for(int y=-1000;y<=1000;y+=25) {
            CGRect r=ZNSResizeFreeWindow(start,CGPointMake(x,y),corner,screen);
            assert(CGRectContainsRect(screen,r)); assert(r.size.width>0 && r.size.height>0);
            assert(fabs(((corner&1)?CGRectGetMinX(r):CGRectGetMaxX(r))-((corner&1)?CGRectGetMinX(start):CGRectGetMaxX(start)))<1e-7);
            assert(fabs(((corner&2)?CGRectGetMinY(r):CGRectGetMaxY(r))-((corner&2)?CGRectGetMinY(start):CGRectGetMaxY(start)))<1e-7);
            CGRect moved=ZNSConstrainIcon(CGRectOffset(start,x,y),screen);
            assert(CGRectContainsRect(screen,moved)); assert(CGSizeEqualToSize(moved.size,start.size));
        }
        CGRect changed=ZNSResizeFreeWindow(start,CGPointMake(40,0),3,screen);
        assert(changed.size.width==320 && changed.size.height==200);
        CGRect occupied[32]; unsigned count=0;
        for(unsigned i=0;i<8;i++) {
            CGRect target;
            assert(ZNSFindParkedFrame(CGRectMake(0,0,56,56),screen,occupied,count,i%2,0,&target));
            assert(CGRectContainsRect(screen,target)); assert(ZNSFrameClear(target,occupied,count));
            occupied[count++]=target;
        }
        CGRect freeFrame=CGRectMake(CGRectGetMaxX(screen)-150,CGRectGetMaxY(screen)-100,150,100),found;
        if(ZNSFindParkedFrame(freeFrame,screen,occupied,count,0,1,&found)) {
            assert(CGRectContainsRect(screen,found)); assert(ZNSFrameClear(found,occupied,count));
        }
        assert(!ZNSFindParkedFrame(CGRectMake(0,0,2000,2000),screen,occupied,count,0,0,&found));
        assert(!ZNSFindParkedFrame(CGRectMake(0,0,30,30),CGRectMake(0,0,56,56),occupied,1,0,0,&found));
    }
    puts("PASS: 52488 free-resize/edge-drag cases; packing and collision rejection.");
}
static void checkIconRows(void) {
    CGRect safe=CGRectMake(6,54,248,400),occupied[12];
    for(unsigned side=0;side<2;side++) {
        occupied[0]=CGRectMake(6,54,248,134);
        CGRect desired=CGRectMake(100,300,56,56); // A clear old origin never wins.
        for(unsigned i=0;i<8;i++) {
            CGRect target;
            assert(ZNSFindIconFrame(desired,safe,occupied,i+1,1,side,&target));
            assert(CGRectContainsRect(safe,target)); assert(ZNSFrameClear(target,occupied,i+1));
            assert(target.origin.y==194+(i%4)*59);
            assert(target.origin.x==(side?198-(i/4)*62:6+(i/4)*62));
            occupied[i+1]=target;
        }
        // A lower thumbnail blocks the edge column, but must not become the
        // anchor of the next column. Reverse input order to catch last-item bias.
        CGRect edge=CGRectMake(side?198:6,54,56,50);
        CGRect low=CGRectMake(side?198:6,172,56,282);
        CGRect result;
        for(unsigned reverse=0;reverse<2;reverse++) {
            occupied[reverse]=edge; occupied[!reverse]=low;
            assert(ZNSFindIconFrame(desired,safe,occupied,2,2,side,&result));
            assert(result.origin.x==(side?198:6) && result.origin.y==110);
            occupied[2]=result;
            assert(ZNSFindIconFrame(desired,safe,occupied,3,2,side,&result));
            assert(result.origin.x==(side?136:68) && result.origin.y==110);
            assert(ZNSFrameClear(result,occupied,3));
        }
        // An opposite-side thumbnail must not move this side's starting Y.
        occupied[0]=CGRectMake(side?6:198,54,56,134);
        assert(ZNSFindIconFrame(desired,safe,occupied,1,1,side,&result));
        assert(result.origin.x==(side?198:6) && result.origin.y==54);
        // Non-thumbnail obstruction is skipped by its exact lower edge + 3.
        occupied[0]=CGRectMake(side?198:6,54,56,75);
        assert(ZNSFindIconFrame(desired,safe,occupied,1,0,side,&result));
        assert(result.origin.x==(side?198:6) && result.origin.y==132);
        assert(ZNSFindIconFrame(desired,safe,NULL,0,0,side,&result));
        assert(result.origin.x==(side?198:6) && result.origin.y==54);
    }
    CGRect result;
    assert(!ZNSFindIconFrame(CGRectMake(0,0,500,500),safe,occupied,1,1,0,&result));
    CGRect landscape=CGRectMake(54,54,818,348);
    CGRect portraitTier=ZNSThumbnailTierFrame(CGSizeMake(428,926),CGRectMake(6,54,416,824),0,2);
    assert(portraitTier.size.height>landscape.size.height);
    assert(!ZNSFindParkedFrame(portraitTier,landscape,NULL,0,0,0,&result));
    CGRect gridBounds=CGRectMake(0,0,124,124),grid[64];
    for(unsigned count=1;count<=40;count++) for(unsigned i=0;i<count;i++) {
        grid[i]=ZNSIconGridFrame(gridBounds,count,i);
        assert(CGRectContainsRect(gridBounds,grid[i]));
        for(unsigned j=0;j<i;j++) assert(!CGRectIntersectsRect(grid[i],grid[j]));
    }
    for(unsigned i=0;i<4;i++) {
        CGRect r=ZNSIconGridFrame(gridBounds,4,i);
        assert(fabs(r.origin.x-(i/2)*(r.size.width+6))<1e-7 && fabs(r.origin.y-(i%2)*(r.size.height+3))<1e-7);
    }
    // No thumbnails: fill the whole edge column before the next column.
    for(unsigned side=0;side<2;side++) for(unsigned i=0;i<4;i++) {
        CGRect r;
        assert(ZNSFindIconFrame(CGRectMake(34,34,56,56),gridBounds,grid,i,0,side,&r));
        assert(r.origin.x==(side?68-(i/2)*62:(i/2)*62));
        assert(r.origin.y==(i%2)*59);
        grid[i]=r;
    }
    CGRect centered=CGRectMake(34,34,56,56);
    assert(!ZNSFindIconFrame(CGRectMake(0,0,56,56),gridBounds,&centered,1,0,0,&result));
    puts("PASS: edge-first icon columns, exact obstacle gaps, topmost same-side anchors, order-independent wrapping and packing rejection.");
}
static void checkMainModes(void) {
    // Landscape corner at a screen edge must still grow by shifting inward.
    CGRect movement=CGRectMake(54,0,872,428);
    for(unsigned corner=0;corner<4;corner++) {
        CGRect start=CGRectMake((corner&1)?CGRectGetMaxX(movement)-300:movement.origin.x,
                                (corner&2)?CGRectGetMaxY(movement)-200:movement.origin.y,300,200);
        CGPoint delta=CGPointMake((corner&1)?90:-90,(corner&2)?60:-60);
        CGRect grown=ZNSResizeMainWindow(start,delta,corner,movement,0);
        assert(grown.size.width>start.size.width && grown.size.height>start.size.height);
        assert(CGRectContainsRect(movement,grown));
        assert(fabs((grown.size.width-14)/(grown.size.height-54)-286.0/146.0)<1e-7);
    }
    CGSize screen=CGSizeMake(428,926);
    CGRect boundsList[]={CGRectMake(0,0,428,926),CGRectMake(0,0,926,428),CGRectMake(0,0,667,375)};
    unsigned cases=0;
    for(unsigned b=0;b<3;b++) for(unsigned landscape=0;landscape<2;landscape++) {
        CGRect bounds=boundsList[b]; unsigned side=bounds.size.width>bounds.size.height && !landscape;
        CGRect start=ZNSDefaultMainWindow(bounds,screen,landscape);
        CGSize chrome=ZNSMainChrome(side),canvas=ZNSScreenCanvas(screen,landscape);
        assert(CGRectContainsRect(bounds,start));
        assert(fabs(CGRectGetMidX(start)-CGRectGetMidX(bounds))<1e-7);
        assert(fabs(CGRectGetMidY(start)-CGRectGetMidY(bounds))<1e-7);
        if(side) { assert(fabs(start.size.height-bounds.size.height)<1e-7); assert(start.origin.y==bounds.origin.y); }
        for(unsigned corner=0;corner<4;corner++) for(int x=-1200;x<=1200;x+=60) for(int y=-1200;y<=1200;y+=60) {
            CGRect r=ZNSResizeMainWindow(start,CGPointMake(x,y),corner,bounds,side); cases++;
            assert(CGRectGetMinX(r)>=-1e-7 && CGRectGetMinY(r)>=-1e-7);
            assert(CGRectGetMaxX(r)<=CGRectGetMaxX(bounds)+1e-7 && CGRectGetMaxY(r)<=CGRectGetMaxY(bounds)+1e-7);
            assert(fabs((r.size.width-chrome.width)/(r.size.height-chrome.height)-canvas.width/canvas.height)<1e-7);
            if(bounds.size.width<=bounds.size.height) {
                assert(fabs(((corner&1)?CGRectGetMinX(r):CGRectGetMaxX(r))-((corner&1)?CGRectGetMinX(start):CGRectGetMaxX(start)))<1e-7);
                assert(fabs(((corner&2)?CGRectGetMinY(r):CGRectGetMaxY(r))-((corner&2)?CGRectGetMinY(start):CGRectGetMaxY(start)))<1e-7);
            }
        }
    }
    for(unsigned landscape=0;landscape<2;landscape++) {
        assert(ZNSThumbnailNextTier(0,landscape)==1);
        assert(ZNSThumbnailNextTier(1,landscape)==(landscape?2:1));
        assert(ZNSThumbnailNextTier(2,landscape)==(landscape?2:1));
        for(unsigned right=0;right<2;right++) {
            assert(ZNSThumbnailReturnsFirst(1,right,right));
            assert(!ZNSThumbnailReturnsFirst(1,right,!right));
            assert(!ZNSThumbnailReturnsFirst(0,right,right));
        }
    }
    CGRect edgeBodies[]={CGRectMake(0,0,180,428),CGRectMake(746,0,180,428),CGRectMake(100,100,180,200)};
    for(unsigned b=0;b<3;b++) for(unsigned corner=0;corner<4;corner++) {
        CGRect handle=ZNSCornerHandle(edgeBodies[b],CGRectMake(0,0,926,428),corner);
        assert(CGRectContainsRect(CGRectMake(0,0,926,428),handle));
        assert(!CGRectIntersectsRect(handle,CGRectInset(edgeBodies[b],4,4)));
    }
    // Visual chrome tracks content scale in either orientation; repeated layout
    // uses the default reference, never the previous already-scaled decoration.
    for(unsigned landscape=0;landscape<2;landscape++) {
        CGRect safe=CGRectMake(0,40,428,850);
        CGRect reference=ZNSMainReferenceWindow(safe,CGSizeMake(428,926),landscape);
        CGRect initial=ZNSDefaultMainWindow(safe,CGSizeMake(428,926),landscape);
        assert(fabs(ZNSMainDecorationScale(initial,reference)-1)<1e-7);
        assert(fabs(CGRectGetMidX(initial)-CGRectGetMidX(safe))<1e-7);
        assert(fabs(CGRectGetMidY(initial)-CGRectGetMidY(safe))<1e-7);
        CGRect wide=CGRectMake(0,20,926,388);
        CGRect wideDefault=ZNSDefaultMainWindow(wide,CGSizeMake(428,926),landscape);
        CGRect wideReference=ZNSMainReferenceWindow(wide,CGSizeMake(428,926),landscape);
        assert(CGRectContainsRect(wide,wideDefault));
        CGFloat expectedWidth=landscape?(wideReference.size.width-14)*1.10+14:wideReference.size.width;
        assert(fabs(wideDefault.size.width-expectedWidth)<1e-7);
        CGSize content=ZNSMainContent(reference).size;
        for(unsigned step=1;step<=10;step++) {
            CGFloat scale=step/10.0;
            CGRect resized=CGRectMake(0,0,content.width*scale+14,content.height*scale+54);
            assert(fabs(ZNSMainDecorationScale(resized,reference)-scale)<1e-7);
            assert(fabs(ZNSMainDecorationScale(CGRectOffset(resized,30,50),reference)-scale)<1e-7);
        }
        CGRect large=CGRectMake(0,0,content.width*1.2+14,content.height*1.2+54);
        assert(ZNSMainDecorationScale(large,reference)==1);
        assert(ZNSMainDecorationScale(reference,CGRectZero)==1);
    }
    unsigned chromeCases=0;
    for(int width=94;width<=926;width+=8) for(int height=144;height<=926;height+=17) for(unsigned expanded=0;expanded<2;expanded++) {
        CGRect bounds=CGRectMake(0,0,width,height);
        CGRect body=ZNSMainBody(bounds),content=ZNSMainContent(bounds);
        CGRect tools=ZNSMainToolsFrame(bounds,expanded);
        CGFloat toolScale=ZNSMainToolScale(tools.size.width,expanded);
        assert(toolScale<=(expanded?0.63:0.5));
        assert(tools.size.width<=(expanded?94.5:58));
        if(width>=155 && expanded) assert(fabs(toolScale-0.9*0.7)<1e-7 && tools.size.width==94.5);
        CGRect top=ZNSMainBarFrame(bounds,expanded,0),bottom=ZNSMainBarFrame(bounds,expanded,1);
        assert(CGRectContainsRect(bounds,body) && CGRectContainsRect(body,content));
        assert(CGRectContainsRect(bounds,tools));
        assert(CGRectContainsRect(bounds,top) && CGRectContainsRect(bounds,bottom));
        assert(fabs(CGRectGetMinY(body)-CGRectGetMaxY(tools)-(expanded?6:2))<1e-7);
        assert(fabs(CGRectGetMinY(body)-CGRectGetMidY(top)-4)<1e-7);
        assert(fabs(CGRectGetMidY(bottom)-CGRectGetMaxY(body)-4)<1e-7);
        assert(ZNSBarThickness()==3);
        assert(top.size.width<=68 && bottom.size.width<=68);
        // Both lines use the same signed 1.5pt travel and stay outside the body.
        for(int step=-1;step<=1;step++) {
            CGFloat gap=4+step*1.5-ZNSBarThickness()/2;
            assert(gap>=1 && gap<=4);
        }
        assert(!CGRectIntersectsRect(top,tools));
        assert(!CGRectIntersectsRect(top,content) && !CGRectIntersectsRect(bottom,content));
        assert(content.size.width==width-14 && content.size.height==height-54);
        CGRect hitScreen=CGRectInset(bounds,-40,-40);
        CGRect topHit=ZNSMainBarHitFrame(bounds,hitScreen,expanded,0),bottomHit=ZNSMainBarHitFrame(bounds,hitScreen,expanded,1);
        CGRect clippedTop=ZNSMainBarHitFrame(bounds,bounds,expanded,0),clippedBottom=ZNSMainBarHitFrame(bounds,bounds,expanded,1);
        assert(CGRectContainsRect(bounds,clippedTop) && CGRectContainsRect(bounds,clippedBottom));
        assert(CGRectEqualToRect(clippedTop,CGRectIntersection(topHit,bounds)));
        assert(CGRectEqualToRect(clippedBottom,CGRectIntersection(bottomHit,bounds)));
        assert(CGRectContainsRect(topHit,top) && CGRectContainsRect(bottomHit,bottom));
        assert(topHit.size.height>top.size.height && bottomHit.size.height>bottom.size.height);
        assert(!CGRectIntersectsRect(topHit,content) && !CGRectIntersectsRect(bottomHit,content));
        assert(!CGRectIntersectsRect(topHit,tools) && !CGRectIntersectsRect(bottomHit,tools));
        assert(CGRectGetMinY(topHit)<CGRectGetMinY(top));
        assert(CGRectGetMaxY(bottomHit)>CGRectGetMaxY(bounds));
        for(unsigned corner=0;corner<4;corner++) {
            CGRect handle=ZNSMainCornerHandle(bounds,bounds,corner,expanded);
            CGPoint center=ZNSCornerCenter(body,corner);
            CGRect dot=CGRectMake(center.x-3,center.y-3,6,6);
            assert(CGRectContainsRect(bounds,handle) && CGRectContainsRect(bounds,dot));
            assert(CGRectContainsRect(handle,dot));
            assert(!CGRectIntersectsRect(handle,content));
            assert(!CGRectIntersectsRect(handle,tools));
            assert(!CGRectIntersectsRect(handle,top) && !CGRectIntersectsRect(handle,bottom));
            assert(!CGRectIntersectsRect(handle,topHit) && !CGRectIntersectsRect(handle,bottomHit));
            assert(handle.size.height>8);
            CGRect outerScreen=CGRectInset(bounds,-40,-40);
            CGRect outer=ZNSMainCornerHandle(bounds,outerScreen,corner,expanded);
            assert(CGRectContainsRect(outerScreen,outer) && CGRectContainsRect(outer,dot));
            assert(outer.size.height==28);
            assert(!CGRectIntersectsRect(outer,content) && !CGRectIntersectsRect(outer,tools));
            assert(!CGRectIntersectsRect(outer,topHit) && !CGRectIntersectsRect(outer,bottomHit));
            assert(fabs(center.x-((corner&1)?CGRectGetMaxX(body):body.origin.x))<1e-7);
            assert(fabs(center.y-((corner&2)?CGRectGetMaxY(body):body.origin.y))<1e-7);
            chromeCases++;
        }
    }
    printf("PASS: %u compact chrome cases; corner-centered dots, App-safe hit strips, toolbar gaps and top/bottom bars.\n",chromeCases);
    assert(ZNSFullscreenProgress(10)==0);
    assert(ZNSFullscreenProgress(-180)==1);
    assert(!ZNSShouldEnterFullscreen(-98,0));
    assert(ZNSShouldEnterFullscreen(-100,0));
    assert(!ZNSShouldEnterFullscreen(-44,-900));
    assert(ZNSShouldEnterFullscreen(-45,-700));
    for(unsigned orientation=0;orientation<2;orientation++) {
        CGRect screenBounds=orientation?CGRectMake(0,0,926,428):CGRectMake(0,0,428,926);
        for(unsigned app=0;app<2;app++) {
            CGRect initial=ZNSDefaultMainWindow(screenBounds,CGSizeMake(428,926),app);
            CGRect local=ZNSMainContent(CGRectMake(0,0,initial.size.width,initial.size.height));
            assert(CGAffineTransformIsIdentity(ZNSFullscreenTransform(initial,screenBounds,0)));
            CGFloat previous=1;
            for(unsigned step=0;step<=10;step++) {
                CGAffineTransform t=ZNSFullscreenTransform(initial,screenBounds,step/10.0);
                assert(t.a==t.d && t.b==0 && t.c==0 && t.a>=previous); previous=t.a;
            }
            CGAffineTransform t=ZNSFullscreenTransform(initial,screenBounds,1);
            CGRect centred=CGRectOffset(local,-initial.size.width/2,-initial.size.height/2);
            CGRect final=CGRectApplyAffineTransform(centred,t);
            final=CGRectOffset(final,CGRectGetMidX(initial),CGRectGetMidY(initial));
            assert(fabs(CGRectGetMidX(final)-CGRectGetMidX(screenBounds))<1e-7);
            assert(fabs(CGRectGetMidY(final)-CGRectGetMidY(screenBounds))<1e-7);
            assert(final.size.width<=screenBounds.size.width+1e-7 && final.size.height<=screenBounds.size.height+1e-7);
        }
    }
    assert(fabs(ZNSCornerArcRadius()/sqrt(2.0)-16)<1e-7);
    assert(ZNSDismissProgress(10,500)==0);
    assert(ZNSDismissProgress(-2000,500)==1);
    assert(!ZNSShouldDismiss(-20,-1200,500));
    assert(!ZNSShouldDismiss(-60,0,500));
    assert(ZNSShouldDismiss(-150,0,500));
    assert(ZNSShouldDismiss(-60,-800,500));
    assert(!ZNSShouldDismiss(60,-800,500));
    // Returning portrait is derived from the current bounds, not the tiny
    // previous landscape footprint; restoring again is deterministic.
    CGRect portrait=ZNSDefaultMainWindow(boundsList[0],screen,0);
    CGRect landscape=ZNSDefaultMainWindow(boundsList[1],screen,0);
    assert(portrait.size.height>landscape.size.height);
    assert(CGRectEqualToRect(portrait,ZNSDefaultMainWindow(boundsList[0],screen,0)));
    printf("PASS: %u fixed-ratio portrait/landscape corner cases; full-height footprint with reserved bars, centering, portrait reset and dismissal thresholds.\n",cases);
}
static void checkHostProjection(void) {
    unsigned cases=0;
    for(unsigned turn=0;turn<4;turn++) for(unsigned zoom=1;zoom<=3;zoom++)
    for(unsigned ax=0;ax<3;ax++) for(unsigned ay=0;ay<3;ay++) {
        CGAffineTransform t=CGAffineTransformMakeRotation(turn*M_PI_2);
        t=CGAffineTransformScale(t,zoom*0.5,zoom*0.5); t.tx=23; t.ty=-31;
        CGPoint anchor=CGPointMake(ax*0.5,ay*0.5),position;
        CGSize canvas=CGSizeMake(926,428),local;
        assert(ZNSHostGeometryForCanvas(canvas,t,anchor,&local,&position));
        CGRect projected=CGRectApplyAffineTransform(CGRectMake(-anchor.x*local.width,-anchor.y*local.height,local.width,local.height),t);
        projected=CGRectOffset(projected,position.x,position.y);
        assert(fabs(projected.origin.x)<1e-7 && fabs(projected.origin.y)<1e-7);
        assert(fabs(projected.size.width-canvas.width)<1e-7 && fabs(projected.size.height-canvas.height)<1e-7);
        cases++;
    }
    CGSize local; CGPoint p;
    assert(!ZNSHostGeometryForCanvas(CGSizeMake(926,428),CGAffineTransformMakeRotation(M_PI_4),CGPointMake(.5,.5),&local,&p));
    assert(!ZNSHostGeometryForCanvas(CGSizeZero,CGAffineTransformIdentity,CGPointZero,&local,&p));
    assert(!ZNSHostGeometryForCanvas(CGSizeMake(926,428),CGAffineTransformMakeScale(0,0),CGPointZero,&local,&p));
    printf("PASS: %u host projection cases with quarter-turns, scales, translation and anchors; invalid/intermediate transforms rejected.\n",cases);
}
static void checkPortraitEdgeWidth(void) {
    CGSize screens[]={{428,926},{390,844},{375,667},{320,568},{1024,1366}};
    for(unsigned i=0;i<5;i++) {
        CGRect b=CGRectMake(19,27,screens[i].width,screens[i].height);
        CGRect r=ZNSDefaultMainWindow(b,screens[i],1);
        CGRect content=ZNSMainContent(r);
        assert(fabs(CGRectGetMinX(r)-CGRectGetMinX(b))<1e-7);
        assert(fabs(CGRectGetMaxX(r)-CGRectGetMaxX(b))<1e-7);
        assert(fabs(CGRectGetMidY(r)-CGRectGetMidY(b))<1e-7);
        assert(fabs(content.size.width/content.size.height-screens[i].height/screens[i].width)<1e-7);
        assert(CGRectContainsRect(b,r));
        assert(CGRectEqualToRect(ZNSFitMainWindow(r,b,0),r));
        CGRect portrait=ZNSDefaultMainWindow(b,screens[i],0);
        assert(portrait.size.width<r.size.width);
    }
    puts("PASS: 5 portrait-device landscape windows fill both edges, retain content ratio and restore deterministically.");
}
int main(void) {
    CGRect half=ZNSThumbnailTierFrame(CGSizeMake(926,428),CGRectMake(0,0,926,428),0,2);
    assert(fabs(half.size.width*half.size.height/(926.0*428.0)-0.5)<1e-7);
    CGRect mainLandscape=ZNSDefaultMainWindow(CGRectMake(54,20,818,388),CGSizeMake(428,926),1);
    assert(fabs(mainLandscape.size.width-((926*0.60-14)*1.10+14))<1e-7);
    assert(fabs(CGRectGetMidX(mainLandscape)-463)<1e-7);
    assert(fabs(ZNSParkedIconSize()-60.48*1.06)<1e-7);
    CGRect obstacle=CGRectMake(0,0,82,126),next;
    assert(ZNSFindParkedFrame(obstacle,CGRectMake(0,0,428,926),&obstacle,1,0,0,&next));
    assert(fabs(next.origin.y-129)<1e-7);
    CGRect mixed=CGRectMake(0,0,ZNSParkedIconSize(),ZNSParkedIconSize());
    assert(ZNSFindIconFrame(mixed,CGRectMake(0,0,428,926),&obstacle,1,1,0,&next));
    assert(fabs(next.origin.y-132)<1e-7);
    checkHostProjection();
    checkPortraitEdgeWidth();
    checkMainModes();
    checkIconRows();
    checkFreeAndPacking();
    CGRect safe=CGRectMake(6,54,416,824);
    CGRect start=CGRectMake(60,140,280,500);
    check(start,safe);
    check(CGRectMake(100,50,500,280),CGRectMake(54,6,824,390));
    check(CGRectMake(6,54,220,180),safe);
    check(CGRectMake(8,8,100,120),CGRectMake(6,6,140,160));
    assert(CGRectContainsRect(safe,ZNSConstrain(CGRectMake(-500,-500,4000,4000),safe)));
    for (int x=-2000;x<=2000;x+=100) for (int y=-2000;y<=2000;y+=100) {
        CGRect icon=ZNSConstrainIcon(CGRectMake(x,y,56,56),safe);
        assert(icon.size.width==56 && icon.size.height==56);
        assert(CGRectContainsRect(safe,icon));
    }
    CGSize screens[]={CGSizeMake(428,926),CGSizeMake(375,667),CGSizeMake(1024,1366)};
    for (unsigned i=0;i<3;i++) {
        checkCanvas(safe,screens[i]);
        checkCanvas(CGRectMake(54,6,824,390),screens[i]);
        checkCanvas(CGRectMake(6,6,140,160),screens[i]);
        for(unsigned landscape=0;landscape<2;landscape++) {
            CGSize canvas=ZNSScreenCanvas(screens[i],landscape);
            checkThumbnailTiers(canvas,safe);
            checkThumbnailTiers(canvas,CGRectMake(54,6,824,390));
            checkThumbnailTiers(canvas,CGRectMake(6,6,140,160));
        }
        assert(CGSizeEqualToSize(ZNSScreenCanvas(screens[i],1),CGSizeMake(screens[i].height,screens[i].width)));
        assert(CGSizeEqualToSize(ZNSScreenCanvas(CGSizeMake(screens[i].height,screens[i].width),0),screens[i]));
    }
    assert(CGSizeEqualToSize(ZNSScreenCanvas(CGSizeZero,0),CGSizeZero));
    assert(CGRectIsEmpty(ZNSThumbnailFrame(CGSizeZero,safe)));
    assert(CGRectIsEmpty(ZNSThumbnailFrame(CGSizeMake(NAN,100),safe)));
    assert(ZNSThumbnailSwipeDocks(0,0));
    assert(!ZNSThumbnailSwipeDocks(0,1));
    assert(!ZNSThumbnailSwipeDocks(1,0));
    assert(ZNSThumbnailSwipeDocks(1,1));
    checkHorizontalSwipes();
    checkFlicks();
    CGRect landscapeBase=ZNSThumbnailTierFrame(CGSizeMake(926,428),safe,0,0);
    assert(fabs(landscapeBase.size.width-98.4)<1e-7);
    assert(fabs(ZNSThumbnailTierFrame(CGSizeMake(926,428),safe,0,1).size.width-295.2)<1e-7);
    assert(fabs(ZNSThumbnailTierFrame(CGSizeMake(926,428),safe,0,2).size.width-416)<1e-7);
    assert(isinf(ZNSThumbnailTierScale(2)));
    CGRect full=ZNSThumbnailTierFrame(CGSizeMake(926,428),CGRectMake(0,0,428,926),0,2);
    assert(fabs(full.size.width-428)<1e-7 && fabs(full.origin.x)<1e-7);
    CGRect fullContent=ZNSThumbnailContentFrame(CGSizeMake(926,428),full,2);
    assert(CGRectEqualToRect(fullContent,full));
    assert(fabs(fullContent.size.width/fullContent.size.height-926.0/428.0)<1e-7);
    // A wide display is not limited to the former 108*4.2 footprint.
    CGRect tablet=ZNSThumbnailTierFrame(CGSizeMake(1194,834),CGRectMake(0,0,834,1194),1,2);
    assert(fabs(tablet.size.width-834)<1e-7 && fabs(tablet.origin.x)<1e-7);
    CGRect shortScreen=CGRectMake(0,0,926,428);
    assert(CGRectContainsRect(shortScreen,ZNSThumbnailTierFrame(CGSizeMake(926,428),shortScreen,0,2)));
    puts("PASS: ratio-resize, tier-drag, enlarged scales and deliberate-flick tests.");
    return 0;
}
