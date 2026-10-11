/**
 把两种语言的设置页和 Finder 菜单截图组合为 README 总览 PNG。
 左侧纵向排列三个设置页，右侧展示展开的 Finder 菜单；两种语言共用 5:4 透明画布。
 */

import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

private enum CompositionFailure: Error, CustomStringConvertible {
    case usage
    case outputDirectoryUnavailable(String)
    case imageUnreadable(String)
    case imageHasNoAlpha(String)
    case canvasUnavailable
    case outputUnavailable(String)
    case outputWriteFailed(String)

    var description: String {
        switch self {
        case .usage:
            "Usage: READMEOverviewComposer <output-directory> "
                + "<en-general> <en-context-menu> <en-templates> <en-finder-menu> "
                + "<zh-general> <zh-context-menu> <zh-templates> <zh-finder-menu>"
        case let .outputDirectoryUnavailable(path):
            "Output directory is unavailable: \(path)"
        case let .imageUnreadable(path):
            "Could not read a source image: \(path)"
        case let .imageHasNoAlpha(path):
            "Source image has no alpha channel: \(path)"
        case .canvasUnavailable:
            "Could not create the overview image canvas."
        case let .outputUnavailable(path):
            "Could not create the overview image destination: \(path)"
        case let .outputWriteFailed(path):
            "Could not write the overview image: \(path)"
        }
    }
}

private struct SourceImage {
    let image: CGImage

    init(url: URL) throws {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw CompositionFailure.imageUnreadable(url.path)
        }
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast:
            break
        case .none, .noneSkipFirst, .noneSkipLast, .alphaOnly:
            throw CompositionFailure.imageHasNoAlpha(url.path)
        @unknown default:
            throw CompositionFailure.imageHasNoAlpha(url.path)
        }
        self.image = image
    }
}

/// 来源图按三个设置页、Finder 菜单的顺序输入，并采用固定显示比例。
private enum OverviewPanel: CaseIterable {
    case generalSettings
    case contextMenuSettings
    case newFileTemplateSettings
    case finderMenu

    /// Finder 菜单是产品主体，在总览图中使用更大的显示比例。
    var scale: CGFloat {
        switch self {
        case .generalSettings, .contextMenuSettings, .newFileTemplateSettings:
            1
        case .finderMenu:
            1.8
        }
    }
}

/// 一张来源图在最终画布上的明确像素尺寸。
private struct RenderedImage {
    let image: CGImage
    let width: Int
    let height: Int

    init(source: SourceImage, scale: CGFloat) {
        image = source.image
        width = Int((CGFloat(image.width) * scale).rounded())
        height = Int((CGFloat(image.height) * scale).rounded())
    }
}

private struct OverviewComposition {
    static let edgePadding = 64
    static let columnSpacing = 128
    static let rowSpacing = 64

    let english: [SourceImage]
    let simplifiedChinese: [SourceImage]

    init(englishURLs: [URL], simplifiedChineseURLs: [URL]) throws {
        precondition(englishURLs.count == simplifiedChineseURLs.count)
        precondition(englishURLs.count == OverviewPanel.allCases.count)

        english = try englishURLs.map(SourceImage.init(url:))
        simplifiedChinese = try simplifiedChineseURLs.map(
            SourceImage.init(url:)
        )
    }

