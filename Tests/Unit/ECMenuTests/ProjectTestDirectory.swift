/**
 为主应用中需要真实文件系统的测试创建项目内隔离工作目录。
 由源码位置定位仓库，将每次测试数据归入可重建的 scratch 测试产物。
 */

import Darwin
import Foundation

/// 为需要真实文件系统的主应用测试创建项目内隔离目录。
nonisolated enum ProjectTestDirectory {
    /// 当前仓库根目录，由本测试支持文件的稳定位置推导。
    private static let projectRootURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// 当前 test host 的单次运行目录。
    private static let unitRunDirectoryURL: URL = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"

        // 使用简短的 unit test 用途名，为 Unix socket 路径保留长度空间。
        let directoryName = "\(formatter.string(from: Date()))-ut-\(getpid())"
        return projectRootURL
            .appendingPathComponent(
                ".artifacts/scratch/tests",
                isDirectory: true
            )
            .appendingPathComponent(directoryName, isDirectory: true)
    }()

    private static let socketNameAllocator = SocketNameAllocator()

    /// 在当前单次 unit run 中创建一个不会与其他测试冲突的目录。
    /// - Returns: 已经存在、只属于当前调用的测试目录。
    static func makeUniqueDirectory() throws -> URL {
        let directoryURL = unitRunDirectoryURL
            .appendingPathComponent("fixtures", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        return directoryURL
    }

    /// 在 Unix `sun_path` 限制内创建项目内的短 socket 测试路径。
    static func makeUniqueSocketURL() throws -> URL {
        let socketURL = unitRunDirectoryURL.appendingPathComponent(
            socketNameAllocator.allocate(),
            isDirectory: false
        )

        let address = sockaddr_un()
        let maximumPathBytes = MemoryLayout.size(ofValue: address.sun_path)
        let pathBytesIncludingTerminator = socketURL.path.utf8CString.count
        guard pathBytesIncludingTerminator <= maximumPathBytes else {
            throw SocketPathTooLongError(
                path: socketURL.path,
                actualBytes: pathBytesIncludingTerminator,
                maximumBytes: maximumPathBytes
            )
        }

        try FileManager.default.createDirectory(
            at: unitRunDirectoryURL,
            withIntermediateDirectories: true
        )
        return socketURL
    }
}

nonisolated private final class SocketNameAllocator: @unchecked Sendable {
    private let lock = NSLock()
    private var nextValue = 0

    func allocate() -> String {
        lock.lock()
        defer { lock.unlock() }

        defer { nextValue += 1 }
        return String(nextValue, radix: 36)
    }
}

private struct SocketPathTooLongError: LocalizedError {
    let path: String
    let actualBytes: Int
    let maximumBytes: Int

    var errorDescription: String? {
        "Unix socket 测试路径超出 macOS sockaddr_un.sun_path 上限：" +
            "\(actualBytes) 字节（含结尾 NUL） > \(maximumBytes) 字节。" +
            "路径：\(path)"
    }
}
