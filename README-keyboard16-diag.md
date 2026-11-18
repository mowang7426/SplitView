# QQ 键盘诊断版（0.7.66+keyboard16.diag1）

独立诊断构建，基于已审计 commit `90370c5c250ce0aac2d62ca7304c622352b6806b`、分支 `fix/qq-keyboard16-animations4-reviewed-20261113`。保留桌面滑动总开关、细粒子与 18 种动画；不含 closebutton1 / keyboard12–15；不改正式/旧工作区。诊断功能只在诊断分支编译时默认开启，设置内“QQ键盘诊断日志”可实时关闭；正式构建未定义默认开启宏时，缺省关闭。

## 复现
1. 安装 CI 产物并进入设置 → 曾牛-分屏 → 打开“QQ键盘诊断日志”。
2. 在 QQ 打开一个文本输入框，使用插件现有键盘扩展/外置键盘相关操作复现：弹出键盘后约 1 秒，观察窗口是否连键盘一起缩回。记下本地时间及是否复现；不要复制或发送聊天文本、键盘输入内容或截图。
3. 复现后尽快导出统一日志。日志采集无需重启 SpringBoard；开关立即生效。

## 记录内容与隐私
os_log subsystem `com.zengniu.splitview`、category `keyboard-diag`，可搜索前缀 `ZNSKeyboardDiag`。App 端在 UIKit 关键 phase 记录 `WillShow/DidShow/WillChange/DidChange/WillHide/DidHide`（当前可观测到的 show/hide 事件；WillChange/DidChange 为 schema 预留，当前不伪造）；含 PID 数值、phase generation（当前客户端 phase 设为 0）、uptime serial、visibleProof。SpringBoard 侧关键恢复授权决策记录 phase proof、owner/focus match、restoreAuth、白名单 restoreReason。限速约每进程每 120ms 一条，字段白名单且字符串仅允许短 ASCII 枚举/数值。

当前打点不采集聊天内容、键盘输入、窗口/scene 地址、bundle 标识、截图/录音或网络数据。尚未接入 scene/window/canvas/frame/placement latch、poll/ack/handoff/layout epoch/swipe/animation等全量现场字段，不能据此断言这些数值。PID数值与设备诊断报告仍属可关联信息，分享前请检查并脱敏。Unified Logging 可能依系统策略保存、轮转或被隐私遮蔽；不保证日志一定出现在“分析数据”或 sysdiagnose。关闭开关可停止后续记录，无法撤回系统此前已留存日志。

## 导出路线（iOS 17）
首选 Mac「控制台 Console」：用 USB 连接并信任设备，在左侧选设备，开始流式记录，搜索 `ZNSKeyboardDiag`，复现后停止并保存/导出所选日志（或先记录再过滤），同时保留复现时间供筛选。设备本身可尝试设置 → 隐私与安全性 → 分析与改进 → 分析数据，查找近期 `sysdiagnose` 并通过分享导出；其中未必包含该类 unified log。也可用 Apple 快捷指令的“获取当前日期/记录”辅助记下时间，但快捷指令不能直接读取 SpringBoard 私有日志。无需越狱 shell 导出，不写公共文件。请勿将完整 sysdiagnose 公开分享；先移除序列号、账户/设备信息及无关应用日志。

CI 的 xcrun/macOS 构建与包检查为构建验证，不替代 iOS 17 真机验证。用户实机复现后仍需用 Console 确认是否有跨进程两侧日志、QQ多 scene 归属和键盘真实可见状态。

## 0.7.66+keyboard16.fix1：几何回退修复与手机导出

此前恢复授权拒绝并不等于没有其他缩窗路径。几何发布没有可用目标时，窗口管理器可直接走通用恢复；旧版只有 App 阶段能够保住扩展。此版允许当前同一 scene/焦点、仍有已验证可见附件的扩展窗口在几何未知时保持；不靠增加延时，也不靠无输入时的历史可见性。真正 DidHide、结束/失焦、失去证明或窗口生命周期切换仍可以恢复。scene 提交回调和超时的安全回滚保持不变。

开启“QQ键盘诊断日志”，在“查看 / 导出诊断日志”先清空，复现后回到同一页用分享按钮导出 JSONL，无需 Mac。用于区分的 SpringBoard 状态记录：

- `Decision_portrait_geometry`：保留已验证扩展或几何回退候选。
- `Decision_portrait_generic_restore`：管理器已进入通用恢复分支；不表示最终渲染一定缩窗。
- `Decision_portrait_scene_rollback`：scene 应用回调或超时检查不匹配。
- `Decision_portrait_visual`：已发布通过校验的视觉阶段；窗口管理器仍有自身门槛。
- `Decision_portrait_native_did_hide`：现有原生 DidHide 回退通道。

每种 SpringBoard 决策分别限速；这些记录不依赖 QQ 写入文件，不含输入文本、窗口/scene 标识或截图。没有客户端记录不等于客户端没有发出通知。真机仍需验证编辑时不缩窗、正常收键盘恢复，以及切换焦点/关闭恢复。
