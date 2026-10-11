/**
 验证通过真实 Finder 模板菜单创建文件的完整结果，拥有模板参数与输出文件的验收条件。
 复用通用菜单会话完成截图和点击，等到生成文件字节符合独立输入且被 Finder 选中后才允许清理窗口。
 */

import Foundation

struct NewFileMenuAcceptance {
    let input: FinderMenuCaptureInput
    let parentTitle: String
    let templateTitle: String
    let expectedFileURL: URL
    let expectedContent: Data

    static func parse(_ arguments: [String]) throws -> Self {
        guard arguments.count == 7, arguments[6].hasPrefix("/"),
              !arguments[3].isEmpty, !arguments[4].isEmpty, !arguments[5].isEmpty,
              !arguments[5].contains("/"), arguments[5] != ".", arguments[5] != ".." else {
            throw AutomationFailure.usage
        }
        let input = try FinderMenuCaptureInput.container(
            outputPath: arguments[1], directoryPath: arguments[2]
        )
        let expectedFileURL = input.context.directory.appendingPathComponent(arguments[5])
        guard !FileManager.default.fileExists(atPath: expectedFileURL.path) else {
            throw Failure.alreadyExists(expectedFileURL.path)
        }
        return Self(
            input: input, parentTitle: arguments[3], templateTitle: arguments[4],
            expectedFileURL: expectedFileURL,
            expectedContent: try Data(contentsOf: URL(fileURLWithPath: arguments[6]))
        )
    }

    @MainActor
    func run(in session: FinderMenuSession) async throws -> MenuSnapshot {
        let submenu = try await session.prepareSubmenu(parentTitle: parentTitle)
        try await MenuScreenshot.capture(submenu.snapshot, to: input.outputURL)
        try session.pressItem(named: templateTitle, in: submenu)
        try waitForCreatedFileSelection(in: session)
        return submenu.snapshot
    }

    @MainActor
    private func waitForCreatedFileSelection(in session: FinderMenuSession) throws {
        let deadline = Date().addingTimeInterval(AutomationTiming.target)
        var fileWasCreated = false
        var contentMatched = false
        repeat {
            var isDirectory: ObjCBool = false
            fileWasCreated = FileManager.default.fileExists(
                atPath: expectedFileURL.path, isDirectory: &isDirectory
            ) && !isDirectory.boolValue
            if fileWasCreated {
                contentMatched = try Data(contentsOf: expectedFileURL) == expectedContent
                do {
                    if contentMatched, try session.isSoleSelectedItem(expectedFileURL) { return }
                } catch AutomationFailure.accessibility(.readAttribute, .failure),
                        AutomationFailure.accessibility(.readAttribute, .invalidUIElement),
                        AutomationFailure.accessibility(.readAttribute, .cannotComplete) {
                    // 仅在结果选择的有界等待内重读更新中的 AX 树。
                }
            }
            runLoopSlice(AutomationTiming.poll)
        } while Date() < deadline
        if fileWasCreated {
            if !contentMatched { throw Failure.contentMismatch(expectedFileURL.path) }
            throw AutomationFailure.finderSelectionTimeout
        }
        throw Failure.creationTimedOut(expectedFileURL.path)
    }

    enum Failure: Error {
        case alreadyExists(String)
        case creationTimedOut(String)
        case contentMismatch(String)

        var code: String {
            switch self {
            case .alreadyExists: "created-file-already-exists"
            case .creationTimedOut: "created-file-timeout"
            case .contentMismatch: "created-file-content-mismatch"
            }
        }

        var message: String {
            switch self {
            case let .alreadyExists(path): "The expected created file already exists: \(path)"
            case let .creationTimedOut(path): "The template command did not create the expected ordinary file: \(path)"
            case let .contentMismatch(path): "The created file differs from the independent expected content: \(path)"
            }
        }
    }
}
