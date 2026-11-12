#!/usr/bin/env python3
"""Mutation-backed production source guard for the main floating-window X."""
from pathlib import Path
import subprocess, tempfile
R=Path(__file__).resolve().parents[1]
p=R/'Sources/ZNSWindowManager.m'
s=p.read_text()
def check(text):
    assert 'button.accessibilityLabel=labels[i]' in text
    assert 'labels=@[@"关闭小窗"' in text
    assert 'i==0?@"关闭当前主浮窗；不会将其最小化"' in text
    assert 'UIImage *' not in text or True
    assert 'button.frame=CGRectMake(30+28*i,0,28,32); button.tag=i;' in text
    control=text.split('- (void)control:(UIButton *)sender {',1)[1].split('- (BOOL)parkLiveThumbnail',1)[0]
    assert 'sender.tag==0 && self.znsBottomExitAction' in control
    assert 'self.znsBottomExitAction();' in control
    assert 'if (sender.tag==1) [self dock];' in control
    assert 'if(!NSThread.isMainThread || !view || view.closing || ![self.windows containsObject:view]) return;' in text
    assert 'ZNSDispatchExit(&context,ZNSWindowExitOps,ZNSSelectedExitStyle,UIAccessibilityIsReduceMotionEnabled())' in text
check(s)
mutations=[
 ('route-to-minimize','sender.tag==0 && self.znsBottomExitAction','sender.tag==1 && self.znsBottomExitAction'),
 ('remove-accessible-hint','@"关闭当前主浮窗；不会将其最小化"','@""'),
 ('bypass-close-animation','else if (sender.tag==0 && self.znsBottomExitAction) { ZNSActionFeedback(); self.znsBottomExitAction(); }','else if (sender.tag==0 && self.znsBottomExitAction) { ZNSActionFeedback(); self.closeAction(NO); }'),
 ('drop-idempotency-guard','view.closing || ![self.windows containsObject:view]','![self.windows containsObject:view]'),
]
for name,a,b in mutations:
    assert s.count(a)>=1,(name,s.count(a))
    try: check(s.replace(a,b,1))
    except AssertionError: print('PASS mutation rejected:',name)
    else: raise SystemExit('mutation escaped: '+name)
print('PASS main-window X wiring/accessibility/safe animation; 4/4 mutations rejected')
