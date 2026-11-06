# 0.7.66+keyboard5 — 回归修正待真机验证

## 证据边界

video_CD03E0B3.mp4 中全宽键盘遮挡输入框，关闭时输入栏先下沉、缩窗、黑块，随后窗口消失回桌面。没有 ips/crash 或重启证据；不能确认 SpringBoard 崩溃，不能认定唯一根因。keyboard4 应停止使用。本文不宣称输入遮挡、窗口消失或动画流畅问题已修复。

## 可从生产代码确认的问题与本次修改

- keyboard4 的 App WillHide 可从原生通知栈进入同步 NSNotification → manager → floating → scene → placement restore；绕开原有双队列重入隔离，并在键盘尚未 DidHide 时重挂 remote surface。本版 WillHide 只记状态，不广播、不恢复；保留现有呈现至 DidHide/生命周期结束，由既有排队通知恢复。取消隐藏的 Shown 可以继续同一呈现。
- 原恢复先将 expanded 设 NO、用旧 expanded canvas 布局，再恢复 scene/canvas、第二次布局。这是代码可证的尺寸/transform 错序，不是已确认的视频唯一根因。本版先恢复 canvas，成功后只做一次普通布局；不再同步动画。
- 原恢复失败仍清空 saved frame/target，失去后续正确恢复几何。本版保留 expanded/saved 状态供重试；增加 floating 和 scene 恢复重入保护。
- 原 scene host/placement 同步调用之后仅异步 completion 有 generation/lifecycle 验证，同步栈可继续提交已取消事务。本版在宿主设置、placement 回写和 scene 提交之后重验代际/生命周期；拒绝恢复过程中再次扩展或递归恢复。
- manager 遍历可变 windows 时恢复会进入宿主回调；生命周期可移除窗口。本版遍历副本，并在扩展前再确认 owner 仍存在。测试主动在回调中移除窗口，以断言检测原路径集合变异错误。
- 撤掉 snapshotViewAfterScreenUpdates:NO overlay 与 FBSSceneTransitionContext/BSAnimationSettings 构造。ABI 可调用不等于远程 surface 可截图、转场语义可用；没有真机证据支持保留它们。

## 明确保留与不改变

保留 PID atomic phase 与 ownership-proven shown latch。其依据仅是生产链测试可以重现旧 1.2 秒超时导致已确认显示键盘回缩；latch 并不证明渲染 surface 或输入框位置正确。保持全宽 scene 原点、原生 keyboard 坐标转换、单位缩放；不制造 UIKit 键盘通知，不设置输入框 inset，不强行 foreground，不修改输入法/第三方 App。

未改授权、focus、键盘 policy、偏好控制器、注入范围、默认选项、默认分支。不会静默回退旧模式并宣称全宽功能成功。安全降级明确不支持隐藏同步动画；DidHide 后即时恢复可能仍有跳变或输入栏下沉。

## 测试设计和限制

PortraitSceneTests/PortraitEventTests 直接 include 生产 scene、placement 状态、floating、manager 代码。新增 ZNSKeyboardRestore.inc 将实际生产 restore 原样共用，不再以只计数且永远成功的 restore stub 替代主要危险链；覆盖 detach 重入、remote transport 异常清理、隐藏取消、host 拒绝及 saved frame 重试、同步生命周期取消、集合变异。snapshot 测试替身如被调用立即断言失败；scene restore 必须传 nil context。

仍模拟 UIKit 对象、布局/渲染服务和系统通知交付；不能证明真实 App 原生避让、host transform 的最终像素、私有 setter 回调时序或系统崩溃原因。几何数学测试不是原生输入框截图验证。

删除 input-picture-missing 的旧变异预期：该预期强制保留此次撤回的危险 snapshot。改测 saved-frame 丢失、WillHide detach、同步 lifecycle 校验和 windows 遍历重入；保留 shown-race/expiry、空几何 detach、frame 恢复、重复动画测试。旧 Geometry/Dip/SecondTier 三组已知 baseline 失败保持记录，不包装为通过。

## 真机阻塞项

需要 iOS 16.2/17.0 RootHide 实测全宽持续输入、emoji/预测栏变化、快速开关与取消隐藏、锁屏/旋转/切 App/移除窗口；同时记录 scene.frame、canvas/reference size、native keyboard frame 和 host transform。输入遮挡原因与窗口消失原因仍待日志和真机。若继续出现消失，需要同时间段 ips 或进程退出证据，而不是再添加未知私有动画 API。
