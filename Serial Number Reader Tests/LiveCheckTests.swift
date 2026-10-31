import Foundation
import JTKit
import JTKitLiveCheck
import JTKitTestSupport
import Testing
@testable import Serial_Number_Reader

// Live checks (JTKit ROADMAP step 11), run only by Scripts/release-check.sh,
// which switches them on (JTKIT_LIVE=1) and passes the credentials it read
// from the login Keychain. ⌘U skips them. Tenants are named by role only:
// - jamfpro-readonly (Jamf Pro over the Platform API) and jamfschool-readonly:
//   read only. One serial is taken from the tenant's own inventory, kept in
//   memory only, and the app's own lookup must find it. Reports mask it.
// - jamfpro-production: the same, only with --include-production.
// - jamf-test-a (Platform API): the test code creates one JTKTEST mobile
//   device record with a made-up serial (not enrolled, not managed: nothing
//   reaches a device); the app looks it up and changes its asset tag with its
//   own Save; the test code reads it back; cleanup deletes the record.
// Every request goes through JTKitLiveCheck's guarded network. Throughout,
// the checks also prove that the app made no request to a saved connection
// and no USB attempt (`UnderTest`).

private let live = LiveCheckRun.isEnabled

#if JTKIT_FAULT_BREAK_BUILD
// Set only by `release-check.sh --fault break-build`, to check that a broken
// build stops the release check before anything reaches a tenant.
#error("Build broken on purpose by the release check's --fault break-build")
#endif

// MARK: Tenants

/// One allow-listed tenant: an in-memory connection (never saved) and the
/// app's own store on the guarded network.
@MainActor
struct LiveTenant {
    let role: String
    let service: AllowList.Service
    let record: JamfConnection
    let secret: String
    /// The app's own lookups and asset-tag Save, as in the app, but with an
    /// in-memory connection list and settings of this run's.
    let store: JamfStore
    let activity = ActivityLog()
    private let settings = TemporaryDefaults("live")

