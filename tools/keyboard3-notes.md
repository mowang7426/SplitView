# keyboard3 regression candidate (0.7.66+keyboard3)

## Evidence and limits

The supplied reference and keyboard2-failure contact sheets were inspected. The failure recording demonstrates a narrow keyboard/window and jumps; it cannot identify a private-API rejection or prove an event order. No device installation, respring, release, or on-device validation is performed by this change.

Source-proven failure paths in keyboard2:
- `portraitPresentation` required `clientKeyboardShown` for the only grace path after `updateTemporaryPortraitCanvas` detached the owned surface. A surface can already be verified/visible before the asynchronous App `shown` hint. Canvas update then removes `externalKeyboardVisible`, so both presentation gates fail and manager restores the scene. The former transaction tests replaced placement with a request counter and could not detect this path.
- The PID-scoped `geometry-changed` callback unconditionally restored the surface when a failed/zero or old-canvas sample differed from the prior geometry. Client `ZNSClientPublishGeometry` explicitly publishes invalid data while scene/window dimensions or responder availability are temporarily inconsistent. This is not a hide notification, but previously caused the same detach/republication path.
- Geometry-only publication suppressed an unchanged valid presentation forever after manager readiness/layoutInFlight rejected its first event. The floating method also had no same-target no-op. Generic manager restore set explicit-action suppression, while every nil-bundle event cleared it, conflating transient transport loss, genuine hide and deliberate gestures.

The existing `ZNSKeyboardShow` and `ZNSKeyboardSetFrame` hooks also detached directly before reconciliation, bypassing canvas-refresh continuity. They now call the same tested helper that arms grace before the original detach; no new hooks or broader interception were added.

The grace was also armed only AFTER the host setter. The setter can synchronously run frame/show/hide hooks before the subsequent placement update; keyboard3 arms the existing verified presentation BEFORE that mutation. A failed native show hint in this bounded reparent interval is not treated as an App hide while exact focus and nonempty live input remain proven. The event test explicitly simulates this synchronous setter callback and asserts that a PID-validated App hide still terminates it.

Changes keep strict focus/ownership and private-API ABI checks. A bounded 1.2-second grace uses previously verified surface visibility, not a not-yet-delivered process hint. Invalid/old-canvas samples do not detach a good portrait surface. SpringBoard hide hints during verified local reparent defer to the PID-validated App hide; genuine App hide clears grace immediately. Client native-coordinate re-sampling is bounded and canceled by hide. Unchanged presentations retry manager readiness without restarting animations. Transient transport loss does not create or clear explicit suppression; real termination clears it.

The screen-width/18%-top geometry, real scene frame/reference-size transaction, original frame snapshots, native keyboard avoidance, orientation behavior, authorization and preference writers remain in place. No synthetic UIKeyboard notification, forced foreground activation, configuration write, or expanded hook scope is introduced. Initial surface geometry and runtime host/scene API acceptance remain device-dependent candidates, not asserted causes of the recording.

## Executable coverage

`PortraitEventTests.m` includes actual `ZNSPortraitPlacement.inc`, `ZNSPortraitFloating.inc`, `ZNSPortraitManager.inc` and `ZNSPortraitScene.inc`. It runs show-before-client-visibility -> scene/canvas change -> invalid/old geometry -> refresh -> persistent expansion -> App hide/restoration, plus reparent vs hide, exact focus loss, deferred manager eligibility, bounded expiry/retry, explicit gesture suppression, lifecycle and API rejection. UIKit surface remount/rendering is MOCKED, not device-tested.

`portrait_runtime_checks.py` extracts and executes the real scene ABI/type-check functions (instance vs metaclass, inherited methods, return/arity/block rejection). Three deliberately faulty mutations must trigger assertions: shown race, invalid-geometry detach, repeated animation. Static safeguards are supplemental, not the regression test itself.

`GeometryTests`, `DipGeometryTests`, `SecondTierPolicyTests` retain their known baseline failures; comparison must show the same failure output, not reclassify them as passing.

## Device diagnostics

Unified logging uses existing subsystem `com.zengniu.splitview`, category `windows` (client dismiss category remains `keyboard-client`). Placement rejection diagnostics are limited to one per second, eight seconds for the same reason; manager gate reporting is limited to one every two seconds. Transaction logging occurs only on a scene request/ack/failure, not every layout. Records contain fixed reason codes, flags and dimensions, no chat content, responder text, screenshots or preference writes.

Useful codes: `P3_REFRESH_BEGIN`, `P3_GEOMETRY_PENDING`, `P3_GEOMETRY_OLD_CANVAS`, `P3_SYSTEM_HIDE_DURING_REPARENT`, `P3_CLIENT_HIDE`, `P3_TARGET_GEOMETRY_REJECT`, `P3_MANAGER_GATE`, `P3_SCENE_GATE`, `P3_SCENE_UPDATE_ABI_REJECT`, `P3_HOST_CANVAS_ABI_REJECT`, `P3_SCENE_ACK`. Existing acknowledgment-rejected/timed-out/restore-failure messages remain. `P3_SCENE_ACK` confirms settings/reference-size checks, NOT rendered pixels.

If the new package still fails, collect a short live unified-log session for that subsystem covering open input -> wait -> hide, with iOS version, orientation and current keyboard placement option. Do not change preferences, install tools, or perform respring automatically. On a host with Apple's `log` command, a suitable read-only filter is:

```sh
log stream --level info --style compact --predicate 'subsystem == "com.zengniu.splitview"'
```

A future device acceptance pass must verify native-size chat controls at keyboard width, input bar touching keyboard top, approximately 18% desktop retained, original size/location restoration, and no regression in landscape external input. Neither CI nor mock assertions establish animation smoothness or iOS 16.2/17.0 runtime compatibility.
