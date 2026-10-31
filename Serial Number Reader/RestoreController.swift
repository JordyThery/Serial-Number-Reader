import Foundation
import JTKit
import Observation
import os

/// Runs one Restore or Revive at a time through Apple Configurator and
/// publishes its progress. Shared app-wide: the progress banner, the quit
/// confirmation and the other device actions all consult it.
///
/// The start and the end of each job are "Action" entries in the activity
/// log, with the device's ECID for the masked export.
///
/// In demo mode a job runs only on the pretend iPhone and is simulated by
/// `DemoUSB`; `cfgutil` never runs (tested). Outside demo mode the pretend
/// iPhone is refused.
@MainActor
@Observable
final class RestoreController {

    struct Job: Equatable {
        enum Kind: Equatable {
            case restore
            case revive
        }

        enum State: Equatable {
            case running
            case succeeded
            case failed(String)
        }

        let kind: Kind
        /// The device as shown when the job started; the device itself
        /// reboots and reconnects several times while it runs.
        let deviceName: String
        let ecid: String
        /// File name of a chosen IPSW, nil for the latest version.
        let ipswName: String?
        let startedAt = Date.now
        var step = "Starting…"
        /// 0…1, or nil while the step has no measurable progress.
        var fraction: Double?
        var log: [String] = []
        var state: State = .running
    }

    private(set) var job: Job?

    var isRunning: Bool { job?.state == .running }

    /// The kind of the current (or just finished) job a list row belongs to,
    /// if any. A restore or revive passes the device through Recovery and a
    /// restore OS, which appear as separate rows without a serial number.
    func jobKind(involving device: USBDevice) -> Job.Kind? {
        guard let job,
              let wanted = Configurator.normalizedECID(job.ecid),
              let ecid = device.configuratorECID,
              let have = Configurator.normalizedECID(ecid),
              wanted == have, device.connectedAt >= job.startedAt
        else { return nil }
        // Recovery/DFU stages stay labelled until the banner is dismissed; a
        // booted row only while running — afterwards it's the restored device.
        return device.mode != .normal || job.state == .running ? job.kind : nil
    }

    private let logger = Logger(subsystem: "be.jordythery.SerialNumberReader", category: "Restore")
    /// Where "Action" entries go; nil records nothing (previews).
    private let activityLog: ActivityLog?
    /// Runs the job; Apple Configurator by default, a fake in tests.
    private let run: @Sendable (Configurator.Operation, String) -> AsyncThrowingStream<ConfiguratorEvent, any Error>
    /// Demo mode's pretend iPhone; nil without demo mode.
    private let demo: DemoUSB?

    init(activityLog: ActivityLog? = nil, demo: DemoUSB? = nil,
         run: @escaping @Sendable (Configurator.Operation, String) -> AsyncThrowingStream<ConfiguratorEvent, any Error>
            = { LiveUSBHardware().runConfigurator($0, ecid: $1) }) {
        self.activityLog = activityLog
        self.demo = demo
        self.run = run
    }

    /// Why the last `start` was refused, for the sheet to show; nil after a start.
    private(set) var refusal: String?

    /// Starts a Restore or Revive for one device. Refused (nil, with the
    /// reason in `refusal`) while another job is running, and for a device
    /// that doesn't belong to the current mode: a real one in demo mode, the
    /// pretend iPhone outside it.
    ///
    /// - Parameter serialNumber: named in the activity log, when known.
    @discardableResult
    func start(_ operation: Configurator.Operation, ecid: String, deviceName: String,
               serialNumber: String? = nil) -> Task<Void, Never>? {
        guard !isRunning else {
            refusal = "Another restore or revive is still running. Wait until it finishes, then try again."
            return nil
        }
        let simulated = demo?.isOn == true
        guard simulated == PretendIPhone.isPretend(ecid: ecid) else {
            logger.error("Restore refused: \(simulated ? "a real device in Demo Mode" : "the pretend iPhone outside Demo Mode", privacy: .public)")
            refusal = simulated
                ? "Demo Mode is on, so only the pretend iPhone can be restored. Turn off Demo Mode to restore this device."
                : "The pretend iPhone can only be restored in Demo Mode."
            return nil
        }
        refusal = nil
        let stream = if simulated, let demo { demo.run(operation, ecid: ecid) } else { run(operation, ecid) }
        let demoNote: String? = simulated ? DeviceActionController.demoNote : nil
        let connection: String? = simulated ? "Demo" : nil
        func note(_ text: String?) -> String? {
            let joined = [text, demoNote].compactMap { $0 }.joined(separator: " ")
            return joined.isEmpty ? nil : joined
        }
        let kind: Job.Kind
        var ipswName: String?
        switch operation {
        case .restore(let ipsw):
            kind = .restore
            ipswName = ipsw?.lastPathComponent
        case .revive:
            kind = .revive
        }
        job = Job(kind: kind, deviceName: deviceName, ecid: ecid, ipswName: ipswName)
        append("Started \(kind == .restore ? "restore" : "revive") of \(deviceName)"
               + (ipswName.map { " with \($0)" } ?? ""))
        let named = serialNumber.map { "\(deviceName) (\($0))" } ?? deviceName
        let devices = [serialNumber, ecid].compactMap { $0 }
        let verb = kind == .restore ? "restore" : "revive"
        activityLog?.recordAction("Started to \(verb) \(named) with Apple Configurator",
                                  note: note(kind == .restore ? "Firmware: \(ipswName ?? "the latest signed version")." : nil),
                                  service: "Apple Configurator", connection: connection, devices: devices)
        let started = ContinuousClock.now
        func elapsed() -> TimeInterval {
            let duration = started.duration(to: .now)
            return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }

        // Keep the Mac awake: sleeping mid-restore would interrupt it.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "Restoring a device with Apple Configurator")

        return Task {
            defer { ProcessInfo.processInfo.endActivity(activity) }
            do {
                for try await event in stream {
                    handle(event)
                }
                job?.state = .succeeded
                job?.fraction = 1
                append("Completed")
                activityLog?.recordAction("\(kind == .restore ? "Restored" : "Revived") \(named) with Apple Configurator",
                                          note: note(nil), service: "Apple Configurator", connection: connection,
                                          devices: devices, duration: elapsed())
            } catch {
                job?.state = .failed(error.localizedDescription)
                append("Failed: \(error.localizedDescription)")
                // cfgutil's message can name the device: private in the system log.
                logger.error("Restore failed: \(error.localizedDescription, privacy: .private)")
                activityLog?.recordAction("Couldn’t \(verb) \(named) with Apple Configurator",
                                          note: note(error.localizedDescription), failed: true,
                                          service: "Apple Configurator", connection: connection,
                                          devices: devices, duration: elapsed())
            }
        }
    }

