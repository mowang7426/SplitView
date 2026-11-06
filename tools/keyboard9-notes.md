# 0.7.66+keyboard9 — WillHide 纯视觉同步，DidHide 恢复场景

## 安全分层

可信 App PID WillHide 仅捕获 phase/generation/timing，通过下一次 main queue 投递独立 `ZNSPortraitKeyboardWillHideVisualNotification`。投递前重新验证 PID、bundle、活动状态、focus、host、shown latch 与 generation；不从 native setter 栈同步进入 manager，不发布普通 visibility，不改 placement、keyboard attachment、scene/canvas。

manager 必须匹配当前 floating 的 bundle 与 `session.keyboardPlacement` 对象身份；关闭、拖动、旋转、停靠、缩略、布局中及失活均不启动视觉过渡。根 transform 非 identity 的其他功能不抢占，继续 keyboard8 回退。

视觉动画仅改变 floating 根 view 的 transform，按 saved/expanded 两个矩形计算缩放和中心偏移。bounds、center、expanded model、content frame 和 scene/canvas 保持不变，不调用 layoutIfNeeded；App 内容和输入栏共同继承该 transform，键盘仍由原生 UIKit 自己隐藏，不移动、分离或重挂键盘。使用 App duration/options 加 BeginFromCurrentState、AllowUserInteraction；零时长及 Reduce Motion 即时。无 snapshot、FBSSceneTransitionContext、BSAnimationSettings 或新增私有 hook。

## 收尾与取消

DidHide 继续走原有 placement restore 和 geometry notification 链。视觉已到终点时，先成功恢复 native canvas，再在无动画事务中移除本功能的 transform 动画、重置 identity、提交 saved frame 和一次 layout；不会再开 keyboard8 第二段缩窗动画。DidHide 早于视觉 completion 时只标记 pending，待同一个动画结束再恢复 scene/canvas（从不早于 DidHide），保留 manager 已清除的 suppression。生命周期的 duration=0 路径不等待动画。

Shown 取消通过同样异步事件把 transform 动画回 identity，不动 scene/canvas；generation 隔离旧 completion。恢复失败清除视觉 transform，但保留 expanded/saved frame/temporary settings 以供重试。不符合视觉门禁、未收到 WillHide、或事件在投递前失效时保留 keyboard8 DidHide 标准 UIKit 回退。

## 测试

PortraitEventTests 直接 include 生产 `ZNSPortraitVisualEvent.inc`、placement、manager、floating、scene 与 restore；queue/NSNotification 链实际执行。新增 PortraitVisualTests 覆盖投递前无动画、投递后单动画、duration/options、整窗 footprint、content/bounds/center/canvas 不变、零 scene 更新/restore/detach、DidHide 单次 restore 无第二动画、提前 DidHide、重复隐藏、重复 Shown、取消与新 generation、零时长、错误 bundle/placement/PID、关闭/拖动/旋转、已有其他 transform、恢复拒绝与重试、主动 dismiss。

新增变异必须以断言失败拒绝：漏掉 WillHide 动画、同步通知回入、提前 scene restore、重复视觉动画、未清理 transform；保留 keyboard8 动画及历史回归变异。Geometry/Dip/SecondTier 三组既有 baseline 失败仍单独记录，不称为通过。

UIKit、render transport、动画完成均为 host mock，只证明生产控制流与安全边界，不证明真机帧率或与目标视频逐帧一致。下一 main-queue 投递会有调度差；非均匀 transform 可能在过渡中轻微缩放文字；原生输入栏仍可能根据 App 自身 inset 动画移动。真机未验证，未安装、未 respring、未 Release、未修改默认分支。
