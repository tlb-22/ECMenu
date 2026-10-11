/**
 提供 README 截图使用的通用设置、右键菜单设置和文件模板场景。
 组合固定正常状态与当前已安装外部应用的真实图标，呈现生产设置页。
 */

import AppKit

/// README 使用的设置页正常运行状态。
@MainActor
private enum READMEStatusPagePreviewState {
    /// 从当前系统严格读取全部外部应用图标，并保持所有产品开关开启。
    static func make() -> StatusPagePreviewState {
        var applicationIcons: [String: NSImage] = [:]

        for descriptor in ContextCommandComposition.descriptors {
            guard let application = descriptor.requiredApplication else {
                continue
            }
            guard let applicationURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: application.bundleIdentifier
            ) else {
                preconditionFailure(
                    "README preview requires \(application.displayName) "
                        + "to be installed"
                )
            }

            applicationIcons[application.bundleIdentifier] =
                NSWorkspace.shared.icon(forFile: applicationURL.path)
        }

        return StatusPagePreviewState(
            isExtensionEnabled: true,
            loginItemState: .enabled,
            configuration: CommandMenuSettings(
                isEnabled: true,
                hiddenFeatureIDs: []
            ),
            applicationIcons: applicationIcons,
            fileTemplateState: .ready([
                try! FileTemplate(displayName: "TXT", defaultFileName: "untitled.txt"),
                try! FileTemplate(displayName: "Markdown", defaultFileName: "untitled.md"),
            ])
        )
    }
}

/// 以正常运行状态呈现 README 中的通用设置页。
@MainActor
enum READMEStatusPageGeneralPreview: ApplicationPreview {
    /// README 图片脚本使用的稳定预览标识。
    static let id = "readme-status-page-general"

    /// 只读取应用安装位置与真实图标，不访问产品偏好或系统设置。
    static func present() -> AnyObject {
        StatusPagePreviewSession(
            selectedPane: .general,
            state: READMEStatusPagePreviewState.make()
        )
    }
}

/// 以正常运行状态呈现 README 中的右键菜单设置页。
@MainActor
enum READMEStatusPageContextMenuPreview: ApplicationPreview {
    /// README 图片脚本使用的稳定预览标识。
    static let id = "readme-status-page-context-menu"

    /// 只读取应用安装位置与真实图标，不访问产品偏好或系统设置。
    static func present() -> AnyObject {
        StatusPagePreviewSession(
            selectedPane: .contextMenu,
            state: READMEStatusPagePreviewState.make()
        )
    }
}

/// 以正常运行状态呈现 README 中的文件模板设置页。
@MainActor
enum READMEStatusPageNewFileTemplatesPreview: ApplicationPreview {
    static let id = "readme-status-page-file-templates"

    /// 模板列表来自预览内存样例，系统状态沿用 README 的正常设置场景。
    static func present() -> AnyObject {
        StatusPagePreviewSession(
            selectedPane: .newFileTemplates,
            state: READMEStatusPagePreviewState.make()
        )
    }
}
