# 模板执行流与模块边界

以下流程描述当前源码的模块协作。`Controller`、`Operations`、呈现会话运行在 MainActor；`Library` actor 串行调用同步 `Storage`。AppKit、Foundation 对象仍在主应用进程内；图外的文件系统和默认编辑器分别表示存储边界与另一进程。

## 加载、初始化与显式重试

```mermaid
sequenceDiagram
    autonumber
    box ECMenu 主应用进程
        participant C as 页面状态控制
        participant O as 模板应用操作
        participant L as 模板库
        participant S as 模板文件存储
        participant P as 菜单变更发布
    end
    participant D as 文件系统
    C->>O: loadForManagement：页面加载或 Retry
    O->>L: load()
    alt 已有已提交缓存
        L-->>O: templates + cached
    else 首次读取
        L->>S: 读取 index.json
        S->>D: P01 Data(contentsOf:)
        alt 整个库尚未创建
            L->>S: P02/P03 保存空白 TXT；P04 提交索引
            S->>D: 创建副本并原子写索引
            L->>L: 保存已提交 records
            L->>S: P06 尽力清理未引用副本
            L-->>O: templates + initialized
        else 有效当前索引
            L->>L: 解码并校验 schema 2 索引
            L->>L: 保存已提交 records
            L->>S: P06 尽力清理未引用副本
            L-->>O: templates + restored
        else 索引读取或校验失败
            L-->>O: 明确失败
        end
    end
    alt 读取成功
        O->>P: didChange：重新确认模板可用性
        P-->>P: 发送不含清单的失效提示
        O-->>C: 完整清单
        C->>C: ready，包括有效空清单
    else 读取失败
        O-->>C: 原失败
        C->>C: failed；显示 Retry
    end
```

