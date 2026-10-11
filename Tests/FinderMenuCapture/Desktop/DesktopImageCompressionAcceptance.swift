/**
 独立生成图片输入，通过真实设置窗口验收取消、格式兼容、缩放、编码与持久化参数。
 操作仅经过桌面驱动，断言读取真实外部结果；证据与报告由验收会话统一拥有。
 */

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension DesktopAcceptanceSuite {
    private func image(_ url: URL, width: Int, height: Int, type: UTType = .png,
                       orientation: Int = 1, textured: Bool = false,
                       color: CGColor = CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 0.5)) throws {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw DesktopUI.Failure.assertion("Cannot construct independent image fixture")
        }
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if textured {
            var seed: UInt32 = 0xEC2026
            for y in stride(from: 0, to: height, by: 2) {
                for x in stride(from: 0, to: width, by: 2) {
                    seed = seed &* 1664525 &+ 1013904223
                    context.setFillColor(CGColor(red: CGFloat((seed >> 16) & 255) / 255,
                                                 green: CGFloat((seed >> 8) & 255) / 255,
                                                 blue: CGFloat(seed & 255) / 255, alpha: 1))
                    context.fill(CGRect(x: x, y: y, width: 2, height: 2))
                }
            }
        }
        guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw DesktopUI.Failure.assertion("Cannot encode independent image fixture")
        }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation,
                                                      kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "E2E private metadata"],
                                                      kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.42,
                                                                                     kCGImagePropertyGPSLatitudeRef: "N",
                                                                                     kCGImagePropertyGPSLongitude: 122.08,
                                                                                     kCGImagePropertyGPSLongitudeRef: "W"]] as CFDictionary)
        try DesktopUI.require(CGImageDestinationFinalize(destination), "Image fixture encoding failed")
    }

    private func animatedImage(_ url: URL) throws {
        let first = fixtureURL.appendingPathComponent("gif-first.png")
        let second = fixtureURL.appendingPathComponent("gif-second.png")
        try image(first, width: 320, height: 160, color: CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1))
        try image(second, width: 320, height: 160, color: CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 2, nil) else {
            throw DesktopUI.Failure.assertion("Cannot create GIF fixture")
        }
        for path in [first, second] {
            guard let source = CGImageSourceCreateWithURL(path as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw DesktopUI.Failure.assertion("Cannot decode independent GIF frame")
            }
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary)
        }
        try DesktopUI.require(CGImageDestinationFinalize(destination), "GIF fixture encoding failed")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) == 2,
              let firstFrame = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw DesktopUI.Failure.assertion("Independent GIF fixture must contain two decodable frames")
        }
        try DesktopUI.require(firstFrame.width == 320 && firstFrame.height == 160,
                              "Independent GIF first frame must have the expected source dimensions")
    }

    func compressImages() async throws {
        let directory = try directory("images")
        let large = directory.appendingPathComponent("large.png")
        let small = directory.appendingPathComponent("small.png")
        let heic = directory.appendingPathComponent("modern.heic")
        let gif = directory.appendingPathComponent("animated.gif")
        let rotated = directory.appendingPathComponent("rotated.jpg")
        try image(large, width: 320, height: 160)
        try image(small, width: 40, height: 20)
        try image(heic, width: 200, height: 100, type: .heic)
        try animatedImage(gif)
        try image(rotated, width: 320, height: 160, type: .jpeg, orientation: 6)
        guard let privateSource = CGImageSourceCreateWithURL(rotated as CFURL, nil),
              let privateProperties = CGImageSourceCopyPropertiesAtIndex(privateSource, 0, nil) as? [String: Any],
              let exif = privateProperties[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let gps = privateProperties[kCGImagePropertyGPSDictionary as String] as? [String: Any] else {
            throw DesktopUI.Failure.assertion("Independent JPEG fixture must carry real private EXIF and GPS metadata")
        }
        try assert(exif[kCGImagePropertyExifUserComment as String] != nil && gps[kCGImagePropertyGPSLatitude as String] != nil,
                   "Independent source JPEG contains actual private EXIF and GPS fields before compression")
        let originalLarge = try Data(contentsOf: large), originalSmall = try Data(contentsOf: small)
        let otherOriginals = try [heic, gif, rotated].map { ($0, try Data(contentsOf: $0)) }
        try await menu(try items([large]), evidence: "compression-cancel", requiredTitles: ["Compress Images"]) { session, snapshot in
            try assert(snapshot.titles.contains("Compress Images"), "Supported ordinary image exposes compression")
            try session.pressItem(named: "Compress Images")
            let field = try DesktopUI.find(compressionWindow(), role: kAXTextFieldRole)
            let slider = try DesktopUI.find(compressionWindow(), role: kAXSliderRole)
            try assert(try AXClient.string(kAXValueAttribute as CFString, of: field) == "1440"
                       && AXClient.integer(kAXValueAttribute as CFString, of: slider) == 8,
                       "Fresh compression settings match independently specified defaults")
            try DesktopUI.edit(field, in: axApp, value: "99", commitKey: CGKeyCode(kVK_Tab))
            try AXClient.setValue(NSNumber(value: 3), for: kAXValueAttribute as CFString, on: slider)
            try DesktopUI.press(DesktopUI.find(compressionWindow(), role: kAXButtonRole, name: "Cancel"))
            try waitForCompressionSettingsToClose()
            try assert(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("large.jpg").path), "Cancel creates no JPEG output")
        }
        let conflict = directory.appendingPathComponent("large.jpg")
        try Data("existing output".utf8).write(to: conflict)
        let expectedOutputs = ["animated.jpg", "large_copy.jpg", "modern.jpg", "rotated_copy.jpg", "small.jpg"].map { directory.appendingPathComponent($0) }
        try await menu(try items([large, small, heic, gif, rotated]), evidence: "compression-confirm", requiredTitles: ["Compress Images"]) { session, _ in
            try session.pressItem(named: "Compress Images")
            let field = try DesktopUI.find(compressionWindow(), role: kAXTextFieldRole)
            let slider = try DesktopUI.find(compressionWindow(), role: kAXSliderRole)
            try assert(try AXClient.string(kAXValueAttribute as CFString, of: field) == "1440"
                       && AXClient.integer(kAXValueAttribute as CFString, of: slider) == 8,
                       "Cancel discards edited width and quality instead of persisting them")
            try DesktopUI.edit(field, in: axApp, value: "80", commitKey: CGKeyCode(kVK_Tab))
            try AXClient.setValue(NSNumber(value: 6), for: kAXValueAttribute as CFString, on: slider)
            try await DesktopUI.screenshot(pid: app.processIdentifier, to: input.outputURL.appendingPathComponent("compression-settings.png"))
            try DesktopUI.press(DesktopUI.find(compressionWindow(), identifier: "image-compression-confirm"))
            let _: Bool = try DesktopUI.wait("Expected JPEG outputs did not appear", seconds: 20) {
                expectedOutputs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) } ? true : nil
            }
            let _: Bool = try DesktopUI.wait("Finder did not select every successful JPEG output") { try session.hasExactlySelectedItems(expectedOutputs) ? true : nil }
            try assert(true, "Finder selects the complete successful output set")
        }
        for (name, width, height) in [("large_copy.jpg", 80, 40), ("small.jpg", 40, 20), ("modern.jpg", 80, 40), ("animated.jpg", 80, 40), ("rotated_copy.jpg", 80, 160)] {
            let url = directory.appendingPathComponent(name)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let output = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
                throw DesktopUI.Failure.assertion("Actual JPEG is not independently decodable")
            }
            struct ImageEvidence: Encodable {
                let format: String?
                let width: Int
                let height: Int
                let exifKeys: [String]
                let hasGPS: Bool
                let creationTimestamp: TimeInterval?
                let modificationTimestamp: TimeInterval?
            }
            let dates = try url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let exifKeys = Set((properties[kCGImagePropertyExifDictionary as String] as? [String: Any])?.keys.map { $0 } ?? [])
            let evidence = ImageEvidence(format: CGImageSourceGetType(source) as String?, width: output.width,
                height: output.height, exifKeys: exifKeys.sorted(), hasGPS: properties[kCGImagePropertyGPSDictionary as String] != nil,
                creationTimestamp: dates.creationDate?.timeIntervalSince1970,
                modificationTimestamp: dates.contentModificationDate?.timeIntervalSince1970)
            try JSONEncoder().encode(evidence).write(to: input.outputURL.appendingPathComponent("\(name)-properties.json"))
            try assert(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier && output.width == width && output.height == height,
                       "\(name) is JPEG with independently expected dimensions")
            try assert(!exifKeys.contains(kCGImagePropertyExifUserComment as String)
                       && properties[kCGImagePropertyGPSDictionary as String] == nil,
                       "\(name) removes the independently embedded private EXIF comment and GPS metadata")
            try assert(dates.creationDate != nil && dates.creationDate == dates.contentModificationDate, "\(name) has matching creation and modification dates")
        }
        let dates = try expectedOutputs.map { try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate! }
        for index in 1..<dates.count {
            try assert(abs(dates[index].timeIntervalSince(dates[index - 1]) - 1) < 0.001, "Outputs receive one-second dates in independently expected Finder filename order")
        }
        let gifPixel = try rgbSample(directory.appendingPathComponent("animated.jpg"))
        try assert(zip(gifPixel, [51, 153, 204]).allSatisfy { pair in abs(pair.0 - pair.1) < 20 },
                   "Animated GIF output renders its blue first frame rather than the red second frame")
        let pixel = try rgbSample(directory.appendingPathComponent("large_copy.jpg"))
        try assert(abs(pixel[0] - 153) < 20 && abs(pixel[1] - 204) < 20 && abs(pixel[2] - 230) < 20,
                   "Transparent PNG pixels are composited over white in the actual JPEG")
        try assert(try Data(contentsOf: conflict) == Data("existing output".utf8), "Compression preserves conflicting existing output")
        try assert(try Data(contentsOf: large) == originalLarge && Data(contentsOf: small) == originalSmall, "Compression preserves source bytes")
        for (url, bytes) in otherOriginals {
            try assert(try Data(contentsOf: url) == bytes, "Compression preserves \(url.lastPathComponent) source bytes")
        }
        try await menu(try items([small]), evidence: "compression-persisted-settings", requiredTitles: ["Compress Images"]) { session, _ in
            try session.pressItem(named: "Compress Images")
            let field = try DesktopUI.find(compressionWindow(), role: kAXTextFieldRole)
            let slider = try DesktopUI.find(compressionWindow(), role: kAXSliderRole)
            try assert(try AXClient.string(kAXValueAttribute as CFString, of: field) == "80" && AXClient.integer(kAXValueAttribute as CFString, of: slider) == 6,
                       "Next real compression request restores confirmed width and JPG quality")
            try DesktopUI.press(DesktopUI.find(compressionWindow(), role: kAXButtonRole, name: "Cancel"))
            try waitForCompressionSettingsToClose()
        }
        try await menu(try items([large, directory.appendingPathComponent("anchor.txt")]), evidence: "compression-inapplicable", requiredTitles: ["Copy Path"]) { _, snapshot in
            try assert(!snapshot.titles.contains("Compress Images") && snapshot.titles.contains("Copy Path") && snapshot.titles.contains("Hide Items"), "Mixed image and plain-file selection omits compression while retaining applicable file commands")
        }
        try await compressionQuality()
        let expectedNames = Set(["anchor.txt", "large.png", "small.png", "modern.heic", "animated.gif", "rotated.jpg", "large.jpg"] + expectedOutputs.map(\.lastPathComponent))
        try assert(try Set(FileManager.default.contentsOfDirectory(atPath: directory.path)) == expectedNames,
                   "Completed image case contains exactly the original files, conflict and confirmed outputs; cancelled requests leave no delayed output")
    }

    private func compressionWindow() throws -> AXUIElement {
        try DesktopUI.find(axApp, role: kAXWindowRole, name: "Compress Images")
    }

    private func rgbSample(_ url: URL) throws -> [Int] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw DesktopUI.Failure.assertion("Cannot inspect the independently decoded image color sample")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        return [Int(bytes[0]), Int(bytes[1]), Int(bytes[2])]
    }

    private func waitForCompressionSettingsToClose() throws {
        let _: Bool = try DesktopUI.wait("Cancelled compression settings window did not close") {
            try DesktopUI.elements(axApp).contains { try DesktopUI.matches($0, identifier: "image-compression-confirm") } ? nil : true
        }
    }

    private func compressionQuality() async throws {
        let directory = try directory("compression-quality")
        let sourceURL = directory.appendingPathComponent("textured.png")
        try image(sourceURL, width: 512, height: 256, textured: true)
        let original = try Data(contentsOf: sourceURL)
        var sizes: [Int] = []
        for (quality, name) in [(2, "textured.jpg"), (10, "textured_copy.jpg")] {
            let outputURL = directory.appendingPathComponent(name)
            try await menu(try items([sourceURL]), evidence: "compression-quality-\(quality)", requiredTitles: ["Compress Images"]) { session, _ in
                try session.pressItem(named: "Compress Images")
                try DesktopUI.edit(DesktopUI.find(compressionWindow(), role: kAXTextFieldRole), in: axApp,
                                   value: "512", commitKey: CGKeyCode(kVK_Tab))
                let slider = try DesktopUI.find(compressionWindow(), role: kAXSliderRole)
                try AXClient.setValue(NSNumber(value: quality), for: kAXValueAttribute as CFString, on: slider)
                try await DesktopUI.screenshot(pid: app.processIdentifier,
                                               to: input.outputURL.appendingPathComponent("compression-quality-\(quality)-settings.png"))
                try DesktopUI.press(DesktopUI.find(compressionWindow(), identifier: "image-compression-confirm"))
                let _: Bool = try DesktopUI.wait("Actual quality comparison JPEG did not appear", seconds: 20) {
                    FileManager.default.fileExists(atPath: outputURL.path) ? true : nil
                }
                let _: Bool = try DesktopUI.wait("Finder did not select the quality comparison JPEG") {
                    try session.hasExactlySelectedItems([outputURL]) ? true : nil
                }
            }
            guard let source = CGImageSourceCreateWithURL(outputURL as CFURL, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw DesktopUI.Failure.assertion("Actual quality comparison output is not independently decodable")
            }
            try assert(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier
                       && decoded.width == 512 && decoded.height == 256,
                       "Quality \(quality) produces a decodable JPEG with unchanged dimensions")
            sizes.append(try Data(contentsOf: outputURL).count)
        }
        try Data("quality\tbytes\n2\t\(sizes[0])\n10\t\(sizes[1])\n".utf8)
            .write(to: input.outputURL.appendingPathComponent("compression-quality.tsv"))
        try assert(sizes[0] < sizes[1], "Lower confirmed quality reduces actual JPEG bytes for the same textured source")
        try assert(try Data(contentsOf: sourceURL) == original, "Both quality submissions preserve the source image bytes")
    }
}
