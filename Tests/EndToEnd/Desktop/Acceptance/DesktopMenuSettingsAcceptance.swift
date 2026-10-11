/**
 从真实设置控件与 Finder 菜单验证命令开关、排序和后台会话生命周期。
 操作只经过桌面驱动，持久化与菜单结果由独立验收条件检查。
 */

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

extension DesktopAcceptanceSuite {
    func menuSettingsAndSession() async throws {
        let directory = try directory("settings-menu")
        try pane("General")
        guard let displayName = Bundle(url: input.appURL)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String else {
            throw DesktopUI.Failure.assertion("Actual product lacks its visible application name")
        }
        try DesktopUI.setSwitch(named: "Enable \(displayName)", in: axApp, enabled: false)
        try await menu(try container(directory), evidence: "application-disabled") { session, _ in
            let snapshot = try session.observeAbsentItems(named: Set(commands))
            try await MenuScreenshot.capture(snapshot, to: input.outputURL.appendingPathComponent("application-disabled-observed.png"))
            try assert(true, "All ECMenu commands remain absent throughout the full Finder menu observation window after disabling the master switch")
        }
        try pane("General")
        try DesktopUI.setSwitch(named: "Enable \(displayName)", in: axApp, enabled: true)
        try pane("Context Menu")
        try DesktopUI.setSwitch(named: "Show Copy Path", in: axApp, enabled: false)
        try await menu(try container(directory), evidence: "copy-path-disabled", requiredTitles: ["New File"]) { _, snapshot in
            try assert(!snapshot.titles.contains("Copy Path") && snapshot.titles.contains("New File"), "Settings toggle removes Copy Path while retaining New File in a fresh Finder menu")
        }
        try pane("Context Menu")
        try DesktopUI.setSwitch(named: "Show Copy Path", in: axApp, enabled: true)
        try await DesktopUI.drag(DesktopUI.find(axApp, name: "Reorder Copy Path"),
            before: DesktopUI.find(axApp, name: "Reorder New File"),
            evidence: input.outputURL.appendingPathComponent("commands-during-drag.png"))
        try await menu(try container(directory), evidence: "command-order", requiredTitles: ["Copy Path", "New File"]) { _, snapshot in
            let actual = snapshot.titles.filter { commands.contains($0) }
            try assert(actual.prefix(2) == ["Copy Path", "New File"], "Released mouse drag changes fresh Finder command order")
        }
        let originalPID = app.processIdentifier
        for (key, evidence) in [(CGKeyCode(kVK_ANSI_W), "command-w"), (CGKeyCode(kVK_ANSI_Q), "command-q")] {
            _ = try DesktopUI.application(input.appURL)
            try DesktopUI.activate(app)
            try DesktopUI.key(key, flags: .maskCommand)
            let _: Bool = try DesktopUI.wait("Configuration did not close into background host") {
                guard !app.isTerminated, app.activationPolicy == .accessory else { return nil }
                let windows = try AXClient.elements(kAXWindowsAttribute as CFString, of: axApp)
                return windows.isEmpty ? true : nil
            }
            try await menu(try container(directory), evidence: evidence, requiredTitles: ["Copy Path"]) { session, _ in
                NSPasteboard.general.clearContents()
                try session.pressItem(named: "Copy Path")
                let _: Bool = try DesktopUI.wait("Background command host did not execute Copy Path") { NSPasteboard.general.string(forType: .string) == directory.path ? true : nil }
                try assert(true, "\(evidence) preserves background command execution")
            }
            let reopened = try DesktopUI.application(input.appURL)
            try assert(reopened.processIdentifier == originalPID, "\(evidence) reopening reuses existing process")
        }
        app.forceTerminate()
        let _: Bool = try DesktopUI.wait("Product did not stop") { app.isTerminated ? true : nil }
        app = try DesktopUI.application(input.appURL)
        try await menu(try container(directory), evidence: "order-after-restart", requiredTitles: ["Copy Path", "New File"]) { _, snapshot in
            try assert(snapshot.titles.filter { commands.contains($0) }.prefix(2) == ["Copy Path", "New File"], "Actual product restart preserves command order")
        }
    }

}
