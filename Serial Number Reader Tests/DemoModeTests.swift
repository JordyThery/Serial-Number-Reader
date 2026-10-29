import Foundation
import JTKit
import JTKitTestSupport
import SwiftUI
import Testing
@testable import Serial_Number_Reader

/// Hardware that writes down every call. In demo mode none may arrive.
nonisolated final class TrapHardware: USBHardware, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var calls: [String] { lock.withLock { recorded } }

    private func note(_ call: String) { lock.withLock { recorded.append(call) } }

    func deviceInfo(udid: String) throws -> LockdownDeviceInfo {
        note("lockdown read")
        throw Configurator.Failure(message: "trap")
    }
    func hasPairRecord(udid: String) -> Bool { note("pair record"); return true }
    func enterRecovery(udid: String) throws { note("Enter Recovery") }
    func sendRecoveryCommands(_ commands: [String], toRegistryEntryID entryID: UInt64) -> String? {
        note("Recovery commands")
        return nil
    }
    func runPrivilegedVDM(_ action: String) -> DeviceActionController.Outcome { note("VDM \(action)"); return .done }
    var isConfiguratorAvailable: Bool { note("Configurator lookup"); return true }
    func listConfiguratorDevices() throws -> [ConfiguratorDevice] { note("cfgutil list"); return [] }
    func unpair(ecid: String) throws { note("cfgutil unpair") }
    func runConfigurator(_ operation: Configurator.Operation, ecid: String) -> AsyncThrowingStream<ConfiguratorEvent, any Error> {
        note("cfgutil \(operation)")
        return AsyncThrowingStream { $0.finish() }
    }
}

/// A switch for one test: not saved anywhere.
@MainActor
private func demoMode(on: Bool) -> DemoMode {
    DemoMode(key: "demoMode", arguments: ["app", DemoMode.launchArgument, on ? "YES" : "NO"])
}

/// The pretend iPhone without waiting: reboots and restore steps take no time.
@MainActor
private func pretendIPhone(_ mode: DemoMode) -> DemoUSB {
    DemoUSB(mode: mode, rebootTime: .zero, stepTime: .zero)
}

