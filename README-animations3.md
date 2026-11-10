# animations3：熄屏效果静态参考与局部浮窗适配

基线 `534396f393bc9bdadb3ae91f42c924c40e42620c`，独立分支 `feat/window-screen-effects`，版本 `0.7.66+keyboard11.animations3`。不合 keyboard12–15，不改默认分支。18 个新选项同时加入出现/消失选择器，全部标记“自研近似”；旧选项、默认消失玻璃/出现轻缩及深色 watchdog 来源保留。

## 静态分析范围

只读取用户提供的 1,259,362 字节 `熄屏幻术-1.0.5-iphoneos-arm64e.deb`，SHA-256 `6b4d215197c6871f19f6de6dcd78aa579f1766125895f0baebca712641715210`。用 ar/tar 解包、LLVM objdump 读取符号/ObjC 元数据/反汇编、自写只读 Mach-O 常量字符串解析器；没有执行其二进制或安装脚本，没有安装、注销、下载其他 deb、绕授权或提取密钥。tar 设置时间戳报错不影响文件内容，归档内容已读取。

control：`com.cracklock.7513` / 1.0.5 / iphoneos-arm64e，Maintainer/Author 7513，依赖 mobilesubstrate、preferenceloader，替代旧包 com.cracklock.shatter。control 归档仅有 control，无 maintainer scripts。注入过滤仅 SpringBoard。主二进制 ShatterLock.dylib、设置二进制 ShatterLockPrefs 均有 arm64/arm64e slice；设置动态构建，不是 Root.plist 效果列表。

资源仅设置包 header/icon 各普通/@2x/@3x、reward.jpg、egg_snow.png、egg.mp3。后两者由彩蛋控制器引用，不是18种常规动画的序列帧。未复制任何原素材、原可执行代码或大段反编译代码。未发现随包提供的源码授权说明；以下仅是独立实现。

分析证据保留在工作区 `screen-effects-analysis/`：`control/control`、`symbols.txt`、`objc.txt`、`strings.txt`、`prefs-strings.txt`、`constant-strings.json`、`prefs-constant-strings.json`、`methods.json`、`prefs-methods.json`、`disassembly.txt`、`effect-methods-disassembly.txt`。Objdump 对 chained 指针只给地址，因此另按 Mach-O sections/类 ro/method list 解析 IMP 和 UTF-16 CFString，避免 strings 漏中文。下表地址为 arm64 slice 的 start IMP，不混用 arm64e 地址。

## 确证效果与实现对应

效果名称和原设计描述来自真实 CFString；类、start 地址、切片/动画属性、CADisplayLink/bitmap 路径来自静态元数据和指令。确证“存在和机制类别”，不是已运行观察到的像素级观感或精确时序复刻。

|原效果／类／start IMP|原设计机制及参数默认值（设置文本）|新设置键及自主近似|
|---|---|---|
|碎屏 CLKCrackView 0x86e8|Voronoi、裂纹再落下；rays11/rings6、裂纹.12s/坠落.48s、gravity1|fx_crack：64矩形内容碎片坠落/拼合；不冒充Voronoi，原默认玻璃仍用旧16片Voronoi|
|像素消散 CLKPixelView 0x9828|撞击点波前缩小淡出；48pt、jitter30%、剩余12%、.60s|fx_pixel：64块抖移缩散/聚合；不复刻同心波时序|
|百叶窗 CLKSliceView 0xa12c|横条左右交错滑走；14条、.50s、错开50%、倾斜5°|fx_slice：12横条错移并收窄/归位|
|信号故障 CLKGlitchView 0xab6c|横条撕裂和闪白；36pt、.42s、14跳|fx_glitch：12横条有限位移/暗度变化，不加过曝闪白|
|CRT关机 CLKCRTView 0xb370|先压纵向亮线，再横向点；.55s、高.6%、白线2pt|fx_crt：内容纵压再横收/点线展开，不加白线素材|
|竖条翻牌 CLKFlipView 0xbb2c|竖轴透视翻走；10条、.55s、透视760、100%|fx_flip：12竖条交错Y轴翻转，透视900；非原先后相位|
|旋涡吸入 CLKVortexView 0xc2dc|卷向撞击点；.70s、1.2圈、半径10%|fx_vortex：64块收向窗口中心并旋转/展开，不取系统撞击点|
|灰烬升腾 CLKAshView 0xd2bc|底部烧穿后上升；.95s、22pt|fx_ash：64块上飘缩散/凝聚，无烧穿着色|
|风沙吹散 CLKSandView 0xe0c0|侧向细沙风扫；.95s、24pt|fx_sand：64块向右上方吹散/汇聚，非逐像素沙粒|
|条带垂落 CLKMeltView 0xe9a0|竖条依次向下；12条、.60s、距离105%、倾斜3°|fx_melt：12竖条不同落距/升回|
|波纹扭曲 CLKWaveView 0xf2ec|横带波动淡出；22pt、.75s、1.15波、28条|fx_wave：12横条离散采样横向波动/平复，不是连续位移着色器|
|方块散开 CLKTilesView 0xf938|拼图向四周旋转飞出；96pt、.70s、260pt、旋转100|fx_tiles：64块径向外散/拼合|
|螺旋甩出 CLKSwirlView 0x1082c|碎屑绕撞击点外甩；.85s、1圈|fx_swirl：64块螺旋外甩/归拢，固定中心和有限弧度|
|漆皮剥落 CLKPeelView 0x11400|顶部往下碎片翻落；.85s、20pt|fx_peel：64矩形翻转下移/贴合，无漆皮轮廓/顶部传播|
|灯管熄灭 CLKFlickerView 0x129a8|闪烁过曝后灭；.50s、4次、过曝65|fx_flicker：单层温和暗闪/亮起，主动去掉过曝和高频闪白|
|烟尘飘散 CLKInkView 0x121b0|碎屑随机游走上飘；1.20s、20pt|fx_ink：64块扩张上飘/凝聚；不含真实烟雾 alpha 纹理|
|灭霸响指 CLKThanosView 0x146e8|中心波前化灰风带走；1.10s、10pt|fx_thanos：64块横向相位偏移的风化/聚合；不是原中心波和细粒度|
|柏林溶解 CLKPerlinView 0x139c4，tick:0x13abc|噪声控制溶解；1.10s、4px；PerlinRaster、bitmap、displayLink逐帧路径|fx_noise：64格确定性错相透明度溶解/显现；明确不是Perlin噪声，未迁移CPU逐帧栅格化|

