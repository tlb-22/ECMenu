# Finder 菜单语义

产品菜单行为见[右键菜单需求](../../../Requirements/FinderMenu.md)，各功能的上下文条件见[功能需求](../../../Requirements/Features/Main.md)。通用证据范围见[平台边界](../Main.md)。

## 菜单种类与目标字段

### SDK 契约

`FIMenuKind` 描述 Finder 请求的菜单种类，而不是由选择数量推断。Xcode 26.6 附带的 macOS 26.5 SDK 在 `FinderSync.h:123–136` 定义了以下类型：

| 类型 | Apple 定义的触发位置 |
|---|---|
| `contextualMenuForItems` | Finder 窗口中的一个项目或一组选中项目 |
| `contextualMenuForContainer` | Finder 窗口背景 |
| `contextualMenuForSidebar` | Finder 侧边栏项目 |
| `toolbarItemMenu` | Extension 工具栏按钮 |

`targetedURL()` 返回用户 Control-click 的 target，`selectedItemURLs()` 返回当前 Finder 窗口的选择数组（`FinderSync.h:73–101`）。两者只保证在 `menuForMenuKind:` 或该菜单创建的 action 中有效；对应对象位于 Extension 管理范围之外时可以为 `nil`。工具栏菜单即使与管理范围无关也可能被请求（`FinderSync.h:144–165`），本产品不为该类型提供菜单。

Apple 没有声明 `selectedItemURLs()` 的顺序等于 Finder 的可见排序。本项目保留 API 返回顺序，但不把它作为平台保证。

### 项目语义映射

项目观察到，container 回调中的 `selectedItemURLs().first` 可能表示当前可见目录，而 `targetedURL()` 仍停留在残余选中项；多层 Finder 替身也会影响背景回调字段。项目把原始字段一次性映射为以下领域快照：

| 菜单类型 | 领域快照 |
|---|---|
| container | `selectedItemURLs().first`，为空时使用 `targetedURL()` |
| items | 非空的完整 `selectedItemURLs()` |
| sidebar | `targetedURL()` |
| toolbar | 不形成快照 |

这是当前人工验收支持的产品语义，不是 Apple 对字段组合的承诺。系统升级后需要重新检查无选择、残余选择和多层替身三类背景菜单。

## 不可变快照与操作绑定

Finder 允许 action 再次读取目标字段，但本项目在 `menu(for:)` 开始时只读取一次并形成 `.container`、`.items` 或 `.sidebar`。菜单可见性和最终 action 因而解释同一次用户交互，不受点击前 Finder 选择或窗口状态变化影响。

每个实际渲染的叶子都在该快照上准备类型化命令，并以菜单项实例的唯一 tag 绑定一次调用。新的菜单请求不能覆盖仍在显示的旧菜单调用，也不能让旧 action 改用“最新 Finder 状态”的全局缓存。

快照只表达 Finder UI 事件。对象是否存在、是否为目录、package、符号链接以及权限由具体功能在自身边界读取。替身解析只能回答路径最终访问的对象，不能反推出用户在哪个 Finder 窗口背景打开菜单。

同一次菜单求值中，文件创建与进入外部应用共享单目标的存在性和跟随符号链接后的目录事实；隐藏与显示共享选中项的隐藏状态事实。事实只保留到本次菜单构建结束，下次请求重新读取。该共享减少同步文件系统读取，也使同一菜单中的相关命令解释同一份系统观察；执行端仍在操作边界处理目标失效等变化。

Finder 要求菜单 action 由 Extension principal object 提供（`FinderSync.h:144–165`），并可能为 Open/Save 面板创建额外 Extension 实例（`FinderSync.h:167–179`）；进程内状态不能假定只有一个全局实例。

## 菜单树与启用状态

`NSMenu` 默认通过自动菜单验证和 responder chain 计算启用状态，而不是遵守手工设置的 `NSMenuItem.isEnabled`（macOS 26.5 SDK `NSMenu.h:137–145`）。项目先根据用户配置、冻结快照和本次读取的系统事实删除无法形成命令的叶子，再关闭每层菜单的自动启用，防止 AppKit 改写已经完成的产品判定。

[命令执行边界](../../Runtime/CommandExecution.md)定义 Feature、Action 与 Handler 的身份关系。Finder 只消费每个已启用 Feature 提供的递归菜单值树；树可以包含叶子、子菜单和分隔线，规范化会删除空子菜单以及每层开头、结尾和连续的分隔线。

文件权限和只读卷等不稳定条件不在菜单阶段预检，执行时仍可能失败。[虚拟机日常验收](../../../../Tests/Main.md)从真实 Finder 上下文读取菜单结构、执行可用动作并核对最终副作用；菜单截图同时保留可检查的界面证据。

平台升级后需要重新验证字段映射、连续构建多个菜单时的旧 action 快照，以及每层菜单树的叶子、空子菜单和分隔线规范化。
