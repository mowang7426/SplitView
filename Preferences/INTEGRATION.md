# 设置面板接入说明（交给主会话）

本子任务只新增 Preferences/ 文件，未修改构建描述、运行时源码，也未构建、安装或提交。无需图标资源，PreferenceLoader 入口不设置 icon。

## Product

在 apelin-project.json 的 products 数组追加以下产品（不要替换现有 tweak 产品）：

```json
{
  "id": "preferences",
  "type": "bundle",
  "name": "ZNSPreferences",
  "sources": ["Preferences/ZNSRootListController.m"],
  "objcARC": true,
  "frameworks": ["Foundation", "UIKit", "Preferences"],
  "extensionSupport": [
    {"extension": "wiki.qaq.apelin.dev.preferences", "component": "preferences"}
  ],
  "infoPlist": "Preferences/Info.plist",
  "resources": ["Preferences/Resources/Root.plist"]
}
```

为 product `preferences` 依次追加 build.steps：compile、link、bundle-resources、lipo、dsym、strip（style: non-global）、sign（identity: adhoc）。沿用项目的部署目标及双 bootstrap 架构配置。

package.depends 追加 `preferenceloader`，保留现有依赖。package.layout 追加：

```json
[
  {
    "path": "/Library/PreferenceBundles/ZNSPreferences.bundle",
    "product": "preferences"
  },
  {
    "path": "/Library/PreferenceLoader/Preferences/ZNSPreferences.plist",
    "file": "Preferences/PreferenceLoader.plist",
    "mode": "0644"
  }
]
```

这些是逻辑包路径，由打包器处理 bootstrap 前缀。勿写入固定 jbroot 路径。Root.plist 需打包到 bundle 根目录，供 loadSpecifiersFromPlistName:@"Root" 加载。

## 运行时约定

- 偏好域：`com.zengniu.splitview`。
- Darwin 通知：`com.zengniu.splitview/changed`，三个可编辑项均声明 PostNotification。
- `Enabled`：布尔值，缺省 `true`。
- `IconGesture`：字符串，允许 `up` / `down` / `both`，缺省 `up`。系统 PSLinkListCell 进入选项列表，中文显示向上滑动／向下滑动／上下均可。
- `ExcludedApps`：原始字符串，缺省空串。运行时按英文逗号分隔，建议 trim 空白并忽略空项；设置面板不将其写成数组。
- 读写使用 PSListController 的默认实现，无 NSUserDefaults 覆盖。未打开设置或未改动的键可能不存在，运行时必须提供上述缺省值。
- 面板只声明基础小窗选项；键盘位置选择、状态栏长按、通知打开、3–7 空挂等只有未接入说明，无开关。

## 后续验证（本子任务未执行）

- 接入构建后核对 bundle 可执行文件名为 ZNSPreferences，入口能打开，简体中文文案显示完整。
- 切换 Enabled，离开再进入设置，核对值持久化及运行时响应。
- 逐项选择 up/down/both，核对保存的值及桌面图标对应滑动方向。
- 输入、修改、清空 ExcludedApps，结束编辑后重新进入，核对值保存及运行时排除行为。
- 核对三个字段写入时的 Darwin 通知接收；设置面板的声明不能代替运行时实测。
- 操作说明提到的小窗按钮、旋转、拖动及缩放由主实现负责，未由本子任务验证。
