# 核心界面入口

本页按用户看到的独立界面列出源码路径。页面的局部组件、布局和交互细节从入口文件继续查找；业务流程与 API 边界由对应能力 spec 维护。

## 三个设置页面

| 页面 | View 与源码路径 | 预览 ID |
|---|---|---|
| 通用 | `GeneralSettingsPage` · [GeneralSettingsPage.swift](../../ECMenu/GeneralSettings/Presentation/GeneralSettingsPage.swift) | `status-page-general` |
| 右键菜单 | `CommandMenuSettingsPage` · [CommandMenuSettingsPage.swift](../../ECMenu/CommandMenuSettings/Presentation/CommandMenuSettingsPage.swift) | `status-page-context-menu` |
| 文件模板 | `NewFileTemplateSettingsPage` · [NewFileTemplateSettingsPage.swift](../../ECMenu/NewFileTemplates/Presentation/NewFileTemplateSettingsPage.swift) | `status-page-file-templates`；空库和失败状态分别追加 `-empty`、`-failure` |

三个页面位于同一个设置窗口。页面选择与装配入口是 [StatusPageContent.swift](../../ECMenu/Settings/StatusPageContent.swift)，生产状态和操作连接入口是 [StatusPage.swift](../../ECMenu/Settings/StatusPage.swift)。能力说明见[通用设置](Features/GeneralSettings.md)、[命令菜单配置](Runtime/CommandMenuSettings.md)与[新建文件模板](Features/NewFileTemplates/Main.md)。

## 窗口与弹窗

| 独立界面 | 呈现入口 | 触发与职责 |
|---|---|---|
| 主设置窗口 | `StatusPageWindowController` · [StatusPageWindowController.swift](../../ECMenu/Settings/StatusPageWindowController.swift) | 普通打开应用；创建并保留承载三个页面的唯一窗口，处理显示、最小化、关闭与位置恢复 |
| 图片压缩设置弹窗 | `ImageCompressionSettingsWindowController` · [ImageCompressionSettingsWindow.swift](../../ECMenu/Commands/ImageCompression/Presentation/ImageCompressionSettingsWindow.swift) | 执行压缩命令后收集参数；预览为 `image-compression-settings`，验证错误场景追加 `-validation-error` |
| 模板文件选择面板 | `FileTemplateFileChooser` · [FileTemplateFileChooser.swift](../../ECMenu/NewFileTemplates/Presentation/FileTemplateFileChooser.swift) | 添加或更换模板；配置并显示系统 `NSOpenPanel`，返回选择的文件或取消 |
| 模板操作错误弹窗 | `NewFileTemplateSettingsPage` 的 `.alert` · [NewFileTemplateSettingsPage.swift](../../ECMenu/NewFileTemplates/Presentation/NewFileTemplateSettingsPage.swift) | 模板操作失败时由 `FileTemplatePageActions.errorMessage` 驱动；确认关闭后清除本次错误 |
| 命令警告弹窗 | `CommandAlertPresenter` · [CommandAlert.swift](../../ECMenu/Feedback/CommandAlert.swift) | 命令反馈提供标题与正文，共用系统 `NSAlert` 呈现和确认关闭 |
| 命令进度窗口 | `ContextCommandProgressWindowController` · [ContextCommandProgressWindowController.swift](../../ECMenu/Feedback/Progress/ContextCommandProgressWindowController.swift) | 展示一个或多个耗时任务；预览为 `context-command-progress-single` / `context-command-progress-multiple` |

窗口行为与验证边界分别见[应用生命周期](Runtime/ApplicationLifecycle.md)、[图片压缩](Features/ImageCompression.md)、[模板交互](Features/NewFileTemplates/Editing.md)和[命令进度](Runtime/CommandProgress.md)。系统设置及默认编辑器等外部应用的窗口由对应应用实现。

## 使用与维护

使用 `./scripts/preview-ui.sh <预览 ID>` 打开独立预览，语言和批量截图参数见[界面预览脚本](../../scripts/Main.md#视觉证据与交付)。预览复用生产呈现，异步交互测试与真实系统验收的区别见[Preview 技术边界](PreviewTarget.md)。

新增、移动或删除独立页面、窗口和弹窗时，同步本页入口及相关能力 spec。局部组件继续在所属能力内组织，目录归属见[目录规则](Architecture/DirectoryRules.md)。
