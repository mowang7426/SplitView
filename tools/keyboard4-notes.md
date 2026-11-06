# keyboard4 真机时序修复（0.7.66+keyboard4）

## 处理的两条链路

1. **展开保持**：已验证显示的竖屏键盘建立 `portraitKeyboardVisibleLatch`。它不再依赖 1.2 秒重挂载 grace；surface reparent、旧 canvas / 零 geometry、输入法 frame 变化和 SpringBoard 临时 hide 都不能清除该锁。锁仅由 PID 绑定的 App `DidHide`、观察目标 PID 变化或常规生命周期关闭解除。
2. **关闭同步**：App 侧 `UIKeyboardWillHide` 只发布动画时间与 `will-hide` 阶段，保留末次有效 geometry；不再在 WillHide 写入零 geometry。SpringBoard 收到可信的 PID `will-hide` 后，在该 UIKit duration/curve 的同一个 `UIView` transaction 内先提交浮窗 frame/layout，再提交 scene/canvas restore。`DidHide` 只完成可见性清理，不会再发送第二次 scene restore。

## 事件分类

- `P3_SYSTEM_WILL_HIDE_AWAIT_CLIENT`：SpringBoard 的 WillHide 是暂定信号，可能由 surface reparent 触发；不解除 shown latch。
- `P3_SYSTEM_DID_HIDE_AWAIT_CLIENT`：仍存在 native input / 已收到 App will-hide 时等待 PID 客户端的真实 completion。
- `P3_CLIENT_HIDE`：PID 绑定 App 的 `DidHide`，是真实终止信号，清锁并恢复普通状态。

日志只包含固定 P3 reason，不包含聊天内容或输入文本。关闭动画会创建临时内存视觉 snapshot，可能包含屏幕上显示的聊天/输入文字；不写入文件、不传输，动画完成即移除。不能将此表述为“没有捕获文字”。

## 验证边界

这是面向 iOS 16.2 / 17.0 RootHide 的修复版测试包，不是已通过真机验收的稳定结论。snapshot 能否捕获远程 surface、FBSSceneTransitionContext / BSAnimationSettings 的私有 ABI、curve 7 的实际动画曲线与 render-server 同步均需真机检查。ABI 检查失败时保留 nil context 的即时安全恢复并记录 P3_RESTORE_ANIMATION_ABI_UNAVAILABLE；不保证该 fallback 的视觉同步。新增 mock 只能验证动画元数据传递与调用顺序，不能证明设备渲染。

本机缺少 xcrun，不能把本机 portrait_runtime_checks.py 的缺工具退出当成测试通过；编译及 mock/事件/变异测试以 macOS CI 实际结果为准。既有三组 legacy baseline 失败仍保留，不应描述为全部历史测试通过。授权、横屏及外置键盘策略保持不变；本轮不安装、不 respring、不创建 Release、不修改默认分支。

## 回归覆盖

`PortraitEventTests.m` 直接执行生产 `.inc`：长期 shown/reparent 超过旧 grace 后仍保持展开；WillHide 时 outer frame 先于 host canvas configure；只提交一次 restore scene update；DidHide 不重提；真实 hide、重挂载、无效几何、输入法变化、失焦、生命周期及历史变异检测仍覆盖。UIKit/render-server 为 mock，非真机渲染结论。
