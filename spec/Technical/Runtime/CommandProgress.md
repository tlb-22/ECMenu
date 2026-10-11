# 命令进度

进度能力在主应用内管理确定整数工作量、显示时机和用户取消意图。产品交互见[需求](../../Requirements/CommandProgress.md)，Task 生命周期见[命令执行](CommandExecution.md)。

## 事件与呈现流

```mermaid
sequenceDiagram
    box ECMenu 主应用进程
        participant H as 业务进度报告（Handler 与 Reporter 组合）
        participant C as 进度协调 ProgressCenter
        participant V as 进度面板宿主（Presenter 与窗口组合）
        participant R as 单次命令调用 Invocation
    end
    participant U as 用户
    H->>C: begin(requestID, descriptor, total)
    C->>C: 登记唯一状态；安排延迟 Task
    alt 延迟到达前已结束
        R->>C: finish(requestID)
        Note over C,V: 取消延迟，不显示
    else 仍在执行
        C->>V: render(items, actions)
        V->>U: 自动显示非激活进度面板
        H->>C: advance：一项到达终态
        C->>V: 更新不可变可见快照
        alt 用户点击取消
            U->>V: 取消某个 requestID
            V->>C: actions.cancel(requestID)
            H->>C: 下一项开始前查询取消意图
            C-->>H: true；由能力停止剩余输入
        else 用户关闭面板
            U->>V: 关闭
            V->>C: actions.dismiss()
            Note over C,V: 隐藏当前可见项，任务继续
        end
        H-->>R: Outcome
        R->>C: finish(requestID)
        C->>V: 移除行；空快照释放面板
    end
```

Center 不持有 AppKit 窗口。装配层把它的 `render(items, actions)` 连接到 Presenter；窗口把动作交还 Center，Reporter 仅转发能力事件。关闭面板只隐藏当时可见的任务，后续新任务仍可显示。

## 模块、输入输出与状态

| 职责模块 | 核心类型 | 源码入口 | 输入 → 输出 | 所有权与外部边界 |
|---|---|---|---|---|
| 进度状态规则 | `ContextCommandProgressState`、`ContextCommandProgressItem` | [ContextCommandProgressState.swift](../../../ECMenu/CommandRuntime/Progress/ContextCommandProgressState.swift) | begin / reveal / advance / cancel / finish → 进度事实 | 纯内存状态规则；正总量、单次 begin、不超额推进是实现约束 |
| 命令进度入口 | `ContextCommandProgressReporter`、`ContextCommandExecutionContext` | [ContextCommandProgressReporter.swift](../../../ECMenu/CommandRuntime/Progress/ContextCommandProgressReporter.swift) | 业务事件 → Center 调用；取消查询 → Bool | 只绑定 requestID 与 descriptor，不复制进度状态 |
| 进度协调 | `ContextCommandProgressCenter` | [ContextCommandProgressCenter.swift](../../../ECMenu/CommandRuntime/Progress/ContextCommandProgressCenter.swift) | 事件、用户动作 → render(items, actions) | 唯一拥有进度、显示延迟任务、已隐藏 ID、上次渲染快照；MainActor；`Task.sleep` 与取消 |
| 进度交互契约 | `ContextCommandProgressActions` | [ContextCommandProgressActions.swift](../../../ECMenu/CommandRuntime/Progress/ContextCommandProgressActions.swift) | 窗口事件 → 对应 Center 意图 | cancel/dismiss 闭包弱引用 Center，不提供复制状态的第二个所有者 |
| 进度面板宿主（组合） | `ContextCommandProgressPresenter`、`ContextCommandProgressWindowController` | [ContextCommandProgressPresenter.swift](../../../ECMenu/Feedback/Progress/ContextCommandProgressPresenter.swift)、[ContextCommandProgressWindowController.swift](../../../ECMenu/Feedback/Progress/ContextCommandProgressWindowController.swift) | 可见快照与动作 → 共享面板 / 回调 | Presenter 保活当前窗口；空快照和关闭时释放，窗口管理行与布局 |
| 任务行呈现（组合） | `ContextCommandProgressRowView`、`ContextCommandProgressIconResolver` | [ContextCommandProgressRowView.swift](../../../ECMenu/Feedback/Progress/ContextCommandProgressRowView.swift)、[ContextCommandProgressIconResolver.swift](../../../ECMenu/Feedback/Progress/ContextCommandProgressIconResolver.swift) | 单项快照、descriptor → 原生呈现 | 系统进度条、标签、图标与按钮；不拥有业务计数 |
| 共享图标画布变换 | `AppKitIconCanvasRenderer` | [AppKitIconCanvasRenderer.swift](../../../ECMenuShared/Platform/Rendering/AppKitIconCanvasRenderer.swift) | 已配置源图、场景画布 → 语义居中或等比适配图像 | 复用 Finder 菜单与设置页的无场景图像变换；调用端拥有字号、画布与缓存 |

任务行呈现使用 [ContextCommandProgressWindowLayout.swift](../../../ECMenu/Feedback/Progress/ContextCommandProgressWindowLayout.swift) 集中提供尺寸、图标字号和间距。图中业务报告节点合并 Handler 与 Reporter 的调用；面板宿主节点合并 Presenter 的窗口生命周期与 WindowController 的原生窗口操作。任务行直接配置 `NSProgressIndicator` 并应用当前计数，图标来源解析独立于共享画布变换。

