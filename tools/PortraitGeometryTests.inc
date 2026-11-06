// Execute exactly the production geometry, with independent screen-space oracle.
static CGRect MapRect(CGRect r,CGRect bounds,CGPoint center,CGAffineTransform t) {
    r=CGRectOffset(r,-CGRectGetMidX(bounds),-CGRectGetMidY(bounds));
    return CGRectOffset(CGRectApplyAffineTransform(r,t),center.x,center.y);
}
static void NearRect(CGRect a,CGRect b) {
    assert(fabs(CGRectGetMinX(a)-CGRectGetMinX(b))<=0.5);
    assert(fabs(CGRectGetMinY(a)-CGRectGetMinY(b))<=0.5);
    assert(fabs(CGRectGetMaxX(a)-CGRectGetMaxX(b))<=0.5);
    assert(fabs(CGRectGetMaxY(a)-CGRectGetMaxY(b))<=0.5);
}
static void LayeredGeometryTests(void) {
    unsigned cases=0;
    CGSize canvases[]={{390,844},{320,568},{428,926},{768,1024},{1024,768}};
    CGSize screens[]={{320,568},{390,844},{768,1024}};
    for (unsigned s=0;s<sizeof(screens)/sizeof(*screens);s++)
    for (int x=-70;x<=90;x+=40) for (int y=20;y<=220;y+=50)
    for (int w=240;w<=440;w+=40) for (int h=360;h<=760;h+=80)
    for (unsigned n=0;n<sizeof(canvases)/sizeof(*canvases);n++) {
        CGRect target=CGRectMake(x-25,y+12,screens[s].width,screens[s].height*0.82),saved=CGRectMake(x+40,y+25,w,h);
        CGRect b=(CGRect){CGPointZero,target.size},normal=(CGRect){CGPointZero,saved.size};
        CGPoint center=CGPointMake(CGRectGetMidX(b),CGRectGetMidY(b));
        CGPoint rootCenter=CGPointMake(CGRectGetMidX(target),CGRectGetMidY(target));
        CGAffineTransform root=ZNSPortraitRectTransform(target,saved);
        ZNSPortraitVisualGeometry g=ZNSPortraitVisualGeometryMake(target.size,saved.size,canvases[n]);
        NearRect(MapRect(b,b,rootCenter,root),saved);
        CGRect body=MapRect(MapRect(b,b,center,g.body),b,rootCenter,root);
        CGRect content=MapRect(MapRect(b,b,center,g.content),b,rootCenter,root);
        CGRect canvas=MapRect(MapRect(MapRect(b,b,center,g.canvas),b,center,g.content),b,rootCenter,root);
        NearRect(body,CGRectOffset(ZNSMainBody(normal),saved.origin.x,saved.origin.y));
        CGRect c=ZNSMainContent(normal);
        NearRect(content,CGRectOffset(c,saved.origin.x,saved.origin.y));
        CGFloat scale=fmin(c.size.width/canvases[n].width,c.size.height/canvases[n].height);
        CGRect expected=CGRectMake(saved.origin.x+CGRectGetMidX(c)-canvases[n].width*scale/2,
            saved.origin.y+CGRectGetMidY(c)-canvases[n].height*scale/2,canvases[n].width*scale,canvases[n].height*scale);
        NearRect(canvas,expected);
        cases++;
    }
    printf("PASS keyboard11 %u layered root/body/content/rendered-canvas screen-space corner cases <=0.5pt; production helper, independent aspect-fit oracle\n",cases);
}
