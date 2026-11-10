#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "ZNSScreenEffectPolicy.h"
#include "ZNSWindowAnimationPolicy.h"
#include "ZNSExitShatterLifecycle.h"
#include "ZNSScreenSettingsFixture.h"
typedef struct { int made,fail,cleared,closed;ZNSExitStyle selected; } Host;
static bool tile(void *v,unsigned i) { Host *h=v;if((int)i==h->fail)return false;h->made++;return true; }
static void discard(void *v) { Host *h=v;h->made=0;h->cleared++; }
static bool present(void *v,ZNSExitStyle s) { ((Host *)v)->selected=s;return true; }
static void closeHost(void *v) { ((Host *)v)->closed++; }
static void fallback(void *v) { (void)v;assert(false); }
int main(void) {
 assert(ZNSScreenCount==18 && ZNSScreenMaxTiles==64 && ZNSScreenFrames==7 && ZNSScreenDuration==.64);
 assert(!ZNSScreenTiles(-1) && !ZNSScreenTiles(18));
 assert(ZNSParseExitStyle("unknown")==ZNSExitShatter && ZNSParseEntryStyle("unknown")==ZNSEntrySoft);
 assert(ZNSResolveExitStyle(ZNSExitNone,true)==ZNSExitNone && ZNSResolveEntryStyle(ZNSEntryNone,true)==ZNSEntryNone);
 double fingerprints[18]={0};
 for(int e=0;e<18;e++) {
  assert(ZNSScreenIndex(znsScreenKeys[e])==e);
  ZNSExitStyle ex=ZNSParseExitStyle(znsScreenKeys[e]);ZNSEntryStyle en=ZNSParseEntryStyle(znsScreenKeys[e]);
  assert(ex==(ZNSExitStyle)(ZNSExitScreenFirst+e) && en==(ZNSEntryStyle)(ZNSEntryScreenFirst+e));
  assert(ZNSResolveExitStyle(ex,false)==ex && ZNSResolveEntryStyle(en,false)==en);
  assert(ZNSResolveExitStyle(ex,true)==ZNSExitFade && ZNSResolveEntryStyle(en,true)==ZNSEntryFade);
  assert(ZNSExitMotionPlan(ex,300,600).duration==ZNSScreenDuration && ZNSEntryMotionPlan(en).duration==ZNSScreenDuration);
  Host h={.fail=-1};ZNSExitDispatchOps ops={present,closeHost,fallback};ZNSDispatchExit(&h,ops,ex,false);assert(h.closed==1 && h.selected==ex);
  ZNSOpeningLifetime life={0};uint64_t token=ZNSOpeningReady(&life,true,true,true,en);assert(token && life.active);
  assert(!ZNSOpeningReady(&life,true,true,true,en));assert(!ZNSOpeningFinish(&life,token+1));
  ZNSOpeningCancel(&life);assert(!ZNSOpeningFinish(&life,token));assert(!ZNSOpeningReady(&life,true,true,true,en));
  unsigned n=ZNSScreenTiles(e);assert(n>=1 && n<=64);
  ZNSScreenBuildOps build={tile,discard};assert(ZNSScreenBuild(&h,e,build) && h.made==(int)n && !h.cleared);
  for(unsigned fail=0;fail<n;fail++) {h=(Host){.fail=(int)fail};assert(!ZNSScreenBuild(&h,e,build));assert(!h.made && h.cleared==1);}
  for(int size=0;size<3;size++) {
   double w=size==0?300:size==1?600:1,hgt=size==0?600:size==1?300:1,area=0;
   ZNSScreenRect rects[64];
   for(unsigned i=0;i<n;i++) {
    assert(ZNSScreenRectAt(e,i,w,hgt,&rects[i]));ZNSScreenRect r=rects[i];
    assert(r.w>0 && r.h>0 && r.x>=0 && r.y>=0 && r.x+r.w<=w+.001 && r.y+r.h<=hgt+.001);area+=r.w*r.h;
    for(unsigned j=0;j<i;j++) {ZNSScreenRect b=rects[j];double ow=fmin(r.x+r.w,b.x+b.w)-fmax(r.x,b.x),oh=fmin(r.y+r.h,b.y+b.h)-fmax(r.y,b.y);assert(ow<=.0001 || oh<=.0001);}
    for(unsigned entry=0;entry<2;entry++) for(unsigned f=0;f<ZNSScreenFrames;f++) {
     double t=(double)f/(ZNSScreenFrames-1);ZNSScreenPose p=ZNSScreenPoseAt(e,i,w,hgt,t,entry);
     assert(isfinite(p.dx) && isfinite(p.dy) && isfinite(p.rz) && isfinite(p.ry));
     assert(p.sx>0 && p.sx<=1.5 && p.sy>0 && p.sy<=1.5 && p.alpha>=0 && p.alpha<=1);
     assert(fabs(p.dx)<=w && fabs(p.dy)<=hgt && fabs(p.rz)<=3.01 && fabs(p.ry)<=1.54);
     if((entry && f==6) || (!entry && f==0)) assert(p.sx==1 && p.sy==1 && p.dx==0 && p.dy==0 && p.rz==0 && p.ry==0 && p.alpha==1);
     if((entry && f==0) || (!entry && f==6)) assert(p.alpha==0);
     fingerprints[e]+=(p.sx*3+p.sy*7+p.dx*.13+p.dy*.17+p.rz*11+p.ry*19+p.alpha*23)*(i+1)*(f+1);
    }
   }
   assert(fabs(area-w*hgt)<.001);ZNSScreenRect bad;
   assert(!ZNSScreenRectAt(e,n,w,hgt,&bad) && !ZNSScreenRectAt(e,0,NAN,hgt,&bad) && !ZNSScreenRectAt(e,0,w,0,&bad));
  }
 }
 for(int i=0;i<18;i++)for(int j=0;j<i;j++)assert(fabs(fingerprints[i]-fingerprints[j])>.01);
 // Direction/axis semantics are checked independently of distinct fingerprints.
 assert(ZNSScreenPoseAt(7,0,300,600,.5,false).dy<0);
 assert(ZNSScreenPoseAt(8,0,300,600,.5,false).dx>0);
 assert(ZNSScreenPoseAt(9,0,300,600,.5,false).dy>0);
 assert(ZNSScreenPoseAt(4,0,300,600,.5,false).sy<.11);
 assert(ZNSScreenPoseAt(5,0,300,600,.5,false).ry!=0);
 assert(ZNSScreenPoseAt(17,0,300,600,.5,false).sx==1);
 double pixels=0;assert(!ZNSShatterSourcePixels(3000,3000,3,&pixels));
 assert(ZNSShatterSourcePixels(300,600,3,&pixels));assert(ZNSShatterReservePixels(&pixels,300*600*9));
 puts("PASS 18 actual picker/parser/dispatch plans; all tile failures; finite disjoint complete geometry; distinct 7-frame poses; both entry/exit endpoints; stale/cancel/one-shot opening; pixel budget");
 return 0;
}
