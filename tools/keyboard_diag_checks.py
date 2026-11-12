#!/usr/bin/env python3
from pathlib import Path
p=Path(__file__).resolve().parents[1]
s=(p/'Sources/ZNSKeyboardDiag.m').read_text()
h=(p/'Sources/ZNSKeyboardDiag.h').read_text()
assert 'ZNSKeyboardDiag' in s and 'keyboard-diag' in s
for phase in ('WillShow','DidShow','WillChange','DidChange','WillHide','DidHide'):
    assert phase in h
for forbidden in ('keyboardText','inputText','responderAddress','bundleIdentifier','windowAddress'):
    assert forbidden not in s
assert 'allowed.invertedSet' in s and 's.length>32' in s
assert 'now-previous.doubleValue<0.12' in s
assert 'ZNS_KEYBOARD_DIAG_DEFAULT_ON' in s
assert 'ZNSKeyboardDiagDecision' in (p/'Sources/ZNSKeyboardPlacement.m').read_text()
print('PASS diagnostic schema/privacy/limit/production-path/default-gate invariants')