原参数范围及所有中文说明在 prefs-constant-strings.json 中。没有搬入原随机选择、参数滑条、触感、锁屏声音、电源键/idleTimer hooks、自绘系统截图、日志或授权逻辑。新效果使用固定安全参数，整体 .64s。

## 安全适配与预算

消失仍仅底部横条点击；不扩大到红色关闭、上滑、最小化、收键盘，不新增 terminate。真正关闭仍由原同步 handoff 执行，动画完成没有 scene/session 或 close 回调。出现只在新 host-ready 成功一次；不改 host 附着、布局、恢复路径或键盘焦点/授权。

共用 ZNSScreenEffectPolicy.h 与 ZNSScreenEffects.m。退出复用原非key、触摸穿透冻结 overlay；出现采用容器同父级的非交互冻结 sibling，只用自有 CA presentation opacity 暂时遮住原内容，模型 alpha/transform 从未写入。结束/取消移除本插件的动画键和冻结表面，不复位活窗口 transform，不污染手势。出现使用独立 entry pose/alpha 端点，不反向调用关闭动作。

快速新建/退出相互取消旧展示：全局至多一份打开或关闭冻结动画；原 generation 校验保持。旋转、scene失活/断开、应用失活、ReduceMotion变化、停用和原关闭路径沿用取消。全部片失败、nil/exception、像素预算不满足，回退短淡入/淡出；旧关闭语义不变。none 保持 none，ReduceMotion 解析后只走 fade。

每效果 1/12/64 个裁片，最多64裁片、7个预计算keyframes、每片transform+opacity两轨、一个冻结源；动画交给CA，无主线程逐帧重绘。源上限2,400,000逻辑像素，完整无重叠裁片合计同等源面积，源+裁片至多4,800,000逻辑像素，并逐片执行原6,000,000累计上限。原120粒子选项预算不变。没有像素读回、强制draw、跨进程同步或磁盘快照。UIKit内部分配与GPU峰值无法用此逻辑预算精确保证。

## 验证和局限

新增实际生产几何/构建协议/生命周期/真实picker测试 ScreenEffectTests.c 与 screen_effect_checks.py，包含18×2设置、全部裁片失败位置、完整无重叠覆盖、横竖/极小几何、7帧有限姿态及端点、各效果差异、方向/轴、单次host-ready、旧token、取消、budget、unknown/default、ReduceMotion/none。13个mutation要求编译成功且被assertion拒绝，不能用编译失败冒充。新增接线源检查补充而非替代生产主机执行。原9动画、12粒子、6玻璃、2深色mutation及legacy baseline比较不删除不弱化。

本机无xcrun；UIKit/完整Theos由macos-15-intel/Xcode16.4 CI验证。没有真机验证，尤其远程/受保护App快照可能nil、黑或空，非nil并不证明内容完整；没有承诺帧率、内存峰值、GPU耗时或watchdog实测通过。所有18项是对应机制的独立有界近似，绝非“原插件18动画已精确复制”。
