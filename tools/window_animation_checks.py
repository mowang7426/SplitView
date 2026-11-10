"""Execute production parser/dispatcher/lifetime using values from the actual plist.
UIKit and remote compositor rendering remain device-only; source guards supplement,
not replace, runtime host tests and assertion-only mutations.
"""
import json
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
R=pathlib.Path(__file__).resolve().parents[1]
P=R/'Sources/ZNSWindowAnimationPolicy.h'
rows=plistlib.loads((R/'Preferences/Resources/Root.plist').read_bytes())['items']
base=plistlib.loads(subprocess.check_output(['git','show','1e278b7:Preferences/Resources/Root.plist'],cwd=R))['items']
assert [x for x in rows if x in base]==base, 'pre-existing preference rows/order must remain unchanged'
bykey={x.get('key'):x for x in rows if 'key' in x}
page='root';pages={}
for row in rows:
    page=row.get('ZNSPage',page)
    if 'key' in row: pages[row['key']]=page
fixture=''
for key,short in [('WindowExitAnimation','Exit'),('WindowEntryAnimation','Entry')]:
    row=bykey[key]
    assert pages[key]=='animations'
    assert row['cell']=='PSLinkListCell' and row['detail']=='PSListItemsController'
    assert row['defaults']=='com.zengniu.splitview' and row['PostNotification']=='com.zengniu.splitview/changed'
    assert len(row['validValues'])==len(row['validTitles'])
    fixture+='static const char *zns'+short+'Values[]={'+','.join(json.dumps(x) for x in row['validValues'])+'};\n'
    fixture+='static const char *zns'+short+'Default='+json.dumps(row['default'])+';\n'
m=(R/'Sources/ZNSWindowManager.m').read_text()
tweak=(R/'Sources/Tweak.m').read_text()
assert 'notify_register_dispatch("com.zengniu.splitview/changed"' in tweak and 'reloadPreferences]' in tweak
assert 'CFSTR("WindowExitAnimation")' in m and 'CFSTR("WindowEntryAnimation")' in m
assert 'ZNSSelectedExitStyle=ZNSParseExitStyle' in m and 'ZNSSelectedEntryStyle=ZNSParseEntryStyle' in m
assert 'ZNSDispatchExit(&context,ZNSWindowExitOps,ZNSSelectedExitStyle,UIAccessibilityIsReduceMotionEnabled())' in m
assert 'ZNSWindowOpeningReady(view,ZNSSelectedEntryStyle,view.ready && view.session.hostView!=nil' in m
assert m.count('[manager animateOpening:current]')==1 and '[self animateOpening:view]' not in m
assert m.count('if(opening) opening(')==2  # normal ready + prepared host
assert m.count('view.znsNewHostReadyCompletion=^(BOOL success)')==1
attach=m.split('- (void)attachHost {',1)[1].split('- (void)setStackCovered:',1)[0]
assert 'Opening' not in attach and 'animateOpening' not in attach
assert m.count('view.znsNewHostReadyCompletion=nil; ZNSWindowOpeningCancel(view)')>=3
assert 'ZNSWindowOpeningCancel(self)' in m and 'ZNSWindowOpeningCancelAll()' in m
opening=(R/'Sources/ZNSWindowOpening.m').read_text()
assert 'view.transform=' not in opening and 'view.alpha=' not in opening
assert 'ZNSOpeningReady(&s->znsLife,true,hostReady' in opening
assert 'ZNSOpeningFinish(&current->znsLife,token)' in opening
assert 'removeAllAnimations' not in opening
helper=(R/'Sources/ZNSExitShatter.m').read_text()
assert 'presentation.znsStyle=style' in helper
assert 'current.znsStyle==ZNSExitReference && ![current znsBuildReference]' in helper
assert 'ZNSExitMotionPlan(self.znsStyle' in helper
assert 'ZNSReferenceBands' in helper and 'ZNSReferenceDelay(i)' in helper
assert 'ZNSShatterReservePixels(&pixels,w*(end-y)' in helper
print('PASS integration: existing plist preserved; native authorized picker page; Darwin -> CFPreferences -> production parsers/dispatch; ready-only new main windows, no attach/layout/restore trigger; cancellation hooks; frozen-only budgeted reference crops',flush=True)
CC=shutil.which('clang');assert CC
mutations=[
('unknown-exit-default','return ZNSExitShatter;\n}', 'return ZNSExitNone;\n}'),
('none-captures','if(style==ZNSExitNone) { ops.close(context); return; }','if(false) { ops.close(context); return; }'),
('exit-reduce-ignored','return reduce && s!=ZNSExitNone ? ZNSExitFade : s;','(void)reduce; return s;'),
('entry-reduce-ignored','return reduce && s!=ZNSEntryNone ? ZNSEntryFade : s;','(void)reduce; return s;'),
('restores-replay','if(s->consumed || !newWindow) return 0;','(void)newWindow; if(s->consumed) return 0;'),
('host-ready-ignored','if(!hostReady || !eligible || style==ZNSEntryNone) return 0;','(void)hostReady; if(!eligible || style==ZNSEntryNone) return 0;'),
('old-task-finishes-new','if(!s->active || token!=s->generation) return false;','(void)token; if(!s->active) return false;'),
('cancel-not-consumed','s->consumed=true;s->active=false;++s->generation;','s->consumed=false;s->active=false;++s->generation;'),
('reference-no-collapse','case ZNSExitReference:p.sx=.06;','case ZNSExitReference:p.sx=1;'),
]
def run(folder):
    binary=folder/'host'
    subprocess.run([CC,'-std=c11','-Wall','-Wextra','-Werror','-I',str(folder),str(R/'tools/WindowAnimationTests.c'),'-lm','-o',str(binary)],check=True)
    return subprocess.run([str(binary)],capture_output=True,text=True,timeout=30)
with tempfile.TemporaryDirectory(prefix='zns-animation-tests-') as tmp:
    root=pathlib.Path(tmp)
    for name,old,new in [('production',None,None)]+mutations:
        d=root/name;d.mkdir();text=P.read_text()
        if old:
            assert text.count(old)==1,name
            text=text.replace(old,new)
        (d/P.name).write_text(text)
        (d/'ZNSAnimationSettingsFixture.h').write_text(fixture)
        result=run(d)
        if old:
            assert result.returncode==-6 and 'assert' in result.stderr.lower(), (name,result.returncode,result.stderr)
            print('PASS assertion rejects mutation:',name,flush=True)
        else:
            print(result.stdout,end='',flush=True);assert result.returncode==0,result.stderr
print('PASS 9/9 production mutations; no UIKit/GPU/device claim',flush=True)
