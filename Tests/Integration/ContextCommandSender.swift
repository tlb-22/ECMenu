/**
 提供独立签名进程，用真实生产 IPC 发送命令、查询配置并验证连接故障边界。
 非法输入仅写真实 socket；认证拒绝、连接关闭和服务继续响应由外部集成流程检查。
 */

import Darwin
import Foundation

/// 使用与 Finder Extension 相同的真实代码签名身份验证生产 IPC。
@main
enum ContextCommandSender {
    private enum FaultScenario: String, CaseIterable {
        case malformedJSON = "malformed-json"
        case lengthOverflow = "frame-length-overflow"
        case truncatedHeader = "truncated-header"
        case truncatedBody = "truncated-body"
        case disconnect = "disconnect"
        case partialFrameTimeout = "partial-frame-timeout"
    }

    private struct FaultResult: Encodable {
        let scenario: String
        let status = "passed"
        let observation: String
        let elapsedSeconds: Double
    }

    private enum CommandMenuSettingsOperation: String {
        case readOnce = "--menu-configuration"
        case waitForHost = "--wait-for-menu-configuration"
    }

    /// 解析测试场景，单次发送命令或查询菜单配置。
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())

        if arguments == ["--expect-identity-rejection"] {
            let started = DispatchTime.now().uptimeNanoseconds
            do {
                _ = try makeClient().fetchCommandMenuSettings()
                throw SenderFailure(message: "Host accepted the deliberately wrong signing identifier")
            } catch let error as ApplicationIPCError {
                guard isPeerClosure(error) else { throw error }
                try printResult(
                    scenario: "wrong-signing-identifier", observation: "closed-before-authentication-acknowledgment", started: started
                )
            }
            return
        }

        if arguments.count == 2, arguments[0] == "--connection-fault",
           let scenario = FaultScenario(rawValue: arguments[1]) {
            try exerciseFault(scenario)
            return
        }

        if arguments.count == 1,
           let argument = arguments.first,
           let operation = CommandMenuSettingsOperation(rawValue: argument) {
            try fetchCommandMenuSettings(operation)
            return
        }

        if arguments.count >= 2,
           let operation = arguments.first,
           ["--copy-path", "--hide-items", "--show-items"].contains(operation) {
            guard let selection = FinderItemSelection(
                paths: Array(arguments.dropFirst())
            ) else {
                throw SenderFailure(message: "Expected at least one absolute item path")
            }
            switch operation {
            case "--copy-path":
                guard let command = CopyPathCommand(
                    paths: selection.absolutePaths
                ) else {
                    throw SenderFailure(message: "Expected at least one absolute item path")
                }
                try deliver(command)
            case "--hide-items":
                try deliver(HideItemsCommand(selection: selection))
            case "--show-items":
                try deliver(ShowItemsCommand(selection: selection))
            default:
                preconditionFailure("Validated operation became unknown")
            }
            return
        }

        if arguments.count == 3, arguments[0] == "--new-file" {
            guard let uuid = UUID(uuidString: arguments[1]),
                  let directoryPath = AbsoluteFilePath(path: arguments[2]) else {
                throw SenderFailure(message: "Expected a template UUID and an absolute directory path")
            }
            try deliver(CreateNewFileCommand(
                directoryPath: directoryPath,
                templateID: FileTemplateID(rawValue: uuid)
            ))
            return
        }

        throw SenderFailure(
            message: "Expected a command/configuration operation, --expect-identity-rejection, or --connection-fault SCENARIO"
        )
    }

    /// 独立进程经双向认证后写入真实坏帧，观察连接终态，不替代业务验收。
    private static func exerciseFault(_ scenario: FaultScenario) throws {
        let started = DispatchTime.now().uptimeNanoseconds
        let deadline = LocalSocketDeadline(timeout: LocalSocketDeadline.defaultTimeout + 5)
        let descriptor = try LocalSocketIO.connect(to: ApplicationIPC.socketURL(), deadline: deadline)
        defer { LocalSocketIO.close(descriptor) }
        try LocalSocketPeerValidator(
            expectedSigningIdentifier: ApplicationIPC.applicationSigningIdentifier
        ).validate(connectedSocket: descriptor)
        let acknowledgment = try LocalSocketIO.readFrame(from: descriptor, deadline: deadline)
        try LocalSocketAuthenticationReadyAcknowledgment.validateAcknowledgmentPayload(acknowledgment)

        switch scenario {
        case .malformedJSON:
            try LocalSocketIO.writeFrame(Data("{invalid-json".utf8), to: descriptor, deadline: deadline)
        case .lengthOverflow:
            try LocalSocketIO.write(header(length: UInt64.max), to: descriptor, deadline: deadline)
        case .truncatedHeader:
            try LocalSocketIO.write(Data(header(length: 8).prefix(3)), to: descriptor, deadline: deadline)
            try closeWriteHalf(descriptor)
        case .truncatedBody:
            var frame = header(length: 8)
            frame.append(Data("{}".utf8))
            try LocalSocketIO.write(frame, to: descriptor, deadline: deadline)
            try closeWriteHalf(descriptor)
        case .disconnect:
            // 本进程随后关闭 socket；服务是否继续响应由新的独立查询验证。
            try printResult(scenario: scenario.rawValue, observation: "authenticated-client-disconnected", started: started)
            return
        case .partialFrameTimeout:
            try LocalSocketIO.write(Data(header(length: 8).prefix(3)), to: descriptor, deadline: deadline)
        }

        do {
            _ = try LocalSocketIO.read(count: 1, from: descriptor, deadline: deadline)
            throw SenderFailure(message: "Host returned unexpected application data for \(scenario.rawValue)")
        } catch let error as ApplicationIPCError {
            guard isPeerClosure(error) else { throw error }
            if scenario == .partialFrameTimeout,
               elapsed(since: started) < LocalSocketDeadline.defaultTimeout - 1 {
                throw SenderFailure(message: "Host closed the partial frame before the expected connection timeout")
            }
            try printResult(scenario: scenario.rawValue, observation: "peer-closed-without-application-response", started: started)
        }
    }

    private static func header(length: UInt64) -> Data {
        var encoded = length.bigEndian
        return withUnsafeBytes(of: &encoded) { Data($0) }
    }

    private static func closeWriteHalf(_ descriptor: Int32) throws {
        guard Darwin.shutdown(descriptor, SHUT_WR) == 0 else { throw LocalSocketIO.posixError("shutdown") }
    }

    private static func isPeerClosure(_ error: ApplicationIPCError) -> Bool {
        switch error {
        case .connectionClosed: true
        case .posix(let operation, let code): operation == "read" && code == ECONNRESET
        default: false
        }
    }

    private static func elapsed(since started: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
    }

    private static func printResult(scenario: String, observation: String, started: UInt64) throws {
        let result = FaultResult(scenario: scenario, observation: observation, elapsedSeconds: elapsed(since: started))
        var output = try JSONEncoder().encode(result)
        output.append(0x0A)
        FileHandle.standardOutput.write(output)
    }

    /// 通过真实认证连接单次写入命令，不等待接管或业务结果。
    private static func deliver<Command: ContextCommandPayload>(
        _ command: Command
    ) throws {
        let request = try ContextCommandRequest(command: command)
        try makeClient().transmit(request)
        print("context-command sent")
    }

    /// 通过已验证 IPC 端点拉取菜单配置快照。
    private static func fetchCommandMenuSettings(_ operation: CommandMenuSettingsOperation) throws {
        let configuration: CommandMenuSettingsSnapshot
        switch operation {
        case .readOnce:
            configuration = try makeClient().fetchCommandMenuSettings()
        case .waitForHost:
            configuration = try waitForHostConfiguration()
        }
        let schemaVersion = CommandMenuSettingsSnapshot.currentSchemaVersion
        print(
            "menu-configuration schema=\(schemaVersion) enabled=\(configuration.isEnabled)"
        )
        for template in configuration.newFileTemplates {
            print("template \(template.id.rawValue.uuidString) \(template.displayName)")
        }
    }

    /// 只读启动探测共用一个传输预算；只在端点尚不存在或尚无监听者时重试。
    private static func waitForHostConfiguration() throws -> CommandMenuSettingsSnapshot {
        let deadline = LocalSocketDeadline(timeout: LocalSocketDeadline.defaultTimeout)
        while true {
            let remaining = try remainingInterval(until: deadline)
            do {
                return try makeClient(connectionTimeout: remaining).fetchCommandMenuSettings()
            } catch let error as ApplicationIPCError {
                guard case let .posix(operation, code) = error,
                      operation == "connect",
                      code == ENOENT || code == ECONNREFUSED else {
                    throw error
                }
                Thread.sleep(forTimeInterval: min(0.05, try remainingInterval(until: deadline)))
            }
        }
    }

    private static func remainingInterval(until deadline: LocalSocketDeadline) throws -> TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadline.dispatchTime.uptimeNanoseconds > now else {
            throw ApplicationIPCError.deadlineExceeded
        }
        return TimeInterval(deadline.dispatchTime.uptimeNanoseconds - now) / 1_000_000_000
    }

    /// 构造会验证精确主应用身份的真实 socket 客户端。
    private static func makeClient(
        connectionTimeout: TimeInterval = LocalSocketDeadline.defaultTimeout
    ) throws -> AuthenticatedLocalSocketClient {
        try AuthenticatedLocalSocketClient(
            expectedServerSigningIdentifier:
                ApplicationIPC.applicationSigningIdentifier,
            connectionTimeout: connectionTimeout
        )
    }

}

/// 表示集成测试入口的参数、传输、身份或配置响应失败。
private struct SenderFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
