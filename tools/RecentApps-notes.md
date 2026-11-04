# 分屏启动加入最近后台卡片

## 静态参考依据

FV 1.6.0-6 的 Attachments/fv-keyboard-audit/main-linked.txt，函数范围 0x147f0–0x14b28：
- 0x14814 读取传入场景 identifier；0x14844/0x14864 读取 clientProcess.bundleIdentifier。
- 0x14948 调用 SBDisplayItem displayItemWithType:bundleIdentifier:uniqueIdentifier:，type=0，uniqueIdentifier 为真实场景标识，不使用包名或自行拼接。
- 0x14a04 将 displayItem 放入角色字典，键来自 0x990d8 的 __objc_intobj，数值 1。
- iOS 16 分支 0x14a48 使用 SBAppLayout initWithItemsForLayoutRoles:configuration:environment:preferredDisplayOrdinal:，参数 1/1/0；旧分支使用三参数 initializer，configuration/environment 同为 1。
- 0x14a64 指向 0x98ce0 常量 SBMainSwitcherControllerCoordinator；旧分支 0x14aa8 指向 0x98d00 常量 SBMainSwitcherViewController。
- 0x14ad0 调用 _addAppLayoutToFront:。

otool 缺少 otool-classic 后端，未取得新的反汇编；以上使用已有 main-linked 和 main-refs 交叉引用，角色及类名常量另由项目内签名 StaticRefs 只读解析二进制确认，没有加载或执行附件 dylib。

## 本项目实现与边界

ZNSRecentApps 仅在调用入口提交请求后运行，无 constructor/hook。请求弱持有 session，下一主队列周期检查；多任务仍可见或锁屏最多等待约3秒，然后放弃。期间关闭场景则不创建卡片。队列按请求顺序处理，同会话重复请求合并到末尾。

运行时检查 getter/factory/initializer/add 方法的 ABI；已有单 App 卡片复用并前移，不重复制造。不存在时用本 session 的实际 FBScene 标识新建；身份不符、布局不可读或目标为多 App 布局时跳过，不猜测。失败只记日志，不通过全屏启动或重新启动 App 兜底。

当前 `firstInModel` 日志只表明读取到的模型首项，不代表视觉位置或后台卡片快照完整。需要安装后的实机验证确认私有接口语义与卡片显示。

## 隔离测试

`tools/RecentAppsTests.m` 直接包含生产模块，使用本进程模拟类，不加载 SpringBoard，不操作真实后台或屏幕。覆盖：创建参数/场景标识、已有卡片前移且数量不增、关闭与身份失配拒绝、多 App/未知布局拒绝、合并/FIFO顺序、待处理关闭撤销、切换器可见时延迟。

编译：`clang -arch arm64 -fobjc-arc -Wall -Wextra -Werror -framework Foundation -framework UIKit '-DAPELIN_PACKAGE_ID="com.zengniu.splitview"' tools/RecentAppsTests.m -o tools/RecentAppsTests`

签名后运行：`ldid -Stools/Tool.entitlements tools/RecentAppsTests`，`./tools/RecentAppsTests`。
