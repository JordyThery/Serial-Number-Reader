import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Serial_Number_Reader

/// The one-time conversion of the old single settings into saved connections,
/// in a throwaway UserDefaults domain with secrets in memory. The tests share
/// one domain, emptied before and after each, so they run one at a time.
@MainActor
@Suite("Connection conversion", .serialized)
final class ConnectionConversionTests {
    private typealias Method = LegacySettingsConversion.Method
    private typealias OldKey = LegacySettingsConversion.OldKey

    private let domain = "be.jordythery.SerialNumberReader.conversion-tests"
    private let defaults: UserDefaults
    private let secrets = InMemorySecretStore()

    init() throws {
        defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
    }

    deinit {
        defaults.removePersistentDomain(forName: domain)
    }

    // MARK: Helpers

    /// Every old setting and secret filled in, as a user of every method would have.
    private func fillInEverything(inUse: Method = .platform) {
        defaults.set(inUse.rawValue, forKey: OldKey.authMethod)
        defaults.set("yourorg.jamfcloud.com/", forKey: OldKey.serverURL)
        defaults.set("pro-client", forKey: OldKey.clientID)
        defaults.set("admin", forKey: OldKey.username)
        defaults.set("us", forKey: OldKey.platformRegion)
        defaults.set(" platform-client ", forKey: OldKey.platformClientID)
        defaults.set("E77C1408-10C8-4007-B177-ABC9157FBCAA", forKey: OldKey.platformEnvironmentID)
        defaults.set("https://yourschool.jamfcloud.com", forKey: OldKey.schoolURL)
        defaults.set("012345", forKey: OldKey.schoolNetworkID)
        secrets.setSecret("pro-secret", for: "clientSecret")
        secrets.setSecret("password", for: "jamfPassword")
        secrets.setSecret("platform-secret", for: "jamfPlatformClientSecret")
        secrets.setSecret("school-key", for: "jamfSchoolAPIKey")
    }

    private func makeStore() -> ConnectionStore<JamfConnection> {
        ConnectionStore(storage: UserDefaultsConnectionStorage(key: JamfConnectionStore.listKey, defaults: defaults),
                        secrets: [.main: SecretLocation(store: secrets)])
    }

    private func run(into store: ConnectionStore<JamfConnection>? = nil) -> LegacySettingsConversion.Outcome {
        LegacySettingsConversion.run(defaults: defaults, secrets: secrets, into: store ?? makeStore())
    }

    /// The old keys and Keychain accounts with their values.
    private func oldSettings() -> [String: String] {
        let keys = [OldKey.authMethod, OldKey.serverURL, OldKey.clientID, OldKey.username, OldKey.platformRegion,
                    OldKey.platformClientID, OldKey.platformEnvironmentID, OldKey.schoolURL, OldKey.schoolNetworkID]
        var values = [String: String]()
        for key in keys { values["defaults:\(key)"] = defaults.string(forKey: key) ?? "<missing>" }
        for method in Method.allCases {
            values["keychain:\(method.secretAccount)"] = secrets.secret(for: method.secretAccount) ?? "<missing>"
        }
        return values
    }

    // MARK: What it creates

