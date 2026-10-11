/**
 启动独立 AppKit 预览进程并保活应用代理。
 根据运行模式输出预览列表或进入界面事件循环，隔离产品应用生命周期。
 */

import AppKit

/// 独立界面预览进程的 AppKit 入口，不经过主应用或 Finder Extension 生命周期。
@main
@MainActor
enum ECMenuPreviewsApp {
    /// `NSApplication` 不保留弱引用 delegate，因此由入口显式保活。
    private static let applicationDelegate = PreviewApplicationDelegate()

    /// 列表查询直接输出；界面预览创建标准前台应用并进入事件循环。
    static func main() {
        if PreviewRuntime.shouldListAvailablePreviews {
            PreviewRuntime.printAvailablePreviewIDs()
            return
        }

        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.delegate = applicationDelegate
        application.run()
    }
}

/// 在独立进程启动完成后把命令行选择交给预览运行时。
@MainActor
private final class PreviewApplicationDelegate:
    NSObject,
    NSApplicationDelegate
{
    /// 呈现指定预览。
    func applicationDidFinishLaunching(_ notification: Notification) {
        PreviewRuntime.presentRequestedPreview()
    }

    /// 关闭当前预览窗口后结束独立预览进程。
    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        true
    }
}
