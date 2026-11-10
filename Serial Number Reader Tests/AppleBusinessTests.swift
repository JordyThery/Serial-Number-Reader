import CryptoKit
import Foundation
import JTKit
import JTKitTestSupport
import SwiftUI
import Testing
@testable import Serial_Number_Reader

/// Apple Business and Apple School Manager lookups on JTKit's client, against
/// a fake Apple: the store's states, the sign-in as the app sends it, and the
/// app's wording. Only throwaway keys made here; no real credentials.
@MainActor
@Suite("Apple Business lookup")
struct AppleBusinessTests {
    private nonisolated static let serial = "PLACEHOLDR05"
    private nonisolated static let clientID = "BUSINESSAPI.00000000-0000-0000-0000-000000000000"
    private nonisolated static let keyID = "key-id-placeholder"
    private nonisolated static let token = "SECRET-access-token-0123456789"

    // Fixtures shaped like the documented responses (JSON:API: `data` with `attributes`).
    private nonisolated static let deviceJSON = """
        {"data": {"id": "\(serial)", "type": "orgDevices", "attributes": {
          "serialNumber": "\(serial)", "deviceModel": "iPad Air 11-inch", "productFamily": "iPad",
          "productType": "iPad14,8", "status": "ASSIGNED", "orderNumber": "ORDER-PLACEHOLDER",
          "purchaseSourceType": "RESELLER", "purchaseSourceId": "RS-1",
          "addedToOrgDateTime": "2026-03-12T09:30:00.000Z", "color": "BLUE", "someNewField": {"x": 1}}}}
        """
    private nonisolated static let assignedServerJSON = #"{"data": {"type": "mdmServers", "id": "SERVER-1"}}"#
    private nonisolated static let mdmServersJSON = """
        {"data": [{"id": "SERVER-1", "type": "mdmServers", "attributes": {"serverName": "Lab MDM", "serverType": "MDM"}},
                  {"id": "SERVER-2", "type": "mdmServers", "attributes": {"serverName": "Other"}}]}
        """
    private nonisolated static let coverageJSON = """
        {"data": [{"id": "AC-1", "type": "appleCareCoverage", "attributes": {
          "description": "AppleCare+", "status": "ACTIVE",
          "startDateTime": "2026-03-12T00:00:00.000Z", "endDateTime": "2028-03-12T00:00:00.000Z"}}]}
        """

    private struct Rig {
        let server: MockServer
        let store: AppleBusinessStore
        let settings: TemporaryDefaults
        let pem: String
        let key: P256.Signing.PrivateKey
        let secrets: InMemorySecretStore
        let log: ActivityLog

        var signIns: [RecordedRequest] { server.requests.filter { $0.url.host() == "account.apple.com" } }
        var api: [RecordedRequest] { server.requests.filter { $0.url.host() != "account.apple.com" } }
    }

