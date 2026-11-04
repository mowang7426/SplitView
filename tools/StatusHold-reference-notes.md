# 状态栏长按：一芽参考证据与源码修复

## 范围与证据等级

本次仅修改 `Sources/ZNSActivationHooks.m`，新增本说明；未修改头文件、设置页、版本或构建描述。未编译、未安装、未运行附件里的 Inspect 或任何新编译程序、未操作或读取屏幕、未提交 Git。

参考文件均位于项目内 `Attachments/yiya-reference/`。以下只记录实际读到的内容，不把字符串邻近关系当作完整反汇编结论。

### 已核实的参考线索

- `strings.txt:632–643` 连续包含 `MTStatusBar `、`MTStatusBar hooks system=%d uikit=%d legacy=%d`、`SBMainDisplaySceneLayoutStatusBarView`、`STUIStatusBar`、`_UIStatusBar`、`UIView`、`attach bar=%@`。同组信息在第二部分约 5127–5138 行重复出现。
- `strings.txt:321` 包含 `StatusBarLongPressEnabled`。只作为参考功能存在的证据，不采用它的偏好域或配置键。
- `strings.txt:1024`、`:2261` 包含 `didMoveToWindow`、`layoutSubviews`；`:1705`、`:1811`、`:3091` 分别包含 `activateStatusBar`、`canActivateStatusBar`、`sharesStatusBarTouchPath:`。字符串表不能证明这些选择器属于哪个类，或它们的参数/返回 ABI，因此本项目没有调用后三个参考私有入口。
- 使用 `nm -h` 阅读帮助后，以 `nm --arch=arm64e --defined-only` 和 `--arch=arm64` 只读检查 `yiya_original_files/Library/MobileSubstrate/DynamicLibraries/BananaMultitask.dylib`：两切片均确有 `_OBJC_CLASS_$_MTStatusBarGesture` 和相应元类定义。arm64e 类/元类值为 `0xaa420` / `0xaa448`；arm64 为 `0xa6420` / `0xa6448`。这证明类存在，不证明它的继承关系或具体回调实现。

### 无法核实的部分

- `objc-metadata.txt` 实际为 0 字节，不能提供方法类型编码或实现地址。
- 先读取 `otool` 帮助，再尝试 `-ov` 与 `-tvV` 只读解析；工具因缺失 `otool-classic` 后端失败。备用 `llvm-objdump`、`objdump` 不在 PATH。
- 因此没有声称完成一芽状态栏方法的逐指令还原，也没有声称已证明它实际 hook 哪个生命周期方法。上述三个类是字符串明确给出的候选挂载层级；本次采用这些层级配合已核实的 UIKit 公开生命周期方法，自行实现挂载。

## 现有问题与修复

旧源码仅 hook `_UIStatusBar.layoutSubviews`，同时要求视图所在窗口必须继承 `UIStatusBarWindow`、`_UIStatusBarWindow` 或 `SBStatusBarWindow`。这会在状态栏由其他 SpringBoard 窗口承载时直接拒绝挂载；此前也未覆盖参考字符串中的 `SBMainDisplaySceneLayoutStatusBarView`、`STUIStatusBar`。这是源码可确认的覆盖缺口，尚未通过本机视图树证明它就是用户设备上唯一原因。

新源码：

1. 运行时查找上述三个候选 UIView 子类；分别 hook `layoutSubviews` 与 `didMoveToWindow`。SDK 的 `UIKit/UIView.h` 明确声明两个方法均无显式参数、返回 `void`；安装前再次验证实际方法返回类型和参数数。
2. 每类、每方法独立保存原 IMP，并始终先调用原实现，避免三层共用原 IMP 导致错误调用。没有 hook `UIView` 基类。
3. 不再要求旧窗口类；只在主屏幕、已识别的状态栏层级挂载，拒绝隐藏、近透明、不可交互、离窗视图及 `ZNSOverlayWindow`（包括其子类）内的镜像状态栏。
4. 选择最外层已识别状态栏作为唯一手势归属。嵌套子层级的旧识别器停用，接收触摸和长按触发时也再次检查归属，避免同一触摸打开多次。
5. 偏好热更新扫描主屏幕的 connectedScenes/windows 中三类已有视图，不再以旧状态栏窗口类筛掉新层级；后续创建和换窗由生命周期钩子补挂载。
6. 保留左右独立开关、0.55 秒长按、8pt 移动容差、中央 42%–58% 不响应、UIControl 子视图排除，以及长按前后前台应用一致性检查。
7. 保留授权与总开关判断、未知锁屏 ABI 时失败关闭、`SBApplication` 类型检查。最终仍经 `ZNSWindowManager.openBundleIdentifier:`，该入口会重新校验授权、总开关、ExcludedApps 和锁屏状态。
8. 保留 `cancelsTouchesInView=NO`、两项 `delaysTouches*=NO`、不阻止其他识别器、允许同时识别。没有拦截全局事件、hit-test、强制开启系统视图交互、注入系统手势管理器或添加遮挡窗口。
9. 添加每类 hook 可用性和首次实际挂载类名的 `os_log`，便于未来经用户同意测试时定位；不记录前台应用标识或用户内容。

## 实际静态检查

- 阅读完整修改文件，复核三类独立 IMP、原方法调用、嵌套去重、失效视图检查、授权和最终打开入口。
- 阅读 SDK `UIKit/UIView.h`，核对本次使用的两个生命周期方法公开声明。
- 执行只读文本断言：三候选类、左右偏好键、授权、锁屏入口、管理器入口、三组独立生命周期包装函数、触摸不取消/不延迟设置和镜像窗口排除均存在。
- 文本检查确认旧窗口限定函数和单一原 IMP 已移除，没有 `sendEvent:`、`hitTest:`、方法交换或强制开启交互的实现，也无行尾空白。
- 文本检查通过不等同于 Objective-C 语法检查、编译通过或实机功能验证；按本次要求没有调用编译器。

## 未测试与限制

- **左右长按启动与开关热更新**：授权后分别只启用左侧/右侧，打开普通 App，在对应可见状态栏侧按住至少 0.55 秒；应仅开启所选侧并打开当前 App 小窗。尚未验证。
- **新层级挂载和去重**：未来安装后监听 activation 日志，确认实际挂载类、重新进入 App/旋转屏幕后仍有效，且一次长按只有一次接受记录。尚未验证。
- **系统手势共存**：检查短点状态栏回顶部、下拉通知/控制中心、中央区域和状态栏按钮原行为；代码不主动阻止系统，但不能据此宣称所有系统竞争路径已正常。尚未验证。
- **安全边界**：分别测试未授权、总开关关闭、ExcludedApps、锁屏及长按过程中切换 App，均不应打开小窗。源码保护保留，尚未实测。
- **镜像/横屏/隐藏状态栏**：验证小窗内的状态栏不会启动、主状态栏横屏左右区正确、隐藏状态栏不响应。不会为了得到触摸而开启原本不可交互的系统视图；若系统把触摸交给其他层级，本次仍可能收不到长按，需要另行取得用户同意后观察实际层级，不应扩大为全局触摸拦截。
- 主功能目前仍待编译和实机测试，不能将本说明当作“状态栏长按已验证修复”的结论。
