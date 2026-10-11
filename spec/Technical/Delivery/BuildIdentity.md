# 构建身份

本文件是产品 Bundle ID、App Group 和签名配对的唯一文档来源。运行时对端认证见 [IPC](../Runtime/IPC.md)，Finder 登记语义见 [Extension 生命周期](../Platform/Finder/ExtensionLifecycle.md)。

## 产品配置

| 配置 | 主应用名称 | 主应用 Bundle / signing identifier | Finder Extension Bundle / signing identifier | App Group |
|---|---|---|---|---|
| Release | `ECMenu` | `com.axiomace.ecmenu` | `com.axiomace.ecmenu.finderext` | `GVPW27HJZ5.ecmenu` |
| Debug | `ECMenu(Debug)` | `com.axiomace.ecmenu.debug` | `com.axiomace.ecmenu.debug.finderext` | `GVPW27HJZ5.ecmenu.debug` |

Xcode build configuration 通过 `ECMENU_APPLICATION_NAME`、`ECMENU_APPLICATION_BUNDLE_IDENTIFIER`、`ECMENU_FINDER_EXTENSION_BUNDLE_IDENTIFIER` 和 `ECMENU_APPLICATION_GROUP_IDENTIFIER` 定义这些值。后三项还分别以 `ECMApplicationSigningIdentifier`、`ECMFinderExtensionSigningIdentifier` 和 `ECMApplicationGroupIdentifier` 注入两个产品的 `Info.plist`，App Group 同时进入双方 entitlement。

运行时代码只读取当前二进制注入的值，不通过源码条件编译或硬编码常量重新判断 Debug/Release。缺少或为空的身份配置属于构建错误，不能退化到另一套配置。

## 测试目标

非产品目标使用 `com.axiomace.ecmenu.test` 子树：

| 目标 | Bundle identifier |
|---|---|
| 主应用测试 | `com.axiomace.ecmenu.test.main` |
| Finder Extension 测试 | `com.axiomace.ecmenu.test.finderext` |
| Preview | `com.axiomace.ecmenu.test.preview` |
| IPC sender | `com.axiomace.ecmenu.test.ipcsender` |
| `FinderMenuAutomation` | `com.axiomace.ecmenu.test.findermenuautomation` |

IPC sender 是验证生产身份检查的唯一例外：产品 Bundle ID 仍属于测试子树，但本地集成构建显式把 signing identifier 覆盖为当前 Finder Extension 身份。它不嵌入或交付到产品应用。

`FinderMenuAutomation` 是在测试虚拟机内需要 Accessibility 与屏幕录制授权的开发 helper，以独立 `.app` 构建，`Contents/Info.plist` 中的 `CFBundleIdentifier` 和 code-signing identifier 都固定为表中身份。桌面调用直接运行 bundle 内的 Mach-O，并核对实际 Apple Development Team；它不嵌入或交付到产品应用。具体自动化边界见 [Finder 菜单自动截图](../FinderMenuCapture.md)。

## 签名与隔离

当前目标使用 Personal Team `GVPW27HJZ5` 的 Apple Development 签名；手动本机构建使用自动签名，虚拟机按同一 Team 在临时专用钥匙串中导入身份并使用手动签名配置。虚拟机的凭据生命周期见[端到端测试](VirtualMachineTests.md)。Release 面向本机使用和 GitHub 分发，不执行 Developer ID export、公证或 staple；首次运行仍由用户按 macOS 界面手动放行。发布脚本的构建与校验入口见[开发脚本](../../../scripts/Main.md#视觉证据与交付)。

Apple 的 [TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)将 macOS App Group、App Sandbox、Hardened Runtime 和调试权限列为无需 provisioning profile 授权的 entitlement；没有受限 entitlement 的 Mac 程序无需 profile。当前主应用和 IPC sender 声明 App Group，Extension 另声明 App Sandbox，Debug 签名注入调试权限，符合这项条件。

项目采用 `<Team ID>.<group name>` 格式。Apple 的[配置 App Groups](https://developer.apple.com/documentation/xcode/configuring-app-groups)说明系统会按签名 Team 核对这种容器身份；[macOS 15 发布说明](https://developer.apple.com/documentation/macos-release-notes/macos-15-release-notes)将 Team 前缀与 `FileManager` 容器定位列为无提示访问的条件，规则同样适用于 Extension。[ApplicationIPC](../../../ECMenuShared/Platform/IPC/ApplicationIPC.swift)通过 `containerURL(forSecurityApplicationGroupIdentifier:)` 定位容器，因此当前 Debug 配置的虚拟机签名输入只需同 Team 的开发身份，无需额外同步 profile。

以上是 Apple 公开契约与当前配置的对应结论。2026-10-11 的来宾接入检查已完成同 Team 真实签名构建、Extension 菜单加载及签名 IPC 验收；环境版本、执行范围与完整流程限制见[接入证据](VirtualMachineTests.md#接入证据)，后续源码的通过范围由相应运行报告确认。

不同 Bundle ID 隔离标准偏好、登录项和 Launch Services/PlugInKit 登记；不同 App Group 隔离组容器及其中的 IPC socket；配置变更通知名由主应用 signing identifier 派生。因此 Debug 与 Release 不共享偏好、配置副本或 IPC，也不能互相通过身份验证。

两个产品的 entitlement 声明当前配置的同一 App Group。双方的 Sandbox 与文件授权边界见[文件访问](../Platform/FileAccess.md)，组容器中的运行态对端认证见 [IPC](../Runtime/IPC.md)。
