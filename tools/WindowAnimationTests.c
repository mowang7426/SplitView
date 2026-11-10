#include <assert.h>
#include <stdio.h>
#include "ZNSWindowAnimationPolicy.h"
#include "ZNSAnimationSettingsFixture.h"
typedef struct { int present,close,fallback; ZNSExitStyle style; bool capture; } Host;
static bool present(void *p,ZNSExitStyle style) { Host *h=p;h->present++;h->style=style;return h->capture; }
static void closeHost(void *p) { ((Host *)p)->close++; }
static void fallback(void *p) { ((Host *)p)->fallback++; }
static const ZNSExitDispatchOps ops={present,closeHost,fallback};
static void settings(void) {
    assert(ZNSParseExitStyle(NULL)==ZNSExitShatter);
    assert(ZNSParseExitStyle("unknown")==ZNSExitShatter);
    assert(ZNSParseExitStyle("")==ZNSExitShatter);
    assert(ZNSParseExitStyle("NONE")==ZNSExitShatter);
    assert(ZNSParseEntryStyle(NULL)==ZNSEntrySoft);
    assert(ZNSParseEntryStyle("unknown")==ZNSEntrySoft);
    for(unsigned i=0;i<6;i++) {
        ZNSExitStyle style=ZNSParseExitStyle(znsExitValues[i]);assert(style==(ZNSExitStyle)i);
        for(unsigned reduce=0;reduce<2;reduce++) for(unsigned capture=0;capture<2;capture++) {
            Host h={.capture=capture};
            ZNSDispatchExit(&h,ops,style,reduce);
            if(style==ZNSExitNone) { assert(h.present==0 && h.close==1 && h.fallback==0); }
            else {
                assert(h.present==1);assert(h.style==(reduce?ZNSExitFade:style));
                assert(h.close==(int)capture && h.fallback==!capture);
            }
        }
    }
    Host unknown={.capture=true};ZNSDispatchExit(&unknown,ops,(ZNSExitStyle)999,false);
    assert(unknown.present==1 && unknown.style==ZNSExitShatter && unknown.close==1);
    for(unsigned i=0;i<4;i++) {
        ZNSEntryStyle s=ZNSParseEntryStyle(znsEntryValues[i]);assert(s==(ZNSEntryStyle)i);
        assert(ZNSResolveEntryStyle(s,false)==s);
        assert(ZNSResolveEntryStyle(s,true)==(s==ZNSEntryNone?ZNSEntryNone:ZNSEntryFade));
    }
    assert(ZNSParseExitStyle(znsExitDefault)==ZNSExitShatter);
    assert(ZNSParseEntryStyle(znsEntryDefault)==ZNSEntrySoft);
    puts("PASS real plist values/defaults -> production parser -> production dispatch host callbacks (all settings, unknown, none, Reduce Motion, capture refusal)");
}
static void plans(void) {
    ZNSMotionPlan p=ZNSExitMotionPlan(ZNSExitReference,300,600);assert(p.sx==.06 && fabs(p.dx-282)<.001 && p.duration==.62);
    p=ZNSExitMotionPlan(ZNSExitShrink,300,600);assert(p.sx==.12 && p.sy==.12);
    p=ZNSExitMotionPlan(ZNSExitSink,300,600);assert(p.dy==160 && p.sx==.92);
    p=ZNSExitMotionPlan(ZNSExitFold,300,600);assert(p.sy==.025 && p.angle==-1.15);
    p=ZNSExitMotionPlan(ZNSExitFade,300,600);assert(p.sx==1 && p.sy==1 && p.dx==0 && p.dy==0 && p.angle==0 && p.duration==.16);
    assert(ZNSReferenceBands==12);
    for(unsigned i=0;i<ZNSReferenceBands;i++) assert(ZNSReferenceDelay(i)>=0 && ZNSReferenceDelay(i)<=.181);
    assert(ZNSReferenceDelay(1)!=ZNSReferenceDelay(2));
    p=ZNSEntryMotionPlan(ZNSEntrySoft);assert(p.sx==.94 && !p.spring);
    p=ZNSEntryMotionPlan(ZNSEntryRise);assert(p.dy==28 && p.sx==1);
    p=ZNSEntryMotionPlan(ZNSEntryPop);assert(p.spring && p.sx==.82);
    p=ZNSEntryMotionPlan(ZNSEntryFade);assert(p.sx==1 && p.dy==0 && !p.spring);
    assert(ZNSEntryMotionPlan(ZNSEntryNone).duration==0);
    puts("PASS distinct bounded production motion plans: reference bands, shrink, sink, fold, soft, rise, pop, motion-free fades");
}
static void lifetime(void) {
    ZNSOpeningLifetime s={0},other={0};
    assert(!ZNSOpeningReady(&s,false,true,true,ZNSEntrySoft));assert(!s.consumed);
    assert(!ZNSOpeningReady(&s,true,false,true,ZNSEntrySoft));assert(s.consumed && !s.active);
    assert(!ZNSOpeningReady(&s,true,true,true,ZNSEntrySoft));
    s=(ZNSOpeningLifetime){0};assert(!ZNSOpeningReady(&s,true,true,false,ZNSEntrySoft));
    s=(ZNSOpeningLifetime){0};assert(!ZNSOpeningReady(&s,true,true,true,ZNSEntryNone));assert(!s.active);
    s=(ZNSOpeningLifetime){0};uint64_t token=ZNSOpeningReady(&s,true,true,true,ZNSEntrySoft);assert(token && s.active);
    assert(!ZNSOpeningReady(&s,true,true,true,ZNSEntrySoft));
    assert(!ZNSOpeningFinish(&s,token+1) && s.active);
    uint64_t newToken=ZNSOpeningReady(&other,true,true,true,ZNSEntryRise);assert(newToken && other.active);
    ZNSOpeningCancel(&s);assert(!s.active && s.consumed);
    assert(!ZNSOpeningFinish(&s,token));assert(other.active);
    assert(!ZNSOpeningReady(&s,true,true,true,ZNSEntryPop));
    assert(ZNSOpeningFinish(&other,newToken));assert(!ZNSOpeningFinish(&other,newToken));
    ZNSOpeningCancel(&other);ZNSOpeningCancel(&other);assert(!other.active);
    s=(ZNSOpeningLifetime){0};ZNSOpeningCancel(&s);
    assert(!ZNSOpeningReady(&s,true,true,true,ZNSEntrySoft));
    puts("PASS production opening lifetime: new-window-only, host-ready failure, ineligible/none, single use, cancel before/after ready, stale task, isolated rapid new session, idempotent finish");
}
int main(void) { settings();plans();lifetime();return 0; }
