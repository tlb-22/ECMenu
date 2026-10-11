/**
 在项目虚拟机封存前，通过系统公开入口依次打开示例文件与目录并清理本轮应用进程。
 保存启动窗口和独立目标清单，不读取第三方私有状态或自动处理其引导界面。
 */

import AppKit
import Darwin
import Foundation

@MainActor
enum ExternalApplicationPreparation {
    static func run(output: URL) async throws {
        try DesktopUI.requireVirtualMachine()
        try DesktopUI.require(PermissionReport.current().isReady, "Application preparation requires existing desktop permissions")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let folder = output.appendingPathComponent("ECMenu-template-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let file = folder.appendingPathComponent("ECMenu-template-example.txt")
        try Data("ECMenu project template startup check\n".utf8).write(to: file)
        struct Request: Encodable { let application: String; let target: String; let screenshots: [String] }
        var requests: [Request] = []
        for (identifier, target, evidence) in [
            ("com.microsoft.VSCode", file, "vscode-file"),
            ("com.microsoft.VSCode", folder, "vscode-folder"),
            ("com.googlecode.iterm2", folder, "iterm-folder")
        ] {
            try await stop(identifier: identifier)
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
                throw DesktopUI.Failure.assertion("Template application is not installed: \(identifier)")
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.open([target], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
            let screenshots = try await ExternalApplicationWindows.capture(identifier: identifier, evidence: evidence, output: output)
            requests.append(Request(application: identifier, target: target.path, screenshots: screenshots))
            try await stop(identifier: identifier)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(requests).write(to: output.appendingPathComponent("startup-targets.json"))
    }

    private static func stop(identifier: String) async throws {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        for application in applications {
            try DesktopUI.require(kill(application.processIdentifier, SIGTERM) == 0, "Could not stop template application process: \(identifier)")
        }
        let deadline = Date().addingTimeInterval(10)
        while applications.contains(where: { !$0.isTerminated }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        try DesktopUI.require(applications.allSatisfy(\.isTerminated), "Template application process did not stop: \(identifier)")
    }
}
