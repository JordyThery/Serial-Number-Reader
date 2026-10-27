import Foundation
import JTKit
import Observation

/// The pretend iPhone's identifiers: device 42 of JTKit's sample devices
/// (`DemoWorld`), "Contoso"'s iPhone 16 in "Contoso Jamf Pro", so the demo
/// Jamf Pro finds it. Its USB IDs and ECID are in a range no real device uses.
nonisolated enum PretendIPhone {
    static let serial = "ZZDEMOP42RX"
    /// Its record in JTKit's sample devices; nil if JTKit has none (no pretend iPhone then).
    static var sample: DemoWorld.Device? { DemoWorld.device(serial: serial) }
    /// JTKit's sample UDID, in its reserved fake range.
    static var udid: String? { sample?.udid }
    /// 16 hex digits; "DE0DE0…" marks it as a demo value.
    static let ecid = "00DE0DE0DE0DE042"
    /// The iPhone 16's chip and board, as its Recovery descriptor reports them.
    static let cpid = "8140"
    static let bdid = "08"
    static let locationID: UInt32 = 0xDE00_0000

    /// Its USB rows' IDs start with 0xDE00; IORegistry entry IDs of real
    /// devices are far smaller.
    static let idPrefix: UInt64 = 0xDE00_0000_0000_0000
    private static let idMask: UInt64 = 0xFFFF_0000_0000_0000

    /// What's shown when something tries to send the pretend iPhone's
    /// identifiers to real hardware.
    static let refusal = "This is Demo Mode’s pretend iPhone. Nothing was sent to a device."

    static func isPretend(id: UInt64) -> Bool { id & idMask == idPrefix }

    static func isPretend(udid: String) -> Bool {
        guard let mine = self.udid else { return false }
        return udid.caseInsensitiveCompare(mine) == .orderedSame
    }

    static func isPretend(ecid value: String) -> Bool {
        guard let normalized = Configurator.normalizedECID(value) else { return false }
        return normalized == ecid
    }

    /// Any of its identifiers, so a row is recognised whichever it carries.
    static func isPretend(_ device: USBDevice) -> Bool {
        isPretend(id: device.id)
            || device.serialNumber == serial
            || device.udid.map(isPretend(udid:)) == true
            || device.ecid.map(isPretend(ecid:)) == true
            || device.configurator.map { isPretend(ecid: $0.ecid) } == true
    }

    static func refuse(udid: String) throws {
        if isPretend(udid: udid) { throw Configurator.Failure(message: refusal) }
    }

    static func refuse(ecid: String) throws {
        if isPretend(ecid: ecid) { throw Configurator.Failure(message: refusal) }
    }
}

/// Demo Mode's pretend USB iPhone: it appears in the device list in Normal,
/// Recovery and DFU mode, and Restart, Enter DFU, Enter Recovery, Boot to
/// Normal, Remove Trust, Restore and Revive on it are simulated here, in
/// memory. Nothing in this class reaches USB, lockdown, IOKit or `cfgutil`.
@MainActor
@Observable
final class DemoUSB {
    let mode: DemoMode
    /// The pretend iPhone's rows, newest first, as `USBDeviceMonitor` lists real ones.
    private(set) var devices: [USBDevice] = []

    @ObservationIgnored private let rebootTime: Duration
    @ObservationIgnored private let stepTime: Duration
    @ObservationIgnored private var nextID = PretendIPhone.idPrefix
    @ObservationIgnored private var isTrusted = true
    /// Its name on the device: Contoso's, until a restore erases it.
    @ObservationIgnored private var deviceName = PretendIPhone.sample?.name ?? "iPhone"

    /// - Parameters:
    ///   - rebootTime: how long a simulated reboot keeps it away.
    ///   - stepTime: how long each simulated step of a restore takes.
    init(mode: DemoMode, rebootTime: Duration = .seconds(3), stepTime: Duration = .seconds(2)) {
        self.mode = mode
        self.rebootTime = rebootTime
        self.stepTime = stepTime
    }

    var isOn: Bool { mode.isOn }

    private var current: USBDevice? { devices.first { $0.isConnected } }

    // MARK: Plugging in

    /// Plugs the pretend iPhone in, booted (demo mode turned on).
    func connect() {
        guard devices.isEmpty else { return }
        appear(.normal)
    }

    /// Takes it away again (demo mode turned off).
    func disconnect() {
        devices.removeAll()
        isTrusted = true
        deviceName = PretendIPhone.sample?.name ?? "iPhone"
    }

    func removeFromList(_ id: USBDevice.ID) {
        devices.removeAll { $0.id == id && !$0.isConnected }
    }

    func clearDisconnected() {
        devices.removeAll { !$0.isConnected }
    }

    // MARK: Actions

    /// Restart: it goes away and comes back in the same mode (from DFU: booted).
    func restart() async -> DeviceActionController.Outcome {
        guard let current else { return .failed("The pretend iPhone isn’t connected.") }
        return await reboot(into: current.mode == .recovery ? .recovery : .normal)
    }

    func enterDFU() async -> DeviceActionController.Outcome {
        await reboot(into: .dfu)
    }

    /// As on iOS 27: refused while it doesn't trust this Mac.
    func enterRecovery() async -> DeviceActionController.Outcome {
        guard let current, current.mode == .normal else { return .failed("The pretend iPhone isn’t booted.") }
        guard isTrusted else { return .trustRequired(deviceID: current.id) }
        return await reboot(into: .recovery)
    }

