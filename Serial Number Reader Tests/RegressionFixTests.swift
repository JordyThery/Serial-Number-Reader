import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Serial_Number_Reader

/// The fixes of 1.5.0 for what changed since 1.3 without being meant to:
/// Mac lookups on an older Jamf Pro (R1), the computer fallback for
/// devices that can't be a Mac (R2), http:// addresses (R3). The one-time
/// conversion that waits for a readable Keychain (R4) is in
/// `ConnectionConversionTests`.
@MainActor
@Suite("Regression fixes")
struct RegressionFixTests {
    private nonisolated static let serial = "PLACEHOLDR21"
    private nonisolated static let udid = "00008140-001A2B3C4D5E6F70"
    private nonisolated static let noDevices = #"{"totalCount": 0, "results": []}"#
    private nonisolated static let mobileDevice = """
        {"totalCount": 1, "results": [{"mobileDeviceId": "7", "udid": "\(udid)",
          "general": {"displayName": "Lab iPhone"}, "hardware": {"serialNumber": "\(serial)"}}]}
        """
    private nonisolated static let token = #"{"access_token": "t", "expires_in": 1200}"#

    private func client(_ server: MockServer, host: String = "pro.example.com") throws -> JamfService {
        let config = try #require(JamfConfiguration.make(
            urlString: host, credentials: .clientCredentials(clientID: "c", clientSecret: "s")))
        return try JamfService(configuration: config,
                               recorder: RequestRecorder(session: server.session, log: ActivityLog(), service: "Jamf Pro"))
    }

    /// A Jamf Pro server's paths, without JTKit's version question.
    private func paths(_ server: MockServer) -> [String] {
        server.requests.map(\.path).filter { !$0.hasSuffix("/jamf-pro-version") }
    }

    // MARK: R1: a Jamf Pro older than 11.30 gets the v1 computer paths

    @Test("R1: on Jamf Pro 11.29 a Mac's lookup and asset tag use the v1 computer paths")
    func olderJamfProUsesV1ComputerPaths() async throws {
        // Its own host: JTKit remembers each server's version while the app runs.
        let host = "pro-1129-\(UUID().uuidString.prefix(8).lowercased()).example.com"
        let server = MockServer { request in
            switch request.path {
            case "/api/oauth/token": .json(200, Self.token)
            case "/api/v1/jamf-pro-version": .json(200, #"{"version": "11.29.2-t1792501724838"}"#)
            case "/api/v2/mobile-devices/detail": .json(200, Self.noDevices)
            case "/api/v1/computers-inventory":
                .json(200, #"{"totalCount": 1, "results": [{"id": "42", "general": {"name": "Lab Mac"}, "hardware": {"serialNumber": "\#(Self.serial)"}}]}"#)
            case "/api/v1/computers-inventory-detail/42": .json(200, "{}")
            default: .json(404, "{}")
            }
        }
        let client = try client(server, host: host)

        let record = try #require(try await client.lookup(.serialNumber(Self.serial), computers: .always).record)
        try await client.updateAssetTag("LAB-03", record: record)

        #expect(record.kind == .computer && record.jamfID == "42")
        #expect(server.requests.contains { $0.path == "/api/v1/jamf-pro-version" })
        #expect(paths(server) == ["/api/oauth/token", "/api/v2/mobile-devices/detail",
                                  "/api/v1/computers-inventory", "/api/v1/computers-inventory-detail/42"])
        #expect(server.requests.last?.method == "PATCH")
        #expect(!server.requests.contains { $0.path.contains("/v4/") })
    }

    // MARK: R2: computers only for a device that could be a Mac

    private func refusingComputers() -> MockServer {
        MockServer { request in
            switch request.path {
            case "/api/oauth/token": .json(200, Self.token)
            case "/api/v2/mobile-devices/detail": .json(200, Self.noDevices)
            case "/api/v1/jamf-pro-version": .json(200, #"{"version": "11.31.0"}"#)
            default: .json(403, "{}")
            }
        }
    }

    @Test("R2: a booted iPhone with no mobile device record is no match, without asking for computers")
    func iPhoneDoesNotAskForComputers() async throws {
        let server = refusingComputers()
        #expect(try await client(server).lookup(.udid(Self.udid), computers: .skip) == .noMatch)
        #expect(!server.requests.contains { $0.path.contains("computers") })
    }

    @Test("R2: an iPhone identified in DFU: a refused computer lookup (403) is no match")
    func refusedComputersForIPhoneIsNoMatch() async throws {
        let server = refusingComputers()
        #expect(try await client(server).lookup(.udid(Self.udid), computers: .ifPermitted) == .noMatch)
        #expect(server.requests.contains { $0.path.contains("computers-inventory") })
    }

    @Test("R2: for a Mac a refused computer lookup is still an error, naming the privilege")
    func refusedComputersForMacFails() async throws {
        let server = refusingComputers()
        let client = try client(server)
        let error = await #expect(throws: JamfPlatform.APIError.self) {
            _ = try await client.lookup(.serialNumber(Self.serial), computers: .always)
        }
        #expect(error?.status == 403)
    }

    @Test("R2: which devices could be a Mac")
    func computerLookupPerDevice() {
        let bootedIPhone = USBDevice(id: 1, mode: .normal, productID: 0x12A8, usbProductName: "iPhone", descriptor: nil,
                                     udid: Self.udid, modelInfo: ModelDatabase.shared.model(identifier: "iPhone17,3"),
                                     connectedAt: .now)
        let bootedUnknown = USBDevice(id: 2, mode: .normal, productID: 0x12A8, usbProductName: "iPhone", descriptor: nil,
                                      udid: Self.udid, modelInfo: nil, connectedAt: .now)
        let recoveryIPhone = USBDevice(id: 3, mode: .recovery, productID: 0x1281, usbProductName: nil,
                                       descriptor: DescriptorParser.parse("CPID:8140 BDID:08 ECID:001A2B3C4D5E6F70 SRNM:[\(Self.serial)]"),
                                       udid: nil, modelInfo: ModelDatabase.shared.model(identifier: "iPhone17,3"),
                                       connectedAt: .now)
        let recoveryMac = USBDevice(id: 4, mode: .recovery, productID: 0x1281, usbProductName: nil,
                                    descriptor: DescriptorParser.parse("CPID:8103 BDID:26 ECID:001A2B3C4D5E6F71 SRNM:[\(Self.serial)]"),
                                    udid: nil, modelInfo: ModelDatabase.shared.model(identifier: "MacBookAir10,1"),
                                    connectedAt: .now)
        let configurator = ConfiguratorDevice(ecid: "0x1A2B3C4D5E6F70", udid: Self.udid, deviceType: "iPhone17,3",
                                              locationID: 0x0130_0000)
        let dfuIPhone = USBDevice(id: 5, mode: .dfu, productID: 0x1881, usbProductName: "Debug USB", descriptor: nil,
                                  udid: nil, modelInfo: ModelDatabase.shared.model(identifier: "iPhone17,3"),
                                  configurator: configurator, connectedAt: .now)
        let dfuUnknown = USBDevice(id: 6, mode: .dfu, productID: 0x1881, usbProductName: "Debug USB", descriptor: nil,
                                   udid: nil, modelInfo: nil, configurator: configurator, connectedAt: .now)

        #expect(bootedIPhone.computerLookup == .skip)
        #expect(bootedUnknown.computerLookup == .skip)
        #expect(recoveryIPhone.computerLookup == .skip)
        #expect(recoveryMac.computerLookup == .always)
        #expect(dfuIPhone.computerLookup == .ifPermitted)
        #expect(dfuUnknown.computerLookup == .always)
    }

    @Test("R2: the app's lookup of a booted iPhone not in Jamf shows no match with an iPhone-only API client")
    func storeShowsNoMatchForIPhone() async throws {
        let server = refusingComputers()
        let (store, settings) = try jamfStore(server: server, serverURL: "https://pro.example.com")
        defer { settings.remove() }
        let iPhone = USBDevice(id: 7, mode: .normal, productID: 0x12A8, usbProductName: "iPhone", descriptor: nil,
                               udid: Self.udid, modelInfo: ModelDatabase.shared.model(identifier: "iPhone17,3"),
                               connectedAt: .now)
        store.lookupIfNeeded(for: iPhone)
        await until { store.state(for: iPhone) != .loading }
        #expect(store.state(for: iPhone) == .noMatch)
        #expect(!server.requests.contains { $0.path.contains("computers") })
    }

    // MARK: R3: an http:// address

    private func jamfStore(server: MockServer, serverURL: String, service: ConnectionService = .jamfPro)
        throws -> (JamfStore, TemporaryDefaults) {
        let settings = TemporaryDefaults("regression")
        let connections = JamfConnectionStore(defaults: settings.defaults, secrets: InMemorySecretStore())
        let record = service == .jamfSchool
            ? JamfConnection(name: "School", service: .jamfSchool, signIn: .schoolAPIKey, serverURL: serverURL, clientID: "1234")
            : JamfConnection(name: "Pro", service: .jamfPro, signIn: .apiClient, serverURL: serverURL, clientID: "client")
        try connections.connections.save(record, secrets: [.main: "secret"])
        connections.activeID = record.id
        return (JamfStore(connections: connections, activityLog: ActivityLog(), session: server.session), settings)
    }

    private func until(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private var bootedIPhone: USBDevice {
        USBDevice(id: 8, mode: .normal, productID: 0x12A8, usbProductName: "iPhone", descriptor: nil,
                  udid: Self.udid, modelInfo: nil, connectedAt: .now)
    }

    @Test("R3: a saved http:// address shows JTKit's message, for Jamf Pro and Jamf School, and sends nothing",
          arguments: [ConnectionService.jamfPro, .jamfSchool])
    func httpAddressMessage(service: ConnectionService) async throws {
        let server = MockServer { _ in .json(200, "{}") }
        let (store, settings) = try jamfStore(server: server, serverURL: "http://jamf.example.com", service: service)
        defer { settings.remove() }

        #expect(store.state(for: bootedIPhone) == .failed(Connection.httpAddressProblem))
        store.lookupIfNeeded(for: bootedIPhone)
        let record = JamfDeviceRecord(kind: service == .jamfSchool ? .schoolDevice : .mobileDevice, jamfID: "7", name: nil,
                                      assetTag: nil, serialNumber: nil, udid: nil, model: nil, modelIdentifier: nil,
                                      osVersion: nil, managed: nil, username: nil, realName: nil, lastInventoryDate: nil)
        #expect(await store.saveAssetTag("X", record: record, for: bootedIPhone) == Connection.httpAddressProblem)
        let saved = try #require(store.connections.activeConnection)
        await #expect(throws: JamfSetupError(message: Connection.httpAddressProblem)) {
            _ = try await store.testConnection(saved, typedSecret: nil)
        }
        #expect(server.requests.isEmpty)
    }

    @Test("R3: changing only the scheme to https:// keeps the stored secret, and lookups work again")
    func schemeChangeKeepsSecret() async throws {
        let server = MockServer { request in
            request.path == "/api/oauth/token" ? .json(200, Self.token) : .json(200, Self.mobileDevice)
        }
        let (store, settings) = try jamfStore(server: server, serverURL: "http://pro.example.com")
        defer { settings.remove() }
        var record = try #require(store.connections.activeConnection)

        // What Settings › Connections saves when only the address changed: the
        // record, no secret (JTKit keeps the stored one for the same server).
        record.serverURL = "https://pro.example.com"
        try store.connections.connections.save(record)
        await until { store.connectionProblem == nil }

        #expect((try store.connections.readSecret(for: record)) == "secret")
        #expect(store.configuration?.secret == "secret")
        store.lookupIfNeeded(for: bootedIPhone)
        await until { store.state(for: bootedIPhone) != .loading }
        #expect(store.state(for: bootedIPhone).isFound)
        #expect(server.requests.first?.bodyString.contains("client_secret=secret") == true)
    }
}

private extension JamfLookupState {
    var isFound: Bool {
        if case .found = self { return true }
        return false
    }
}
