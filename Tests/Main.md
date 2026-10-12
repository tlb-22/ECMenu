# 测试与界面证据

持续功能开发期间，在本机通过针对性的简单手动测试验证当前改动；正式发布前使用 `./scripts/test.sh` 完整验收，并检查报告与产物。自动测试与截图在一次性 macOS 虚拟机中执行：同步当前工作区，构建真实签名应用，通过 Finder、设置控件和原生对话框完成操作，导出报告、截图及实际文件后删除克隆。首次接入或公共基线变化时运行 `./scripts/prepare-test-vm.sh`。

执行证据与适用限制见[接入证据](../spec/Technical/Delivery/VirtualMachineTests.md#接入证据)，每次运行结果以实际导出的报告为准。

## 默认验收

| 流程 | 外部成功条件 | 定义 |
|---|---|---|
| 模板管理 | 文件选择导入、名称提交、鼠标释放后的排序、替换及删除；重启后恢复已提交内容 | `EndToEnd/Desktop/Acceptance/` |
| 新建文件 | 真实 Finder 子菜单点击，生成内容与导入来源字节一致，冲突不覆盖，选择指向新文件 | `EndToEnd/Desktop/Acceptance/`、`EndToEnd/Desktop/Features/NewFile/` |
| 复制路径、隐藏与显示 | 剪贴板匹配 Finder 实际选择；文件 flags 与上下文菜单随操作变化 | `EndToEnd/Desktop/Acceptance/` |
| 图片压缩 | 参数窗取消不创建目录；每次命令新建结果目录，实际 JPEG 尺寸、格式与目录/文件冲突名称正确，来源不变 | `EndToEnd/Desktop/Acceptance/` |
| 菜单配置与会话 | 开关和排序改变真实 Finder 菜单；关闭配置窗口后命令仍可执行，重开恢复配置 | `EndToEnd/Desktop/Acceptance/` |
| 外部应用 | 真实 Finder 菜单触发 VS Code 与 iTerm2，记录窗口截图；目标加载与终端工作目录由人工检查 | `EndToEnd/Desktop/Acceptance/` |
| 存储失败 | 不可写目标显示错误，坏索引显示可恢复失败，其他命令仍可执行 | `EndToEnd/Desktop/Acceptance/` |
| 双语菜单 | 五类真实 Finder 上下文产生截图与标题检查结果 | `EndToEnd/Desktop/` |
| 签名 IPC | 独立签名进程查询配置、提交命令，读取真实文件 flags 验证效果 | `EndToEnd/IPC/` |

每个桌面 case 记录步骤、断言、耗时和失败现场。截图可人工检查；当前没有图像断言，不能将截图生成解释为外观自动验收。外部应用自动检查覆盖实际菜单、应用启动和可见窗口，并保存各应用全部可见窗口的截图及独立目标清单；目标内容加载及终端工作目录单独记录为待人工检查。此类 case 与桌面报告使用 `review-pending`，检查说明和证据位于 `manualReview`，宿主报告继续保留该状态。配置窗口预览采用内存数据，用于视觉证据，不能代替产品流程。

## 导航与入口

- [虚拟机执行协议](../spec/Technical/Delivery/VirtualMachineTests.md)：模板、工具、签名、输入同步、清理与覆盖范围。
- [端到端定义](EndToEnd/Main.md)：桌面用户流程与独立签名 IPC。
- [测试运行设施](Infrastructure/Main.md)：虚拟机适配与 README 图片合成。
- [项目虚拟机适配](Infrastructure/VirtualMachine/Main.md)：公开定义、被 Git 忽略的本机配置、签名与桌面作业。
- [关键单测](Unit/Main.md)与[例外清单](Unit/Exceptions.md)：保留的 8 个既有用例及实际失败模式。
- [Finder 菜单捕获](../spec/Technical/FinderMenuCapture.md)：真实输入、菜单身份、窗口捕获和语言检查。
- [独立预览](../spec/Technical/PreviewTarget.md)：固定视觉场景与生产呈现边界。

`./scripts/test-checks.sh` 执行构建、捕获定义检查和少量故障注入例外。开发机调用时默认进入虚拟机，应用承载的 XCTest 窗口留在来宾；普通 CI 在自己的 runner 中执行。Preview 注册表列举不创建应用窗口。它的通过仅表达这些检查，不表达真实桌面验收通过。

需要单独复核图片压缩流程时，可用 `python3 scripts/test-vm.py desktop --case image-compression` 执行对应真实用户流程。省略 `--case` 时执行全部桌面 case；指定流程仍构建当前源码并导出报告、截图和实际文件，宿主及 guest 报告记录本轮筛选范围。

本阶段验收使用已准备权限的开发环境。干净安装、产品首次权限、真实注销登录、最低支持系统和 Release 交付物的完整验收尚未纳入默认流程。
