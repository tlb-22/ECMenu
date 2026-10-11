/**
 从真实设置页和 Finder 菜单执行产品验收，核对文件、剪贴板、图片与持久化输出。
 输入和预期由测试独立定义；报告逐项保存步骤、断言、截图与失败现场，不导入产品实现。
 */

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class DesktopAcceptanceSuite {
    struct Input {
        let appURL: URL
        let outputURL: URL

        static func parse(_ arguments: [String]) throws -> Self {
            guard arguments.count == 3, arguments[1].hasPrefix("/"), arguments[2].hasPrefix("/") else {
                throw AutomationFailure.usage
            }
            return Self(appURL: URL(fileURLWithPath: arguments[1]).standardizedFileURL,
                        outputURL: URL(fileURLWithPath: arguments[2]).standardizedFileURL)
        }
    }

    struct Index: Decodable {
        let templates: [Record]
        struct Record: Decodable {
            let template: Template
            let file: File
            struct Template: Decodable, Equatable { let id: UUID; let displayName: String; let defaultFileName: String }
            struct File: Decodable { let id: UUID; let fileName: String }
        }
    }

    enum Status: String, Encodable {
        case running, passed, failed
        case reviewPending = "review-pending"
    }

    private struct ManualReview: Encodable {
        let instructions: [String]
        let evidence: [String]
    }

    private struct CaseResult: Encodable {
        let name: String
        let steps: [String]
        var assertions: [String] = []
        var status: Status = .running
        var manualReview: ManualReview?
        var seconds: TimeInterval = 0
        var error: String?
    }

    private struct Report: Encodable {
        let application: String
        let startedAt: Date
        var status: Status = .running
        var cases: [CaseResult] = []
        let visualVerification = "Screenshots are review evidence; no pixel assertions are implemented."
        let excluded = ["clean installation", "first permission prompts", "real logout/login", "minimum supported macOS", "real input method composition"]
    }

    let input: Input
    private let appIdentifier: String
    let fixtureURL: URL
    let indexURL: URL
    var app: NSRunningApplication!
    var axApp: AXUIElement { AXUIElementCreateApplication(app.processIdentifier) }
    private var report: Report
    let commands = ["New File", "Copy Path", "Hide Items", "Show Items", "Compress Images", "Open in Visual Studio Code", "Open in iTerm2"]
    var importedID: UUID!
    let originalBytes = Data("ECMenu end-to-end template\n中文与 spaces\n".utf8)
    let replacedBytes = Data([0, 255, 13, 10, 65, 66, 67, 0])

    init(input: Input) throws {
        self.input = input
        guard let bundle = Bundle(url: input.appURL), let identifier = bundle.bundleIdentifier,
              identifier.hasSuffix(".debug") else { throw DesktopUI.Failure.assertion("Desktop suite requires the actual Debug product") }
        appIdentifier = identifier
        fixtureURL = input.outputURL.appendingPathComponent("fixtures", isDirectory: true)
        indexURL = URL.applicationSupportDirectory.appendingPathComponent(identifier)
            .appendingPathComponent("FileTemplates/index.json")
        report = Report(application: input.appURL.path, startedAt: Date())
    }

    func run() async throws -> Status {
        try DesktopUI.requireVirtualMachine()
        try DesktopUI.require(PermissionReport.current().isReady, "Desktop helper requires Accessibility and Screen Recording")
        try FileManager.default.createDirectory(at: fixtureURL, withIntermediateDirectories: true)
        try persist()
        do {
            app = try DesktopUI.application(input.appURL)
            try DesktopUI.activate(app)
            try await check("template-import-edit-and-restart", steps: ["Open real File Templates page", "Import ordinary files through native chooser", "Click and edit both names", "Drag row and inspect persisted order", "Restart current product"]) {
                try await templateManagement()
            }
            try await check("new-file-bytes-and-conflicts", steps: ["Open real Finder container menu", "Choose stored template", "Inspect bytes and selected new file", "Repeat with existing output"]) {
                try await newFiles()
            }
            try await check("template-replace-and-delete", steps: ["Replace content through native chooser", "Create file from updated menu", "Delete template through its row button", "Check source and prior outputs survive"]) {
                try await replaceAndDelete()
            }
            try await check("copy-path-and-visibility", steps: ["Copy single, multi and container paths", "Hide and show through Finder", "Inspect flags and exact available commands"]) {
                try await copyAndVisibility()
            }
            try await check("image-compression", steps: ["Open settings from image selection", "Cancel without output", "Submit width and quality", "Decode actual JPEGs and check metadata, conflicts, dates and sources", "Compare actual low and high quality outputs from the same textured source"]) {
                try await compressImages()
            }
            try await check("menu-settings-and-session", steps: ["Toggle command visibility", "Drag command order", "Inspect fresh Finder menus", "Close configuration with Command-W and Command-Q", "Execute background command and reopen existing process"]) {
                try await menuSettingsAndSession()
            }
            try await check("external-application-menus-and-evidence", steps: ["Click actual Finder commands for a file and folder", "Check applicable commands and application launch", "Capture every visible target application window", "Record independent targets for manual review"]) {
                try await externalApplications()
            }
            try await check("unwritable-target-feedback", steps: ["Select read-only folder", "Click New File template", "Inspect real error alert and absence of output"]) {
                try await permissionFailure()
            }
            try await check("template-library-failure-and-empty", steps: ["Corrupt actual on-disk index and restart", "Inspect visible error and other Finder commands", "Restore index and use Retry", "Delete final template and restart"]) {
                try await libraryFailureAndEmpty()
            }
            report.status = report.cases.contains { $0.status == .reviewPending } ? .reviewPending : .passed
            try persist()
            return report.status
        } catch {
            report.status = .failed
            try persist()
            if let app, !app.isTerminated {
                try? DesktopUI.dump(axApp, to: input.outputURL.appendingPathComponent("failure-product-ax.tsv"))
                try? await DesktopUI.screenshot(pid: app.processIdentifier, to: input.outputURL.appendingPathComponent("failure-product.png"))
            }
            if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
                try? DesktopUI.dump(AXUIElementCreateApplication(finder.processIdentifier), to: input.outputURL.appendingPathComponent("failure-finder-ax.tsv"))
            }
            if let frontmost = NSWorkspace.shared.frontmostApplication,
               frontmost.processIdentifier != app?.processIdentifier,
               frontmost.bundleIdentifier != "com.apple.finder" {
                try? DesktopUI.dump(AXUIElementCreateApplication(frontmost.processIdentifier),
                                    to: input.outputURL.appendingPathComponent("failure-external-ax.tsv"))
                try? await DesktopUI.screenshot(pid: frontmost.processIdentifier,
                                                to: input.outputURL.appendingPathComponent("failure-external.png"))
            }
            for identifier in ["com.microsoft.VSCode", "com.googlecode.iterm2"] {
                if let external = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first {
                    try? DesktopUI.dump(AXUIElementCreateApplication(external.processIdentifier),
                                        to: input.outputURL.appendingPathComponent("failure-\(identifier)-ax.tsv"))
                    try? await DesktopUI.screenshot(pid: external.processIdentifier,
                                                    to: input.outputURL.appendingPathComponent("failure-\(identifier).png"))
                }
            }
            throw error
        }
    }

    private func check(_ name: String, steps: [String], operation: () async throws -> Void) async throws {
        report.cases.append(CaseResult(name: name, steps: steps))
        try persist()
        let began = Date()
        print("CASE\t\(name)\trunning")
        do {
            try await operation()
            report.cases[report.cases.count - 1].status = report.cases.last!.manualReview == nil ? .passed : .reviewPending
        } catch {
            report.cases[report.cases.count - 1].status = .failed
            report.cases[report.cases.count - 1].manualReview = nil
            report.cases[report.cases.count - 1].error = String(describing: error)
            report.cases[report.cases.count - 1].seconds = Date().timeIntervalSince(began)
            try persist()
            throw error
        }
        report.cases[report.cases.count - 1].seconds = Date().timeIntervalSince(began)
        try persist()
        print("CASE\t\(name)\t\(report.cases.last!.status.rawValue)")
    }

    func requireManualReview(instructions: [String], evidence: [String]) {
        precondition(!instructions.isEmpty && !evidence.isEmpty && report.cases.last?.manualReview == nil)
        report.cases[report.cases.count - 1].manualReview = ManualReview(instructions: instructions, evidence: evidence)
    }

    func assert(_ condition: Bool, _ message: String) throws {
        try DesktopUI.require(condition, message)
        report.cases[report.cases.count - 1].assertions.append(message)
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: input.outputURL.appendingPathComponent("report.json"), options: .atomic)
        if let current = report.cases.last, FileManager.default.fileExists(atPath: indexURL.path) {
            try Data(contentsOf: indexURL).write(to: input.outputURL.appendingPathComponent("\(current.name)-template-index.json"), options: .atomic)
        }
    }

    func index() throws -> Index { try JSONDecoder().decode(Index.self, from: Data(contentsOf: indexURL)) }

    func templateRecord(_ id: UUID) throws -> Index.Record {
        guard let record = try index().templates.first(where: { $0.template.id == id }) else {
            throw DesktopUI.Failure.assertion("Committed template disappeared from actual index: \(id)")
        }
        return record
    }

    func pane(_ name: String) throws {
        try DesktopUI.activate(app)
        try DesktopUI.click(DesktopUI.find(axApp, role: kAXStaticTextRole, name: name))
    }

    func templateField(_ id: UUID, _ field: String) throws -> AXUIElement {
        try DesktopUI.find(axApp, identifier: "file-template.\(id.uuidString).\(field)")
    }

    func rowButton(_ id: UUID, _ title: String) throws -> AXUIElement {
        let field = try templateField(id, "display-name")
        let fieldFrame = try AXClient.frame(of: field)
        let candidates = try DesktopUI.elements(axApp).filter {
            try DesktopUI.matches($0, role: kAXButtonRole, name: title)
                && abs(AXClient.frame(of: $0).midY - fieldFrame.midY) < 35
        }
        try DesktopUI.require(candidates.count == 1, "Expected one \(title) button in the target template row")
        return candidates[0]
    }

    func directory(_ name: String) throws -> URL {
        let url = fixtureURL.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("opening item".utf8).write(to: url.appendingPathComponent("anchor.txt"))
        return url
    }

    func container(_ directory: URL) throws -> FinderMenuContext {
        .container(directory: directory, openingItem: directory.appendingPathComponent("anchor.txt"))
    }

    func items(_ urls: [URL]) throws -> FinderMenuContext {
        .items(try ItemSelection(first: urls[0], remaining: Array(urls.dropFirst())))
    }

    func menu(_ context: FinderMenuContext, evidence: String, requiredTitles: Set<String> = [],
                      operation: (FinderMenuSession, MenuSnapshot) async throws -> Void) async throws {
        let session = FinderMenuSession(context: context)
        do {
            let snapshot = try session.prepare(requiredTitles: requiredTitles)
            try snapshot.titles.joined(separator: "\n").write(to: input.outputURL.appendingPathComponent("\(evidence)-titles.txt"), atomically: true, encoding: .utf8)
            try await MenuScreenshot.capture(snapshot, to: input.outputURL.appendingPathComponent("\(evidence).png"))
            try await operation(session, snapshot)
            try session.closeOwnedUI()
        } catch {
            if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
                try? DesktopUI.dump(AXUIElementCreateApplication(finder.processIdentifier), to: input.outputURL.appendingPathComponent("\(evidence)-failure-ax.tsv"))
                try? await DesktopUI.screenshot(pid: finder.processIdentifier, to: input.outputURL.appendingPathComponent("\(evidence)-failure-finder.png"))
            }
            try? session.closeOwnedUI()
            throw error
        }
    }


}
