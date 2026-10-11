/**
 为 README 的真实 Finder 截图准备 TXT、Markdown 两个模板。
 在 guest 中重置当前 Debug 配置，再通过真实设置页和原生选择器导入并命名，不直接生成产品索引。
 */

import AppKit
import ApplicationServices
import Foundation

@MainActor
enum ReadmeTemplateFixture {
    static func prepare(_ input: DesktopAcceptanceSuite.Input) async throws {
        try DesktopUI.requireVirtualMachine()
        try DesktopUI.require(PermissionReport.current().isReady, "README fixture requires desktop helper permissions")
        guard let bundle = Bundle(url: input.appURL), let identifier = bundle.bundleIdentifier,
              identifier.hasSuffix(".debug") else {
            throw DesktopUI.Failure.assertion("README fixture requires the actual Debug product")
        }
        let library = URL.applicationSupportDirectory.appendingPathComponent(identifier).appendingPathComponent("FileTemplates")
        let indexURL = library.appendingPathComponent("index.json")
        for app in NSWorkspace.shared.runningApplications where app.bundleURL?.standardizedFileURL == input.appURL {
            app.forceTerminate()
            let _: Bool = try DesktopUI.wait("Debug product did not stop before README fixture reset") { app.isTerminated ? true : nil }
        }
        if FileManager.default.fileExists(atPath: library.path) { try FileManager.default.removeItem(at: library) }
        let preferences = UserDefaults(suiteName: identifier)!
        preferences.removePersistentDomain(forName: identifier)
        preferences.set(["en"], forKey: "AppleLanguages")
        preferences.synchronize()
        try FileManager.default.createDirectory(at: input.outputURL, withIntermediateDirectories: true)
        let app = try DesktopUI.application(input.appURL)
        try DesktopUI.activate(app)
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        try DesktopUI.click(DesktopUI.find(ax, role: kAXStaticTextRole, name: "File Templates"))
        func index() throws -> DesktopAcceptanceSuite.Index {
            try JSONDecoder().decode(DesktopAcceptanceSuite.Index.self, from: Data(contentsOf: indexURL))
        }
        let initial: DesktopAcceptanceSuite.Index = try DesktopUI.wait("Initial TXT template did not appear") {
            FileManager.default.fileExists(atPath: indexURL.path) ? try index() : nil
        }
        try DesktopUI.require(initial.templates.count == 1 && initial.templates[0].template.displayName == "TXT"
                              && initial.templates[0].template.defaultFileName == "untitled.txt", "Initial README TXT fixture differs from the product baseline")
        let markdown = input.outputURL.appendingPathComponent("README.md")
        try Data("# Example\n\nMarkdown template.\n".utf8).write(to: markdown)
        try DesktopUI.press(DesktopUI.find(ax, role: kAXButtonRole, name: "Add Template…"))
        try DesktopUI.chooseFile(markdown, in: ax, confirming: "Open")
        let imported: DesktopAcceptanceSuite.Index = try DesktopUI.wait("README Markdown template import did not commit") {
            let value = try index()
            return value.templates.count == 2 ? value : nil
        }
        let id = imported.templates[1].template.id
        let field = try DesktopUI.find(ax, identifier: "file-template.\(id.uuidString).display-name")
        try DesktopUI.edit(field, in: ax, value: "Markdown")
        let _: Bool = try DesktopUI.wait("README Markdown template name edit did not commit") {
            try index().templates[1].template.displayName == "Markdown" ? true : nil
        }
        let final = try index()
        try DesktopUI.require(final.templates.map(\.template.displayName) == ["TXT", "Markdown"]
                              && final.templates.map(\.template.defaultFileName) == ["untitled.txt", "untitled.md"],
                              "Real README template library must match the two preview rows")
        try Data(contentsOf: indexURL).write(to: input.outputURL.appendingPathComponent("prepared-template-index.json"))
        try await DesktopUI.screenshot(pid: app.processIdentifier, to: input.outputURL.appendingPathComponent("prepared-template-settings.png"))
        try Data("TXT\tuntitled.txt\nMarkdown\tuntitled.md\n".utf8)
            .write(to: input.outputURL.appendingPathComponent("expected-templates.tsv"))
    }
}
