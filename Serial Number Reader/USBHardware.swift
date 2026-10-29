import Foundation

/// Everything the app does that reaches a USB device or starts a program for
/// one, apart from watching USB itself (IOKit, in `USBDeviceMonitor`): the
/// lockdown reads, Enter Recovery, the Recovery commands, the VDMs through the
/// administrator prompt and every use of `cfgutil`.
///
/// One doorway, so demo mode can be kept away from it: in demo mode the
/// controllers use `DemoUSB` instead and never call this (tested).
nonisolated protocol USBHardware: Sendable {
    /// Unpaired lockdown read of a booted device.
    func deviceInfo(udid: String) throws -> LockdownDeviceInfo
    /// Whether this Mac holds a pairing for a booted device.
    func hasPairRecord(udid: String) -> Bool
    func enterRecovery(udid: String) throws
    /// iBoot commands to a Recovery-mode device; nil when sent, else the message.
    func sendRecoveryCommands(_ commands: [String], toRegistryEntryID entryID: UInt64) -> String?
    /// Restart or Enter DFU over USB-C (`reboot` or `dfu`), through the administrator prompt.
    func runPrivilegedVDM(_ action: String) -> DeviceActionController.Outcome
    /// Whether Apple Configurator (and so `cfgutil`) is installed.
    var isConfiguratorAvailable: Bool { get }
    func listConfiguratorDevices() throws -> [ConfiguratorDevice]
    func unpair(ecid: String) throws
    func runConfigurator(_ operation: Configurator.Operation, ecid: String) -> AsyncThrowingStream<ConfiguratorEvent, any Error>
}

/// The real USB devices. As a second safeguard it refuses the pretend
/// iPhone's identifiers, so a pretend device can never reach real hardware.
/// Under tests it refuses everything else too, and writes each attempt down
/// (`USBGuard`): the release check fails on any.
nonisolated struct LiveUSBHardware: USBHardware {
    /// Refuses under tests; `.shared` decides from how the app was launched.
    var underTest: USBGuard = .shared

    func deviceInfo(udid: String) throws -> LockdownDeviceInfo {
        try PretendIPhone.refuse(udid: udid)
        try underTest.check("lockdown read")
        return try Usbmux.deviceInfo(udid: udid)
    }

    func hasPairRecord(udid: String) -> Bool {
        guard !PretendIPhone.isPretend(udid: udid) else { return false }
        guard underTest.refusal(for: "pair record check") == nil else { return false }
        return Usbmux.hasPairRecord(udid: udid)
    }

    func enterRecovery(udid: String) throws {
        try PretendIPhone.refuse(udid: udid)
        try underTest.check("Enter Recovery")
        try Usbmux.enterRecovery(udid: udid)
    }

    func sendRecoveryCommands(_ commands: [String], toRegistryEntryID entryID: UInt64) -> String? {
        guard !PretendIPhone.isPretend(id: entryID) else { return PretendIPhone.refusal }
        if let refusal = underTest.refusal(for: "Boot to Normal (Recovery commands)") { return refusal }
        return RecoveryCommands.send(commands, toRegistryEntryID: entryID)
    }

    func runPrivilegedVDM(_ action: String) -> DeviceActionController.Outcome {
        let name = action == "dfu" ? "Enter DFU" : "Restart"
        if let refusal = underTest.refusal(for: "\(name) (VDM \(action))") { return .failed(refusal) }
        return DeviceActionController.runPrivilegedVDM(action)
    }

    /// Only looks for Apple Configurator on disk; reaches no device.
    var isConfiguratorAvailable: Bool { Configurator.isAvailable }

    func listConfiguratorDevices() throws -> [ConfiguratorDevice] {
        try underTest.check("cfgutil list")
        return try Configurator.listDevices()
    }

    func unpair(ecid: String) throws {
        try PretendIPhone.refuse(ecid: ecid)
        try underTest.check("Remove Trust (cfgutil unpair)")
        try Configurator.unpair(ecid: ecid)
    }

    func runConfigurator(_ operation: Configurator.Operation, ecid: String) -> AsyncThrowingStream<ConfiguratorEvent, any Error> {
        guard !PretendIPhone.isPretend(ecid: ecid) else {
            return AsyncThrowingStream { $0.finish(throwing: Configurator.Failure(message: PretendIPhone.refusal)) }
        }
        if let refusal = underTest.refusal(for: "\(operation == .revive ? "Revive" : "Restore") (cfgutil)") {
            return AsyncThrowingStream { $0.finish(throwing: Configurator.Failure(message: refusal)) }
        }
        return Configurator.run(operation, ecid: ecid)
    }
}
