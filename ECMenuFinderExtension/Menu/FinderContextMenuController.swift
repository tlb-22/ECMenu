/**
 协调本次 Finder 菜单的配置过滤、能力求值和 AppKit 渲染，并管理已冻结动作的唯一 tag。
 动作按菜单项实例保留和消费，历史记录有界淘汰；图像适配交给独立渲染器。
 */

import AppKit
import FinderSync
import Foundation

/// 解释声明式布局、渲染 Finder 菜单并把 action 路由到增量功能。
final class FinderContextMenuController {
    /// 跨请求保留旧 action 的数量预算；单个菜单超过预算时仍完整保留。
    private static let maximumRetainedActions = 256

    /// 每次菜单请求根据当前配置构造不可变声明，不跨请求缓存模板列表。
    private let makeMenu: () -> FinderContextMenuDefinition

    /// 查询产品当前是否应向 Finder 贡献任何右键菜单的纯边界。
    private let isMenuEnabled: () -> Bool

    /// 查询一个功能当前是否被产品配置显示的纯边界。
    private let isFeatureVisible: (ContextCommandFeatureID) -> Bool

    /// 查询 Launch Services 当前能否定位声明的固定应用。
    private let isApplicationAvailable: (
        ContextCommandApplicationRequirement
    ) -> Bool

    /// 各菜单实例唯一 action tag 对应的已准备调用。
    private var preparedActionsByTag: [Int: PreparedContextMenuAction] = [:]

    /// 按注册顺序保存尚未执行的 action tag，供有界淘汰使用。
    private var retainedActionTags: [Int] = []

    /// 下一个分配给具体菜单项的正整数 tag。
    private var nextActionTag = 1

    /// 图标适配器独占可重用的图像缓存。
    private let iconRenderer = FinderMenuIconRenderer()

