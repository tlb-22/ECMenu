/**
 驱动虚拟机内真实应用的可访问性控件、键盘与拖动，并保存窗口及树证据。
 不调用业务函数；控件定位失败、聚焦失败和动作失败均终止当前验收。
 */

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Darwin
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

@MainActor
enum DesktopUI {
    enum Failure: Error, LocalizedError, CustomStringConvertible {
        case assertion(String)
        var description: String { switch self { case let .assertion(message): message } }
        var errorDescription: String? { description }
    }

    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure.assertion(message) }
    }

    static func requireVirtualMachine() throws {
        var virtualized: Int32 = 0
        var size = MemoryLayout<Int32>.size
        try require(sysctlbyname("kern.hv_vmm_present", &virtualized, &size, nil, 0) == 0 && virtualized == 1,
                    "Desktop input is restricted to a virtual machine")
    }

    static func wait<T>(_ message: String, seconds: TimeInterval = 10,
                        resolve: () throws -> T?) throws -> T {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            do {
                if let result = try resolve() { return result }
            } catch AutomationFailure.accessibility(.readAttribute, .invalidUIElement),
                    AutomationFailure.accessibility(.readAttribute, .cannotComplete) {
                // 页面和原生 sheet 替换期间只在本次有界等待内重新读取 AX 树。
            }
            runLoopSlice(0.05)
        } while Date() < deadline
        throw Failure.assertion(message)
    }

    static func application(_ appPath: URL) throws -> NSRunningApplication {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [appPath.path]
        try process.run()
        process.waitUntilExit()
        try require(process.terminationStatus == 0, "Opening the actual application failed")
        guard let title = Bundle(url: appPath)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String else {
            throw Failure.assertion("Actual product lacks its configuration window title")
        }
        return try wait("Application configuration window did not become ready") {
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.standardizedFileURL == appPath }),
                  app.isActive else { return nil }
            let windows = try AXClient.elements(kAXWindowsAttribute as CFString, of: AXUIElementCreateApplication(app.processIdentifier))
            let ready = try windows.contains { try AXClient.string(kAXTitleAttribute as CFString, of: $0) == title }
            return ready ? app : nil
        }
    }

    static func activate(_ app: NSRunningApplication) throws {
        app.activate(options: [.activateAllWindows])
        let _: Bool = try wait("Target application did not become frontmost") {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier ? true : nil
        }
    }

    static func elements(_ root: AXUIElement) throws -> [AXUIElement] {
        [root] + (try AXTree.paths(below: root)).map(\.element)
    }

    static func matches(_ element: AXUIElement, role: String? = nil,
                        name: String? = nil, identifier: String? = nil) throws -> Bool {
        if let role, try AXClient.string(kAXRoleAttribute as CFString, of: element) != role { return false }
        if let identifier, try AXClient.string(kAXIdentifierAttribute as CFString, of: element) != identifier { return false }
        if let name {
            let labels = try [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
                .compactMap { try AXClient.value($0 as CFString, of: element, optional: true) as? String }
            if !labels.contains(name) { return false }
        }
        return true
    }

    static func find(_ root: AXUIElement, role: String? = nil, name: String? = nil,
                     identifier: String? = nil) throws -> AXUIElement {
        var lastCount: Int?
        do {
            return try wait("Control unavailable: \(identifier ?? name ?? role ?? "unknown")") {
                let candidates = try elements(root).filter { element in
                    do { return try matches(element, role: role, name: name, identifier: identifier) }
                    catch AutomationFailure.accessibility(.readAttribute, .invalidUIElement) { return false }
                }
                lastCount = candidates.count
                return candidates.count == 1 ? candidates[0] : nil
            }
        } catch {
            print("CONTROL_FAILURE\t\(identifier ?? name ?? role ?? "unknown")\tmatched=\(lastCount.map(String.init) ?? "unreadable")")
            throw error
        }
    }

    static func press(_ element: AXUIElement) throws {
        try require(try AXClient.bool(kAXEnabledAttribute as CFString, of: element) != false, "Control is disabled")
        try AXClient.perform(kAXPressAction as CFString, on: element)
    }

    static func setSwitch(named name: String, in application: AXUIElement, enabled: Bool) throws {
        let control: AXUIElement = try wait("Switch unavailable: \(name)") {
            let candidates = try elements(application).filter {
                try matches($0, role: kAXCheckBoxRole, name: name)
            }
            return candidates.count == 1 ? candidates[0] : nil
        }
        let expected = enabled ? 1 : 0
        try require(try AXClient.integer(kAXValueAttribute as CFString, of: control) == 1 - expected,
                    "Switch did not start in its independently expected state: \(name)")
        try press(control)
        let _: Bool = try wait("Switch did not change to its requested state: \(name)") {
            try AXClient.integer(kAXValueAttribute as CFString, of: control) == expected ? true : nil
        }
    }

    static func click(_ element: AXUIElement) throws {
        try FinderPointer.click(at: FinderPointer.location(of: element))
        runLoopSlice(0.1)
    }

    static func key(_ code: CGKeyCode, flags: CGEventFlags = []) throws {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
            throw AutomationFailure.keyboardEventUnavailable
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        runLoopSlice(0.1)
    }

    static func paste(_ value: String) throws {
        NSPasteboard.general.clearContents()
        try require(NSPasteboard.general.setString(value, forType: .string), "Fixture clipboard write failed")
        try key(CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
    }

    static func edit(_ field: AXUIElement, in application: AXUIElement, value: String,
                     commitKey: CGKeyCode = CGKeyCode(kVK_Return)) throws {
        try click(field)
        let _: Bool = try wait("Click did not focus the actual text field", seconds: 2) {
            guard let focused = try AXClient.element(kAXFocusedUIElementAttribute as CFString, of: application) else { return nil }
            if AXClient.same(focused, field) { return true }
            let expected = try AXClient.string(kAXIdentifierAttribute as CFString, of: field)
            let actual = try AXClient.string(kAXIdentifierAttribute as CFString, of: focused)
            return expected != nil && expected == actual ? true : nil
        }
        try key(CGKeyCode(kVK_ANSI_A), flags: .maskCommand)
        try paste(value)
        let _: Bool = try wait("Text field did not receive the complete proposed edit") {
            try AXClient.string(kAXValueAttribute as CFString, of: field) == value ? true : nil
        }
        try key(commitKey)
    }

    static func chooseFile(_ url: URL, in app: AXUIElement, confirming title: String) throws {
        let panel = try find(app, role: kAXSheetRole, identifier: "open-panel")
        try key(CGKeyCode(kVK_ANSI_G), flags: [.maskCommand, .maskShift])
        // Go to Folder 的字段由系统建立焦点；粘贴经过真实键盘事件提交。
        let _: AXUIElement = try wait("Native Go to Folder field did not focus") {
            guard let field = try AXClient.element(kAXFocusedUIElementAttribute as CFString, of: app),
                  try AXClient.string(kAXRoleAttribute as CFString, of: field) == kAXTextFieldRole else { return nil }
            return field
        }
        try key(CGKeyCode(kVK_ANSI_A), flags: .maskCommand)
        try paste(url.path)
        try key(CGKeyCode(kVK_Return))
        try press(find(panel, role: kAXButtonRole, name: title))
    }

    static func drag(_ source: AXUIElement, before target: AXUIElement, evidence: URL) async throws {
        let start = try FinderPointer.location(of: source)
        var row = target
        while try AXClient.string(kAXRoleAttribute as CFString, of: row) != kAXRowRole {
            guard let parent = try AXClient.element(kAXParentAttribute as CFString, of: row) else {
                throw Failure.assertion("Drag target does not belong to a settings row")
            }
            row = parent
        }
        let targetFrame = try AXClient.frame(of: row)
        let finish = CGPoint(x: start.x, y: targetFrame.minY + 2)
        guard let eventSource = CGEventSource(stateID: .hidSystemState) else { throw AutomationFailure.pointerEventUnavailable }
        eventSource.localEventsSuppressionInterval = 0
        var pid: pid_t = 0
        try require(AXUIElementGetPid(source, &pid) == .success, "Drag source has no application owner")
        func event(_ type: CGEventType, _ point: CGPoint) throws {
            guard let event = CGEvent(mouseEventSource: eventSource, mouseType: type,
                                      mouseCursorPosition: point, mouseButton: .left) else {
                throw AutomationFailure.pointerEventUnavailable
            }
            event.flags = []
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.setDoubleValueField(.mouseEventPressure, value: type == .leftMouseDown || type == .leftMouseDragged ? 1 : 0)
            event.post(tap: .cghidEventTap)
        }
        try event(.mouseMoved, start)
        try event(.leftMouseDown, start)
        do {
            runLoopSlice(0.15)
            for frame in 1...40 {
                let fraction = CGFloat(frame) / 40
                try event(.leftMouseDragged, CGPoint(x: start.x + (finish.x - start.x) * fraction,
                                                    y: start.y + (finish.y - start.y) * fraction))
                runLoopSlice(0.02)
            }
            runLoopSlice(0.3)
            try await screenshot(pid: pid, to: evidence)
            try event(.leftMouseUp, finish)
        } catch {
            try? event(.leftMouseUp, finish)
            throw error
        }
        runLoopSlice(0.2)
    }

    static func screenshot(pid: pid_t, to url: URL) async throws {
        let content = try await SCShareableContent.current
        guard let window = content.windows.first(where: {
            $0.owningApplication?.processID == pid && $0.isOnScreen && $0.windowLayer == 0
        }) else { throw Failure.assertion("No visible product window for screenshot") }
        let configuration = SCScreenshotConfiguration()
        configuration.showsCursor = false
        configuration.dynamicRange = .sdr
        let output = try await SCScreenshotManager.captureScreenshot(
            contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration
        )
        guard let image = output.sdrImage,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.assertion("Could not create product screenshot")
        }
        CGImageDestinationAddImage(destination, image, nil)
        try require(CGImageDestinationFinalize(destination), "Could not save product screenshot")
    }

    static func dump(_ root: AXUIElement, to url: URL) throws {
        let lines = try elements(root).map { element in
            [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute, kAXValueAttribute]
                .map { attribute in
                    do {
                        if attribute == kAXValueAttribute {
                            guard let value = try AXClient.value(attribute as CFString, of: element, optional: true) else { return "" }
                            if let text = value as? String { return text }
                            if let number = value as? NSNumber { return number.stringValue }
                            return "<non-scalar value>"
                        }
                        return try AXClient.string(attribute as CFString, of: element) ?? ""
                    }
                    catch { return "<read failed: \(error)>" }
                }.map { $0.replacingOccurrences(of: "\t", with: "\\t").replacingOccurrences(of: "\n", with: "\\n") }
                .joined(separator: "\t")
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
