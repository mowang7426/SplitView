import pathlib, plistlib, json, subprocess
p=pathlib.Path(__file__).resolve().parents[1]
for f in (p/'Preferences').rglob('*.plist'):
    plistlib.loads(f.read_bytes())
manifest=json.loads((p/'apelin-project.json').read_text())
assert manifest['package']['version']=='0.7.66+keyboard12'
assert 'Version: 0.7.66+keyboard12' in (p/'control').read_text()
for name in ['Sources/ZNSAuthorization.h','Sources/ZNSKeyboardFocus.m','Preferences/ZNSRootListController.m','Sources/ZNSKeyboardPolicy.h']:
    original=subprocess.check_output(['git','show','e174b5232a0f7e18ed79c25e3e83481de507b0e7:'+name],cwd=p)
    assert (p/name).read_bytes()==original,name+' unexpectedly changed'
source=(p/'Sources/ZNSKeyboardPlacement.m').read_text()
for include in ['ZNSPortraitPlacement.inc','ZNSKeyboardRestore.inc','ZNSPortraitVisualEvent.inc']:
    source=source.replace('#include "'+include+'"',(p/'Sources'/include).read_text())
assert 'owner.portraitExpansion || ![owner externalKeyboardVisible]' in source
assert 'self.portraitExpansion=!landscape && !self.portraitExternal' in source
assert 'self.presentationTimingKnown?self.presentationDuration:0.25' in source
assert 'updateTemporaryPortraitCanvas:' in source
assert '@"geometry.request"' in source
assert source.count('[owner znsReparentForNativeKeyboardUpdate]')==2
client=(p/'Sources/ZNSKeyboardClient.m').read_text()
assert 'fromCoordinateSpace:window.screen.coordinateSpace' in client
assert 'ZNSClientPublishGeometry(ZNSLastKeyboardGeometryNote)' in client
assert 'ZNSLastKeyboardGeometryNote=nil' in client
# WillHide retains live geometry and emits a phase; only DidHide clears it.
clientHide=client[client.index('BOOL willHide='):client.index('NSString *name=ZNSKeyboardClientEvent(getpid(),@"dismiss")')]
assert clientHide.index('if (didHide) {') < clientHide.index('ZNSClientWriteGeometry(CGRectZero,CGSizeZero,NO)')
assert 'if (willHide) ZNSClientPost(@"will-hide")' in clientHide
manager=(p/'Sources/ZNSWindowManager.m').read_text()
for include in ['ZNSPortraitFloating.inc','ZNSPortraitManager.inc']:
    manager=manager.replace('#include "'+include+'"',(p/'Sources'/include).read_text())
assert 'self.portraitKeyboardSavedFrame=self.frame' in manager
assert 'self.portraitKeyboardSavedExpandedFrame=self.expandedFrame' in manager
assert 'UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction' in manager
assert 'ZNSPortraitKeyboardTarget(keyboard,root.bounds' in manager
assert 'self.content.frame=self.portraitKeyboardExpanded?self.bounds:' in manager
assert 'self.portraitKeyboardExpanded?ZNSPortraitCanvasTransform():' in manager
assert 'applyTemporaryPortraitFrame:screenFrame' in manager
restore=manager.split('- (void)restorePortraitKeyboardWithDuration:',2)[2].split('- (BOOL)isStackParticipant',1)[0]
assert restore.index('restoreTemporaryPortraitCanvas')<restore.index('self.portraitKeyboardExpanded=NO')<restore.index('NSTimeInterval effectiveDuration=')<restore.index('UIView animateWithDuration:effectiveDuration')
assert 'if (ownsFrame) strongSelf.frame=saved' in restore
assert restore.count('[strongSelf layoutIfNeeded]')==1
assert 'options:options|UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction' in restore
assert 'UIAccessibilityIsReduceMotionEnabled()?0:MAX(0,duration)' in restore
assert 'performWithoutAnimation:layout' in restore
assert 'snapshotViewAfterScreenUpdates:' not in restore
assert 'FBSSceneTransitionContext' not in restore and 'BSAnimationSettings' not in restore
assert 'portraitKeyboardRestoreGeneration' in restore and 'portraitKeyboardRestoring' in restore
assert 'ZNSPublishPortraitHide' not in source
willHide=source.split('- (void)znsClientWillHide {',1)[1].split('- (void)znsClientDidHide',1)[0]
assert 'postNotification' not in willHide and '[self restore]' not in willHide
assert 'P3_SYSTEM_WILL_HIDE_AWAIT_CLIENT' in source
assert '@"will-hide"' in source
assert 'portraitKeyboardVisibleLatch' in source
classifier=(p/'Sources/ZNSPortraitVisibilityEvent.inc').read_text()
assert '#include "ZNSPortraitVisibilityEvent.inc"' in source
assert 'ZNSPortraitVisibilityEvent(presentation,lastPresentation' in source
assert 'previous && continuity' in classifier and '@"continuity":@YES' in classifier
assert 'clientVisibilityKnown &&' in source and 'ZNSKeyboardMatchesFocus(self)' in source
assert 'view!=owner || (!eligible && !holdUnknown)' in manager
assert 'owner.portraitKeyboardExpanded' in manager and 'owner.activeManipulation' in manager
container=manager.split('- (void)fitAfterContainerChange {',1)[1]
assert container.index('!CGSizeEqualToSize') < container.index('[self restorePortraitKeyboardWithDuration:0 options:0]')
scene=(p/'Sources/ZNSSceneSession.m').read_text()
assert '#include "ZNSPortraitScene.inc"' in scene
assert 'if (![self restoreTemporaryPortraitCanvas])' in scene
transaction=(p/'Sources/ZNSPortraitScene.inc').read_text()
for forbidden in ['setKeyboardFocusActive:', '[self.keyboardFocus invalidate]', '[self.keyboardPlacement suspend]', 'ZNSSetSceneBackgrounded(', 'setInterfaceOrientation:', 'setDeviceOrientation:', 'CFPreferencesSet', 'contentInset', 'setContentInset', 'setTransform:', 'performSelector:', 'endEditing:', 'becomeFirstResponder', 'activateApplication']:
    assert forbidden not in transaction,forbidden
