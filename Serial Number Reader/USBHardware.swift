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
nonisolated struct LiveUSBHardware: USBHardware {
    func deviceInfo(udid: String) throws -> LockdownDeviceInfo {
        try PretendIPhone.refuse(udid: udid)
        return try Usbmux.deviceInfo(udid: udid)
    }

    func hasPairRecord(udid: String) -> Bool {
        guard !PretendIPhone.isPretend(udid: udid) else { return false }
        return Usbmux.hasPairRecord(udid: udid)
    }

    func enterRecovery(udid: String) throws {
        try PretendIPhone.refuse(udid: udid)
        try Usbmux.enterRecovery(udid: udid)
    }

    func sendRecoveryCommands(_ commands: [String], toRegistryEntryID entryID: UInt64) -> String? {
        guard !PretendIPhone.isPretend(id: entryID) else { return PretendIPhone.refusal }
        return RecoveryCommands.send(commands, toRegistryEntryID: entryID)
    }

    func runPrivilegedVDM(_ action: String) -> DeviceActionController.Outcome {
        DeviceActionController.runPrivilegedVDM(action)
    }

    var isConfiguratorAvailable: Bool { Configurator.isAvailable }

    func listConfiguratorDevices() throws -> [ConfiguratorDevice] {
        try Configurator.listDevices()
    }

    func unpair(ecid: String) throws {
        try PretendIPhone.refuse(ecid: ecid)
        try Configurator.unpair(ecid: ecid)
    }

    func runConfigurator(_ operation: Configurator.Operation, ecid: String) -> AsyncThrowingStream<ConfiguratorEvent, any Error> {
        guard !PretendIPhone.isPretend(ecid: ecid) else {
            return AsyncThrowingStream { $0.finish(throwing: Configurator.Failure(message: PretendIPhone.refusal)) }
        }
        return Configurator.run(operation, ecid: ecid)
    }
}
