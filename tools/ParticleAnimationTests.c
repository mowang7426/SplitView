#include <assert.h>
#include <stdio.h>
#include "ZNSParticlePolicy.h"
#include "ZNSWindowAnimationPolicy.h"
typedef struct { unsigned crops,live,clears,disposed,scheduled; int fail; bool capture; ZNSShatterLifetime life; } Host;
static bool crop(void *c,unsigned i) { Host *h=c;h->crops++;if((int)i==h->fail)return false;h->live++;return true; }
static void clear(void *c) { Host *h=c;h->clears++;h->live=0; }
static bool capture(void *c) { return ((Host *)c)->capture; }
static void dispose(void *c) { Host *h=c;h->disposed++;clear(c); }
static void play(void *c,bool scatter,uint64_t token) { (void)c;(void)scatter;(void)token; }
static void schedule(void *c,bool scatter,uint64_t token) { (void)scatter;(void)token;((Host *)c)->scheduled++; }
static const ZNSShatterOperations ops={capture,crop,clear,play,dispose,schedule};
static void geometry(void) {
    assert(ZNSParticleCount==120 && ZNSParticleCount<=128);
    assert(ZNSParticleDuration>=.5 && ZNSParticleDuration+ZNSParticleMaxDelay>=.6 && ZNSParticleDuration+ZNSParticleMaxDelay<=.9);
    const double sizes[][3]={{180,320,3},{320,180,3},{390,700,2},{2,2,1},{800,600,2},{1000,600,2}};
    for(unsigned n=0;n<sizeof(sizes)/sizeof(sizes[0]);n++) {
        double w=sizes[n][0],h=sizes[n][1],s=sizes[n][2],pixels=w*h*s*s,area=0; double first=-1;bool varied=false;
        for(unsigned i=0;i<ZNSParticleCount;i++) {
            ZNSParticle p;assert(ZNSParticlePlan(w,h,s,i,&p));
            assert(isfinite(p.x)&&isfinite(p.y)&&isfinite(p.w)&&isfinite(p.h)&&isfinite(p.dx)&&isfinite(p.dy)&&isfinite(p.scale)&&isfinite(p.angle)&&isfinite(p.delay));
            assert(p.x>=0 && p.y>=0 && p.w>0 && p.h>0 && p.x+p.w<=w+1e-8 && p.y+p.h<=h+1e-8);
            assert(p.dx>=w*.12 && p.dx<=w*.42 && fabs(p.dy)<=h*.20);
            assert(p.scale>=.08 && p.scale<=.28 && fabs(p.angle)<=.45);
            assert(p.delay>=0 && p.delay<=ZNSParticleMaxDelay);
            if(first<0)first=p.delay;else if(first!=p.delay)varied=true;
            if(i%ZNSParticleColumns) { ZNSParticle prev;assert(ZNSParticlePlan(w,h,s,i-1,&prev));assert(fabs(prev.x+prev.w-p.x)<1e-8); }
            if(i>=ZNSParticleColumns) { ZNSParticle prev;assert(ZNSParticlePlan(w,h,s,i-ZNSParticleColumns,&prev));assert(fabs(prev.y+prev.h-p.y)<1e-8); }
            area+=p.w*p.h;assert(ZNSShatterReservePixels(&pixels,p.w*p.h*s*s));
        }
        assert(varied && fabs(area-w*h)<1e-5 && fabs(pixels-2*w*h*s*s)<1e-4);
        assert(pixels<=2*ZNSShatterPixelBudget+1e-6);
    }
    ZNSParticle p;
    assert(!ZNSParticlePlan(NAN,300,3,0,&p));assert(!ZNSParticlePlan(300,INFINITY,3,0,&p));
    assert(!ZNSParticlePlan(300,300,0,0,&p));assert(!ZNSParticlePlan(300,300,3,ZNSParticleCount,&p));
    assert(!ZNSParticlePlan(300,300,3,0,NULL));assert(!ZNSParticlePlan(1000,1000,3,0,&p));
    assert(!ZNSParticlePlan(-1,300,3,0,&p));
    puts("PASS particle production geometry: 120 finite content tiles, exact nonoverlapping full coverage, right/outward drift, varied delay/scale, .76s, <=2 source areas");
}
static void lifecycle(void) {
    for(int fail=-1;fail<(int)ZNSParticleCount;fail++) {
        Host h={.fail=fail,.capture=true};assert(ZNSShatterStart(&h.life,&h,ops,false));
        assert(h.scheduled==1 && h.crops==0);
        uint64_t t=h.life.generation;
        bool ok=ZNSParticleBuild(&h.life,&h,ops,t);
        assert(ok==(fail==-1));
        if(ok)assert(h.crops==ZNSParticleCount && h.live==ZNSParticleCount);
        else assert(h.crops==(unsigned)fail+1 && h.live==0 && h.clears==1);
        ZNSShatterFinish(&h.life,&h,ops,t);ZNSShatterFinish(&h.life,&h,ops,t);
        assert(h.disposed==1 && !h.life.active);
        unsigned crops=h.crops;assert(!ZNSParticleBuild(&h.life,&h,ops,t));assert(h.crops==crops);
        assert(ZNSShatterStart(&h.life,&h,ops,false));assert(!ZNSParticleBuild(&h.life,&h,ops,t));
        ZNSShatterFinish(&h.life,&h,ops,t);assert(h.life.active && h.disposed==1);
        ZNSShatterFinish(&h.life,&h,ops,h.life.generation);assert(h.disposed==2);
    }
    Host h={.fail=-1,.capture=false};assert(!ZNSShatterStart(&h.life,&h,ops,false));
    assert(h.disposed==1 && !h.crops && !h.scheduled);
    assert(ZNSParseExitStyle("particles")==ZNSExitParticles);
    assert(ZNSResolveExitStyle(ZNSExitParticles,true)==ZNSExitFade);
    assert(ZNSResolveExitStyle(ZNSExitNone,true)==ZNSExitNone);
    assert(ZNSResolveExitStyle(ZNSExitParticles,false)==ZNSExitParticles);
    puts("PASS particle host lifecycle: delayed build; all 120 partial-crop failures clear; no-snapshot; cancel/stale-build/stale-finish; idempotent disposal; Reduce Motion fade/none");
}
int main(void) { geometry();lifecycle();return 0; }
