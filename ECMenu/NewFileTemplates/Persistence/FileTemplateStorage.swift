/**
 封装模板索引、内容副本和库目录的实际文件系统操作。
 负责安全定位、原子索引保存、排他副本创建与删除，并返回类型化存储失败。
 */

import Darwin
import Foundation
import OSLog

/// 模板库专用的同步文件边界；不持有索引缓存，调用者负责串行访问。
nonisolated struct FileTemplateStorage {
    static var defaultRootURL: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent(ApplicationIPC.applicationSigningIdentifier, isDirectory: true)
            .appendingPathComponent("FileTemplates", isDirectory: true)
    }

    private let fileManager = FileManager.default
    private static let logger = Logger(
        subsystem: ApplicationLogging.subsystem,
        category: "NewFileTemplates"
    )

    /// 在实际访问时读取当前产品身份，定位唯一的生产模板库。
    private var rootURL: URL {
        Self.defaultRootURL
    }

    private var indexURL: URL {
        rootURL.appendingPathComponent("index.json", isDirectory: false)
    }

    private var filesURL: URL {
        rootURL.appendingPathComponent("Files", isDirectory: true)
    }

    func directoryURL(for file: FileTemplateFileReference) -> URL {
        filesURL.appendingPathComponent(file.id.uuidString, isDirectory: true)
    }

    func contentURL(for file: FileTemplateFileReference) -> URL {
        directoryURL(for: file).appendingPathComponent(file.fileName, isDirectory: false)
    }

    /// nil 只表示整个模板库尚未创建；已有根目录缺失索引仍是读取失败。
    func readIndex() throws -> Data? {
        do {
            return try Data(contentsOf: indexURL)
        } catch {
            if isMissingFile(error), !fileManager.fileExists(atPath: rootURL.path) {
                return nil
            }
            throw failure(.readIndex, at: indexURL, error: error)
        }
    }

    func saveContent(_ data: Data, named fileName: String) throws -> FileTemplateFileReference {
        let file = try FileTemplateFileReference(fileName: fileName)
        let directory = directoryURL(for: file)
        do {
            try fileManager.createDirectory(at: filesURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        } catch {
            throw failure(.prepareDirectory, at: directory, error: error)
        }
        let url = contentURL(for: file)
        do {
            try data.write(to: url, options: .withoutOverwriting)
        } catch {
            cleanContent(at: directory)
            throw failure(.saveContent, at: url, error: error)
        }
        return file
    }

    func commit(_ updated: [FileTemplateRecord]) throws {
        // 编码只有已验证值的固定结构，不含可能由用户输入触发的编码失败。
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try! encoder.encode(FileTemplateIndex(templates: updated))
        do {
            try data.write(to: indexURL, options: .atomic)
        } catch {
            throw failure(.saveIndex, at: indexURL, error: error)
        }
    }

    func readContent(at url: URL) throws -> Data {
        try withRegularFile(at: url) { handle in
            do {
                return try handle.readToEnd() ?? Data()
            } catch {
                throw failure(.readContent, at: url, error: error)
            }
        }
    }

    func validateRegularFile(at url: URL) throws {
        try withRegularFile(at: url) { _ in () }
    }

    /// O_NOFOLLOW 与 fstat 约束实际打开的对象，避免符号链接或特殊文件被读取。
    private func withRegularFile<T>(at url: URL, body: (FileHandle) throws -> T) throws -> T {
        guard url.isFileURL else {
            throw FileTemplateLibraryError.unsupportedFile(url)
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw FileTemplateLibraryError.unsupportedFile(url)
            }
            throw failure(.readContent, at: url, error: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0 else {
            throw failure(.readContent, at: url, error: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
        }
        guard attributes.st_mode & S_IFMT == S_IFREG else {
            throw FileTemplateLibraryError.unsupportedFile(url)
        }
        return try body(handle)
    }

    func removeContent(at url: URL) throws(FileTemplateCleanupIssue) {
        do {
            try fileManager.removeItem(at: url)
        } catch {
            guard !isMissingFile(error) else { return }
            throw FileTemplateCleanupIssue(url: url, cause: SystemErrorSnapshot(capturing: error))
        }
    }

    func cleanContent(at url: URL) {
        do {
            try removeContent(at: url)
        } catch {
            Self.logger.error("Could not clean unused template files: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 只在恢复索引时清理孤儿，保留有效索引引用的内容目录。
    func cleanUnreferencedFiles(referencedBy records: [FileTemplateRecord]) {
        let referencedNames = Set(records.map { $0.file.id.uuidString })
        do {
            let urls = try fileManager.contentsOfDirectory(at: filesURL, includingPropertiesForKeys: nil)
            for url in urls where !referencedNames.contains(url.lastPathComponent) {
                cleanContent(at: url)
            }
        } catch {
            Self.logger.error("Could not clean unused template files: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func failure(
        _ operation: FileTemplateFileOperation,
        at url: URL,
        error: Error
    ) -> FileTemplateLibraryError {
        .fileOperation(operation, url: url, cause: SystemErrorSnapshot(capturing: error))
    }

    private func isMissingFile(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && (
            error.code == CocoaError.fileReadNoSuchFile.rawValue ||
            error.code == CocoaError.fileNoSuchFile.rawValue
        )) || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
    }
}
