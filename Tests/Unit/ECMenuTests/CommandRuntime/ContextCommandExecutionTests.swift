/**
 验证命令执行内部的两个精确生命周期交错，避免完成后弹出迟到进度窗口或呈现已取消结果。
 通过控制执行器机会与 Router 释放时刻验证真实界面操作无法稳定安排的顺序。
 */

import XCTest
@testable import ECMenu

@MainActor
final class ContextCommandExecutionTests: XCTestCase {
    /// 完成必须先于零延迟显示任务执行；UI 截图无法可靠发现一帧以内的迟到窗口。
    func testProgressCenterDoesNotRenderFastCompletedTask() async {
        let requestID = UUID()
        let rendered = expectation(description: "Completed fast task rendered late progress")
        rendered.isInverted = true
        let center = ContextCommandProgressCenter(
            displayDelay: .zero,
            render: { _, _ in rendered.fulfill() }
        )

        center.begin(
            requestID: requestID,
            descriptor: progressDescriptor(
                id: "fast",
                title: "快速任务"
            ),
            totalUnitCount: 1
        )
        center.advance(requestID: requestID)
        center.finish(requestID: requestID)
        // 为零延迟显示任务的 sleep continuation 留出明确的主执行器观察窗口。
        await fulfillment(of: [rendered], timeout: 0.2)
    }

    /// Router 释放必须取消正在执行的同一个 Task，并阻止取消后的反馈出口。
    func testRouterCancellationReachesHandlerTask() async throws {
        let started = expectation(description: "Handler execution started")
        let cancelled = expectation(description: "Handler observed cancellation")
        let presented = expectation(description: "Cancelled result was presented")
        presented.isInverted = true

        let probe = CancellationProbe(
            started: started,
            cancelled: cancelled,
            presented: presented
        )
        let handlers = ContextCommandHandlers {
            CancellationHandler(probe: probe)
        }
        var router: ContextCommandRouter? = ContextCommandRouter(
            handlers: handlers,
            progressCenter: ContextCommandProgressCenter(render: { _, _ in })
        )
        let invocation = try XCTUnwrap(
            router?.prepare(
                try ContextCommandEnvelope(
                    RecordingCommand(value: "cancel")
                )
            )
        )
        router?.run(invocation)

        await fulfillment(of: [started], timeout: 1)
        router = nil
        await fulfillment(of: [cancelled, presented], timeout: 1)
    }
}

private func progressDescriptor(
    id: String,
    title: LocalizedStringResource,
    symbolName: String = "gearshape"
) -> ContextCommandDescriptor {
    ContextCommandDescriptor(
        id: "progress-test-\(id)",
        title: title,
        icon: .systemSymbol(name: symbolName)
    )
}

private struct RecordingCommand: ContextCommandPayload {
    /// 测试注册使用的稳定身份。
    static let descriptor = ContextCommandDescriptor(
        id: "recording-command",
        title: "Recording Command",
        icon: .systemSymbol(name: "record.circle")
    )

    /// Handler 原样返回的测试值。
    let value: String
}

nonisolated private final class CancellationProbe: @unchecked Sendable {
    /// Handler 进入执行阶段时完成。
    let started: XCTestExpectation

    /// Handler 在同一个 Task 中观察到取消时完成。
    let cancelled: XCTestExpectation

    /// 若 Router 错误呈现已取消结果则完成；测试中设置为反向期望。
    let presented: XCTestExpectation

    /// 注入完整生命周期的三个观测点。
    init(
        started: XCTestExpectation,
        cancelled: XCTestExpectation,
        presented: XCTestExpectation
    ) {
        self.started = started
        self.cancelled = cancelled
        self.presented = presented
    }
}

nonisolated private struct CancellationHandler: ContextCommandHandling {
    /// 跨执行隔离域使用的线程安全测试探针。
    let probe: CancellationProbe

    /// 在 Router 创建的同一个任务中观察取消状态。
    @concurrent func execute(_ command: RecordingCommand) async {
        probe.started.fulfill()
        while !Task.isCancelled {
            await Task.yield()
        }
        probe.cancelled.fulfill()
    }

    /// 已取消命令不应到达该主线程反馈出口。
    @MainActor func present(_ outcome: Void, requestID: UUID) {
        probe.presented.fulfill()
    }
}
