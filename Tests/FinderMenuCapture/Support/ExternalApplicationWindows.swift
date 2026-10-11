/**
 保存实际外部应用进程的全部可见普通窗口和子窗口，供模板准备与菜单验收人工检查。
 窗口标题只作为证据，不用于推断第三方应用内部的加载状态。
 */

import AppKit
import Foundation
import ScreenCaptureKit

@MainActor
enum ExternalApplicationWindows {
    static func capture(identifier: String, evidence: String, output: URL) async throws -> [String] {
        let application: NSRunningApplication = try DesktopUI.wait("External application did not launch: \(identifier)", seconds: 20) {
            NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first
        }
        let deadline = Date().addingTimeInterval(20)
        var windows: [SCWindow] = []
        repeat {
            let content = try await SCShareableContent.current
            windows = content.windows.filter {
                $0.owningApplication?.processID == application.processIdentifier && $0.isOnScreen && $0.windowLayer == 0
            }.sorted { $0.windowID < $1.windowID }
            if !windows.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        try DesktopUI.require(!windows.isEmpty, "External application did not expose a visible window for review: \(identifier)")
        // 窗口出现后留出普通绘制时间，再枚举实际窗口；目标加载仍由截图人工检查。
        try await Task.sleep(for: .seconds(2))
        let content = try await SCShareableContent.current
        windows = content.windows.filter {
            $0.owningApplication?.processID == application.processIdentifier && $0.isOnScreen && $0.windowLayer == 0
        }.sorted { $0.windowID < $1.windowID }
        try DesktopUI.require(!windows.isEmpty, "External application closed its review windows: \(identifier)")
        struct WindowEvidence: Encodable { let id: UInt32; let title: String?; let image: String }
        var records: [WindowEvidence] = []
        for (index, window) in windows.enumerated() {
            let filename = "\(evidence)-window-\(index + 1).png"
            try await MenuScreenshot.captureWindow(number: window.windowID, includingChildWindows: true,
                                                   to: output.appendingPathComponent(filename))
            records.append(WindowEvidence(id: window.windowID, title: window.title, image: filename))
        }
        let manifest = "\(evidence)-windows.json"
        try JSONEncoder().encode(records).write(to: output.appendingPathComponent(manifest))
        return [manifest] + records.map(\.image)
    }
}
