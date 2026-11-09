# keyboard15 — native hide completion

Base: `29b67e999606149f9111e40c01d8daa6e2134a75` (keyboard14).
Version: `0.7.66+keyboard15`. No default branch, device installation, respring or Release changes.

## Evidence and scope

The new 12,370,645-byte recording is 6.043356 seconds, 886x1920. After initial 2fps extraction, exact seeks + Apple Vision OCR find keyboard keys at 2.0/3.0s. The split title normalized width is ~0.123 there, drops to ~0.085 at 3.4/3.6s, then grows to ~0.116 at 3.8s and ~0.123 at 4.0/5.8s. Its version text width grows from ~0.230 at 3.4s to ~0.333 at 4.0/5.8s. This supports a transient shrink followed by renewed enlarged presentation, NOT 'never shrinks at all'. No native image viewing was used. OCR alone cannot prove scene/settings/host frame transactions, target UIKit selector availability, phase messages, PID, or application bundle identity.

The observer also published a fresh Shown for every DidShow, including one delivered after a later Hidden. That can bypass keyboard14's genuinely-new-Shown requirement. Production now accepts DidShow only while the current phase is already Shown; a new WillShow remains able to reopen. This is a code-proven stale completion path, not a claim that this notification was captured from this recording.

keyboard14 makes Hidden a candidate and requires an App-process nonce/phase-bound proof. Its strict UIKeyboardImpl reader intentionally returns unknown for missing class/activeInstance/BOOL selectors or nil instance. Unknown is resampled indefinitely, so a real close has no recovery authority when that API is unsupported. This is a code-proven liveness defect; whether it is this device's exact trigger remains unproven.

## Added completion authority

`ZNSClientNativeHide.inc` runs only in the existing .app bridge on the main queue. A fallback absence proof needs ALL of:

- explicit local UIKit notes; a unique input scene/window bound during Show;
- paired WillHide/DidHide in the same native generation;
- WillHide begins with docked keyboard intersecting the owned window, and ends outside screen;
- DidHide end outside screen; same window, unchanged window/scene/screen layout epoch;
- the public window keyboardLayoutGuide was previously observed visible in this Show generation and is currently no larger than safe-area bottom;
- no current private-reader OR guide-visible evidence;
- the identical raw Hidden phase at request and response, plus existing PID/nonce/placement/focus/owner/visual-phase guards.

No timeout manufactures absence. No global dismissal, focus acquisition, fake UIKit notification, inset mutation, scene-backgrounding or text inspection is added. Unknown without full native evidence remains unknown. Nil reader alone remains unknown. New Show, background, orientation, changed layout/owner, on-screen frame or a current visible source revokes fallback permission. A post-hide stale surface still cannot revive placement: keyboard14's new-App-Shown authority is unchanged.

Existing client-size ACK grace/retries, applied scene ACK, compensation/host/completion order, continuity, authorization and dark-mode watchdog are untouched. Numeric, change-only os_log emits phase/reader/guide/owner-valid/completed/result; never text, responder identity, bundle, window pointer or frame.

## Tests and validation limits

- `tools/ClientHideLifecycleTests.c` includes actual production lifecycle/resolver includes, executes on local clang and CI. It covers permanent unknown/nil-reader semantics, both visible vetoes, no default-guide inference, native pairing, owner/epoch/phase changes, revocation and repeated cycles.
- `tools/native_hide_runtime_checks.py`: 16 compiled mutations must fail a runtime assertion, never credit a compiler failure.
- `tools/PortraitNativeHideTests.inc`: actual existing placement/manager/floating/scene-restore methods fed by the new production resolver, repeating unknown-reader close -> applied restore with missing size ACK -> new App Shown.
- Existing full production tests and prior mutations remain unchanged except adding the new lifecycle resolver to test transport. Existing three legacy baseline failures remain declared, not waived or weakened.
- UIKit adapter and notifications are not verified on this user's device. The fallback is intentionally conservative for floating/undocked keyboards, multiple scenes, missing begin/end frame, an unobserved keyboard guide or a resize during hide. These can still retain expansion; collect numeric hide-proof logs rather than add a timeout.

CI workflow remains 407431710, macos-15-intel / Xcode 16.4 / iPhoneOS16.5 SDK / RootHide arm64e; final outcome and artifact references belong in delivery report.
