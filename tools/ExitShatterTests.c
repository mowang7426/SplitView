// Executes the actual production coordinator + geometry; no UIKit/runtime model.
#include "ZNSExitShatterLifecycle.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
typedef struct {
    ZNSShatterLifetime life;
    unsigned captures,shards,clears,plays,disposes,schedules;
    bool captureOK,scatter;
    int failShard;
    uint64_t queued;
} ZNSShatterMock;
static bool capture(void *v) { ZNSShatterMock *m=v; m->captures++; return m->captureOK; }
static bool shard(void *v,unsigned i) { ZNSShatterMock *m=v; assert(i==m->shards); m->shards++; return (int)i!=m->failShard; }
static void clear(void *v) { ((ZNSShatterMock *)v)->clears++; }
static void play(void *v,bool scatter,uint64_t token) {
    ZNSShatterMock *m=v; assert(m->life.active && token==m->life.generation);
    m->plays++; m->scatter=scatter;
}
static void dispose(void *v) { ZNSShatterMock *m=v; assert(!m->life.active); m->disposes++; }
static void schedule(void *v,bool scatter,uint64_t token) {
    ZNSShatterMock *m=v; m->schedules++; m->queued=token; m->scatter=scatter;
}
static const ZNSShatterOperations ops={capture,shard,clear,play,dispose,schedule};
static ZNSShatterMock fresh(void) { ZNSShatterMock m={.captureOK=true,.failShard=-1}; return m; }
static void drain(ZNSShatterMock *m) { ZNSShatterBuild(&m->life,m,ops,m->scatter,m->queued); }
static void finish(ZNSShatterMock *m,uint64_t token) { ZNSShatterFinish(&m->life,m,ops,token); }
static void lifecycle(void) {
    ZNSShatterMock m=fresh(); m.captureOK=false;
    assert(!ZNSShatterStart(&m.life,&m,ops,true));
    assert(m.captures==1 && m.disposes==1 && m.schedules==0 && m.plays==0 && m.shards==0);
    m=fresh(); assert(ZNSShatterStart(&m.life,&m,ops,true));
    assert(m.schedules==1 && m.plays==0 && m.shards==0);
    assert(!ZNSShatterStart(&m.life,&m,ops,true)); assert(m.captures==1);
    drain(&m); assert(m.scatter && m.shards==ZNSShatterCount && m.plays==1 && m.clears==0);
    finish(&m,m.queued); finish(&m,m.queued);
    assert(m.disposes==1 && !m.life.active);
    unsigned plays=m.plays; drain(&m); assert(m.plays==plays);
    // Reduce Motion / unavailable geometry: one frozen fade, no shards at all.
    m=fresh(); assert(ZNSShatterStart(&m.life,&m,ops,false)); drain(&m);
    assert(!m.scatter && m.plays==1 && m.shards==0); finish(&m,m.queued); assert(m.disposes==1);
    // Every partial-capture refusal must release partial shards and fade root.
    for(int failure=0;failure<ZNSShatterCount;failure++) {
        m=fresh(); m.failShard=failure;
        assert(ZNSShatterStart(&m.life,&m,ops,true)); drain(&m);
        assert(!m.scatter && m.plays==1 && m.shards==(unsigned)failure+1 && m.clears==1);
        finish(&m,m.queued); assert(m.disposes==1);
    }
    // Rotation/disconnect/disable/cancel while waiting for first display frame.
    m=fresh(); assert(ZNSShatterStart(&m.life,&m,ops,true));
    uint64_t old=m.queued; finish(&m,old); drain(&m);
    assert(m.disposes==1 && m.shards==0 && m.plays==0);
    // A late completion/fail-safe must not dispose a reused/new generation.
    assert(ZNSShatterStart(&m.life,&m,ops,false)); uint64_t current=m.queued;
    assert(current!=old); finish(&m,old);
    assert(m.life.active && m.disposes==1);
    ZNSShatterBuild(&m.life,&m,ops,true,old); assert(m.shards==0 && m.plays==0);
    drain(&m); assert(m.plays==1); finish(&m,current); assert(m.disposes==2);
    ZNSShatterMock next=fresh(); assert(ZNSShatterStart(&next.life,&next,ops,true));
    finish(&m,old); assert(next.life.active && next.disposes==0); finish(&next,next.queued);
    puts("PASS production lifecycle: capture refusal, 16 partial failures, Reduce Motion/fade, duplicate start, cancel before build, stale completion/build, isolated next presentation");
}
static void geometry(void) {
    ZNSShatterPolygon p[ZNSShatterCount],again[ZNSShatterCount];
    assert(!ZNSShatterGeometry(NAN,300,2,1,p));
    assert(!ZNSShatterGeometry(300,INFINITY,2,1,p));
    assert(!ZNSShatterGeometry(300,300,0,1,p));
    assert(!ZNSShatterGeometry(300,300,NAN,1,p));
    assert(!ZNSShatterGeometry(-1,300,2,1,p));
    assert(!ZNSShatterGeometry(300,300,2,1,NULL));
    assert(!ZNSShatterGeometry(1000,1000,3,1,p));
    assert(!ZNSShatterGeometry(10000,20,1,1,p));
    double pixels=0;
    assert(ZNSShatterSourcePixels(600,1000,2,&pixels) && pixels==ZNSShatterPixelBudget);
    assert(!ZNSShatterSourcePixels(601,1000,2,&pixels));
    assert(!ZNSShatterSourcePixels(600,1000,2,NULL));
    assert(!ZNSShatterSourcePixels(600,1000,1e-300,&pixels));
    assert(ZNSShatterReservePixels(&pixels,1.5*ZNSShatterPixelBudget));
    assert(pixels==2.5*ZNSShatterPixelBudget);
    assert(!ZNSShatterReservePixels(&pixels,1));
    assert(!ZNSShatterReservePixels(&pixels,NAN));
    assert(!ZNSShatterReservePixels(&pixels,-1));
    assert(!ZNSShatterReservePixels(NULL,10));
    unsigned nonQuad=0;
    for(uint32_t seed=0;seed<5000;seed++) {
        double w=120+(seed%500),h=150+(seed%600);
        assert(ZNSShatterGeometry(w,h,2,seed,p));
        assert(ZNSShatterGeometry(w,h,2,seed,again));
        double total=0,crops=0;
        for(unsigned i=0;i<ZNSShatterCount;i++) {
            assert(p[i].count>=3 && p[i].count<=ZNSShatterVertices);
            assert(again[i].count==p[i].count);
            if(p[i].count!=4) nonQuad++;
            double area=0,minX=w,minY=h,maxX=0,maxY=0;
            for(unsigned k=0;k<p[i].count;k++) {
                ZNSShatterPoint a=p[i].p[k],b=p[i].p[(k+1)%p[i].count],c=p[i].p[(k+2)%p[i].count];
                assert(isfinite(a.x) && isfinite(a.y) && a.x>=-1e-7 && a.x<=w+1e-7 && a.y>=-1e-7 && a.y<=h+1e-7);
                assert(a.x==again[i].p[k].x && a.y==again[i].p[k].y);
                assert((b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)>=-1e-6);
                area+=a.x*b.y-a.y*b.x;
                minX=fmin(minX,a.x); minY=fmin(minY,a.y); maxX=fmax(maxX,a.x); maxY=fmax(maxY,a.y);
            }
            assert(area>0); total+=area/2; crops+=(maxX-minX)*(maxY-minY);
            assert(isfinite(p[i].dx) && fabs(p[i].dx)<=0.32*w+1e-7 && fabs(p[i].dx)>=0.12*w-1e-7);
            assert((i%4<2 && p[i].dx<0 && p[i].angle<0) || (i%4>=2 && p[i].dx>0 && p[i].angle>0));
            assert(p[i].dy>=0.22*h && p[i].dy<=0.52*h);
            assert(fabs(p[i].angle)>=0.12 && fabs(p[i].angle)<=0.57);
        }
        assert(fabs(total-w*h)<1e-6*w*h);
        assert(crops<2.5*w*h); // Worst-case allocation is additionally capped in UIKit helper.
    }
    assert(nonQuad>5000);
    assert(ZNSShatterCount<=20 && ZNSShatterDuration>=0.4 && ZNSShatterDuration<=0.5);
    assert(ZNSShatterFadeDuration>0 && ZNSShatterFadeDuration<=0.2);
    puts("PASS production Voronoi: 5000 seeds / 80000 polygons, deterministic, finite, convex, full area, irregular, bounded piece count/pixel budget/motion");
}
int main(void) { lifecycle(); geometry(); return 0; }
