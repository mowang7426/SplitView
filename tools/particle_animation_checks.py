"""Real production particle policy/host tests and assertion-only mutations."""
import pathlib, plistlib, shutil, subprocess, tempfile
R=pathlib.Path(__file__).resolve().parents[1]
headers=['ZNSParticlePolicy.h','ZNSExitShatterGeometry.h','ZNSExitShatterLifecycle.h','ZNSWindowAnimationPolicy.h']
rows=plistlib.loads((R/'Preferences/Resources/Root.plist').read_bytes())['items']
row=next(x for x in rows if x.get('key')=='WindowExitAnimation')
assert row['validTitles'][row['validValues'].index('particles')]=='粒子消散'
assert row['validTitles'][row['validValues'].index('reference')]=='参考·向右消散（近似）'
assert row['default']=='shatter'
code=(R/'Sources/ZNSExitShatter.m').read_text()
assert 'ops.shard=ZNSParticleShardOp' in code and 'ZNSParticleBuild(&current->znsLife' in code
assert 'if(!ZNSParticleBuild' in code and 'current.znsStyle=ZNSExitFade' in code
crop=code.split('- (BOOL)znsMakeParticle:(unsigned)index {')[1].split('- (void)znsClearShards')[0]
assert 'ZNSParticlePlan(' in crop and 'ZNSShatterReservePixels(' in crop
assert 'self.znsFrozen resizableSnapshotViewFromRect:rect afterScreenUpdates:NO' in crop
assert 'if(!tile) return NO' in crop
assert 'animateWithDuration:ZNSParticleDuration delay:particle.delay' in code
assert 'CGAffineTransformMakeTranslation(particle.dx,particle.dy)' in code
assert 'tile.alpha=0' in code and 'ZNSParticleMaxDelay:0' in code
assert 'UIAccessibilityReduceMotionStatusDidChangeNotification' in code
print('PASS particle wiring: distinct real picker, parser, frozen NO-update content crops, reserve before crop, partial failure fade, runtime plan/delay and inherited cancel/ReduceMotion',flush=True)
mutations=[
('count-unbounded','ZNSParticlePolicy.h','#define ZNSParticleColumns 10','#define ZNSParticleColumns 100'),
('coverage-gap','ZNSParticlePolicy.h','.w=w*(col+1)/ZNSParticleColumns-x','.w=.9*(w*(col+1)/ZNSParticleColumns-x)'),
('left-drift','ZNSParticlePolicy.h','.dx=w*(.12+','.dx=-w*(.12+'),
('delay-unbounded','ZNSParticlePolicy.h','#define ZNSParticleMaxDelay .18','#define ZNSParticleMaxDelay 1.8'),
('coordinates-nonfinite','ZNSParticlePolicy.h','.x=x,.y=y','.x=NAN,.y=y'),
('stale-particle-build','ZNSParticlePolicy.h','if(!life->active || life->generation!=token) return false;','(void)token; if(!life->active) return false;'),
('cancel-builds','ZNSParticlePolicy.h','if(!life->active || life->generation!=token) return false;','if(life->active && life->generation!=token) return false;'),
('partial-not-cleared','ZNSParticlePolicy.h','ops.clearShards(context);','(void)ops.clearShards;'),
('no-snapshot-accepted','ZNSExitShatterLifecycle.h','if(!ops.capture(context))','if(ops.capture(context))'),
('reduce-motion-particles','ZNSWindowAnimationPolicy.h','return reduce && s!=ZNSExitNone ? ZNSExitFade : s;','(void)reduce; return s;'),
('stale-completion','ZNSExitShatterGeometry.h','if(!s->active || s->generation!=token) return false;','(void)token; if(!s->active) return false;'),
('pixel-budget-removed','ZNSExitShatterGeometry.h','area>ZNSShatterPixelBudget','area>100*ZNSShatterPixelBudget'),
]
with tempfile.TemporaryDirectory(prefix='zns-particle-') as tmp:
 for name,filename,old,new in [('production',None,None,None)]+mutations:
    d=pathlib.Path(tmp)/name;d.mkdir()
    for header in headers:
        text=(R/'Sources'/header).read_text()
        if header==filename:
            assert text.count(old)==1,name
            text=text.replace(old,new)
        (d/header).write_text(text)
    subprocess.run([shutil.which('clang'),'-std=c11','-Wall','-Wextra','-Werror','-I',str(d),str(R/'tools/ParticleAnimationTests.c'),'-lm','-o',str(d/'host')],check=True)
    result=subprocess.run([str(d/'host')],capture_output=True,text=True,timeout=30)
    if old:
        assert result.returncode==-6 and 'assert' in result.stderr.lower(),(name,result.returncode,result.stderr)
        print('PASS assertion rejects particle mutation:',name,flush=True)
    else:
        assert result.returncode==0,result.stderr
        print(result.stdout,end='',flush=True)
print('PASS 12/12 particle mutations; UIKit/compositor/device behavior not emulated',flush=True)
