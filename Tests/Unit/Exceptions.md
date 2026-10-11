# 单元测试例外

产品交付通过虚拟机内的真实用户流程验收。XCTest 仅覆盖下列需要控制内部调度机会或注入不可稳定制造的系统边界失败的关键行为；它们不作为菜单、文件操作、设置或窗口流程通过的证据。

| 文件与用例 | 真实失败模式 | 单元验证的必要性 |
| --- | --- | --- |
| [CopyPathTests](ECMenuTests/Commands/CopyPath/CopyPathTests.swift) · `testPasteboardFailureIsPartOfExecutionResult` | 系统剪贴板拒绝写入，命令却报告成功。 | `NSPasteboard` 写入失败无法通过普通用户操作可靠制造；仅替换写入边界并验证失败结果。 |
| 同上 · `testCancellationAfterReadingFactsPreventsMainActorWrite` | 已取消命令在排队获得主执行器后覆盖剪贴板。 | 需要将取消安排在后台事实读取完成与主执行器写入之间；真实 Finder 操作无法稳定控制该间隙。 |
| [ContextCommandExecutionTests](ECMenuTests/CommandRuntime/ContextCommandExecutionTests.swift) · `testProgressCenterDoesNotRenderFastCompletedTask` | 快任务结束后，迟到的显示任务仍弹出进度窗口。 | 需要保证完成先于延迟回调获得执行机会；界面截图无法可靠捕获极短的错误窗口。 |
| 同上 · `testRouterCancellationReachesHandlerTask` | 命令所有者释放后，后台任务继续或呈现迟到结果。 | 可控 Handler 精确观察同一个 Task 的取消；退出应用会同时结束观测进程，难以从界面证明任务与反馈的内部交错。 |
| [ContextCommandTransportTests](ECMenuTests/IPC/ContextCommandTransportTests.swift) · `testAcceptRecoversAfterResourceFailure` | 一次文件描述符资源耗尽使监听器永久停摆。 | 在 `accept` 边界注入一次 `EMFILE`，不以耗尽整个来宾资源作为普通产品验收前提。 |
| 同上 · `testStoppingOrReleasingListenerAfterResourceFailureCleansEndpoint` | 退避期间结束监听器，延迟重试恢复已取消 source、泄漏所有者或重新创建端点。 | 必须将 stop/release 安排在资源退避期间，并越过重试时间观察清理；外部进程时序无法稳定安排该状态。 |
| 同上 · `testFatalAcceptFailureReleasesEndpointBeforeReporting` | 致命错误回调执行时旧端点仍存在，状态所有者无法安全重建。 | 在系统接收边界注入 `EBADF`，直接观察回调时刻的端点状态；正常用户流程不会产生此系统边界错误。 |
| [CommandMenuSettingsReplicaTests](ECMenuFinderExtensionTests/CommandMenuSettings/CommandMenuSettingsReplicaTests.swift) · `testConcurrentRefreshSignalsCoalesceAndSkipStaleResponse` | 多次配置更新与旧请求完成交错，过时快照覆盖最新配置或模板。 | 可控传输明确安排刷新信号与响应先后，真实 IPC 的调度速度无法保证进入同一交错。 |

测试数据由 `ProjectTestDirectory` 创建在项目的 `.artifacts/scratch/tests/` 中；XCTest 结果由测试入口保存为可检查的 `.xcresult`。配置副本测试使用随机名称的独立偏好域，并在结束时清理。

改变以上行为时，先明确实际失败模式并编写会失败的测试，再修改实现。新增例外必须说明真实用户流程无法有效验证的具体原因；字段映射、序列化往返、内部调用次数以及已实现算法的复述不构成例外理由。
