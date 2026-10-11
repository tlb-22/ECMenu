/**
 通过原生文件选择、名称编辑、真实拖动和 Finder 菜单验证模板的完整管理与使用流程。
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
    func templateManagement() async throws {
        let initial: Index = try DesktopUI.wait("Initial template index did not appear") {
            FileManager.default.fileExists(atPath: indexURL.path) ? try index() : nil
        }
        try assert(initial.templates.count == 1 && initial.templates[0].template.displayName == "TXT", "Fresh profile has one TXT template")
        try pane("File Templates")
        let source = fixtureURL.appendingPathComponent("source.txt")
        try originalBytes.write(to: source)
        try DesktopUI.press(DesktopUI.find(axApp, role: kAXButtonRole, name: "Add Template…"))
        try DesktopUI.chooseFile(source, in: axApp, confirming: "Open")
        let imported: Index = try DesktopUI.wait("Imported template did not commit") { let value = try index(); return value.templates.count == 2 ? value : nil }
        importedID = imported.templates[1].template.id
        try assert(imported.templates[1].template.displayName == "TXT 2", "Import assigns first unused display name")
        try DesktopUI.edit(templateField(importedID, "display-name"), in: axApp, value: "E2E Template")
        try DesktopUI.edit(templateField(importedID, "default-file-name"), in: axApp, value: "bad/path.txt")
        try DesktopUI.key(CGKeyCode(kVK_Escape))
        let _: Bool = try DesktopUI.wait("Invalid filename did not restore the committed value after Escape") {
            try AXClient.string(kAXValueAttribute as CFString, of: templateField(importedID, "default-file-name")) == "untitled.txt" ? true : nil
        }
        try assert(try templateRecord(importedID).template.defaultFileName == "untitled.txt", "An invalid path is rejected without changing committed template metadata")
        try DesktopUI.edit(templateField(importedID, "default-file-name"), in: axApp, value: "result.txt", commitKey: CGKeyCode(kVK_Tab))
        try pane("General")
        let _: Bool = try DesktopUI.wait("Both name edits did not commit") {
            let record = try templateRecord(importedID)
            return record.template.displayName == "E2E Template" && record.template.defaultFileName == "result.txt" ? true : nil
        }
        try assert(true, "Click-focused name edits commit both independent fields")
        try pane("File Templates")
        try await DesktopUI.drag(DesktopUI.find(axApp, name: "Reorder E2E Template"),
            before: templateField(initial.templates[0].template.id, "display-name"),
            evidence: input.outputURL.appendingPathComponent("templates-during-drag.png"))
        let _: Bool = try DesktopUI.wait("Mouse drag did not persist template order") {
            try index().templates.first?.template.id == importedID ? true : nil
        }
        try assert(true, "Released mouse drag changes persisted template order")
        try await DesktopUI.screenshot(pid: app.processIdentifier, to: input.outputURL.appendingPathComponent("templates-after-drag.png"))
        try Data("source modified after import".utf8).write(to: source)
        app.forceTerminate()
        let _: Bool = try DesktopUI.wait("Product did not stop for persistence check") { app.isTerminated ? true : nil }
        app = try DesktopUI.application(input.appURL)
        try pane("File Templates")
        let field = try templateField(importedID, "display-name")
        try assert(try AXClient.string(kAXValueAttribute as CFString, of: field) == "E2E Template", "Real product restart restores template names and order")
    }

    private func create(_ directory: URL, name: String, bytes: Data, evidence: String,
                        context: FinderMenuContext? = nil) async throws {
        let target = directory.appendingPathComponent(name)
        try await menu(try context ?? container(directory), evidence: evidence, requiredTitles: ["New File", "Copy Path"]) { session, _ in
            let submenu = try await session.prepareSubmenu(parentTitle: "New File")
            try assert(submenu.snapshot.titles.filter { !$0.isEmpty } == ["E2E Template", "TXT"], "Finder submenu reflects saved template order")
            try await MenuScreenshot.capture(submenu.snapshot, to: input.outputURL.appendingPathComponent("\(evidence)-submenu.png"))
            try session.pressItem(named: "E2E Template", in: submenu)
            let _: Bool = try DesktopUI.wait("Created file content or Finder selection did not match") {
                guard FileManager.default.fileExists(atPath: target.path), try Data(contentsOf: target) == bytes else { return nil }
                return try session.isSoleSelectedItem(target) ? true : nil
            }
            try assert(true, "\(name) has exact template bytes and is selected by Finder")
        }
    }

    func newFiles() async throws {
        let destination = try directory("new-files")
        try await create(destination, name: "result.txt", bytes: originalBytes, evidence: "new-file")
        try await create(destination, name: "result_copy.txt", bytes: originalBytes, evidence: "new-file-conflict")
        try assert(try Data(contentsOf: destination.appendingPathComponent("result.txt")) == originalBytes, "Existing output remains unchanged after conflict")
        let original = try templateRecord(importedID)
        let saved = indexURL.deletingLastPathComponent().appendingPathComponent("Files/\(original.file.id.uuidString)/\(original.file.fileName)")
        try assert(try Data(contentsOf: saved) == originalBytes, "Modifying the import source leaves the stored template copy unchanged")
        let folder = destination.appendingPathComponent("selected-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try await create(folder, name: "result.txt", bytes: originalBytes, evidence: "new-file-selected-folder", context: items([folder]))
        try await create(destination, name: "result_copy2.txt", bytes: originalBytes, evidence: "new-file-selected-file", context: items([destination.appendingPathComponent("anchor.txt")]))
        try await menu(try items([destination.appendingPathComponent("anchor.txt"), destination.appendingPathComponent("result.txt")]), evidence: "new-file-multiple-inapplicable", requiredTitles: ["Copy Path", "Hide Items"]) { _, snapshot in
            try assert(!snapshot.titles.contains("New File") && snapshot.titles.contains("Copy Path") && snapshot.titles.contains("Hide Items"), "Multiple selected files omit New File while retaining applicable Copy Path and Hide Items commands")
        }
    }

    func replaceAndDelete() async throws {
        let replacement = fixtureURL.appendingPathComponent("replacement.bin")
        try replacedBytes.write(to: replacement)
        let before = try index().templates.map(\.template)
        let original = try templateRecord(importedID)
        let originalCopy = indexURL.deletingLastPathComponent().appendingPathComponent("Files/\(original.file.id.uuidString)/\(original.file.fileName)")
        try pane("File Templates")
        let beforeCancel = try Data(contentsOf: indexURL)
        try DesktopUI.press(rowButton(importedID, "Replace…"))
        try DesktopUI.press(DesktopUI.find(axApp, role: kAXButtonRole, name: "Cancel"))
        _ = try templateField(importedID, "display-name")
        try assert(try Data(contentsOf: indexURL) == beforeCancel, "Cancelling the native replacement chooser preserves the complete committed index")
        try assert(try Data(contentsOf: originalCopy) == originalBytes, "Cancelling replacement preserves the original stored template bytes")
        try DesktopUI.press(rowButton(importedID, "Replace…"))
        try DesktopUI.chooseFile(replacement, in: axApp, confirming: "Open")
        let _: Bool = try DesktopUI.wait("Template replacement did not commit") {
            let record = try templateRecord(importedID)
            return record.file.fileName == "replacement.bin" ? true : nil
        }
        try assert(try index().templates.map(\.template) == before, "Replacement preserves template identity, names and order")
        let replacementRecord = try templateRecord(importedID)
        let replacementCopy = indexURL.deletingLastPathComponent().appendingPathComponent("Files/\(replacementRecord.file.id.uuidString)/\(replacementRecord.file.fileName)")
        try await create(try directory("replacement-output"), name: "result.txt", bytes: replacedBytes, evidence: "replaced-template")
        try pane("File Templates")
        try DesktopUI.press(rowButton(importedID, "Delete Template"))
        let _: Bool = try DesktopUI.wait("Template deletion did not commit") { try index().templates.count == 1 ? true : nil }
        let _: Bool = try DesktopUI.wait("Template deletion left the stored internal copy") {
            FileManager.default.fileExists(atPath: replacementCopy.path) ? nil : true
        }
        try assert(true, "Deleting the template removes its stored internal file copy")
        try assert(try Data(contentsOf: replacement) == replacedBytes, "Deleting a template preserves its source file")
        try assert(try Data(contentsOf: fixtureURL.appendingPathComponent("replacement-output/result.txt")) == replacedBytes, "Deleting a template preserves previously created files")
        let destination = try directory("deleted-template-menu")
        try await menu(try container(destination), evidence: "after-template-delete", requiredTitles: ["New File"]) { session, _ in
            let submenu = try await session.prepareSubmenu(parentTitle: "New File")
            try assert(submenu.snapshot.titles.filter { !$0.isEmpty } == ["TXT"], "Deleted template disappears from a fresh Finder submenu")
        }
    }
}
