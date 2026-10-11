/**
 管理主应用已认证本地 IPC 服务的启动与请求处理入口。
 将菜单快照请求交给快照提供者，将命令请求交给运行时路由器。
 */

import Foundation
import OSLog

/// 应用生命周期持有的监听资源，由唯一所有者负责停止。
nonisolated protocol ApplicationIPCListening: AnyObject, Sendable {
    func stop()
}

extension AuthenticatedLocalSocketServer: ApplicationIPCListening {}

/// 接收经过身份验证的 Extension 请求，并分派命令或返回菜单配置。
@MainActor
final class ApplicationIPCServer {
    enum State {
        case stopped
        case listening(any ApplicationIPCListening)
        case failed(Error)
    }

    typealias MakeTransport = (
        @escaping @Sendable (ApplicationIPCError) -> Void
    ) throws -> any ApplicationIPCListening

    private let logger = Logger(
        subsystem: ApplicationLogging.subsystem,
        category: "ApplicationIPC"
    )

    /// 运行和失败状态由应用侧唯一所有者管理；底层失败完成清理后才上报。
    private(set) var state = State.stopped
    private let makeTransport: MakeTransport
    private let didStart: () -> Void

    // MARK: - ==================== 生命周期 ====================

    /// 只连接运行时与快照读取边界，模板可用性由菜单能力解释。
    convenience init(
        router: ContextCommandRouter,
        menuSnapshot: @escaping @MainActor @Sendable () async -> CommandMenuSettingsSnapshot,
        didStart: @escaping () -> Void
    ) {
        self.init(makeTransport: { didFail in
            try AuthenticatedLocalSocketServer(
                expectedClientSigningIdentifier: ApplicationIPC.finderExtensionSigningIdentifier,
                contextCommandSink: { request in
                    Task { @MainActor in
                        guard let invocation = router.prepare(request.command) else { return }
                        router.run(invocation)
                    }
                },
                commandMenuSettingsProvider: { reply in
                    Task { @MainActor in reply(.success(await menuSnapshot())) }
                },
                didFail: didFail
            )
        }, didStart: didStart)
    }

    /// 保存生产监听构造与启动通知，供首次启动和失败后恢复共用。
    private init(makeTransport: @escaping MakeTransport, didStart: @escaping () -> Void) {
        self.makeTransport = makeTransport
        self.didStart = didStart
    }

    /// 首次启动以及用户再次打开应用时恢复不可用的监听，不重放任何命令。
    func startIfNeeded() {
        if case .listening = state { return }
        do {
            let transport = try makeTransport { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.handleListenerFailure(error)
                }
            }
            state = .listening(transport)
            // 初次或恢复监听都唤醒配置副本，重新拉取权威快照。
            didStart()
        } catch {
            recordFailure(error)
        }
    }

    private func handleListenerFailure(_ error: ApplicationIPCError) {
        guard case .listening = state else { return }
        recordFailure(error)
    }

    private func recordFailure(_ error: Error) {
        state = .failed(error)
        logger.error(
            "Authenticated local IPC is unavailable: \(error.localizedDescription, privacy: .private)"
        )
    }

    /// 关闭监听 socket；活跃进程退出时不留下过期端点。
    deinit {
        if case let .listening(transport) = state { transport.stop() }
    }
}
