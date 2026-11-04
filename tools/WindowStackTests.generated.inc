#ifdef ZNS_TEST_FLOATING
- (BOOL)isStackParticipant {
    return !self.closing && !self.docked && (!self.thumbnail || self.thumbnailFree);
}
#endif
#ifdef ZNS_TEST_FLOATING
- (CGRect)thumbnailFrameInSafe:(CGRect)safe {
    CGSize canvas=self.session.canvasSize;
    if (canvas.width<=0 || canvas.height<=0) canvas=ZNSScreenCanvas(UIScreen.mainScreen.bounds.size,self.session.landscape);
    CGRect bounds=self.thumbnailFree?self.superview.bounds:safe;
    CGRect target=ZNSThumbnailTierFrame(canvas,bounds,self.thumbnailRight,(unsigned)self.thumbnailTier);
    if (self.thumbnailFree) target.origin=CGPointMake(self.center.x-target.size.width/2,self.center.y-target.size.height/2);
    else if (self.thumbnail) target.origin.y=self.frame.origin.y;
    return ZNSConstrainIcon(target,bounds);
}
#endif
#ifdef ZNS_TEST_FLOATING
- (void)thumbnailTapped:(UITapGestureRecognizer *)gesture {
    if(gesture.state!=UIGestureRecognizerStateRecognized || !self.thumbnail || self.closing) return;
    BOOL covered=self.stackCovered;
    if(self.parkedSelected) self.parkedSelected();
    if(self.thumbnailTier==2 || (self.thumbnailFree && covered)) {
        // Third tier always selects only; a rear moved second tier needs one
        // complete selection tap before a subsequent tap can restore it.
        if(self.requestFront) self.requestFront();
        return;
    }
    [self restore];
}
#endif
#ifdef ZNS_TEST_MANAGER
- (void)raiseWindow:(ZNSFloatingView *)view {
    if(!view || !view.isStackParticipant || ![self.windows containsObject:view]) return;
    view.stackOrder=++self.nextStackOrder;
    [self updateWindowStack];
}
#endif
#ifdef ZNS_TEST_MANAGER
- (void)updateWindowStack {
    UIView *root=self.controller.view;
    // Lower tiers/icons retain packing order below the independently movable layer.
    for(ZNSFloatingView *view in self.parkedOrder)
        if(!view.closing && !view.isStackParticipant) [root bringSubviewToFront:view];
    NSArray<ZNSFloatingView *> *ordered=[self.windows sortedArrayUsingComparator:^NSComparisonResult(ZNSFloatingView *a,ZNSFloatingView *b) {
        if(a.stackOrder==b.stackOrder) return NSOrderedSame;
        return a.stackOrder<b.stackOrder?NSOrderedAscending:NSOrderedDescending;
    }];
    ZNSFloatingView *front=nil;
    for(ZNSFloatingView *view in ordered) {
        if(view.isStackParticipant) { [root bringSubviewToFront:view]; front=view; }
    }
    // Remote content bypasses the local touch observer. Only the rear main
    // needs a selection surface; free thumbnails already own their touches.
    for(ZNSFloatingView *view in self.windows)
        view.stackCovered=view.isStackParticipant && front!=view;
}
#endif
#ifdef ZNS_TEST_MANAGER
- (void)collapseParkedToIcon:(ZNSFloatingView *)view {
    [view cancelInteraction];
    view.thumbnail=NO; view.docked=YES; view.dockedFromThumbnail=YES; view.wasParkedIcon=YES;
    view.restoreButton.accessibilityLabel=@"恢复实时空挂窗口";
    [view updateContentInputGate]; [view setNeedsLayout];
}
#endif
#ifdef ZNS_TEST_MANAGER
- (void)arrangeParked {
    if (self.arranging || !self.window) return;
    self.arranging=YES;
    NSMutableArray<ZNSFloatingView *> *items=[NSMutableArray new];
    for (ZNSFloatingView *v in self.parkedOrder) if (!v.closing && (v.thumbnail || v.docked)) [items addObject:v];
    BOOL waitingForDirection=NO;
    for (ZNSFloatingView *v in items) if ([v applyPendingDeviceOrientation]) waitingForDirection=YES;
    if (waitingForDirection) { self.arranging=NO; return; }
    CGRect safe=[self availableFrame];
    BOOL landscape=self.controller.view.bounds.size.width>self.controller.view.bounds.size.height;
    NSUInteger live=0;
    for(ZNSFloatingView *v in items) if(v.thumbnail) live++;
    for(ZNSFloatingView *v in items) if(live>self.maxParkedApps && v.thumbnail) {
        v.rotationOverflow=NO; [self collapseParkedToIcon:v]; live--;
    }
    // Only icons created by a landscape space shortage are eligible. User-docked
    // icons and capacity overflow never unexpectedly turn into thumbnails.
    for(ZNSFloatingView *v in items) if(v.restoreOnNextArrange) {
        v.restoreOnNextArrange=NO;
        if(landscape || !v.rotationOverflow || live>=self.maxParkedApps) continue;
        // Reserve restoration candidates before movable icons. The packing pass
        // accepts the exact old position or collapses the candidate again.
        v.docked=NO; v.thumbnail=YES; v.wasParkedIcon=NO; v.dockedFromThumbnail=NO;
        v.restoringPosition=YES; live++;
    }
    CGRect *occupied=calloc(MAX(items.count,1),sizeof(CGRect));
    if(!occupied) { self.arranging=NO; return; }
    NSMutableDictionary<NSValue *,NSValue *> *targets=[NSMutableDictionary new];
    for(NSUInteger attempt=0;attempt<=items.count;attempt++) {
        [targets removeAllObjects]; unsigned used=0;
        // Free third tiers neither reserve parking cells nor become space victims.
        for(ZNSFloatingView *v in items) if(v.thumbnail && v.thumbnailFree) {
            CGRect target=[v thumbnailFrameInSafe:safe];
            if(v.restoringPosition) target.origin=v.portraitFrame.origin;
            target=ZNSConstrainIcon(target,self.controller.view.bounds);
            targets[[NSValue valueWithNonretainedObject:v]]=[NSValue valueWithCGRect:target];
        }
        ZNSFloatingView *victim=nil;
        NSMutableArray<ZNSFloatingView *> *ordered=[NSMutableArray new];
        for(ZNSFloatingView *v in items) if(v.thumbnail && !v.thumbnailFree && v.restoringPosition) [ordered addObject:v];
        for(ZNSFloatingView *v in items) if(v.thumbnail && !v.thumbnailFree && !v.restoringPosition) [ordered addObject:v];
        for(ZNSFloatingView *v in ordered) {
            CGRect desired=[v thumbnailFrameInSafe:safe],target=CGRectZero;
            if(v.restoringPosition) desired.origin=v.portraitFrame.origin;
            if(landscape && v.portraitSaved && v.portraitTier==v.thumbnailTier && CGSizeEqualToSize(v.portraitCanvas,v.session.canvasSize)) desired.size=v.portraitFrame.size;
            BOOL inScreen=CGRectContainsRect(v.thumbnailFree?self.controller.view.bounds:safe,desired);
            if((v.thumbnailFree || v.restoringPosition) && inScreen && ZNSFrameClear(desired,occupied,used)) target=desired;
            else if(v.restoringPosition || !ZNSFindParkedFrame(desired,safe,occupied,used,v.thumbnailRight,0,&target)) { victim=v; break; }
            occupied[used++]=target; targets[[NSValue valueWithNonretainedObject:v]]=[NSValue valueWithCGRect:target];
        }
        if(!victim) {
            unsigned thumbnailCount=used;
            // Use the same safe area as parked thumbnails on ALL edges.
            // Restoring physical x/width puts landscape icons under the status
            // bar/notch region even though their vertical positions are safe.
            CGRect iconSafe=safe;
            NSUInteger icons=0;
            for(ZNSFloatingView *v in items) if(v.docked) icons++;
            CGFloat iconSize=fmin(ZNSParkedIconSize(),fmin(iconSafe.size.width,iconSafe.size.height));
            while(iconSize>16 && floor((iconSafe.size.width+6)/(iconSize+6))*floor((iconSafe.size.height+3)/(iconSize+3))<icons) iconSize-=2;
            for(ZNSFloatingView *v in items) if(v.docked) {
                CGRect desired=CGRectMake(v.frame.origin.x,v.frame.origin.y,iconSize,iconSize),target;
                if(!ZNSFindIconFrame(desired,iconSafe,occupied,used,thumbnailCount,v.thumbnailRight,&target)) {
                    for(ZNSFloatingView *other in items) if(other.thumbnail && !other.thumbnailFree) { victim=other; break; }
                    if(!victim) {
                        // No fixed thumbnails remain: repack only icons. Keep
                        // every free overlay's independently constrained target.
                        NSUInteger index=0;
                        for(ZNSFloatingView *icon in items) if(icon.docked) {
                            CGRect grid=ZNSIconGridFrame(iconSafe,(unsigned)icons,(unsigned)index++);
                            targets[[NSValue valueWithNonretainedObject:icon]]=[NSValue valueWithCGRect:grid];
                        }
                    }
                    break;
                }
                occupied[used++]=target; targets[[NSValue valueWithNonretainedObject:v]]=[NSValue valueWithCGRect:target];
            }
        }
        if(!victim) break;
        if(landscape && victim.portraitSaved) victim.rotationOverflow=YES;
        if(landscape && victim.thumbnailTier==1) {
            // A second-tier space overflow is an icon whose next thumbnail is
            // first tier, both on tap and on automatic portrait restoration.
            victim.thumbnailTier=0; victim.thumbnailFree=NO;
            victim.portraitTier=0; victim.portraitCanvas=CGSizeZero;
            victim.restoringPosition=NO;
        }
        [self collapseParkedToIcon:victim];
    }
    free(occupied);
    for(ZNSFloatingView *view in items) {
        NSValue *value=targets[[NSValue valueWithNonretainedObject:view]];
        if(!value || view.parkedPan) continue;
        CGRect target=value.CGRectValue;
        if(view.thumbnail) view.rotationOverflow=NO;
        if(!view.thumbnail) view.restoringPosition=NO;
        [view setNeedsLayout];
        if(!CGRectEqualToRect(view.frame,target)) {
            [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled()?0:0.18 delay:0 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction|UIViewAnimationOptionCurveEaseOut animations:^{
                view.frame=target; [view layoutIfNeeded];
            } completion:nil];
        } else [view layoutIfNeeded];
    }
    [self updateWindowStack];
    self.arranging=NO; [self updateOutsideButton];
}
#endif
