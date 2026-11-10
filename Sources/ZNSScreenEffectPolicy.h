#pragma once
#include <stdbool.h>
#include <math.h>
// Original bounded choreography. Index order matches ZNSScreenIndex.
#define ZNSScreenCount 18
#define ZNSScreenMaxTiles 64
#define ZNSScreenDuration .64
#define ZNSScreenFrames 7
typedef struct { double x,y,w,h; } ZNSScreenRect;
typedef struct { double sx,sy,dx,dy,rz,ry,alpha; } ZNSScreenPose;
static inline unsigned ZNSScreenTiles(int effect) {
    if(effect<0 || effect>=ZNSScreenCount) return 0;
    if(effect==4 || effect==14) return 1;
    if(effect==2 || effect==3 || effect==5 || effect==9 || effect==10) return 12;
    return ZNSScreenMaxTiles;
}
typedef struct { bool (*tile)(void *,unsigned); void (*discard)(void *); } ZNSScreenBuildOps;
static inline bool ZNSScreenBuild(void *context,int effect,ZNSScreenBuildOps ops) {
    unsigned count=ZNSScreenTiles(effect);
    if(!count) return false;
    for(unsigned i=0;i<count;i++) if(!ops.tile(context,i)) { ops.discard(context);return false; }
    return true;
}
static inline bool ZNSScreenRectAt(int effect,unsigned i,double w,double h,ZNSScreenRect *out) {
    unsigned n=ZNSScreenTiles(effect); if(!out || i>=n || !isfinite(w) || !isfinite(h) || w<=0 || h<=0 || w>4096 || h>4096) return false;
    unsigned cols=n==64?8:1,rows=n==64?8:n;
    if(effect==5 || effect==9) { cols=n;rows=1; }
    unsigned c=i%cols,r=i/cols;
    double x=w*c/cols,y=h*r/rows;
    *out=(ZNSScreenRect){x,y,w*(c+1)/cols-x,h*(r+1)/rows-y};return true;
}
static inline double ZNSScreenClamp(double t) { return fmin(1,fmax(0,t)); }
static inline ZNSScreenPose ZNSScreenPoseAt(int e,unsigned i,double w,double h,double t,bool entry) {
    // Entry is a reveal/assembly with increasing opacity, never a replay of close callbacks.
    t=ZNSScreenClamp(t); double q=entry?1-t:t;
    double u=((i*37+11)%67)/66.0, v=((i*19+5)%71)/70.0;
    double a=(i%8+.5)/8.0-.5,b=(i/8+.5)/8.0-.5;
    ZNSScreenPose p={1,1,0,0,0,0,1-q};
    switch(e) {
        case 0:p.dy=h*.5*q*q;p.dx=a*w*.35*q;p.rz=(u-.5)*1.4*q;break;
        case 1:p.sx=p.sy=1-.95*q;p.dx=(u-.5)*w*.08*q;p.dy=(v-.5)*h*.08*q;break;
        case 2:p.sy=1-.98*q;p.dx=(i%2?1:-1)*w*.16*q;break;
        case 3:p.dx=sin(t*31+i*7)*w*.045*sin(t*3.141592653589793);p.alpha=(1-q)*(i%3==0?.65:1);break;
        case 4:p.sy=fmax(.008,1-q*1.8);p.sx=q<.55?1:fmax(.015,1-(q-.55)/.45);break;
        case 5:p.ry=(i%2?1:-1)*1.53*q;p.sx=1-.12*q;break;
        case 6:p.dx=-a*w*q;p.dy=-b*h*q;p.rz=2.5*q;p.sx=p.sy=1-.94*q;break;
        case 7:p.dy=-h*(.18+u*.27)*q;p.dx=sin(u*8)*w*.15*q;p.sx=p.sy=1-.75*q;break;
        case 8:p.dx=w*(.22+u*.32)*q;p.dy=-h*(.05+v*.16)*q;p.sx=p.sy=1-.85*q;break;
        case 9:p.dy=h*(.16+u*.42)*q*q;p.sy=1-.6*q;p.rz=(u-.5)*.15*q;break;
        case 10:p.dx=sin(i*.7+t*7)*w*.09*sin(t*3.141592653589793);p.sx=1-.05*q;break;
        case 11:p.dx=a*w*.85*q;p.dy=b*h*.85*q;p.sx=p.sy=1-.7*q;p.rz=(u-.5)*q;break;
        case 12:p.dx=(a*cos(q*2)-b*sin(q*2))*w*q*.7;p.dy=(a*sin(q*2)+b*cos(q*2))*h*q*.7;p.rz=3*q;p.sx=p.sy=1-.8*q;break;
        case 13:p.ry=1.4*q;p.dy=h*.15*q;p.dx=(u-.5)*w*.16*q;p.sx=1-.65*q;break;
        case 14:p.alpha=(1-q)*(t>.15 && t<.3?.45:1);p.dy=sin(t*25)*sin(t*3.141592653589793)*fmin(2,h*.01);break;
        case 15:p.dy=-h*(.08+v*.22)*q;p.dx=(u-.5)*w*.3*q;p.sx=p.sy=1+q*.45;break;
        case 16:{ double phase=ZNSScreenClamp((q-a*.20)/.9);p.dx=w*.32*phase;p.dy=-h*.13*phase;p.sx=p.sy=1-.9*phase;p.alpha=1-phase;break; }
        case 17:p.alpha=1-ZNSScreenClamp((q-u*.55)/.45);break; // Coarse deterministic dissolve, NOT Perlin raster noise.
        default:break;
    }
    // Exact visible/home endpoints prevent last-frame geometry or alpha jumps.
    if((entry && t==1) || (!entry && t==0)) p=(ZNSScreenPose){1,1,0,0,0,0,1};
    if((entry && t==0) || (!entry && t==1)) p.alpha=0;
    return p;
}
