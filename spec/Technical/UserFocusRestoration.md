# 本机开发入口的用户焦点恢复

本机手动开发和环境切换入口在结束时请求恢复启动前的应用焦点；`run-debug.sh` 与 `activate-environment.sh` 共用此边界。`preview-ui.sh` 用于留下可交互的前台窗口。默认验收在一次性虚拟机中运行，宿主只编排与收集产物，不需要通过焦点恢复保护开发桌面；流程见[测试定义](../../Tests/Main.md)。

## 稳定路径

最外层脚本在等待共享操作锁之前，通过 `NSWorkspace.frontmostApplication` 记录前台应用的 PID、启动时间、bundle identifier 和可执行文件路径。它随后以会话标记重新执行原命令；同一调用链中的子脚本看到该标记后直接运行，不再捕获或恢复焦点。

原命令退出时，先执行其自身的进程、窗口、语言和偏好恢复，再由最外层包装器请求原应用重新激活。包装器通过独立进程组运行完整子进程树；收到 HUP、INT 或 TERM 时把信号转发到该进程组，等待子脚本清理后才恢复焦点。恢复目标必须仍是同一 PID、非空且相同的启动时间及稳定身份，避免 PID 复用后激活无关进程。Finder 是唯一例外：Extension 刷新和环境切换会按设计重启 Finder，原进程消失时可以选择 bundle identifier 与可执行路径唯一匹配的新 Finder 进程。

普通应用已经退出时跳过恢复，不重新启动应用；没有前台应用的 CI 或无界面会话也正常执行原命令，只是不建立恢复目标。恢复失败会使原本成功的脚本失败；原命令已经失败时保留其退出状态，并在独立日志中报告恢复错误。

## 职责与源码映射

| 职责模块 | 核心类型或脚本与源码入口 | 输入、输出与状态所有权 |
|---|---|---|
| 手动开发恢复会话 | [user-focus.sh](../../scripts/lib/user-focus.sh) 接入，[with-user-focus-restored.sh](../../scripts/lib/with-user-focus-restored.sh) 执行包装 | 手动开发命令 → 捕获原焦点、运行子进程组、等待清理后恢复；包装器持有本轮身份快照、子进程、会话标记和原退出码，通过 `trap` / `kill` / `wait` 转发信号并等待退出 |
| 运行进程与系统激活 | `UserFocusRestorer` · [UserFocusRestorer.swift](../../Tests/UserFocusRestoration/Support/UserFocusRestorer.swift) | `capture` / `restore` / `launch` 参数 → 编码身份、恢复状态或新命令进程；`NSWorkspace` 读取运行事实，`NSRunningApplication.activate` 请求激活并在主 RunLoop 核实结果，`setsid` / `execvp` 建立子命令会话 |
| 恢复目标规则 | `UserFocusApplicationIdentity` / `UserFocusRestorationResolver` · [UserFocusRestorationModel.swift](../../Tests/UserFocusRestoration/Support/UserFocusRestorationModel.swift) | 原身份与当前候选身份 → 可恢复目标或不可用；纯值计算，无外部 I/O，由系统边界读取事实后调用 |

这些支持文件属于本机手动开发入口。目标身份、退出状态与恢复结果记录在本次日志中；虚拟机验收不把恢复宿主焦点或保持宿主 Finder 窗口集合作为产品通过条件。

## 平台契约与证据边界

Apple 将 `NSWorkspace.frontmostApplication` 定义为当前接收键盘事件的应用；`NSRunningApplication.activate(options:)` 用于请求激活运行中的应用。实现使用空选项，不请求同时展开该应用的所有窗口，并在主 RunLoop 上等待后同时核对 `isActive` 与当前前台 PID，而不把 API 的同步返回值当成已经完成切换。[NSWorkspace.frontmostApplication](https://developer.apple.com/documentation/appkit/nsworkspace/frontmostapplication) · [NSRunningApplication.activate(options:)](https://developer.apple.com/documentation/appkit/nsrunningapplication/activate(options:)) · [NSApplication.ActivationOptions](https://developer.apple.com/documentation/appkit/nsapplication/activationoptions)

Xcode 26.6 SDK 的 `NSRunningApplication.h` 将 `activateIgnoringOtherApps` 标记为 macOS 14 起已弃用且不再生效，因此它不能作为增强激活的后备路径。项目也不使用 Accessibility 或私有 Space API；焦点恢复本身不增加系统授权要求。

项目对公开 AppKit API 表面的调查结论是：它只允许激活应用，没有选择指定 Space 的接口。因此自动验证“原应用重新成为前台”，不能从代码断言当前 Space 编号。2026-09-04 在 macOS 26.6.1（25G76）、Xcode 26.6（17F113）与 Visual Studio Code 1.136.1 上实测：从全屏 VS Code 切到另一应用后，对原运行实例调用 `activate(options: [])` 会返回原 VS Code 全屏 Space；完整 README 截图链路结束后也恢复为启动前同一 PID 的 `Code`，且嵌套脚本没有提前恢复。当同一应用在多个 Space 中拥有多个窗口时，具体显示哪个窗口仍由 macOS 的窗口与 Mission Control 状态决定。[在 Mac 上的多个空间中工作](https://support.apple.com/guide/mac-help/mh14112/mac)

## 已排除的路径

- 先激活辅助进程再交还焦点：命令行辅助进程作为 accessory application 时未可靠成为前台，不能提供稳定的交接基础。
- `activateIgnoringOtherApps`：当前 SDK 已明确声明无效。
- `NSWorkspace.openApplication`：包含启动或重新打开应用的语义，会把已退出的普通应用重新拉起，不符合恢复同一运行实例的边界。
- Accessibility 或私有 Space 控制：为此目的扩大权限或依赖非公开接口不合理，也不能形成可维护的产品契约。
