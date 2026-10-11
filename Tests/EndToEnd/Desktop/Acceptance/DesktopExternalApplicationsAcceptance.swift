/**
 从真实 Finder 菜单执行外部应用命令，核对命令适用范围并保存实际窗口证据。
 第三方应用内部的目标加载与工作目录留给人工检查，不驱动其引导页或编辑器控件。
 */

import AppKit
import Foundation

extension DesktopAcceptanceSuite {
    func externalApplications() async throws {
        struct ApplicationVersion: Encodable { let identifier: String; let version: String; let build: String }
        struct Request: Encodable { let application: String; let target: String; let screenshots: [String] }
        let versions = try ["com.microsoft.VSCode", "com.googlecode.iterm2"].map { identifier -> ApplicationVersion in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier), let bundle = Bundle(url: url),
                  let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
                throw DesktopUI.Failure.assertion("External application is unavailable or lacks version metadata: \(identifier)")
            }
            return ApplicationVersion(identifier: identifier, version: version, build: build)
        }
        try JSONEncoder().encode(versions).write(to: input.outputURL.appendingPathComponent("external-application-versions.json"))
        let directory = try directory("external-app-target")
        let source = directory.appendingPathComponent("ECMenu-open-target.txt")
        try Data("ECMenu external application review target\n".utf8).write(to: source)
        let project = try self.directory("ECMenu-project-folder")
        try Data("ECMenu workspace review marker\n".utf8).write(to: project.appendingPathComponent("workspace-marker.txt"))
        var requests: [Request] = []

        try await menu(try items([source]), evidence: "open-in-vscode", requiredTitles: ["Open in Visual Studio Code"]) { session, snapshot in
            try assert(!snapshot.titles.contains("Open in iTerm2") && snapshot.titles.contains("Copy Path") && snapshot.titles.contains("Hide Items"),
                       "An ordinary file omits iTerm2 while retaining applicable file commands")
            try session.pressItem(named: "Open in Visual Studio Code")
            let screenshots = try await ExternalApplicationWindows.capture(identifier: "com.microsoft.VSCode", evidence: "vscode-file", output: input.outputURL)
            requests.append(Request(application: "com.microsoft.VSCode", target: source.path, screenshots: screenshots))
        }
        try await menu(try items([project]), evidence: "open-folder-in-vscode", requiredTitles: ["Open in Visual Studio Code", "Open in iTerm2"]) { session, snapshot in
            try assert(snapshot.titles.contains("Open in iTerm2"), "A selected folder offers the directory-only iTerm2 command")
            try session.pressItem(named: "Open in Visual Studio Code")
            let screenshots = try await ExternalApplicationWindows.capture(identifier: "com.microsoft.VSCode", evidence: "vscode-folder", output: input.outputURL)
            requests.append(Request(application: "com.microsoft.VSCode", target: project.path, screenshots: screenshots))
        }
        try await menu(try items([source, directory.appendingPathComponent("anchor.txt")]), evidence: "external-multiselection", requiredTitles: ["Copy Path", "Hide Items"]) { _, snapshot in
            try assert(!snapshot.titles.contains("Open in Visual Studio Code") && !snapshot.titles.contains("Open in iTerm2")
                       && snapshot.titles.contains("Copy Path") && snapshot.titles.contains("Hide Items"),
                       "Multiple files omit external application commands while retaining applicable file commands")
        }
        try await menu(try container(directory), evidence: "open-in-iterm", requiredTitles: ["Open in iTerm2"]) { session, _ in
            try session.pressItem(named: "Open in iTerm2")
            let screenshots = try await ExternalApplicationWindows.capture(identifier: "com.googlecode.iterm2", evidence: "iterm-folder", output: input.outputURL)
            requests.append(Request(application: "com.googlecode.iterm2", target: directory.path, screenshots: screenshots))
        }
        try JSONEncoder().encode(requests).write(to: input.outputURL.appendingPathComponent("external-application-targets.json"))
        requireManualReview(instructions: [
            "Compare the VS Code file and folder screenshots with external-application-targets.json; confirm the requested file content and workspace are visible.",
            "Compare the iTerm screenshots with its recorded target; confirm the terminal working directory manually.",
            "A welcome or permission screen is evidence of an incomplete target check, not a product pass."
        ], evidence: ["external-application-versions.json", "external-application-targets.json"] + requests.flatMap(\.screenshots))
    }

}
