import CryptoKit
import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Serial_Number_Reader

/// A refusing guard writing to a file of the test's own, so these tests never
/// add to the attempts the release check reads.
private func temporaryLog() -> TestRun.AttemptLog {
    TestRun.AttemptLog(fileURL: FileManager.default.temporaryDirectory
        .appending(path: "snr-under-test-\(UUID().uuidString)/attempts.jsonl"))
}

@MainActor
@Suite("Under tests: no real USB device and no saved connection")
struct UnderTestTests {
    // Made-up identifiers, not the pretend iPhone's (those are refused before the guard).
    let udid = "00000000-000A11CE0000000A"
    let ecid = "0xA11CE"

    @Test("The unit-test host counts as under tests")
    func hostIsUnderTest() {
        #expect(TestRun.isActive)
        #expect(USBGuard.shared.isActive)
    }

    @Test("Every USB action, device read and cfgutil run is refused and written down")
    func everyUSBCallIsRefused() async throws {
        let log = temporaryLog()
        defer { try? FileManager.default.removeItem(at: log.fileURL.deletingLastPathComponent()) }
        let live = LiveUSBHardware(underTest: USBGuard(isActive: true, log: log))

        #expect(throws: Configurator.Failure.self) { try live.deviceInfo(udid: udid) }
        #expect(!live.hasPairRecord(udid: udid))
        #expect(throws: Configurator.Failure.self) { try live.enterRecovery(udid: udid) }
        #expect(live.sendRecoveryCommands(["reboot"], toRegistryEntryID: 0xA11CE) == UnderTest.refusal)
        #expect(live.usbCPort(forEntryID: 0x1000_0A01) == .failure(.underTest))
        #expect(live.runPrivilegedVDM("reboot", deviceEntryID: 0x1000_0A01) == .failed(UnderTest.refusal))
        #expect(live.runPrivilegedVDM("dfu", deviceEntryID: 0x1000_0A01) == .failed(UnderTest.refusal))
        #expect(throws: Configurator.Failure.self) { try live.listConfiguratorDevices() }
        #expect(throws: Configurator.Failure.self) { try live.unpair(ecid: ecid) }
        await #expect(throws: Configurator.Failure.self) {
            for try await _ in live.runConfigurator(.restore(ipsw: nil), ecid: ecid) {}
        }
        await #expect(throws: Configurator.Failure.self) {
            for try await _ in live.runConfigurator(.revive, ecid: ecid) {}
        }

        #expect(log.attempts().map(\.what) == [
            "lockdown read", "pair record check", "Enter Recovery", "Boot to Normal (Recovery commands)",
            "USB-C port check", "Restart (VDM reboot)", "Enter DFU (VDM dfu)", "cfgutil list", "Remove Trust (cfgutil unpair)",
            "Restore (cfgutil)", "Revive (cfgutil)",
        ])
    }

    @Test("The actions go through the guarded doorway: a refused Restart is an error, not a run")
    func actionsAreRefused() async throws {
        let log = temporaryLog()
        defer { try? FileManager.default.removeItem(at: log.fileURL.deletingLastPathComponent()) }
        let activity = ActivityLog()
        let actions = DeviceActionController(activityLog: activity, hardware: LiveUSBHardware(underTest: USBGuard(isActive: true, log: log)))
        let restore = RestoreController(activityLog: activity) { operation, ecid in
            LiveUSBHardware(underTest: USBGuard(isActive: true, log: log)).runConfigurator(operation, ecid: ecid)
        }
        _ = restore.start(.revive, ecid: ecid, deviceName: "iPhone")
        await until { log.attempts().contains { $0.what == "Revive (cfgutil)" } }
        #expect(log.attempts().contains { $0.what == "Revive (cfgutil)" })
        #expect(actions.runningAction == nil)
    }

    @Test("Outside tests the guard does nothing")
    func offOutsideTests() throws {
        let log = temporaryLog()
        defer { try? FileManager.default.removeItem(at: log.fileURL.deletingLastPathComponent()) }
        let off = USBGuard(isActive: false, log: log)
        #expect(off.refusal(for: "Restart") == nil)
        try off.check("cfgutil list")
        #expect(log.attempts().isEmpty)
    }

    @Test("Under tests the app's own monitor doesn't watch real USB; one with other hardware still may")
    func monitorDoesNotWatchRealUSB() {
        let real = USBDeviceMonitor()
        real.start()
        defer { real.stop() }
        #expect(!real.isWatchingUSB)

        let outside = USBDeviceMonitor(hardware: TrapHardware(), underTest: true)
        outside.start()
        defer { outside.stop() }
        #expect(outside.isWatchingUSB)
    }

    @Test("A request for a saved connection is refused before it's sent, and written down without its query")
    func savedConnectionRequestsAreRefused() async throws {
        let log = temporaryLog()
        defer { try? FileManager.default.removeItem(at: log.fileURL.deletingLastPathComponent()) }
        let session = TestRun.refusingSession(log: log, message: UnderTest.refusal)
        var request = URLRequest(url: URL(string: "https://example.jamfcloud.com/api/v2/mobile-devices/detail?filter=serialNumber%3D%3D%22PLACEHOLDER1%22")!)
        request.httpMethod = "GET"
        let error = await #expect(throws: URLError.self) { _ = try await session.data(for: request) }
        // No answer, never a cancellation.
        #expect(error?.code == .resourceUnavailable)
        #expect(error?.localizedDescription == UnderTest.refusal)
        #expect(log.attempts().map(\.what) == ["GET example.jamfcloud.com/api/v2/mobile-devices/detail"])
    }

    @Test("A lookup and Test Connection for a saved Apple account are refused before they're sent, and written down")
    func savedAppleAccountIsRefused() async throws {
        let log = temporaryLog()
        defer { try? FileManager.default.removeItem(at: log.fileURL.deletingLastPathComponent()) }
        let settings = TemporaryDefaults("under-test-apple")
        defer { settings.remove() }
        // A fake Apple that answers everything: nothing may reach it.
        let server = MockServer { _ in .json(200, #"{"access_token": "x", "expires_in": 3600}"#) }
        let connections = AppConnectionStore(defaults: settings.defaults, secrets: InMemorySecretStore(), countsAsSaved: true)
        let record = AppleBusinessConnection(name: "Lab Org", service: .appleBusinessManager, signIn: .applePrivateKey,
                                             clientID: "BUSINESSAPI.00000000-0000-0000-0000-000000000000",
                                             keyID: "key-id-placeholder")
        let pem = P256.Signing.PrivateKey().pemRepresentation
        try connections.connections.save(.apple(record), secrets: [.main: pem])
        connections.activeAppleID = record.id
        let store = AppleBusinessStore(connections: connections, activityLog: ActivityLog(), session: server.session,
                                       underTestLog: log)

        store.lookupIfNeeded(serial: "PLACEHOLDR05")
        for _ in 0..<500 where store.state(forSerial: "PLACEHOLDR05") == .loading {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .failed = store.state(forSerial: "PLACEHOLDR05") else {
            Issue.record("The lookup wasn't refused: \(store.state(forSerial: "PLACEHOLDR05"))")
            return
        }
        await #expect(throws: (any Error).self) { _ = try await store.testConnection(record, typedSecret: nil) }

        #expect(server.requests.isEmpty)
        let attempts = log.attempts().map(\.what)
        #expect(!attempts.isEmpty)
        #expect(attempts.allSatisfy { $0.hasPrefix("POST account.apple.com") })
    }

    @Test("Only the app's real settings or Keychain count as the saved connections")
    func whatCountsAsSaved() {
        let settings = TemporaryDefaults("under-test")
        defer { settings.remove() }
        #expect(!AppConnectionStore(defaults: settings.defaults, secrets: InMemorySecretStore()).holdsSavedConnections)
        #expect(!AppConnectionStore.forUnitTestHost().holdsSavedConnections)
    }

    private func until(_ condition: @escaping () -> Bool) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(20)) }
    }
}
