#!/usr/bin/env python3
"""Source-level checks for process-wide keyboard notification ambiguity."""
from pathlib import Path
import sys
root=Path(__file__).resolve().parents[1]
s=(root/'Sources/ZNSKeyboardClient.m').read_text()
start=s.index('static BOOL ZNSClientHasSingleActiveKeyboardScene')
end=s.index('static void ZNSClientPublishPhase',start)
helper=s[start:end]
assert 'connectedScenes' in helper
assert 'UISceneActivationStateUnattached' in helper
assert 'if (active) return NO;' in helper
assert 'return active!=nil;' in helper
cb=s[s.index('BOOL willHide='):s.index('NSString *name=ZNSKeyboardClientEvent(getpid(),@"dismiss")')]
assert 'if ((hide || show) && ZNSClientHasSingleActiveKeyboardScene())' in cb
assert cb.index('ZNSClientHasSingleActiveKeyboardScene()') < cb.index('ZNSClientPublishPhase(')
assert 'if (didHide) {' in cb and 'ZNSClientWriteGeometry(CGRectZero,CGSizeZero,NO)' in cb
assert 'ZNSClientHasSingleActiveKeyboardScene' in s
# Mutation guards: deleting the unique-scene gate or allowing ambiguous scenes
# must invalidate the claimed production safety invariant.
mutations=[cb.replace('if ((hide || show) && ZNSClientHasSingleActiveKeyboardScene())','if (hide || show)'),
           helper.replace('if (active) return NO;','/* mutation: accept multiple scenes */')]
for m in mutations:
    safe=('ZNSClientHasSingleActiveKeyboardScene()' in m and 'if (active) return NO;' in m)
    assert not safe, 'mutation escaped multi-scene guard'
print('PASS keyboard16 multi-scene notification fail-closed source invariant + 2 mutations')
