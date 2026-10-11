/**
 为开发脚本提供前台应用快照、子进程启动和用户焦点恢复入口。
 核对应用实例身份后调用 AppKit 激活目标，并等待前台状态确认或报告失败。
 */

import AppKit
import Darwin
import Foundation

private enum UserFocusRestorationFailure: Error, CustomStringConvertible {
    case usage
    case snapshotEncodingFailed
    case snapshotUnreadable
    case targetChanged
    case systemCallFailed(String, String)
    case activationRejected(String)
    case activationTimedOut(String)

    var description: String {
        switch self {
        case .usage:
            "Usage: UserFocusRestorer <capture|restore snapshot|launch command>"
        case .snapshotEncodingFailed:
            "Could not encode the frontmost application snapshot."
        case .snapshotUnreadable:
            "Could not decode the frontmost application snapshot."
        case .targetChanged:
            "The selected focus restoration target changed before activation."
        case let .systemCallFailed(name, message):
            "\(name) failed: \(message)"
        case let .activationRejected(name):
            "macOS rejected the request to reactivate \(name)."
        case let .activationTimedOut(name):
            "Timed out while reactivating \(name)."
        }
    }
}

@main
private enum UserFocusRestorer {
    private static let activationTimeout: TimeInterval = 5

    static func main() {
        do {
            try run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            let message = if let failure =
                error as? UserFocusRestorationFailure
            {
                failure.description
            } else {
                error.localizedDescription
            }
            FileHandle.standardError.write(Data("\(message)\n".utf8))
            Darwin.exit(EXIT_FAILURE)
        }
    }

    private static func run(arguments: [String]) throws {
        switch arguments.first {
        case "capture" where arguments.count == 1:
            try capture()
        case "restore" where arguments.count == 2:
            try restore(encodedSnapshot: arguments[1])
        case "launch" where arguments.count >= 2:
            try launch(arguments: Array(arguments.dropFirst()))
        default:
            throw UserFocusRestorationFailure.usage
        }
    }

    private static func launch(arguments: [String]) throws {
        guard setsid() != -1 else {
            throw systemCallFailure("setsid")
        }

        var cArguments = arguments.map { strdup($0) }
        cArguments.append(nil)
        defer {
            for argument in cArguments {
                free(argument)
            }
        }

        let result = cArguments.withUnsafeMutableBufferPointer { buffer in
            execvp(buffer[0], buffer.baseAddress)
        }
        if result == -1 {
            throw systemCallFailure("execvp")
        }
    }

    private static func capture() throws {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            writeDiagnostic("SKIPPED\tno frontmost application")
            return
        }
        let snapshot = identity(of: application)
        guard let data = try? JSONEncoder().encode(snapshot) else {
            throw UserFocusRestorationFailure.snapshotEncodingFailed
        }
        writeDiagnostic(
            "CAPTURED\t\(applicationName(application))"
                + "\tpid=\(application.processIdentifier)"
        )
        FileHandle.standardOutput.write(
            Data("\(data.base64EncodedString())\n".utf8)
        )
    }

    private static func restore(encodedSnapshot: String) throws {
        guard
            let data = Data(base64Encoded: encodedSnapshot),
            let snapshot = try? JSONDecoder().decode(
                UserFocusApplicationIdentity.self,
                from: data
            )
        else {
            throw UserFocusRestorationFailure.snapshotUnreadable
        }

        let runningApplications = NSWorkspace.shared.runningApplications
        let candidates = runningApplications.map(identity(of:))
        guard case let .application(targetIdentity) =
            UserFocusRestorationResolver.resolve(
                snapshot: snapshot,
                candidates: candidates
            )
        else {
            writeStatus("SKIPPED\toriginal application is no longer running")
            return
        }
        guard
            let application = NSRunningApplication(
                processIdentifier: targetIdentity.processIdentifier
            ),
            identity(of: application) == targetIdentity
        else {
            throw UserFocusRestorationFailure.targetChanged
        }

        if isFrontmost(application) {
            writeStatus("RESTORED\t\(applicationName(application))")
            return
        }
        guard application.activate(options: []) else {
            throw UserFocusRestorationFailure.activationRejected(
                applicationName(application)
            )
        }
        guard waitUntilFrontmost(application) else {
            throw UserFocusRestorationFailure.activationTimedOut(
                applicationName(application)
            )
        }
        writeStatus("RESTORED\t\(applicationName(application))")
    }

    private static func waitUntilFrontmost(
        _ application: NSRunningApplication
    ) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime
            + activationTimeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if isFrontmost(application) {
                return true
            }
            RunLoop.current.run(
                mode: .default,
                before: Date(timeIntervalSinceNow: 0.05)
            )
        }
        return isFrontmost(application)
    }

    private static func isFrontmost(
        _ application: NSRunningApplication
    ) -> Bool {
        application.isActive
            && NSWorkspace.shared.frontmostApplication?
                .processIdentifier == application.processIdentifier
    }

    private static func identity(
        of application: NSRunningApplication
    ) -> UserFocusApplicationIdentity {
        UserFocusApplicationIdentity(
            processIdentifier: application.processIdentifier,
            launchTime: application.launchDate?.timeIntervalSinceReferenceDate,
            bundleIdentifier: application.bundleIdentifier,
            executablePath: application.executableURL?
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
        )
    }

    private static func applicationName(
        _ application: NSRunningApplication
    ) -> String {
        application.localizedName
            ?? application.bundleIdentifier
            ?? "pid \(application.processIdentifier)"
    }

    private static func writeStatus(_ value: String) {
        FileHandle.standardOutput.write(Data("\(value)\n".utf8))
    }

    private static func writeDiagnostic(_ value: String) {
        FileHandle.standardError.write(Data("\(value)\n".utf8))
    }

    private static func systemCallFailure(
        _ name: String
    ) -> UserFocusRestorationFailure {
        let errorCode = errno
        return .systemCallFailed(
            name,
            String(cString: strerror(errorCode))
        )
    }
}