/// Waits (up to two seconds) until `condition` holds, e.g. after an observed change.
@MainActor
private func until(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<200 where !condition() {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// A real iPhone, booted, and one in Recovery mode (placeholder identifiers).
private let realIPhone = USBDevice(
    id: 0x1000_0A2B, mode: .normal, productID: 0x12A8, usbProductName: "iPhone",
    rawSerialDescriptor: "00008140001A2B3C4D5E6F70", descriptor: nil, udid: "00008140-001A2B3C4D5E6F70",
    modelInfo: nil, locationID: 0x0110_0000,
    configurator: ConfiguratorDevice(ecid: "0x1A2B3C4D5E6F70", udid: "00008140-001A2B3C4D5E6F70",
                                     deviceType: "iPhone17,3", locationID: 0x0110_0000),
    isTrusted: true, connectedAt: .now)
private let realRecovery = USBDevice(
    id: 0x1000_0A2C, mode: .recovery, productID: 0x1281, usbProductName: "Apple Mobile Device (Recovery Mode)",
    rawSerialDescriptor: "CPID:8140 BDID:08 ECID:001A2B3C4D5E6F71 SRNM:[F9FXK2Q3HGMN]",
    descriptor: DescriptorParser.parse("CPID:8140 BDID:08 ECID:001A2B3C4D5E6F71 SRNM:[F9FXK2Q3HGMN]"),
    udid: "00008140-001A2B3C4D5E6F71", modelInfo: nil, locationID: 0x0120_0000, connectedAt: .now)

@MainActor
@Suite("Demo mode: the pretend iPhone and real USB devices")
struct DemoUSBTests {
    @Test("In demo mode nothing reaches a real device or cfgutil, also with a real iPhone plugged in")
    func neverRealHardware() async throws {
        let trap = TrapHardware()
        let mode = demoMode(on: true)
        let usb = pretendIPhone(mode)
        let log = ActivityLog()
        let monitor = USBDeviceMonitor(hardware: trap, demo: usb)
        let actions = DeviceActionController(activityLog: log, hardware: trap, demo: usb)
        let restore = RestoreController(activityLog: log, demo: usb) { trap.runConfigurator($0, ecid: $1) }
        monitor.start()
        defer { monitor.stop() }

        // USB isn't watched; a real iPhone arriving is neither read nor listed.
        #expect(!monitor.isWatchingUSB)
        monitor.add(realIPhone)
        monitor.add(realRecovery)
        #expect(monitor.devices.count == 1 && monitor.devices.allSatisfy(PretendIPhone.isPretend))
        monitor.refreshTrust(deviceID: realIPhone.id)

        // Every action on the real devices is refused before anything runs.
        for device in [realIPhone, realRecovery] {
            actions.restart(device: device)
            actions.enterDFU(device: device)
            actions.enterRecovery(device: device)
            actions.bootToNormal(device: device)
            actions.removeTrust(device: device) {}
            #expect(actions.runningAction == nil)
            let ecid = try #require(device.configuratorECID)
            #expect(restore.start(.restore(ipsw: nil), ecid: ecid, deviceName: "iPhone") == nil)
            #expect(restore.start(.revive, ecid: ecid, deviceName: "iPhone") == nil)
        }
        #expect(actions.lastError?.contains("Demo Mode is on") == true)

        // Every action on the pretend iPhone is simulated, start to finish.
        struct NotConnected: Error {}
        func pretend() throws -> USBDevice {
            guard let device = monitor.devices.first(where: \.isConnected) else { throw NotConnected() }
            return device
        }
        func run(_ action: (USBDevice) -> Void) async throws {
            action(try pretend())
            await actions.currentTask?.value
        }
        #expect(try pretend().mode == .normal && pretend().isTrusted)
        try await run { actions.removeTrust(device: $0) {} }
        #expect(try !pretend().isTrusted)
        try await run(actions.enterRecovery(device:))    // iOS 27: refused without trust
        #expect(actions.trustRequiredDeviceID == (try pretend().id))
        try await run(actions.restart(device:))
        #expect(try pretend().mode == .normal && pretend().isTrusted)
        try await run(actions.enterRecovery(device:))
        #expect(try pretend().mode == .recovery && pretend().serialNumber == PretendIPhone.serial)
        try await run(actions.bootToNormal(device:))
        #expect(try pretend().mode == .normal)
        try await run(actions.enterDFU(device:))
        #expect(try pretend().mode == .dfu && pretend().isOpaqueDFU)
        let ecid = try #require(try pretend().configuratorECID)
        await restore.start(.restore(ipsw: nil), ecid: ecid, deviceName: "iPhone 16", serialNumber: PretendIPhone.serial)?.value
        #expect(restore.job?.state == .succeeded)
        #expect(try pretend().mode == .normal && pretend().lockdownInfo?.deviceName == "iPhone", "erased")
        try await run(actions.enterDFU(device:))
        await restore.start(.revive, ecid: ecid, deviceName: "iPhone 16")?.value
        #expect(try pretend().mode == .normal)

        #expect(trap.calls.isEmpty, "\(trap.calls)")
        #expect(log.entries.count == 11)
        #expect(log.entries.allSatisfy {
            $0.category == "Action" && $0.connection == "Demo" && $0.note?.contains(DeviceActionController.demoNote) == true
        })
    }

    @Test("Outside demo mode the pretend iPhone is refused, and the real doorway refuses its identifiers")
    func pretendOutsideDemo() async throws {
        let trap = TrapHardware()
        let mode = demoMode(on: true)
        let usb = pretendIPhone(mode)
        usb.connect()
        let device = try #require(usb.devices.first)
        mode.isOn = false
        let actions = DeviceActionController(hardware: trap, demo: usb)
        let restore = RestoreController(demo: usb) { trap.runConfigurator($0, ecid: $1) }
        actions.restart(device: device)
        actions.enterRecovery(device: device)
        actions.removeTrust(device: device) {}
        #expect(actions.runningAction == nil && actions.lastError == PretendIPhone.refusal)
        #expect(restore.start(.revive, ecid: try #require(device.configuratorECID), deviceName: "iPhone") == nil)
        #expect(trap.calls.isEmpty)

        // The second safeguard: the real hardware refuses the pretend identifiers before sending.
        let live = LiveUSBHardware()
        let udid = try #require(PretendIPhone.udid)
        #expect(throws: Configurator.Failure.self) { try live.enterRecovery(udid: udid) }
        #expect(throws: Configurator.Failure.self) { try live.deviceInfo(udid: udid) }
        #expect(!live.hasPairRecord(udid: udid))
        #expect(live.sendRecoveryCommands(["reboot"], toRegistryEntryID: device.id) == PretendIPhone.refusal)
        #expect(throws: Configurator.Failure.self) { try live.unpair(ecid: PretendIPhone.ecid) }
        await #expect(throws: Configurator.Failure.self) {
            for try await _ in live.runConfigurator(.revive, ecid: Configurator.cfgutilECID(PretendIPhone.ecid)) {}
        }
    }

    @Test("Watching USB stops when demo mode is turned on and starts again when it's turned off")
    func watchingFollowsTheSwitch() async {
        let mode = demoMode(on: false)
        let monitor = USBDeviceMonitor(hardware: TrapHardware(), demo: pretendIPhone(mode))
        monitor.start()
        defer { monitor.stop() }
        #expect(monitor.isWatchingUSB && !monitor.devices.contains(where: PretendIPhone.isPretend))

        mode.isOn = true
        await until { !monitor.isWatchingUSB }
        #expect(!monitor.isWatchingUSB)
        #expect(monitor.devices.count == 1 && monitor.devices.allSatisfy(PretendIPhone.isPretend))

        mode.isOn = false
        await until { monitor.isWatchingUSB }
        #expect(monitor.isWatchingUSB && !monitor.devices.contains(where: PretendIPhone.isPretend))
    }

    @Test("The pretend iPhone is device 42 of JTKit's sample devices, with obviously fake identifiers")
    func clearlyFake() throws {
        let sample = try #require(PretendIPhone.sample)
        #expect(sample.serial == PretendIPhone.serial && sample.serial.hasPrefix("ZZDEMO"))
        #expect(sample.family == .iPhone && sample.managedBy == .jamfPro && sample.organization == .contoso)
        #expect(DemoSamples.isDemoID(try #require(PretendIPhone.udid)))
        #expect(PretendIPhone.ecid.hasPrefix("00DE0DE0"))
        #expect(PretendIPhone.isPretend(id: PretendIPhone.idPrefix + 1))
        #expect(!PretendIPhone.isPretend(id: realIPhone.id) && !PretendIPhone.isPretend(realIPhone))
        #expect(!PretendIPhone.isPretend(realRecovery))
    }
}

