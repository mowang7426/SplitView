# 粒子消散（animations2）

基线：`a73c8c7fc4f2597540b4e65d8f020daaca2439f3`（animations1，keyboard11、深色 watchdog 修复）。不合入 keyboard12–15。

## 使用

设置 → SplitView → 动画 → 底部点击退出动画 → **粒子消散**。真实值 `particles`；Darwin changed → reloadPreferences → 生产解析/分发立即生效。默认仍是玻璃碎裂，参考·向右消散（近似）仍是独立 12 条带，所有出现选项不变。只接入已有底部点击退出，不改变关闭、进程、键盘、授权焦点或 scene 的语义。

## 实现和预算

沿用一个 `snapshotViewAfterScreenUpdates:NO` 冻结源及独立、非 key、触摸穿透 overlay；显示机会后再从冻结源裁切 10×12 网格，最多 **120 个原内容纹理颗粒**，不从 App 逐颗抓取。每个矩形颗粒不同延迟（0–0.18 秒）、缩小到 8–28%、旋转 ±0.45 弧度、向右移动窗口宽度的 12–42%，上下按行向外漂移，整体淡出。运动 0.58 秒，最长 0.76 秒；延后 0.02 秒建片和 0.03 秒清理余量后约 0.81 秒释放。

最多一个 presentation / 一个冻结源 / 120 个裁片视图（无颗粒 mask）/ 120 组 UIView 动画调用，颗粒端仅 transform 和 opacity 两种动画属性（至多 240 个属性轨道；UIKit 内部对象和背板共享不受本插件精确控制）。无 CADisplayLink/逐帧 CPU 循环。颗粒准备 O(120)，恒定上限；SpringBoard 主线程仍承担有限 UIKit 复制和动画提交，不承诺真机帧率。

冻结源最多 2,400,000 像素；120 个无重叠内容裁片合计恰好一个源面积，因此正常颗粒源+裁片累计最多 4,800,000 逻辑像素。每片创建前继续执行已有 6,000,000 累计像素硬上限，失败立即清理已有裁片并退化为冻结源淡出。像素数是逻辑资源预算，不等同于 UIKit 实际峰值内存测量。纯 RGBA 4 字节粗估对应 19.2 MB 内容面积，但不包含对齐/临时资源，不能当成内存保证。

无 CPU bitmap/readback、强制 draw/renderInContext、同步图像读回、跨进程等待或磁盘截图。不是 CAEmitter 纯色粒子，不是 GPU shader，也不是逐像素尘埃或参考视频的精确复刻；有界纹理网格起始可见矩形结构，随后缩小错相形成碎粒。

## 失败和清理

任一裁片失败（包括部分成功后失败）全部清片并以冻结源淡出；无源快照/源超过预算时沿用原关闭淡出。Reduce Motion 把该选项解析为 fade，无动画仍为 none。继承 scene 断开/失活、旋转、Reduce Motion 改变和快速再次退出取消，清理幂等、generation 隔离旧任务，保持冻结纹理提供者到清理时释放。

UIKit 非 nil 快照不保证远程/受保护内容有画面；可能空白或黑色，这是 API 和内容源限制。主机测试不能验证真实 SpringBoard 远程纹理、细粒视觉、GPU 时间或 watchdog 上限，需要真机验收。

## 测试

`python3 tools/particle_animation_checks.py` 运行实际生产 C 策略/生命周期主机注入测试：120 个有限坐标、精确全区域覆盖/无缝边界、方向/时长/错相/尺度、像素预算；枚举 120 个部分裁片失败位置；取消/旧 build/旧 completion/幂等释放；无 snapshot；Reduce Motion。12 个 assertion-only mutations 必须被断言拒绝。

保留既有 9 动画 + 6 玻璃 + 2 深色 mutations；3 项 legacy baseline failures 仍必须在比较测试中复现，不放宽原断言。CI 继续 macos-15-intel / Xcode 16.4 / iPhoneOS16.5 / RootHide arm64e；artifact 改名为 splitview-roothide-animations2，包精确版本断言为 0.7.66+keyboard11.animations2。未安装、注销、发布 Release，也不下载 artifact/deb 验包；包结构/签名验证由 CI 内运行。
