# 模板存储与内容契约

加载、变更、打开与发布的调用关系见[执行流](Flows.md)。本页维护模板数据身份、存储提交和系统 I/O 的边界。 [FileTemplateLibraryError](../../../../ECMenu/NewFileTemplates/Domain/FileTemplateLibraryError.swift) 与同文件的 `FileTemplateFileOperation` 定义跨存储调用返回的失败及操作种类。

## 模板身份与名称

模板由软件生成的唯一、稳定 `FileTemplateID` 标识，显示名和默认输出文件名均允许重复；它们不作为存储键、内容查找依据或命令身份。菜单项按 ID 绑定用户选择，主应用按同一 ID 读取当前模板。已经删除或不可读取的模板返回运行时失败，不按名称寻找替代项。

模板 ID 和文件副本 UUID 是两份不同的身份。名称修改保留二者；更换只改变文件副本 UUID 和导入文件名，保留模板 ID、名称与清单顺序。完整元数据由主应用 [FileTemplate](../../../../ECMenu/NewFileTemplates/Domain/FileTemplate.swift) 拥有；跨端仅共享 [ID](../../../../ECMenuShared/Contracts/NewFileTemplates/FileTemplateID.swift) 和[菜单描述](../../../../ECMenuShared/Contracts/NewFileTemplates/FileTemplateMenuItem.swift)，菜单描述含 ID、显示名和用于类型图标的默认文件名后缀。

排序只移动权威记录数组中的位置，保留记录中的模板 ID、名称、文件副本 UUID 与导入文件名。菜单快照按同一记录顺序投影；不另存排序索引，也不按显示名定位模板。导入追加到清单末尾，删除保留其余模板的相对顺序。

## 模板库持久化

模板库位于 Foundation 返回的用户 Application Support 目录下，以当前主应用 signing identifier 隔离产品身份：

```text
~/Library/Application Support/<application-signing-identifier>/FileTemplates/
├── index.json
└── Files/
    └── <文件副本 UUID>/
        └── <导入文件名>
```

Application Support 用于应用管理的用户数据，按应用身份设置子目录符合 [Apple 目录约定](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/MacOSXDirectories/MacOSXDirectories.html)。Debug 与 Release 的身份值见[构建身份](../../Delivery/BuildIdentity.md)。默认根目录只在真正访问库时解析，依赖装配和预览构造不读取生产身份。

源码能力目录使用 `NewFileTemplates`，磁盘目录名 `FileTemplates` 属于独立的存储契约。

`index.json` 是模板清单的唯一持久化来源，当前 schema 为 `2`，`templates` 按菜单顺序保存。每项的 `template` 保存模板 ID、显示名和默认文件名，`file` 保存独立的文件副本 UUID 和导入文件名。记录及文件引用定义见 [FileTemplateRecord](../../../../ECMenu/NewFileTemplates/Persistence/FileTemplateRecord.swift)，版本校验与编码入口见 [FileTemplateIndex](../../../../ECMenu/NewFileTemplates/Persistence/FileTemplateIndex.swift)。解码拒绝重复模板 ID、重复文件副本 UUID 和越出单文件名范围的内容名称。

文件副本与索引作为一套业务数据备份和恢复。界面偏好及功能显示开关有各自的 UserDefaults 所有者，不属于模板索引事务。

## 初始化与恢复

只有模板根目录尚不存在，且索引读取确认为文件缺失时，才创建空白 TXT 初始模板。有效空清单表示用户已删除全部模板，重启不补回。索引只接受 schema `2`；已有根目录的索引缺失、损坏、版本不支持或读取失败是明确失败，不重写索引或清理内容。

初始化先建立副本目录并保存零字节内容，再提交索引。若索引提交失败，根目录可能已经存在而索引缺失；普通读取重试不会把这一状态解释为全新模板库，也不承诺自动修复。初始索引成功后才保存 actor 的 records。首次有效恢复或初始化执行维护式孤儿清理，清理问题记日志。

