# 开发脚本

开发构建使用当前宿主桌面；自动端到端验收与截图使用一次性 macOS 虚拟机。脚本从自身位置定位仓库，构建缓存只位于 `.derivedData/`，可重建证据按用途位于 `.artifacts/scratch/{logs,tests,probes,previews}/YYYYMMDD-HHMMSS-<purpose>-<pid>`。

## 日常入口

| 入口 | 用途与成功边界 |
|---|---|
| `./scripts/run-debug.sh` | 签名构建、运行当前 Debug 产物并核对主应用及 Extension 路径 |
| `./scripts/run-debug.sh --refresh-finder` | 刷新当前 Debug Extension 登记与 Finder 进程 |
| `./scripts/run-debug.sh --refresh-icon` | 刷新系统图标缓存与当前 Debug 登记 |
| `./scripts/activate-environment.sh debug\|release` | 准备目标环境后切换 Finder Extension，失败恢复原启用状态 |
| `python3 scripts/prepare-test-signing.py` | 一次性通过宿主钥匙串系统授权初始化签名来源，验证后保存到用户私有配置 |
| `./scripts/prepare-test-vm.sh` | 从公共基线全新准备项目模板，安装应用与公开配置、准备权限和缓存，成功后事务替换 |
| `./scripts/test.sh` | 在 guest 构建当前代码，执行真实桌面流程、双语菜单、签名 IPC 与 8 个故障注入例外，单独记录人工检查项 |
| `python3 scripts/test-vm.py desktop [--case image-compression]` | 在一次性 guest 执行桌面流程；可只检查图片压缩，导出实际范围的报告与证据 |
| `./scripts/test-integration.sh` | 在一次性 guest 运行独立签名 IPC 流程与实际文件结果检查 |
| `./scripts/test-checks.sh` | 开发机默认进入 VM，普通 CI 在 runner 中执行构建、注册表、捕获定义与故障注入检查 |

`run-debug.sh --build-only` 只构建并核对产品，`--no-build` 使用已构建产品，两者互斥。手动开发入口按当前产物的精确路径管理进程；Debug 与 Release 数据隔离，两个 Finder Extension 不得同时启用。手动启动与环境切换结束后恢复原前台应用，虚拟机流程无需宿主焦点或 Finder 窗口保护。

## 视觉证据与交付

| 入口 | 用途 |
|---|---|
| `./scripts/preview-ui.sh <preview-id> [--language en\|zh-Hans]` | 在当前桌面留下可交互的独立预览；`--list` 列出场景 |
| `./scripts/capture-previews.sh [<preview-id> ...]` | 在 guest 批量捕获双语固定预览，导出 PNG 和就绪记录 |
| `./scripts/capture-finder-menus.sh` | 在 guest 捕获真实双语 Finder 菜单，导出标题检查和截图；`--check` 仅本地静态检查 |
| `./scripts/capture-readme-images.sh` | 在 guest 合成中英文 README 图，成功后同步图片及引用到当前工作区 |
| `python3 scripts/check-readme-images.py` | 检查版本化图片、README 引用和正式版本一致 |
| `./scripts/generate-app-icon.sh --check` | 检查图标生成资源一致 |
| `./scripts/build-release.sh` | 创建 Archive、版本 ZIP 和 SHA256SUMS，拒绝覆盖非空版本目录 |

截图可人工检查，当前没有图像断言。外部应用流程保存真实 ECMenu 菜单操作、应用版本、独立目标清单与全部可见窗口截图；目标内容和终端工作目录由人工检查。自动阶段完成且存在人工项时，桌面及虚拟机报告为 `review-pending`，流程退出 0；执行、导出或清理失败仍非零退出。独立 Preview 的内存状态用于视觉证据，产品功能通过实际应用与 Finder 流程验收。正式产物位于 `.artifacts/releases/<version>+<build>/`；当前发布采用 Apple Development 签名，不执行公证和网络发布。

README 捕获在 guest 中通过真实模板管理页准备 TXT、Markdown，默认文件名为 `untitled.txt`、`untitled.md`，再拍摄真实 Finder 子菜单；重复 `--expect-template <title>` 参数提供独立的实际模板行顺序期望。fixture 输入、已提交索引、设置页截图和子菜单行回执随本轮证据导出。

显式新建文件验收使用 `FinderMenuAutomation create-file <submenu.png> <directory> <parent-title> <template-title> <expected-file-name> <expected-content-file>`，只有实际文件字节与独立预期一致、且 Finder 选中新文件才通过。批量产品流程由 `desktop-suite <debug.app> <output-directory> [--case image-compression]` 执行；README 的两模板准备由 `prepare-readme-templates <debug.app> <output-directory>` 执行。桌面命令限定在 guest，权限与启动责任进程遵循虚拟机协议。

桌面工具经 `python3 Tests/Infrastructure/VirtualMachine/run-desktop-job.py [--timeout <seconds>] <new-result-directory> -- <absolute-executable> [arguments...]` 作为 GUI launchd 的直接子进程启动，保存输出与退出码。Preview 的 `window-image <window-id> <output.png>` 复用同一已授权的原生工具进行窗口截图；日常 `permissions` 只查询，项目模板通过系统设置添加并授权实际应用，再由新进程核对授权结果。

模板准备与图形验收克隆使用 `prepare-capture <output.png>` 实际捕获系统设置窗口，检查驱动的额外系统录屏提示。原生准备只批准 Apple 签名进程中明确指向当前驱动的已识别提示，保留 PNG 和公开授权结果；完成后关闭系统设置，产品验收随后开始。

## 导航

- [测试定义与覆盖](../Tests/Main.md)：真实流程、外部结果与单测例外。
- [虚拟机执行协议](../spec/Technical/Delivery/VirtualMachineTests.md)：模板、缓存、管理员与签名凭据、结果导出和失败清理。
- [开发、验证与交付流程](../spec/Technical/Delivery/DevelopmentWorkflow.md)：模块与工具 API 边界。
- [构建身份](../spec/Technical/Delivery/BuildIdentity.md)：产品及测试的 Team、Bundle ID、App Group 与签名。
- [独立预览](../spec/Technical/PreviewTarget.md)与[菜单捕获](../spec/Technical/FinderMenuCapture.md)：可重复视觉定义及平台条件。

项目模板必须关机，准备始终从公共基线建立新候选，来宾正常关机完成后事务替换；日常验收克隆项目模板使用已封存的应用、权限和构建缓存，引导前检查项目 scratch 不存在。公开启动设置、应用版本与封存边界在[虚拟机协议](../spec/Technical/Delivery/VirtualMachineTests.md#环境与缓存)维护，预热及普通启动截图不代替产品流程验收。普通源码变化直接同步并增量构建；工具、目标应用或公共封存变化时重新准备，构建耗时明显增加时可主动刷新缓存。共享 `.derivedData/` 或 Finder 登记状态的手动脚本顺序执行，虚拟机调度使用所有项目共用的内核锁。

本机环境目录、模板名称、来宾工作区和宿主应用来源由被 Git 忽略的 `Tests/Infrastructure/VirtualMachine/Local.json` 提供，填写格式见[本机配置](../Tests/Infrastructure/VirtualMachine/Main.md#本机配置)。持续开发期间在本机进行针对性的简单手动测试；正式发布前在虚拟机中完整验收并检查报告与产物。
