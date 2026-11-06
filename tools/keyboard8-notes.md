# 0.7.66+keyboard8 — DidHide 后标准 UIKit 缩窗动画

## 修改边界

仅修改 `ZNSPortraitFloating.inc` 中可信 `restoreTemporaryPortraitCanvas` 成功后的浮窗恢复表现。keyboard7 的 scene acknowledgment、visibility classifier、keyboard placement、WillHide/DidHide 通知链及安全 canvas 恢复顺序均未改变。

未引入 `snapshotViewAfterScreenUpdates:`、`FBSSceneTransitionContext`、`BSAnimationSettings`、私有动画 API、伪造键盘通知或延迟 hide。canvas restore 仍在动画前提交，避免 keyboard4 的旧 canvas/远程 surface 回归。

## 行为

真实 DidHide 携带非零 duration 时，在 canvas 恢复成功后使用 `UIView animateWithDuration:delay:options:animations:completion:`，保留事件 duration/options，并追加 `BeginFromCurrentState | AllowUserInteraction`。frame 与 content/canvas layout 在同一 UIKit animation transaction 内插值。

`duration=0`（拖动、旋转、显式恢复）及 Reduce Motion 继续立即恢复。若 owner frame 已被新布局接管，只做无动画布局与状态清理，不覆盖新 frame，也不启动无意义动画。canvas 恢复失败不启动动画，保留 saved frame 供重试。

`portraitKeyboardRestoring` 覆盖整个动画期；completion 才清理 target/saved/flag。restore generation 防止迟到 completion 清除更新一轮状态，重复 restore 不会创建第二动画，异常路径会安全清理或保留可重试状态。

## 自动验证

`PortraitEventTests.m` 直接执行生产 `.inc`：真实 Hidden/ended 事件传入 0.28 秒和曲线 options，验证 canvas 已恢复后 frame/content 同属一个非零 animation id、completion 前 restoring 为 true、重复 restore 不增加动画、completion 后 saved/target 清空；同时覆盖 duration 0 立即恢复和 canvas rejection 无动画保留 saved frame。

`portrait_runtime_checks.py` 增加硬跳与忽略 options 变异，替换为无动画路径或丢弃事件曲线时必须 assertion failure。`keyboard_expand_checks.py` 要求 restore canvas 位于标准 UIView 动画前、包含 `BeginFromCurrentState`，并继续禁止 snapshot/FBS/BS 私有过渡。

这些测试的 UIKit、scene callback 与 render transport 均为 mock，只验证生产控制流和 transaction 归属，不等同真机动画观感。键盘隐藏与缩窗不是同一相位：出于安全原因不在 WillHide 同步 manager；keyboard8 只保证 DidHide 后缩窗本身使用标准 UIKit 平滑插值。未安装、未 respring、未创建 Release、未修改默认分支。
