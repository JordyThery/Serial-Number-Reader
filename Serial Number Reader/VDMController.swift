import Foundation
import os

/// Runs the privileged VDM actions (restart / enter DFU) by re-launching this
/// app's own executable as root through a single administrator prompt.
///
/// AppleHPM — the USB-C port controller interface used to send the VDM — is a
/// private IOKit service that requires root, so there's no sandbox-friendly
/// path here. The app ships un-sandboxed and asks for admin rights per action.
@MainActor
@Observable
final class VDMController {

    enum Action: String {
        case reboot
        case dfu

        var verb: String {
            switch self {
            case .reboot: "Restart"
            case .dfu: "Enter DFU"
            }
        }
    }

    /// The action currently running, if any (drives button spinners).
    private(set) var runningAction: Action?
    /// Last human-readable error, shown transiently in the UI.
    private(set) var lastError: String?

    private let logger = Logger(subsystem: "be.jordythery.SerialNumberReader", category: "VDM")

    func run(_ action: Action) {
        guard runningAction == nil else { return }
        runningAction = action
        lastError = nil

        Task {
            let result = await Self.runPrivileged(action)
            switch result {
            case .success:
                logger.debug("VDM \(action.rawValue, privacy: .public) sent")
            case .cancelled:
                break // user dismissed the password prompt — stay silent
            case .failure(let message):
                lastError = message
            }
            runningAction = nil
        }
    }

    private enum RunResult {
        case success
        case cancelled
        case failure(String)
    }

    private static func runPrivileged(_ action: Action) async -> RunResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: executeViaAppleScript(action))
            }
        }
    }

    /// Uses `osascript … with administrator privileges` to run our own binary
    /// as root with `--vdm <action>`. A single OS password prompt authorises it.
    private static func executeViaAppleScript(_ action: Action) -> RunResult {
        let executablePath = Bundle.main.executablePath ?? CommandLine.arguments[0]
        // Quote for the embedded shell command inside the AppleScript string.
        let shellCommand = "\(shellQuoted(executablePath)) --vdm \(action.rawValue)"
        let appleScriptSource = """
        do shell script "\(escapedForAppleScript(shellCommand))" with administrator privileges
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScriptSource]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .failure(error.localizedDescription)
        }

        if process.terminationStatus == 0 {
            return .success
        }

        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(data: errorData, encoding: .utf8) ?? ""
        // osascript returns -128 when the user cancels the authorization dialog.
        if errorText.contains("-128") || errorText.contains("User canceled") {
            return .cancelled
        }
        let trimmed = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure(trimmed.isEmpty ? "The command failed (exit \(process.terminationStatus))." : trimmed)
    }

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escape a string to live inside an AppleScript double-quoted literal.
    private static func escapedForAppleScript(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
