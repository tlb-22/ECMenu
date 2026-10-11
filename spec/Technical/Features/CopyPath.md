# 拷贝路径

能力范围是把 Finder 冻结的有序绝对路径写入系统剪贴板。产品行为见[需求](../../Requirements/Features/CopyPath.md)，上下文形成与投递分别见 [Finder 菜单语义](../Platform/Finder/ContextMenus.md)和 [IPC](../Runtime/IPC.md)。

## 执行流

```mermaid
sequenceDiagram
    box Finder Extension 进程
        participant E as 菜单命令构造
    end
    box ECMenu 主应用进程
        participant H as 复制用例
        participant P as 文件与剪贴板适配
        participant R as 复制规则与结果
        participant F as 结果反馈
    end
    participant S as 文件系统 / 系统剪贴板
    E->>H: 经 IPC 与 Router：CopyPathCommand
    H->>P: 非空有序绝对路径
    P->>S: lstat：读取路径对象存在性
    S-->>P: 每个对象是否存在
    P-->>H: existingURLs
    H->>R: 命令 + 存在事实
    alt 任一对象失效
        R-->>H: targetUnavailable
    else 所有对象存在
        R-->>H: 多行文本计划
        H->>H: 切回 MainActor，检查 Task 取消
        alt 已取消
            Note over H: 返回 cancelled；不写剪贴板
        else 继续执行
            H->>P: writeString：同步 MainActor 调用
            P->>S: clearContents，然后 setString
            S-->>P: Bool 写入结果
            P-->>H: 成功或写失败
        end
    end
    H-->>F: Router 仅在 Task 未取消时交付完整 Outcome
    F->>F: 成功日志；失败日志与提示音
```

`CopyPathPlatform` 是主应用内注入的 SDK 适配边界，图中的剪贴板是系统共享状态。任务取消检查和同步剪贴板写入位于同一次 MainActor 调用；排队等待主执行器期间取消的任务不会写入。写入成功是本能力的业务完成点，反馈阶段不再写剪贴板。

## 模块、输入输出与状态

| 职责模块 | 核心类型 | 源码入口 | 输入 → 输出 | 状态与系统调用 |
|---|---|---|---|---|
| 菜单命令构造 | `CopyPathFeature` | [CopyPathFeature.swift](../../../ECMenuFinderExtension/Commands/CopyPath/CopyPathFeature.swift) | 菜单语义快照 → CopyPathCommand? | 纯值转换；发送复用 IPC，目标来源 API 见 Finder 公共说明 |
| 复制用例 | `CopyPathHandler` | [CopyPathHandler.swift](../../../ECMenu/Commands/CopyPath/CopyPathHandler.swift) | 类型化命令、平台能力 → success / failure / cancelled | 单次执行拥有计划；Swift Task 取消与 MainActor 切换 |
| 复制规则与结果 | `CopyPathRules`、`CopyPathPlan`、`CopyPathOutcome` | [CopyPathRules.swift](../../../ECMenu/Commands/CopyPath/CopyPathRules.swift) | 有序路径 + 存在集合 → 完整计划 / targetUnavailable | 无外部 I/O；全部目标有效才生成正文，保持顺序 |
| 文件与剪贴板适配 | `CopyPathPlatform` | [接口声明](../../../ECMenu/Commands/CopyPath/CopyPathHandler.swift)、[系统实现](../../../ECMenu/Commands/CopyPath/CopyPathSystem.swift) | 路径 → 存在集合；String → Bool | `lstat` 与 NSPasteboard；通过 CopyPathPlatform 注入 |
| 结果反馈 | `CopyPathFeedback` | [CopyPathFeedback.swift](../../../ECMenu/Commands/CopyPath/CopyPathFeedback.swift) | 已完成结果 + 本地 UUID → 日志或提示音 | `Logger`、`NSSound.beep()`；不保存业务状态 |

本能力没有持久化设置或跨请求缓存。命令与执行期存在事实属于本次任务；系统剪贴板由 macOS 拥有，其他应用可以随时改写。

## API 契约与设计依据

| API | 实际输入 → 输出 | 副作用、失败与消费方式 |
|---|---|---|
| Darwin `lstat` | 绝对 POSIX 路径、stat 指针 → 0 / 非 0 | 读取链接目录项自身；非 0 在本能力折叠为目标不可用，不继续写入部分路径 |
| `NSPasteboard.general.clearContents()` | 系统通用剪贴板 → changeCount | 清除旧内容；返回计数不作为写成功证明 |
| [`setString(_:forType:)`](https://developer.apple.com/documentation/appkit/nspasteboard/setstring%28_%3Afortype%3A%29) | 多行 POSIX String、`.string` → Bool | 写首个 pasteboard item 的一种文本表示；false 进入 pasteboardWriteFailed |
| `Logger` / `NSSound.beep()` | 结果、UUID → 日志 / 系统提示音 | 失败反馈不恢复旧剪贴板；取消静默 |

存在检查与写剪贴板不是原子操作，只表达检查时点的事实。使用 `lstat` 保留断链自身的可复制路径。所有路径是一份字符串，多选换行是正文内容，不拆成多个剪贴板条目。

macOS 26.5 SDK 的 `NSPasteboard.h` 明确 `clearContents` 清除内容并返回 change count，`setString` 对首项写指定类型。两步不是事务：写入失败时旧内容已经清除。MainActor 是本项目的剪贴板隔离选择。

## 验证与证据范围

[虚拟机日常验收](../../../Tests/Main.md)从真实 Finder 菜单复制单项、多项和目录路径，并读取来宾系统剪贴板核对正文。仅保留 [CopyPathTests](../../../Tests/Unit/ECMenuTests/Commands/CopyPath/CopyPathTests.swift) 的系统写入失败与事实读取后等待主执行器期间取消两个例外，具体失败模式和必要性见[单元测试例外](../../../Tests/Unit/Exceptions.md)。SDK 核对版本为 macOS 26.5。

多选验收先核对完整路径集合、数量和换行，再在同一来源窗口与选择上执行 Finder 自身的“拷贝为路径名”，用标准 shell 引用解码比较顺序。macOS 26.6.2 的来宾观察中，AX 选择数组与这两个实际剪贴板输出的顺序不同，ECMenu 输出与 Finder 原生输出顺序一致；AX 顺序不能作为 FinderSync 顺序的独立预期。API 契约和证据边界见[菜单稳定协议](../FinderMenuCapture.md#稳定协议)。

实机验收可在 Finder 选择含空格及 Unicode 名称的多个对象，拷贝后粘贴到纯文本编辑器核对顺序与换行；该路径的操作记录应注明 macOS 版本。当前自动化覆盖与完整测试入口见[命令执行](../Runtime/CommandExecution.md#验证入口)。
