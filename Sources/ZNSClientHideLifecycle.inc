// App-main-thread lifecycle state. No timers turn unknown into absent.
// Scalar core is included verbatim by host tests; UIKit adapter supplies only
// current owned window/scene, layout epoch, screen frame and keyboard guide.
#include <stdint.h>
#include <stdbool.h>
typedef struct {
    uint64_t generation, willGeneration, hiddenPhase, layoutEpoch;
    uintptr_t owner;
    bool paired, completed;
} ZNSClientHideLifecycle;
static bool ZNSClientMayPublishShow(bool willShow,uint64_t current) {
    // DidShow completes only an already-started Show. It must not manufacture
    // a new Show generation after a later WillHide/DidHide (or bridge startup).
    return willShow || (current&3)==ZNSClientKeyboardShown;
}
static void ZNSClientHideReset(ZNSClientHideLifecycle *s) {
    ++s->generation; s->willGeneration=0; s->hiddenPhase=0;
    s->paired=false; s->completed=false;
}
static void ZNSClientHideWill(ZNSClientHideLifecycle *s,uintptr_t owner,
    uint64_t epoch,bool localDockedExit) {
    ZNSClientHideReset(s);
    s->owner=owner; s->layoutEpoch=epoch; s->willGeneration=s->generation;
    s->paired=owner && localDockedExit;
}
static void ZNSClientHideDid(ZNSClientHideLifecycle *s,uint64_t phase,
    uintptr_t owner,uint64_t epoch,bool offscreen) {
    s->completed=s->paired && s->willGeneration==s->generation &&
        owner && owner==s->owner && epoch==s->layoutEpoch && offscreen &&
        phase && (phase&3)==ZNSClientKeyboardHidden;
    s->hiddenPhase=s->completed?phase:0;
    s->paired=false; // one completion consumes exactly one WillHide
}
static NSInteger ZNSClientCompletedHideProof(const ZNSClientHideLifecycle *s,
    uint64_t expected,uint64_t current,NSInteger live,uintptr_t owner,
    uint64_t epoch,NSInteger guide) {
    if (!expected || expected!=current || (current&3)!=ZNSClientKeyboardHidden) return 0;
    live=ZNSClientResolveHiddenProof(expected,current,live);
    if (live==1 || guide==1) return 1; // either current visible source vetoes
    if (live==2) return 2; // existing strict-ABI reader remains useful
    return s->completed && s->hiddenPhase==current && owner && owner==s->owner &&
        epoch==s->layoutEpoch && guide==2 ? 2 : 0;
}
