/**
 定义通用 Finder 菜单自动化的选择上下文、菜单快照、有限失败与等待时限。
 值模型表达各模块共享的事实，权限查询、输入解析和命令验收由各自入口负责。
 */

@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation

enum FinderMenuContext {
    case container(directory: URL, openingItem: URL)
    case items(ItemSelection)

    var directory: URL {
        switch self {
        case let .container(directory, _): directory
        case let .items(selection): selection.directory
        }
    }

    var representedURLs: [URL] {
        switch self {
        case let .container(_, openingItem): [openingItem]
        case let .items(selection): selection.urls
        }
    }

    var selectedURLs: [URL] {
        switch self {
        case .container: []
        case let .items(selection): selection.urls
        }
    }
}

struct ItemSelection {
    let first: URL
    let remaining: [URL]

    var urls: [URL] { [first] + remaining }
    var directory: URL { first.deletingLastPathComponent().standardizedFileURL }

    init(first: URL, remaining: [URL]) throws {
        let directory = first.deletingLastPathComponent().standardizedFileURL
        guard remaining.allSatisfy({
            $0.deletingLastPathComponent().standardizedFileURL == directory
        }) else {
            throw AutomationFailure.itemsMustShareDirectory
        }
        self.first = first
        self.remaining = remaining
    }
}

struct MenuRect: Equatable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    init(_ frame: CGRect) {
        x = frame.minX
        y = frame.minY
        width = frame.width
        height = frame.height
    }
}

struct MenuSnapshot: Equatable {
    let processIdentifier: pid_t
    let rect: MenuRect
    /// 包含空标题分隔项，作为截图前后稳定性指纹。
    let titles: [String]
}

enum AXOperation: String {
    case readAttribute
    case writeAttribute
    case readActions
    case performAction
    case hitTest
    case createObserver
    case registerNotification
}

enum AutomationFailure: Error {
    case usage
    case pathMustBeAbsolute(String)
    case directoryDoesNotExist(String)
    case containerIsEmpty(String)
    case itemDoesNotExist(String)
    case itemsMustShareDirectory
    case outputMustBePNG(String)
    case outputDirectoryDoesNotExist(String)
    case outputAlreadyExists(String)
    case permissions(PermissionReport)
    case finderOpenFailed(String)
    case finderUnavailable
    case interactiveSessionUnavailable
    case finderActivationTimeout(frontmostBundleIdentifier: String?)
    case newFinderWindowUnavailable
    case finderWindowOwnershipAmbiguous
    case finderWindowTimeout
    case finderSelectionTimeout
    case keyboardEventUnavailable
    case pointerEventUnavailable
    case showMenuUnavailable
    case menuOpenTimeout(frontmostBundleIdentifier: String?)
    case menuStabilityTimeout
    case menuCancelUnavailable
    case menuCloseTimeout
    case sheetCancelUnavailable
    case sheetCloseTimeout
    case windowCloseTimeout
    case focusLost(String)
    case menuChanged
    case menuItemUnavailable(String)
    case menuItemUnexpected(String)
    case screenshotFailed(String)
    case accessibility(AXOperation, AXError)
    case invalidAccessibilityValue(String)
    case unexpected(String)

    var code: String {
        switch self {
        case .usage: "usage"
        case .pathMustBeAbsolute: "path-not-absolute"
        case .directoryDoesNotExist: "directory-not-found"
        case .containerIsEmpty: "container-empty"
        case .itemDoesNotExist: "item-not-found"
        case .itemsMustShareDirectory: "items-not-in-one-directory"
        case .outputMustBePNG: "output-not-png"
        case .outputDirectoryDoesNotExist: "output-directory-not-found"
        case .outputAlreadyExists: "output-exists"
        case .permissions: "permission-denied"
        case .finderOpenFailed: "finder-open-failed"
        case .finderUnavailable: "finder-unavailable"
        case .interactiveSessionUnavailable: "interactive-session-unavailable"
        case .finderActivationTimeout: "finder-activation-timeout"
        case .newFinderWindowUnavailable: "new-finder-window-unavailable"
        case .finderWindowOwnershipAmbiguous: "finder-window-ownership-ambiguous"
        case .finderWindowTimeout: "finder-window-timeout"
        case .finderSelectionTimeout: "finder-selection-timeout"
        case .keyboardEventUnavailable: "keyboard-event-unavailable"
        case .pointerEventUnavailable: "pointer-event-unavailable"
        case .showMenuUnavailable: "show-menu-unavailable"
        case .menuOpenTimeout: "menu-open-timeout"
        case .menuStabilityTimeout: "menu-stability-timeout"
        case .menuCancelUnavailable: "menu-cancel-unavailable"
        case .menuCloseTimeout: "menu-close-timeout"
        case .sheetCancelUnavailable: "sheet-cancel-unavailable"
        case .sheetCloseTimeout: "sheet-close-timeout"
        case .windowCloseTimeout: "window-close-timeout"
        case .focusLost: "focus-lost"
        case .menuChanged: "menu-changed"
        case .menuItemUnavailable: "menu-item-unavailable"
        case .menuItemUnexpected: "unexpected-menu-item"
        case .screenshotFailed: "screenshot-failed"
        case .accessibility: "accessibility-error"
        case .invalidAccessibilityValue: "invalid-accessibility-value"
        case .unexpected: "unexpected-error"
        }
    }