首次读取完成后，Library 仅缓存已提交记录；后续 `load()` 返回缓存，管理页 Retry 也不检测外部对索引的修改。无缓存时重试可以重新读取用户已经修复的索引。读取来源通过 [FileTemplateLoadResult](../../../../ECMenu/NewFileTemplates/Persistence/FileTemplateLoadResult.swift) 一次性返回，供应用层决定[发布时机](Flows.md#加载初始化与显式重试)。

## 提交与清理结果

导入和更换先完整写入新的独立副本，再原子替换索引。索引写入返回成功之后，Library 才替换进程内 records。提交失败时保留旧清单和内容，尝试清理未提交的新副本；这次清理若失败只记日志，继续抛原始提交错误。

排序在 Library actor 内从当前已提交记录计算新位置；实际顺序变化时只执行一次 P04 索引提交，不读写或清理内容副本。写入失败保留原记录顺序，页面继续呈现原清单并报告错误；顺序未变化时不写索引，也不发布变更提示。

库变更方法返回的 [FileTemplateCommit](../../../../ECMenu/NewFileTemplates/Domain/FileTemplateCommit.swift) 表示已提交事实：

| 结果 | 已发生的变化 | 应用发布与界面处理 |
|---|---|---|
| 抛出验证或库错误 | 此次管理变更尚未提交；原索引仍有效 | 不发布此次提交，已有 ready 页面和草稿保持 |
| `committed(templates)` | 索引和 actor 记录已经更新，所需清理完成 | Operations 提示一次，Controller 应用清单 |
| `committedWithCleanupIssue(templates, issue)` | 索引与记录已经更新，旧副本目录未能清理 | 同样先发布并应用清单；删除呈现 `issue.failure`，更换记日志后正常完成 |

`FileTemplateCleanupIssue` 只表达副本目录删除失败，携带 URL 与不可变底层错误快照，不允许把其他存储失败当作提交后的清理问题。索引不再引用的残留副本由后续进程首次有效恢复时的孤儿清理重新尝试；普通缓存查询不会再次清理。

元数据索引替换与文件副本创建/删除是多个文件系统操作。接口明确它们的提交顺序，不把它们描述为横跨多个文件的原子事务或断电持久性保证。

## 文件打开与更换

内部副本保留导入文件名及扩展名，让系统默认应用按文件类型打开它。默认输出文件名是另一项设置，不决定内部副本的打开方式。无扩展名普通文件可导入，系统拒绝打开时由管理页呈现错误。

打开入口提供当前已提交副本 URL，先验证实际打开对象为普通文件；验证不读取完整内容。新建文件每次通过 `content(for:)` 读取当前元数据和实际字节，返回独立的 [FileTemplateContent](../../../../ECMenu/NewFileTemplates/Domain/FileTemplateContent.swift)。应用不缓存内容、不监听外部编辑过程，也不保证与外部写入重叠的读取具有事务快照语义。

更换创建新的副本 UUID，所以外部编辑器稍后保存旧 URL 不会改变新索引引用的内容。旧路径可能被编辑器重新建立；它不再属于当前模板。默认应用打开的 Bool 完成点和交互流程见[打开内部副本](Flows.md#打开内部副本与外部编辑)。

## 文件 API 与完成点

以下 API 均由 [FileTemplateStorage](../../../../ECMenu/NewFileTemplates/Persistence/FileTemplateStorage.swift) 在 Library actor 的串行操作内调用，属于主应用内的 Foundation/Darwin 边界，不是另一个进程。

| 编号 / 能力 | 实际输入与 API | 输出与消费方式；失败与约束 |
|---|---|---|
| **P01 索引读取** | index URL → `Data(contentsOf:)`；失败后结合 `FileManager.fileExists(atPath:)` 判断整个库是否尚不存在 | Data 或错误。仅“索引缺失且根目录不存在”返回未初始化；其他错误映射 `.readIndex`。JSON 解码校验由 Library / Index 完成 |
| **P02 副本目录准备** | Files 根目录和全新 UUID 目录 → `FileManager.createDirectory(at:withIntermediateDirectories:)` | Void 或错误；根目录允许补中间目录，新副本目录不允许。失败为 `.prepareDirectory` |
| **P03 独立副本写入** | 完整 Data、新副本 URL → `Data.write(to:options: .withoutOverwriting)` | Void 表示内容写入完成，但模板尚未进入索引；错误为 `.saveContent`，尝试清理新目录 |
| **P04 索引提交** | 已验证记录 → `JSONEncoder.encode`；完整 Data、index URL → `Data.write(to:options: .atomic)` | 写入返回才更新 records；失败为 `.saveIndex`。固定有效编码结构的编码失败属于实现错误，不静默兜底 |
| **P05 普通文件验证/读取** | 文件 URL → `Darwin.open`，选项 `O_RDONLY \| O_NOFOLLOW \| O_NONBLOCK`；fd → `fstat`；需要内容时 `FileHandle.readToEnd()` | 最终路径为符号链接或实际打开对象不是普通文件时为 `.unsupportedFile`；open/stat/read 系统失败为 `.readContent`。nil 读取结果表示空 Data；defer 关闭 handle，关闭错误不单独呈现 |
| **P06 删除/孤儿清理** | 副本目录 URL → `FileManager.removeItem(at:)`；Files URL → `contentsOfDirectory(at:includingPropertiesForKeys:)` | 文件缺失视为已清理，其他删除失败形成 CleanupIssue。维护式枚举/清理失败用 `Logger.error` 记录；提交后的显式清理问题交给 Commit |

P03 与 P04 的写入选项承担不同职责。Xcode 26.6（17F113）的 macOS 26.5 SDK `NSData.h:25–27` 明确 `.withoutOverwriting` 防止替换既有文件，并且不能与 `.atomic` 组合；官方选项入口见 [NSData.WritingOptions](https://developer.apple.com/documentation/foundation/nsdata/writingoptions)。它不公开 Foundation 的内部系统调用，也不提供任意写入中断的 crash-atomic 保证。

P05 的普通文件限制来自项目对实际已打开 fd 的校验；`O_NOFOLLOW` 约束最后路径分量，不宣称所有父目录均无符号链接，也不把文件验证与后续默认应用打开扩展为同一事务。权限及外置卷约束见[文件访问](../../Platform/FileAccess.md)。

## 验证与实机证据

[虚拟机日常验收](../../../../Tests/Main.md)通过真实管理页导入、修改名称、更换、删除与重开应用检查持久化，随后从 Finder 创建文件比较副本内容和模板顺序。独立副本、冲突不覆盖与重启恢复以最终索引和文件字节为证据，不以内存值或保存方法返回作为通过条件。

已有真实 Finder 观察确认 TXT 子菜单创建零字节默认文件、冲突后新名称及默认创建结果自动选中；对应环境和限制见[新建文件](../NewFile.md#项目设计与验证范围)。损坏索引、提交后清理问题、向更换前旧 URL 保存以及默认编辑器行为，仅在当前运行报告包含相应 fixture 与结果时算作已验收。权限和原生名称交互的边界分别见[文件访问](../../Platform/FileAccess.md)和[名称编辑](Editing.md#原生焦点证据与验收)。
