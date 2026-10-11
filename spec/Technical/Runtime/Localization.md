# 本地化

产品以英文（`en`）为源语言，并提供简体中文（`zh-Hans`）翻译。主应用和 Finder Extension 是独立 Bundle，分别由 `ECMenu/Localizable.xcstrings` 与 `ECMenuFinderExtension/Localizable.xcstrings` 提供运行时字符串；固定产品名不使用 `InfoPlist.strings`。

`ECMenuShared` 以 `LocalizedStringResource` 保存命令等跨端显示语义，不提前解析为文字。主应用和 Extension 在各自的呈现边界通过当前进程的主 Bundle 解析资源，因此状态页、进度窗口和 Finder 菜单共享语义，而资源仍归各自 Bundle 所有。语言选择不进入持久化配置或 IPC。

## 资源流与源码映射

```text
共享命令显示语义（随两个产品分别编译）
  ├─ 主应用呈现 → 主应用 String Catalog → 设置命令名称、进度任务名称
  └─ Extension 呈现 → Extension String Catalog → Finder 菜单文字
```

上图是各进程内部的资源解析关系；“呈现”汇总各自拥有文字的界面模块，具体核心页面见[界面入口](../ViewCatalog.md)。

| 职责模块 / 资源所有者 | 核心类型 / 资源 | 源码入口 | 输入 → 输出 | 外部 API 与边界 |
|---|---|---|---|---|
| 共享显示契约 | `ContextCommandDescriptor`、各能力 Command | [ContextCommandIdentity.swift](../../../ECMenuShared/Contracts/Commands/ContextCommandIdentity.swift)、[能力契约目录](../../../ECMenuShared/Contracts/Commands) | 功能身份与产品显示声明 → `LocalizedStringResource` | Foundation 资源值保留键、默认文案和注释，供使用方解析 |
| 主应用本地化资源 | String Catalog | [Localizable.xcstrings](../../../ECMenu/Localizable.xcstrings) | 资源键与当前语言 → 主应用译文 | 资源归主应用 Bundle；页面与反馈文案由所属能力声明 |
| Extension 本地化资源 | String Catalog | [Localizable.xcstrings](../../../ECMenuFinderExtension/Localizable.xcstrings) | 资源键与当前语言 → Extension 译文 | 资源归 Extension Bundle；随 Extension 进程取得语言 |
| Finder 菜单文字呈现 | `ContextMenuActionTitle`、`FinderContextMenuController` | [ContextMenuAction.swift](../../../ECMenuFinderExtension/Menu/ContextMenuAction.swift)、[FinderContextMenuController.swift](../../../ECMenuFinderExtension/Menu/FinderContextMenuController.swift) | 产品资源或用户模板名称 → 菜单标题 | `String(localized:)` 解析产品资源；用户名称按原文显示 |

主应用的 SwiftUI 页面通过 `Text` 等本地化初始化入口呈现资源；AppKit 进度与告警通过 `String(localized:)` 形成控件文字，入口分别见[设置外壳](../Features/GeneralSettings.md#设置外壳导航与能力页面)、[命令进度](CommandProgress.md)与[通用告警](CommandExecution.md#模块输入输出与所有权)。

## 语言生命周期

产品跟随 macOS 的语言选择，不实现应用内切换。主应用与 Extension 都只保证在进程启动时取得当前语言；语言变化后须重新启动主应用，并重启 Finder 以重新加载 Extension，再检查真实 Finder 菜单，不能只验证主应用或 Preview。

真实 Finder 菜单的自动截图在一次性 guest 中设置 Finder 与当前 Debug containing app 的按应用语言；每种语言只重启 Finder 和 Extension，主应用保持运行。这只是测试编排，不进入产品配置或 IPC。Finder Sync 取得 containing app 语言是 macOS 26.6.1 下根据 PluginKit 启动参数与真实菜单得到的项目观察，不作为 Apple 的跨版本契约；完整事务与复验边界见 [Finder 菜单自动截图](../FinderMenuCapture.md#双语截图)。
