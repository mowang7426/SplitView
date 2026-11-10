"""Execute actual production C policy; compiled assertion-rejected mutations only."""
import pathlib,shutil,subprocess,tempfile
R=pathlib.Path(__file__).resolve().parents[1]
mutations=[
 ('oversize','#define ZNSFineDiameter 3.0','#define ZNSFineDiameter 12.0'),
 ('mask-budget','#define ZNSFineMaskWidth 128','#define ZNSFineMaskWidth 256'),
 ('birth-budget','#define ZNSFineBirthRate 1800','#define ZNSFineBirthRate 18000'),
 ('tail-cut','#define ZNSFineDuration 1.08','#define ZNSFineDuration .8'),
 ('frame-resize','w<=640','w<=1640'),
 ('height-resize','h<=1280','h<=2280'),
 ('stop-emission','elapsed<ZNSFineEmitDuration','elapsed<1000'),
 ('cancel-emission','return active && elapsed','return (active || !active) && elapsed'),
 ('stale-token','generation==token','generation!=token'),
 ('cancel-start','return active && generation','return (active || !active) && generation'),
 ('capture-failure','&& captured &&','&& (captured || !captured) &&'),
 ('reduce-motion','&& !reduce &&','&& (reduce || !reduce) &&'),
 ('erosion-direction','.72*(x+.5)','.72*(ZNSFineMaskWidth-x-.5)'),
 ('end-mask','if(frame>=ZNSFineMaskFrames-1) return 0;','if(frame>=ZNSFineMaskFrames-1) return 255;'),
]
with tempfile.TemporaryDirectory() as tmp:
 for name,old,new in [('production',None,None)]+mutations:
  d=pathlib.Path(tmp)/name;d.mkdir()
  for src in (R/'Sources').glob('*.h'):
   text=src.read_text()
   if src.name=='ZNSFineParticlePolicy.h' and old:
    assert text.count(old)==1,name
    text=text.replace(old,new)
   (d/src.name).write_text(text)
  subprocess.run([shutil.which('clang'),'-std=c11','-Wall','-Wextra','-Werror','-I',str(d),str(R/'tools/FineParticleTests.c'),'-lm','-o',str(d/'test')],check=True)
  p=subprocess.run([str(d/'test')],capture_output=True,text=True)
  if old: assert p.returncode==-6 and 'assert' in p.stderr.lower(),(name,p.returncode,p.stderr)
  else: assert p.returncode==0,p.stderr
  print('PASS',name,flush=True)
code=(R/'Sources/ZNSFineParticles.inc').read_text()
checks=['emitter.birthRate=0;', 'gate.values=@[@1,@0,@0]', 'ZNSFineEmitDuration/ZNSFineDuration',
 'self.znsEmitter.birthRate=ZNSFineRate(0,false)', 'self.znsEmitter.emitterCells=nil',
 '[self.znsEmitter removeFromSuperlayer]', 'self.znsFrozen.layer.mask=nil',
 '!CGSizeEqualToSize(self.bounds.size,self.znsFrozen.bounds.size)', '[self znsStop];self.hidden=YES',
 'cell.scale=ZNSFineDiameter/12', 'cell.scaleRange=ZNSFineDiameterRange/12',
 'cell.birthRate=ZNSFineRate(0,true)', 'cell.velocity=100', 'cell.alphaSpeed=-2.8']
def wired(s): return all(c in s for c in checks)
assert wired(code)
for check in checks: assert not wired(code.replace(check,'')),check
assert 'snapshotView' not in code and 'drawViewHierarchy' not in code
assert 'CADisplayLink' not in code and 'NSTimer' not in code
print('PASS 14 compiled policy mutations + 14 supplementary source-wiring deletion checks; not UIKit/GPU execution')
