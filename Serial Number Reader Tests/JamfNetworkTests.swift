import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Serial_Number_Reader

/// The Jamf clients on JTKit's networking, against a fake server: sign-in,
/// lookups, retries, the app's error hints, and what the activity log keeps.
@MainActor
@Suite("Jamf networking")
struct JamfNetworkTests {
    private nonisolated static let serial = "C02XK1ABJG5H"
    private nonisolated static let udid = "00008130-001A2B3C4D5E6F70"

    private nonisolated static let mobileDevice = """
        {"totalCount": 1, "results": [{"mobileDeviceId": "7",
          "general": {"displayName": "Lab iPad", "assetTag": "LAB-01"},
          "hardware": {"serialNumber": "\(serial)", "model": "iPad Air"}}]}
        """
    private nonisolated static let noDevices = #"{"totalCount": 0, "results": []}"#

    private func recorder(_ server: MockServer, _ log: ActivityLog, service: String) -> RequestRecorder {
        RequestRecorder(session: server.session, log: log, service: service, connection: "Test")
    }

    /// Every entry as the log window, Copy and both exports show it.
    private func allText(_ log: ActivityLog) -> String {
        log.entries.map(ActivityLogExport.transcript(of:)).joined(separator: "\n")
            + ActivityLogExport.text(log.entries, masked: true)
            + ActivityLogExport.text(log.entries, masked: false)
    }

    // MARK: Jamf School

