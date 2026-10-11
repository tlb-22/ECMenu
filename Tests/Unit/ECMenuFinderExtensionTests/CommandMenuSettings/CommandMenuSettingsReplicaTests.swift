/**
 验证菜单配置副本在多个刷新信号与过时响应交错时只发布最新快照。
 由可控传输精确安排响应顺序，避免真实 IPC 调度的不确定性掩盖旧响应覆盖问题。
 */

import Foundation
import XCTest
@testable import ECMenuFinderExtension

@MainActor
final class CommandMenuSettingsReplicaTests: XCTestCase {
    /// 旧请求完成前连续两次更新，旧响应不得覆盖最终配置及模板身份。
    func testConcurrentRefreshSignalsCoalesceAndSkipStaleResponse() async throws {
        let suiteName = "CommandMenuSettingsReplicaTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let transport = ControlledCommandMenuSettingsTransport()
        let replica = CommandMenuSettingsReplica(
            defaults: defaults,
            transport: transport
        )
        XCTAssertEqual(transport.requestCount, 1)

        replica.refreshConfiguration()
        replica.refreshConfiguration()
        XCTAssertEqual(transport.requestCount, 1)

        let stale = CommandMenuSettingsSnapshot(
            configuration: CommandMenuSettings(isEnabled: false),
            newFileTemplates: [FileTemplateMenuItem(id: FileTemplateID(), displayName: "Stale", filenameExtension: "txt")]
        )
        transport.completeNext(with: .success(stale))
        await waitForRequestCount(2, in: transport)

        XCTAssertTrue(replica.isEnabled)
        XCTAssertTrue(replica.isVisible(CreateNewFileCommand.descriptor.id))
        XCTAssertTrue(replica.newFileTemplates.isEmpty)

        let templates = [
            FileTemplateMenuItem(id: FileTemplateID(), displayName: "TXT", filenameExtension: "txt"),
            FileTemplateMenuItem(id: FileTemplateID(), displayName: "TXT", filenameExtension: "txt"),
        ]
        let latest = CommandMenuSettingsSnapshot(
            configuration: CommandMenuSettings(
                isEnabled: true,
                hiddenFeatureIDs: ["new-text-file"],
                orderedFeatureIDs: CommandMenuSettings.defaultFeatureIDs.reversed()
            ),
            newFileTemplates: templates
        )
        transport.completeNext(with: .success(latest))
        await waitUntil {
            replica.menuSettings == latest.configuration
                && replica.newFileTemplates == latest.newFileTemplates
        }

        XCTAssertEqual(transport.requestCount, 2)
        XCTAssertTrue(replica.isEnabled)
        XCTAssertFalse(replica.isVisible(CreateNewFileCommand.descriptor.id))
        XCTAssertEqual(replica.newFileTemplates, templates)
        XCTAssertEqual(replica.menuSettings, latest.configuration)
        let stored = try XCTUnwrap(defaults.data(forKey: CommandMenuSettingsSnapshotCache.key))
        XCTAssertEqual(try CommandMenuSettingsSnapshotCache.decode(stored), latest)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !condition(), clock.now < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition(), "配置副本未在截止时间前发布最新快照")
    }

    private func waitForRequestCount(
        _ expectedCount: Int,
        in transport: ControlledCommandMenuSettingsTransport
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while transport.requestCount < expectedCount, clock.now < deadline {
            await Task.yield()
        }
        XCTAssertEqual(transport.requestCount, expectedCount)
    }
}

nonisolated private final class ControlledCommandMenuSettingsTransport:
    CommandMenuSettingsRequesting,
    @unchecked Sendable
{
    typealias Completion = @Sendable (
        Result<CommandMenuSettingsSnapshot, Error>
    ) -> Void

    private let lock = NSLock()
    private var completions: [Completion] = []
    private var requests: [ApplicationIPCRequest] = []

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    func fetchCommandMenuSettings(completion: @escaping Completion) {
        lock.lock()
        requests.append(.commandMenuSettings)
        completions.append(completion)
        lock.unlock()
    }

    func completeNext(
        with result: Result<CommandMenuSettingsSnapshot, Error>
    ) {
        lock.lock()
        let completion = completions.removeFirst()
        lock.unlock()
        completion(result)
    }
}