@MainActor
@Suite("Demo mode: Jamf lookups and connections")
struct DemoJamfTests {
    /// A store whose real network is a fake server that must stay unused in demo mode.
    /// Its settings domain is removed with its file by the test (`defer`).
    private func store(_ mode: DemoMode, server: MockServer, log: ActivityLog? = nil)
        -> (JamfStore, TemporaryDefaults) {
        let settings = TemporaryDefaults("demo")
        let connections = JamfConnectionStore(defaults: settings.defaults, secrets: InMemorySecretStore())
        return (JamfStore(connections: connections, activityLog: log ?? ActivityLog(), session: server.session, demo: mode), settings)
    }

    private func found(_ store: JamfStore, _ device: USBDevice) async -> JamfDeviceRecord? {
        store.lookupIfNeeded(for: device)
        await until { store.state(for: device) != .loading }
        if case .found(let record) = store.state(for: device) { return record }
        return nil
    }

    @Test("Contoso Jamf Pro finds the pretend iPhone, booted and in Recovery; the asset tag is saved there")
    func jamfPro() async throws {
        let server = MockServer { _ in .json(500, "{}") }
        let mode = demoMode(on: true)
        let log = ActivityLog()
        let (store, settings) = store(mode, server: server, log: log)
        defer { settings.remove() }
        let usb = pretendIPhone(mode)
        usb.connect()
        let booted = try #require(usb.devices.first)

        #expect(store.demoConnection == .demoJamfPro && store.productName == "Jamf Pro")
        #expect(store.isConfigured && store.webBaseURL == nil)
        let record = try #require(await found(store, booted))
        #expect(record.serialNumber == PretendIPhone.serial && record.assetTag == "CT-1042")
        #expect(await store.saveAssetTag("CT-2042", record: record, for: booted) == nil)
        #expect(mode.jamfProServer.assetTag(serial: PretendIPhone.serial) == "CT-2042")

        _ = await usb.enterRecovery()
        let recovery = try #require(usb.devices.first)
        #expect(recovery.jamfQuery == .serialNumber(PretendIPhone.serial))
        #expect(await found(store, recovery)?.udid == PretendIPhone.udid)

        #expect(server.requests.isEmpty, "the real network isn't used")
        #expect(!log.entries.isEmpty && log.entries.allSatisfy { $0.connection == Connection.demoJamfPro.name })
    }

