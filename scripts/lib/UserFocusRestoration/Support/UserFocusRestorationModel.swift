/**
 定义用户前台应用身份，以及自动化结束后允许恢复的目标选择规则。
 依据不可变进程事实拒绝 PID 复用，并单独处理可唯一辨认的 Finder 重启实例。
 */

import Foundation

/// 足以区分一个运行中应用实例、并拒绝 PID 复用的稳定身份。
struct UserFocusApplicationIdentity: Codable, Equatable {
    let processIdentifier: Int32
    let launchTime: TimeInterval?
    let bundleIdentifier: String?
    let executablePath: String?
}

/// 手动开发命令结束后对当前运行应用集合做出的有限决定。
enum UserFocusRestorationResolution: Equatable {
    case application(UserFocusApplicationIdentity)
    case unavailable
}

/// 只根据不可变应用身份选择允许恢复的目标。
enum UserFocusRestorationResolver {
    private static let finderBundleIdentifier = "com.apple.finder"

    static func resolve(
        snapshot: UserFocusApplicationIdentity,
        candidates: [UserFocusApplicationIdentity]
    ) -> UserFocusRestorationResolution {
        if let exactApplication = candidates.first(where: {
            isSameProcess($0, as: snapshot)
        }) {
            return .application(exactApplication)
        }

        guard snapshot.bundleIdentifier == finderBundleIdentifier else {
            return .unavailable
        }
        let finderReplacements = candidates.filter {
            hasSameStableIdentity($0, as: snapshot)
        }
        guard finderReplacements.count == 1 else {
            return .unavailable
        }
        return .application(finderReplacements[0])
    }

    private static func isSameProcess(
        _ candidate: UserFocusApplicationIdentity,
        as snapshot: UserFocusApplicationIdentity
    ) -> Bool {
        guard
            candidate.processIdentifier == snapshot.processIdentifier,
            let launchTime = snapshot.launchTime,
            candidate.launchTime == launchTime
        else {
            return false
        }
        return hasSameStableIdentity(candidate, as: snapshot)
    }

    private static func hasSameStableIdentity(
        _ candidate: UserFocusApplicationIdentity,
        as snapshot: UserFocusApplicationIdentity
    ) -> Bool {
        guard
            candidate.bundleIdentifier == snapshot.bundleIdentifier,
            candidate.executablePath == snapshot.executablePath
        else {
            return false
        }
        return snapshot.bundleIdentifier != nil
            || snapshot.executablePath != nil
    }
}
