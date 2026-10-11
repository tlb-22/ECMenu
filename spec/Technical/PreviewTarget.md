# 界面预览目标

界面预览由独立的沙箱 macOS App target 承载。它在单独进程中复用生产 renderer 和共享契约，只在开发边界注入合成状态；产品主应用不包含预览分支，预览应用也不启动 IPC、嵌入 Finder Extension、参与产品归档或改变正在运行的产品生命周期。

文件模板预览通过内存快照和操作回调覆盖列表、空清单与载入失败，不访问产品模板库。列表中的名称编辑只更新预览会话内的对应字段；打开和更换操作不访问外部应用或文件。

预览场景自身不执行 UI 自动化。唯一 Composition 注册全部 Preview ID，稳定 runtime 解析 ID、验证注册唯一性并维持对应会话；各 Case 以独立 ID 固定一种可见状态，并复用生产呈现类型或呈现边界。完整测试保证 Preview target 可编译且入口可列出；可见结果通过人工检查，原生列表拖动和名称点击由实际产品桌面验收验证。

## 职责与源码映射

启动脚本把 Preview ID 与语言参数交给独立进程，runtime 从注册表选择 Case 并保活它返回的界面会话。批量截图时，runtime 另以窗口就绪和捕获后确认协议与脚本协作。

| 职责模块 | 核心类型或脚本与源码入口 | 输入、输出与状态所有权 |
|---|---|---|
| 构建、启动与截图编排 | [preview-ui.sh](../../scripts/preview-ui.sh)、[capture-previews.sh](../../scripts/capture-previews.sh) | Preview ID、语言 → 通过 `xcodebuild` 构建并启动独立产物；批量脚本持有捕获进程和输出文件，依据 `READY` 窗口编号通过 GUI launchd 启动已授权的 `FinderMenuAutomation window-image`，使用 ScreenCaptureKit 捕获 |
| 独立进程入口 | `ECMenuPreviewsApp` / `PreviewApplicationDelegate` · [PreviewApp.swift](../../Tests/ECMenuPreviews/PreviewApp.swift) | AppKit 启动通知 → 查询场景列表或呈现指定场景；入口保活代理并管理 `NSApplication` 事件循环 |
| 场景注册 | `PreviewComposition` · [PreviewComposition.swift](../../Tests/ECMenuPreviews/PreviewComposition.swift) | 具体 Case 类型 → 唯一的 ID 与呈现入口注册表；纯内存声明 |
| 会话与截图协议 | `PreviewRuntime` / `PreviewReadinessCoordinator` · [PreviewRuntime.swift](../../Tests/ECMenuPreviews/PreviewRuntime.swift) | 启动参数与注册表 → 当前 Case 会话或错误界面；runtime 保活会话，协调器在主 RunLoop 检查 AppKit 窗口焦点、编号与布局，并通过标准输出发布 READY 与结果，通过 SIGUSR1 接收截图完成信号 |
| 场景状态与生产界面装配 | [Cases/](../../Tests/ECMenuPreviews/Cases/)，设置页共用 `StatusPagePreviewSession` · [StatusPagePreview.swift](../../Tests/ECMenuPreviews/Cases/StatusPagePreview.swift) | 固定场景参数 → SwiftUI/AppKit 界面；各会话拥有内存状态与操作回调。README 场景在 [READMEStatusPagePreview.swift](../../Tests/ECMenuPreviews/Cases/READMEStatusPagePreview.swift) 通过 `NSWorkspace` 读取真实应用图标 |

生产页面和窗口入口见[核心界面入口](ViewCatalog.md)。同一主题的多个可见状态可以在一个 Case 文件中定义，共用该主题的参数和会话。

## 原生交互验证与平台证据

真实模板页面的点击聚焦、键盘输入、名称保存、原生拖动与最终持久化通过[虚拟机日常验收](../../Tests/Main.md)验证。独立 Preview 提供固定内存状态和可检查截图，承担界面呈现与交互诊断；它不证明生产索引、用户偏好或异步文件操作已完成。

项目观察（2026-09-08，macOS 26.6.2、Xcode 26.6）：在本进程隐藏窗口实验中，SwiftUI 的 `AccessibilityNode` / `AccessibilityLazyLayoutNode` 实现了公开的 Objective-C 可访问性方法，但没有声明 `NSAccessibilityProtocol` 协议；按协议转换过滤子节点会遗漏真实控件。具体类名只用于描述此版本的观察，不作为跨系统保证或驱动依赖。

项目观察（2026-09-09，macOS 26.6.2、Xcode 26.6）：[GitHub Actions 运行 34305654097](https://github.com/tlb-22/ECMenu/actions/runs/34305654097) 中六项隐藏窗口按钮检查读到空树。独立进程探针中，布局及调用窗口 `orderBack` 后均未建立 SwiftUI 节点，本进程角色查询后节点出现；在 `AXIsProcessTrusted() == false` 的沙箱进程中，该查询也成功。Apple 的 [NSHostingView](https://developer.apple.com/documentation/swiftui/nshostingview) 契约提供 AppKit 桥接与可访问性访问接口；上述节点初始化行为属于此版本的项目观察，不是节点同步发布或跨版本时序保证。真实窗口验收仍需等待目标控件就绪，并以最终输入落点和持久化结果作为通过依据。

## 原生列表交互诊断

排序和名称编辑通过实际产品桌面验收，定义见 [Tests](../../Tests/Main.md)。预览只生成固定状态的视觉证据。

## 语言与批量截图

启动脚本可向单次预览进程传入 `-AppleLanguages (en)` 或 `-AppleLanguages (zh-Hans)`，分别检查英文和简体中文；未指定时不覆盖系统语言。语言只存在于进程启动参数中，预览和产品界面无需维护额外的 Locale 状态。

批量截图脚本构建一次 Preview target，从注册表验证全部或调用方指定的场景，并串行捕获每个场景的英文和简体中文版本。Preview runtime 负责激活唯一可见顶层窗口；窗口成为 key window、完成布局和绘制，且窗口编号与尺寸跨一轮主循环保持稳定后，才通过标准输出发送 `READY <windowNumber>`。脚本按该窗口编号生成不含阴影的独立窗口截图，圆角外保持透明；截图完成后，runtime 再确认应用与窗口在整段捕获期间没有失焦，只保留通过确认的图片。截图不依赖辅助功能或外部模拟点击。自动化在独立 guest 中串行执行，整轮由宿主 VM 运行锁管理；手动交互预览使用独立的宿主操作锁。

原生 `window-image` 入口在捕获前创建并完成 AppKit 应用初始化，与其他桌面命令使用相同启动边界。2026-10-11 在 macOS 26.6.2、Xcode 27.0 来宾中，运行标识 `20261011-065806-vm-previews-84977` 完成全部 12 个场景的中英文 24 张 PNG 捕获、导出及清理；人工抽查四张未发现布局问题。生成成功表达窗口与截图协议完成，全部视觉状态仍以实际截图检查为准。

README 设置页场景分别覆盖通用、右键菜单和文件模板三个页面，与状态覆盖场景使用不同 Preview ID：前者固定全部开关开启，并在 Preview 边界通过 Launch Services 严格读取所需外部应用的真实图标；后者继续保留未批准、未启用和应用缺失等状态。README 文件模板页面依次使用 TXT、Markdown、Word 三条内存样例，对应 `.txt`、`.md`、`.docx` 后缀。两者只共享生产 renderer 与无副作用的预览会话，不向产品代码加入文档截图分支。

构建、启动与截图参数见[开发脚本](../../scripts/Main.md#视觉证据与交付)。