assert '[desired setFrame:frame]' in transaction
assert 'ZNSConfigureHostCanvas(self.hostView,frame.size' in transaction
assert 'owner.temporaryPortraitGeneration!=generation' in transaction
assert 'requestPortraitClientGeometry' in transaction
assert 'self.temporaryPortraitSettings=self.lease.settings' in transaction
assert '[restored setFrame:[original frame]]' in transaction
assert 'ZNSPortraitTransitionContext' not in scene+transaction
assert 'FBSSceneTransitionContext' not in scene and 'BSAnimationSettings' not in scene
assert 'withTransitionContext:nil completion:' in transaction.split('- (BOOL)restoreTemporaryPortraitCanvasWithDuration:',1)[1]
assert 'self.temporaryPortraitRestoring' in transaction
assert transaction.count('[self znsOwnsTemporaryPortraitGeneration:generation]')>=5
assert 'znsTemporaryPortraitStateMatchesFrame:' in transaction
assert transaction.count('[owner znsTemporaryPortraitStateMatchesFrame:frame]')==2
assert 'P7_SCENE_ACK_INFERRED' in transaction
assert '!owner.temporaryPortraitSettings || !owner.temporaryPortraitPending' in transaction
assert 'acknowledgment timed out; original canvas restored' not in transaction
apply=transaction.split('- (BOOL)applyTemporaryPortraitFrame:',1)[1].split('- (BOOL)restoreTemporaryPortraitCanvas',1)[0]
assert 'CGRectEqualToRect([applied frame],frame)' not in transaction
assert 'ZNSGeometryRectNear([applied frame],frame)' in transaction
assert 'ZNSHostCanvasMatches(self.hostView,frame.size' in transaction
assert 'fabs(actual-desired)<=0.5' in scene
publisher=(p/'Sources/ZNSPortraitVisualEvent.inc').read_text()
assert 'dispatch_async(dispatch_get_main_queue()' in publisher
assert 'ZNSPortraitKeyboardWillHideVisualNotification' in publisher
assert 'ZNSPublishPortraitVisualWillHideAsync(' in willHide
visual=(p/'Sources/ZNSPortraitFloating.inc').read_text().split('- (void)beginPortraitKeyboardVisualRestoreWithDuration:',1)[1].split('- (void)znsResumePortraitAfterHide',1)[0]
handler=(p/'Sources/ZNSPortraitManager.inc').read_text().split('- (void)portraitKeyboardWillHideVisual:',1)[1].split('- (void)portraitKeyboardGeometryChanged:',1)[0]
for block in [willHide,publisher,visual,handler]:
    for forbidden in ['restoreTemporaryPortraitCanvas','applyTemporaryPortraitFrame:', '[self restore]', 'ZNSPublishKeyboardVisibility(', 'snapshotViewAfterScreenUpdates:', 'FBSSceneTransitionContext', 'BSAnimationSettings', '[self layoutIfNeeded]', 'self.frame=', 'self.center=', 'self.bounds=']:
        assert forbidden not in block,forbidden
