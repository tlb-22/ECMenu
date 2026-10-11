# 项目模板权限准备

项目模板为 `FinderMenuAutomation.app` 原生驱动准备辅助功能与屏幕录制权限。日常验收使用原生 Swift 驱动；Appium 只用于模板准备时操作来宾的系统设置与原生文件选择器。所有入口核对虚拟机及当前登录桌面账户。

依赖由 `package-lock.json` 锁定：Node 24.21.0、Appium 3.8.0、Mac2 driver 4.3.6。缺少依赖时在来宾执行 `npm ci`，缓存与安装日志进入本次仓库内的运行目录。Mac2 使用公共模板已有授权的 Xcode Helper；项目不修改权限数据库。[Mac2 环境要求](https://appium.github.io/appium-mac2-driver/latest/getting-started/)、[Appium 的 npm 依赖发现](https://appium.io/docs/en/latest/guides/managing-exts/)说明该装配方式。

入口为 `python3 Tests/VirtualMachine/prepare-permissions.py <应用内驱动绝对路径> <本次报告目录>`。驱动路径是 `.derivedData/Build/Products/Debug/FinderMenuAutomation.app/Contents/MacOS/FinderMenuAutomation`，应用与可执行文件使用稳定标识 `com.axiomace.ecmenu.test.findermenuautomation`，正式模板使用产品相同的开发签名 Team，准备入口拒绝 ad-hoc 与缺少 Team 的签名。系统文件选择器选取所属 `.app`，权限查询直接启动其中的实际可执行文件。

Mac2 4.3.6 的构建入口没有 `derivedDataPath` 选项。准备脚本显式启动官方 WDA 的 `xcodebuild`，指定 `.derivedData/PermissionBootstrap`，再用受支持的 `webDriverAgentMacUrl` 附着。运行结束后停止 WDA，删除本次 `.xcresult` 与该 Derived Data 的 `Logs/Test`；认证活动与附件不进入报告或封存模板。[Mac2 capability 契约](https://appium.github.io/appium-mac2-driver/latest/reference/capabilities/)列出附着方式。

只有真实管理员密码控件出现时，脚本才输出一行 `ECMENU_ADMINISTRATOR_REQUIRED`，随后从标准输入读取含 `user` 与非空 `password` 的 JSON，核对账户为当前来宾桌面用户。宿主控制器收到该标识后，从本机环境的私有凭据文件读取并经 SSH 标准输入转发。Appium 与 npm 的标准输入关闭，驱动日志关闭，客户端不记录请求正文。认证窗口不生成截图或控件树；密码不属于仓库配置、命令参数或报告。

结果写入 `permissions.json`，包含系统版本、签名身份、准备前后权限和步骤结果。两项原生权限查询均为 `true` 后，原生驱动实际捕获系统设置窗口，核对额外录屏提示并保存 PNG 与 `captureConsent`；未知按钮、捕获失败或认证活动清理失败均拒绝封存。录屏准备限定为明确指向本驱动的 Apple 系统提示，产品首次权限验收不属于此入口。

桌面工具由 GUI launchd 直接启动，统一入口如下：

```sh
python3 Tests/VirtualMachine/run-desktop-job.py --timeout 300 \
  <本次唯一作业目录> -- <可执行文件绝对路径> <参数…>
```

作业目录必须位于来宾仓库内且尚不存在。入口用 FIFO 实时传递标准输入，透传标准输出与错误，并保留 `stdout.log`、`stderr.log`、`desktop-job.json`。退出码沿用工具结果；超时为 124，中断为 130，准备或清理失败为 1。结束后注销 launchd 登记并移除 FIFO。Finder 验收、菜单截图、README fixture 与 Preview 窗口截图使用同一入口和同一驱动。

项目在 macOS 26.6.2（25G83）的隔离来宾中观察到：SSH 直接启动工具时，TCC 请求归属 SSH 服务；GUI launchd 独立启动后，授权归属驱动自身。产品 Team 的实际签名驱动已通过系统设置添加和管理员认证，两项原生权限查询均为 `true`，项目模板已封存。标准输入输出、原始退出码、超时及作业清理也已验证。录屏预检通过后仍可能出现额外的实际捕获授权提示，当前项目观察的允许按钮为 `Allow`，不推断其授权期限；日常克隆在产品流程前重新核对。完整证据范围见[虚拟机测试](../../../spec/Technical/Delivery/VirtualMachineTests.md#接入证据)。
