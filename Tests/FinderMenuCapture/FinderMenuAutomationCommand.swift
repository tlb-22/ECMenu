/**
 定义 Finder 自动化工具支持的命令行操作，将参数交给通用捕获或具体能力验证。
 本文件是工具的操作装配入口，保留单一用法说明，不持有 Finder 会话或系统权限状态。
 */

import Foundation

enum CLICommand {
    case preflight
    case permissions
    case prepareCapture(URL)
    case prepareExternalApplications(URL)
    case finderWindows
    case windowImage(WindowImageInput)
    case capture(FinderMenuCaptureInput, CaptureContent)
    case createFile(NewFileMenuAcceptance)
    case desktopSuite(DesktopAcceptanceSuite.Input)
    case prepareReadmeTemplates(DesktopAcceptanceSuite.Input)

    enum CaptureContent {
        case menu
        case submenu(parentTitle: String)
    }

    static let usage = "Usage: FinderMenuAutomation preflight | permissions | prepare-capture <output.png> | prepare-external-applications <output-directory> | finder-windows | window-image <window-id> <output.png> | container <output.png> <directory> | items <output.png> <item> [item ...] | submenu <output.png> <directory> <parent-title> | create-file <submenu.png> <directory> <parent-title> <template-title> <expected-file-name> <expected-content-file> | desktop-suite <debug.app> <output-directory> | prepare-readme-templates <debug.app> <output-directory>"

    static func parse(_ arguments: [String]) throws -> CLICommand {
        guard let command = arguments.first else { throw AutomationFailure.usage }
        switch command {
        case "preflight":
            guard arguments.count == 1 else { throw AutomationFailure.usage }
            return .preflight
        case "permissions":
            guard arguments.count == 1 else { throw AutomationFailure.usage }
            return .permissions
        case "prepare-capture":
            guard arguments.count == 2 else { throw AutomationFailure.usage }
            return .prepareCapture(try WindowImageInput.outputURL(path: arguments[1]))
        case "prepare-external-applications":
            guard arguments.count == 2, arguments[1].hasPrefix("/") else { throw AutomationFailure.usage }
            return .prepareExternalApplications(URL(fileURLWithPath: arguments[1]).standardizedFileURL)
        case "finder-windows":
            guard arguments.count == 1 else { throw AutomationFailure.usage }
            return .finderWindows
        case "window-image":
            return .windowImage(try WindowImageInput.parse(arguments))
        case "container":
            guard arguments.count == 3 else { throw AutomationFailure.usage }
            return .capture(try .container(outputPath: arguments[1], directoryPath: arguments[2]), .menu)
        case "items":
            guard arguments.count >= 3 else { throw AutomationFailure.usage }
            return .capture(try .items(outputPath: arguments[1], firstPath: arguments[2], remainingPaths: Array(arguments.dropFirst(3))), .menu)
        case "submenu":
            guard arguments.count == 4, !arguments[3].isEmpty else { throw AutomationFailure.usage }
            return .capture(
                try .container(outputPath: arguments[1], directoryPath: arguments[2]),
                .submenu(parentTitle: arguments[3])
            )
        case "create-file":
            return .createFile(try NewFileMenuAcceptance.parse(arguments))
        case "desktop-suite":
            return .desktopSuite(try DesktopAcceptanceSuite.Input.parse(arguments))
        case "prepare-readme-templates":
            return .prepareReadmeTemplates(try DesktopAcceptanceSuite.Input.parse(arguments))
        default:
            throw AutomationFailure.usage
        }
    }
}
