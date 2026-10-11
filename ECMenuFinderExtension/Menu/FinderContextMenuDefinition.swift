/**
 保存按产品配置排列的菜单声明树，并把具体能力适配为可执行叶子。
 构造时验证动作身份唯一，类型擦除后的叶子仍保留各自命令准备行为。
 */

import Foundation

/// 保存 Finder 产品顺序、层级和可执行叶子的不可变声明。
struct FinderContextMenuDefinition {
    /// 产品声明和运行时准备共用的递归菜单树。
    let nodes: [ContextMenuNode<AnyContextMenuAction>]

    /// 使用已经按配置排列的完整能力子树构造菜单。
    init(nodes: [ContextMenuNode<AnyContextMenuAction>]) {
        let actionIDs = nodes
            .flatMap { $0.items }
            .map(\.descriptor.id)
        precondition(
            Set(actionIDs).count == actionIDs.count,
            "A Finder context-menu Action was registered more than once"
        )
        self.nodes = nodes
    }
}

/// 把具体 Feature 的完整子树适配为运行时共用的动作类型。
enum FinderContextMenuBuilder {
    /// 一项能力贡献的完整菜单子树。
    typealias Component = [ContextMenuNode<AnyContextMenuAction>]

    /// 一个具体 Feature 贡献自己的完整菜单子树和运行时 Action。
    static func buildExpression<Feature: ContextMenuFeature>(
        _ expression: Feature
    ) -> Component {
        let featureID = Feature.Command.descriptor.id
        let nodes = expression.nodes.map { node in
            node.mapItems { action in
                AnyContextMenuAction(
                    action,
                    featureID: featureID,
                    commandClient: expression.commandClient
                )
            }
        }
        return nodes
    }
}
