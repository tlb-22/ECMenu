/**
 查询真实 Finder 自动化需要的辅助功能与屏幕录制权限，并按显式请求提示系统授权。
 权限事实与查询入口集中在开发工具边界，生产应用不依赖这些授权。
 */

@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation

struct PermissionReport {
    let accessibility: Bool
    let screenCapture: Bool

    static func current(requestIfNeeded: Bool = false) -> PermissionReport {
        let accessibility: Bool
        if requestIfNeeded {
            let options = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
            ] as CFDictionary
            accessibility = AXIsProcessTrustedWithOptions(options)
        } else {
            accessibility = AXIsProcessTrusted()
        }

        let screenCapture = CGPreflightScreenCaptureAccess()
            || (requestIfNeeded && CGRequestScreenCaptureAccess())
        return PermissionReport(
            accessibility: accessibility,
            screenCapture: screenCapture
        )
    }

    var isReady: Bool { accessibility && screenCapture }
}

