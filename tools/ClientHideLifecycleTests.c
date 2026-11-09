#include <assert.h>
#include <stdio.h>
#include <stdint.h>
typedef long NSInteger;
enum { ZNSClientKeyboardShown=1, ZNSClientKeyboardHidden=3 };
#include "../Sources/ZNSClientHiddenProof.inc"
#include "../Sources/ZNSClientHideLifecycle.inc"
static void Complete(ZNSClientHideLifecycle *s) {
    ZNSClientHideWill(s,42,7,true);
    ZNSClientHideDid(s,103,42,7,true);
}
static NSInteger Proof(ZNSClientHideLifecycle *s,NSInteger live,NSInteger guide) {
    return ZNSClientCompletedHideProof(s,103,103,live,42,7,guide);
}
int main(void) {
    ZNSClientHideLifecycle s={0};
    for (uint64_t phase=0;phase<8;phase++) {
        assert(ZNSClientMayPublishShow(true,phase)); // a new WillShow can reopen
        assert(ZNSClientMayPublishShow(false,phase)==((phase&3)==1));
    }
    assert(Proof(&s,0,2)==0); // empty guide without lifecycle is not absence
    for (unsigned repeat=0;repeat<8;repeat++) {
        Complete(&s);
        assert(Proof(&s,0,2)==2); // reader permanently unknown / nil instance
        assert(Proof(&s,0,0)==0); // default/unobserved guide cannot help
        assert(Proof(&s,1,2)==1); // private visible veto
        assert(Proof(&s,0,1)==1); // live guide veto while remote surface exists
        assert(Proof(&s,2,1)==1); // even private absent cannot override guide
        assert(Proof(&s,2,0)==2); // preserve keyboard13 reader compatibility
        assert(ZNSClientCompletedHideProof(&s,103,107,0,42,7,2)==0);
        assert(ZNSClientCompletedHideProof(&s,107,103,0,42,7,2)==0);
        assert(ZNSClientCompletedHideProof(&s,107,107,0,42,7,2)==0);
        assert(ZNSClientCompletedHideProof(&s,105,105,0,42,7,2)==0);
        assert(ZNSClientCompletedHideProof(&s,0,0,0,42,7,2)==0);
        assert(ZNSClientCompletedHideProof(&s,103,103,0,43,7,2)==0);
        assert(ZNSClientCompletedHideProof(&s,103,103,0,0,7,2)==0);
        assert(ZNSClientCompletedHideProof(&s,103,103,0,42,8,2)==0);
        ZNSClientHideReset(&s); // new Show, close, rotate, background
        assert(Proof(&s,0,2)==0);
        ZNSClientHideDid(&s,103,42,7,true); // unpaired completion
        assert(Proof(&s,0,2)==0);
        ZNSClientHideWill(&s,42,7,false); // resize hide / on-screen end
        ZNSClientHideDid(&s,103,42,7,true);
        assert(Proof(&s,0,2)==0);
        ZNSClientHideWill(&s,42,7,true);
        ZNSClientHideDid(&s,103,42,7,false);
        assert(Proof(&s,0,2)==0);
        ZNSClientHideWill(&s,42,7,true);
        ZNSClientHideDid(&s,103,42,8,true); // canvas changed during native hide
        assert(Proof(&s,0,2)==0);
        ZNSClientHideWill(&s,42,7,true);
        ZNSClientHideDid(&s,103,43,7,true); // owner changed
        assert(Proof(&s,0,2)==0);
        ZNSClientHideWill(&s,42,7,true);
        ZNSClientHideDid(&s,105,42,7,true); // wrong phase
        assert(Proof(&s,0,2)==0);
        Complete(&s);
        ZNSClientHideDid(&s,103,42,7,true); // no duplicate completion reuse
        assert(Proof(&s,0,2)==0);
    }
    puts("PASS keyboard15 production lifecycle core: unknown/nil-reader genuine close, dual visible veto, no lifecycle/no guide fail closed, owner/phase/layout epoch, paired completion, repeated cycles and lifecycle revocation");
    return 0;
}
