#include "ZNSFineParticlePolicy.h"
#include "ZNSWindowAnimationPolicy.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
 assert(ZNSFineDiameter-ZNSFineDiameterRange>=2);
 assert(ZNSFineDiameter+ZNSFineDiameterRange<=4);
 assert(ZNSFineMaskBytes<=2228224);
 assert(ZNSFineBirthRate*(ZNSFineLifetime+ZNSFineLifetimeRange)<=ZNSFineMaxLive);
 assert(ZNSFineMaxLive<=720);
 assert(ZNSFineDuration>=ZNSFineEmitDuration+ZNSFineLifetime+ZNSFineLifetimeRange);
 assert(ZNSFineDuration<=1.1);
 assert(ZNSFineGeometry(300,600,3));assert(ZNSFineGeometry(600,300,2));
 assert(!ZNSFineGeometry(641,300,1));assert(!ZNSFineGeometry(300,1281,1));
 assert(!ZNSFineGeometry(NAN,600,2));assert(!ZNSFineGeometry(300,INFINITY,2));
 assert(!ZNSFineGeometry(640,1280,3));assert(!ZNSFineGeometry(0,600,2));
 assert(ZNSFineMayStart(true,7,7,true,false,300,600,3));
 assert(!ZNSFineMayStart(false,7,7,true,false,300,600,3));
 assert(!ZNSFineMayStart(true,7,6,true,false,300,600,3));
 assert(!ZNSFineMayStart(true,7,7,false,false,300,600,3));
 assert(!ZNSFineMayStart(true,7,7,true,true,300,600,3));
 assert(!ZNSFineMayStart(true,7,7,true,false,1000,600,3));
 assert(ZNSFineRate(0,true)==1800);assert(ZNSFineRate(.639,true)==1800);
 assert(ZNSFineRate(.64,true)==0);assert(ZNSFineRate(100,true)==0);
 assert(ZNSFineRate(0,false)==0);assert(ZNSFineRate(-1,true)==0);
 assert(ZNSResolveExitStyle(ZNSExitParticles,true)==ZNSExitFade);
 assert(ZNSResolveExitStyle(ZNSExitNone,true)==ZNSExitNone);
 unsigned left=0,right=0;
 for(unsigned y=0;y<ZNSFineMaskHeight;y++) for(unsigned x=0;x<ZNSFineMaskWidth;x++) {
  assert(ZNSFineAlpha(x,y,0)==255);assert(ZNSFineAlpha(x,y,16)==0);
  for(unsigned f=1;f<ZNSFineMaskFrames;f++) assert(ZNSFineAlpha(x,y,f)<=ZNSFineAlpha(x,y,f-1));
  if(x<ZNSFineMaskWidth/2) left+=ZNSFineAlpha(x,y,8);else right+=ZNSFineAlpha(x,y,8);
 }
 assert(left<right/2);
 puts("PASS production fine geometry/size/budget/monotone erosion/rightward front/emission stop/token/cancel/snapshot failure/ReduceMotion/none");
}
