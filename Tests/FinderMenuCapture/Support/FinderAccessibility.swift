/**
 封装 Finder 菜单自动化使用的 Accessibility 属性、动作、树遍历和通知等待。
 将系统返回值转换为明确事实或自动化失败，并提供主循环驱动的等待边界。
 */

import ApplicationServices
import CoreGraphics
import Foundation

enum AXClient {
    static func value(
        _ attribute: CFString,
        of element: AXUIElement,
        optional: Bool = false
    ) throws -> CFTypeRef? {
        var result: CFTypeRef?
        let deadline = Date().addingTimeInterval(AutomationTiming.accessibilityRetry)
        var error: AXError
        repeat {
            result = nil
            error = AXUIElementCopyAttributeValue(element, attribute, &result)
            if error != .cannotComplete { break }
            runLoopSlice(AutomationTiming.poll)
        } while Date() < deadline
        switch error {
        case .success:
            return result
        case .attributeUnsupported where optional,
             .noValue where optional:
            return nil
        default:
            throw AutomationFailure.accessibility(.readAttribute, error)
        }
    }

    static func element(_ attribute: CFString, of element: AXUIElement) throws -> AXUIElement? {
        guard let value = try value(attribute, of: element, optional: true) else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw AutomationFailure.invalidAccessibilityValue(attribute as String)
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    static func elements(_ attribute: CFString, of element: AXUIElement) throws -> [AXUIElement] {
        guard let value = try value(attribute, of: element, optional: true) else { return [] }
        guard let elements = value as? [AXUIElement] else {
            throw AutomationFailure.invalidAccessibilityValue(attribute as String)
        }
        return elements
    }

    static func string(_ attribute: CFString, of element: AXUIElement) throws -> String? {
        guard let value = try value(attribute, of: element, optional: true) else { return nil }
        guard let string = value as? String else {
            throw AutomationFailure.invalidAccessibilityValue(attribute as String)
        }
        return string
    }

    static func bool(_ attribute: CFString, of element: AXUIElement) throws -> Bool? {
        guard let value = try value(attribute, of: element, optional: true) else { return nil }
        guard let bool = value as? Bool else {
            throw AutomationFailure.invalidAccessibilityValue(attribute as String)
        }
        return bool
    }

    static func integer(_ attribute: CFString, of element: AXUIElement) throws -> Int? {
        guard let value = try value(attribute, of: element, optional: true) else { return nil }
        guard let number = value as? NSNumber else {
            throw AutomationFailure.invalidAccessibilityValue(attribute as String)
        }
        return number.intValue
    }

    static func fileURL(
        _ attribute: CFString,
        of element: AXUIElement
    ) throws -> URL? {
        guard let value = try value(attribute, of: element, optional: true) else {
            return nil
        }
        if let url = value as? URL {
            return url.isFileURL ? url.standardizedFileURL : nil
        }
        if let string = value as? String {
            if string.hasPrefix("/") {
                return URL(fileURLWithPath: string).standardizedFileURL
            }
            guard let url = URL(string: string) else {
                throw AutomationFailure.invalidAccessibilityValue(attribute as String)
            }
            return url.isFileURL ? url.standardizedFileURL : nil
        }
        throw AutomationFailure.invalidAccessibilityValue(attribute as String)
    }

    static func url(of element: AXUIElement) throws -> URL? {
        try fileURL(kAXURLAttribute as CFString, of: element)
    }

    static func frame(of element: AXUIElement) throws -> CGRect {
        let positionAttribute = kAXPositionAttribute as CFString
        guard let rawPosition = try value(positionAttribute, of: element),
              CFGetTypeID(rawPosition) == AXValueGetTypeID() else {
            throw AutomationFailure.invalidAccessibilityValue(positionAttribute as String)
        }
        let positionValue = unsafeBitCast(rawPosition, to: AXValue.self)
        var position = CGPoint.zero
        guard AXValueGetType(positionValue) == .cgPoint,
              AXValueGetValue(positionValue, .cgPoint, &position) else {
            throw AutomationFailure.invalidAccessibilityValue(positionAttribute as String)
        }

        let sizeAttribute = kAXSizeAttribute as CFString
        guard let rawSize = try value(sizeAttribute, of: element),
              CFGetTypeID(rawSize) == AXValueGetTypeID() else {
            throw AutomationFailure.invalidAccessibilityValue(sizeAttribute as String)
        }
        let sizeValue = unsafeBitCast(rawSize, to: AXValue.self)
        var size = CGSize.zero
        guard AXValueGetType(sizeValue) == .cgSize,
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            throw AutomationFailure.invalidAccessibilityValue(sizeAttribute as String)
        }
        return CGRect(origin: position, size: size)
    }

    static func element(at point: CGPoint, in scope: AXUIElement) throws -> AXUIElement {
        var result: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(
            scope,
            Float(point.x),
            Float(point.y),
            &result
        )
        guard error == .success, let result else {
            throw AutomationFailure.accessibility(.hitTest, error)
        }
        return result
    }

    static func actionNames(of element: AXUIElement) throws -> [String] {
        var result: CFArray?
        let deadline = Date().addingTimeInterval(AutomationTiming.accessibilityRetry)
        var error: AXError
        repeat {
            result = nil
            error = AXUIElementCopyActionNames(element, &result)
            if error != .cannotComplete { break }
            runLoopSlice(AutomationTiming.poll)
        } while Date() < deadline
        guard error == .success else {
            throw AutomationFailure.accessibility(.readActions, error)
        }
        guard let result else { return [] }
        guard let names = result as? [String] else {
            throw AutomationFailure.invalidAccessibilityValue("AXActionNames")
        }
        return names
    }