## API 契约与取消边界

| 调用者 / API | 输入 → 输出 | 约束与失败 |
|---|---|---|
| Center / `Task.sleep(for:)` | 显示延迟 → 返回 / CancellationError | 默认一秒；提前结束取消对应延迟 Task。仅仍在执行的任务变为可见 |
| 窗口 / `NSPanel`、`orderFrontRegardless`、NSButton target/action | 快照与动作 → 显示、单项取消、关闭事件 | 使用 nonactivatingPanel；自动出现不调用 NSApp.activate。关闭不是取消 |
| 图标 / `NSImage`、`NSWorkspace`、`NSImage.alignmentRect` | descriptor 视觉来源 / 应用路径、场景字号与画布 → 图像 | Symbol 保持配置后的自然尺寸，按语义主体居中；应用与文件类型图标等比适配且不放大。图标解析和缓存属于呈现，无业务执行权限 |
| 任务行 / `NSProgressIndicator` | `minValue = 0`、`maxValue = totalUnitCount`、`doubleValue = completedUnitCount` → 确定进度和辅助技术数值 | `style = .bar`、`isIndeterminate = false`；`controlSize = .small`，`sizeToFit()` 使用系统推荐高度。外观与焦点配色交给 AppKit；处理计数不是成功输出数 |
| 能力 / 用户取消查询、`Task.isCancelled` | 当前边界 → 是否开始下一项 | 两种取消来源独立；ImageIO 当前项完整结束，用户取消保留结果并反馈，Task 取消由 Invocation 跳过反馈 |

进度对 Handler 是可选能力，只有主动 begin 才登记。图片压缩在确认参数后开始，每个输入的成功或失败都推进一次。多个请求共用面板，不改变批次之间的并发。

取消按钮只表达协作意图，具体能力选择不会破坏输出的响应点。Presenter 不持有业务 Task，不中断文件写入，也没有替代 Center 的可变进度模型。

## 平台边界

Xcode 26.6（17F113）附带的 macOS 26.5 SDK 将 Foundation `Progress` 定义为工作量与取消状态的可观察模型，并提供按文件 URL 发布和跨进程订阅的机制（`NSProgress.h:18–33, 109–121, 210–231`）。文件类型 Progress 的工作单位是字节，文件数量由独立计数表达（`NSProgress.h:81–86, 197–208, 261–288`）。

公开契约没有承诺 Finder 会订阅任意应用发布的任务，Finder Sync 也没有登记第三方文件任务进度的接口。因此产品不依赖 Finder 私有进度界面，而由主应用拥有共享的 AppKit 任务窗口。

`NSProgressIndicator` 提供确定进度的最小值、最大值、当前值和原生辅助功能，`controlSize` 与 `sizeToFit()` 提供系统推荐尺寸（macOS SDK `NSProgressIndicator.h:22–39, 56–58`）。任务行使用这一标准控件，尺寸、绘制和窗口焦点配色由 AppKit 管理。

`NSProgressIndicator` 没有公开的填充颜色属性，已废弃的 `controlTint` 在 macOS 10.15 之后不再生效。项目在 macOS 26.6.1（25G76）观察到，标准进度条位于未激活面板时呈系统非强调色；用户主动使窗口成为 key window 后才呈强调色。该配色是指定系统版本的观察，产品显示进度时不主动激活应用。

图标与 Finder 菜单、设置页面复用共享画布规则：SF Symbol 按 `alignmentRect` 的语义主体中心平移，保持配置后的自然尺寸，超出画布的附属像素由图像边界裁切；应用和文件类型图标按完整图像保持比例适配且不放大小图。进度场景自行提供字号和画布，几何规则及其平台依据见[菜单图标](../Platform/Finder/MenuIcons.md#渲染约束)。

项目观察（2026-09-11，macOS 26.6.2、macOS 26.5 SDK）：压缩图标 `photo.badge.arrow.down` 在 40 pt 画布、23 pt 常规字重下，源图为 36×29 pt，语义对齐区域为 `{{0,8},{33,16}}`，居中后的完整绘制区域为 `{{3.5,4},{36,29}}`。场景字号为角标保留空间，主体对齐仍由共享规则决定。探针标识 `20260911-202749-progress-symbol-geometry-29421`；数值限定于本机系统资源，不作为其他 Symbol 或系统版本的几何保证。

同一环境中的 Finder“转换图像”快速操作采用带图标、名称、进度、取消和剩余时间的独立窗口。该观察只提供当前系统视觉参照，不证明 Finder 内部实现，也不是未来平台契约。

## 验证与实机证据

[虚拟机日常验收](../../../Tests/Main.md)通过实际参数窗口和处理结果验证压缩流程；进度面板的显示、取消、关闭后继续与后续任务显示，只以实际执行的批次和报告确认。[执行与进度例外](../../../Tests/ECMenuTests/CommandRuntime/ContextCommandExecutionTests.swift)保留快速完成先于显示回调、Router 释放取消两个精确生命周期交错，必要性见[单元测试例外](../../../Tests/UnitTestExceptions.md)。

平台观察环境与 SDK 证据见上节。实机复验使用足够长的压缩批次，分别观察面板自动出现、单项取消、关闭后继续及后续新任务再次显示；记录 macOS 版本与前台应用。运行结果归入统一[测试记录](CommandExecution.md#验证入口)，不把仅存在测试定义描述为已经执行通过。
