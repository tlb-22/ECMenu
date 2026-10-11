# 技术文档

本目录为每个业务能力维护高层执行流、模块与源码映射、状态所有权、外部 API 输入/输出、验证证据与设计依据。平台和跨能力机制保留独立专题，公共结论只有一个维护位置。产品行为和验收边界以 [Requirements](../Requirements/Main.md) 为准；局部算法和完整类型定义由源码与测试表达。编写方式见 [Technical spec 编写约束](Architecture/TechnicalSpecGuidelines.md)。

涉及平台行为时，文档明确区分 Apple SDK 契约、项目观察、推断和项目设计。

## 项目结构

顶层目录按运行目标和所有权划分；下列结构只记录稳定职责，不枚举具体源码文件：

```text
ECMenu/                         主应用
├── App/                        进程与配置会话生命周期
├── Settings/                   设置窗口、导航和页面装配
├── GeneralSettings/            通用设置、登录项与系统设置入口
├── CommandMenuSettings/        命令菜单偏好、快照与更新发布
├── NewFileTemplates/           模板库、文件副本与管理状态
├── IPC/                        应用侧进程边界
├── Commands/                   按能力组织的命令执行
├── CommandRuntime/             命令任务与进度事实
├── Feedback/                   通用警告和进度窗口
└── FileSystem/                 跨能力共用的命名与错误模型
ECMenuFinderExtension/          Finder Extension
├── App/                        Extension 生命周期
├── CommandMenuSettings/        配置只读副本
├── IPC/                        请求发送
├── Menu/                       Finder 上下文、菜单构建与渲染
└── Commands/                   各能力菜单规则
ECMenuShared/
├── Contracts/                  两个产品目标共用的值与请求
└── Platform/                   实际复用的系统实现
Tests/                          真实桌面验收、故障注入例外与界面预览
design/AppIcon/                 应用图标设计源与生成产物
scripts/                        构建、运行、测试与交付入口
spec/                           当前需求与技术知识
```

右键功能分别在 `ECMenuShared/Contracts/Commands/<能力>/`、`ECMenuFinderExtension/Commands/<能力>/` 和 `ECMenu/Commands/<能力>/` 保存共享契约、Finder 菜单规则与主应用用例。三端使用相同能力名。[ContextMenuComposition](../../ECMenuFinderExtension/Menu/ContextMenuComposition.swift) 和 [ContextCommandComposition](../../ECMenu/App/ContextCommandComposition.swift) 分别注册调用端与执行端能力；主应用描述和 Handler 工厂来自同一份声明。

能力内部按需区分 Domain、Application、Persistence、Platform、Presentation。具体归属、文件拆分和 View 查找方式见[目录组织规则](Architecture/DirectoryRules.md)。

## 导航

- [系统架构](Architecture/Main.md)：进程边界、依赖关系、状态所有权与结构规范。
- [核心界面入口](ViewCatalog.md)：三个设置页面、设置弹窗及其他独立窗口的源码路径。
- [运行时](Runtime/Main.md)：进程职责、应用生命周期、IPC、命令执行、进度与配置同步。
- [平台边界](Platform/Main.md)：macOS 与 Finder API 契约、项目实测和文件访问约束。
- [交付边界](Delivery/Main.md)：构建身份、环境隔离和应用图标交付。
- [功能技术决策](Features/Main.md)：各业务能力依赖的平台 API 与不可由单个源码位置恢复的约束。
- [界面预览目标](PreviewTarget.md)：独立 Preview target 与生产代码的边界。
- [Finder 菜单自动截图](FinderMenuCapture.md)：真实 Finder 菜单的自动驱动、独立窗口捕获、稳定边界与失败经验。
- [手动开发入口的用户焦点恢复](UserFocusRestoration.md)：构建启动与环境切换后的前台应用恢复。
- [虚拟机端到端测试](Delivery/VirtualMachineTests.md)：项目模板、签名凭据、真实流程与结果边界。