    func bootToNormal() async -> DeviceActionController.Outcome {
        guard current?.mode == .recovery else { return .failed("The pretend iPhone isn’t in Recovery mode.") }
        return await reboot(into: .normal)
    }

    func removeTrust() async -> DeviceActionController.Outcome {
        guard let index = devices.firstIndex(where: { $0.isConnected && $0.mode == .normal }) else {
            return .failed("The pretend iPhone isn’t booted.")
        }
        isTrusted = false
        devices[index].isTrusted = false
        return .done
    }

    /// A Restore or Revive as Apple Configurator reports one, with the
    /// stages a real device passes through: Recovery without a serial, the
    /// restore OS, then booted (erased after a restore, content kept after a revive).
    func run(_ operation: Configurator.Operation, ecid: String) -> AsyncThrowingStream<ConfiguratorEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    try await self.simulate(operation, ecid: ecid, continuation)
                    continuation.yield(.finished)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func simulate(_ operation: Configurator.Operation, ecid: String,
                          _ continuation: AsyncThrowingStream<ConfiguratorEvent, any Error>.Continuation) async throws {
        guard PretendIPhone.isPretend(ecid: ecid), current != nil else {
            throw Configurator.Failure(message: "The pretend iPhone isn’t connected.")
        }
        let erases = if case .restore = operation { true } else { false }
        continuation.yield(.step("Preparing"))
        try await Task.sleep(for: stepTime)
        continuation.yield(.step("Unzipping firmware"))
        for tenth in 1...10 {
            try await Task.sleep(for: stepTime / 5)
            continuation.yield(.progress(step: "Unzipping firmware", fraction: Double(tenth) / 10))
        }
        continuation.yield(.stepComplete("Unzipping firmware"))
        continuation.yield(.step("Preparing the device"))
        detach()
        try await Task.sleep(for: stepTime)
        appear(.recovery, withSerial: false)
        continuation.yield(.step(erases ? "Restoring" : "Reviving"))
        try await Task.sleep(for: stepTime * 2)
        detach()
        continuation.yield(.step("Waiting for the device"))
        try await Task.sleep(for: stepTime)
        if erases {
            // Erased: Contoso's name and this Mac's pairing are gone.
            deviceName = "iPhone"
            isTrusted = false
        }
        appear(.normal)
    }

    // MARK: Rows

    private enum Stage { case normal, recovery, dfu }

    private func reboot(into stage: Stage) async -> DeviceActionController.Outcome {
        detach()
        try? await Task.sleep(for: rebootTime)
        guard isOn else { return .done }
        if stage == .normal, current == nil {
            // Back on the Lock Screen: you tapped Trust again, so the demo can go on.
            isTrusted = true
        }
        appear(stage)
        return .done
    }

    private func detach() {
        guard let index = devices.firstIndex(where: \.isConnected) else { return }
        devices[index].isConnected = false
        devices[index].disconnectedAt = .now
    }

    private func appear(_ stage: Stage, withSerial: Bool = true) {
        guard let sample = PretendIPhone.sample, let udid = PretendIPhone.udid else { return }
        detach()
        nextID += 1
        let model = ModelDatabase.shared.model(identifier: sample.modelIdentifier)
        let configurator = ConfiguratorDevice(ecid: Configurator.cfgutilECID(PretendIPhone.ecid), udid: udid,
                                              deviceType: sample.modelIdentifier, locationID: PretendIPhone.locationID)
        var device: USBDevice
        switch stage {
        case .normal:
            device = USBDevice(
                id: nextID, mode: .normal, productID: 0x12A8, usbProductName: "iPhone",
                rawSerialDescriptor: udid, descriptor: nil, udid: udid, modelInfo: model,
                lockdownInfo: LockdownDeviceInfo(productType: sample.modelIdentifier, productVersion: sample.osVersion,
                                                 buildVersion: "25A0042", deviceClass: "iPhone", deviceName: deviceName),
                locationID: PretendIPhone.locationID, configurator: configurator, isTrusted: isTrusted,
                connectedAt: .now)
        case .recovery:
            let raw = "CPID:\(PretendIPhone.cpid) CPRV:11 CPFM:03 SCEP:01 BDID:\(PretendIPhone.bdid) "
                + "ECID:\(PretendIPhone.ecid) IBFL:3C" + (withSerial ? " SRNM:[\(PretendIPhone.serial)]" : "")
            device = USBDevice(
                id: nextID, mode: .recovery, productID: USBDeviceMonitor.recoveryProductID,
                usbProductName: "Apple Mobile Device (Recovery Mode)", rawSerialDescriptor: raw,
                descriptor: DescriptorParser.parse(raw), udid: nil,
                modelInfo: ModelDatabase.shared.model(cpidHex: PretendIPhone.cpid, bdidHex: PretendIPhone.bdid) ?? model,
                locationID: PretendIPhone.locationID, configurator: configurator, connectedAt: .now)
        case .dfu:
            // Current hardware in DFU shows no identifiers over USB; Apple
            // Configurator (simulated) identifies it, so its UDID is known.
            device = USBDevice(
                id: nextID, mode: .dfu, productID: USBDeviceMonitor.debugUSBProductID, usbProductName: "Debug USB",
                rawSerialDescriptor: nil, descriptor: nil, udid: udid, modelInfo: model,
                locationID: PretendIPhone.locationID, configurator: configurator, connectedAt: .now)
        }
        // As the monitor does: its own earlier disconnected rows make way.
        if let key = device.identityKey {
            devices.removeAll { !$0.isConnected && $0.identityKey == key }
        }
        devices.insert(device, at: 0)
    }
}