    static func setValue(
        _ value: CFTypeRef,
        for attribute: CFString,
        on element: AXUIElement
    ) throws {
        let error = AXUIElementSetAttributeValue(element, attribute, value)
        guard error == .success else {
            throw AutomationFailure.accessibility(.writeAttribute, error)
        }
    }

    static func isSettable(
        _ attribute: CFString,
        on element: AXUIElement
    ) throws -> Bool {
        var result = DarwinBoolean(false)
        let deadline = Date().addingTimeInterval(AutomationTiming.accessibilityRetry)
        var error: AXError
        repeat {
            result = false
            error = AXUIElementIsAttributeSettable(element, attribute, &result)
            if error != .cannotComplete { break }
            runLoopSlice(AutomationTiming.poll)
        } while Date() < deadline
        switch error {
        case .success:
            return result.boolValue
        case .attributeUnsupported, .noValue:
            return false
        default:
            throw AutomationFailure.accessibility(.readAttribute, error)
        }
    }

    static func supports(_ action: CFString, on element: AXUIElement) throws -> Bool {
        try actionNames(of: element).contains(action as String)
    }

    /// `cannotComplete` 不证明动作失败；调用方继续观察动作产生的 UI 事实。
    static func perform(_ action: CFString, on element: AXUIElement) throws {
        let error = AXUIElementPerformAction(element, action)
        guard error == .success || error == .cannotComplete else {
            throw AutomationFailure.accessibility(.performAction, error)
        }
    }

    static func same(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        CFEqual(lhs, rhs)
    }

}

struct AXPath {
    let element: AXUIElement
    /// 从直接父元素依次到根元素。
    let ancestors: [AXUIElement]

    var elementAndAncestors: [AXUIElement] { [element] + ancestors }
}

enum AXTree {
    static func paths(below root: AXUIElement) throws -> [AXPath] {
        var paths: [AXPath] = []
        var pending = try AXClient.elements(kAXChildrenAttribute as CFString, of: root)
            .reversed()
            .map { (element: $0, ancestors: [root]) }

        while let node = pending.popLast() {
            let children: [AXUIElement]
            do {
                children = try AXClient.elements(kAXChildrenAttribute as CFString, of: node.element)
            } catch AutomationFailure.accessibility(.readAttribute, .invalidUIElement) {
                // 树枚举期间销毁的节点已经不属于当前界面，继续读取其他仍存活的分支。
                continue
            }
            paths.append(AXPath(element: node.element, ancestors: node.ancestors))
            let ancestors = [node.element] + node.ancestors
            pending.append(contentsOf: children.reversed().map {
                (element: $0, ancestors: ancestors)
            })
        }
        return paths
    }
}

private func elementNotificationCallback(
    _: AXObserver,
    element: AXUIElement,
    notification: CFString,
    context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    Unmanaged<AXElementNotificationWaiter>
        .fromOpaque(context)
        .takeUnretainedValue()
        .receive(element, notification: notification)
}

final class AXElementNotificationWaiter {
    private let application: AXUIElement
    private let notification: CFString
    private var observer: AXObserver?
    private var receivedElements: [AXUIElement] = []

    init(
        processIdentifier: pid_t,
        application: AXUIElement,
        notification: CFString
    ) throws {
        self.application = application
        self.notification = notification

        var observer: AXObserver?
        let creation = AXObserverCreate(
            processIdentifier,
            elementNotificationCallback,
            &observer
        )
        guard creation == .success, let observer else {
            throw AutomationFailure.accessibility(.createObserver, creation)
        }
        self.observer = observer

        var registration: AXError
        var registrationAttempt = 0
        repeat {
            registrationAttempt += 1
            registration = AXObserverAddNotification(
                observer,
                application,
                notification,
                Unmanaged.passUnretained(self).toOpaque()
            )
            if registration != .cannotComplete { break }
            runLoopSlice(AutomationTiming.poll)
        } while registrationAttempt < AutomationTiming.accessibilityRetryAttempts
        let registered = registration == .success
            || (registrationAttempt > 1
                && registration == .notificationAlreadyRegistered)
        guard registered else {
            self.observer = nil
            throw AutomationFailure.accessibility(
                .registerNotification,
                registration
            )
        }
        CFRunLoopAddSource(
            CFRunLoopGetCurrent(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )
    }

    deinit {
        guard let observer else { return }
        AXObserverRemoveNotification(
            observer,
            application,
            notification
        )
        CFRunLoopRemoveSource(
            CFRunLoopGetCurrent(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )
    }

    func receive(_ element: AXUIElement, notification: CFString) {
        guard notification as String == self.notification as String else { return }
        receivedElements.append(element)
    }

    func wait<Value>(
        timeout: TimeInterval,
        resolve: ([AXUIElement]) throws -> Value?
    ) throws -> Value? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let elements = receivedElements
            if let value = try resolve(elements),
               elements.count == receivedElements.count {
                return value
            }
            guard Date() < deadline else { return nil }
            runLoopSlice(AutomationTiming.poll)
        } while true
    }
}

func runLoopSlice(_ duration: TimeInterval) {
    CFRunLoopRunInMode(.defaultMode, duration, true)
}
