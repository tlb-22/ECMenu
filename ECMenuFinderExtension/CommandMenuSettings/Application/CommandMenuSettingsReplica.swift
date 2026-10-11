/**
 协调命令菜单配置的恢复、变化提示与认证查询，向菜单构建提供最后一份有效快照。
 实例独占已应用快照和单飞刷新状态；拉取期间的新提示淘汰当前响应，失败保留已有副本。
 */

import Foundation
import OSLog

/// Finder Extension 保存的最后一份有效菜单配置，只接受主应用发布的更新。
final class CommandMenuSettingsReplica: NSObject {
    private enum RefreshState {
        case idle
        case fetching(refreshAgain: Bool)
    }
    /// 当前用于构建 Finder 菜单的配置快照。
    private var configuration: CommandMenuSettingsSnapshot

    /// 在主应用不可用时恢复最后有效快照的本地偏好存储。
    private let cache: CommandMenuSettingsCacheStore

    /// 只接受精确主应用签名响应的定向 socket 客户端。
    private let transport: (any CommandMenuSettingsRequesting)?

    /// 同一时刻最多存在一个配置拉取，避免响应乱序覆盖新状态。
    private var refreshState = RefreshState.idle
    private static let logger = Logger(
        subsystem: ApplicationLogging.subsystem,
        category: "CommandMenuSettings"
    )

    /// 恢复缓存、监听无数据更新信号并向主应用定向拉取配置。
    override convenience init() {
        let transport: AuthenticatedLocalSocketClient?
        do {
            transport = try AuthenticatedLocalSocketClient(
                expectedServerSigningIdentifier:
                    ApplicationIPC.applicationSigningIdentifier
            )
        } catch {
            transport = nil
            Self.logger.error(
                "Could not initialize authenticated local IPC: \(error.localizedDescription, privacy: .public)"
            )
        }
        self.init(defaults: .standard, transport: transport)
    }

    /// 注入缓存和 transport，供同步并发策略测试使用。
    init(
        defaults: UserDefaults,
        transport: (any CommandMenuSettingsRequesting)?
    ) {
        let cache = CommandMenuSettingsCacheStore(defaults: defaults)
        self.cache = cache
        self.transport = transport
        configuration = cache.restore() ?? .standard
        super.init()

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleConfigurationChangeSignal(_:)),
            name: CommandMenuSettingsChannel.didChangeNotification,
            object: nil
        )
        refreshConfiguration()
    }

    /// 释放配置通知观察者。
    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    /// 查询产品当前是否应向 Finder 贡献任何右键菜单项。
    var isEnabled: Bool {
        configuration.isEnabled
    }

    /// 构建本次子菜单所需的有序模板描述。
    var newFileTemplates: [FileTemplateMenuItem] { configuration.newFileTemplates }

    /// 本次菜单使用的开关与命令顺序；副本只提供不可变值。
    var menuSettings: CommandMenuSettings { configuration.configuration }

    /// 查询功能自身的显示配置，不合并产品总开关。
    /// - Parameter feature: 固定右键功能标识。
    /// - Returns: 功能未被独立隐藏时为 `true`。
    func isVisible(_ feature: ContextCommandFeatureID) -> Bool {
        configuration.isVisible(feature)
    }

    /// 无数据广播只能触发拉取，本身不能改变任何菜单状态。
    @objc private func handleConfigurationChangeSignal(
        _ notification: Notification
    ) {
        refreshConfiguration()
    }

    /// 通过双向身份验证的 socket 请求主应用当前真相。
    func refreshConfiguration() {
        guard let transport else {
            Self.logger.error("Authenticated local IPC is unavailable")
            return
        }
        guard case .idle = refreshState else {
            refreshState = .fetching(refreshAgain: true)
            return
        }

        refreshState = .fetching(refreshAgain: false)

        transport.fetchCommandMenuSettings { [self] result in
            Task { @MainActor [self] in
                guard case let .fetching(shouldRefreshAgain) = self.refreshState else {
                    preconditionFailure("A configuration request completed without an active refresh")
                }
                self.refreshState = .idle

                // 拉取期间出现新信号时，当前响应可能已经过时；不应用它，
                // 等待下一次经过验证的读取。
                if !shouldRefreshAgain {
                    self.applyRefreshResult(result)
                }
                if shouldRefreshAgain {
                    self.refreshConfiguration()
                }
            }
        }
    }

    /// 验证、应用并缓存一次没有被后续信号淘汰的响应。
    private func applyRefreshResult(
        _ result: Result<CommandMenuSettingsSnapshot, Error>
    ) {
        guard case let .success(updated) = result else {
            if case let .failure(error) = result {
                Self.logger.error(
                    "Could not refresh menu configuration: \(error.localizedDescription, privacy: .public)"
                )
            }
            return
        }

        configuration = updated
        cache.store(updated)
        Self.logger.info(
            "Applied menu configuration: enabled=\(updated.isEnabled), hiddenFeatures=\(updated.hiddenFeatureIDs.count)"
        )
    }
}
