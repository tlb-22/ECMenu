/**
 作为模板能力的应用入口，统一协调读取、管理页加载、变更提交与菜单更新发布。
 根据加载来源和提交事实决定通知时机，并按操作语义处理提交后的清理问题。
 */

import Foundation
import OSLog

/// 模板能力的应用入口；协调已提交事实与发布，不另存一份模板索引。
@MainActor
final class FileTemplateOperations {
    private let library: FileTemplateLibrary
    private let openFile: @MainActor (URL) throws -> Void
    private let didChange: ([FileTemplate]) -> Void
    private static let logger = Logger(subsystem: ApplicationLogging.subsystem, category: "NewFileTemplates")

    init(
        library: FileTemplateLibrary,
        openFile: @escaping @MainActor (URL) throws -> Void = FileTemplateOpener.open,
        didChange: @escaping ([FileTemplate]) -> Void
    ) {
        self.library = library
        self.openFile = openFile
        self.didChange = didChange
    }

    /// 普通查询只在本次读取确实提交了初始化时发布，缓存查询不会形成通知循环。
    func load() async throws -> [FileTemplate] {
        let result = try await library.load()
        switch result.origin {
        case .initialized:
            didChange(result.templates)
        case .cached, .restored:
            break
        }
        return result.templates
    }

    /// 管理页加载和显式重试成功都重新确认可用性；初始化提交合并在同一次提示中。
    func loadForManagement() async throws -> [FileTemplate] {
        let result = try await library.load()
        didChange(result.templates)
        return result.templates
    }

    func content(for id: FileTemplateID) async throws -> FileTemplateContent {
        _ = try await load()
        return try await library.content(for: id)
    }

    func fileURL(for id: FileTemplateID) async throws -> URL {
        _ = try await load()
        return try await library.fileURL(for: id)
    }

    func openTemplate(id: FileTemplateID) async throws {
        try openFile(try await fileURL(for: id))
    }

    func importFile(at url: URL) async throws -> FileTemplateCommit {
        try await perform { try await self.library.importFile(at: url) }
    }

    func updateName(
        for id: FileTemplateID,
        field: FileTemplateNameField,
        value: String
    ) async throws -> FileTemplateCommit {
        try await perform {
            try await self.library.updateName(for: id, field: field, value: value)
        }
    }

    /// 一次排序只在顺序实际提交后发布；不变的插入位置不产生提交或提示。
    func moveTemplate(id: FileTemplateID, before destinationID: FileTemplateID?) async throws -> FileTemplateCommit? {
        _ = try await load()
        let result = try await library.move(id: id, before: destinationID)
        if let result { didChange(result.templates) }
        return result
    }

    func replaceTemplate(id: FileTemplateID, at url: URL) async throws -> FileTemplateCommit {
        let result = try await perform { try await self.library.replaceFile(for: id, at: url) }
        if case .committedWithCleanupIssue(_, let issue) = result {
            Self.logger.error("Could not clean unused template files: \(issue.localizedDescription, privacy: .public)")
        }
        return result
    }

    func removeTemplate(id: FileTemplateID) async throws -> FileTemplateCommit {
        try await perform { try await self.library.remove(id: id) }
    }

    private func perform(
        _ operation: () async throws -> FileTemplateCommit
    ) async throws -> FileTemplateCommit {
        _ = try await load()
        let result = try await operation()
        didChange(result.templates)
        return result
    }
}
