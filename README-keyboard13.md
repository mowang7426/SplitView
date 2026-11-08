# keyboard13：恢复必须有当前隐藏证据

基线：`74cede3e766e582d56003aa573c51f0148f3aa28`（keyboard12）。

## 代码证据与设备推断

keyboard12 的 `znsAcceptClientPhase(Hidden)` 无条件调用 `znsClientDidHide`，清空 shown/continuity、visible latch、geometry，并发布 ended。manager 随即启动普通恢复或 hide retry；恢复事务在 scene 已匹配后，30 tick 降级 client-size ACK，允许 host/canvas/小窗 handoff。Hidden guard 过去只重验这些已经由同一 hide 设置的内存标记，不能证明原生键盘当前消失。

因此 remount 的临时 DidHide/迟到的旧 hide 可以进入该路径；0.5 秒降级是暴露误分类的提交条件，不是独立关闭证据。本次没有 QQ 视频或日志，不能确认该可达路径就是反馈设备上的唯一根因，亦未真机验证。

## 修复

* 每次候选 Hidden 都要求 PID 专属 App 实时查询。请求绑定单调 nonce 与完整 phase word（含 UIKit phase 时间戳）；回答绑定同一 nonce/phase，读取使用 response 双读，当前 phase 再读。
* App 主线程通过 ABI 校验后的 `UIKeyboardImpl.activeInstance` 的 `isVisible` / `isOnScreen` 只读查询回答：visible / absent / unknown；缺接口、ABI 不符、两个接口矛盾或无实例均为 unknown。没有强制 responder、焦点申请、合成通知或放宽 owner 授权。
* visible/unknown 不清除 continuity，不提交恢复 scene，撤回临时 WillHide 的视觉恢复。已有 0.25 秒活动定时器重采样；没有把等待时间转换为 hidden 的门槛，也不新增无限 dispatch 重试链。之后真正 absent 即可恢复，无需依赖新 Shown。
* Hidden guard 将请求证据绑定到既有 PID/bundle/focus/phase/session/layout epoch/owner/lifecycle guard，直到 handoff。新 Shown、迟到旧响应或旧 phase 不能授权收缩。
* 保留 keyboard6 continuity、keyboard7 scene ACK、keyboard12 30 tick 缺失 size-ACK 恢复，以及 scene → compensation → host/canvas → completion 的无动画 handoff 顺序；深色 watchdog 代码未修改。

## 验证与边界

`PortraitHiddenProofTests.inc` 执行实际 production placement/manager/floating/restore includes：Shown 后临时 hide/remount，visible/unknown 不缩窗、无新 Shown 后真实关闭恢复、旧 hide 与旧 phase 响应拒绝、30 tick handoff 旧证据拒绝、缺 size ACK 仍可恢复。旧测试通过新请求/响应 mock 经过生产 Hidden acceptance，不再直接置 hidden 状态。原 owner/PID/focus/epoch/close/rotate 与 host handoff 测试继续保留。

新增 mutation 要求 bypass proof、忽略 phase、visible 当 absent、unknown 当 absent、handoff 不验 proof 均由断言杀死；编译失败不算杀死。Darwin 通道、原生可见性与 UIKit/render-server 均为 MOCK，不能证明设备像素同步。私有实时可见性接口在目标系统是否可用，需设备日志/验收；unknown 保持展开是明确的保守策略，绝不超时盲缩。若目标系统接口长期不支持，普通键盘关闭恢复可能保持 pending，生命周期强制恢复路径仍保留，应据设备证据继续适配，不能宣称所有真机已解决。

不安装、不注销、不发 Release、不改默认分支、不下载 CI 包验包。CI 仅构建并上传原有 workflow artifact。
