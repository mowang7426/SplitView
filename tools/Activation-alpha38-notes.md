# alpha38 activation interface notes

Source-only investigation; no compilation, installation or on-device runtime/UI probe in this round.

## Public declarations consulted

- https://github.com/MTACS/iOS-17-Runtime-Headers/blob/main/PrivateFrameworks/SpringBoardHome.framework/SBIconView.h
  - `- (void)_handleTap` (no parameter), `isEnabled`, `isEditing`, `tapGestureDidChange:`.
- https://github.com/MTACS/iOS-17-Runtime-Headers/blob/main/PrivateFrameworks/SpringBoard.framework/SpringBoard.h
  - `isShowingHomescreen`, `_simulateHomeButtonPressWithCompletion:`.
  - `_applicationOpenURL:withApplication:animating:activationSettings:origin:withResult:`.
- SBUIController's header in the same repository does not declare the Home simulation selector; the receiver used here is UIApplication.sharedApplication (SpringBoard), not SBUIController.

These are iOS17 declarations, not proof of behaviour on this project's iOS16.1.1 device. Runtime checks refuse a mismatched return/argument ABI. A matching ABI does not prove the semantic contract, including nil URL/application-open handling and callback optionality.

## Scope

- Desktop click hooks only SBIconView's `_handleTap` while Home is showing. The manager admits only an already-managed, enabled, nonexcluded bundle. Busy managed windows consume the tap instead of falling through to a full-screen launch. Other icons chain to the previous IMP.
- While a main window is up, the existing local outside-tap shield resolves a real SBIconView under the point in SBHomeScreenWindow. It does not inject events, forward taps to another application, or call a private launch action.
- Status hold waits for scene startup completion, checks the current foreground bundle again, then requests Home. Failure/lock/closing/parking cancels or rejects the request. There is no fixed readiness timer.
- Fullscreen swipe retains the existing proportional expansion. Only this exit uses the explicit application-open request with animating:NO; no global UIKit/CA animation suppression, generic SpringBoard transition hook, or fallback icon animation is used. Unsupported ABI makes the swipe rebound.

## Still required

Build validation; actual iOS16 ABI availability; icon/folder tap routing and unhighlight behaviour; whether Home remains the reported foreground during managed hosting; status-bar touch delivery; whether Home transition preserves hosting; whether nil-URL no-animation activation correctly raises the App without a desktop flash. None is established by this note or by the source's signature checks.