    /// - Parameter session: what the app's store sends through: the guarded
    ///   network, or a fence in front of it.
    init(run: LiveCheckRun, role: String, service: AllowList.Service, session: URLSession? = nil) throws {
        self.role = role
        self.service = service
        let entry = try run.entry(role: role, service: service)
        switch service {
        case .jamfPlatform:
            record = JamfConnection(name: "Live check \(role)", service: .jamfPlatform, signIn: .apiClient,
                                    region: try #require(JamfRegion(rawValue: entry.region ?? "")),
                                    environmentID: try #require(entry.environmentID),
                                    clientID: try run.credential(role, "client-id"))
            secret = try run.credential(role, "client-secret")
        case .jamfSchool:
            record = JamfConnection(name: "Live check \(role)", service: .jamfSchool, signIn: .schoolAPIKey,
                                    serverURL: "https://" + (try #require(entry.host)),
                                    clientID: try run.credential(role, "network-id"))
            secret = try run.credential(role, "api-key")
        default:
            throw LiveFailure("\(role): \(service.rawValue) isn't used by Serial Number Reader")
        }
        let connections = JamfConnectionStore(defaults: settings.defaults, secrets: InMemorySecretStore())
        try connections.connections.save(record, secrets: [.main: secret])
        connections.activeID = record.id
        store = JamfStore(connections: connections, activityLog: activity, session: session ?? run.network.session)
    }

    func removeSettings() {
        settings.remove()
    }

    /// JTKit's client for the test code (picking a serial, the test record),
    /// on the guarded network; never the app's store.
    func client(_ run: LiveCheckRun) throws -> JamfService {
        let configuration = try #require(JamfStore.configuration(for: record, secret: secret), "\(role): incomplete connection")
        return try JamfService(configuration: configuration,
                               recorder: RequestRecorder(session: run.network.session, log: nil, category: "Live check"))
    }

    /// The app's own lookup for a device in Recovery with this serial, as when
    /// one is plugged in: `lookupIfNeeded`, or `refresh` to read again.
    func lookUp(serial: String, again: Bool = false) async -> JamfLookupState {
        let device = LiveDevice.recovery(serial: serial)
        if again { store.refresh(for: device) } else { store.lookupIfNeeded(for: device) }
        for _ in 0..<300 {
            let state = store.state(for: device)
            if state != .loading { return state }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return store.state(for: device)
    }
}

/// A Recovery-mode device as the app sees one over USB, built in memory:
/// nothing is read from USB. Made-up ECID.
enum LiveDevice {
    static func recovery(serial: String) -> USBDevice {
        let descriptor = "CPID:8140 BDID:08 ECID:0000000000000001 SRNM:[\(serial)]"
        return USBDevice(id: 0xDE00_7E57, mode: .recovery, productID: 0x1281, usbProductName: "Apple Mobile Device (Recovery Mode)",
                         rawSerialDescriptor: descriptor, descriptor: DescriptorParser.parse(descriptor),
                         udid: nil, modelInfo: nil, connectedAt: .now)
    }
}

struct LiveFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The note for a failed step: a missing privilege is named.
func failure(_ error: any Error) -> String {
    if let error = error as? JamfPlatform.APIError, error.status == 401 || error.status == 403 {
        return "MISSING PRIVILEGE on the API client's role: \(error.localizedDescription)"
    }
    return "\(error)"
}

/// Replaces a serial in a note with its placeholder, so no report or log holds it.
func masked(_ text: String, serial: String) -> String {
    text.replacingOccurrences(of: serial, with: "serial 1", options: .caseInsensitive)
}

/// The two "under tests" checks, recorded as steps; any attempt fails the run.
@MainActor
func checkUnderTest(_ run: LiveCheckRun, when: String) {
    let usb = TestRun.AttemptLog.usb.attempts()
    run.record(step: "no USB action or cfgutil under tests (\(when))", passed: usb.isEmpty,
               note: usb.isEmpty ? nil : "\(usb.count) refused: " + usb.map { "\($0.what) (\($0.process))" }.joined(separator: "; "))
    #expect(usb.isEmpty, "USB attempts under tests: \(usb.map(\.what))")
    let saved = TestRun.AttemptLog.savedConnections.attempts()
    run.record(step: "no request to a saved connection under tests (\(when))", passed: saved.isEmpty,
               note: saved.isEmpty ? nil : "\(saved.count) refused: " + saved.map { "\($0.what) (\($0.process))" }.joined(separator: "; "))
    #expect(saved.isEmpty, "Requests to saved connections under tests: \(saved.map(\.what))")
}

// MARK: Picking one serial from a tenant's inventory (reads only)

@MainActor
enum Inventory {
    /// Why no serial was found (counts only, no identifiers), for the report.
    static var emptyNote = ""

    /// The serial of the first mobile device, else of the first computer.
    static func firstSerial(_ service: JamfService) async throws -> (serial: String, kind: String)? {
        emptyNote = ""
        switch service {
        case .pro(let client, _):
            let mobiles = try await client.json("pro/v2/mobile-devices/detail", query: [
                URLQueryItem(name: "section", value: "HARDWARE"), URLQueryItem(name: "page", value: "0"),
                URLQueryItem(name: "page-size", value: "1"),
            ], privilege: .readMobileDevices)
            if let serial = mobiles["results"]?.arrayValue?.first?["hardware"]?["serialNumber"]?.stringValue, !serial.isEmpty {
                return (serial, "mobile device")
            }
            let computers = try await client.json("pro/v4/computers-inventory", query: [
                URLQueryItem(name: "section", value: "HARDWARE"), URLQueryItem(name: "page", value: "0"),
                URLQueryItem(name: "page-size", value: "1"),
            ], privilege: .readComputers)
            if let serial = computers["results"]?.arrayValue?.first?["hardware"]?["serialNumber"]?.stringValue, !serial.isEmpty {
                return (serial, "computer")
            }
            let count = { (json: LosslessJSON) in json["totalCount"]?.numberValue?.intValue.map(String.init) ?? "?" }
            emptyNote = "\(count(mobiles)) mobile devices, \(count(computers)) computers"
            return nil
        case .school(let client):
            let fleet = try await client.fleet()
            guard let device = fleet.values.sorted(by: { $0.udid < $1.udid }).first,
                  let serial = device.serialNumber else {
                emptyNote = "\(fleet.count) devices with a serial"
                return nil
            }
            return (serial, "Jamf School device")
        }
    }
}

// MARK: The test record on jamf-test-a

/// Mobile device and computer records on jamf-test-a, through the Classic
/// API over the Platform gateway, the route the app's asset-tag change uses
/// too (so the guarded network's ledger matches).
@MainActor
struct TestDevices {
    static let resource = "mobiledevices"
    static let computers = "computers"
    let client: JamfPlatform.Client

    /// An unmanaged record that no device will ever enroll as, with no model
    /// or OS, like a record that never enrolled: Jamf types it "Unknown" and
    /// its device list leaves out the general section (name, asset tag), which
    /// JTKit 0.12.3 then reads from the record itself. Its name is the first
    /// `<name>`, which the guarded network checks for the run's prefix.
    func create(name: String, serial: String, udid: String) async throws -> String {
        let xml = """
        <mobile_device><general><name>\(escape(name))</name><display_name>\(escape(name))</display_name>\
        <device_name>\(escape(name))</device_name><serial_number>\(serial)</serial_number><udid>\(udid)</udid>\
        <asset_tag></asset_tag><managed>false</managed><supervised>false</supervised></general></mobile_device>
        """
        let response = try await client.send(HTTPRequest(method: "POST", path: JamfClassic.createPath(Self.resource),
                                                         body: Data(xml.utf8), accept: "application/xml", contentType: "application/xml"),
                                             privilege: "Create Mobile Devices")
        return try #require(JamfClassic.createdID(in: response.data), "The mobile device create returned no id")
    }

    /// An unmanaged computer record, never enrolled: a made-up Mac with a
    /// model and macOS, like a real one. Its name is the first `<name>`.
    func createComputer(name: String, serial: String, udid: String) async throws -> String {
        let xml = """
        <computer><general><name>\(escape(name))</name><serial_number>\(serial)</serial_number><udid>\(udid)</udid>\
        <asset_tag></asset_tag><remote_management><managed>false</managed></remote_management></general>\
        <hardware><model>MacBook Air (M2, 2022)</model><model_identifier>Mac14,2</model_identifier>\
        <os_name>macOS</os_name><os_version>15.0</os_version></hardware></computer>
        """
        let response = try await client.send(HTTPRequest(method: "POST", path: JamfClassic.createPath(Self.computers),
                                                         body: Data(xml.utf8), accept: "application/xml", contentType: "application/xml"),
                                             privilege: "Create Computers")
        return try #require(JamfClassic.createdID(in: response.data), "The computer create returned no id")
    }

    /// Every mobile device and computer record whose name marks it as a test object.
    func testRecords(_ run: LiveCheckRun) async throws -> [(resource: String, id: String, name: String)] {
        var found: [(resource: String, id: String, name: String)] = []
        for (resource, key, privilege) in [(Self.resource, "mobile_devices", JamfPro.Privilege.readMobileDevices),
                                           (Self.computers, "computers", JamfPro.Privilege.readComputers)] {
            // Classic answers XML unless asked for JSON.
            let response = try await client.send(HTTPRequest(method: "GET", path: "proclassic/\(resource)", accept: "application/json"),
                                                 privilege: privilege)
            let list = try LosslessJSON(data: response.data)
            for record in list[key]?.arrayValue ?? [] {
                if let id = record["id"]?.stringValue, let name = record["name"]?.stringValue, run.isSweepable(name) {
                    found.append((resource, id, name))
                }
            }
        }
        return found
    }

    /// The record's asset tag, read back by the test code (not the app),
    /// as the Jamf Pro API shows it (what the app reads) and as Classic does.
    func assetTag(serial: String, id: String) async throws -> (pro: String?, proHasGeneral: Bool, classic: String?) {
        let record = try await client.mobileDevice(serial: serial).record
        let response = try await client.send(HTTPRequest(method: "GET", path: JamfClassic.path(Self.resource, id: id) + "/subset/General",
                                                         accept: "application/json"), privilege: .readMobileDevices)
        let classic = try LosslessJSON(data: response.data)["mobile_device"]?["general"]?["asset_tag"]?.stringValue
        return (record?.general?.assetTag, record?.general != nil, classic)
    }

    /// What Jamf's device list (the read JTKit's lookup starts from, General
    /// and Hardware sections only) returns for the record: field names and
    /// kinds only (a diagnostic; the record's values are all made up anyway).
    /// How JTKit completes a never-enrolled record is JTKit's own and isn't
    /// repeated here; the read-back note shows what came of it.
    func shape(serial: String) async throws -> String {
        func describe(_ json: LosslessJSON?) -> String {
            guard let json else { return "missing" }
            if let object = json.objectValue { return "{" + object.keys.joined(separator: ",") + "}" }
            if json.arrayValue != nil { return "array" }
            if json.stringValue != nil { return "string" }
            return "\(json)"
        }
        let list = try await client.json("pro/v2/mobile-devices/detail", query: [
            URLQueryItem(name: "section", value: "GENERAL"), URLQueryItem(name: "section", value: "HARDWARE"),
            URLQueryItem(name: "filter", value: "serialNumber==\"\(serial)\""),
        ], privilege: .readMobileDevices)
        let first = list["results"]?.arrayValue?.first
        return "list: \(describe(first)), deviceType \(first?["deviceType"]?.stringValue ?? "none"), general \(describe(first?["general"]))"
    }

    func delete(id: String) async throws {
        try await client.deleteMobileDevice(id: id)
    }

    func delete(resource: String, id: String) async throws {
        if resource == Self.computers {
            _ = try await client.send(HTTPRequest(method: "DELETE", path: JamfClassic.path(Self.computers, id: id), accept: "application/json"),
                                      privilege: "Delete Computers")
        } else {
            try await delete(id: id)
        }
    }

    private func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

// MARK: The asset-tag fence

/// In front of the guarded network for the app's store on jamf-test-a: lets
/// through reads, sign-in, and one change only, the asset tag of this run's
/// record (a PATCH whose body holds nothing but `assetTag`). Anything else
/// is refused before it is sent and fails the check.
final class AssetTagFence: @unchecked Sendable {
    static let header = "X-JTKTEST-Fence"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fences: [UUID: AssetTagFence] = [:]

    let id = UUID()
    let inner: URLSession
    let deviceID: String
    private let lock = NSLock()
    private var refused: [String] = []
    private var changed = 0

    init(inner: URLSession, deviceID: String) {
        self.inner = inner
        self.deviceID = deviceID
        Self.lock.withLock { Self.fences[id] = self }
    }

    static func fence(_ id: UUID) -> AssetTagFence? { lock.withLock { fences[id] } }

    var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AssetTagFenceProtocol.self]
        configuration.httpAdditionalHeaders = [Self.header: id.uuidString]
        return URLSession(configuration: configuration)
    }

    var refusals: [String] { lock.withLock { refused } }
    var changes: Int { lock.withLock { changed } }

    static let signInPaths: Set<String> = ["/auth/token", "/api/oauth/token", "/api/v1/auth/token",
                                           "/api/v1/auth/invalidate-token", "/api/v1/auth/keep-alive"]

    func allows(method: String, path: String, body: Data) -> Bool {
        switch method.uppercased() {
        case "GET", "HEAD":
            return true
        case "POST":
            return Self.signInPaths.contains(path)
        case "PATCH":
            guard path.hasSuffix("/v2/mobile-devices/\(deviceID)"),
                  let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  Set(object.keys) == ["assetTag"] else { return false }
            lock.withLock { changed += 1 }
            return true
        default:
            return false
        }
    }

    func refuse(_ request: String) { lock.withLock { refused.append(request) } }
}

private final class AssetTagFenceProtocol: URLProtocol, @unchecked Sendable {
    private var forwarding: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let value = request.value(forHTTPHeaderField: AssetTagFence.header), let id = UUID(uuidString: value),
              let fence = AssetTagFence.fence(id) else {
            client?.urlProtocol(self, didFailWithError: LiveFailure("A request without its fence"))
            return
        }
        var forwarded = request
        forwarded.setValue(nil, forHTTPHeaderField: AssetTagFence.header)
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        forwarded.httpBodyStream = nil
        forwarded.httpBody = body.isEmpty ? nil : body
        let method = forwarded.httpMethod ?? "GET"
        let path = forwarded.url?.path(percentEncoded: false) ?? ""
        guard fence.allows(method: method, path: path, body: body) else {
            fence.refuse("\(method) \(path)")
            client?.urlProtocol(self, didFailWithError: LiveFailure("The fence refused \(method) \(path): the app may only change this record's asset tag"))
            return
        }
        let client = client
        forwarding = Task { [self] in
            do {
                let (data, response) = try await fence.inner.data(for: forwarded)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {
        forwarding?.cancel()
    }

    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

// MARK: The roles

enum Roles {
    static let readOnlyPro = "jamfpro-readonly"
    static let readOnlySchool = "jamfschool-readonly"
    static let production = "jamfpro-production"
    static let testA = "jamf-test-a"

    /// The read-only lookups of this run: production only with --include-production
    /// (the release check leaves it out of the run's roles otherwise).
    static func readOnly(_ run: LiveCheckRun) -> [(String, AllowList.Service)] {
        [(readOnlyPro, .jamfPlatform), (readOnlySchool, .jamfSchool), (production, .jamfPlatform)]
            .filter { run.roles.contains($0.0) && (run.policy.includeProduction || $0.0 != production) }
    }
}

// MARK: Stage 1: sign in

@MainActor
@Suite("Live: sign in", .enabled(if: live), .serialized)
struct LiveSignInTests {
    /// A sign-in and one small read on each tenant, plus a count of left-over
    /// test records on jamf-test-a. Reads only.
    @Test func signInAndRead() async throws {
        let run = try LiveCheckRun.current()
        checkUnderTest(run, when: "start")
        var failed: (any Error)?
        for (role, service) in Roles.readOnly(run) + [(Roles.testA, .jamfPlatform)] where run.roles.contains(role) {
            do {
                let tenant = try LiveTenant(run: run, role: role, service: service)
                defer { tenant.removeSettings() }
                let message = try await tenant.store.testConnection(tenant.record, typedSecret: tenant.secret)
                var note = message.isEmpty ? "signed in" : "signed in (\(message))"
                if role == Roles.testA, case .pro(let client, _) = try tenant.client(run) {
                    note += "; \(try await TestDevices(client: client).testRecords(run).count) left-over test records"
                }
                run.record(step: "sign in: \(role)", passed: true, note: note)
            } catch {
                run.record(step: "sign in: \(role)", passed: false, note: failure(error))
                failed = failed ?? error
            }
        }
        if let failed { throw failed }
        #expect(run.network.refusals.isEmpty, "\(run.network.refusals)")
    }
}

// MARK: Stage 4: the main task, live

@MainActor
@Suite("Live: lookups and the asset tag", .enabled(if: live), .serialized)
struct LiveLookupTests {
    /// On each read-only tenant: one serial from its own inventory, then the
    /// app's own lookup must find it. Nothing is written anywhere.
    @Test func readOnlyLookups() async throws {
        let run = try LiveCheckRun.current()
        checkUnderTest(run, when: "before the lookups")

        // --fault usb-attempt: one Restart through the real doorway, to show the
        // guard refuses it and the run fails. Only under tests (the guard is on),
        // and the release check starts it only when no Apple device is connected.
        if run.fault == "usb-attempt" {
            try #require(USBGuard.shared.isActive, "The USB guard is off: the fault isn't injected")
            _ = LiveUSBHardware().runPrivilegedVDM("reboot")
            run.record(step: "usb-attempt", passed: false, note: "a Restart through the real doorway, injected on purpose (--fault usb-attempt)")
        }

        var failed: (any Error)?
        for (role, service) in Roles.readOnly(run) {
            let step = "\(role): one serial from its inventory, found by the app's lookup"
            do {
                let tenant = try LiveTenant(run: run, role: role, service: service)
                defer { tenant.removeSettings() }
                guard let picked = try await Inventory.firstSerial(try tenant.client(run)) else {
                    // Decided by Jordy: an empty inventory is reported, not failed.
                    run.record(step: "\(role): nothing to look up", passed: true,
                               note: Inventory.emptyNote.isEmpty ? "no device with a serial" : Inventory.emptyNote)
                    continue
                }
                let state = await tenant.lookUp(serial: picked.serial)
                let found: Bool
                let note: String
                if case .found(let record) = state {
                    found = record.serialNumber?.caseInsensitiveCompare(picked.serial) == .orderedSame
                    note = found ? "serial 1 (a \(picked.kind)) found as \(record.kind.rawValue)" : "found a record with another serial"
                } else {
                    found = false
                    note = masked("serial 1 (a \(picked.kind)): \(state)", serial: picked.serial)
                }
                run.record(step: step, passed: found, note: note)
                // Only the outcome: a failure never prints the serial.
                #expect(found, "\(role): the app's lookup didn't find the serial")
                if !found { failed = failed ?? LiveFailure("\(role): lookup") }
            } catch {
                run.record(step: step, passed: false, note: failure(error))
                failed = failed ?? error
            }
        }
        checkUnderTest(run, when: "after the lookups")
        if let failed { throw failed }
    }

    /// On jamf-test-a: a JTKTEST record, the app's own lookup and asset-tag
    /// Save behind a fence, read back by the test code and by the app.
    @Test func assetTag() async throws {
        let run = try LiveCheckRun.current()
        guard run.roles.contains(Roles.testA) else { return }
        let role = Roles.testA
        let step = { (name: String) in "\(role): \(name)" }
        func attempt<T>(_ name: String, _ body: () async throws -> T) async throws -> T {
            do {
                return try await body()
            } catch {
                run.record(step: step(name), passed: false, note: failure(error))
                throw error
            }
        }
        let setup = try LiveTenant(run: run, role: role, service: .jamfPlatform)
        defer { setup.removeSettings() }
        guard case .pro(let client, _) = try setup.client(run) else { throw LiveFailure("\(role) isn't Jamf Pro") }
        let devices = TestDevices(client: client)

        // 1. The test record: made-up serial and UDID, unmanaged.
        let digits = run.prefix.filter(\.isNumber)
        let serial = "JTKTEST\(digits)"
        let udid = "00000000-0000\(digits)0000"
        let name = "\(run.prefix) – iPad"
        let deviceID = try await attempt("create a test mobile device record") {
            try await devices.create(name: name, serial: serial, udid: udid)
        }
        run.record(step: step("create a test mobile device record"), passed: true,
                   note: "id \(deviceID), made-up serial \(serial), never enrolled (no model or OS), not managed")
        // A computer record next to it (made-up Mac).
        let macSerial = "JTKTESTM\(digits)"
        let computerID = try await attempt("create a test computer record") {
            try await devices.createComputer(name: "\(run.prefix) – Mac", serial: macSerial, udid: UUID().uuidString)
        }
        run.record(step: step("create a test computer record"), passed: true, note: "id \(computerID), made-up serial \(macSerial), not managed")
        try run.injectFault("fail-live-step", at: step("after both test records were created"))

        // 2. The app's own lookup and Save, behind the fence.
        let fence = AssetTagFence(inner: run.network.session, deviceID: deviceID)
        let app = try LiveTenant(run: run, role: role, service: .jamfPlatform, session: fence.session)
        defer { app.removeSettings() }
        let state = await app.lookUp(serial: serial)
        guard case .found(let record) = state, record.kind == .mobileDevice, record.jamfID == deviceID else {
            run.record(step: step("the app's lookup finds the test record"), passed: false, note: "\(state)")
            throw LiveFailure("The app's lookup didn't find the test record")
        }
        run.record(step: step("the app's lookup finds the test record"), passed: true, note: "mobile device \(deviceID)")
        // Never enrolled, yet the app shows its name (JTKit 0.12.3).
        run.record(step: step("the app shows the never-enrolled record's name"), passed: record.name == name,
                   note: "“\(record.name ?? "none")”")
        #expect(record.name == name)

        let tag = "JTKTEST-\(digits)"
        let message = await app.store.saveAssetTag(tag, record: record, for: LiveDevice.recovery(serial: serial))
        run.record(step: step("the app's Save changes the asset tag"), passed: message == nil && fence.changes == 1,
                   note: message ?? "\(fence.changes) change sent")
        try #require(message == nil, "The app's Save failed: \(message ?? "")")

        // 3. Read back: by the test code, then by the app's own lookup again.
        // Jamf may take a moment to show the change: up to 30 seconds.
        var stored: (pro: String?, proHasGeneral: Bool, classic: String?) = (nil, false, nil)
        for _ in 0..<10 {
            stored = try await attempt("read the asset tag back") { try await devices.assetTag(serial: serial, id: deviceID) }
            if stored.pro == tag { break }
            try await Task.sleep(for: .seconds(3))
        }
        if stored.pro != tag {
            let shape = (try? await devices.shape(serial: serial)) ?? "unreadable"
            run.record(step: step("diagnostic: the record in the Jamf Pro API"), passed: false, note: shape)
        }
        run.record(step: step("read the asset tag back"), passed: stored.pro == tag,
                   note: "Jamf Pro API “\(stored.pro ?? "none")”\(stored.proHasGeneral ? "" : " (no general section)"), Classic “\(stored.classic ?? "none")”")
        #expect(stored.pro == tag)
        let again = await app.lookUp(serial: serial, again: true)
        var appSees: String?
        var appName: String?
        if case .found(let refreshed) = again { appSees = refreshed.assetTag; appName = refreshed.name }
        run.record(step: step("the app's lookup shows the new asset tag and the name"), passed: appSees == tag && appName == name,
                   note: "asset tag “\(appSees ?? "\(again)")”, name “\(appName ?? "none")”")
        #expect(appSees == tag)
        #expect(appName == name)

        let refused = fence.refusals
        run.record(step: step("the app sent nothing but reads, sign-in and this asset tag"), passed: refused.isEmpty,
                   note: refused.isEmpty ? nil : refused.joined(separator: "; "))
        #expect(refused.isEmpty, "\(refused)")
        checkUnderTest(run, when: "after the asset tag")

        // 4. The computer record, found by the app's own lookup
        //    (mobile devices first, then computers, as in the app).
        let macState = await app.lookUp(serial: macSerial)
        var macFound = false
        var macName: String?
        if case .found(let mac) = macState {
            macFound = mac.kind == .computer && mac.jamfID == computerID && mac.serialNumber == macSerial
            macName = mac.name
        }
        run.record(step: step("the app's lookup finds the test computer"), passed: macFound,
                   note: macFound ? "computer \(computerID), name “\(macName ?? "none")”" : "\(macState)")
        #expect(macFound, "The app's lookup didn't find the test computer")
        #expect(fence.refusals.isEmpty, "\(fence.refusals)")

        // 5. Removal (cleanup also runs on every exit).
        try await attempt("delete the test records") {
            try await devices.delete(id: deviceID)
            try await devices.delete(resource: TestDevices.computers, id: computerID)
        }
        run.record(step: step("delete the test records"), passed: true)
        #expect(run.network.refusals.isEmpty, "\(run.network.refusals)")
    }
}

// MARK: Cleanup, on every exit

@MainActor
@Suite("Live: cleanup", .enabled(if: live), .serialized)
struct LiveCleanupTests {
    /// Deletes what the ledger still lists, then sweeps jamf-test-a for any
    /// record still named as a test object. Fails if anything is left. Also
    /// the last under-tests check, after the unit and smoke tests.
    @Test func removeTestObjects() async throws {
        let run = try LiveCheckRun.current()
        defer { checkUnderTest(run, when: "end of the run") }
        guard run.roles.contains(Roles.testA) else { return }
        let tenant = try LiveTenant(run: run, role: Roles.testA, service: .jamfPlatform)
        defer { tenant.removeSettings() }
        guard case .pro(let client, _) = try tenant.client(run) else { throw LiveFailure("\(Roles.testA) isn't Jamf Pro") }
        let devices = TestDevices(client: client)
        let target = try run.target(role: Roles.testA, service: .jamfPlatform)
        for record in try await devices.testRecords(run) {
            try run.adoptForSweep(role: Roles.testA, service: .jamfPlatform, resource: record.resource, id: record.id, name: record.name)
        }
        for item in run.ledger.outstanding where item.target == target {
            do {
                try await devices.delete(resource: item.resource, id: item.id)
            } catch {
                run.record(step: "cleanup: \(item.resource) \(item.id)", passed: false, note: failure(error))
            }
        }
        let left = run.ledger.outstanding
        let still = try await devices.testRecords(run)
        let clean = left.isEmpty && still.isEmpty
        run.record(step: "cleanup", passed: clean,
                   note: clean ? nil : "\(left.count) in the ledger and \(still.count) on the tenant not removed")
        #expect(left.isEmpty, "\(left.map { "\($0.resource) \($0.id) \($0.name)" })")
        #expect(still.isEmpty, "\(still.map { "\($0.resource) \($0.id) \($0.name)" })")
    }
}
