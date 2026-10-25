import Foundation
import os

/// Runs the device power/mode actions shown in the detail pane:
///
/// - **Restart / Enter DFU** — USB-PD vendor-defined messages via the private
///   AppleHPM port-controller interface. Requires root, so the app re-launches
///   its own executable with `--vdm <action>` through an administrator prompt.
///   The command targets the first port with a connected device, so the UI
///   only offers it while a single device is attached.
/// - **Enter Recovery** — lockdownd `EnterRecovery` over usbmuxd for a booted
///   device. No privileges required.
/// - **Boot to Normal** — iBoot `setenv auto-boot true` + `reboot` over USB
///   control requests for a Recovery-mode device. No privileges required.
/// - **Remove Trust** — removes this Mac's pairing with a booted device
///   through Apple Configurator.
///
/// A single instance is shared app-wide so only one action runs at a time —
/// the VDM path operates on ports, not on a specific selected device.
@MainActor
@Observable
final class DeviceActionController {

    enum Action: Equatable {
        case reboot
        case dfu
        case enterRecovery
        case bootNormal
        case removeTrust
    }

    /// The action currently running, if any (drives button spinners).
    private(set) var runningAction: Action?
    /// Last human-readable error, shown transiently in the UI.
    private(set) var lastError: String?
    /// The device that refused Enter Recovery because it doesn't trust this
    /// Mac; the Power section shows trust and button-step guidance for it.
    private(set) var trustRequiredDeviceID: UInt64?

    /// What an action's work reports back. Created off the main actor.
    nonisolated private enum Outcome: Sendable {
        case done
        case failed(String)
        case trustRequired(deviceID: UInt64)

        init(errorMessage: String?) {
            self = errorMessage.map(Outcome.failed) ?? .done
        }
    }

    private let logger = Logger(subsystem: "be.jordythery.SerialNumberReader", category: "DeviceActions")

    // MARK: - Actions

    /// Force-restarts the connected device via USB-PD (admin prompt).
    func restart() {
        start(.reboot) { Outcome(errorMessage: Self.runPrivilegedVDM("reboot")) }
    }

    /// Reboots the connected device into DFU mode via USB-PD (admin prompt).
    func enterDFU() {
        start(.dfu) { Outcome(errorMessage: Self.runPrivilegedVDM("dfu")) }
    }

    /// Asks a booted device to reboot into Recovery mode via lockdownd —
    /// unpaired where allowed, otherwise over the Mac's trusted connection.
    func enterRecovery(device: USBDevice) {
        guard let udid = device.udid else {
            lastError = "No UDID available for this device."
            return
        }
        let deviceID = device.id
        start(.enterRecovery) {
            do {
                try Usbmux.enterRecovery(udid: udid)
                return .done
            } catch Usbmux.Failure.trustRequired {
                return .trustRequired(deviceID: deviceID)
            }
        }
    }

    /// Boots a Recovery-mode device back to normal (auto-boot true + reboot).
    func bootToNormal(device: USBDevice) {
        let entryID = device.id
        start(.bootNormal) {
            Outcome(errorMessage: RecoveryCommands.send(
                ["setenv auto-boot true", "saveenv", "reboot"],
                toRegistryEntryID: entryID
            ))
        }
    }

    /// Removes the pairing between this Mac and a booted device, on both
    /// sides, through Apple Configurator. `onSuccess` runs on the main actor.
    func removeTrust(device: USBDevice, onSuccess: @escaping @MainActor () -> Void) {
        guard let ecid = device.configuratorECID else {
            lastError = "This device's ECID is unknown, so its trust can't be removed here."
            return
        }
        start(.removeTrust, onSuccess: onSuccess) {
            try Configurator.unpair(ecid: ecid)
            return .done
        }
    }

    // MARK: - Execution

    /// Runs blocking `work` off the main thread and publishes its outcome.
    private func start(_ action: Action, onSuccess: (@MainActor () -> Void)? = nil,
                       work: @escaping @Sendable () throws -> Outcome) {
        guard runningAction == nil else { return }
        runningAction = action
        lastError = nil
        trustRequiredDeviceID = nil
        Task {
            let outcome: Outcome
            do {
                outcome = try await Task.detached(priority: .userInitiated) { try work() }.value
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            switch outcome {
            case .done:
                onSuccess?()
            case .failed(let message):
                logger.error("\(String(describing: action), privacy: .public) failed: \(message, privacy: .public)")
                lastError = message
            case .trustRequired(let deviceID):
                trustRequiredDeviceID = deviceID
            }
            runningAction = nil
        }
    }

    /// Returns an error message, or nil for success and for a cancelled
    /// authorization prompt (cancellation is intentionally silent).
    private nonisolated static func runPrivilegedVDM(_ action: String) -> String? {
        switch executeViaAppleScript(action) {
        case .success, .cancelled: nil
        case .failure(let message): message
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
