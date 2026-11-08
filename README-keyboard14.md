# keyboard14: dismissal rebound guard

Base: `3c448511f51e4b194631b2d92e453f42ce9c0163` (keyboard13).
Version: `0.7.66+keyboard14`. Independent branch, no installation or release.

## Recording evidence, not an assumed unknown-interface stall

Input `video_E4880150.mp4`: 9.408333s, 886x1920, 1120 frames, 20,443,525 bytes.
Analysis uses ffmpeg timestamp sampling and Apple Vision OCR bounding boxes; no native video/image understanding is claimed.

The visible text identifies a Minis window showing the prior SplitView report, not a QQ conversation. At ~5.0-5.8s OCR detects nine-key labels (PQRS, 123). At ~5.9s these move down; by ~6.0s the sampled OCR no longer detects key labels. Content shrinks around 6.0-6.4s, then grows again around 6.5-6.8s and remains large through 9.0s, without OCR detecting a return of the keyboard. Example: width of `到原小窗` text is ~.176 of screen at 5.8s, ~.126 at 6.2-6.4s, then ~.176 at 6.7-6.8s. This supports a dismiss -> briefly small -> rebound pattern. Sampling uncertainty ~0.1s; OCR absence is not pixel-level proof. Device logs/actual phase/getter results are unavailable.

## Confirmed code defect and changes

The old `reconcile` unconditionally reconsidered a `keyboardHidden` owner after 0.4s if native inputViews + a still-visible layer existed. In portrait this bypassed the App's Hidden phase/proof. Such layers can persist after dismissal. Also, delayed valid geometry could set Shown/latch and clear keyboardHidden without checking the current phase. This is a reproducible code path consistent with the observed rebound, not proof of the device's unique root cause.

- Extract actual native recovery into `ZNSHiddenSurfaceRecovery.inc`. Portrait recovery requires current App Shown. Stale surface/inputViews cannot resurrect a Hidden/WillHide/Unknown owner. Existing nonportrait overlay recovery is retained; a fresh Shown still recovers.
- Reject geometry that would resurrect a confirmed hidden portrait owner unless raw App phase is Shown.
- Extract the actual read-only UIKeyboardImpl reader into `ZNSClientLiveVisibility.inc`. Validate class getter object return/arity and instance getter B/c BOOL return/arity before invoking the matching function pointer; integer/object ABI is unsupported. Any visible getter vetoes absence. Missing class, selectors or active instance remains Unknown, never absent. No sharedInstance instantiation, endEditing or responder mutation.
- Move the existing active-timer nonce invalidation into the tested production `znsResampleHiddenProof` method; keep the same 0.25s timer/reconcile chain. Unknown/visible is re-probed, never converted to absent by timeout.
- Retain keyboard6 continuity, keyboard7 scene acknowledgment, keyboard12 30-tick client-size-only degradation (scene still required), bounded retries, compensation/host/completion handoff order and the dark-mode watchdog.

## Verification contract

Host tests directly include the production placement/recovery/manager/floating/scene code; only transport/rendering are mocked. New sequence: confirmed absence -> small handoff without client-size ACK -> 20 ticks of stale live layer + valid delayed geometry -> still small -> fresh Shown expands -> genuine close restores again. Cover Shown/WillHide/Unknown, nonportrait recovery, PID/verified PID/focus/inactive/suspend/invalidated/dead host. Existing owner/phase/layout epoch/close/rotate/handoff tests remain.

A separate Objective-C runtime suite compiles the production reader with fake classes covering B/c ABI, inherited getters, nil/missing/wrong methods and contradictory visibility. Mutation checks must compile and fail with runtime assertions; compiler failures are not accepted as kills. New mutations remove the surface/geometry phase guards, permanently disable recovery, disable re-sampling, break either BOOL ABI, treat nil as absence, remove visible veto, or invoke an unsupported integer ABI.

Three legacy baseline failures remain explicitly nonpassing: GeometryTests, DipGeometryTests, SecondTierPolicyTests. No assertions or exceptions were relaxed.

## Limits

CI is not device validation. In particular, actual target UIKit selector availability/results and remote-surface lifetime are unknown. An implementation that always returns Unknown can still retain expansion after a true dismissal; this patch does not manufacture absence to conceal that limitation. The observed brief shrink/rebound is a separate path and is now regression-tested. Test on Minis and QQ: sustained input must stay expanded; actual dismissal must restore and remain small for >5 seconds; repeat show/hide plus focus/rotate/close. Do not claim device-verified repair from CI alone.
