/**
 解析窗口捕获的有效编号与新的 PNG 输出路径，供已授权的桌面驱动使用。
 输出路径校验由模板权限准备共用；窗口可见事实由 ScreenCaptureKit 验证。
 */

import CoreGraphics
import Foundation

struct WindowImageInput {
    let number: CGWindowID
    let outputURL: URL

    static func parse(_ arguments: [String]) throws -> Self {
        guard arguments.count == 3, let number = CGWindowID(arguments[1]), number > 0 else {
            throw AutomationFailure.usage
        }
        return Self(number: number, outputURL: try outputURL(path: arguments[2]))
    }

    static func outputURL(path: String) throws -> URL {
        guard path.hasPrefix("/") else { throw AutomationFailure.pathMustBeAbsolute(path) }
        let output = URL(fileURLWithPath: path).standardizedFileURL
        guard output.pathExtension.lowercased() == "png" else { throw AutomationFailure.outputMustBePNG(path) }
        var isDirectory = ObjCBool(false)
        let parent = output.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AutomationFailure.outputDirectoryDoesNotExist(parent.path)
        }
        guard !FileManager.default.fileExists(atPath: output.path) else { throw AutomationFailure.outputAlreadyExists(output.path) }
        return output
    }
}
