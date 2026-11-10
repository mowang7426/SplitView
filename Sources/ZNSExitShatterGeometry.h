#pragma once
#include <math.h>
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

// Pure production geometry/policy, also executed by the native host tests.
#define ZNSShatterCount 16
#define ZNSShatterVertices 24
#define ZNSShatterPixelBudget 2400000.0
#define ZNSShatterDuration 0.46
#define ZNSShatterFadeDuration 0.16
typedef struct { double x,y; } ZNSShatterPoint;
typedef struct { unsigned count; ZNSShatterPoint p[ZNSShatterVertices]; double dx,dy,angle; } ZNSShatterPolygon;
typedef struct { bool active; uint64_t generation; } ZNSShatterLifetime;
static inline bool ZNSShatterSourcePixels(double w,double h,double scale,double *pixels) {
    double area=w*h*scale*scale;
    if(!pixels || !isfinite(w) || !isfinite(h) || !isfinite(scale) || w<2 || h<2 || scale<=0 ||
       w>4096 || h>4096 || !isfinite(area) || area<=0 || area>ZNSShatterPixelBudget) return false;
    *pixels=area; return true;
}
static inline bool ZNSShatterReservePixels(double *pixels,double area) {
    if(!pixels || !isfinite(*pixels) || *pixels<0 || !isfinite(area) || area<=0 ||
       *pixels+area>2.5*ZNSShatterPixelBudget) return false;
    *pixels+=area; return true;
}
static inline uint64_t ZNSShatterBegin(ZNSShatterLifetime *s) { s->active=true; return ++s->generation; }
static inline bool ZNSShatterEnd(ZNSShatterLifetime *s,uint64_t token) {
    if(!s->active || s->generation!=token) return false;
    s->active=false; return true;
}
static inline uint32_t ZNSShatterRandom(uint32_t *s) { *s=*s*1664525u+1013904223u; return *s; }
static inline double ZNSShatterUnit(uint32_t *s) { return (ZNSShatterRandom(s)>>8)/16777216.0; }
static inline bool ZNSShatterGeometry(double w,double h,double scale,uint32_t seed,ZNSShatterPolygon out[ZNSShatterCount]) {
    double pixels=0;
    if(!out || !ZNSShatterSourcePixels(w,h,scale,&pixels)) return false;
    ZNSShatterPoint sites[ZNSShatterCount];
    for(unsigned i=0;i<ZNSShatterCount;i++) {
        sites[i]=(ZNSShatterPoint){w*((i%4)+0.2+0.6*ZNSShatterUnit(&seed))/4,
                                  h*((i/4)+0.2+0.6*ZNSShatterUnit(&seed))/4};
    }
    // Voronoi half-plane clipping: irregular convex glass, not rectangular tiles.
    for(unsigned i=0;i<ZNSShatterCount;i++) {
        ZNSShatterPolygon poly={.count=4,.p={{0,0},{w,0},{w,h},{0,h}}};
        for(unsigned j=0;j<ZNSShatterCount;j++) {
            if(i==j) continue;
            double nx=sites[j].x-sites[i].x,ny=sites[j].y-sites[i].y;
            double edge=(sites[j].x*sites[j].x+sites[j].y*sites[j].y-sites[i].x*sites[i].x-sites[i].y*sites[i].y)/2;
            ZNSShatterPolygon next={0};
            for(unsigned k=0;k<poly.count;k++) {
                ZNSShatterPoint a=poly.p[k],b=poly.p[(k+1)%poly.count];
                double da=a.x*nx+a.y*ny-edge,db=b.x*nx+b.y*ny-edge;
                if(da<=0) { if(next.count==ZNSShatterVertices) return false; next.p[next.count++]=a; }
                if((da<0 && db>0) || (da>0 && db<0)) {
                    double t=da/(da-db);
                    if(next.count==ZNSShatterVertices) return false;
                    next.p[next.count++]=(ZNSShatterPoint){a.x+t*(b.x-a.x),a.y+t*(b.y-a.y)};
                }
            }
            poly=next;
        }
        if(poly.count<3) return false;
        poly.dx=(sites[i].x<w/2?-1:1)*w*(0.12+0.2*ZNSShatterUnit(&seed));
        poly.dy=h*(0.22+0.3*ZNSShatterUnit(&seed));
        poly.angle=(sites[i].x<w/2?-1:1)*(0.12+0.45*ZNSShatterUnit(&seed));
        out[i]=poly;
    }
    return true;
}