    func write(to outputDirectory: URL) throws {
        let english = renderedPanels(from: english)
        let simplifiedChinese = renderedPanels(from: simplifiedChinese)
        let overviews = [english, simplifiedChinese]
        let settingsWidth = overviews
            .flatMap { $0.dropLast() }
            .map(\.width)
            .max()!
        let settingsRowHeights = english.dropLast().indices.map { index in
            overviews.map { $0[index].height }.max()!
        }
        let settingsHeight = settingsRowHeights.reduce(0, +)
            + Self.rowSpacing * (settingsRowHeights.count - 1)
        let menuWidth = overviews.map { $0.last!.width }.max()!
        let menuHeight = overviews.map { $0.last!.height }.max()!
        let contentHeight = max(settingsHeight, menuHeight)
        let minimumWidth = Self.edgePadding * 2
            + settingsWidth + Self.columnSpacing + menuWidth
        let minimumHeight = Self.edgePadding * 2 + contentHeight
        // 用整数像素补足画布，保证宽高严格为 5:4，并完整保留来源截图。
        let canvasUnit = max((minimumWidth + 4) / 5, (minimumHeight + 3) / 4)
        let canvasWidth = canvasUnit * 5
        let canvasHeight = canvasUnit * 4

        try write(
            panels: english,
            settingsWidth: settingsWidth,
            settingsRowHeights: settingsRowHeights,
            settingsHeight: settingsHeight,
            menuWidth: menuWidth,
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight,
            contentHeight: contentHeight,
            to: outputDirectory.appendingPathComponent("overview-en.png")
        )
        try write(
            panels: simplifiedChinese,
            settingsWidth: settingsWidth,
            settingsRowHeights: settingsRowHeights,
            settingsHeight: settingsHeight,
            menuWidth: menuWidth,
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight,
            contentHeight: contentHeight,
            to: outputDirectory.appendingPathComponent(
                "overview-zh-Hans.png"
            )
        )
    }

    /// 将页面声明转换为每种语言共用的显示比例。
    private func renderedPanels(
        from sources: [SourceImage]
    ) -> [RenderedImage] {
        zip(OverviewPanel.allCases, sources).map { pair in
            RenderedImage(source: pair.1, scale: pair.0.scale)
        }
    }

    private func write(
        panels: [RenderedImage],
        settingsWidth: Int,
        settingsRowHeights: [Int],
        settingsHeight: Int,
        menuWidth: Int,
        canvasWidth: Int,
        canvasHeight: Int,
        contentHeight: Int,
        to outputURL: URL
    ) throws {
        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.displayP3),
            let context = CGContext(
                data: nil,
                width: canvasWidth,
                height: canvasHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw CompositionFailure.canvasUnavailable
        }

        context.clear(
            CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
        )
        context.interpolationQuality = .high
        let contentX = (canvasWidth - settingsWidth - Self.columnSpacing - menuWidth) / 2
        let contentY = (canvasHeight - contentHeight) / 2
        var rowTop = contentY + (contentHeight + settingsHeight) / 2
        for (index, source) in panels.dropLast().enumerated() {
            let rowHeight = settingsRowHeights[index]
            let imageX = contentX
                + (settingsWidth - source.width) / 2
            let imageY = rowTop - rowHeight
                + (rowHeight - source.height) / 2
            context.draw(
                source.image,
                in: CGRect(
                    x: imageX,
                    y: imageY,
                    width: source.width,
                    height: source.height
                )
            )
            rowTop -= rowHeight + Self.rowSpacing
        }
        let menu = panels.last!
        context.draw(
            menu.image,
            in: CGRect(
                x: contentX + settingsWidth + Self.columnSpacing
                    + (menuWidth - menu.width) / 2,
                y: contentY + (contentHeight - menu.height) / 2,
                width: menu.width,
                height: menu.height
            )
        )

        guard let outputImage = context.makeImage() else {
            throw CompositionFailure.canvasUnavailable
        }
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw CompositionFailure.outputUnavailable(outputURL.path)
        }
        CGImageDestinationAddImage(destination, outputImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CompositionFailure.outputWriteFailed(outputURL.path)
        }
    }
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 9 else {
        throw CompositionFailure.usage
    }

    let outputDirectory = URL(fileURLWithPath: arguments[0])
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(
        atPath: outputDirectory.path,
        isDirectory: &isDirectory
    ), isDirectory.boolValue else {
        throw CompositionFailure.outputDirectoryUnavailable(
            outputDirectory.path
        )
    }

    let composition = try OverviewComposition(
        englishURLs: arguments[1...4].map(URL.init(fileURLWithPath:)),
        simplifiedChineseURLs: arguments[5...8].map(
            URL.init(fileURLWithPath:)
        )
    )
    try composition.write(to: outputDirectory)
} catch {
    let message = if let failure = error as? CompositionFailure {
        failure.description
    } else {
        error.localizedDescription
    }
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    Darwin.exit(EXIT_FAILURE)
}
