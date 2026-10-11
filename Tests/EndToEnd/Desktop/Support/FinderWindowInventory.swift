/**
 通过 Accessibility 读取当前 Finder 普通窗口数量。
 为菜单截图入口提供已有窗口检查，要求可明确定位唯一 Finder 进程。
 */

import AppKit
import ApplicationServices

enum FinderWindowInventory {
    static func currentCount() throws -> Int {
        let finders = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.finder"
        )
        guard finders.count == 1, let finder = finders.first else {
            throw AutomationFailure.finderUnavailable
        }
        let application = AXUIElementCreateApplication(finder.processIdentifier)
        let windows = try AXClient.elements(
            kAXWindowsAttribute as CFString,
            of: application
        )
        return try windows.filter { window in
            let role = try AXClient.string(
                kAXRoleAttribute as CFString,
                of: window
            )
            let identifier = try AXClient.string(
                kAXIdentifierAttribute as CFString,
                of: window
            )
            return role == kAXWindowRole as String
                && identifier == "FinderWindow"
        }.count
    }
}
