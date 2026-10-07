import Foundation
import os

/// Runs the device power/mode actions shown in the detail pane:
///
/// - **Restart / Enter DFU** — USB-PD vendor-defined messages via the private
///   AppleHPM port-controller interface. Requires root, so the app re-launches
///   its own executable with `--vdm <action>` through an administrator prompt.
/// - **Enter Recovery** — lockdownd `EnterRecovery` over usbmuxd for a booted
///   device. No privileges required.
/// - **Boot to Normal** — iBoot `setenv auto-boot true` + `reboot` over USB
///   control requests for a Recovery-mode device. No privileges required.
@MainActor
@Observable
final class DeviceActionController {

    enum Action: Equatable {
        case reboot
        case dfu
        case enterRecovery
        case bootNormal
    }

    /// The action currently running, if any (drives button spinners).
    private(set) var runningAction: Action?
    /// Last human-readable error, shown transiently in the UI.
    private(set) var lastError: String?

    private let logger = Logger(subsystem: "be.jordythery.SerialNumberReader", category: "DeviceActions")

    // MARK: - Privileged VDM actions (admin prompt)

    func restart() { runVDM(.reboot, argument: "reboot") }
    func enterDFU() { runVDM(.dfu, argument: "dfu") }

    // MARK: - Unprivileged actions

    /// Asks a booted device to reboot into Recovery mode via lockdownd.
    func enterRecovery(device: USBDevice) {
        guard let udid = device.udid else {
            lastError = "No UDID available for this device."
            return
        }
        start(.enterRecovery) {
            try Usbmux.enterRecovery(udid: udid)
            return nil
        }
    }

    /// Boots a Recovery-mode device back to normal (auto-boot true + reboot).
    func bootToNormal(device: USBDevice) {
        let entryID = device.id
        start(.bootNormal) {
            RecoveryCommands.send(
                ["setenv auto-boot true", "saveenv", "reboot"],
                toRegistryEntryID: entryID
            )
        }
    }

    // MARK: - Execution

    /// Runs blocking `work` off the main thread; it returns an error message
    /// or nil, or throws.
    private func start(_ action: Action, work: @escaping @Sendable () throws -> String?) {
        guard runningAction == nil else { return }
        runningAction = action
        lastError = nil
        Task {
            let failure: String?
            do {
                failure = try await Task.detached(priority: .userInitiated) { try work() }.value
            } catch {
                failure = error.localizedDescription
            }
            if let failure {
                logger.error("\(String(describing: action), privacy: .public) failed: \(failure, privacy: .public)")
                lastError = failure
            }
            runningAction = nil
        }
    }

    private func runVDM(_ action: Action, argument: String) {
        guard runningAction == nil else { return }
        runningAction = action
        lastError = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Self.executeViaAppleScript(argument)
            }.value
            switch result {
            case .success:
                logger.debug("VDM \(argument, privacy: .public) sent")
            case .cancelled:
                break // user dismissed the password prompt — stay silent
            case .failure(let message):
                lastError = message
            }
            runningAction = nil
        }
    }

    private enum RunResult: Sendable {
        case success
        case cancelled
        case failure(String)
    }

    /// Uses `osascript … with administrator privileges` to run our own binary
    /// as root with `--vdm <action>`. A single OS password prompt authorises it.
    private nonisolated static func executeViaAppleScript(_ action: String) -> RunResult {
        let executablePath = Bundle.main.executablePath ?? CommandLine.arguments[0]
        // Quote for the embedded shell command inside the AppleScript string.
        let shellCommand = "\(shellQuoted(executablePath)) --vdm \(action)"
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

    private nonisolated static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escape a string to live inside an AppleScript double-quoted literal.
    private nonisolated static func escapedForAppleScript(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
