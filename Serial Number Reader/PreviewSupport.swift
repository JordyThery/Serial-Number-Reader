import Foundation
import JTKit

/// What Xcode's previews show: demo mode's pretend iPhone and JTKit's demo
/// connections. A preview never reaches a real device, the saved connections,
/// the Keychain or the network.
@MainActor
enum PreviewSupport {
    /// Demo mode switched on for this preview only; saved nowhere.
    static let mode = DemoMode(key: "demoMode", arguments: ["app", DemoMode.launchArgument, "YES"])
    static let usb = DemoUSB(mode: mode)
}

/// USB hardware that refuses every call and reaches nothing: previews.
nonisolated struct NoUSBHardware: USBHardware {
    static let refusal = "Previews never reach a device."

    func deviceInfo(udid: String) throws -> LockdownDeviceInfo { throw Configurator.Failure(message: Self.refusal) }
    func hasPairRecord(udid: String) -> Bool { false }
    func enterRecovery(udid: String) throws { throw Configurator.Failure(message: Self.refusal) }
    func sendRecoveryCommands(_ commands: [String], toRegistryEntryID entryID: UInt64) -> String? { Self.refusal }
    func runPrivilegedVDM(_ action: String) -> DeviceActionController.Outcome { .failed(Self.refusal) }
    var isConfiguratorAvailable: Bool { false }
    func listConfiguratorDevices() throws -> [ConfiguratorDevice] { throw Configurator.Failure(message: Self.refusal) }
    func unpair(ecid: String) throws { throw Configurator.Failure(message: Self.refusal) }
    func runConfigurator(_ operation: Configurator.Operation, ecid: String) -> AsyncThrowingStream<ConfiguratorEvent, any Error> {
        AsyncThrowingStream { $0.finish(throwing: Configurator.Failure(message: Self.refusal)) }
    }
}

extension USBDeviceMonitor {
    /// Never watches USB, also when demo mode is switched off in the
    /// preview: the doorway refuses every call, as under tests.
    static var preview: USBDeviceMonitor {
        USBDeviceMonitor(hardware: LiveUSBHardware(underTest: USBGuard(isActive: true, log: .usb)),
                         demo: PreviewSupport.usb, underTest: true)
    }
}

extension JamfStore {
    /// A throwaway, empty list of connections without Keychain; demo mode's connections.
    static var preview: JamfStore { JamfStore(connections: .forUnitTestHost(), demo: PreviewSupport.mode) }
}

extension DeviceActionController {
    static var preview: DeviceActionController {
        DeviceActionController(hardware: NoUSBHardware(), demo: PreviewSupport.usb)
    }
}

extension RestoreController {
    static var preview: RestoreController {
        RestoreController(demo: PreviewSupport.usb, run: { NoUSBHardware().runConfigurator($0, ecid: $1) })
    }
}
