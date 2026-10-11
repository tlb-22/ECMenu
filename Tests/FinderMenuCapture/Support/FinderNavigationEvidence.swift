/**
 保存 Finder 目录定位失败时的窗口身份和 AX 树，供虚拟机验收日志检查。
 属性读取失败保留为诊断事实；证据采集不替代原始失败或改变界面。
 */

import AppKit
import ApplicationServices
import Foundation

@MainActor
enum FinderNavigationEvidence {
    enum Stage: String, Encodable { case contextTimeout, focusChanged, selectionHitMismatch }

    private struct Element: Encodable {
        let role: String
        let title: String
        let identifier: String
        let url: String
        let value: String
        let actions: String
        let selectionSettable: String
        let frame: String
        let ancestors: String
    }

    private struct Report: Encodable {
        let stage: Stage
        let directory: String
        let expectedURLs: [String]
        let ownedWindow: Element
        let focusedWindow: Element?
        let windows: [Element]
        let elements: [Element]
        let hit: Element?
        let itemScope: Element?
        let menuTarget: Element?
    }

    static func record(stage: Stage, window: AXUIElement, application: AXUIElement,
                       context: FinderMenuContext, hit: AXUIElement? = nil,
                       itemScope: AXUIElement? = nil, menuTarget: AXUIElement? = nil) {
        do {
            let focused = try AXClient.element(kAXFocusedWindowAttribute as CFString, of: application)
            let windows = try AXClient.elements(kAXWindowsAttribute as CFString, of: application)
            let paths = try AXTree.paths(below: window)
            let report = Report(stage: stage, directory: context.directory.path,
                expectedURLs: context.representedURLs.map(\.path), ownedWindow: element(window),
                focusedWindow: focused.map { element($0) }, windows: windows.map { element($0) },
                elements: paths.map { element($0.element, ancestors: $0.ancestors) },
                hit: hit.map { element($0) }, itemScope: itemScope.map { element($0) },
                menuTarget: menuTarget.map { element($0) })
            let data = try JSONEncoder().encode(report)
            FileHandle.standardOutput.write(Data("NAVIGATION_FAILURE\t\(data.base64EncodedString())\n".utf8))
        } catch {
            FileHandle.standardOutput.write(Data("NAVIGATION_DIAGNOSTIC_ERROR\t\(error)\n".utf8))
        }
    }

    private static func read(_ operation: () throws -> String) -> String {
        do { return try operation() }
        catch { return "<read failed: \(error)>" }
    }

    private static func element(_ source: AXUIElement, ancestors: [AXUIElement] = []) -> Element {
        Element(
            role: read { try AXClient.string(kAXRoleAttribute as CFString, of: source) ?? "" },
            title: read { try AXClient.string(kAXTitleAttribute as CFString, of: source) ?? "" },
            identifier: read { try AXClient.string(kAXIdentifierAttribute as CFString, of: source) ?? "" },
            url: read { try AXClient.url(of: source)?.path ?? "" },
            value: read { try AXClient.string(kAXValueAttribute as CFString, of: source) ?? "" },
            actions: read { try AXClient.actionNames(of: source).joined(separator: ",") },
            selectionSettable: read { String(try AXClient.isSettable(kAXSelectedChildrenAttribute as CFString, on: source)) },
            frame: read { NSStringFromRect(try AXClient.frame(of: source)) },
            ancestors: read { try ancestors.map {
                try AXClient.string(kAXRoleAttribute as CFString, of: $0) ?? ""
            }.joined(separator: "/") }
        )
    }
}