    /// Clears a finished job's banner.
    func dismiss() {
        guard !isRunning else { return }
        job = nil
    }

    private func handle(_ event: ConfiguratorEvent) {
        switch event {
        case .step(let name):
            job?.step = name
            job?.fraction = nil
            append(name)
        case .stepComplete:
            break
        case .progress(let step, let fraction):
            if let step { job?.step = step }
            job?.fraction = fraction
        case .error(let message):
            append("Error: \(message)")
        case .finished:
            break
        }
    }

    private func append(_ line: String) {
        let time = Date.now.formatted(date: .omitted, time: .standard)
        job?.log.append("\(time)  \(line)")
    }
}

// MARK: - IPSW files

/// What a chosen IPSW contains, from its build manifest.
nonisolated struct IPSWInfo: Equatable, Sendable {
    let productVersion: String
    let buildVersion: String
    let supportedProductTypes: [String]

    func supports(_ productType: String) -> Bool {
        supportedProductTypes.contains(productType)
    }

    /// Parses BuildManifest.plist.
    static func parse(manifest: [String: Any]) -> IPSWInfo? {
        guard let version = manifest["ProductVersion"] as? String,
              let build = manifest["ProductBuildVersion"] as? String
        else { return nil }
        return IPSWInfo(
            productVersion: version,
            buildVersion: build,
            supportedProductTypes: manifest["SupportedProductTypes"] as? [String] ?? []
        )
    }

    /// Reads the manifest from an IPSW (a zip archive) without extracting
    /// it. Blocking — call off the main thread.
    static func read(from url: URL) throws -> IPSWInfo {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, "BuildManifest.plist"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let manifest = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let info = parse(manifest: manifest)
        else { throw Configurator.Failure(message: "This file isn't a readable IPSW.") }
        return info
    }
}

// MARK: - Signing status

/// Apple only installs firmware it still signs. Looks the status up in the
/// public ipsw.me data (sends only the model identifier and build), so a
/// restore that would be refused is caught before the device is erased.
/// Apple's signing server stays the final authority.
nonisolated enum FirmwareSigning {

    struct Firmware: Equatable, Sendable {
        let version: String
        let build: String
        let signed: Bool
    }

    /// What the pretend iPhone's Restore sheet shows in demo mode: a made-up
    /// signed release, so demo mode never asks ipsw.me.
    static let demoLatest = Firmware(version: "26.0", build: "23A0042", signed: true)

    /// Whether a specific build is signed for the model; nil when unknown.
    /// - Parameter pretendDevice: the pretend iPhone (demo mode): no lookup, signed.
    static func isSigned(productType: String, build: String, pretendDevice: Bool = false) async -> Bool? {
        if pretendDevice { return true }
        guard let url = URL(string: "https://api.ipsw.me/v4/ipsw/\(productType)/\(build)") else { return nil }
        struct Response: Decodable { let signed: Bool }
        guard let response: Response = await fetch(url) else { return nil }
        return response.signed
    }

    /// The newest signed release for the model; nil when unknown.
    /// - Parameter pretendDevice: the pretend iPhone (demo mode): no lookup, `demoLatest`.
    static func latestSigned(productType: String, pretendDevice: Bool = false) async -> Firmware? {
        if pretendDevice { return demoLatest }
        guard let url = URL(string: "https://api.ipsw.me/v4/device/\(productType)?type=ipsw") else { return nil }
        struct Response: Decodable {
            struct Entry: Decodable { let version: String; let buildid: String; let signed: Bool }
            let firmwares: [Entry]
        }
        guard let response: Response = await fetch(url) else { return nil }
        return response.firmwares
            .first { $0.signed }
            .map { Firmware(version: $0.version, build: $0.buildid, signed: true) }
    }

    private static func fetch<T: Decodable>(_ url: URL) async -> T? {
        // Under tests (the unit-test host, a sandbox run) no public lookups:
        // the answer is "unknown".
        guard !TestRun.isActive else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
