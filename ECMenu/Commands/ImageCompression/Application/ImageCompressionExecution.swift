/**
 按压缩计划逐项读取、转换并写出图片，汇总成功、失败与取消结果。
 通过注入的平台操作执行副作用，并在项目边界报告进度与检查取消。
 */

import Foundation

/// 压缩所需的目录创建、图像编码、文件写入与日期设置边界。
nonisolated struct ImageCompressionPlatform: Sendable {
    let encodedJPEG: @Sendable (URL, ImageCompressionSettings) throws -> Data
    let prepareOutputDirectory: @Sendable (URL) throws -> URL
    let writeJPEG: @Sendable (Data, URL, URL) throws -> URL
    let setFileDates: @Sendable (URL, Date) throws -> Void
}

/// 在项目边界处理取消，逐项转换并排他写入，保留全部已生成输出。
nonisolated enum ImageCompressionExecution {
    /// 每个源父目录在本批次中只创建一次输出目录，或保存一次创建失败。
    private enum OutputDirectory {
        case created(URL)
        case failed(SystemErrorSnapshot)
    }

    static func execute(
        _ plan: ImageCompressionPlan,
        platform: ImageCompressionPlatform,
        progress: ContextCommandProgressReporter? = nil
    ) async -> ImageCompressionReport {
        var items: [ImageCompressionItemResult] = []
        var wasCancelled = false
        var outputDirectories: [URL: OutputDirectory] = [:]

        for item in plan.items {
            if let progress, await progress.isCancellationRequested {
                wasCancelled = true
                break
            }
            guard !Task.isCancelled else { break }

            items.append(autoreleasepool {
                execute(item, settings: plan.settings, platform: platform,
                        outputDirectories: &outputDirectories)
            })
            if let progress {
                await progress.advance()
            }
        }

        return ImageCompressionReport(items: items, wasCancelled: wasCancelled)
    }

    private static func execute(
        _ item: ImageCompressionItemPlan,
        settings: ImageCompressionSettings,
        platform: ImageCompressionPlatform,
        outputDirectories: inout [URL: OutputDirectory]
    ) -> ImageCompressionItemResult {
        let jpegData: Data
        do {
            jpegData = try platform.encodedJPEG(item.sourceURL, settings)
        } catch {
            return .failed(.source(
                sourceURL: item.sourceURL,
                stage: (error as? ImageCompressionProcessingError)?.stage ?? .decode,
                error: SystemErrorSnapshot(capturing: error)
            ))
        }

        let sourceDirectory = item.sourceURL.deletingLastPathComponent()
        let directory: OutputDirectory
        if let existing = outputDirectories[sourceDirectory] {
            directory = existing
        } else {
            do {
                directory = .created(try platform.prepareOutputDirectory(sourceDirectory))
            } catch {
                directory = .failed(SystemErrorSnapshot(capturing: error))
            }
            outputDirectories[sourceDirectory] = directory
        }

        let outputDirectory: URL
        switch directory {
        case .created(let url):
            outputDirectory = url
        case .failed(let error):
            return .failed(.destination(
                sourceURL: item.sourceURL,
                directoryURL: sourceDirectory,
                error: error
            ))
        }

        let outputURL: URL
        do {
            outputURL = try platform.writeJPEG(jpegData, item.sourceURL, outputDirectory)
        } catch {
            return .failed(.destination(
                sourceURL: item.sourceURL,
                directoryURL: outputDirectory,
                error: SystemErrorSnapshot(capturing: error)
            ))
        }

        let fileDateError: SystemErrorSnapshot?
        do {
            try platform.setFileDates(outputURL, item.outputDate)
            fileDateError = nil
        } catch {
            fileDateError = SystemErrorSnapshot(capturing: error)
        }
        return .output(ImageCompressionOutput(url: outputURL, fileDateError: fileDateError))
    }
}