    @Test("Jamf School: the Basic Authorization header is hidden completely in the log")
    func jamfSchoolCredentialsNeverRecorded() async throws {
        let networkID = "84512376"
        let apiKey = "s3cr3tApiKeyXYZ987"
        let encoded = Data("\(networkID):\(apiKey)".utf8).base64EncodedString()
        let server = MockServer { request in
            if request.method == "POST" { return .json(200, #"{"code": 200}"#) }
            if request.path.hasSuffix("/api/devices") {
                return .json(200, #"{"code": 200, "devices": [{"UDID": "\#(Self.udid)", "serialNumber": "\#(Self.serial)"}]}"#)
            }
            return .json(200, #"{"code": 200, "device": {"UDID": "\#(Self.udid)", "serialNumber": "\#(Self.serial)", "name": "Lab iPad"}}"#)
        }
        let log = ActivityLog()
        let config = try #require(JamfConfiguration.make(
            urlString: "school.example.com", credentials: .jamfSchool(networkID: networkID, apiKey: apiKey)))
        let client = try JamfService(configuration: config, recorder: recorder(server, log, service: "Jamf School"))

        let record = try #require(try await client.lookup(.serialNumber(Self.serial)).record)
        try await client.updateAssetTag("LAB+01", record: record)

        // The server did get the credentials…
        #expect(server.requests.count == 3)
        #expect(server.requests.allSatisfy { $0.header("Authorization") == "Basic \(encoded)" })
        // …the log shows none of them, in any form.
        #expect(log.entries.count == 3)
        for entry in log.entries {
            let authorization = entry.request?.requestHeaders.first { $0.name.lowercased() == "authorization" }
            #expect(authorization?.value == "Basic \(Redaction.placeholder)")
        }
        let text = allText(log)
        for secret in [networkID, apiKey, encoded, String(encoded.dropLast(2))] {
            #expect(!text.contains(secret))
        }
    }

    @Test("Jamf School: the server's error message is cleaned before it is shown")
    func jamfSchoolErrorRedacted() async throws {
        let server = MockServer { _ in .json(500, #"{"code": 500, "message": "failed: password=hunter2"}"#) }
        let log = ActivityLog()
        let config = try #require(JamfConfiguration.make(
            urlString: "school.example.com", credentials: .jamfSchool(networkID: "1", apiKey: "key")))
        let client = try JamfService(configuration: config, recorder: recorder(server, log, service: "Jamf School"))
        do {
            _ = try await client.lookup(.udid(Self.udid))
            Issue.record("Expected an error")
        } catch {
            #expect(!error.localizedDescription.contains("hunter2"))
            #expect(error.localizedDescription.contains("HTTP 500"))
        }
    }

    // MARK: Jamf Pro and the Platform API

    @Test("Jamf Pro API client: signs in once, sends the token, records neither")
    func apiClientLookup() async throws {
        let server = MockServer { request in
            if request.path == "/api/oauth/token" {
                return .json(200, #"{"access_token": "tok-abc-123", "expires_in": 1200}"#)
            }
            return .json(200, Self.mobileDevice)
        }
        let log = ActivityLog()
        let config = try #require(JamfConfiguration.make(
            urlString: "https://pro.example.com", credentials: .clientCredentials(clientID: "client", clientSecret: "shh-secret")))
        let client = try JamfService(configuration: config, recorder: recorder(server, log, service: "Jamf Pro"))

        let record = try #require(try await client.lookup(.serialNumber(Self.serial)).record)
        _ = try await client.lookup(.serialNumber(Self.serial))

        #expect(record.kind == .mobileDevice)
        #expect(record.jamfID == "7")
        #expect(record.serialNumber == Self.serial)
        #expect(server.requests.map(\.path) == ["/api/oauth/token", "/api/v2/mobile-devices/detail", "/api/v2/mobile-devices/detail"])
        #expect(server.requests[0].bodyString.contains("client_secret=shh-secret"))
        #expect(server.requests[1].header("Authorization") == "Bearer tok-abc-123")
        #expect(server.requests[1].queryValue("filter") == "serialNumber==\"\(Self.serial)\"")
        let text = allText(log)
        #expect(!text.contains("shh-secret"))
        #expect(!text.contains("tok-abc-123"))
    }

    @Test("Jamf Pro user account: Basic sign-in, then computers when no mobile device matches")
    func usernamePasswordFallsBackToComputers() async throws {
        let server = MockServer { request in
            switch request.path {
            case "/api/v1/auth/token":
                return .json(200, #"{"token": "user-token", "expires": "2099-01-01T00:00:00.000Z"}"#)
            case "/api/v2/mobile-devices/detail":
                return .json(200, Self.noDevices)
            default:
                return .json(200, #"{"totalCount": 1, "results": [{"id": "42", "general": {"name": "Lab Mac"}, "hardware": {"serialNumber": "\#(Self.serial)"}}]}"#)
            }
        }
        let log = ActivityLog()
        let config = try #require(JamfConfiguration.make(
            urlString: "pro.example.com", credentials: .basic(username: "admin", password: "pa55word")))
        let client = try JamfService(configuration: config, recorder: recorder(server, log, service: "Jamf Pro"))

        let record = try #require(try await client.lookup(.serialNumber(Self.serial)).record)

        #expect(record.kind == .computer)
        #expect(record.jamfID == "42")
        #expect(record.name == "Lab Mac")
        #expect(server.requests.map(\.path) == ["/api/v1/auth/token", "/api/v2/mobile-devices/detail", "/api/v4/computers-inventory"])
        #expect(server.requests[0].header("Authorization") == "Basic " + Data("admin:pa55word".utf8).base64EncodedString())
        #expect(server.requests[2].header("Authorization") == "Bearer user-token")
        #expect(!allText(log).contains("pa55word"))
    }

    @Test("Platform API: regional gateway, /pro paths and the environment header")
    func platformLookup() async throws {
        let environmentID = "5E0C2A6B-1C3D-4E5F-8A9B-0C1D2E3F4A5B"
        let server = MockServer { request in
            if request.path == "/auth/token" { return .json(200, #"{"access_token": "gw-token", "expires_in": 900}"#) }
            return .json(200, Self.mobileDevice)
        }
        let config = try #require(JamfConfiguration.make(
            urlString: "", credentials: .platform(region: .us, clientID: "id", clientSecret: "secret", environmentID: environmentID)))
        let client = try JamfService(configuration: config, recorder: recorder(server, ActivityLog(), service: "Jamf Platform API"))

        _ = try await client.lookup(.udid(Self.udid))

        #expect(server.requests.map(\.url.host) == ["us.api.jamfcloud.com", "us.api.jamfcloud.com"])
        #expect(server.requests.map(\.path) == ["/auth/token", "/pro/v2/mobile-devices/detail"])
        #expect(server.requests[1].header("X-Environment-Id") == environmentID)
    }

    @Test("A 429 waits and tries again, and the wait shows in the log")
    func retriesAfter429() async throws {
        let lookups = Counter()
        let server = MockServer { request in
            if request.path == "/api/oauth/token" { return .json(200, #"{"access_token": "t", "expires_in": 1200}"#) }
            if lookups.next() == 1 { return .json(429, "{}", headers: ["Retry-After": "0"]) }
            return .json(200, Self.mobileDevice)
        }
        let log = ActivityLog()
        let config = try #require(JamfConfiguration.make(
            urlString: "pro.example.com", credentials: .clientCredentials(clientID: "c", clientSecret: "s")))
        let client = try JamfService(configuration: config, recorder: recorder(server, log, service: "Jamf Pro"))

        let record = try #require(try await client.lookup(.serialNumber(Self.serial)).record)

        #expect(record.jamfID == "7")
        #expect(lookups.value == 2)
        #expect(log.entries.contains { $0.isWarning && ($0.note ?? "").contains("HTTP 429") })
    }

    @Test("JTKit's error format with the app's hints: wrong environment ID, missing permission")
    func platformHints() async throws {
        let status = Locked(400)
        let server = MockServer { request in
            if request.path == "/auth/token" { return .json(200, #"{"access_token": "t", "expires_in": 900}"#) }
            return .json(status.value, #"{"httpStatus": \#(status.value), "traceId": "trace-77", "errors": [{"code": "INVALID_REQUEST_CONTEXT_ID"}]}"#)
        }
        let config = try #require(JamfConfiguration.make(
            urlString: "", credentials: .platform(region: .eu, clientID: "id", clientSecret: "secret",
                                                  environmentID: "5E0C2A6B-1C3D-4E5F-8A9B-0C1D2E3F4A5B")))
        let client = try JamfService(configuration: config, recorder: recorder(server, ActivityLog(), service: "Jamf Platform API"))

        let wrongEnvironment = await #expect(throws: JamfPlatform.APIError.self) { try await client.testConnection() }
        let message = try #require(wrongEnvironment?.message())
        #expect(message.hasPrefix("HTTP 400 Bad Request"))
        #expect(message.contains("Trace ID: trace-77"))
        #expect(message.contains("The Environment ID doesn’t belong to this integration."))
        #expect(server.requests.last?.path == "/pro/v4/computers-inventory")

        status.value = 403
        let forbidden = await #expect(throws: JamfPlatform.APIError.self) { try await client.testConnection() }
        #expect(forbidden?.message().contains("Serial Number Reader needs the devices:read permission, and devices:update to edit asset tags.") == true)
        #expect(forbidden?.message().contains("Check its permissions in Jamf Account.") == true)
    }

    @Test("A refused sign-in shows the Platform API hint")
    func platformSignInHint() async throws {
        let server = MockServer { _ in .json(401, #"{"error": "invalid_client"}"#) }
        let config = try #require(JamfConfiguration.make(
            urlString: "", credentials: .platform(region: .eu, clientID: "id", clientSecret: "secret",
                                                  environmentID: "5E0C2A6B-1C3D-4E5F-8A9B-0C1D2E3F4A5B")))
        let client = try JamfService(configuration: config, recorder: recorder(server, ActivityLog(), service: "Jamf Platform API"))

        let error = await #expect(throws: JamfPlatform.APIError.self) { try await client.testConnection() }
        #expect(error?.message().contains("Check the client ID, client secret and region. Jamf Account integrations expire after six months.") == true)
    }

    @Test("Asset tag saves are retried after a server error")
    func assetTagSafeToRepeat() async throws {
        let patches = Counter()
        let server = MockServer { request in
            if request.path == "/api/oauth/token" { return .json(200, #"{"access_token": "t", "expires_in": 1200}"#) }
            return patches.next() == 1 ? .json(503, "{}", headers: ["Retry-After": "0"]) : .json(200, "{}")
        }
        let config = try #require(JamfConfiguration.make(
            urlString: "pro.example.com", credentials: .clientCredentials(clientID: "c", clientSecret: "s")))
        let client = try JamfService(configuration: config, recorder: recorder(server, ActivityLog(), service: "Jamf Pro"))

        try await client.updateAssetTag("LAB-02", record: Self.record(.mobileDevice, id: "7"))

        #expect(patches.value == 2)
        #expect(server.requests.last?.method == "PATCH")
        #expect(server.requests.last?.bodyString == #"{"assetTag":"LAB-02"}"#)
    }

    @Test("A Mac's asset tag goes to v4")
    func computerAssetTag() async throws {
        let server = MockServer { request in
            request.path == "/api/oauth/token" ? .json(200, #"{"access_token": "t", "expires_in": 1200}"#) : .json(200, "{}")
        }
        let config = try #require(JamfConfiguration.make(
            urlString: "pro.example.com", credentials: .clientCredentials(clientID: "c", clientSecret: "s")))
        let client = try JamfService(configuration: config, recorder: recorder(server, ActivityLog(), service: "Jamf Pro"))

        try await client.updateAssetTag("", record: Self.record(.computer, id: "42"))

        #expect(server.requests.last?.path == "/api/v4/computers-inventory-detail/42")
        #expect(server.requests.last?.bodyString == #"{"general":{"assetTag":""}}"#)
    }

    @Test("A refused lookup names the Jamf Pro privilege; a wrong password mentions no region")
    func jamfProHints() async throws {
        let signIn = Locked(200)
        let server = MockServer { request in
            if request.path == "/api/v1/auth/token" {
                return signIn.value == 200 ? .json(200, #"{"token": "t", "expires": "2099-01-01T00:00:00.000Z"}"#) : .json(401, "{}")
            }
            return .json(403, "{}")
        }
        let config = try #require(JamfConfiguration.make(
            urlString: "pro.example.com", credentials: .basic(username: "admin", password: "pw")))
        let client = try JamfService(configuration: config, recorder: recorder(server, ActivityLog(), service: "Jamf Pro"))

        let forbidden = await #expect(throws: JamfPlatform.APIError.self) { _ = try await client.lookup(.udid(Self.udid)) }
        #expect(forbidden?.message().contains("The user account is missing the “Read Mobile Devices” privilege.") == true)

        signIn.value = 401
        let wrong = await #expect(throws: JamfPlatform.APIError.self) { try await client.testConnection() }
        let message = try #require(wrong?.message())
        #expect(message.contains("Check the username and password."))
        #expect(!message.contains("region"))
    }

