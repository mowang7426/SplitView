# keyboard11.animations1

Independent branch from `1e278b7c4da656c6d430fdbf192bba73d373fd92` (shatter1), descending directly from deep-watchdog `01896574439233512bc9b141f03cd7a2392f23e0`. No keyboard12–15 merge; deep scene, keyboard, focus, authorization and watchdog implementations unchanged.

## Native Preferences

Settings → 曾牛-分屏🐮 → 浮窗动画. Uses existing authorized PSListItemsController, `com.zengniu.splitview` and `/changed` Darwin reload. No new persistence system or default writes.

- `WindowExitAnimation`: none / shatter (default) / reference / shrink / sink / fold.
- `WindowEntryAnimation`: none / soft (default) / rise / pop.
- Unknown or wrong-type values fall back to shatter / soft.
- Choices apply to the next corresponding action; no respring. Existing animations retain their captured style.
- Reduce Motion converts non-none effects to 160ms motion-free opacity transitions; none stays immediate.

Exit choices affect only a **tap on the bottom bar**. Swiping up, red close, keyboard dismiss, minimization and fullscreen retain baseline behavior. None closes immediately. Frozen effects hand off to the existing session teardown immediately, never terminate an App, never run a delayed scene-close callback. A refused snapshot uses the existing 160ms owner/generation-bound native fade.

Opening choices affect only a **newly allocated main floating view after successful host attachment**, including a prepared switcher host. Failed/notification-parked creation does not animate. Restoring existing parked/dipped/icon views, keyboard show/hide, rotation or repeated attach/layout do not replay. No wait for remote pixels; connecting UI stays visible. CA presentation animations never assign model transform/alpha. On completion or cancellation only the namespaced animation key is removed. Closing, interaction takeover, geometry change, scene deactivation, lock, disable and destruction invalidate ownership; old tasks cannot change a new view/session.

## Reference video evidence and limits

`video_BFC39EC8.mp4`: ffprobe reports 886×1920 at nominal 120fps, duration 5.713333s. Analyzed with ffmpeg 12fps extraction at 443×960, Pillow pixel/row geometry, apple-vision OCR and rectangle coordinates; no native image/video interpretation.

Observed central white chat surface loses pixels from left towards right, nonuniformly by row. At y=400 in reduced frames: 3.000s white span x=61…373; 3.333s x=122…373; 3.500s x=264…371; 3.667s only 4 near-white pixels remain x=353…381; by 3.750s none at that row. Difference-mask central ROI area drops from 148000 at 3.000s to 119749 at 3.333s, 73221 at 3.500s and 6768 at 3.833s. These counts include background/widget changes, not exact object segmentation. OCR locates chat text before disappearance; rectangle detector returns no reliable whole-window rectangle in most sampled frames.

Inference: a directional, uneven erosion/dispersal, not merely uniform scale/opacity. Exact shader, particle topology, touch origin and timing curve cannot be established from these CLI measurements. Implemented `参考·向右消散（近似）`: twelve frozen horizontal crops collapse/translate towards the right with bounded stagger and fade (~0.85s total). This is an explicitly approximate container effect, not an exact dust shader or video clone. No per-pixel GPU particle shader is claimed.

## Safety and tests

Reuse shatter1's independent non-key/pass-through overlay, one `snapshotViewAfterScreenUpdates:NO` frozen provider, crop-only replicas, shared source/pixel budget, maximum one exit presentation. Reference uses 12 crops; glass keeps 16 polygons. No CPU readback, forced redraw, screen capture service, synchronous remote wait or persisted App images. Crop refusal/exception clears partial bands and fades the frozen provider. Rotation/scene/Reduce Motion cancels overlays; new creation cancels the old exit overlay. Provider remains retained through disposal. Shatter geometry/lifecycle and their original six mutation tests remain.

`tools/window_animation_checks.py` compiles the actual production C parser/dispatcher/motion plans/one-shot lifecycle against values/defaults extracted from actual Root.plist. It runs fake-host close/capture/fallback callbacks for every setting with Reduce Motion and refusal, new-only/ready/ineligible/none/stale-cancel isolation tests and nine assertion-rejected mutations. Supplementary integration guards check Darwin reload, typed reads, real manager hooks, native picker page and preserved original preference rows. This is host logic validation, not UIKit/render-server/GPU testing.

CI runs existing portrait, legacy-comparison, deep dark-watchdog, keyboard11, shatter and new animation tests before RootHide Theos arm64e build, final code signing and staged package verification. Three pre-existing legacy geometry failures are comparison evidence, not silently relabeled as passing. Device rendering, remote protected content snapshots, animation quality, SpringBoard timing and accessibility need real-device validation.
