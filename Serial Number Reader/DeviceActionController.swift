import Foundation
import JTKit
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
///
/// Each action that ran writes an "Action" entry to the activity log, done or
/// failed, with the device's serial number, UDID and ECID for the masked
/// export. A cancelled administrator prompt writes nothing: nothing happened.
@MainActor
@Observable
final class DeviceActionController {

    enum Action: Equatable {
        case reboot
        case dfu
        case enterRecovery
        case bootNormal
        case removeTrust

        /// The activity log's words for it, done and failed.
        func summary(_ device: String, failed: Bool) -> String {
            switch (self, failed) {
            case (.reboot, false): "Restarted \(device) over USB"
            case (.reboot, true): "Couldn’t restart \(device) over USB"
            case (.dfu, false): "Put \(device) into DFU mode over USB"
            case (.dfu, true): "Couldn’t put \(device) into DFU mode over USB"
            case (.enterRecovery, false): "Put \(device) into Recovery mode over USB"
            case (.enterRecovery, true): "Couldn’t put \(device) into Recovery mode over USB"
            case (.bootNormal, false): "Booted \(device) out of Recovery mode over USB"
            case (.bootNormal, true): "Couldn’t boot \(device) out of Recovery mode over USB"
            case (.removeTrust, false): "Removed the trust between this Mac and \(device)"
            case (.removeTrust, true): "Couldn’t remove the trust between this Mac and \(device)"
            }
        }

        /// What carried it out, as the activity log's service.
        var service: String { self == .removeTrust ? "Apple Configurator" : "USB" }
    }

    /// The device an action is for, as the activity log names it.
    struct Target: Equatable, Sendable {
        /// e.g. "iPad Air (F9FXK2Q3HGMN)".
        let name: String
        /// Serial number, UDID and ECID, masked in the bug-report export.
        let identifiers: [String]

        init(name: String, identifiers: [String]) {
            self.name = name
            self.identifiers = identifiers
        }

        init(_ device: USBDevice) {
            let identifiers = [device.serialNumber, device.displayUDID, device.ecid].compactMap { $0 }
            name = device.serialNumber.map { "\(device.modelDisplayName) (\($0))" } ?? device.modelDisplayName
            self.identifiers = identifiers.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        }
    }

    /// The action currently running, if any (drives button spinners).
    private(set) var runningAction: Action?
    /// Last human-readable error, shown transiently in the UI.
    private(set) var lastError: String?
    /// The device that refused Enter Recovery because it doesn't trust this
    /// Mac; the Power section shows trust and button-step guidance for it.
    private(set) var trustRequiredDeviceID: UInt64?

    /// What an action's work reports back. Created off the main actor.
    nonisolated enum Outcome: Sendable, Equatable {
        case done
        case failed(String)
        case trustRequired(deviceID: UInt64)
        /// The administrator prompt was cancelled: nothing was done.
        case cancelled

        init(errorMessage: String?) {
            self = errorMessage.map(Outcome.failed) ?? .done
        }
    }

    /// Where "Action" entries go; nil records nothing (previews).
    private let activityLog: ActivityLog?
    private let logger = Logger(subsystem: "be.jordythery.SerialNumberReader", category: "DeviceActions")

    init(activityLog: ActivityLog? = nil) {
        self.activityLog = activityLog
    }

    // MARK: - Actions

    /// Force-restarts the connected device via USB-PD (admin prompt).
    func restart(device: USBDevice) {
        start(.reboot, for: Target(device)) { Self.runPrivilegedVDM("reboot") }
    }

    /// Reboots the connected device into DFU mode via USB-PD (admin prompt).
    func enterDFU(device: USBDevice) {
        start(.dfu, for: Target(device)) { Self.runPrivilegedVDM("dfu") }
    }

    /// Asks a booted device to reboot into Recovery mode via lockdownd —
    /// unpaired where allowed, otherwise over the Mac's trusted connection.
    func enterRecovery(device: USBDevice) {
        guard let udid = device.udid else {
            lastError = "No UDID available for this device."
            return
        }
        let deviceID = device.id
        start(.enterRecovery, for: Target(device)) {
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
        start(.bootNormal, for: Target(device)) {
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
        start(.removeTrust, for: Target(device), onSuccess: onSuccess) {
            try Configurator.unpair(ecid: ecid)
            return .done
        }
    }

    // MARK: - Execution

    /// Runs blocking `work` off the main thread, publishes its outcome and
    /// records it. Waits for the outcome, so tests can check what was recorded.
    @discardableResult
    func start(_ action: Action, for target: Target, onSuccess: (@MainActor () -> Void)? = nil,
               work: @escaping @Sendable () throws -> Outcome) -> Task<Void, Never>? {
        guard runningAction == nil else { return nil }
        runningAction = action
        lastError = nil
        trustRequiredDeviceID = nil
        let started = ContinuousClock.now
        return Task {
            let outcome: Outcome
            do {
                outcome = try await Task.detached(priority: .userInitiated) { try work() }.value
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            let elapsed = started.duration(to: .now)
            let duration = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            switch outcome {
            case .done:
                record(action, target, failed: false, note: nil, duration: duration)
                onSuccess?()
            case .failed(let message):
                // The message can hold a UDID or the device's reply: private.
                logger.error("\(String(describing: action), privacy: .public) failed: \(message, privacy: .private)")
                record(action, target, failed: true, note: message, duration: duration)
                lastError = message
            case .trustRequired(let deviceID):
                record(action, target, failed: true, note: "The device doesn’t trust this Mac.", duration: duration)
                trustRequiredDeviceID = deviceID
            case .cancelled:
                break
            }
            runningAction = nil
        }
    }

    private func record(_ action: Action, _ target: Target, failed: Bool, note: String?, duration: TimeInterval) {
        activityLog?.recordAction(action.summary(target.name, failed: failed), note: note, failed: failed,
                                  service: action.service, devices: target.identifiers, duration: duration)
    }

    /// Done, failed with a message, or cancelled at the authorization prompt
    /// (cancellation is intentionally silent, and not recorded).
    private nonisolated static func runPrivilegedVDM(_ action: String) -> Outcome {
        switch executeViaAppleScript(action) {
        case .success: .done
        case .cancelled: .cancelled
        case .failure(let message): .failed(message)
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
