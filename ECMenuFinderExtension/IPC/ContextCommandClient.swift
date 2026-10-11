/**
 将准备好的类型化命令封装为一次跨进程请求，并连接发送结果与 Extension 的错误提示。
 每次点击只投递一次；transport 不可用或发送失败时记录错误并在主线程提示。
 */

import AppKit
import Foundation
import OSLog

/// 向当前常驻主应用单次发送 Finder 右键命令。
@MainActor
final class ContextCommandClient {
    private let logger = Logger(
        subsystem: ApplicationLogging.subsystem,
        category: "ContextCommand"
    )

    /// 每次发送前验证精确主应用签名的定向 socket 客户端。
    private let transport: (any ContextCommandSending)?

    /// 建立生产 transport；初始化失败时每次点击直接反馈投递失败。
    init() {
        do {
            transport = try AuthenticatedLocalSocketClient(
                expectedServerSigningIdentifier:
                    ApplicationIPC.applicationSigningIdentifier
            )
        } catch {
            transport = nil
            logger.error(
                "Could not initialize authenticated local IPC: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    /// 构造并单次发送命令，不等待接管回执或业务执行结果。
    /// - Parameter command: Finder Feature 构造的具体命令参数。
    func send<Command: ContextCommandPayload>(_ command: Command) {
        let request = try! ContextCommandRequest(command: command)

        guard let transport else {
            reportDeliveryFailure(nil)
            return
        }

        transport.send(request) { [weak self] result in
            guard case let .failure(error) = result else {
                return
            }
            Task { @MainActor [weak self] in
                self?.reportDeliveryFailure(error)
            }
        }
    }

    /// 记录连接、身份验证、编码或完整写入失败并播放一次系统提示音。
    private func reportDeliveryFailure(_ error: Error?) {
        if let error {
            logger.error(
                "Could not send context command: \(error.localizedDescription, privacy: .private)"
            )
        } else {
            logger.error("Authenticated local IPC is unavailable")
        }
        NSSound.beep()
    }
}
