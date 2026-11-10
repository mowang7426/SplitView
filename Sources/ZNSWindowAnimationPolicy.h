#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
// Shared production configuration, motion plans and one-shot host lifecycle.
typedef enum { ZNSExitNone, ZNSExitShatter, ZNSExitReference, ZNSExitShrink, ZNSExitSink, ZNSExitFold, ZNSExitFade } ZNSExitStyle;
typedef enum { ZNSEntryNone, ZNSEntrySoft, ZNSEntryRise, ZNSEntryPop, ZNSEntryFade } ZNSEntryStyle;
static inline ZNSExitStyle ZNSParseExitStyle(const char *s) {
    if(s) {
        if(!strcmp(s,"none")) return ZNSExitNone;
        if(!strcmp(s,"reference")) return ZNSExitReference;
        if(!strcmp(s,"shrink")) return ZNSExitShrink;
        if(!strcmp(s,"sink")) return ZNSExitSink;
        if(!strcmp(s,"fold")) return ZNSExitFold;
    }
    return ZNSExitShatter;
}
static inline ZNSEntryStyle ZNSParseEntryStyle(const char *s) {
    if(s) {
        if(!strcmp(s,"none")) return ZNSEntryNone;
        if(!strcmp(s,"rise")) return ZNSEntryRise;
        if(!strcmp(s,"pop")) return ZNSEntryPop;
    }
    return ZNSEntrySoft;
}
static inline ZNSExitStyle ZNSResolveExitStyle(ZNSExitStyle s,bool reduce) {
    if(s<ZNSExitNone || s>ZNSExitFade) s=ZNSExitShatter;
    return reduce && s!=ZNSExitNone ? ZNSExitFade : s;
}
static inline ZNSEntryStyle ZNSResolveEntryStyle(ZNSEntryStyle s,bool reduce) {
    if(s<ZNSEntryNone || s>ZNSEntryFade) s=ZNSEntrySoft;
    return reduce && s!=ZNSEntryNone ? ZNSEntryFade : s;
}
typedef struct {
    bool (*present)(void *context,ZNSExitStyle style);
    void (*close)(void *context);
    void (*fallback)(void *context);
} ZNSExitDispatchOps;
// Synchronous handoff only. Frozen completion never gets these callbacks.
static inline void ZNSDispatchExit(void *context,ZNSExitDispatchOps ops,ZNSExitStyle selected,bool reduce) {
    ZNSExitStyle style=ZNSResolveExitStyle(selected,reduce);
    if(style==ZNSExitNone) { ops.close(context); return; }
    if(ops.present(context,style)) ops.close(context);
    else ops.fallback(context);
}
typedef struct { double sx,sy,dx,dy,angle,duration; bool spring; } ZNSMotionPlan;
static inline ZNSMotionPlan ZNSExitMotionPlan(ZNSExitStyle style,double w,double h) {
    ZNSMotionPlan p={1,1,0,0,0,0.16,false};
    switch(style) {
        case ZNSExitNone:p.duration=0;break;
        case ZNSExitShatter:p.duration=0.46;break;
        case ZNSExitReference:p.sx=.06;p.dx=w*.94;p.duration=.62;break;
        case ZNSExitShrink:p.sx=p.sy=.12;p.duration=.28;break;
        case ZNSExitSink:p.sx=p.sy=.92;p.dy=fmin(h*.32,160);p.duration=.32;break;
        case ZNSExitFold:p.sy=.025;p.angle=-1.15;p.dy=h*.12;p.duration=.34;break;
        case ZNSExitFade:break;
    }
    return p;
}
static inline ZNSMotionPlan ZNSEntryMotionPlan(ZNSEntryStyle style) {
    ZNSMotionPlan p={1,1,0,0,0,.16,false};
    switch(style) {
        case ZNSEntryNone:p.duration=0;break;
        case ZNSEntrySoft:p.sx=p.sy=.94;p.duration=.24;break;
        case ZNSEntryRise:p.dy=28;p.duration=.28;break;
        case ZNSEntryPop:p.sx=p.sy=.82;p.duration=.36;p.spring=true;break;
        case ZNSEntryFade:break;
    }
    return p;
}
#define ZNSReferenceBands 12
// Slightly uneven horizontal bands; deterministic, bounded and no image readback.
static inline double ZNSReferenceDelay(unsigned i) { return .018*(double)((i*7)%11); }
typedef struct { uint64_t generation; bool consumed,active; } ZNSOpeningLifetime;
static inline uint64_t ZNSOpeningReady(ZNSOpeningLifetime *s,bool newWindow,bool hostReady,bool eligible,ZNSEntryStyle style) {
    if(s->consumed || !newWindow) return 0;
    s->consumed=true;
    if(!hostReady || !eligible || style==ZNSEntryNone) return 0;
    s->active=true;return ++s->generation;
}
static inline bool ZNSOpeningFinish(ZNSOpeningLifetime *s,uint64_t token) {
    if(!s->active || token!=s->generation) return false;
    s->active=false;return true;
}
static inline void ZNSOpeningCancel(ZNSOpeningLifetime *s) {
    s->consumed=true;s->active=false;++s->generation;
}
