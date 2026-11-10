#pragma once
#include "ZNSExitShatterGeometry.h"
typedef struct {
    bool (*capture)(void *context);
    bool (*shard)(void *context,unsigned index);
    void (*clearShards)(void *context);
    void (*play)(void *context,bool scatter,uint64_t token);
    void (*dispose)(void *context);
    void (*schedule)(void *context,bool scatter,uint64_t token);
} ZNSShatterOperations;
// Production coordinator: platform capture/animation are injectable for host tests.
// Build only from the frozen view after it has had a display opportunity. Never
// wait synchronously for a render-server acknowledgment or a remote App.
static inline void ZNSShatterBuild(ZNSShatterLifetime *life,void *context,ZNSShatterOperations ops,bool scatter,uint64_t token) {
    if(!life->active || life->generation!=token) return;
    if(scatter) {
        for(unsigned i=0;i<ZNSShatterCount;i++) {
            if(!ops.shard(context,i)) { scatter=false; ops.clearShards(context); break; }
        }
    }
    ops.play(context,scatter,token);
}
static inline bool ZNSShatterStart(ZNSShatterLifetime *life,void *context,ZNSShatterOperations ops,bool scatter) {
    if(life->active) return false;
    if(!ops.capture(context)) { ops.dispose(context); return false; }
    uint64_t token=ZNSShatterBegin(life);
    ops.schedule(context,scatter,token);
    return true;
}
static inline void ZNSShatterFinish(ZNSShatterLifetime *life,void *context,ZNSShatterOperations ops,uint64_t token) {
    if(ZNSShatterEnd(life,token)) ops.dispose(context);
}
