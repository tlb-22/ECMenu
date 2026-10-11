/**
 为需要避免覆盖的文件和目录输出生成确定性的冲突候选名称。
 以纯函数处理已有 copy 后缀和递增序号，候选是否可写由系统边界判断。
 */

import Foundation

// MARK: - ==================== 文件冲突命名 ====================

/// 为所有不允许覆盖的输出统一生成 `_copy` 冲突候选名称。
nonisolated enum FileCollisionNaming {
    /// 根据首选 URL 和从 `1` 开始的候选序号构造确定性 URL。
    /// - Parameters:
    ///   - preferredURL: 没有冲突时使用的完整文件或目录 URL。
    ///   - sequenceNumber: `1` 保留首选名称，后续依次使用 `_copy`、`_copy2`。
    /// - Returns: 不读取文件系统的候选 URL。
    static func candidateURL(
        for preferredURL: URL,
        sequenceNumber: Int
    ) -> URL {
        precondition(sequenceNumber >= 1)

        guard sequenceNumber > 1 else {
            return preferredURL
        }

        let originalStem = preferredURL
            .deletingPathExtension()
            .lastPathComponent
        let parsedStem = parseCopySuffix(originalStem)
        let offset = sequenceNumber - 1
        let candidateBase: String
        let copyNumber: Int
        if let existingCopyNumber = parsedStem.copyNumber {
            let remainingNumericCandidates = Int.max - existingCopyNumber
            if offset <= remainingNumericCandidates {
                candidateBase = parsedStem.base
                copyNumber = existingCopyNumber + offset
            } else {
                // 用户文件名中的编号已经无法继续递增时，把完整原名视为
                // 新基础名；第一项回退候选从 `_copy` 重新开始。
                candidateBase = originalStem
                copyNumber = offset - remainingNumericCandidates
            }
        } else {
            candidateBase = parsedStem.base
            copyNumber = offset
        }

        let suffix = copyNumber == 1 ? "_copy" : "_copy\(copyNumber)"
        let pathExtension = preferredURL.pathExtension
        let filename = pathExtension.isEmpty
            ? candidateBase + suffix
            : candidateBase + suffix + "." + pathExtension
        return preferredURL
            .deletingLastPathComponent()
            .appendingPathComponent(filename)
    }

    /// 惰性生成首选名称及其全部冲突候选，不读取文件系统。
    /// - Parameter preferredURL: 没有冲突时使用的完整文件 URL。
    /// - Returns: 原名、`_copy`、`_copy2` 顺序的惰性 URL 序列。
    static func candidateURLs(
        for preferredURL: URL
    ) -> LazyMapSequence<ClosedRange<Int>, URL> {
        (1...Int.max).lazy.map { sequenceNumber in
            candidateURL(
                for: preferredURL,
                sequenceNumber: sequenceNumber
            )
        }
    }

    // MARK: - ==================== 纯函数：识别已有 copy 后缀 ====================

    /// 已经归一化的基础名和可继续递增的 copy 序号。
    private struct ParsedStem {
        /// 删除有效 `_copy` 后缀后的原始基础名。
        let base: String

        /// `_copy` 对应 `1`，`_copy2` 对应 `2`；没有有效后缀时为 `nil`。
        let copyNumber: Int?
    }

    /// 识别名称末尾由本规则生成的 `_copy` 或 `_copyN`。
    /// - Parameter stem: 不含最后一个扩展名的文件基础名。
    /// - Returns: 可用于继续编号的归一化结果。
    private static func parseCopySuffix(_ stem: String) -> ParsedStem {
        guard
            let markerRange = stem.range(of: "_copy", options: .backwards),
            markerRange.lowerBound != stem.startIndex
        else {
            return ParsedStem(base: stem, copyNumber: nil)
        }

        let numericSuffix = stem[markerRange.upperBound...]
        let copyNumber: Int?
        if numericSuffix.isEmpty {
            copyNumber = 1
        } else if
            numericSuffix.allSatisfy(\.isNumber),
            let value = Int(numericSuffix),
            value >= 2
        {
            copyNumber = value
        } else {
            copyNumber = nil
        }

        guard let copyNumber else {
            return ParsedStem(base: stem, copyNumber: nil)
        }
        return ParsedStem(
            base: String(stem[..<markerRange.lowerBound]),
            copyNumber: copyNumber
        )
    }
}