`loadIfNeeded()` 让启动和页面入口共享一个初始 Task；初始失败也保留该 Task，用户点击 Retry 才通过 `reload()` 再次读取。重试先进入 loading；库有缓存时只返回缓存，无缓存时重新读取并校验索引。初始化的成功路径同样执行维护式孤儿清理；[存储契约](Persistence.md#初始化与恢复)列出初始化失败边界。

[`NewFileTemplateSettingsPage`](../../../../ECMenu/NewFileTemplates/Presentation/NewFileTemplateSettingsPage.swift) 将 `FileTemplatePageState` 映射为三种原生呈现：loading 使用 `ProgressView`，failed 使用 [`ContentUnavailableView(label:description:actions:)`](https://developer.apple.com/documentation/swiftui/contentunavailableview/init(label:description:actions:)) 呈现错误标题、原因与重试按钮，ready 的空清单使用同一状态视图呈现添加说明并保留底部添加入口。状态视图只接收文案和操作闭包，不持有加载任务或模板数据；标题层级、说明与动作的布局由 SwiftUI 管理。

`loadForManagement()` 成功时发送一次提示，即使本次返回缓存，或同时完成初始化；这使之前收到 `.unavailable` 的 Extension 有重新查询机会。生产的普通 `load()`、`content(for:)`、`fileURL(for:)` 只在本次首次读取实际提交了初始化时提示。后两者先完成读取发布，再读取内容或验证打开 URL；即使请求的 ID 随后无法解析，已经发生的初始化提交仍然发布。

| 读取来源 | 库返回的事实 | 普通应用读取是否提示 | 管理页成功加载/重试是否提示 |
|---|---|---|---|
| `cached` | 已提交的进程内 records | 否 | 是 |
| `restored` | 有效当前索引刚恢复 | 否 | 是 |
| `initialized` | 本次首次初始化已提交 | 是 | 是，只发一次 |

这张表只描述发布触发条件。失效提示可能丢失，且不携带配置正文；它不等于 Extension 已应用清单。通知 API、快照中 `.unavailable` 与 `.available([])` 的区分和传输完成点由[菜单配置](../../Runtime/CommandMenuSettings.md)维护。

## 文件类型图标呈现

```mermaid
sequenceDiagram
    box ECMenu 主应用进程
        participant C as 页面状态控制
        participant V as 模板页面
        participant I as 文件类型图标适配
        participant W as AppKit NSWorkspace
    end
    C-->>V: ready：加载或提交后的模板清单
    V->>I: 已保存的 defaultFileName
    I->>I: V05 后缀转换为 UTType
    I->>W: V06 icon(for: 内容类型)
    W-->>I: 系统文件类型图标 NSImage
    I-->>V: NSImage
    V->>V: 按独立尺寸缩放，与名称一起呈现
```

图标位于排序提示和两行名称之间，与名称组成内部 `HStack` 并整体垂直居中。页面顶部的 `NewFileTemplatesStyle.templateIconSize` 独立控制图标尺寸，保持原图比例；`iconNameSpacing` 控制图标与名称控件之间的间距，外层排序提示和操作按钮的间距由 `rowSpacing` 控制。图标是装饰性内容，不接收点击，也不成为辅助功能节点；拖动由所在行处理。

页面直接根据已提交模板的 `defaultFileName` 取图标。名称草稿和提交失败保留原图标，成功提交后随 ready 清单更新；设置页图标不形成新的可变状态或持久化字段。Finder 通过菜单快照接收同一后缀，并在 Extension 内查询与适配图标，见[菜单图标](../../Platform/Finder/MenuIcons.md#文件类型图标)。后缀用于提示文件类型，不验证内部副本的内容格式，也不读取文件缩略图或单文件自定义图标。

| 职责模块 | 核心类型 | 源码入口 | 输入 → 输出；拥有的状态 | 外部 API |
|---|---|---|---|---|
| 模板页面 | `NewFileTemplateSettingsPage`、`NewFileTemplatesStyle` | [页面与布局参数](../../../../ECMenu/NewFileTemplates/Presentation/NewFileTemplateSettingsPage.swift) | 已提交模板、NSImage → 行内图标；尺寸属于呈现参数 | SwiftUI `Image(nsImage:)`、比例缩放与布局；不执行文件 I/O |
| 文件类型图标适配 | `FileTypeIconProvider` | [FileTypeIconProvider.swift](../../../../ECMenuShared/Platform/Rendering/FileTypeIconProvider.swift) | 默认文件名 → 系统图标 NSImage；无应用自有缓存 | V05、V06；由页面在 MainActor 同步调用 |

## 导入、更换与删除

行尾的打开、更换和删除使用原生无边框图标按钮，保留本地化悬停提示与辅助功能名称；三个按钮共用 `NewFileTemplatesStyle` 的图标字号和按钮边长。打开使用 `text.document`，更换使用 `arrow.left.arrow.right`，删除使用红色 `trash`。

```mermaid
sequenceDiagram
    autonumber
    box ECMenu 主应用进程
        participant V as 页面与操作会话
        participant C as 页面状态控制
        participant O as 模板应用操作
        participant L as 模板库
        participant S as 模板文件存储
        participant P as 菜单变更发布
    end
    V->>V: 先完成名称编辑，再取得文件操作占用
    opt 导入或更换
        V->>V: V01 文件选择器返回 URL；取消则结束
    end
    V->>C: URL / 模板 ID
    C->>C: isUpdating；保持 ready 清单
    C->>O: 类型化管理操作
    O->>L: 确认读取后执行变更
    opt 导入或更换
        L->>S: P05 读取普通文件；P02/P03 保存全新副本
    end
    L->>S: P04 提交完整索引
    alt 索引已提交
        L->>L: 替换 records
        opt 更换或删除
            L->>S: P06 尝试清理旧副本目录
            S-->>L: 清理完成或 CleanupIssue
        end
        L-->>O: Commit：已提交清单，含可能清理问题
        O->>P: didChange：一次提交提示
        opt 更换且清理失败
            O->>O: V03 记录清理问题
        end
        O-->>C: FileTemplateCommit
        C->>C: 先应用 ready 清单并释放更新占用
        alt 删除且清理失败
            C-->>V: 已提交后报告清理错误
            V->>V: V02 显示错误
        else 操作完成
            C-->>V: 正常完成
        end
    else 提交前失败
        L->>S: 准备过新副本时，P06 尽力清理它
        L-->>O: 原始失败；原索引保持有效
        O-->>C: 原始失败，不发布提交
        C-->>V: 保留 ready 清单，释放更新占用并报错
    end
```

源文件读取或副本准备失败也直接走提交前失败路径，不写索引；准备过程中自身的部分写入由 Storage 尽力清理。已确认的名称提交和后续文件选择是两个完成点，取消选择不撤回名称修改。文件操作开始后没有用户取消入口，视图消失取消的只是进度指示器延迟显示任务。

| 职责模块 | 核心类型 | 源码入口 | 输入 → 输出；拥有的状态 | 外部 API |
|---|---|---|---|---|
| 页面与操作会话 | `NewFileTemplateSettingsPage`、`FileTemplatePageActions` | [页面](../../../../ECMenu/NewFileTemplates/Presentation/NewFileTemplateSettingsPage.swift)、[文件操作会话](../../../../ECMenu/NewFileTemplates/Presentation/FileTemplatePageActions.swift) | 用户意图、编辑会话 → 名称提交后执行文件操作；会话拥有 phase 和错误消息，跨页面重建保留 | V02；操作调度使用 Task，无文件 I/O |
| 文件选择器 | `FileTemplateFileChooser` | [FileTemplateFileChooser.swift](../../../../ECMenu/NewFileTemplates/Presentation/FileTemplateFileChooser.swift) | 面板标题 → 一个 URL 或取消 nil | V01 |
| 页面状态控制 | `FileTemplateController`、`FileTemplatePageState` | [Controller](../../../../ECMenu/NewFileTemplates/Presentation/FileTemplateController.swift)、[状态模型](../../../../ECMenu/NewFileTemplates/Presentation/FileTemplatePageState.swift) | 读取/修改意图 → ready/failed 页面状态；持有初始加载 Task 和更新占用 | Combine `@Published`，无存储/通知 API |
| 模板应用操作 | `FileTemplateOperations` | [FileTemplateOperations.swift](../../../../ECMenu/NewFileTemplates/Application/FileTemplateOperations.swift) | 管理意图/读取请求 → 清单、内容、URL 或 Commit；协调发布，不持有索引副本 | 调用注入边界；仅更换清理日志使用 V03 |
| 模板库 | `FileTemplateLibrary` | [FileTemplateLibrary.swift](../../../../ECMenu/NewFileTemplates/Persistence/FileTemplateLibrary.swift) | 管理意图 → 权威提交结果；唯一拥有 records，串行组合名称规则、副本准备、提交与清理 | 调用 Storage，无直接系统调用 |
| 模板名称规则 | `FileTemplate`、`FileTemplateNameField`、`FileTemplateImportNaming` | [有效模型](../../../../ECMenu/NewFileTemplates/Domain/FileTemplate.swift)、[单字段更新](../../../../ECMenu/NewFileTemplates/Domain/FileTemplateNameField.swift)、[导入命名](../../../../ECMenu/NewFileTemplates/Domain/FileTemplateImportNaming.swift) | 源文件名、现有清单或单字段值 → 有效模板/验证失败 | 纯规则，无外部 I/O |
| 模板文件存储 | `FileTemplateStorage` | [FileTemplateStorage.swift](../../../../ECMenu/NewFileTemplates/Persistence/FileTemplateStorage.swift) | 路径、Data、索引记录 → 已读取字节、已完成写入或类型化失败；拥有每次打开的 handle 生命周期 | [P01–P06](Persistence.md#文件-api-与完成点) |
| 默认应用打开适配 | `FileTemplateOpener` | [系统实现](../../../../ECMenu/NewFileTemplates/Platform/FileTemplateOpener.swift) | 内部副本 URL → 打开请求成功或失败；不持有编辑器状态 | V04 |
| 菜单变更发布 | `MenuChangePublisher` | [MenuChangePublisher.swift](../../../../ECMenu/CommandMenuSettings/Application/MenuChangePublisher.swift) | 已提交清单或可用性重新确认 → 分布式失效提示；不保存清单 | [菜单配置](../../Runtime/CommandMenuSettings.md)的 `DistributedNotificationCenter` 边界 |

## 调整模板顺序

```mermaid
sequenceDiagram
    autonumber
    actor U as 用户
    box ECMenu 主应用进程
        participant V as 模板页面与原生列表（组合）
        participant E as 名称编辑会话
        participant C as 页面状态控制
        participant O as 模板应用操作
        participant L as 模板库
        participant S as 模板文件存储
        participant P as 菜单变更发布
    end
    U->>V: 从排序提示或行内非控件区域开始拖动
    V->>E: 退出名称编辑并立即提交
    Note over E,S: 名称遵循单字段提交流程，独立保存
    U->>V: 移动指针，查看插入位置
    alt 取消拖动或顺序未变
        V->>V: 清除拖动呈现，不提交顺序
    else 完成有效移动
        V->>V: onMove 下标转换为稳定 ID 移动意图
        V->>E: PageActions 等待同一次名称提交
        alt 名称保存失败
            E-->>V: 保留草稿与焦点，不提交顺序
        else 名称已保存或没有编辑
            V->>C: moveTemplate(ID, before: 目标 ID 或末尾)
            C->>O: moveTemplate(id:before:)
            O->>L: move(id:before:)
            L->>L: 从当前权威 records 计算位置
            alt 当前顺序确实变化
                L->>S: P04 原子提交完整索引一次
                alt 提交成功
                    L->>L: 替换 records
                    L-->>O: committed，携带有序清单
                    O->>P: didChange：发布一次失效提示
                    O-->>C: FileTemplateCommit
                    C-->>V: 应用新的 ready 清单
                else 提交失败
                    L-->>C: 经 Operations 返回存储错误
                    C-->>V: 保留原清单，显示错误
                end
            else 当前顺序未变
                L-->>C: 经 Operations 返回 nil，不保存或发布
            end
        end
    end
```

系统 List 持有拖动预览与插入提示，不提前改写 Controller 或 Library 的已提交顺序。开始拖动触发的名称保存独立完成；`onMove` 产生稳定 ID 移动意图后，通过 `FileTemplatePageActions` 等待同一名称提交，成功后执行排序，失败时保留名称草稿与编辑焦点，不提交顺序。顺序操作从 Library 的最新记录移动模板，因此保留已提交名称与文件引用。取消排序不撤销名称提交；名称焦点与系统提示音反馈见[编辑会话](Editing.md#入口取消与后续操作)。

图中的“模板页面与原生列表（组合）”由 [NewFileTemplateSettingsPage](../../../../ECMenu/NewFileTemplates/Presentation/NewFileTemplateSettingsPage.swift)、`FileTemplatePageActions`、共用 `SettingsReorderList` 与 `SettingsReorderHandle` 组成。列表将系统移动下标转换为稳定 ID；源码映射与拖动、键盘、辅助功能 API 输入输出由[设置列表排序交互](../../Runtime/CommandMenuSettings.md#设置列表排序交互)维护。本页面连接名称提交与模板移动业务回调。

排序调用沿用上方页面状态控制、模板应用操作、模板库、存储与发布模块。`FileTemplateController.moveTemplate(id:before:)` 持有本次更新占用，接收提交结果后更新 ready；`FileTemplateOperations.moveTemplate(id:before:)` 仅对实际 Commit 发布；`FileTemplateLibrary.move(id:before:)` 在 actor 当前记录中按 ID 移位，nil 目标表示末尾，顺序未变返回 nil。模板或目标 ID 已不存在时返回 `templateNotFound`。排序只调用 [P04 索引提交](Persistence.md#文件-api-与完成点)，不读取或修改内部副本文件。

## 打开内部副本与外部编辑

```mermaid
sequenceDiagram
    autonumber
    box ECMenu 主应用进程
        participant C as 页面与操作会话 / 页面状态控制
        participant O as 模板应用操作
        participant L as 模板库 / 模板文件存储
        participant W as 默认应用打开适配
        participant N as 新建文件用例
    end
    participant D as 内部副本文件
    box 外部编辑器进程
        participant E as 默认应用
    end
    C->>C: 完成名称编辑并取得文件操作占用
    C->>O: openTemplate(ID)
    O->>O: load：必要的初始化先发布
    O->>L: fileURL(ID)
    L->>D: P05 打开并验证普通文件，不读全部内容
    alt 验证通过
        L-->>O: 当前已提交副本 URL
        O->>W: openFile(URL)
        W->>W: V04 NSWorkspace.open(URL)
        alt 系统接受打开请求
            W-->>O: Void，正常返回
            W->>E: 系统请求默认应用打开
            E->>D: 用户在编辑器中保存
        else 系统拒绝打开
            W-->>O: throws FileTemplateOpenError
        end
        N->>O: 后续创建通过 content(ID) 取值
        O->>L: 读取当前元数据与全部字节
        L->>D: P05 重新读取文件内容
        L-->>O: FileTemplateContent 或读取失败
    else ID 或文件失效
        L-->>O: 明确失败，不调用默认应用
    end
```

“后续创建”由[新建文件用例](../NewFile.md)调用，不依赖管理页继续存在。打开本身不提交索引、不设置 Controller 的 `isUpdating`，仍受文件操作会话占用约束。`FileTemplateOpener` 只请求系统打开文件；外部应用如何显示、编辑与保存不属于它的完成回执。返回 URL 到默认应用重新打开之间也不是文件锁定事务。[外部内容边界](Persistence.md#文件打开与更换)说明并发保存和旧 URL 的影响。

| API / 调用者 | 实际输入与输出 | 完成点、失败与约束 |
|---|---|---|
| **V01** FileChooser：`NSOpenPanel.beginSheetModal(for:)` / `begin` | 标题、当前 key window；只选一个文件，禁止选目录，包按目录浏览 → `ModalResponse`，`.OK` 读取 `panel.url` | MainActor；其他响应返回 nil，`.OK` 缺 URL 属于实现不变量错误。面板只收集选择，普通文件验证交给 Storage |
| **V02** 页面：SwiftUI `.alert` | 操作会话中的本地化错误消息 → 用户可关闭的提示 | 主应用呈现状态，不改变已经提交的索引；名称提交失败由[编辑会话 E08](Editing.md#原生-api-输入输出)反馈 |
| **V03** Operations：`Logger.error` | 更换已提交后的 `FileTemplateCleanupIssue.localizedDescription` → 日志 | 无业务成功回执，不撤回提交；原清理问题仍包含在返回 Commit 中 |
| **V04** [FileTemplateOpener](../../../../ECMenu/NewFileTemplates/Platform/FileTemplateOpener.swift)：`NSWorkspace.shared.open(URL)` | 当前内部副本 URL → Bool | MainActor；false 转 `couldNotOpen`，true 表示系统打开请求成功，不表示编辑器已经显示或保存。使用同步 Bool 变体，见 [Apple API](https://developer.apple.com/documentation/appkit/nsworkspace/open(_:)) |
| **V05** IconProvider：`NSString.pathExtension`、[`UTType(filenameExtension:)`](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/init(filenameextension:conformingto:)) | 默认文件名 → 后缀字符串 → 可选 UTType，默认要求符合 `.data` | 无法匹配已声明类型时，系统可能返回动态类型；无效参数返回 nil，项目使用 `.data`。动态类型继续交给系统图标 API；不访问模板文件 |
| **V06** IconProvider：[`NSWorkspace.shared.icon(for:)`](https://developer.apple.com/documentation/appkit/nsworkspace/icon(for:)) | UTType → NSImage | 查询对应内容类型的图标，操作失败由系统返回默认图标，不抛错。项目在 MainActor 消费返回图片，由 SwiftUI 控制显示尺寸 |

图中的读取、提交、验证和清理 API 统一在[存储表 P01–P06](Persistence.md#文件-api-与完成点)展开；默认编辑器没有由 ECMenu 调用的保存 API。

## 状态所有权

| 状态 | 唯一所有者与生命周期 | 更新/消费边界 |
|---|---|---|
| 已提交模板记录 | Library actor，主应用进程级 | 首次恢复与索引提交成功后更新；内容字节每次读取 |
| 页面 ready/failed 与初始加载 Task | Controller，配置窗口使用的呈现模型 | 读取结果或 Commit 更新；存储失败保持原 ready |
| 文件操作 phase 与错误 | PageActions，状态页窗口会话 | 先结束名称、再选择/执行，defer 释放；页面切换不释放占用 |
| 字段草稿、提交 Task 与最后目标 | NameDraft / NameEditingSession，状态页窗口会话 | [名称编辑流程](Editing.md)控制焦点与结果 |
| 拖动预览、插入位置与滚动 | 系统 List，一次原生拖动期间 | 完成移动通过 onMove 输出下标；共用组件转换为稳定 ID，不修改业务清单 |
| 拖动开始时的名称提交引用 | 模板页面持有名称 Task 引用，一次拖动期间 | 完成移动消费同次名称结果后调用业务移动；结束时释放引用，不取消名称任务 |
| `FileTemplateContent` | 单次调用返回的不可变值 | 新建文件用例消费，不暴露库路径 |
| 读取来源与 Commit | 一次调用的不可变事实 | Operations 决定是否发布；不另存可变“需要发布”标记 |
| 菜单副本 | Finder Extension 的 Replica | 经 IPC 整体应用，包含 ID、显示名与默认文件名后缀；不承担模板持久化 |

## 验证证据与限制

[虚拟机日常验收](../../../../Tests/Main.md)在真实模板管理页完成导入、两个名称字段编辑、原生拖动、更换与删除，再从 Finder 子菜单创建文件核对索引顺序、模板身份与内容。真实重开应用检查已提交名称和顺序的恢复；修改源文件后再次创建用于检查保存副本的独立性。

图标使用[独立 Preview](../../PreviewTarget.md)产生可检查截图，并在真实页面与 Finder 菜单中观察。V05/V06 的返回语义来自 Apple 契约；具体外观取决于当前系统类型与图标资源，既有观察环境见[界面验证记录](../../Architecture/Verification.md#界面与真实-finder)。

提交结果、错误提示与通知同步以本轮实际流程报告为准。已有带版本的系统观察见[存储证据](Persistence.md#验证与实机证据)和[原生焦点证据](Editing.md#原生焦点证据与验收)；默认编辑器保存、输入法和窗口切换结论限定于实际执行的场景。
