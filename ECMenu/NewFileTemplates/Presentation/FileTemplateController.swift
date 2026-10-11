/**
 持有模板管理页的加载状态与当前清单，并把用户操作交给模板应用入口。
 先应用已经提交的清单，再按操作约定向界面报告清理问题。
 */

import Combine
import Foundation

/// 模板管理界面的已提交快照与更新占用；持久化和发布由应用操作负责。
@MainActor
final class FileTemplateController: ObservableObject {
    @Published private(set) var state = FileTemplatePageState.loading
    @Published private(set) var isUpdating = false

    private let operations: FileTemplateOperations
    private var initialLoad: Task<Void, Never>?

    var templates: [FileTemplate]? { state.templates }

    init(operations: FileTemplateOperations) {
        self.operations = operations
    }

    /// 启动与页面入口共享同一次初始化，不会补回用户已经删除的模板。
    func loadIfNeeded() async {
        if let initialLoad {
            await initialLoad.value
            return
        }
        let task = Task { await reload() }
        initialLoad = task
        await task.value
    }

    /// 读取失败后允许用户明确重试；错误保留为页面状态。
    func reload() async {
        state = .loading
        do {
            state = .ready(try await operations.loadForManagement())
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func importFile(at url: URL) async throws {
        _ = try await perform { try await self.operations.importFile(at: url) }
    }

    func updateName(for id: FileTemplateID, field: FileTemplateNameField, value: String) async throws {
        _ = try await perform {
            try await self.operations.updateName(for: id, field: field, value: value)
        }
    }

    /// 拖放结束后提交最终位置；无变化不替换页面快照，写入失败保持原顺序。
    func moveTemplate(id: FileTemplateID, before destinationID: FileTemplateID?) async throws {
        precondition(!isUpdating && templates != nil)
        isUpdating = true
        defer { isUpdating = false }

        if let result = try await operations.moveTemplate(id: id, before: destinationID) {
            state = .ready(result.templates)
        }
    }

    func openTemplate(id: FileTemplateID) async throws {
        try await operations.openTemplate(id: id)
    }

    func replaceTemplate(id: FileTemplateID, at url: URL) async throws {
        _ = try await perform { try await self.operations.replaceTemplate(id: id, at: url) }
    }

    func removeTemplate(id: FileTemplateID) async throws {
        let result = try await perform { try await self.operations.removeTemplate(id: id) }
        if case .committedWithCleanupIssue(_, let issue) = result {
            throw issue.failure
        }
    }

    /// 只应用明确的已提交快照；提交前失败保持现有控件和草稿，不进入 loading 或重新发布。
    private func perform(
        _ operation: () async throws -> FileTemplateCommit
    ) async throws -> FileTemplateCommit {
        precondition(!isUpdating && templates != nil)
        isUpdating = true
        defer { isUpdating = false }

        let result = try await operation()
        state = .ready(result.templates)
        return result
    }
}
