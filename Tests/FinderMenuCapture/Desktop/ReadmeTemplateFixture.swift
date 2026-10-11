/**
 为 README 的真实 Finder 截图准备 TXT、Markdown、Word 三个模板。
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
        let word = try wordTemplate(in: input.outputURL)
        for (position, source, title) in [(2, markdown, "Markdown"), (3, word, "Word")] {
            try DesktopUI.press(DesktopUI.find(ax, role: kAXButtonRole, name: "Add Template…"))
            try DesktopUI.chooseFile(source, in: ax, confirming: "Open")
            let imported: DesktopAcceptanceSuite.Index = try DesktopUI.wait("README template import did not commit") {
                let value = try index()
                return value.templates.count == position ? value : nil
            }
            let id = imported.templates[position - 1].template.id
            let field = try DesktopUI.find(ax, identifier: "file-template.\(id.uuidString).display-name")
            try DesktopUI.edit(field, in: ax, value: title)
            let _: Bool = try DesktopUI.wait("README template name edit did not commit") {
                try index().templates[position - 1].template.displayName == title ? true : nil
            }
        }
        let final = try index()
        try DesktopUI.require(final.templates.map(\.template.displayName) == ["TXT", "Markdown", "Word"]
                              && final.templates.map(\.template.defaultFileName) == ["untitled.txt", "untitled.md", "untitled.docx"],
                              "Real README template library must match the three preview rows")
        try Data(contentsOf: indexURL).write(to: input.outputURL.appendingPathComponent("prepared-template-index.json"))
        try await DesktopUI.screenshot(pid: app.processIdentifier, to: input.outputURL.appendingPathComponent("prepared-template-settings.png"))
        try Data("TXT\tuntitled.txt\nMarkdown\tuntitled.md\nWord\tuntitled.docx\n".utf8)
            .write(to: input.outputURL.appendingPathComponent("expected-templates.tsv"))
    }

    private static func wordTemplate(in root: URL) throws -> URL {
        let package = root.appendingPathComponent("word-package", isDirectory: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("word"), withIntermediateDirectories: true)
        let files = [
            "[Content_Types].xml": "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>",
            "_rels/.rels": "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>",
            "word/document.xml": "<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p><w:r><w:t>Word template.</w:t></w:r></w:p><w:sectPr/></w:body></w:document>"
        ]
        for (path, content) in files { try Data(content.utf8).write(to: package.appendingPathComponent(path)) }
        let output = root.appendingPathComponent("Blank.docx")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = package
        zip.arguments = ["-q", "-r", output.path, "[Content_Types].xml", "_rels", "word"]
        try zip.run()
        zip.waitUntilExit()
        try DesktopUI.require(zip.terminationStatus == 0, "Could not construct a valid Word template input")
        return output
    }
}
