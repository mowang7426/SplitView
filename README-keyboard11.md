# keyboard11 — 分层几何交接修正

版本：`0.7.66+keyboard11`；仅 `feature/portrait-keyboard-expand`；RootHide `iphoneos-arm64e`。

## 实现

- 保留 keyboard9 的 root expanded→原 savedFrame 映射，不把整个浮窗挤到 contentFrame。
- `ZNSPortraitVisualGeometryMake` 使用原 `ZNSMainBody` / `ZNSMainContent` 得到普通布局端点，逆向抵消 root 的比例，在 bodyBackground、content、canvasContainer 上分别施加纯视觉 transform。
- `ZNSPortraitFittedCanvas` 同时供普通生产布局和补偿几何使用。canvas 的目标取原生画布 aspect-fit 的实际显示矩形，不把 content 外框冒充画布边界。
- WillHide 不改 frame、bounds、center、host/reference、scene 或原生键盘 geometry，不 layout、不 detach；没有 snapshot、FBS/private animation API、新 hook、文本采集或额外排队延迟。
- 保留 keyboard10 的 normal DidHide 双尺寸确认：scene settings 和客户端 window-size reply 都满足后才交接。在同一现有无动画事务中，新增 prepareVisual 回调先清子层补偿，再恢复 host/reference，最后清 root transform、恢复原 frame、执行一次普通布局，避免双 transform。
- visual/pending 期间普通 layout 不覆盖补偿；内容输入由既有 layer-input gate 临时阻断，避免视觉补偿与点击坐标不一致。原生 keyboard routing 不受改动。
- 顶栏现有可见元素随视觉阶段淡出；普通几何完成交接后 toolbar/topBar/bottomBar 用 0.15 秒纯 alpha 淡入，delay=0。减弱动态效果时为 0。隐藏栏不为此强制显示，不改布局结构。
- 统一清理 descendant transforms、圆角视觉值和自己的动画；Shown 返回、取消、失败重试、close/drag/rotate/强制恢复均使用原生命周期路径。chrome 淡入有单独所有权标记，关闭/再次展开时回收 opacity 动画，旧 completion 有 generation 检查。
- keyboard7 acknowledgment 与 keyboard6 continuity 保持不变。授权、focus 和 keyboard policy 未修改。

## 验证范围

- 生产纯 C helper 的 13,500 组几何案例：3 种 screen 尺寸、不同窗口原点/宽高、5 种 native canvas 比例；独立计算普通布局 oracle，比较 root/body/content/rendered-canvas 四边误差不超过 0.5pt。
- 生产 `.inc` 的 27 组异步事件交接矩阵：3 种 screen、3 种 native canvas、3 种 offset；检查实际子视图 transform 链、pending freeze、host 尺寸改变前补偿已清理、交接只执行一次普通布局、chrome 淡入/close 清理。
- 旧事件/scene/ack/restore/generation 用例继续执行。新增 mutation 必须以断言失败捕获：旧 outer-only endpoint、未清子层补偿、漏 canvas aspect-fit、host 改尺寸后才清理、chrome 突现。
- 原有三个 legacy baseline failures 仍由 `legacy_geometry_checks.py` 与原基线逐一比对，不忽略新回归。
- CI 固定 macOS-15 / Xcode 16.4 / pinned iPhoneOS16.5 SDK，不改构建环境。CI 成功及下载验包结果以最终 run/commit 绑定的 verification.json 为准，不能使用 keyboard10 的包代替。

## 明确限制

**尚未真机验证，不保证客户端 render 稳定。** 几何测试验证的是生产数学端点与状态机，不是 render-server 像素时序。scene settings 与客户端尺寸确认不是 pixel fence，不证明 WKWebView/Metal/第三方聊天页面已经重绘；CoreAnimation 真实曲线、圆角和阴影像素、交接帧、键盘/光标/候选栏需真机录像确认。不要把 host mock 的通过宣称为客户端实测。

未执行安装、卸载、respring、Release 发布或默认分支修改。保留 keyboard10 包以便人工对照。
