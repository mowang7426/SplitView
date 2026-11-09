"""Compile the production lifecycle include; mutations must fail assertions, not compilation."""
import pathlib, subprocess, tempfile, shutil
p=pathlib.Path(__file__).resolve().parents[1]
cc=shutil.which('clang') or shutil.which('cc')
assert cc
faults=[
 ('unknown-reader-still-stuck','epoch==s->layoutEpoch && guide==2 ? 2 : 0','epoch==s->layoutEpoch && guide==2 ? 0 : 0'),
 ('private-visible-ignored','if (live==1 || guide==1)','if (guide==1)'),
 ('guide-visible-ignored','if (live==1 || guide==1)','if (live==1)'),
 ('unpaired-didhide-accepted','s->completed=s->paired &&','s->completed=true &&'),
 ('native-end-onscreen-accepted','epoch==s->layoutEpoch && offscreen &&','epoch==s->layoutEpoch && (offscreen || true) &&'),
 ('willhide-onscreen-accepted','s->paired=owner && localDockedExit;','s->paired=owner && (localDockedExit || true);'),
 ('changed-layout-during-hide','epoch==s->layoutEpoch && offscreen &&','(epoch || true) && offscreen &&'),
 ('owner-changed-at-completion','owner && owner==s->owner && epoch==s->layoutEpoch','owner && epoch==s->layoutEpoch'),
 ('owner-changed-at-probe','s->hiddenPhase==current && owner && owner==s->owner &&','s->hiddenPhase==current && owner &&'),
 ('layout-changed-at-probe','epoch==s->layoutEpoch && guide==2','(epoch || true) && guide==2'),
 ('phase-changed-at-probe','expected!=current','false'),
 ('guide-uninitialized-accepted','epoch==s->layoutEpoch && guide==2','epoch==s->layoutEpoch && guide!=1'),
 ('double-completion-reused','s->paired=false; // one completion','s->paired=s->paired; // one completion'),
 ('close-show-rotation-not-revoked','s->willGeneration=0; s->hiddenPhase=0;\n    s->paired=false; s->completed=false;','s->willGeneration=0;\n    s->paired=false;'),
]
(p/'build').mkdir(exist_ok=True)
with tempfile.TemporaryDirectory() as td:
 root=pathlib.Path(td); (root/'tools').mkdir(); (root/'Sources').mkdir()
 for name in ['ZNSClientHiddenProof.inc','ZNSClientHideLifecycle.inc']:
  shutil.copy(p/'Sources'/name,root/'Sources'/name)
 shutil.copy(p/'tools/ClientHideLifecycleTests.c',root/'tools/ClientHideLifecycleTests.c')
 def run(name):
  binary=root/name
  subprocess.run([cc,'-Wall','-Wextra','-Werror',str(root/'tools/ClientHideLifecycleTests.c'),'-o',str(binary)],check=True)
  return subprocess.run([str(binary)],capture_output=True,text=True)
 baseline=run('baseline'); assert baseline.returncode==0,baseline.stderr
 print(baseline.stdout.strip())
 f=root/'Sources/ZNSClientHideLifecycle.inc'; original=f.read_text()
 for name,old,new in faults:
  assert original.count(old)==1,(name,original.count(old))
  f.write_text(original.replace(old,new))
  r=run(name)
  (p/'build'/('mutation-native-'+name+'.log')).write_text(r.stdout+r.stderr)
  assert r.returncode!=0 and ('Assertion' in r.stderr or 'assertion' in r.stderr),(name,r.returncode,r.stderr)
  print('PASS production mutation rejected by assertion:',name)
  f.write_text(original)
print('PASS 14 keyboard15 native lifecycle mutations; no compile-failure credit')
