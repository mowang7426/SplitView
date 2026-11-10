# animations4：细粒消散（有界近似）

仅替换旧 `particles`「粒子消散」的120个大裁片实现，不新增重复选项；旧key、默认玻璃及animations3其他18项保持。基线248d2fdbab81ae89645b5189c6f602039080d080，版本0.7.66+keyboard11.animations4。

## 视频事实
反馈文件视频886×1920、5.48s、654帧、平均118.981fps。4fps接触表及3.25s原图可见：浮窗左侧先变成密集细斑，向右推进，保留文字/图标的彩色细节，约3–4s消散。未见设置页，不能确定是参考、旧版现状或其他插件；背景animations3交付文本不能证明生效效果来源。录屏状态栏FPS不是本实现的性能测量。
在3.25s的ROI(190,670)-(410,750)，RGB最小值>150且色差<80的4连通区域共71个；面积<=64px的70个区域长边中位4px，P90为7px。包含文字残留/背景/压缩，不是准确粒径测量，更不能未知设备比例就换算pt。

## 真实实现
原窗口只请求一次 `snapshotViewAfterScreenUpdates:NO`。保留一张冻结内容，不为粒子裁切snapshot、不读取远程App像素。128×256程序噪声mask共17个预计算关键帧，左到右渐进侵蚀原画，不是大矩形先缩小再飞走；mask栅格在允许的640×1280pt以内单元<=5pt。有限关键帧不是逐像素连续shader，可能可见时间步进。
一个CAEmitterLayer+一个CAEmitterCell共享12×12圆形程序纹理，包围盒直径2–4本地pt，圆形实际着色区域略小；向右100±35pt/s、加速度80pt/s²、微上飘、alphaSpeed=-2.8。细尘为半透明中性灰，**不是逐粒保留原窗口颜色**；只有正在消蚀的原画保留颜色，不能宣称视频彩色细粒精确复刻。没有音效、闪白或黑白矩形爆开。

## 预算及成本
单冻结源原有2,400,000像素上限；细粒不添加内容裁片。17×128×256×4=2,228,224字节mask像素，12×12×4=576字节共享点纹理；新建一个UIView容器及其backing layer、一个mask layer、一个emitter layer（不计算既有冻结内容内部实现）。不创建每粒UIView/CALayer。
发射1800/s，0.64s后CA gate切0，模型birthRate始终0；lifetime .32±.08s，理论同时存活<=720、全程约1152粒；1.08s效果，1.11s token保护清理。取消立即清发射cell、动画、mask及宿主。CA内部缓存/粒子存储/离屏mask合成开销不能由逻辑预算保证。
mask在一次构建中程序生成557,056个像素，约2.13MiB RGBA；不是每帧CPU重绘，但这次有界分配/生成仍在主线程，可能增加首次关闭延迟，应真机测量后决定后台预热。仅12×12程序圆点用UIGraphics，不重绘App，不用drawViewHierarchy/renderInContext/远端截图服务/同步读回。没有无限timer或displayLink。

## 生命周期与回归
仅既有底部点击触发；不改scene尺寸、键盘、焦点、授权、深色watchdog，不合keyboard12–15。旧解析器处理ReduceMotion淡出及none；冻结失败不进入细粒，资源或几何不符回退淡出。非nil快照仍可能黑/空，不能检测或保证受保护远程内容。
快速新窗、旧token、取消、旋转/锁屏/失活继续走原生命周期；surface尺寸变化停止发射、清mask、隐藏，待已有有界回收；不拉伸正在播放mask。
新增FineParticleTests.c执行实际生产policy，14个可编译且assert拒绝的mutation覆盖粒径、预算、方向、终态mask、发射停止、取消、token、snapshot失败、ReduceMotion、宽高边界；14个源接线删除检查仅补充而非UIKit实测。保留原9动画、13 screen、6玻璃、12历史粒子policy、2深色mutation；旧粒子header仅保留历史测试，不再作为渲染生产路径。
三项legacy failure仍由原基线比较明确记录：GeometryTests、DipGeometryTests、SecondTierPolicyTests，不算通过。host测试和CI交叉编译不能证明真机GPU性能、远程画面完整性或视觉逐像素复刻。