assert 'CGAffineTransformMake(' in visual and 'self.transform=visual' in visual
assert 'CGAffineTransformIsIdentity(self.transform)' in visual
assert 'UIView animateWithDuration:effectiveDuration' in visual
assert 'portraitKeyboardVisualRestoring && !self.portraitKeyboardVisualReturning' in visual
assert 'notification.object!=owner.session.keyboardPlacement' in handler
assert 'if (visualRestore || !ownsFrame || effectiveDuration<=0)' in restore
assert '[strongSelf clearPortraitKeyboardVisualRestore]' in restore
assert 'portraitKeyboardVisualFinalizePending=YES' in restore
# Both real close entry points must relinquish keyboard visual ownership before
# close animation/teardown takes the root transform or removes the session.
for selector, end, takeover in [
    ('closeWindow:', '- (void)finishCloseWindow:', '[view.layer removeAllAnimations]'),
    ('finishCloseWindow:', '- (void)close:(BOOL)', '[self.windows removeObject:view]')]:
    body=manager.rsplit('- (void)'+selector,1)[1].split(end,1)[0]
    guard='[view restorePortraitKeyboardWithDuration:0 options:0];'
    assert body.count(guard)==1
    assert body.index('![self.windows containsObject:view]') < body.index('view.closing=YES') < body.index(guard) < body.index(takeover)
assert 'if(fullscreen || UIAccessibilityIsReduceMotionEnabled()) { [self finishCloseWindow:view fullscreen:fullscreen]; return; }' in manager
print('PASS keyboard11 close entry ownership: membership guard, closing state, zero-duration visual cancellation before transform takeover/session teardown.')
assert 'ZNSPortraitKeyboardWillHideVisualNotification' in manager
print('PASS keyboard11 version/plists, unchanged authorization/focus/policy and safe scene logic; asynchronous owner-bound WillHide visual-only transform; scene/canvas restore after DidHide; keyboard8 fallback; no snapshot/private transition API. Source checks, not device rendering.')

# Layered visual implementation remains presentation-only, including descendants.
compensation=(p/'Sources/ZNSPortraitCompensation.inc').read_text()
for forbidden in ['.frame=', '.bounds=', '.center=', 'layoutIfNeeded', 'layoutHostInCanvas', 'applyTemporaryPortraitFrame:', 'restoreTemporaryPortraitCanvas', 'snapshotViewAfterScreenUpdates:', 'FBSSceneTransitionContext', 'BSAnimationSettings']:
    assert forbidden not in compensation,forbidden
assert 'ZNSPortraitVisualGeometryMake' in compensation
assert 'self.bodyBackground.transform=g.body' in compensation
assert 'self.content.transform=g.content' in compensation
assert 'self.canvasContainer.transform=g.canvas' in compensation
assert 'if (self.portraitKeyboardVisualRestoring || self.session.znsPortraitRestorePending) return;' in manager
assert 'self.content.userInteractionEnabled=!self.portraitKeyboardVisualRestoring && !self.thumbnail && !self.dipped;' in manager
assert 'CGRect fitted=ZNSPortraitFittedCanvas(self.content.bounds,canvas)' in manager
handoff=(p/'Sources/ZNSPortraitRestoreTransaction.inc').read_text()
assert handoff.index('if (prepareVisual) prepareVisual();')<handoff.index('BOOL configured=ZNSConfigureHostCanvas')
floating=(p/'Sources/ZNSPortraitFloating.inc').read_text()
assert 'self.session.znsPortraitRestorePrepareVisual=nil;' in floating
assert 'owner.portraitKeyboardRestoreGeneration==generation' in floating and '[owner znsClearPortraitCompensation];' in floating
cleanup=floating.split('- (void)clearPortraitKeyboardVisualRestore {',1)[1].split('- (void)beginPortraitKeyboardVisualRestore',1)[0]
assert 'self.transform=CGAffineTransformIdentity;' in cleanup and '[self znsClearPortraitCompensation];' in cleanup
assert cleanup.index('self.transform=CGAffineTransformIdentity;')<cleanup.index('[self znsClearPortraitCompensation];')
assert '[self znsClearPortraitCompensation]' in manager
print('PASS keyboard11 child compensation clears in prepare callback before host configuration; root clears on successful completion within no-animation handoff; geometry/events separately tested, not device pixels.')

assert 'BOOL sizeGraceExpired=attempt>=30;' in handoff
assert 'if (sceneMatches && (sizeAcknowledged || sizeGraceExpired))' in handoff
assert 'P12_SIZE_ACK_DEGRADED' in handoff
assert 'attempt>=4' in floating and 'NSEC_PER_SEC/10' in floating
assert 'owner.portraitKeyboardHideRetryGeneration!=token' in floating
assert 'manager.floating==live && [manager.windows containsObject:live]' in manager
assert 'sessionGuard()' in manager and 'owner.layoutGeneration==layout' in transaction
assert 'owner.clientPID==pid' in source and 'owner.portraitKeyboardVisualPhaseGeneration==phase' in source
print('PASS keyboard12 bounded size-confirmation degradation requires matched scene; bounded asynchronous hide retry with phase/PID/focus, generation, ownership, lifecycle and layout epoch guards; failure retains snapshot.')