    /// A fake Apple: `route` first, then sign-in, then 404.
    private func makeRig(service: ConnectionService = .appleBusinessManager, saved: Bool = true,
                     route: @escaping @Sendable (RecordedRequest) -> MockResponse? = { _ in nil }) throws -> Rig {
        let server = MockServer { request in
            if request.url.host() == "account.apple.com" {
                return .json(200, #"{"access_token": "\#(Self.token)", "token_type": "Bearer", "expires_in": 3600}"#)
            }
            if let answer = route(request) { return answer }
            switch request.path {
            case "/v1/orgDevices/\(Self.serial)": return .json(200, Self.deviceJSON)
            case "/v1/orgDevices/\(Self.serial)/relationships/assignedServer": return .json(200, Self.assignedServerJSON)
            case "/v1/orgDevices/\(Self.serial)/appleCareCoverage": return .json(200, Self.coverageJSON)
            case "/v1/mdmServers": return .json(200, Self.mdmServersJSON)
            default: return .json(404, #"{"errors": [{"status": "404", "code": "NOT_FOUND", "title": "Not Found"}]}"#)
            }
        }
        let key = P256.Signing.PrivateKey()
        let settings = TemporaryDefaults("applebusiness")
        let secrets = InMemorySecretStore()
        let connections = AppConnectionStore(defaults: settings.defaults, secrets: secrets)
        if saved {
            let record = AppleBusinessConnection(name: "Lab Org", service: service, signIn: .applePrivateKey,
                                                 clientID: Self.clientID, keyID: Self.keyID)
            try connections.connections.save(.apple(record), secrets: [.main: key.pemRepresentation])
            connections.activeAppleID = record.id
        }
        let log = ActivityLog()
        let store = AppleBusinessStore(connections: connections, activityLog: log, session: server.session)
        return Rig(server: server, store: store, settings: settings, pem: key.pemRepresentation, key: key,
                   secrets: secrets, log: log)
    }

    private func finished(_ store: AppleBusinessStore, _ serial: String = AppleBusinessTests.serial) async -> AppleBusinessLookupState {
        store.lookupIfNeeded(serial: serial)
        for _ in 0..<500 where store.state(forSerial: serial) == .loading {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return store.state(forSerial: serial)
    }

    // MARK: Optional feature

    @Test("Without a saved account the feature is off and nothing is sent")
    func notConfigured() async throws {
        let rig = try makeRig(saved: false)
        #expect(!rig.store.isConfigured)
        #expect(rig.store.state(forSerial: Self.serial) == .notConfigured)
        rig.store.lookupIfNeeded(serial: Self.serial)
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.server.requests.isEmpty)
    }

    @Test("An account without key ID or private key is incomplete, so the feature stays off")
    func incompleteAccount() {
        let record = AppleBusinessConnection(name: "Lab", service: .appleBusinessManager, signIn: .applePrivateKey,
                                             clientID: Self.clientID, keyID: "")
        #expect(AppleBusinessStore.configuration(for: record, hasPrivateKey: true) == nil)
        var complete = record
        complete.keyID = Self.keyID
        #expect(AppleBusinessStore.configuration(for: complete, hasPrivateKey: false) == nil)
        #expect(AppleBusinessStore.configuration(for: complete, hasPrivateKey: true) != nil)
        // A Jamf service is never an Apple account.
        complete.service = .jamfPro
        #expect(AppleBusinessStore.configuration(for: complete, hasPrivateKey: true) == nil)
    }

    @Test("The private key is read only when signing in: not at launch, not for later lookups, never kept")
    func keyReadOnlyAtSignIn() async throws {
        let rig = try makeRig { request in
            request.path.hasPrefix("/v1/orgDevices/OTHER") ? .json(404, #"{"errors": []}"#) : nil
        }
        // Saving the account wrote the key; from here on, only reads count.
        let secrets = CountingSecretStore(base: rig.secrets)
        let connections = AppConnectionStore(defaults: rig.settings.defaults, secrets: secrets)
        let store = AppleBusinessStore(connections: connections, activityLog: ActivityLog(), session: rig.server.session)
        #expect(store.isConfigured)
        #expect(secrets.reads == 0)
        #expect(secrets.presenceChecks > 0)
        _ = await finished(store)
        #expect(secrets.reads == 1)
        // The token is still valid: no sign-in, no read.
        _ = await finished(store, "OTHER00001")
        #expect(secrets.reads == 1)
        #expect(rig.signIns.count == 1)
    }

    @Test("A Keychain that can't be read shows the problem, writes nothing, and Retry asks it again")
    func unreadableKeychain() async throws {
        let rig = try makeRig()
        let secrets = CountingSecretStore(base: rig.secrets)
        secrets.refuses = true
        let connections = AppConnectionStore(defaults: rig.settings.defaults, secrets: secrets)
        let store = AppleBusinessStore(connections: connections, activityLog: ActivityLog(), session: rig.server.session)
        let list = rig.settings.defaults.data(forKey: AppConnectionStore.appleListKey)
        guard case .failed = store.state(forSerial: Self.serial) else {
            Issue.record("Expected the Keychain problem, got \(store.state(forSerial: Self.serial))")
            return
        }
        store.lookupIfNeeded(serial: Self.serial)
        #expect(rig.server.requests.isEmpty)
        #expect(secrets.writes == 0)
        #expect(rig.settings.defaults.data(forKey: AppConnectionStore.appleListKey) == list)

        secrets.refuses = false
        store.refresh(serial: Self.serial)
        for _ in 0..<500 where store.state(forSerial: Self.serial) == .loading {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .found = store.state(forSerial: Self.serial) else {
            Issue.record("Retry didn't read the Keychain again: \(store.state(forSerial: Self.serial))")
            return
        }
    }

    @Test("A private key replaced in Settings is used at the next lookup")
    func replacedKeySignsInAgain() async throws {
        let rig = try makeRig()
        _ = await finished(rig.store)
        #expect(rig.signIns.count == 1)
        let record = try #require(rig.store.connections.activeAppleConnection)
        try rig.store.connections.connections.save(.apple(record), secrets: [.main: P256.Signing.PrivateKey().pemRepresentation])
        for _ in 0..<100 where rig.store.lookupStates[Self.serial] != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = await finished(rig.store)
        #expect(rig.signIns.count == 2)
    }

    @Test("No serial number yet: nothing to look up")
    func noSerial() throws {
        let rig = try makeRig()
        #expect(rig.store.state(forSerial: nil) == .unavailable("No serial number to look up yet"))
        #expect(rig.store.state(forSerial: "  ") == .unavailable("No serial number to look up yet"))
    }

    // MARK: Sign-in

    private func segments(_ jwt: String) throws -> (header: [String: Any], claims: [String: Any], input: Data, signature: Data) {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        try #require(parts.count == 3)
        func decode(_ part: Substring) throws -> Data {
            var text = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while text.count % 4 != 0 { text += "=" }
            return try #require(Data(base64Encoded: text))
        }
        func object(_ data: Data) throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        return (try object(decode(parts[0])), try object(decode(parts[1])),
                Data("\(parts[0]).\(parts[1])".utf8), try decode(parts[2]))
    }

    @Test("The sign-in is a form with client credentials and a client assertion signed ES256 in raw r||s")
    func signInRequest() async throws {
        let rig = try makeRig()
        _ = await finished(rig.store)
        let signIn = try #require(rig.signIns.first)
        #expect(signIn.method == "POST")
        #expect(signIn.header("Content-Type")?.hasPrefix("application/x-www-form-urlencoded") == true)

        var components = URLComponents()
        components.percentEncodedQuery = signIn.bodyString
        let form = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(form["grant_type"] == "client_credentials")
        #expect(form["client_id"] == Self.clientID)
        #expect(form["client_assertion_type"] == "urn:ietf:params:oauth:client-assertion-type:jwt-bearer")
        #expect(form["scope"] == "business.api")

        let jwt = try segments(try #require(form["client_assertion"]))
        #expect(jwt.header["alg"] as? String == "ES256")
        #expect(jwt.header["kid"] as? String == Self.keyID)
        #expect(jwt.claims["iss"] as? String == Self.clientID)
        #expect(jwt.claims["sub"] as? String == Self.clientID)
        #expect(jwt.claims["aud"] as? String == signIn.url.absoluteString)
        let issuedAt = try #require(jwt.claims["iat"] as? Double)
        let expires = try #require(jwt.claims["exp"] as? Double)
        #expect(expires > issuedAt && expires - issuedAt <= 20 * 60)
        #expect(!(jwt.claims["jti"] as? String ?? "").isEmpty)
        // Raw r||s (64 bytes), not DER, and valid for the key's public half.
        #expect(jwt.signature.count == 64)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: jwt.signature)
        #expect(rig.key.publicKey.isValidSignature(signature, for: jwt.input))
    }

    @Test("Apple School Manager signs in with the school scope and uses its own address")
    func schoolManager() async throws {
        let rig = try makeRig(service: .appleSchoolManager)
        #expect(rig.store.productName == "Apple School Manager")
        _ = await finished(rig.store)
        #expect(rig.signIns.first?.bodyString.contains("scope=school.api") == true)
        #expect(rig.api.allSatisfy { $0.url.host() == "api-school.apple.com" })
    }

    @Test("Every assertion has its own jti")
    func uniqueJTI() async throws {
        var ids = Set<String>()
        for _ in 0..<2 {
            let rig = try makeRig()
            _ = await finished(rig.store)
            var components = URLComponents()
            components.percentEncodedQuery = try #require(rig.signIns.first).bodyString
            let assertion = try #require(components.queryItems?.first { $0.name == "client_assertion" }?.value)
            ids.insert(try #require(try segments(assertion).claims["jti"] as? String))
        }
        #expect(ids.count == 2)
    }

    @Test("The access token is cached: several lookups sign in once, and it is sent as a Bearer token")
    func tokenCached() async throws {
        let rig = try makeRig { request in
            request.path.hasPrefix("/v1/orgDevices/OTHER") ? .json(404, #"{"errors": []}"#) : nil
        }
        _ = await finished(rig.store)
        _ = await finished(rig.store, "OTHER00001")
        #expect(rig.signIns.count == 1)
        #expect(rig.api.allSatisfy { $0.header("Authorization") == "Bearer \(Self.token)" })
    }

    @Test("Lookups at the same moment share one sign-in")
    func concurrentLookupsShareSignIn() async throws {
        let rig = try makeRig { _ in nil }
        let serials = (1...5).map { "CONCURR\($0)" }
        for serial in serials { rig.store.lookupIfNeeded(serial: serial) }
        for serial in serials {
            for _ in 0..<500 where rig.store.state(forSerial: serial) == .loading {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        #expect(rig.signIns.count == 1)
    }

    // MARK: Results

    @Test("A device with its device management service and AppleCare coverage")
    func foundDevice() async throws {
        let rig = try makeRig()
        guard case .found(let record) = await finished(rig.store) else {
            Issue.record("Expected a found device, got \(rig.store.state(forSerial: Self.serial))")
            return
        }
        #expect(record.device.serialNumber == Self.serial)
        #expect(record.device.deviceModel == "iPad Air 11-inch")
        #expect(record.device.productFamily == "iPad")
        #expect(record.device.orderNumber == "ORDER-PLACEHOLDER")
        #expect(record.device.addedToOrgDateTime == "2026-03-12T09:30:00.000Z")
        #expect(AppleBusinessText.status(record.device) == "Assigned")
        #expect(AppleBusinessText.purchaseSource(record.device) == "Reseller (RS-1)")
        #expect(record.mdmServerName == "Lab MDM")
        #expect(record.coverage.count == 1)
        #expect(record.coverage.first?.isActive == true)
        #expect(AppleBusinessText.coverage(record.coverage[0]).hasPrefix("Active until"))
        #expect(record.coverageProblem == nil)
        #expect(rig.api.map(\.path).contains("/v1/orgDevices/\(Self.serial)/relationships/assignedServer"))
    }

    @Test("The Open in link goes to the portal of the account in use, named Apple Business or Apple School Manager, and not in demo mode")
    func portalLink() throws {
        let business = try makeRig()
        #expect(business.store.portalURL == URL(string: "https://business.apple.com"))
        #expect(business.store.productName == "Apple Business")
        let school = try makeRig(service: .appleSchoolManager)
        #expect(school.store.portalURL == URL(string: "https://school.apple.com"))
        #expect(school.store.productName == "Apple School Manager")
        #expect(try makeRig(saved: false).store.portalURL == nil)
        let demo = AppleBusinessStore(connections: .forUnitTestHost(), demo: PreviewSupport.mode)
        #expect(demo.portalURL == nil)
    }

    @Test("The serial number is looked up uppercase and trimmed")
    func serialNormalized() async throws {
        let rig = try makeRig()
        guard case .found = await finished(rig.store, " placeholdr05 ") else {
            Issue.record("Expected a found device")
            return
        }
        #expect(rig.api.first?.path == "/v1/orgDevices/\(Self.serial)")
    }

    @Test("An unassigned device has no device management service")
    func unassigned() async throws {
        let rig = try makeRig { request in
            request.path.hasSuffix("/relationships/assignedServer") ? .json(200, #"{"data": null}"#) : nil
        }
        guard case .found(let record) = await finished(rig.store) else {
            Issue.record("Expected a found device")
            return
        }
        #expect(record.mdmServerName == nil)
    }

    @Test("A failed coverage request doesn't fail the lookup")
    func coverageFailure() async throws {
        let rig = try makeRig { request in
            request.path.hasSuffix("/appleCareCoverage")
                ? .json(500, #"{"errors": [{"status": "500", "code": "INTERNAL", "title": "Broken"}]}"#, headers: ["Retry-After": "0"])
                : nil
        }
        guard case .found(let record) = await finished(rig.store) else {
            Issue.record("Expected a found device")
            return
        }
        #expect(record.device.serialNumber == Self.serial)
        #expect(record.coverage.isEmpty)
        #expect(record.coverageProblem != nil)
    }

    @Test("A failed assigned-server or server-list request keeps the device that was found")
    func serverFailureKeepsDevice() async throws {
        for failing in ["/v1/orgDevices/\(Self.serial)/relationships/assignedServer", "/v1/mdmServers"] {
            let rig = try makeRig { request in
                request.path == failing
                    ? .json(403, #"{"errors": [{"status": "403", "code": "FORBIDDEN", "title": "Not allowed"}]}"#)
                    : nil
            }
            guard case .found(let record) = await finished(rig.store) else {
                Issue.record("\(failing) failing hid the device: \(rig.store.state(forSerial: Self.serial))")
                continue
            }
            #expect(record.device.serialNumber == Self.serial)
            #expect(record.mdmServerName == nil)
            #expect(record.serverProblem?.contains("403") == true)
            #expect(record.coverage.count == 1)
        }
    }

    // MARK: Errors

    @Test("404: the device isn't in the organization")
    func notInOrganization() async throws {
        let rig = try makeRig()
        #expect(await finished(rig.store, "UNKNOWN001") == .notInOrganization)
    }

    @Test("401 and 403 on the device: a message from Apple's answer, never the token")
    func authorizationErrors() async throws {
        for status in [401, 403] {
            let rig = try makeRig { request in
                request.path == "/v1/orgDevices/\(Self.serial)"
                    ? .json(status, #"{"errors": [{"status": "\#(status)", "code": "NOT_AUTHORIZED", "title": "Not allowed", "detail": "Token \#(Self.token) refused"}]}"#)
                    : nil
            }
            guard case .failed(let message) = await finished(rig.store) else {
                Issue.record("Expected a failure for \(status)")
                continue
            }
            #expect(message.contains("\(status)"))
            #expect(!message.contains(Self.token))
        }
    }

    @Test("Apple's sign-in refusing the account is shown, without the assertion or key")
    func signInRefused() async throws {
        let server = MockServer { _ in
            .json(400, #"{"error": "invalid_client", "error_description": "Client assertion is not valid"}"#)
        }
        let settings = TemporaryDefaults("applebusiness")
        let key = P256.Signing.PrivateKey()
        let connections = AppConnectionStore(defaults: settings.defaults, secrets: InMemorySecretStore())
        let record = AppleBusinessConnection(name: "Lab", service: .appleBusinessManager, signIn: .applePrivateKey,
                                             clientID: Self.clientID, keyID: Self.keyID)
        try connections.connections.save(.apple(record), secrets: [.main: key.pemRepresentation])
        connections.activeAppleID = record.id
        let store = AppleBusinessStore(connections: connections, activityLog: ActivityLog(), session: server.session)
        guard case .failed(let message) = await finished(store) else {
            Issue.record("Expected a failure")
            return
        }
        #expect(message.contains("invalid_client"))
        #expect(!message.contains("BEGIN"))
    }

    @Test("429 is retried after Retry-After; a lasting 429 is shown as a failure")
    func rateLimited() async throws {
        let calls = LockedCounter()
        let rig = try makeRig { request in
            guard request.path == "/v1/orgDevices/\(Self.serial)" else { return nil }
            return calls.next() == 1
                ? .json(429, #"{"errors": [{"status": "429", "code": "RATE_LIMIT", "title": "Too many requests"}]}"#,
                        headers: ["Retry-After": "0"])
                : nil
        }
        guard case .found = await finished(rig.store) else {
            Issue.record("Expected the retry to succeed")
            return
        }
        #expect(calls.value == 2)

        let lasting = try makeRig { request in
            request.path == "/v1/orgDevices/\(Self.serial)"
                ? .json(429, #"{"errors": [{"status": "429", "code": "RATE_LIMIT", "title": "Too many requests"}]}"#,
                        headers: ["Retry-After": "0"])
                : nil
        }
        guard case .failed(let message) = await finished(lasting.store) else {
            Issue.record("Expected a failure")
            return
        }
        #expect(message.contains("429"))
    }

    // MARK: Demo mode

    @Test("In demo mode the pretend iPhone is found in the demo organization, and no saved account is used")
    func demoFindsPretendIPhone() async throws {
        let store = AppleBusinessStore(connections: .forUnitTestHost(), demo: PreviewSupport.mode)
        #expect(store.isDemo && store.isConfigured)
        #expect(store.productName == "Apple Business")
        guard case .found(let record) = await finished(store, PretendIPhone.serial) else {
            Issue.record("The pretend iPhone isn't in the demo organization: \(store.state(forSerial: PretendIPhone.serial))")
            return
        }
        #expect(record.device.serialNumber == PretendIPhone.serial)
    }

    // MARK: Network

    @Test("Toward Apple only the sign-in is a POST; every other request is a GET, to Apple's own hosts only")
    func onlyGetsAndTheSignIn() async throws {
        for service in [ConnectionService.appleBusinessManager, .appleSchoolManager] {
            let rig = try makeRig(service: service)
            guard case .found = await finished(rig.store) else {
                Issue.record("Expected a found device")
                continue
            }
            let record = try #require(rig.store.connections.activeAppleConnection)
            _ = try await rig.store.testConnection(record, typedSecret: nil)
            let apiHost = service == .appleSchoolManager ? "api-school.apple.com" : "api-business.apple.com"
            #expect(!rig.server.requests.isEmpty)
            for request in rig.server.requests {
                #expect(request.url.scheme == "https")
                if request.url.host() == "account.apple.com" {
                    #expect(request.method == "POST")
                    #expect(request.path == "/auth/oauth2/v2/token")
                } else {
                    #expect(request.url.host() == apiHost)
                    #expect(request.method == "GET")
                    #expect(request.bodyString.isEmpty)
                }
            }
        }
    }

    // MARK: Status

    @Test("Only an assigned device looks assigned: Unassigned, Released and others are told apart")
    func statusKinds() throws {
        func device(_ status: String?) throws -> ABM.OrgDevice {
            // the record's attributes, as JTKit decodes them
            let json = status.map { #"{"serialNumber": "X", "status": "\#($0)"}"# } ?? #"{"serialNumber": "X"}"#
            return try JSONDecoder().decode(ABM.OrgDevice.self, from: Data(json.utf8))
        }
        #expect(AppleBusinessText.statusKind(try device("ASSIGNED")) == .assigned)
        #expect(AppleBusinessText.statusKind(try device("UNASSIGNED")) == .unassigned)
        #expect(AppleBusinessText.status(try device("UNASSIGNED")) == "Unassigned")
        #expect(AppleBusinessText.statusKind(try device("SOMETHING_NEW")) == .other)
        #expect(AppleBusinessText.statusKind(try device(nil)) == .other)
        #expect(AppleBusinessText.status(try device(nil)) == "Unknown")
    }

    @Test("The product family is shown as Apple writes it: iPhone, iPad, never Iphone")
    func productFamilySpelling() throws {
        for family in ["iPhone", "iPad", "Mac", "AppleTV"] {
            let device = try JSONDecoder().decode(ABM.OrgDevice.self,
                                                  from: Data(#"{"serialNumber": "X", "productFamily": "\#(family)"}"#.utf8))
            #expect(AppleBusinessText.productFamily(device) == family)
        }
        let none = try JSONDecoder().decode(ABM.OrgDevice.self, from: Data(#"{"serialNumber": "X", "productFamily": ""}"#.utf8))
        #expect(AppleBusinessText.productFamily(none) == nil)
    }

    // MARK: Storage

    @Test("Apple accounts are saved apart: their own key and Keychain store, and the Jamf list stays byte for byte")
    func storedApart() throws {
        let settings = TemporaryDefaults("applebusiness-storage")
        defer { settings.remove() }
        let jamfSecrets = InMemorySecretStore()
        let appleSecrets = InMemorySecretStore()
        let jamf = JamfConnection(name: "Lab Jamf", service: .jamfPro, signIn: .apiClient,
                                  serverURL: "https://example.jamfcloud.com", clientID: "jamf-client")
        let store = AppConnectionStore(defaults: settings.defaults, secrets: jamfSecrets, appleSecrets: appleSecrets)
        try store.connections.save(.jamf(jamf), secrets: [.main: "jamf-secret"])
        let jamfList = try #require(settings.defaults.data(forKey: AppConnectionStore.listKey))

        let apple = AppleBusinessConnection(name: "Lab Org", service: .appleSchoolManager, signIn: .applePrivateKey,
                                            clientID: Self.clientID, keyID: Self.keyID)
        try store.connections.save(.apple(apple), secrets: [.main: "PEM-PLACEHOLDER"])
        store.activeAppleID = apple.id

        // The Jamf list is untouched and reads as before, for older versions too.
        #expect(settings.defaults.data(forKey: AppConnectionStore.listKey) == jamfList)
        #expect(try JSONDecoder().decode([JamfConnection].self, from: jamfList) == [jamf])
        let appleList = try #require(settings.defaults.data(forKey: AppConnectionStore.appleListKey))
        #expect(try JSONDecoder().decode([AppleBusinessConnection].self, from: appleList) == [apple])
        #expect(settings.defaults.string(forKey: AppConnectionStore.appleActiveKey) == apple.id.uuidString)
        // Each secret in its own store, under the connection's UUID.
        #expect(jamfSecrets.secret(for: jamf.id.uuidString) == "jamf-secret")
        #expect(jamfSecrets.secret(for: apple.id.uuidString) == nil)
        #expect(appleSecrets.secret(for: apple.id.uuidString) == "PEM-PLACEHOLDER")
        #expect(appleSecrets.secret(for: jamf.id.uuidString) == nil)

        // Read again at the next launch: both lists, both choices.
        let next = AppConnectionStore(defaults: settings.defaults, secrets: jamfSecrets, appleSecrets: appleSecrets)
        #expect(next.jamfConnections == [jamf])
        #expect(next.appleConnections == [apple])
        #expect(next.activeConnection == jamf)
        #expect(next.activeAppleConnection == apple)
        #expect(try next.hasSecret(for: apple))
        #expect(try next.secretReader(for: apple.connection)() == "PEM-PLACEHOLDER")

        // Deleting the account removes its list entry and key only.
        try next.connections.delete(id: apple.id)
        next.connectionWasDeleted()
        #expect(next.activeAppleID == nil)
        #expect(appleSecrets.secret(for: apple.id.uuidString) == nil)
        #expect(settings.defaults.data(forKey: AppConnectionStore.listKey) == jamfList)
        #expect(jamfSecrets.secret(for: jamf.id.uuidString) == "jamf-secret")
    }

    @Test("The roles: the Jamf role takes Jamf services only, the Apple role Apple Business and Apple School Manager only")
    func roles() throws {
        let rig = try makeRig()
        let jamf = JamfStore(connections: rig.store.connections)
        let jamfRole = jamf.connectionRole(selection: .constant(nil))
        let appleRole = rig.store.connectionRole(selection: .constant(nil))
        for service in AppConnection.services {
            let connection = Connection(name: "x", service: service)
            #expect(jamfRole.accepts(connection) == AppConnection.jamfServices.contains(service))
            #expect(appleRole.accepts(connection) == AppConnection.appleServices.contains(service))
        }
        #expect(!jamfRole.accepts(Connection(name: "x", service: .intune)))
        #expect(!appleRole.accepts(Connection(name: "x", service: .intune)))
    }

    @Test("A wait for Apple shows in the wait bar, and Stop ends the lookup without sending it again")
    func waitIsShownAndCanBeStopped() async throws {
        let calls = LockedCounter()
        let rig = try makeRig { request in
            guard request.path == "/v1/orgDevices/\(Self.serial)" else { return nil }
            _ = calls.next()
            return .json(429, #"{"errors": [{"status": "429", "code": "RATE_LIMIT", "title": "Too many requests"}]}"#,
                         headers: ["Retry-After": "40"])
        }
        rig.store.lookupIfNeeded(serial: Self.serial)
        for _ in 0..<500 where rig.store.waits.statusText == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let text = try #require(rig.store.waits.statusText)
        #expect(text.contains("Apple asked to wait"))
        rig.store.waits.cancelAll()
        for _ in 0..<500 where rig.store.state(forSerial: Self.serial) == .loading {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(rig.store.state(forSerial: Self.serial) == .failed(JamfStore.stoppedText))
        #expect(rig.store.waits.statusText == nil)
        #expect(calls.value == 1)
    }

    @Test("An unassigned device costs no assigned-server request")
    func unassignedSkipsServerRequest() async throws {
        let unassigned = Self.deviceJSON.replacingOccurrences(of: #""status": "ASSIGNED""#, with: #""status": "UNASSIGNED""#)
        let rig = try makeRig { request in
            request.path == "/v1/orgDevices/\(Self.serial)" ? .json(200, unassigned) : nil
        }
        guard case .found(let record) = await finished(rig.store) else {
            Issue.record("Expected a found device")
            return
        }
        #expect(AppleBusinessText.statusKind(record.device) == .unassigned)
        #expect(record.mdmServerName == nil)
        #expect(!rig.api.contains { $0.path.hasSuffix("/relationships/assignedServer") || $0.path == "/v1/mdmServers" })
    }

    @Test("Retry Lookup (⌘R) is offered when either lookup has an answer to repeat, and repeats the Apple one")
    func retryCoversBothLookups() async throws {
        let device = USBDevice(id: 1, mode: .recovery, productID: 0x1281, usbProductName: nil,
                               descriptor: DescriptorParser.parse("CPID:6060 BDID:0A ECID:001A2B3C4D5E6F72 SRNM:[\(Self.serial)]"),
                               udid: nil, modelInfo: nil, connectedAt: .now)
        func offered(_ apple: AppleBusinessLookupState?) -> Bool {
            DeviceActionAvailability(device: device, busy: false, editingAssetTag: false, connectedDeviceCount: 1,
                                     configuratorAvailable: true, jamfState: .notConfigured, appleState: apple).retryLookup
        }
        #expect(!offered(nil))
        #expect(!offered(.loading))
        #expect(offered(.failed("x")))
        #expect(offered(.notInOrganization))

        let rig = try makeRig()
        _ = await finished(rig.store)
        let before = rig.api.filter { $0.path == "/v1/orgDevices/\(Self.serial)" }.count
        rig.store.refresh(serial: Self.serial)
        for _ in 0..<500 where rig.store.state(forSerial: Self.serial) == .loading {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(rig.api.filter { $0.path == "/v1/orgDevices/\(Self.serial)" }.count == before + 1)
    }

    // MARK: Test Connection, secrets, export

    @Test("Test Connection signs in with the typed private key and counts the device management services")
    func testConnection() async throws {
        let rig = try makeRig(saved: false)
        let record = AppleBusinessConnection(name: "Lab", service: .appleBusinessManager, signIn: .applePrivateKey,
                                             clientID: Self.clientID, keyID: Self.keyID)
        let message = try await rig.store.testConnection(record, typedSecret: rig.pem)
        #expect(message == "Connected · Apple Business · 2 device management services")
        #expect(rig.signIns.count == 1)
        await #expect(throws: ConnectionTestError("Fill in the client ID, key ID and private key first.")) {
            try await rig.store.testConnection(record, typedSecret: "")
        }
    }

    @Test("The private key lives only in the secrets store: not in the settings, not in the activity log")
    func keyStaysSecret() async throws {
        let rig = try makeRig()
        _ = await finished(rig.store)
        let body = rig.pem.split(separator: "\n").dropFirst().dropLast().joined()
        // The list is JSON data in the settings: read it as text.
        let stored = rig.settings.defaults.dictionaryRepresentation().values
            .map { ($0 as? Data).map { String(decoding: $0, as: UTF8.self) } ?? "\($0)" }.joined()
        #expect(!stored.contains(body))
        #expect(stored.contains(Self.clientID))
        #expect(rig.secrets.secret(for: try #require(rig.store.connections.activeAppleID).uuidString) == rig.pem)
        let logged = rig.log.entries.map(ActivityLogExport.transcript(of:)).joined()
            + ActivityLogExport.text(rig.log.entries, masked: false)
        #expect(!rig.log.entries.isEmpty)
        #expect(!logged.contains(body))
        #expect(!logged.contains(Self.token))
        // The client ID is saved with the account, like a Jamf client ID, but
        // never logged.
        #expect(!logged.contains(Self.clientID))
        #expect(!logged.contains(Self.keyID))
    }

    @Test("The CSV has the two Apple Business columns, empty when the feature is off")
    func exportColumns() async throws {
        let rig = try makeRig()
        let state = await finished(rig.store)
        let device = USBDevice(id: 1, mode: .recovery, productID: 0x1281, usbProductName: nil,
                               descriptor: DescriptorParser.parse("CPID:6060 BDID:0A ECID:001A2B3C4D5E6F72 SRNM:[\(Self.serial)]"),
                               udid: nil, modelInfo: nil, connectedAt: .now)
        let row = SessionExport.row(for: device, jamf: .notConfigured, appleBusiness: state)
        #expect(row.appleBusinessStatus == "Assigned")
        #expect(row.appleBusinessMDMServer == "Lab MDM")
        #expect(SessionExport.header.suffix(2) == ["Apple Business Status", "Apple Business Device Management Service"])
        #expect(SessionExport.csv([row]).contains("Assigned,Lab MDM"))

        let off = SessionExport.row(for: device, jamf: .notConfigured)
        #expect(off.appleBusinessStatus.isEmpty && off.appleBusinessMDMServer.isEmpty)
        #expect(AppleBusinessText.exportStatus(.notInOrganization) == "Not in organization")
        #expect(AppleBusinessText.exportStatus(.failed("x")) == "Failed")
    }
}

/// Counts calls from the fake server's handler, which runs off the main actor.
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
    var value: Int { lock.withLock { count } }
}

/// Counts reads of a secret apart from presence checks, and can refuse like
/// a locked Keychain.
private final class CountingSecretStore: SecretStore, @unchecked Sendable {
    private let base: any SecretStore
    private let lock = NSLock()
    private var counts = (reads: 0, presence: 0, writes: 0)
    private var refusing = false

    init(base: any SecretStore) { self.base = base }

    var reads: Int { lock.withLock { counts.reads } }
    var presenceChecks: Int { lock.withLock { counts.presence } }
    var writes: Int { lock.withLock { counts.writes } }
    var refuses: Bool {
        get { lock.withLock { refusing } }
        set { lock.withLock { refusing = newValue } }
    }

    func secret(for account: String) -> String? { try? readSecret(for: account) }

    func readSecret(for account: String) throws -> String? {
        if refuses { throw SecretStoreError(status: errSecInteractionNotAllowed) }
        lock.withLock { counts.reads += 1 }
        return try base.readSecret(for: account)
    }

    func hasSecret(for account: String) throws -> Bool {
        if refuses { throw SecretStoreError(status: errSecInteractionNotAllowed) }
        lock.withLock { counts.presence += 1 }
        return try base.hasSecret(for: account)
    }

    @discardableResult
    func setSecret(_ secret: String?, for account: String) -> Bool {
        lock.withLock { counts.writes += 1 }
        return base.setSecret(secret, for: account)
    }

    func writeSecret(_ secret: String?, for account: String) throws {
        lock.withLock { counts.writes += 1 }
        try base.writeSecret(secret, for: account)
    }
}
