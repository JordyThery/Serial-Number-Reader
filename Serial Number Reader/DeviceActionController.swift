import Foundation
import JTKit
import os

/// Runs the device power/mode actions shown in the detail pane:
///
/// - **Restart / Enter DFU** — USB-PD vendor-defined messages via the private
///   AppleHPM port-controller interface. Requires root, so the app re-launches
///   its own executable with `--vdm <action>` through an administrator prompt,
///   after checking that the executable on disk is the signed app that runs.
///   The command goes to the selected device's own USB-C port (`USBCPort`):
///   the app checks the chain before the prompt and the root helper checks
///   it again itself; a device behind a hub or dock is refused. Afterwards the
///   app watches for the same device (by ECID) to come back in the expected
///   mode, and reports success only then (`DeviceReturnWatch`).
/// - **Enter Recovery** — lockdownd `EnterRecovery` over usbmuxd for a booted
///   device. No privileges required; on iOS 27 and later only over the
///   pairing of a Mac the device already trusts.
/// - **Boot to Normal** — iBoot `setenv auto-boot true` + `reboot` over USB
///   control requests for a Recovery-mode device. No privileges required.
/// - **Remove Trust** — removes this Mac's pairing with a booted device
///   through Apple Configurator.
///
/// A single instance is shared app-wide so only one action runs at a time —
/// the VDM path operates on ports, not on a specific selected device — and
/// none while a Restore or Revive runs (`restore`).
///
/// Each action that ran writes an "Action" entry to the activity log, done or
/// failed, with the device's serial number, UDID and ECID for the masked
/// export. A cancelled administrator prompt writes nothing: nothing happened.
///
/// In demo mode every action goes to `DemoUSB`'s pretend iPhone and is
/// simulated; nothing goes to the hardware, also for a real device (tested).
/// Outside demo mode the pretend iPhone is refused.
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

        /// The activity log's words when the command was sent but the device
        /// didn't come back.
        func notBackSummary(_ device: String) -> String {
            switch self {
            case .reboot: "Sent Restart to \(device), but it didn’t come back on USB"
            case .dfu: "Sent Enter DFU to \(device), but it didn’t come back in DFU mode"
            default: summary(device, failed: true)
            }
        }

        /// What carried it out, as the activity log's service.
        var service: String { self == .removeTrust ? "Apple Configurator" : "USB" }
    }

    /// The device an action is for, as the activity log names it.
    struct Target: Equatable, Sendable {
        /// e.g. "iPad Air (PLACEHOLDR01)".
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
    /// A note on the last action that isn't an error (e.g. the device came
    /// back but couldn't be confirmed as the same one).
    private(set) var lastNote: String?
    /// The action whose device the app is waiting for, after the command.
    private(set) var waitingForReturn: Action?
    /// Watches the device list after Restart and Enter DFU; nil doesn't wait
    /// (previews and most tests). Set by the app.
    @ObservationIgnored var returnWatch: DeviceReturnWatch?
    /// The device that refused Enter Recovery because it doesn't trust this
    /// Mac; the Actions section shows trust and button-step guidance for it.
    private(set) var trustRequiredDeviceID: UInt64?

    /// What an action's work reports back. Created off the main actor.
    nonisolated enum Outcome: Sendable, Equatable {
        case done
        case failed(String)
        case trustRequired(deviceID: UInt64)
        /// The administrator prompt was cancelled: nothing was done.
        case cancelled
        /// The VDM went out, but the device's reply was missed: it may
        /// already be rebooting.
        case replyMissed
        /// Done, with a note (e.g. back, but not confirmed as the same device).
        case doneWithNote(String)
        /// The command went out, but the device didn't come back.
        case notBack(String)

        init(errorMessage: String?) {
            self = errorMessage.map(Outcome.failed) ?? .done
        }
    }

    /// The app's Restore and Revive: no action starts while one runs.
    weak var restore: RestoreController?

    /// Where "Action" entries go; nil records nothing (previews).
    private let activityLog: ActivityLog?
    /// The real devices: lockdown, iBoot, the VDMs and Apple Configurator.
    private let hardware: any USBHardware
    /// Demo mode's pretend iPhone; nil without demo mode.
    private let demo: DemoUSB?
    private let logger = Logger(subsystem: "be.jordythery.SerialNumberReader", category: "DeviceActions")

    /// The activity log's note on every simulated action.
    nonisolated static let demoNote = "Demo Mode: simulated, nothing was sent to a device."

    /// - Parameters:
    ///   - hardware: the real devices; a fake in tests.
    ///   - demo: demo mode's pretend iPhone; nil without demo mode.
    ///   - now: the clock for how long the Apple Configurator check is kept; a fake in tests.
    init(activityLog: ActivityLog? = nil, hardware: any USBHardware = LiveUSBHardware(), demo: DemoUSB? = nil,
         now: @escaping () -> Date = { .now }) {
        self.activityLog = activityLog
        self.hardware = hardware
        self.demo = demo
        self.now = now
    }

    /// Whether Restore, Revive and Remove Trust can run: Apple Configurator
    /// is installed, or demo mode simulates it. The disk is checked at most
    /// every few seconds, not on every redraw of the Actions section.
    var isConfiguratorAvailable: Bool {
        if demo?.isOn == true { return true }
        if let cached = configuratorCheck, now().timeIntervalSince(cached.at) < Self.configuratorCheckLifetime {
            return cached.available
        }
        let available = hardware.isConfiguratorAvailable
        configuratorCheck = (available, now())
        return available
    }

    nonisolated static let configuratorCheckLifetime: TimeInterval = 5
    @ObservationIgnored private var configuratorCheck: (available: Bool, at: Date)?
    @ObservationIgnored private let now: () -> Date

    /// The message when an action is refused because a Restore or Revive runs.
    nonisolated static let restoreRunning = "A restore or revive is running. Wait until it finishes, then try again."
    /// The message when a device reported no UDID (sidebar, detail and actions).
    nonisolated static let noUDID = "The device reported no UDID."

    /// Where an action for `device` goes: the pretend iPhone while demo mode
    /// is on, the hardware otherwise. Nil, with the reason shown, when the
    /// device doesn't belong there: a real device in demo mode (it isn't
    /// listed, but never reaches the hardware either), or the pretend iPhone
    /// outside demo mode.
    private func simulator(for device: USBDevice) -> (demo: DemoUSB?, allowed: Bool) {
        let isPretend = PretendIPhone.isPretend(device)
        if let demo, demo.isOn {
            if isPretend { return (demo, true) }
            lastError = PretendIPhone.realDeviceRefusal
            return (nil, false)
        }
        if isPretend {
            lastError = PretendIPhone.refusal
            return (nil, false)
        }
        return (nil, true)
    }

    // MARK: - Actions

    /// Force-restarts the connected device via USB-PD (admin prompt), on its
    /// own USB-C port; waits for it to come back (not for a Mac: a Mac that
    /// starts up doesn't appear on USB).
    func restart(device: USBDevice) {
        let expectation = device.modelInfo?.isMac == true ? nil : DeviceReturnExpectation.restart(of: device)
        sendVDM(.reboot, "reboot", to: device, expecting: expectation) { await $0.restart() }
    }

    /// Reboots the connected device into DFU mode via USB-PD (admin prompt),
    /// on its own USB-C port; waits for it to come back in DFU mode.
    func enterDFU(device: USBDevice) {
        sendVDM(.dfu, "dfu", to: device, expecting: .dfu(of: device)) { await $0.enterDFU() }
    }

    /// Why Restart and Enter DFU can't go to this device now, or nil. Reads
    /// the IORegistry (no privileges); the pretend iPhone is always reachable.
    /// Kept a few seconds, so a redraw doesn't read the registry each time.
    func portRefusal(for device: USBDevice) -> USBCPort.Refusal? {
        if PretendIPhone.isPretend(device) { return nil }
        if let cached = portChecks[device.id], now().timeIntervalSince(cached.at) < Self.portCheckLifetime {
            return cached.refusal
        }
        var refusal: USBCPort.Refusal?
        if case .failure(let reason) = hardware.usbCPort(forEntryID: device.id) { refusal = reason }
        portChecks[device.id] = (refusal, now())
        return refusal
    }

    nonisolated static let portCheckLifetime: TimeInterval = 3
    @ObservationIgnored private var portChecks: [UInt64: (refusal: USBCPort.Refusal?, at: Date)] = [:]

    private func sendVDM(_ action: Action, _ command: String, to device: USBDevice,
                         expecting expectation: DeviceReturnExpectation?,
                         demoWork: @escaping @MainActor (DemoUSB) async -> Outcome) {
        let route = simulator(for: device)
        guard route.allowed else { return }
        if let demo = route.demo {
            return simulate(action, for: Target(device), expecting: expectation) { await demoWork(demo) }
        }
        // The same check as the dimmed buttons, once more before the password is asked.
        if case .failure(let refusal) = hardware.usbCPort(forEntryID: device.id) {
            lastError = refusal.message
            return
        }
        let hardware = hardware
        let entryID = device.id
        start(action, for: Target(device), expecting: expectation) {
            hardware.runPrivilegedVDM(command, deviceEntryID: entryID)
        }
    }

    /// Asks a booted device to reboot into Recovery mode via lockdownd —
    /// unpaired where allowed, otherwise over the Mac's trusted connection.
    func enterRecovery(device: USBDevice) {
        guard let udid = device.udid else {
            lastError = Self.noUDID
            return
        }
        let route = simulator(for: device)
        guard route.allowed else { return }
        if let demo = route.demo { return simulate(.enterRecovery, for: Target(device)) { await demo.enterRecovery() } }
        let deviceID = device.id
        let hardware = hardware
        start(.enterRecovery, for: Target(device)) {
            do {
                try hardware.enterRecovery(udid: udid)
                return .done
            } catch Usbmux.Failure.trustRequired {
                return .trustRequired(deviceID: deviceID)
            }
        }
    }

    /// Boots a Recovery-mode device back to normal (auto-boot true + reboot).
    func bootToNormal(device: USBDevice) {
        let route = simulator(for: device)
        guard route.allowed else { return }
        if let demo = route.demo { return simulate(.bootNormal, for: Target(device)) { await demo.bootToNormal() } }
        let entryID = device.id
        let hardware = hardware
        start(.bootNormal, for: Target(device)) {
            Outcome(errorMessage: hardware.sendRecoveryCommands(
                ["setenv auto-boot true", "saveenv", "reboot"],
                toRegistryEntryID: entryID
            ))
        }
    }

    /// Removes the pairing between this Mac and a booted device, on both
    /// sides, through Apple Configurator. `onSuccess` runs on the main actor.
    func removeTrust(device: USBDevice, onSuccess: @escaping @MainActor () -> Void) {
        guard let ecid = device.configuratorECID else {
            lastError = "This device’s ECID is unknown, so its trust can’t be removed here."
            return
        }
        let route = simulator(for: device)
        guard route.allowed else { return }
        if let demo = route.demo {
            return simulate(.removeTrust, for: Target(device), onSuccess: onSuccess) { await demo.removeTrust() }
        }
        let hardware = hardware
        start(.removeTrust, for: Target(device), onSuccess: onSuccess) {
            try hardware.unpair(ecid: ecid)
            return .done
        }
    }

    // MARK: - Execution

    /// Runs blocking `work` off the main thread, publishes its outcome and
    /// records it. Waits for the outcome, so tests can check what was recorded.
    @discardableResult
    func start(_ action: Action, for target: Target, expecting expectation: DeviceReturnExpectation? = nil,
               onSuccess: (@MainActor () -> Void)? = nil,
               work: @escaping @Sendable () throws -> Outcome) -> Task<Void, Never>? {
        perform(action, for: target, simulated: false, expecting: expectation, onSuccess: onSuccess) {
            do {
                // Its own threads: the work blocks (sockets, USB, the password prompt).
                return try await BlockingWork.run(work)
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }

    /// Runs a simulated action on the pretend iPhone; recorded as simulated.
    private func simulate(_ action: Action, for target: Target, expecting expectation: DeviceReturnExpectation? = nil,
                          onSuccess: (@MainActor () -> Void)? = nil,
                          work: @escaping @MainActor () async -> Outcome) {
        perform(action, for: target, simulated: true, expecting: expectation, onSuccess: onSuccess, work: work)
    }

    /// The last action's task, so tests can wait for it.
    @ObservationIgnored private(set) var currentTask: Task<Void, Never>?

    @discardableResult
    private func perform(_ action: Action, for target: Target, simulated: Bool,
                         expecting expectation: DeviceReturnExpectation?, onSuccess: (@MainActor () -> Void)?,
                         work: @escaping @MainActor () async -> Outcome) -> Task<Void, Never>? {
        guard runningAction == nil else { return nil }
        if restore?.isRunning == true {
            lastError = Self.restoreRunning
            return nil
        }
        runningAction = action
        lastError = nil
        lastNote = nil
        trustRequiredDeviceID = nil
        let started = ContinuousClock.now
        let startDate = Date.now
        let task = Task {
            var outcome = await work()
            // Success only once the same device is back in the expected mode;
            // after a missed reply, a short watch instead of a failure.
            if let expectation, let watch = returnWatch {
                let watched: DeviceReturnExpectation? = switch outcome {
                case .done: expectation
                case .replyMissed: expectation.afterMissedReply()
                default: nil
                }
                if let watched {
                    waitingForReturn = action
                    outcome = switch await watch.wait(for: watched, since: startDate) {
                    case .back: .done
                    case .backUnconfirmed(let note): .doneWithNote(note)
                    case .notBack(let message): .notBack(message)
                    }
                    waitingForReturn = nil
                }
            }
            if outcome == .replyMissed {
                outcome = .failed(VDMToolReplyMissed + " Check whether the device restarted.")
            }
            let elapsed = started.duration(to: .now)
            let duration = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            func note(_ text: String?) -> String? {
                guard simulated else { return text }
                return [text, Self.demoNote].compactMap { $0 }.joined(separator: " ")
            }
            switch outcome {
            case .done:
                record(action, target, failed: false, note: note(nil), simulated: simulated, duration: duration)
                onSuccess?()
            case .doneWithNote(let text):
                record(action, target, failed: false, note: note(text), simulated: simulated, duration: duration)
                lastNote = text
                onSuccess?()
            case .notBack(let message):
                record(action, target, failed: true, note: note(message), simulated: simulated, duration: duration,
                       summary: action.notBackSummary(target.name))
                lastError = message
            case .failed(let message):
                // The message can hold a UDID or the device's reply: private.
                logger.error("\(String(describing: action), privacy: .public) failed: \(message, privacy: .private)")
                record(action, target, failed: true, note: note(message), simulated: simulated, duration: duration)
                lastError = message
            case .trustRequired(let deviceID):
                record(action, target, failed: true, note: note("The device doesn’t trust this Mac."),
                       simulated: simulated, duration: duration)
                trustRequiredDeviceID = deviceID
            case .cancelled, .replyMissed:
                break
            }
            runningAction = nil
        }
        currentTask = task
        return task
    }

    private func record(_ action: Action, _ target: Target, failed: Bool, note: String?, simulated: Bool,
                        duration: TimeInterval, summary: String? = nil) {
        activityLog?.recordAction(summary ?? action.summary(target.name, failed: failed), note: note, failed: failed,
                                  service: action.service, connection: simulated ? "Demo" : nil,
                                  devices: target.identifiers, duration: duration)
    }

    /// Done, failed with a message, or cancelled at the authorization prompt
    /// (cancellation is intentionally silent, and not recorded).
    nonisolated static func runPrivilegedVDM(_ action: String, deviceEntryID: UInt64) -> Outcome {
        switch executeViaAppleScript(PrivilegedVDM.commandArguments(action: action, deviceEntryID: deviceEntryID)) {
        case .success: .done
        case .cancelled: .cancelled
        case .replyMissed: .replyMissed
        case .failure(let message): .failed(message)
        }
    }

    nonisolated enum RunResult: Sendable, Equatable {
        case success
        case cancelled
        /// The helper's exit 6: sent, but the device's reply was missed.
        case replyMissed
        case failure(String)
    }

    /// Uses `osascript … with administrator privileges` to run our own binary
    /// as root with `--vdm <action> --entry <hex>`. A single OS password
    /// prompt authorizes it. Before the prompt, the executable on disk must
    /// be the signed app that is running: a swapped binary is never run as root.
    private nonisolated static func executeViaAppleScript(_ arguments: [String]) -> RunResult {
        // Second safeguard behind LiveUSBHardware: no administrator prompt, no VDM under tests.
        if let refusal = USBGuard.shared.refusal(for: "administrator prompt for \(arguments.prefix(2).joined(separator: " "))") {
            return .failure(refusal)
        }
        // Only the forms the root side accepts; nothing else reaches the shell.
        guard PrivilegedVDM.parse(arguments) != nil else { return .failure("Unknown arguments.") }
        guard let executablePath = Bundle.main.executablePath else { return .failure(unverifiedApp) }
        if let refusal = signatureRefusal(executable: executablePath, bundle: Bundle.main.bundleURL) {
            return .failure(refusal)
        }
        // Quote for the embedded shell command inside the AppleScript string.
        let shellCommand = ([executablePath] + arguments).map(shellQuoted).joined(separator: " ")
        let appleScriptSource = """
        do shell script "\(escapedForAppleScript(shellCommand))" with administrator privileges
        """
        do {
            let result = try ProcessOutput.run(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", appleScriptSource])
            return runResult(status: result.status, errorText: result.errorText)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// What osascript's exit status and error output mean.
    nonisolated static func runResult(status: Int32, errorText: String) -> RunResult {
        if status == 0 { return .success }
        // osascript returns -128 when the user cancels the authorization dialog.
        if errorText.contains("-128") || errorText.contains("User canceled") { return .cancelled }
        if errorText.contains(VDMToolReplyMissed) { return .replyMissed }
        // The root helper's message is the last line; osascript puts its own words before it.
        return .failure(errorText.isEmpty ? "The command failed (exit \(status))." : errorText)
    }

    nonisolated static let unverifiedApp =
        "Serial Number Reader couldn’t verify its own app on disk, so it won’t ask for an administrator password. Reinstall the app and try again."

    /// Nil when the app bundle on disk is valid and meets the running app's
    /// own code requirement (same signer and identifier, or for a locally
    /// signed build the same code), and `executable` is its executable;
    /// otherwise the message to show.
    nonisolated static func signatureRefusal(executable: String, bundle: URL) -> String? {
        var running: SecCode?
        var runningStatic: SecStaticCode?
        var requirement: SecRequirement?
        var onDisk: SecStaticCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &runningStatic) == errSecSuccess, let runningStatic,
              SecCodeCopyDesignatedRequirement(runningStatic, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(bundle as CFURL, [], &onDisk) == errSecSuccess, let onDisk,
              SecStaticCodeCheckValidity(onDisk, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
        else { return unverifiedApp }
        // The executable that would run as root must be the bundle's own.
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(onDisk, [], &info) == errSecSuccess,
              let main = (info as? [String: Any])?[kSecCodeInfoMainExecutable as String] as? URL,
              main.resolvingSymlinksInPath().path == URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
        else { return unverifiedApp }
        return nil
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