    @Test("Each filled-in method becomes a connection with its fields and its secret")
    func convertsEveryMethod() throws {
        fillInEverything()
        let store = makeStore()

        #expect(run(into: store) == .converted(added: 4, activeID: Method.platform.connectionID))
        #expect(store.records.map(\.id) == Method.allCases.map(\.connectionID))

        let pro = try #require(store.record(id: Method.clientCredentials.connectionID))
        #expect(pro == JamfConnection(id: pro.id, name: "Jamf Pro (API client)", service: .jamfPro, signIn: .apiClient,
                                      serverURL: "https://yourorg.jamfcloud.com", clientID: "pro-client"))
        #expect(store.secret(for: pro.connection) == "pro-secret")

        let basic = try #require(store.record(id: Method.basic.connectionID))
        #expect(basic == JamfConnection(id: basic.id, name: "Jamf Pro (username and password)", service: .jamfPro,
                                        signIn: .usernamePassword, serverURL: "https://yourorg.jamfcloud.com",
                                        username: "admin"))
        #expect(store.secret(for: basic.connection) == "password")

        let platform = try #require(store.record(id: Method.platform.connectionID))
        #expect(platform == JamfConnection(id: platform.id, name: "Jamf Platform API", service: .jamfPlatform,
                                           signIn: .apiClient, region: .us,
                                           environmentID: "E77C1408-10C8-4007-B177-ABC9157FBCAA",
                                           jamfProWebURL: "https://yourorg.jamfcloud.com",
                                           clientID: "platform-client"))
        #expect(store.secret(for: platform.connection) == "platform-secret")

        let school = try #require(store.record(id: Method.jamfSchool.connectionID))
        #expect(school == JamfConnection(id: school.id, name: "Jamf School", service: .jamfSchool,
                                         signIn: .schoolAPIKey, serverURL: "https://yourschool.jamfcloud.com",
                                         clientID: "012345"))
        #expect(store.secret(for: school.connection) == "school-key")

        // the shared editor accepts every converted connection as it is
        for record in store.records {
            #expect(record.connection.issues.isEmpty, "\(record.name)")
        }
        #expect(defaults.bool(forKey: LegacySettingsConversion.markerKey))
    }

    @Test("Secrets are copied to the connection's own Keychain account")
    func secretsGoToConnectionAccounts() {
        fillInEverything()
        _ = run()
        for method in Method.allCases {
            #expect(secrets.secret(for: method.connectionID.uuidString) == secrets.secret(for: method.secretAccount))
        }
        #expect(secrets.all.count == 8)
    }

    @Test("A secret alone is enough to convert a method")
    func secretAlone() {
        defaults.set(Method.clientCredentials.rawValue, forKey: OldKey.authMethod)
        secrets.setSecret("school-key", for: "jamfSchoolAPIKey")
        let store = makeStore()
        _ = run(into: store)
        #expect(store.records.map(\.id) == [Method.jamfSchool.connectionID])
    }

    @Test("A shared server address alone converts only the method in use")
    func sharedAddressCountsOnlyForMethodInUse() {
        defaults.set(Method.basic.rawValue, forKey: OldKey.authMethod)
        defaults.set("https://yourorg.jamfcloud.com", forKey: OldKey.serverURL)
        let store = makeStore()

        #expect(run(into: store) == .converted(added: 1, activeID: Method.basic.connectionID))
        #expect(store.records.map(\.id) == [Method.basic.connectionID])
    }

    @Test("The region alone, always set by the old picker, doesn't count")
    func regionAloneDoesNotCount() {
        defaults.set(Method.jamfSchool.rawValue, forKey: OldKey.authMethod)
        defaults.set("us", forKey: OldKey.platformRegion)
        let store = makeStore()
        _ = run(into: store)
        #expect(store.records.isEmpty)
    }

    @Test("Without a region, the Platform API connection gets Europe, the old default")
    func platformRegionDefault() throws {
        defaults.set("platform-client", forKey: OldKey.platformClientID)
        let store = makeStore()
        _ = run(into: store)
        #expect(try #require(store.records.first).region == .eu)
    }

    // MARK: The active connection

    @Test("Without a saved method, the API client is active, as before")
    func defaultMethodIsAPIClient() {
        fillInEverything()
        defaults.removeObject(forKey: OldKey.authMethod)
        #expect(run().activeID == Method.clientCredentials.connectionID)
    }

    @Test("When the method in use has nothing filled in, the first converted connection is active")
    func activeFallsBackToFirst() {
        defaults.set(Method.basic.rawValue, forKey: OldKey.authMethod)
        defaults.set("platform-client", forKey: OldKey.platformClientID)
        defaults.set("012345", forKey: OldKey.schoolNetworkID)
        #expect(run() == .converted(added: 2, activeID: Method.platform.connectionID))
    }

    @Test("The app saves the converted active connection")
    func appSavesActiveConnection() {
        fillInEverything(inUse: .jamfSchool)
        let app = JamfConnectionStore(defaults: defaults, secrets: secrets)
        #expect(app.activeID == Method.jamfSchool.connectionID)
        #expect(defaults.string(forKey: JamfConnectionStore.activeKey) == Method.jamfSchool.connectionID.uuidString)
    }

    @Test("With nothing filled in, nothing is created and the marker is set")
    func nothingToConvert() {
        let store = makeStore()
        #expect(run(into: store) == .converted(added: 0, activeID: nil))
        #expect(store.records.isEmpty)
        #expect(defaults.object(forKey: JamfConnectionStore.listKey) == nil)
        #expect(defaults.bool(forKey: LegacySettingsConversion.markerKey))
    }

    // MARK: Once, without duplicates

    @Test("Running it twice converts once and reads nothing the second time")
    func runningTwice() {
        fillInEverything()
        #expect(run() == .converted(added: 4, activeID: Method.platform.connectionID))
        let listAfterFirst = defaults.data(forKey: JamfConnectionStore.listKey)
        let secretsAfterFirst = secrets.all

        // the old settings change afterwards, e.g. in an older build
        defaults.set("other-client", forKey: OldKey.clientID)
        secrets.setSecret("changed", for: "clientSecret")

        let store = makeStore()
        #expect(run(into: store) == .alreadyDone)
        #expect(store.records.count == 4)
        #expect(defaults.data(forKey: JamfConnectionStore.listKey) == listAfterFirst)
        #expect(secrets.secret(for: Method.clientCredentials.connectionID.uuidString)
                == secretsAfterFirst[Method.clientCredentials.connectionID.uuidString])
    }

    @Test("Relaunching the app twice keeps one copy of each connection and the user's choice")
    func relaunchingTheApp() {
        fillInEverything()
        let first = JamfConnectionStore(defaults: defaults, secrets: secrets)
        first.activeID = Method.basic.connectionID

        let second = JamfConnectionStore(defaults: defaults, secrets: secrets)
        #expect(second.connections.records.count == 4)
        #expect(second.activeID == Method.basic.connectionID)
    }

    @Test("Without the marker, the fixed IDs still prevent duplicates")
    func markerLostAddsNothing() {
        fillInEverything()
        _ = run()
        defaults.removeObject(forKey: LegacySettingsConversion.markerKey)

        let store = makeStore()
        #expect(run(into: store) == .converted(added: 0, activeID: Method.platform.connectionID))
        #expect(store.records.count == 4)
    }

    @Test("A run that stopped halfway is completed without duplicates or overwriting")
    func completesPartialRun() throws {
        fillInEverything()
        // the first run saved the API client connection, then stopped
        let store = makeStore()
        let partial = JamfConnection(id: Method.clientCredentials.connectionID, name: "Jamf Pro (API client)",
                                     service: .jamfPro, signIn: .apiClient)
        try store.save(partial, secrets: [.main: "already-copied"])

        #expect(run(into: store) == .converted(added: 3, activeID: Method.platform.connectionID))
        #expect(store.records.count == 4)
        #expect(store.record(id: partial.id) == partial)
        #expect(store.secret(for: partial.connection) == "already-copied")
    }

    @Test("A list that already holds other connections is left alone")
    func existingListWins() throws {
        fillInEverything()
        let store = makeStore()
        let own = JamfConnection(name: "Added by hand", service: .jamfSchool, signIn: .schoolAPIKey)
        try store.save(own)
        defaults.removeObject(forKey: LegacySettingsConversion.markerKey)
        let listBefore = defaults.data(forKey: JamfConnectionStore.listKey)

        #expect(run(into: store) == .skippedExistingList)
        #expect(store.records == [own])
        #expect(defaults.data(forKey: JamfConnectionStore.listKey) == listBefore)
        #expect(defaults.bool(forKey: LegacySettingsConversion.markerKey))
    }

    // MARK: Failures

    @Test("When the Keychain refuses, the marker stays unset and the next launch completes it")
    func keychainRefusesThenRetries() {
        fillInEverything()
        secrets.refusesWrites = true
        let store = makeStore()

        guard case .failed = run(into: store) else {
            Issue.record("expected the conversion to fail")
            return
        }
        #expect(store.records.isEmpty)
        #expect(defaults.object(forKey: LegacySettingsConversion.markerKey) == nil)

        secrets.refusesWrites = false
        let next = makeStore()
        #expect(run(into: next) == .converted(added: 4, activeID: Method.platform.connectionID))
        #expect(next.records.count == 4)
    }

    @Test("An unreadable list is not converted into and not replaced")
    func unreadableList() {
        fillInEverything()
        let garbage = Data("not json".utf8)
        defaults.set(garbage, forKey: JamfConnectionStore.listKey)
        let store = makeStore()

        guard case .failed = run(into: store) else {
            Issue.record("expected the conversion to fail")
            return
        }
        #expect(defaults.data(forKey: JamfConnectionStore.listKey) == garbage)
        #expect(defaults.object(forKey: LegacySettingsConversion.markerKey) == nil)
    }

    // MARK: The old settings stay as they are

    @Test("The old settings and Keychain items are unchanged afterwards")
    func oldSettingsUntouched() {
        fillInEverything()
        let before = oldSettings()
        let app = JamfConnectionStore(defaults: defaults, secrets: secrets)

        // using the new list doesn't write to the old settings either
        if let record = app.connections.records.first {
            try? app.connections.delete(id: record.id)
        }
        app.activeID = nil

        #expect(oldSettings() == before)
    }

    // MARK: Using a converted connection

    @Test("Converted connections build the same configuration as the old settings")
    func configurations() throws {
        fillInEverything()
        let store = makeStore()
        _ = run(into: store)

        func configuration(_ method: Method) throws -> JamfConfiguration {
            let record = try #require(store.record(id: method.connectionID))
            return try #require(JamfStore.configuration(for: record, secret: store.secret(for: record.connection) ?? ""))
        }
        let platform = try configuration(.platform)
        #expect(platform.apiBaseURL.absoluteString == "https://us.api.jamfcloud.com/pro")
        #expect(platform.webBaseURL?.absoluteString == "https://yourorg.jamfcloud.com")
        #expect(platform.credentials == .platform(region: .us, clientID: "platform-client",
                                                   clientSecret: "platform-secret",
                                                   environmentID: "E77C1408-10C8-4007-B177-ABC9157FBCAA"))
        #expect(try configuration(.basic).credentials == .basic(username: "admin", password: "password"))
        #expect(try configuration(.clientCredentials).tokenURL?.absoluteString
                == "https://yourorg.jamfcloud.com/api/oauth/token")
        #expect(try configuration(.jamfSchool).isJamfSchool)
    }

    @Test("Setting back the connection just read leaves the record unchanged")
    func connectionRoundTrip() {
        fillInEverything()
        let store = makeStore()
        _ = run(into: store)
        for record in store.records {
            var copy = record
            copy.connection = record.connection
            #expect(copy == record)
        }
    }
}
