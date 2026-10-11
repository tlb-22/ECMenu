/**
 在 Finder 回调边界读取瞬时目标与选择字段，结合菜单类型一次性映射为合法语义快照。
 平台枚举映射与纯字段解释集中在此，能力消费快照而不重新推断 Finder 的事件来源。
 */

import Foundation
import FinderSync

/// 集中读取并解释 FinderSync 的瞬时菜单状态。
enum FinderContextReader {
    /// 在 Finder 菜单构建边界把原始目标字段解释为语义快照。
    ///
    /// container 回调可能把当前可见目录放入 `selectedItemURLs`，同时让
    /// `targetedURL` 停留在残余选中项，因此这里选择前者的第一项并以后者
    /// 回退。该框架差异不会继续暴露给具体 Feature 或主应用 Handler。
    /// - Parameter context: Finder 正在构建的菜单种类。
    /// - Returns: 完整语义所需路径存在时返回快照，否则返回 `nil`。
    static func snapshot(for context: FinderMenuContext) -> FinderContextSnapshot? {
        let finder = FIFinderSyncController.default()
        let targetedURL = finder.targetedURL()
        let selectedURLs = finder.selectedItemURLs() ?? []

        return snapshot(
            for: context,
            targetedURL: targetedURL,
            selectedURLs: selectedURLs
        )
    }

    /// 纯粹解释一次已经读取的 Finder 原始状态。
    /// - Parameters:
    ///   - context: Finder 原始菜单种类映射后的值。
    ///   - targetedURL: `FIFinderSyncController.targetedURL()` 的返回值。
    ///   - selectedURLs: `selectedItemURLs()` 的返回值或空数组。
    /// - Returns: 不含无效字段组合的语义快照。
    nonisolated private static func snapshot(
        for context: FinderMenuContext,
        targetedURL: URL?,
        selectedURLs: [URL]
    ) -> FinderContextSnapshot? {
        switch context {
        case .container:
            guard
                let directoryURL = selectedURLs.first ?? targetedURL,
                let path = AbsoluteFilePath(url: directoryURL)
            else {
                return nil
            }
            return .container(path: path)

        case .items:
            guard let selection = FinderItemSelection(urls: selectedURLs) else {
                return nil
            }
            return .items(selection: selection)

        case .sidebar:
            guard
                let directoryURL = targetedURL,
                let path = AbsoluteFilePath(url: directoryURL)
            else {
                return nil
            }
            return .sidebar(path: path)
        }
    }
}

// MARK: - ==================== 纯函数：Finder 上下文映射 ====================

/// 定义 Finder 框架菜单类型到 Extension 内部语义上下文的边界映射。
extension FinderMenuContext {
    /// 把 Finder 框架菜单类型映射为 Extension 菜单求值使用的上下文类型。
    /// - Parameter menuKind: Finder 原始菜单类型。
    init?(_ menuKind: FIMenuKind) {
        switch menuKind {
        case .contextualMenuForContainer:
            self = .container
        case .contextualMenuForItems:
            self = .items
        case .contextualMenuForSidebar:
            self = .sidebar
        default:
            return nil
        }
    }
}
