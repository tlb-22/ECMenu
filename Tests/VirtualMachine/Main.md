# 虚拟机测试适配

本目录提供 ECMenu 对公共 macOS 测试模板的项目适配。模板、源码、签名与结果的完整执行协议见[虚拟机端到端测试](../../spec/Technical/Delivery/VirtualMachineTests.md)，产品用例见[测试入口](../Main.md)。

项目模板拥有 VS Code、iTerm、常规英文启动环境和构建缓存。准备时从公共模板全新派生，安装完整应用、设置公开选项并保存真实启动窗口证据，来宾正常关机完成后事务替换项目模板；日常验收从项目模板快速克隆，引导前检查项目 scratch 不存在。公开启动配置、封存及克隆检查见[环境与缓存](../../spec/Technical/Delivery/VirtualMachineTests.md#环境与缓存)。

## 本机配置

[Project.json](Project.json) 只记录稳定项目身份。首次接入时将 [Local.example.json](Local.example.json) 复制为同目录 `Local.json`，填写 `environmentDirectory`、`template`、`directory` 和 `applications`。它们分别指定宿主封存环境根、项目模板名、来宾用户目录内的工作区相对路径及宿主应用来源。`Local.json` 被 Git 忽略，源码快照也显式排除；未配置时明确给出接入提示，帮助入口仍可使用。

管理员凭据、SSH 密钥和签名私钥继续由宿主环境的私有文件管理。公开定义只保留系统工具与共享目录协议；账户来自公共封存配置，来宾核对当前登录桌面账户。

## 定义与边界

| 定义 | 职责 |
|---|---|
| [Project.json](Project.json)、[Local.example.json](Local.example.json) | 公开项目身份和本机执行设置的填写格式 |
| [SigningIdentity.swift](SigningIdentity.swift) | 宿主精确身份导出或内存检查；guest 单轮钥匙串导入与清理 |
| [prepare-test-signing.py](../../scripts/prepare-test-signing.py) | 一次性宿主系统授权、精确身份验证及私有来源保存 |
| [prepare-application-settings.py](prepare-application-settings.py) | 项目来宾的公开 VS Code 用户设置、iTerm 更新偏好、常规英文地区配置及读回回执 |
| [ExternalApplicationPreparation.swift](../FinderMenuCapture/Support/ExternalApplicationPreparation.swift) | 封存前以系统打开请求启动示例文件与目录，保存目标和窗口证据，清理本轮应用进程 |
| [ExternalApplicationWindows.swift](../FinderMenuCapture/Support/ExternalApplicationWindows.swift) | 模板准备与日常菜单流程共用的外部应用可见窗口、附属 sheet 及清单捕获 |
| [prepare-permissions.py](prepare-permissions.py) | 通过真实系统设置准备原生驱动权限，管理员认证按需接收标准输入 |
| [CapturePermissionPreparation.swift](../FinderMenuCapture/Support/CapturePermissionPreparation.swift) | 实际捕获系统设置窗口，核对并处理指向当前驱动的系统录屏提示 |
| [desktop_job.py](desktop_job.py) | 由 guest GUI launchd 直接启动桌面工具，拥有作业、日志与生命周期 |
| [run-desktop-job.py](run-desktop-job.py) | 透传普通标准输入输出，返回实际退出码；超时返回 124，中断清理作业 |
| [Bootstrap](Bootstrap/Main.md) | 只在权限准备阶段使用的 Appium/Mac2 固定依赖 |

桌面驱动由 GUI launchd 独立启动，使辅助功能和屏幕录制权限归属稳定的原生驱动。日常 Finder 操作、设置流程和 Preview 窗口截图使用同一个驱动身份。作业结果目录位于本轮 guest 仓库 scratch，保留 `desktop-job.json`、stdout、stderr 和 launchd 定义；结束时移除作业及输入 FIFO。

模板准备和每轮克隆在产品验收前实际捕获一次系统设置窗口。驱动只处理 Apple 签名进程中明确指向 `FinderMenuAutomation` 的录屏授权提示，未知按钮或歧义直接失败；日志记录公开按钮名称与批准或未出现的结果。这是测试工具的环境准备，产品首次权限流程仍在本阶段验收范围之外。

准备阶段使用 `./scripts/prepare-test-vm.sh`，日常验收使用 `./scripts/test.sh`。宿主入口和 guest 脚本顺序执行，公共内核锁覆盖整轮克隆、运行、导出和删除。
