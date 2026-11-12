"""Compile/run real production C helpers, then assertion-only mutation checks.
Does not claim to emulate UIKit compositor, remote App surfaces or GPU timing.
"""
import os
import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
BASE = '01896574439233512bc9b141f03cd7a2392f23e0'
CC = shutil.which('clang')
assert CC, 'clang required'


def run_tests(include, binary):
    subprocess.run([CC, '-std=c11', '-Wall', '-Wextra', '-Werror', '-I', str(include),
                    str(ROOT / 'tools/ExitShatterTests.c'), '-lm', '-o', str(binary)], check=True)
    return subprocess.run([str(binary)], capture_output=True, text=True, timeout=45)


# Preserve exact deep watchdog/focus/authorization sources. Keyboard16 owns the
# process-wide scene ambiguity gate in ZNSKeyboardClient.m; all other protected
# sources remain byte-identical to the deep-watchdog baseline.
for path in sorted((ROOT / 'Sources').iterdir()):
    if any(key in path.name for key in ['Keyboard', 'Portrait', 'Authorization', 'LandscapeIconGrid', 'SceneSession']) and path.name != 'ZNSKeyboardClient.m':
        baseline = subprocess.check_output(['git', 'show', BASE + ':Sources/' + path.name], cwd=ROOT)
        assert path.read_bytes() == baseline, 'baseline source changed: ' + path.name
manager = (ROOT / 'Sources/ZNSWindowManager.m').read_text()
bar = manager.split('- (void)barTapped:', 1)[1].split('- (void)restoreChromeOpacity', 1)[0]
assert 'gesture.view==self.bottomBar && self.znsBottomExitAction' in bar
assert manager.count('self.znsBottomExitAction()') == 1
assert manager.count('ZNSExitShatterPresent(view)') == 1
entry = manager.split('- (void)znsCloseBottomTapped:(ZNSFloatingView *)view {', 1)[1].split('- (void)closeWindow:', 1)[0]
assert 'ZNSDispatchExit(&context,ZNSWindowExitOps,ZNSSelectedExitStyle,UIAccessibilityIsReduceMotionEnabled())' in entry
assert 'style==ZNSExitShatter?ZNSExitShatterPresent(view):ZNSExitAnimationPresent(view,style)' in manager
assert '[c->manager finishCloseWindow:c->view fullscreen:NO]' in manager
assert 'current.interactionGeneration==generation' in entry
helper = (ROOT / 'Sources/ZNSExitShatter.m').read_text()
for forbidden in ['afterScreenUpdates:YES', 'renderInContext:', 'drawViewHierarchyInRect:',
                  'dispatch_sync(', 'dispatch_semaphore_wait(', 'UIImagePNGRepresentation(',
                  'UIGraphicsBeginImageContext', 'writeToFile:', 'makeKeyAndVisible]',
                  'stopForFullscreen:', 'kill(', 'terminate', 'os_log(', 'NSLog(']:
    # Comments explicitly name prohibited approaches; only calls are forbidden.
    code = '\n'.join(line.split('//', 1)[0] for line in helper.splitlines())
    assert forbidden not in code, forbidden
assert 'resizableSnapshotViewFromRect:rect afterScreenUpdates:NO' in helper
assert 'self.znsFrozen resizableSnapshotViewFromRect:' in helper
assert 'source snapshotViewAfterScreenUpdates:NO' in helper
play_block = helper.split('- (void)znsPlay:(BOOL)scatter token:(uint64_t)token {', 1)[1].split('- (void)znsCancel {', 1)[0]
assert 'self.znsFrozen=nil' not in play_block
assert 'self.znsStage addSubview:self.znsFrozen' in play_block
assert 'self.znsFrozen=nil' in helper.split('- (void)znsDispose {', 1)[1]
assert 'ZNSShatterSourcePixels(' in helper and 'ZNSShatterReservePixels(' in helper
assert 'ZNSShatterBuild(&current->znsLife' in helper
assert 'znsHost.userInteractionEnabled=NO' in helper and 'ZNSSetLayerInputEnabled(self.znsHost.layer,NO)' in helper
assert 'hitTest:' in helper and 'return nil;' in helper
print('PASS integration guards: bottom-tap only, unchanged deep watchdog/keyboard/focus/auth sources, frozen-only crops, independent non-key/pass-through host, no redraw/readback/disk/sync wait/process kill', flush=True)

mutations = [
    ('stale-end-generation', 'ZNSExitShatterGeometry.h',
     'if(!s->active || s->generation!=token) return false;',
     '(void)token; if(!s->active) return false;'),
    ('stale-build-generation', 'ZNSExitShatterLifecycle.h',
     'if(!life->active || life->generation!=token) return;',
     'if(!life->active) return;'),
    ('partial-shards-not-cleared', 'ZNSExitShatterLifecycle.h',
     'ops.clearShards(context);', '(void)ops.clearShards;'),
    ('reduce-motion-ignored', 'ZNSExitShatterLifecycle.h',
     '    if(scatter) {', '    scatter=true; if(scatter) {'),
    ('upward-shards', 'ZNSExitShatterGeometry.h',
     'poly.dy=h*(0.22+', 'poly.dy=-h*(0.22+'),
    ('pixel-cap-removed', 'ZNSExitShatterGeometry.h',
     '*pixels+area>2.5*ZNSShatterPixelBudget', '*pixels+area>250*ZNSShatterPixelBudget'),
]
with tempfile.TemporaryDirectory(prefix='zns-shatter-host-') as tmp:
    tmp = pathlib.Path(tmp)
    result = run_tests(ROOT / 'Sources', tmp / 'tests')
    print(result.stdout, end='', flush=True)
    assert result.returncode == 0, result.stderr
    for name, filename, old, new in mutations:
        folder = tmp / name
        folder.mkdir()
        for header in ['ZNSExitShatterGeometry.h', 'ZNSExitShatterLifecycle.h']:
            text = (ROOT / 'Sources' / header).read_text()
            if header == filename:
                assert text.count(old) == 1, name
                text = text.replace(old, new)
            (folder / header).write_text(text)
        result = run_tests(folder, folder / 'tests')
        assert result.returncode == -6 and ('Assertion' in result.stderr or 'assertion' in result.stderr), (name, result.returncode, result.stderr)
        print('PASS mutation rejected by assertion:', name, flush=True)
print('PASS 6/6 mutations; original legacy baseline-comparison tests remain unchanged', flush=True)
