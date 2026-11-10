"""Production C policies + actual preference wiring, with assertion-only mutations."""
import pathlib,plistlib,json,subprocess,tempfile,shutil
R=pathlib.Path(__file__).resolve().parents[1]
P=R/'Sources'
rows=plistlib.loads((R/'Preferences/Resources/Root.plist').read_bytes())['items']
by={x.get('key'):x for x in rows if 'key' in x}
old=plistlib.loads(subprocess.check_output(['git','show','534396f393bc9bdadb3ae91f42c924c40e42620c:Preferences/Resources/Root.plist'],cwd=R))['items']
for row in old:
 if row.get('key') not in ('WindowEntryAnimation','WindowExitAnimation'):assert row in rows
for key in ('WindowEntryAnimation','WindowExitAnimation'):
 row=by[key];base=next(x for x in old if x.get('key')==key)
 for field in ('validValues','validTitles'):assert row[field][:len(base[field])]==base[field]
 assert row['default']==base['default'] and row['PostNotification']=='com.zengniu.splitview/changed'
 keys=row['validValues'][len(base['validValues']):]
 assert len(keys)==18 and len(set(keys))==18 and all(x.startswith('fx_') for x in keys)
 assert all('自研近似' in x for x in row['validTitles'][len(base['validTitles']):])
 if key=='WindowEntryAnimation':entry=keys
 else:assert keys==entry
fixture='static const char *znsScreenKeys[]={'+','.join(json.dumps(k) for k in keys)+'};\n'
opening=(P/'ZNSWindowOpening.m').read_text();exit=(P/'ZNSExitShatter.m').read_text();renderer=(P/'ZNSScreenEffects.m').read_text()
assert 'ZNSScreenEffectCreate(frozen,(int)style-ZNSEntryScreenFirst,YES,scale)' in opening
assert 'ZNSScreenEffectCreate(self.znsFrozen,(int)self.znsStyle-ZNSExitScreenFirst,NO,self.znsScale)' in exit
assert 'if(!s.znsSurface) style=ZNSEntryFade' in opening and 'self.znsStyle=ZNSExitFade;[self znsPlaySelected:token];return;' in exit
assert 'ZNSWindowOpeningCancelAll();' in opening and 'ZNSShatterFinish(&current->znsLife' in exit
assert 'ZNSScreenBuild((__bridge void *)make,effect,ops)' in renderer
assert 'ZNSScreenPoseAt(effect,i,w,h,t,entry)' in renderer and 'ZNSScreenRectAt(effect,i,w,h,&r)' in renderer
assert 'ZNSShatterReservePixels(&pixels' in renderer and 'ZNSShatterSourcePixels' in renderer
for forbidden in ('CADisplayLink','renderInContext','drawViewHierarchy','afterScreenUpdates:YES','writeToFile','makeKeyAndVisible'):
 assert forbidden not in renderer+opening
assert 'view.transform=' not in opening and 'view.alpha=' not in opening
assert '[self.znsSurface removeFromSuperview];self.znsSurface=nil;' in opening
print('PASS old preference rows/defaults retained; 18x2 actual picker mappings; production render/build; entry failure fade and generation cleanup; no live model writes/readback/per-frame drawing',flush=True)
mutations=[
 ('cap','ZNSScreenEffectPolicy.h','#define ZNSScreenMaxTiles 64','#define ZNSScreenMaxTiles 640'),
 ('gap','ZNSScreenEffectPolicy.h','w*(c+1)/cols-x','(w*(c+1)/cols-x)*.9'),
 ('nan','ZNSScreenEffectPolicy.h','double x=w*c/cols','double x=NAN'),
 ('entry-end','ZNSScreenEffectPolicy.h','if((entry && t==1) || (!entry && t==0))','if((entry && t==0) || (!entry && t==0))'),
 ('exit-alpha','ZNSScreenEffectPolicy.h','p.alpha=0;','p.alpha=1;'),
 ('crt-axis','ZNSScreenEffectPolicy.h','p.sy=fmax(.008,1-q*1.8)','p.sy=1'),
 ('ash-direction','ZNSScreenEffectPolicy.h','p.dy=-h*(.18+u*.27)*q','p.dy=h*(.18+u*.27)*q'),
 ('partial-cleanup','ZNSScreenEffectPolicy.h','ops.discard(context);return false;','return false;'),
 ('entry-parser','ZNSWindowAnimationPolicy.h','ZNSEntryScreenFirst+effect','ZNSEntryScreenFirst'),
 ('exit-parser','ZNSWindowAnimationPolicy.h','ZNSExitScreenFirst+effect','ZNSExitScreenFirst'),
 ('reduce','ZNSWindowAnimationPolicy.h','return reduce && s!=ZNSEntryNone ? ZNSEntryFade : s;','(void)reduce; return s;'),
 ('stale','ZNSWindowAnimationPolicy.h','if(!s->active || token!=s->generation) return false;','(void)token; if(!s->active) return false;'),
 ('budget','ZNSExitShatterGeometry.h','area>ZNSShatterPixelBudget','false'),
]
CC=shutil.which('clang');assert CC
with tempfile.TemporaryDirectory() as tmp:
 for name,file,a,b in [('production',None,None,None)]+mutations:
  d=pathlib.Path(tmp)/name;d.mkdir()
  for header in ('ZNSScreenEffectPolicy.h','ZNSWindowAnimationPolicy.h','ZNSExitShatterLifecycle.h','ZNSExitShatterGeometry.h'):
   text=(P/header).read_text()
   if header==file:assert text.count(a)==1,(name,a);text=text.replace(a,b)
   (d/header).write_text(text)
  (d/'ZNSScreenSettingsFixture.h').write_text(fixture)
  subprocess.run([CC,'-std=c11','-Wall','-Wextra','-Werror','-I',str(d),str(R/'tools/ScreenEffectTests.c'),'-lm','-o',str(d/'test')],check=True)
  p=subprocess.run([str(d/'test')],capture_output=True,text=True)
  if file:assert p.returncode==-6 and 'assert' in p.stderr.lower(),(name,p.stderr);print('PASS assertion rejects screen mutation:',name,flush=True)
  else:assert p.returncode==0,p.stderr;print(p.stdout,end='',flush=True)
print('PASS 13/13 screen policy mutations; UIKit/compositor remains device-only',flush=True)