    @Test("A record whose serial isn't the one asked for is no match; two are ambiguous")
    func exactMatches() async throws {
        let answer = Locked(#"{"totalCount": 1, "results": [{"mobileDeviceId": "7", "hardware": {"serialNumber": "OTHER123"}}]}"#)
        let server = MockServer { request in
            if request.path == "/api/oauth/token" { return .json(200, #"{"access_token": "t", "expires_in": 1200}"#) }
            return request.path == "/api/v2/mobile-devices/detail" ? .json(200, answer.value) : .json(200, Self.noDevices)
        }
        let config = try #require(JamfConfiguration.make(
            urlString: "pro.example.com", credentials: .clientCredentials(clientID: "c", clientSecret: "s")))
        let client = try JamfService(configuration: config, recorder: recorder(server, ActivityLog(), service: "Jamf Pro"))

        #expect(try await client.lookup(.serialNumber(Self.serial)) == .noMatch)
        answer.value = #"{"totalCount": 2, "results": [{"mobileDeviceId": "7", "hardware": {"serialNumber": "\#(Self.serial)"}}, {"mobileDeviceId": "8", "hardware": {"serialNumber": "\#(Self.serial)"}}]}"#
        #expect(try await client.lookup(.serialNumber(Self.serial)) == .multipleMatches(2))
    }

    @Test("A serial from the USB descriptor with odd characters is never sent")
    func invalidIdentifier() async throws {
        let server = MockServer { _ in .json(200, #"{"access_token": "t", "expires_in": 1200}"#) }
        let config = try #require(JamfConfiguration.make(
            urlString: "pro.example.com", credentials: .clientCredentials(clientID: "c", clientSecret: "s")))
        let client = try JamfService(configuration: config, recorder: recorder(server, ActivityLog(), service: "Jamf Pro"))
        await #expect(throws: JamfPlatform.APIError.self) { _ = try await client.lookup(.serialNumber("C02\"||1")) }
        #expect(!server.requests.contains { $0.path.contains("mobile-devices") })
    }

    @Test("Export for Bug Report masks the serial number in the lookup address")
    func bugReportMasksSerial() async throws {
        let server = MockServer { request in
            if request.path == "/api/oauth/token" { return .json(200, #"{"access_token": "t", "expires_in": 1200}"#) }
            return .json(200, Self.mobileDevice)
        }
        let log = ActivityLog()
        let config = try #require(JamfConfiguration.make(
            urlString: "pro.example.com", credentials: .clientCredentials(clientID: "c", clientSecret: "s")))
        let client = try JamfService(configuration: config, recorder: recorder(server, log, service: "Jamf Pro"))

        _ = try await client.lookup(.serialNumber(Self.serial))

        #expect(ActivityLogExport.text(log.entries, masked: false).contains(Self.serial))
        #expect(!ActivityLogExport.text(log.entries, masked: true).contains(Self.serial))
    }
}

extension JamfNetworkTests {
    fileprivate nonisolated static func record(_ kind: JamfDeviceRecord.Kind, id: String) -> JamfDeviceRecord {
        JamfDeviceRecord(kind: kind, jamfID: id, name: nil, assetTag: nil, serialNumber: nil, udid: nil, model: nil,
                         modelIdentifier: nil, osVersion: nil, managed: nil, username: nil, realName: nil,
                         email: nil, lastInventoryDate: nil)
    }
}

extension JamfLookupResult {
    var record: JamfDeviceRecord? {
        if case .found(let record) = self { return record }
        return nil
    }
}

/// A value shared between a test and the fake server's handler.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Counts calls: `next()` returns 1, 2, 3…
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func next() -> Int {
        lock.withLock { count += 1; return count }
    }
}
