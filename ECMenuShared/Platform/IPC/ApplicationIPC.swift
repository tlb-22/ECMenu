/**
 从签名覆盖的产品 Bundle 解析当前环境的双方身份与 App Group，并定位组容器内的通信端点。
 缺失构建身份是实现不变量失败，容器暂不可用则作为连接初始化错误交给调用者。
 */

import Foundation

/// 通过所属代码定位产品 Bundle，使主应用与 Finder Extension 各自读取签名覆盖的身份配置。
nonisolated private final class ApplicationIPCBundleToken {}

/// 主应用与 Finder Extension 共享的定向本地 IPC 常量。
nonisolated enum ApplicationIPC {
    /// 当前构建配置注入的 macOS Team-ID 风格 App Group。
    static let applicationGroupIdentifier = requiredInfoString(
        forKey: "ECMApplicationGroupIdentifier"
    )

    /// App Group 容器内的唯一 Unix-domain socket 叶名。
    static let socketName = "ipc"

    /// Finder Extension 校验主应用时要求的精确 signing identifier。
    static let applicationSigningIdentifier = requiredInfoString(
        forKey: "ECMApplicationSigningIdentifier"
    )

    /// 主应用校验 Finder Extension 时要求的精确 signing identifier。
    static let finderExtensionSigningIdentifier = requiredInfoString(
        forKey: "ECMFinderExtensionSigningIdentifier"
    )

    /// 通过系统 API 获取当前用户的 App Group 容器和 socket 路径。
    static func socketURL(
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: applicationGroupIdentifier
        ) else {
            throw ApplicationIPCError.applicationGroupUnavailable
        }
        return containerURL.appendingPathComponent(
            socketName,
            isDirectory: false
        )
    }

    /// 从签名覆盖的构建产物 Info.plist 读取不可缺失的身份配置。
    private static func requiredInfoString(forKey key: String) -> String {
        let productBundle = Bundle(for: ApplicationIPCBundleToken.self)
        guard
            let value = productBundle.object(
                forInfoDictionaryKey: key
            ) as? String,
            !value.isEmpty,
            !value.contains("$(")
        else {
            preconditionFailure(
                "Missing or unresolved build identity value for \(key)"
            )
        }
        return value
    }
}
