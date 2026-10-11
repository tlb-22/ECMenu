/**
 提供 Finder 自动化需要的回车和 Escape 键事件。
 把有限键语义转换为成对的 CoreGraphics 按下与松开事件。
 */

import Carbon.HIToolbox
import CoreGraphics

enum FinderKey {
    case returnKey
    case escape

    var virtualKey: CGKeyCode {
        switch self {
        case .returnKey: CGKeyCode(kVK_Return)
        case .escape: CGKeyCode(kVK_Escape)
        }
    }
}

enum FinderKeyboard {
    static func press(_ key: FinderKey) throws {
        guard let keyDown = CGEvent(
            keyboardEventSource: nil,
            virtualKey: key.virtualKey,
            keyDown: true
        ), let keyUp = CGEvent(
            keyboardEventSource: nil,
            virtualKey: key.virtualKey,
            keyDown: false
        ) else {
            throw AutomationFailure.keyboardEventUnavailable
        }
        keyDown.flags = []
        keyUp.flags = []
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