    var message: String {
        switch self {
        case .usage:
            "Invalid command arguments."
        case let .pathMustBeAbsolute(path): "Path must be absolute: \(path)"
        case let .directoryDoesNotExist(path): "Directory does not exist: \(path)"
        case let .containerIsEmpty(path):
            "Container capture requires one opening item: \(path)"
        case let .itemDoesNotExist(path): "Item does not exist: \(path)"
        case .itemsMustShareDirectory: "Selected items must share one parent directory."
        case let .outputMustBePNG(path): "Screenshot output must be a PNG path: \(path)"
        case let .outputDirectoryDoesNotExist(path):
            "Screenshot output directory does not exist: \(path)"
        case let .outputAlreadyExists(path): "Screenshot output already exists: \(path)"
        case let .permissions(report):
            "Permissions unavailable (accessibility=\(report.accessibility), screenCapture=\(report.screenCapture))."
        case let .finderOpenFailed(path): "Finder did not open: \(path)"
        case .finderUnavailable: "Finder did not become available."
        case .interactiveSessionUnavailable:
            "Unlock the macOS desktop before capturing Finder menus."
        case let .finderActivationTimeout(bundleIdentifier):
            "Finder did not become frontmost; frontmost application: \(bundleIdentifier ?? "unavailable")."
        case .newFinderWindowUnavailable:
            "Finder did not expose its Command-N new-window action."
        case .finderWindowOwnershipAmbiguous:
            "Finder created more than one possible window; none was claimed."
        case .finderWindowTimeout: "Finder did not create a focused window."
        case .finderSelectionTimeout: "Finder did not apply the requested selection."
        case .keyboardEventUnavailable:
            "The Finder automation helper could not create a keyboard event."
        case .pointerEventUnavailable:
            "The Finder automation helper could not create a pointer event."
        case .showMenuUnavailable: "Finder did not expose AXShowMenu for this context."
        case let .menuOpenTimeout(bundleIdentifier):
            "The Finder menu did not open; frontmost application: \(bundleIdentifier ?? "unavailable")."
        case .menuStabilityTimeout: "The Finder menu did not stabilize."
        case .menuCancelUnavailable: "The Finder menu did not expose AXCancel."
        case .menuCloseTimeout: "The Finder menu did not close."
        case .sheetCancelUnavailable:
            "The owned Finder sheet did not expose a cancel action."
        case .sheetCloseTimeout: "The owned Finder sheet did not close."
        case .windowCloseTimeout: "The owned Finder window did not close."
        case let .focusLost(reason): reason
        case .menuChanged: "The Finder menu rect or titles changed during capture."
        case let .menuItemUnexpected(title): "An excluded menu command appeared during observation: \(title)"
        case let .menuItemUnavailable(title):
            "Expected one enabled menu item or submenu: \(title)"
        case let .screenshotFailed(message): "Screenshot failed: \(message)"
        case let .accessibility(operation, error):
            "\(operation.rawValue) failed with AXError \(error.rawValue)."
        case let .invalidAccessibilityValue(attribute):
            "Finder returned an invalid \(attribute) value."
        case let .unexpected(message): message
        }
    }
}

enum AutomationTiming {
    static let finder: TimeInterval = 10
    static let target: TimeInterval = 10
    static let menu: TimeInterval = 5
    static let stability: TimeInterval = 2
    static let cleanup: TimeInterval = 2
    static let accessibilityRetry: TimeInterval = 0.25
    static let accessibilityRetryAttempts = 3
    static let poll: TimeInterval = 0.05
}
