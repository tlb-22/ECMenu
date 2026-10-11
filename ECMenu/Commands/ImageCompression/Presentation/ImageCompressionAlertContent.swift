/**
 根据图片压缩批次结果生成本地化告警内容。
 集中处理失败数量、目标名称和系统原因的用户可读表达。
 */

import Foundation

/// 把压缩失败与已经生成 JPG 后的时间属性问题分别汇总。
nonisolated enum ImageCompressionAlertContent {
    /// 区分问题是否只影响已处理图片中的一部分。
    private enum IssueScope {
        case all
        case partial
    }

    private enum AccessFailure {
        case read
        case write
    }

    static func make(
        for report: ImageCompressionReport,
        locale: Locale = .current
    ) -> CommandAlertContent? {
        let permissionFailures = report.failures.filter {
            $0.kind == .permissionDenied || $0.kind == .readOnlyFileSystem
        }
        let unreadableImages = permissionFailures.compactMap { failure -> URL? in
            guard case .source = failure else { return nil }
            return failure.sourceURL
        }
        let imagesWithUnwritableFolders = permissionFailures.compactMap { failure -> URL? in
            guard case .destination = failure else { return nil }
            return failure.sourceURL
        }
        let fileDateIssues = report.outputs.filter { $0.fileDateError != nil }

        var lines: [String] = []
        for (access, images) in [
            (AccessFailure.read, unreadableImages),
            (AccessFailure.write, imagesWithUnwritableFolders),
        ] where !images.isEmpty {
            lines.append(compressionPermissionBody(
                access: access,
                scope: report.outputURLs.isEmpty ? .all : .partial,
                subject: CommandAlertText.subject(for: images),
                locale: locale
            ))
        }

        if !fileDateIssues.isEmpty {
            let subject = CommandAlertText.subject(
                for: fileDateIssues.map(\.url)
            )
            let scope: IssueScope = fileDateIssues.count < report.items.count
                ? .partial
                : .all
            lines.append(
                fileDateBody(
                    scope: scope,
                    subject: subject,
                    locale: locale
                )
            )
        }

        guard !lines.isEmpty else {
            return nil
        }
        return CommandAlertContent(
            body: lines.joined(separator: "\n"),
            locale: locale
        )
    }

    /// 读取与目录写入权限分别汇总，每种语义使用完整本地化句式。
    private static func compressionPermissionBody(
        access: AccessFailure,
        scope: IssueScope,
        subject: CommandAlertSubject,
        locale: Locale
    ) -> String {
        let resource: LocalizedStringResource
        switch (access, scope, subject) {
        case (.read, .all, .named(let name)):
            resource = LocalizedStringResource(
                "alert.imageCompression.readPermission.all.named",
                defaultValue: "Couldn’t compress “\(name)” because it can’t be read.",
                locale: locale,
                comment: "The named image could not be compressed because it cannot be read"
            )
        case (.read, .all, .counted(let count)):
            resource = LocalizedStringResource(
                "alert.imageCompression.readPermission.all.counted",
                defaultValue: "Couldn’t compress the selected images because \(count) images can’t be read.",
                locale: locale,
                comment: "No selected images could be compressed; the argument counts unreadable images"
            )
        case (.read, .partial, .named(let name)):
            resource = LocalizedStringResource(
                "alert.imageCompression.readPermission.partial.named",
                defaultValue: "Some images couldn’t be compressed because “\(name)” can’t be read.",
                locale: locale,
                comment: "Other images were compressed, but the named image cannot be read"
            )
        case (.read, .partial, .counted(let count)):
            resource = LocalizedStringResource(
                "alert.imageCompression.readPermission.partial.counted",
                defaultValue: "Some images couldn’t be compressed because \(count) images can’t be read.",
                locale: locale,
                comment: "Other images were compressed; the argument counts unreadable images"
            )
        case (.write, .all, .named(let name)):
            resource = LocalizedStringResource(
                "alert.imageCompression.writePermission.all.named",
                defaultValue: "Couldn’t compress “\(name)” because its output folder isn’t writable.",
                locale: locale,
                comment: "The named image could not be compressed because its output folder is not writable"
            )
        case (.write, .all, .counted(let count)):
            resource = LocalizedStringResource(
                "alert.imageCompression.writePermission.all.counted",
                defaultValue: "Couldn’t compress the selected images because the output folders for \(count) images aren’t writable.",
                locale: locale,
                comment: "No selected images could be compressed; the argument counts images whose output folders are not writable"
            )
        case (.write, .partial, .named(let name)):
            resource = LocalizedStringResource(
                "alert.imageCompression.writePermission.partial.named",
                defaultValue: "Some images couldn’t be compressed because the output folder for “\(name)” isn’t writable.",
                locale: locale,
                comment: "Other images were compressed, but the output folder for the named image is not writable"
            )
        case (.write, .partial, .counted(let count)):
            resource = LocalizedStringResource(
                "alert.imageCompression.writePermission.partial.counted",
                defaultValue: "Some images couldn’t be compressed because the output folders for \(count) images aren’t writable.",
                locale: locale,
                comment: "Other images were compressed; the argument counts images whose output folders are not writable"
            )
        }
        return String(localized: resource)
    }

    /// 已写出 JPG 的时间属性问题按完整句式覆盖全部/部分和名称/数量。
    private static func fileDateBody(
        scope: IssueScope,
        subject: CommandAlertSubject,
        locale: Locale
    ) -> String {
        let resource: LocalizedStringResource
        switch (scope, subject) {
        case (.all, .named(let name)):
            resource = LocalizedStringResource(
                "alert.imageCompression.fileDates.all.named",
                defaultValue: "“\(name)” was compressed, but its date attributes couldn’t be updated.",
                locale: locale,
                comment: "The named image was compressed, but its creation and modification dates could not be updated"
            )
        case (.all, .counted(let count)):
            resource = LocalizedStringResource(
                "alert.imageCompression.fileDates.all.counted",
                defaultValue: "The images were compressed, but the date attributes of \(count) images couldn’t be updated.",
                locale: locale,
                comment: "All processed images have date-attribute problems; the argument is the affected image count"
            )
        case (.partial, .named(let name)):
            resource = LocalizedStringResource(
                "alert.imageCompression.fileDates.partial.named",
                defaultValue: "Some images were compressed, but the date attributes of “\(name)” couldn’t be updated.",
                locale: locale,
                comment: "Other images completed normally, but the named compressed image has a date-attribute problem"
            )
        case (.partial, .counted(let count)):
            resource = LocalizedStringResource(
                "alert.imageCompression.fileDates.partial.counted",
                defaultValue: "Some images were compressed, but the date attributes of \(count) images couldn’t be updated.",
                locale: locale,
                comment: "Other images completed normally; the argument is the number of compressed images with date-attribute problems"
            )
        }
        return String(localized: resource)
    }
}
