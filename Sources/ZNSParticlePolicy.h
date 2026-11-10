#pragma once
#include "ZNSExitShatterLifecycle.h"
#define ZNSParticleColumns 10
#define ZNSParticleRows 12
#define ZNSParticleCount (ZNSParticleColumns*ZNSParticleRows)
#define ZNSParticleDuration .58
#define ZNSParticleMaxDelay .18
// Finite content tiles, not a per-pixel shader. One frozen provider, no readback.
typedef struct { double x,y,w,h,dx,dy,scale,angle,delay; } ZNSParticle;
static inline bool ZNSParticlePlan(double w,double h,double scale,unsigned i,ZNSParticle *p) {
    double pixels=0;
    if(!p || i>=ZNSParticleCount || !ZNSShatterSourcePixels(w,h,scale,&pixels)) return false;
    unsigned col=i%ZNSParticleColumns,row=i/ZNSParticleColumns;
    uint32_t seed=0x53564u+i*7919u;
    double x=w*col/ZNSParticleColumns,y=h*row/ZNSParticleRows;
    *p=(ZNSParticle){.x=x,.y=y,.w=w*(col+1)/ZNSParticleColumns-x,
        .h=h*(row+1)/ZNSParticleRows-y,
        .dx=w*(.12+.30*ZNSShatterUnit(&seed)),
        .dy=h*((row+.5)/ZNSParticleRows-.5)*(.18+.20*ZNSShatterUnit(&seed)),
        .scale=.08+.20*ZNSShatterUnit(&seed),
        .angle=(ZNSShatterUnit(&seed)-.5)*.9,
        .delay=ZNSParticleMaxDelay*(.55*col/(ZNSParticleColumns-1)+.45*ZNSShatterUnit(&seed))};
    return true;
}
// Same token and cleanup contract as glass. No crop after cancel; partial failure
// discards ALL tiles and leaves the frozen root available for the normal fade.
static inline bool ZNSParticleBuild(ZNSShatterLifetime *life,void *context,ZNSShatterOperations ops,uint64_t token) {
    if(!life->active || life->generation!=token) return false;
    for(unsigned i=0;i<ZNSParticleCount;i++) {
        if(!ops.shard(context,i)) { ops.clearShards(context); return false; }
    }
    return true;
}
