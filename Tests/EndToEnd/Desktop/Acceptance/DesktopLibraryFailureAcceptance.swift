/**
 在 guest 文件系统制造不可写目录和坏索引，验证可见失败、重试与空库重启行为。
 操作仅经过桌面驱动，断言读取真实外部结果；证据与报告由验收会话统一拥有。
 */

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension DesktopAcceptanceSuite {
    func permissionFailure() async throws {
        let parent = try directory("read-only-parent")
        let target = parent.appendingPathComponent("read-only-target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try DesktopUI.require(chmod(target.path, 0o555) == 0, "Could not construct real unwritable directory")
        defer { _ = chmod(target.path, 0o755) }
        try await menu(try items([target]), evidence: "unwritable-new-file", requiredTitles: ["New File"]) { session, _ in
            let submenu = try await session.prepareSubmenu(parentTitle: "New File")
            try session.pressItem(named: "TXT", in: submenu)
            let _: AXUIElement = try DesktopUI.wait("Real write failure did not present an alert") {
                try DesktopUI.elements(axApp).first { try AXClient.string(kAXRoleAttribute as CFString, of: $0) == kAXButtonRole && AXClient.string(kAXTitleAttribute as CFString, of: $0) == "OK" }
            }
            try DesktopUI.dump(axApp, to: input.outputURL.appendingPathComponent("unwritable-alert-ax.tsv"))
            try await DesktopUI.screenshot(pid: app.processIdentifier, to: input.outputURL.appendingPathComponent("unwritable-alert.png"))
            let content = try String(contentsOf: input.outputURL.appendingPathComponent("unwritable-alert-ax.tsv"), encoding: .utf8)
            try assert(content.contains("read-only-target") && content.lowercased().contains("writ"), "Real alert identifies the unwritable target")
            try assert(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty, "Failed write creates no file")
            try DesktopUI.press(DesktopUI.find(axApp, role: kAXButtonRole, name: "OK"))
        }
    }

    func libraryFailureAndEmpty() async throws {
        let saved = try Data(contentsOf: indexURL)
        app.forceTerminate()
        let _: Bool = try DesktopUI.wait("Product did not stop before index fault") { app.isTerminated ? true : nil }
        try Data("{broken index".utf8).write(to: indexURL)
        app = try DesktopUI.application(input.appURL)
        try pane("File Templates")
        _ = try DesktopUI.find(axApp, role: kAXStaticTextRole, name: "Unable to Load Templates")
        try assert(true, "Real malformed index produces the template page failure state")
        try await DesktopUI.screenshot(pid: app.processIdentifier, to: input.outputURL.appendingPathComponent("template-library-failure.png"))
        let destination = try directory("library-failure")
        try await menu(try container(destination), evidence: "library-failure-menu", requiredTitles: ["Copy Path"]) { session, snapshot in
            try assert(!snapshot.titles.contains("New File") && snapshot.titles.contains("Copy Path"), "Unreadable library hides New File while other commands remain available")
            NSPasteboard.general.clearContents()
            try session.pressItem(named: "Copy Path")
            let _: Bool = try DesktopUI.wait("Other command failed while template library was invalid") { NSPasteboard.general.string(forType: .string) == destination.path ? true : nil }
        }
        try saved.write(to: indexURL, options: .atomic)
        try pane("File Templates")
        try DesktopUI.press(DesktopUI.find(axApp, role: kAXButtonRole, name: "Retry"))
        let recovered = try index().templates
        try assert(recovered.count == 1, "Retry restores the independently expected remaining template record")
        let id = recovered[0].template.id
        _ = try templateField(id, "display-name")
        try assert(true, "Retry recovers from an actual repaired index")
        try DesktopUI.press(rowButton(id, "Delete Template"))
        let _: Bool = try DesktopUI.wait("Last template deletion did not persist empty library") { try index().templates.isEmpty ? true : nil }
        app.forceTerminate()
        let _: Bool = try DesktopUI.wait("Product did not stop before empty library restart") { app.isTerminated ? true : nil }
        app = try DesktopUI.application(input.appURL)
        try pane("File Templates")
        _ = try DesktopUI.find(axApp, role: kAXStaticTextRole, name: "No File Templates")
        try assert(try index().templates.isEmpty, "Real restart preserves the deliberately empty library without recreating TXT")
        try await menu(try container(destination), evidence: "empty-library-menu", requiredTitles: ["Copy Path"]) { _, snapshot in
            try assert(!snapshot.titles.contains("New File") && snapshot.titles.contains("Copy Path"), "An empty library hides New File while retaining other commands")
        }
    }
}