    /// 使用菜单声明树和纯配置查询创建稳定运行时。
    /// - Parameters:
    ///   - makeMenu: 按本次配置构造菜单项、顺序、分组和层级。
    ///   - isFeatureVisible: 查询一个功能是否应出现在 Finder 菜单中。
    ///   - isMenuEnabled: 查询产品总开关是否允许贡献右键菜单。
    ///   - isApplicationAvailable: 查询一个固定应用依赖是否可用。
    init(
        makeMenu: @escaping () -> FinderContextMenuDefinition,
        isFeatureVisible: @escaping (ContextCommandFeatureID) -> Bool,
        isMenuEnabled: @escaping () -> Bool = { true },
        isApplicationAvailable: @escaping (
            ContextCommandApplicationRequirement
        ) -> Bool = { requirement in
            NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: requirement.bundleIdentifier
            ) != nil
        }
    ) {
        self.makeMenu = makeMenu
        self.isFeatureVisible = isFeatureVisible
        self.isMenuEnabled = isMenuEnabled
        self.isApplicationAvailable = isApplicationAvailable
    }

    /// 把 Extension 配置副本适配为 Controller 使用的纯查询边界。
    /// - Parameters:
    ///   - makeMenu: 按本次配置构造菜单项、顺序、分组和层级。
    ///   - configuration: Extension 持有的可见性配置副本。
    convenience init(
        makeMenu: @escaping () -> FinderContextMenuDefinition,
        configuration: CommandMenuSettingsReplica
    ) {
        self.init(
            makeMenu: makeMenu,
            isFeatureVisible: { [configuration] featureID in
                configuration.isVisible(featureID)
            },
            isMenuEnabled: { [configuration] in
                configuration.isEnabled
            }
        )
    }

    // MARK: - ==================== 副作用：渲染声明式菜单 ====================

    /// 把当前 Finder 上下文中的可见布局解释为 `NSMenu`。
    /// - Parameters:
    ///   - menuKind: Finder 原始菜单类型。
    ///   - action: `FinderSync` 主对象公开的通用 action。
    /// - Returns: 至少包含一个动作项时返回菜单，否则返回 `nil`。
    func menu(for menuKind: FIMenuKind, action: Selector) -> NSMenu? {
        guard isMenuEnabled() else {
            return nil
        }
        guard
            let context = FinderMenuContext(menuKind),
            let snapshot = FinderContextReader.snapshot(for: context)
        else {
            return nil
        }
        return menu(for: snapshot, action: action)
    }

    /// 使用 Finder 请求菜单时已经冻结的状态渲染菜单。
    ///
    /// 菜单可用性和随后发生的 action 共用这份值，避免 action 回调时
    /// Finder 的瞬时选择状态已经发生变化。
    /// - Parameters:
    ///   - snapshot: 当前菜单实例唯一对应的 Finder 快照。
    ///   - action: `FinderSync` 主对象公开的通用 action。
    /// - Returns: 至少包含一个动作项时返回菜单，否则返回 `nil`。
    func menu(
        for snapshot: FinderContextSnapshot,
        action: Selector
    ) -> NSMenu? {
        guard isMenuEnabled() else {
            return nil
        }
        let definition = makeMenu()
        let evaluationContext = FinderContextMenuEvaluationContext(
            snapshot: snapshot
        )
        let nodes: [ContextMenuNode<PreparedContextMenuAction>] =
            ContextMenuNodeResolver.compactMapItems(
                in: definition.nodes
            ) { [isFeatureVisible, isApplicationAvailable] action in
                let descriptor = action.descriptor
                guard isFeatureVisible(descriptor.id.featureID) else {
                    return nil
                }
                guard descriptor.requiredApplication.map(
                    isApplicationAvailable
                ) ?? true else {
                    return nil
                }
                return action.prepare(in: evaluationContext)
            }
        guard !nodes.isEmpty else {
            return nil
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        nodes.forEach {
            menu.addItem(
                menuItem(
                    from: $0,
                    action: action
                )
            )
        }
        discardOldActions(keepingAtLeast: nodes.flatMap(\.items).count)
        return menu
    }

    /// 递归把一个已经过滤和规范化的布局节点渲染为 AppKit 菜单项。
    private func menuItem(
        from node: ContextMenuNode<PreparedContextMenuAction>,
        action: Selector
    ) -> NSMenuItem {
        switch node {
        case .item(let preparedAction):
            let descriptor = preparedAction.descriptor
            let menuItem = NSMenuItem(
                title: descriptor.title.string,
                action: action,
                keyEquivalent: ""
            )
            menuItem.isEnabled = true
            menuItem.tag = retain(preparedAction)
            menuItem.image = descriptor.icon.flatMap { iconRenderer.image(for: $0) }
            return menuItem

        case .separator:
            return .separator()

        case .submenu(let title, let icon, let children):
            let localizedTitle = String(localized: title)
            let parent = NSMenuItem(
                title: localizedTitle,
                action: nil,
                keyEquivalent: ""
            )
            let submenu = NSMenu(title: localizedTitle)
            submenu.autoenablesItems = false
            children.forEach {
                submenu.addItem(
                    menuItem(from: $0, action: action)
                )
            }
            parent.submenu = submenu
            parent.image = icon.flatMap { iconRenderer.image(for: $0) }
            return parent
        }
    }

    // MARK: - ==================== 副作用：路由 Finder 动作 ====================

    /// 取出菜单项 tag 已经绑定的命令并直接投递。
    /// - Parameter menuItem: Finder 回传的菜单项。
    func perform(_ menuItem: NSMenuItem) {
        guard menuItem.isEnabled, menuItem.action != nil else {
            return
        }

        guard let preparedAction = consumePreparedAction(for: menuItem) else {
            NSSound.beep()
            return
        }

        preparedAction.perform()
    }

    /// 为一个具体菜单项分配唯一 tag，并保留已准备调用。
    ///
    /// Finder 可能在旧菜单 action 到达前请求另一种菜单。固定 Action tag
    /// 会让后一次请求覆盖前一个菜单的快照，因此 tag 必须属于菜单项实例。
    /// - Parameter preparedAction: 菜单构建时已经冻结的调用。
    /// - Returns: Finder 可以原样回传的正整数 tag。
    private func retain(_ preparedAction: PreparedContextMenuAction) -> Int {
        let tag = nextActionTag
        nextActionTag = tag == Int.max ? 1 : tag + 1

        precondition(
            preparedActionsByTag[tag] == nil,
            "Finder action tag wrapped into a retained action"
        )
        preparedActionsByTag[tag] = preparedAction
        retainedActionTags.append(tag)

        return tag
    }

    /// 只在整份菜单注册后淘汰旧调用，保证当前菜单中的所有模板均可执行。
    private func discardOldActions(keepingAtLeast currentActionCount: Int) {
        let retainedCount = max(Self.maximumRetainedActions, currentActionCount)
        while retainedActionTags.count > retainedCount {
            let expiredTag = retainedActionTags.removeFirst()
            preparedActionsByTag.removeValue(forKey: expiredTag)
        }
    }

    /// 取出本次 action 的已准备调用，并释放路由记录。
    /// - Parameter menuItem: Finder 回传的具体菜单项。
    /// - Returns: 该菜单项构建时绑定的 Action；tag 无效时为 `nil`。
    private func consumePreparedAction(
        for menuItem: NSMenuItem
    ) -> PreparedContextMenuAction? {
        let tag = menuItem.tag
        guard let action = preparedActionsByTag.removeValue(forKey: tag) else {
            return nil
        }
        retainedActionTags.removeAll { $0 == tag }
        return action
    }
}
