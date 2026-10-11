/**
 在测试环境准备阶段实际捕获系统设置窗口，并处理当前驱动的系统录屏授权提示。
 只在虚拟机执行；仅匹配 Apple 进程中明确指向本驱动的提示，不处理产品对话框。
 */

import AppKit
import ApplicationServices
import Foundation
import ScreenCaptureKit
import Security

@MainActor
enum CapturePermissionPreparation {
    private enum ConsentState { case waiting, approved }

    static func run(output: URL) async throws {
        try DesktopUI.requireVirtualMachine()
        try DesktopUI.require(PermissionReport.current().isReady, "Capture preparation requires existing AX and screen permissions")
        let window = try await settingsWindow()
        try await MenuScreenshot.captureWindow(number: window.windowID, to: output)
        let deadline = Date().addingTimeInterval(30)
        var state: ConsentState = .waiting
        while Date() < deadline {
            let prompt = try consentPrompt()
            if let prompt, state == .waiting {
                let labels = try prompt.buttons.map { try AXClient.string(kAXTitleAttribute as CFString, of: $0) ?? "" }
                print("CAPTURE_CONSENT_BUTTONS\t\(try JSONEncoder().encode(labels).base64EncodedString())")
                let allowed = ["Allow for One Month", "Allow for 1 Month", "Continue Allowing", "Allow", "允许一个月", "继续允许", "允许"]
                // 下方按显式名称定位，避免把打开系统设置或拒绝按钮当作授权。
                let candidates = try prompt.buttons.filter { button in
                    try allowed.contains { try DesktopUI.matches(button, name: $0) }
                }
                try DesktopUI.require(candidates.count == 1, "Unknown or ambiguous screen capture consent button")
                try DesktopUI.press(candidates[0])
                state = .approved
            } else if state == .approved, prompt == nil {
                print("CAPTURE_CONSENT\tapproved")
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        try DesktopUI.require(state == .waiting, "Screen capture consent did not close after approval")
        print("CAPTURE_CONSENT\tnot-present")
    }

    private struct Prompt {
        let buttons: [AXUIElement]
    }

    private static func settingsWindow() async throws -> SCWindow {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences")
            try DesktopUI.require(applications.count <= 1, "Capture preparation found multiple System Settings processes")
            if let application = applications.first {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                let windows = content.windows.filter {
                    $0.isOnScreen && $0.windowLayer == 0 && $0.owningApplication?.processID == application.processIdentifier
                }
                try DesktopUI.require(windows.count <= 1, "Capture preparation found multiple System Settings windows")
                if let window = windows.first { return window }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw DesktopUI.Failure.assertion("System Settings window did not become ready for capture preparation")
    }

    private static func consentPrompt() throws -> Prompt? {
        guard let information = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            throw DesktopUI.Failure.assertion("Could not enumerate visible system window owners")
        }
        let pids = Set(information.compactMap { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value })
        let requirement = try appleRequirement()
        for pid in pids {
            var code: SecCode?
            guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: pid] as CFDictionary,
                                                [], &code) == errSecSuccess,
                  let code, SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { continue }
            let application = AXUIElementCreateApplication(pid)
            var rawWindows: CFTypeRef?
            guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &rawWindows) == .success,
                  let windows = rawWindows as? [AXUIElement] else { continue }
            for window in windows {
                do {
                    let elements = try DesktopUI.elements(window)
                    let messages = try elements.compactMap { element -> String? in
                        guard try AXClient.string(kAXRoleAttribute as CFString, of: element) == kAXStaticTextRole else { return nil }
                        return try AXClient.value(kAXValueAttribute as CFString, of: element, optional: true) as? String
                    }
                    guard messages.contains(where: {
                        $0.contains("FinderMenuAutomation") && ($0.contains("bypass the system private window picker") || $0.contains("绕过系统") || $0.contains("绕过系统专用窗口"))
                    }) else { continue }
                    return Prompt(buttons: try elements.filter {
                        try AXClient.string(kAXRoleAttribute as CFString, of: $0) == kAXButtonRole
                    })
                }
                catch AutomationFailure.accessibility(.readAttribute, .invalidUIElement),
                      AutomationFailure.accessibility(.readAttribute, .cannotComplete) { continue }
            }
        }
        return nil
    }

    private static func appleRequirement() throws -> SecRequirement {
        var requirement: SecRequirement?
        try DesktopUI.require(SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
                              "Could not construct the Apple system process requirement")
        return requirement!
    }
}
