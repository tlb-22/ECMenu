/**
 通过真实 Finder 选择和菜单核对剪贴板路径、文件隐藏属性与适用命令。
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
    func copyAndVisibility() async throws {
        let directory = try directory("paths with spaces")
        let first = directory.appendingPathComponent("中文 first.txt")
        let second = directory.appendingPathComponent("second.txt")
        let originals = [(first, Data("first".utf8)), (second, Data("second".utf8))]
        for (url, bytes) in originals { try bytes.write(to: url) }
        for (context, label) in [(try items([first]), "copy-single"),
                                 (try items([first, second]), "copy-multiple"),
                                 (try container(directory), "copy-container")] {
            let singleOrContainerPath = switch context {
            case let .container(directory, _): directory.path
            case let .items(selection): selection.first.path
            }
            NSPasteboard.general.clearContents()
            try await menu(context, evidence: label, requiredTitles: ["Copy Path"]) { session, _ in
                let observed = try session.selectedURLsBeforeAction()
                try assert(Set(observed) == Set(context.selectedURLs), "\(label) observes the requested Finder selection")
                try session.pressItem(named: "Copy Path")
                defer {
                    struct ClipboardEvidence: Encodable { let selected: [String]; let currentClipboard: String? }
                    let evidence = ClipboardEvidence(selected: observed.map(\.path), currentClipboard: NSPasteboard.general.string(forType: .string))
                    try? JSONEncoder().encode(evidence).write(to: input.outputURL.appendingPathComponent("\(label)-clipboard-observation.json"))
                }
                let actual: String = try DesktopUI.wait("Clipboard paths differ from the selected URLs") {
                    guard let value = NSPasteboard.general.string(forType: .string) else { return nil }
                    if observed.count <= 1 { return value == singleOrContainerPath ? value : nil }
                    let paths = value.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                    return paths.count == observed.count && Set(paths) == Set(observed.map(\.path)) ? value : nil
                }
                try actual.write(to: input.outputURL.appendingPathComponent("\(label)-clipboard.txt"), atomically: true, encoding: .utf8)
                if observed.count > 1 {
                    NSPasteboard.general.clearContents()
                    try session.copySelectedPathnamesUsingFinder()
                    let reference: String = try DesktopUI.wait("Finder's own path copy did not produce text") {
                        NSPasteboard.general.string(forType: .string)
                    }
                    try reference.write(to: input.outputURL.appendingPathComponent("\(label)-finder-reference.txt"), atomically: true, encoding: .utf8)
                    let referencePaths = try nativeFinderPaths(reference)
                    try assert(referencePaths.count == observed.count && Set(referencePaths) == Set(observed.map(\.path)),
                               "Finder's independent path copy contains exactly the selected targets")
                    try assert(actual.split(separator: "\n").map(String.init) == referencePaths,
                               "Multi-selection order matches Finder's independent Copy as Pathnames command")
                }
                try assert(true, "\(label) produces exact POSIX paths without a trailing newline")
            }
        }
        try await menu(try items([first, second]), evidence: "hide-items", requiredTitles: ["Hide Items"]) { session, snapshot in
            try assert(snapshot.titles.contains("Hide Items") && !snapshot.titles.contains("Show Items"), "Visible selection exposes only Hide Items")
            try session.pressItem(named: "Hide Items")
            let _: Bool = try DesktopUI.wait("Hide command did not set file flags") { try [first, second].allSatisfy { try hidden($0) } ? true : nil }
            try assert(true, "Hide Items changes real flags for every selected file")
            for (url, bytes) in originals {
                try assert(try Data(contentsOf: url) == bytes, "Hide Items preserves \(url.lastPathComponent) bytes at its original path")
            }
        }
        // 仅改变 guest Finder 的显示方式，使隐藏项目可以被用户实际选中。
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            throw DesktopUI.Failure.assertion("Finder stopped before hidden-item selection")
        }
        try DesktopUI.activate(finder)
        try DesktopUI.key(CGKeyCode(kVK_ANSI_Period), flags: [.maskCommand, .maskShift])
        try await menu(try items([first, second]), evidence: "show-items", requiredTitles: ["Show Items"]) { session, snapshot in
            try assert(snapshot.titles.contains("Show Items") && !snapshot.titles.contains("Hide Items"), "Hidden selection exposes only Show Items")
            try session.pressItem(named: "Show Items")
            let _: Bool = try DesktopUI.wait("Show command did not clear file flags") { try [first, second].allSatisfy { try !hidden($0) } ? true : nil }
            try assert(true, "Show Items clears flags and preserves file paths and contents")
        }
        for (url, bytes) in originals {
            try assert(try Data(contentsOf: url) == bytes, "Show Items preserves \(url.lastPathComponent) bytes at its original path")
        }
    }

    private func hidden(_ url: URL) throws -> Bool {
        var value = stat()
        try DesktopUI.require(lstat(url.path, &value) == 0, "Could not inspect actual output flags")
        return value.st_flags & UInt32(UF_HIDDEN) != 0
    }

    /// Finder 自身以 shell 引用和空格分隔路径；标准 shlex 解码独立输出，不推导排序。
    private func nativeFinderPaths(_ text: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import json,shlex,sys; json.dump(shlex.split(sys.stdin.read()),sys.stdout)"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(text.utf8))
        try input.fileHandleForWriting.close()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try DesktopUI.require(process.terminationStatus == 0, "Finder native path text is not valid shell quoting")
        return try JSONDecoder().decode([String].self, from: result)
    }
}
