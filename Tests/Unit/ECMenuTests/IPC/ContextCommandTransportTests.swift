/**
 验证 Unix socket 监听在资源耗尽、退避取消及致命接收错误下的恢复和资源清理顺序。
 只在 accept 系统边界注入精确错误；正常通信与产品身份验收由虚拟机完整流程承担。
 */

import Darwin
import Foundation
import XCTest
@testable import ECMenu

final class ContextCommandTransportTests: XCTestCase {
    /// 系统资源耗尽不能使整个监听器永久停摆；避免在 E2E 中耗尽来宾所有描述符。
    func testAcceptRecoversAfterResourceFailure() async throws {
        let socketURL = try ProjectTestDirectory.makeUniqueSocketURL()
        let acceptor = FailingOnceIPCAcceptor(code: EMFILE)
        let routed = expectation(description: "Command after recovered accept")
        let server = try AuthenticatedLocalSocketServer(
            expectedClientSigningIdentifier: ApplicationIPC.applicationSigningIdentifier,
            socketURL: socketURL,
            contextCommandSink: { _ in routed.fulfill() },
            commandMenuSettingsProvider: { $0(.success(.standard)) },
            acceptConnection: { acceptor.accept($0) },
            didFail: { error in XCTFail("Resource failure stopped the listener: \(error)") }
        )
        defer { server.stop() }
        let client = try AuthenticatedLocalSocketClient(
            expectedServerSigningIdentifier: ApplicationIPC.applicationSigningIdentifier,
            socketURL: socketURL
        )
        let request = try makeRequest()
        try await Task.detached { try client.transmit(request) }.value
        await fulfillment(of: [routed], timeout: 1)
    }

    /// 停止或释放恰逢资源退避时，延迟重试不能恢复已取消 source 或重新创建端点。
    func testStoppingOrReleasingListenerAfterResourceFailureCleansEndpoint() async throws {
        for termination in [ListenerTermination.stop, .release] {
            let socketURL = try ProjectTestDirectory.makeUniqueSocketURL()
            let exhausted = expectation(description: "Listener encountered resource exhaustion")
            let acceptor = ResourceExhaustedIPCAcceptor(firstFailure: exhausted)
            var server: AuthenticatedLocalSocketServer? = try AuthenticatedLocalSocketServer(
                expectedClientSigningIdentifier: ApplicationIPC.applicationSigningIdentifier,
                socketURL: socketURL,
                contextCommandSink: { _ in XCTFail("Resource-exhausted listener routed a command") },
                commandMenuSettingsProvider: { $0(.success(.standard)) },
                acceptConnection: { acceptor.accept($0) },
                didFail: { error in XCTFail("Stopping reported a fatal failure: \(error)") }
            )
            defer { server?.stop() }
            let releasedServer = WeakIPCListenerReference(server)
            let connection = try LocalSocketIO.connect(to: socketURL)
            defer { LocalSocketIO.close(connection) }
            await fulfillment(of: [exhausted], timeout: 1)

            // accept 替身返回后，让 source 进入 100 ms 的资源退避。
            // 替身始终返回 EMFILE，延迟调度也不会进入正常接收路径。
            try await Task.sleep(for: .milliseconds(20))
            switch termination {
            case .stop:
                server?.stop()
                server?.stop() // 停止必须幂等，不能对已取消 source 再次 resume。
            case .release:
                server = nil
            }

            let clock = ContinuousClock()
            let cleanupDeadline = clock.now.advanced(by: .seconds(1))
            while FileManager.default.fileExists(atPath: socketURL.path), clock.now < cleanupDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
            // 越过原重试时刻，确认取消的延迟任务不会重新打开或再次恢复 source。
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
            server = nil
            XCTAssertNil(releasedServer.value)
        }
    }

    /// 致命错误回调前先释放端点，允许状态所有者安全重建监听器。
    func testFatalAcceptFailureReleasesEndpointBeforeReporting() async throws {
        let socketURL = try ProjectTestDirectory.makeUniqueSocketURL()
        let failed = expectation(description: "Fatal listener failure reported after cleanup")
        let server = try AuthenticatedLocalSocketServer(
            expectedClientSigningIdentifier: ApplicationIPC.applicationSigningIdentifier,
            socketURL: socketURL,
            contextCommandSink: { _ in XCTFail("Failed listener routed a command") },
            commandMenuSettingsProvider: { $0(.success(.standard)) },
            acceptConnection: { _ in .failure(.posix(operation: "accept", code: EBADF)) },
            didFail: { error in
                XCTAssertEqual(error, .posix(operation: "accept", code: EBADF))
                XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
                failed.fulfill()
            }
        )
        defer { server.stop() }
        let client = try AuthenticatedLocalSocketClient(
            expectedServerSigningIdentifier: ApplicationIPC.applicationSigningIdentifier,
            socketURL: socketURL,
            connectionTimeout: 1
        )
        let result = await Task.detached { Result { try client.fetchCommandMenuSettings() } }.value
        if case .success = result { XCTFail("A failed listener returned a configuration") }
        await fulfillment(of: [failed], timeout: 1)
    }

    private func makeRequest(
        path: String = "/test/parent"
    ) throws -> ContextCommandRequest {
        try ContextCommandRequest(
            command: CreateNewFileCommand(
                directoryPath: try XCTUnwrap(AbsoluteFilePath(path: path)),
                templateID: .init()
            )
        )
    }
}

nonisolated private enum ListenerTermination {
    case stop
    case release
}

nonisolated private final class WeakIPCListenerReference {
    weak var value: AuthenticatedLocalSocketServer?

    init(_ value: AuthenticatedLocalSocketServer?) { self.value = value }
}

nonisolated private final class ResourceExhaustedIPCAcceptor: @unchecked Sendable {
    private let lock = NSLock()
    private var firstFailure: XCTestExpectation?

    init(firstFailure: XCTestExpectation) { self.firstFailure = firstFailure }

    func accept(_ descriptor: Int32) -> Result<Int32, ApplicationIPCError> {
        lock.lock()
        let notification = firstFailure
        firstFailure = nil
        lock.unlock()
        notification?.fulfill()
        return .failure(.posix(operation: "accept", code: EMFILE))
    }
}

nonisolated private final class FailingOnceIPCAcceptor: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: Int32?

    init(code: Int32) { failure = code }

    func accept(_ descriptor: Int32) -> Result<Int32, ApplicationIPCError> {
        lock.lock()
        let code = failure
        failure = nil
        lock.unlock()
        if let code { return .failure(.posix(operation: "accept", code: code)) }
        return LocalSocketIO.acceptConnection(descriptor)
    }
}
