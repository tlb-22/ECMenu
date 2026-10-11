/**
 为压缩流程装配图像转换、批次目录创建、JPEG 排他写入与文件时间设置。
 目录和文件均按统一冲突规则排他创建，已有内容的所有权留在用户文件系统。
 */

import Darwin
import Foundation

extension ImageCompressionPlatform {
    nonisolated static var system: Self {
        Self(
            encodedJPEG: ImageCompressionTranscoder.encodedJPEG,
            prepareOutputDirectory: createOutputDirectory,
            writeJPEG: writeJPEGWithoutOverwriting,
            setFileDates: { url, date in
                try FileManager.default.setAttributes(
                    [.creationDate: date, .modificationDate: date],
                    ofItemAtPath: url.path
                )
            }
        )
    }

    /// 每批在源目录下排他创建新目录，文件或目录占用候选名时继续递增。
    private nonisolated static func createOutputDirectory(in sourceDirectory: URL) throws -> URL {
        let preferredURL = sourceDirectory.appendingPathComponent("compressed", isDirectory: true)
        for candidateURL in FileCollisionNaming.candidateURLs(for: preferredURL) {
            let errorCode = candidateURL.withUnsafeFileSystemRepresentation { path -> Int32? in
                guard let path else {
                    preconditionFailure("Compression output must have a file-system path")
                }
                return mkdir(path, 0o777) == 0 ? nil : errno
            }
            guard let errorCode else { return candidateURL }
            guard errorCode == EEXIST else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// 编码结束后逐个排他尝试候选名，系统报告冲突时继续。
    private nonisolated static func writeJPEGWithoutOverwriting(
        _ data: Data,
        for sourceURL: URL,
        in directoryURL: URL
    ) throws -> URL {
        let preferredURL = directoryURL
            .appendingPathComponent(sourceURL.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("jpg")
        for candidateURL in FileCollisionNaming.candidateURLs(for: preferredURL) {
            do {
                try data.write(to: candidateURL, options: .withoutOverwriting)
                return candidateURL
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }
}
