/**
 提供 Finder 自动化的元素定位、单击、右键和指针悬停操作。
 根据 Accessibility 几何信息生成 CoreGraphics 指针事件，并报告不可用的事件边界。
 */

import ApplicationServices
import CoreGraphics

enum FinderPointer {
    static func location(of element: AXUIElement) throws -> CGPoint {
        let frame = try AXClient.frame(of: element)
        guard frame.width > 0, frame.height > 0 else {
            throw AutomationFailure.pointerEventUnavailable
        }
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    static func click(at location: CGPoint, flags: CGEventFlags = []) throws {
        guard let mouseDown = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: location,
            mouseButton: .left
        ), let mouseUp = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: location,
            mouseButton: .left
        ) else {
            throw AutomationFailure.pointerEventUnavailable
        }
        mouseDown.flags = flags
        mouseUp.flags = flags
        mouseDown.setIntegerValueField(.mouseEventClickState, value: 1)
        mouseUp.setIntegerValueField(.mouseEventClickState, value: 1)
        mouseDown.post(tap: .cghidEventTap)
        runLoopSlice(0.05)
        mouseUp.post(tap: .cghidEventTap)
    }

    static func rightClick(at location: CGPoint) throws {
        guard let mouseDown = CGEvent(
            mouseEventSource: nil,
            mouseType: .rightMouseDown,
            mouseCursorPosition: location,
            mouseButton: .right
        ), let mouseUp = CGEvent(
            mouseEventSource: nil,
            mouseType: .rightMouseUp,
            mouseCursorPosition: location,
            mouseButton: .right
        ) else {
            throw AutomationFailure.pointerEventUnavailable
        }
        mouseDown.flags = []
        mouseUp.flags = []
        mouseDown.post(tap: .cghidEventTap)
        mouseUp.post(tap: .cghidEventTap)
    }

    static func move(to location: CGPoint) throws {
        guard let mouseMove = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: location,
            mouseButton: .left
        ) else {
            throw AutomationFailure.pointerEventUnavailable
        }
        mouseMove.flags = []
        mouseMove.post(tap: .cghidEventTap)
    }
}
