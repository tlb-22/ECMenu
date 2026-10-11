/**
 解析并验证菜单捕获共用的输出路径与 Finder 选择输入。
 文件系统查询只用于建立本轮 fixture 前置条件，不承担具体命令的执行验收。
 */

import Foundation

struct FinderMenuCaptureInput {
    let context: FinderMenuContext
    let outputURL: URL

    static func container(outputPath: String, directoryPath: String) throws -> Self {
        let output = try outputURL(outputPath)
        let directory = try fileURL(directoryPath)
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw AutomationFailure.directoryDoesNotExist(directory.path)
        }
        let openingItems = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let openingItem = openingItems.first else {
            throw AutomationFailure.containerIsEmpty(directory.path)
        }
        return Self(
            context: .container(directory: directory, openingItem: openingItem),
            outputURL: output
        )
    }

    static func items(outputPath: String, firstPath: String, remainingPaths: [String]) throws -> Self {
        let output = try outputURL(outputPath)
        let urls = try ([firstPath] + remainingPaths).map(fileURL)
        for url in urls where !FileManager.default.fileExists(atPath: url.path) {
            throw AutomationFailure.itemDoesNotExist(url.path)
        }
        return Self(
            context: .items(try ItemSelection(first: urls[0], remaining: Array(urls.dropFirst()))),
            outputURL: output
        )
    }

    private static func fileURL(_ path: String) throws -> URL {
        guard path.hasPrefix("/") else { throw AutomationFailure.pathMustBeAbsolute(path) }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private static func outputURL(_ path: String) throws -> URL {
        let output = try fileURL(path)
        guard output.pathExtension.lowercased() == "png" else {
            throw AutomationFailure.outputMustBePNG(path)
        }
        var isDirectory = ObjCBool(false)
        let parent = output.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw AutomationFailure.outputDirectoryDoesNotExist(parent.path)
        }
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw AutomationFailure.outputAlreadyExists(output.path)
        }
        return output
    }
}
