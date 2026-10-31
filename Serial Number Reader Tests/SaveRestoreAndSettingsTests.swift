import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Serial_Number_Reader

/// A Jamf School server in memory that keeps one device's asset tag, the
/// way Jamf stores it: upper-cased (a stand-in for any server-side change).
/// Asset-tag saves can be held until the test lets them through.
nonisolated final class AssetTagServer: @unchecked Sendable {
    static let serial = "PLACEHOLDR01"
    static let udid = "00008130-0000000000000001"

    private let lock = NSLock()
    private var tag = "OLD-TAG"
    private let gate = DispatchSemaphore(value: 0)
    private let holdsSaves: Bool
    lazy var server = MockServer { [unowned self] request in self.answer(request) }

    init(holdsSaves: Bool = false) {
        self.holdsSaves = holdsSaves
    }

    /// Lets a held save through.
    func release() { gate.signal() }

    var storedTag: String { lock.withLock { tag } }

    private func answer(_ request: RecordedRequest) -> MockResponse {
        if request.method == "POST" {
            if holdsSaves { gate.wait() }
            let sent = URLComponents(string: "?" + request.bodyString)?.queryItems?.first { $0.name == "assetTag" }?.value ?? ""
            lock.withLock { tag = sent.uppercased() }
            return .json(200, #"{"code": 200}"#)
        }
        let device = #"{"UDID": "\#(Self.udid)", "serialNumber": "\#(Self.serial)", "name": "Lab iPad", "assetTag": "\#(storedTag)"}"#
        if request.path.hasSuffix("/api/devices") { return .json(200, #"{"code": 200, "devices": [\#(device)]}"#) }
        return .json(200, #"{"code": 200, "device": \#(device)}"#)
    }
}

@MainActor
@Suite("Asset-tag saves, refused restores, demo lookups and test settings")
struct SaveRestoreAndSettingsTests {
    /// A store with one saved Jamf School connection (in memory) on `server`.
    private func store(_ server: MockServer, settings: TemporaryDefaults) throws -> JamfStore {
        let connections = JamfConnectionStore(defaults: settings.defaults, secrets: InMemorySecretStore())
        let record = JamfConnection(name: "School", service: .jamfSchool, signIn: .schoolAPIKey,
                                    serverURL: "school.example.com", clientID: "84512376")
        try connections.connections.save(record, secrets: [.main: "api-key"])
        connections.activeID = record.id
        return JamfStore(connections: connections, activityLog: ActivityLog(), session: server.session)
    }

    private func found(_ store: JamfStore, _ device: USBDevice) async -> JamfDeviceRecord? {
        store.lookupIfNeeded(for: device)
        await until { store.state(for: device) != .loading }
        if case .found(let record) = store.state(for: device) { return record }
        return nil
    }

    // MARK: Asset tag

    @Test("After a save the app shows the asset tag Jamf stored, not what was typed")
    func showsStoredAssetTag() async throws {
        let fake = AssetTagServer()
        let settings = TemporaryDefaults("saves")
        defer { settings.remove() }
        let store = try store(fake.server, settings: settings)
        let device = LiveDevice.recovery(serial: AssetTagServer.serial)
        let record = try #require(await found(store, device))
        #expect(record.assetTag == "OLD-TAG")

        #expect(await store.saveAssetTag("  lab-01 ", record: record, for: device) == nil)
        #expect(fake.storedTag == "LAB-01")
        guard case .found(let shown) = store.state(for: device) else { Issue.record("No record shown"); return }
        #expect(shown.assetTag == "LAB-01", "Jamf's value, read back")
    }

    @Test("A save that finishes after switching connections doesn't land in the new connection's list")
    func saveDuringSwitch() async throws {
        let fake = AssetTagServer(holdsSaves: true)
        let settings = TemporaryDefaults("saves")
        defer { settings.remove() }
        let store = try store(fake.server, settings: settings)
        let device = LiveDevice.recovery(serial: AssetTagServer.serial)
        let record = try #require(await found(store, device))

        let save = Task { await store.saveAssetTag("NEW-TAG", record: record, for: device) }
        await until { fake.server.requests.contains { $0.method == "POST" } }

        // Switch to another connection while the save waits on the server.
        let other = JamfConnection(name: "Other", service: .jamfSchool, signIn: .schoolAPIKey,
                                   serverURL: "other.example.com", clientID: "11111111")
        try store.connections.connections.save(other, secrets: [.main: "other-key"])
        let generation = store.configurationGeneration
        store.connections.activeID = other.id
        await until { store.configurationGeneration != generation }
        fake.release()
        #expect(await save.value == nil, "saved on the server that was in use")

        if case .found = store.state(for: device) {
            Issue.record("The old server's record was put in the new connection's list")
        }
    }

    // MARK: Restore

    @Test("A refused restore says why, and a later start clears it")
    func refusedRestoreSaysWhy() async throws {
        let mode = DemoMode(key: "demoMode", arguments: ["app", DemoMode.launchArgument, "NO"])
        let usb = DemoUSB(mode: mode)
        let restore = RestoreController(demo: usb) { _, _ in AsyncThrowingStream { _ in } }

        // The pretend iPhone outside demo mode.
        #expect(restore.start(.revive, ecid: PretendIPhone.ecid, deviceName: "iPhone") == nil)
        #expect(restore.refusal?.contains("Demo Mode") == true)

        // A real device while another job runs.
        let running = restore.start(.revive, ecid: "0xA11CE", deviceName: "iPad")
        #expect(running != nil && restore.refusal == nil)
        #expect(restore.start(.restore(ipsw: nil), ecid: "0xA11CF", deviceName: "iPad") == nil)
        #expect(restore.refusal?.contains("still running") == true)
        running?.cancel()
    }

    @Test("The pretend iPhone's Restore sheet asks ipsw.me nothing")
    func pretendFirmwareIsLocal() async {
        #expect(await FirmwareSigning.latestSigned(productType: "iPhone17,3", pretendDevice: true) == FirmwareSigning.demoLatest)
        #expect(await FirmwareSigning.isSigned(productType: "iPhone17,3", build: "23A0042", pretendDevice: true) == true)
        // Under tests a real model gets "unknown" without a lookup either.
        #expect(await FirmwareSigning.latestSigned(productType: "iPhone17,3") == nil)
    }

    // MARK: Test host settings

    @Test("A demo switch left on in the test host's settings is emptied before it's read")
    func staleDemoSwitchIsEmptied() {
        let settings = TemporaryDefaults("saves")
        defer { settings.remove() }
        settings.defaults.set(true, forKey: "demoMode")
        let emptied = JamfConnectionStore.emptiedDefaults(domain: settings.domain)
        #expect(emptied.object(forKey: "demoMode") == nil)
        #expect(!DemoMode(key: "demoMode", defaults: emptied).isOn)
        // And the app's own switch, made from the emptied host settings, is off.
        #expect(!AppDemo.mode.isOn)
    }

    @Test("A test's settings stay out of ~/Library/Preferences, also a moment after they're removed")
    func temporarySettingsLeaveNoFile() async {
        let settings = TemporaryDefaults("saves")
        settings.defaults.set("x", forKey: "k")
        settings.defaults.synchronize()
        #expect(settings.defaults.string(forKey: "k") == "x")
        settings.remove()
        // macOS writes an emptied domain back with a delay: wait for it.
        try? await Task.sleep(for: .seconds(2))
        #expect(settings.leavesNothingInPreferences)
    }

    private func until(_ condition: @escaping () -> Bool) async {
        for _ in 0..<150 where !condition() { try? await Task.sleep(for: .milliseconds(20)) }
    }
}
