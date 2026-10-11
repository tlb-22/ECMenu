/**
 验证拷贝路径在无法稳定由真实 Finder 流程制造的系统失败与取消交错中的副作用边界。
 剪贴板写入返回失败必须进入结果；后台事实读取后、主执行器写入前的取消必须阻止写入。
 */

import Foundation
import XCTest
@testable import ECMenu

final class CopyPathTests: XCTestCase {
    /// 真实 NSPasteboard 写入失败不可稳定从用户流程触发，用系统边界替身验证失败交付。
    @MainActor
    func testPasteboardFailureIsPartOfExecutionResult() async throws {
        let item = url("/test/item")
        var written: String?
        let handler = CopyPathHandler(
            platform: CopyPathPlatform(existingURLs: { _ in [item] }, writeString: {
                written = $0
                return false
            }),
            present: { _, _ in XCTFail("Execution must not present feedback") }
        )
        let result = await handler.execute(try command([item]))
        XCTAssertEqual(result, .failure(.pasteboardWriteFailed))
        XCTAssertEqual(written, item.path)
    }

    /// 精确占用 MainActor 并在事实读取后取消，防止已取消任务覆盖用户剪贴板。
    @MainActor
    func testCancellationAfterReadingFactsPreventsMainActorWrite() async throws {
        let item = url("/test/item")
        let command = try command([item])
        let factsRead = DispatchSemaphore(value: 0)
        let handler = CopyPathHandler(
            platform: CopyPathPlatform(existingURLs: { _ in
                factsRead.signal()
                return [item]
            }, writeString: { _ in
                XCTFail("A task cancelled before its MainActor write must leave the clipboard untouched")
                return true
            }),
            present: { _, _ in XCTFail("Execution must not present feedback") }
        )
        let task = Task.detached { await handler.execute(command) }
        // 同步等待只阻塞这里占有的 MainActor；后台事实读取不依赖主执行器。
        XCTAssertEqual(factsRead.wait(timeout: .now() + 1), .success)
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
    }

    private func url(_ path: String) -> URL {
        URL(fileURLWithPath: path).standardizedFileURL
    }

    private func command(_ urls: [URL]) throws -> CopyPathCommand {
        try XCTUnwrap(
            CopyPathCommand(
                paths: urls.map { try XCTUnwrap(AbsoluteFilePath(url: $0)) }
            )
        )
    }
}
