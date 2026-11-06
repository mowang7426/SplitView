# 0.7.66+keyboard6 — 键盘仍显示时错误回缩

只修复键盘已由 App PID phase 确认 shown 时，host.window 短断、场景布局中、键盘帧转换无效、多 surface 重挂载造成 portraitPresentation=nil / manager !eligible 被误当成键盘结束的事件链。

- 生产 `ZNSPortraitVisibilityEvent.inc` 把 nil 且同一已确认 owner 仍持有焦点的状态标记为 `continuity`，并保留上一份可信呈现证据贯穿连续 nil 样本；忽略陈旧 restoreTiming ended。
- 生产 manager 仅在 `continuity`、当前同一 bundle、已 expanded 且窗口仍正常存在时，对暂态资格失败跳过恢复；非 owner、关闭/拖动/停放/旋转、失焦、PID DidHide、会话失效仍走原恢复。
- 有界 P6_RESUME_UNKNOWN 诊断仅含内部原因码和布尔状态，不记录输入内容。
- `PortraitEventTests.m` 直接执行生产分类器、placement 和 manager：连续 nil、陈旧结束标记、layoutInFlight、无效转换、真 DidHide、失焦、关闭、非 owner；仅模拟 UIKit/scene 传输，不等于真机通过。
- 没有修改隐藏动画；没有 snapshot/FBS 私有 API、新 hook、默认设置、注入策略、安装或注销。

需真机用最新视频的步骤复现并收集 P3/P6 同时段日志；这只能证明上述源码误恢复路径已修，不证明视频中的全部触发原因均已排除。既有三组 legacy baseline 失败仍未处理。macOS CI 成功与否以 GitHub Actions run 为准。