    @Test("Contoso Academy (Jamf School) doesn't have Contoso's iPhone")
    func jamfSchool() async throws {
        let server = MockServer { _ in .json(500, "{}") }
        let mode = demoMode(on: true)
        let (store, settings) = store(mode, server: server)
        defer { settings.remove() }
        let usb = pretendIPhone(mode)
        usb.connect()
        let booted = try #require(usb.devices.first)
        let generation = store.configurationGeneration
        store.demoChoice?.selectedID = Connection.demoJamfSchool.id
        await until { store.configurationGeneration != generation }
        #expect(store.demoConnection == .demoJamfSchool && store.productName == "Jamf School")
        store.lookupIfNeeded(for: booted)
        await until { store.state(for: booted) != .loading }
        #expect(store.state(for: booted) == .noMatch)
        #expect(server.requests.isEmpty)
    }

    @Test("Test Connection in Settings stays real in demo mode")
    func testConnectionStaysReal() async throws {
        let server = MockServer { request in
            request.path == "/api/oauth/token"
                ? .json(200, #"{"access_token": "t", "expires_in": 1200}"#) : .json(200, "{}")
        }
        let mode = demoMode(on: true)
        let (store, settings) = store(mode, server: server)
        defer { settings.remove() }
        let record = JamfConnection(name: "Real", service: .jamfPro, signIn: .apiClient,
                                    serverURL: "pro.example.com", clientID: "client")
        #expect(try await store.testConnection(record, typedSecret: "secret") == "Authenticated successfully")
        #expect(!server.requests.isEmpty)
        #expect(server.requests.allSatisfy { $0.url.host() == "pro.example.com" })
        #expect(mode.jamfProServer.requestCount == 0)
        #expect(mode.isOn)
    }

    @Test("Demo mode leaves the saved connections and the one in use as they were")
    func savedConnectionsUnchanged() async throws {
        let server = MockServer { _ in .json(500, "{}") }
        let mode = demoMode(on: false)
        let (store, settings) = store(mode, server: server)
        defer { settings.remove() }
        let defaults = settings.defaults
        let saved = JamfConnection(name: "Real", service: .jamfPro, signIn: .apiClient,
                                   serverURL: "pro.example.com", clientID: "client")
        try store.connections.connections.save(saved, secrets: [.main: "secret"])
        store.connections.activeID = saved.id
        let list = defaults.data(forKey: JamfConnectionStore.listKey)
        let active = defaults.string(forKey: JamfConnectionStore.activeKey)

        mode.isOn = true
        await until { store.demoConnection != nil }
        #expect(store.demoConnection == .demoJamfPro && store.webBaseURL == nil)
        #expect(store.connectionRole(selection: .constant(saved.id)).usesDemo)
        #expect(store.connections.activeConnection == saved)
        #expect(throws: ConnectionStoreError.self) { try store.connections.connections.save(JamfConnection(
            name: "Contoso", service: .jamfPro, signIn: .apiClient, serverURL: "https://\(DemoWorld.jamfProHost)", clientID: "c")) }

        mode.isOn = false
        await until { store.demoConnection == nil }
        #expect(store.demoConnection == nil && store.connections.activeConnection == saved)
        #expect(defaults.data(forKey: JamfConnectionStore.listKey) == list)
        #expect(defaults.string(forKey: JamfConnectionStore.activeKey) == active)
    }
}
