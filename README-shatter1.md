# shatter1：仅底部退出点击的临时玻璃动画

## 基线与动作语义

精确基线：`01896574439233512bc9b141f03cd7a2392f23e0`，即
`fix/dark-mode-watchdog-2026-11-06`。不合并 keyboard12–15；保留 keyboard11
及深色 watchdog 修复。版本为 `0.7.66+keyboard11.shatter1`。

该基线没有名为 `tuichuapp` 的 selector/资源。实际底部控件是
`ZNSFloatingView.bottomBar`，accessibilityIdentifier=`ZNSBottomBar`，提示
“上滑/点击-退出APP”；UITapGestureRecognizer 进入 `barTapped:`。
只在此方法确认 `gesture.view==self.bottomBar` 后调用独立的
`znsBottomExitAction` → `znsCloseBottomTapped:`。底部上滑、工具栏 xmark、
最小化、全屏、外部点击、收键盘、后台退出/锁屏等不进入碎裂路径。

现有动作并不是 terminate：`finishCloseWindow:fullscreen:NO` 先释放自己的
窗口/输入与托管状态，然后调用原 `stopForFullscreen:NO`，后者释放 host、lease、
keep-alive 并请求 scene backgrounded。是否挂起由系统决定；没有增加杀进程能力。
成功捕获后立即走这一原有清理顺序，不等待动画。只有取图失败使用短异步淡出后清理。

## 实现

- `ZNSExitShatter.m/.h`：独立 UIView snapshot、同 UIWindowScene 非 key host、
  polygon mask 和 UIView 动画；不持有活 App session/源窗口的后续回调。
- `ZNSExitShatterGeometry.h`：16 个抖动种子的 Voronoi 半平面裁剪，最多 24 顶点；
  不是规则方格。片面向左右与下方平移，适度二维旋转、透明度降至零，无白底、
  闪光、爆光或抖屏。碎裂动画 0.46 秒，含开始前约 0.02 秒冻结显示机会，总约 0.48 秒。
- `ZNSExitShatterLifecycle.h`：生产协调器，capture → 带令牌 schedule →
  build → play → 幂等 dispose。此真实代码由可运行 C host mock 直接执行。
- 减少动态效果时不制作碎片，仅冻结图 0.16 秒淡出；碎片裁剪任一失败则清理已制作
  碎片并对原冻结图淡出。源 snapshot nil/异常/超预算时不重试，不同步等待，原浮窗
  0.16 秒淡出后仍调用原关闭逻辑；0.22 秒回收兜底与 generation 校验防旧回调误关新窗。
- 所有 UI 主线程；不调用 drawViewHierarchy/renderInContext、afterScreenUpdates:YES、
  screenshot service、图片 readback、信号量或 dispatch_sync；没有新 scene 尺寸/键盘策略。
- 原窗口取图仅一次：`snapshotViewAfterScreenUpdates:NO`。之后只从冻结 UIView
  用 `resizableSnapshotViewFromRect:afterScreenUpdates:NO:withCapInsets:` 裁剪；不从
  已退出 App 取图，不生成每片 CPU UIImage。冻结 view 的 backing 复用由 UIKit 管理，
  不保证系统内部恰好只有一张物理纹理。
- 源预算最多 240 万像素；源加裁剪矩形累计最多 600 万像素（RGBA 数量级约 24 MB，
  不是对 UIKit/GPU 实际内存占用的承诺）。最多 16 片、1 个活 overlay；新退出会先取消旧动画。
  大窗口超过源预算直接原视图淡出，不为动画大尺寸截图。
- 坐标使用源视图到同 scene host 的三个基点转换，保留缩放/二维变换；没有全局反复 layout。
  host 不成为 key，禁 UIView 交互、render-server hit testing 且 hitTest 返回 nil。
- completion 与 0.7 秒 fail-safe 只结束自己的 token/overlay；绝不调用 manager 关闭。
  旋转、scene disconnect/deactivate、应用 resign-active、Reduce Motion 改变、插件停用、
  锁屏/撤销授权均取消。清理移除观察者、碎片、冻结图、controller 和 host，可重复调用。
- snapshot 仅临时驻留内存；不将用户输入/画面保存到磁盘或日志。

## 截图技术边界（必须真机验）

UIKit 的 NO-update snapshot 是本进程视图的 compositor replica；没有强制远端 App
重绘或同步确认。对于某些跨进程/受保护/尚未提交的 surface，UIKit 可能返回 nil，也可能
返回非 nil 但缺失远端画面。nil、异常、预算拒绝和部分裁剪失败均有上述淡出路径。
为避免 readback/跨进程同步，本实现不检测“非 nil 但空白”的远端像素，也不能仅凭 CI
证明每个 App 内容被包含。0.02 秒只是显示机会，不是 render-server 同步屏障。
未用纯色/伪造纹理补足内容，不能把这种限制称为真实内容截图已验证。

## 自动测试与人工清单

运行：`python3 tools/exit_shatter_checks.py`（clang + Python，Linux/macOS）；
CI 在原有 host 回归后追加同一脚本，保留 macos-15-intel / Xcode 16.4 / pinned Theos、SDK。

测试直接包含生产几何与协调器，而非只测重新实现的示意算法：

- 5000 seeds / 80000 面片，有限/凸/顶点有界/面积覆盖/随机稳定与非方格、
  左右下落方向、旋转和时长界限、源和累计像素预算边界。
- 捕获拒绝、16 个部分裁剪失败位置、Reduce Motion/geometry fallback、重复开始、
  制作前取消、过期 build/completion、跨 generation 与另一 presentation 隔离、幂等收尾。
- 6 个 mutation 必须以 assertion（不是编译失败）拒绝：移除结束 token、制作 token、
  部分碎片清理、忽略 Reduce Motion、向上掉落、移除像素上限。
- 集成静态约束仅底部点击；深色 watchdog、所有键盘/portrait、scene session、焦点、授权
  源码逐字与基线相同。原 keyboard source 检查只更新版本字符串，断言未放宽。
- `legacy_geometry_checks.py` 原样保留；3 个已知 baseline failures 继续按 baseline/current
  精确结果比较，不标记成通过，也不因动画弱化。

真机人工验收仍需：多个含文本/视频/受保护内容的 App，深浅色、多浮窗，键盘可见时底栏点击，
快速重复/退出后立即新开，横竖屏中断、锁屏、禁用插件、scene 销毁、Reduce Motion；确认无
白闪/漏画面/透明输入拦截/残留 overlay，监测 SpringBoard 实际帧耗与内存。编译和 host mock
不能替代这些 GPU/远端 surface/私有 scene 生命周期验证。本次不安装、不注销、不发布 Release。
