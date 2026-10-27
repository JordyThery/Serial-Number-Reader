import Foundation
import JTKit
import Observation
import os

/// A saved Jamf connection: Jamf Pro (API client or username and password),
/// the Jamf Platform API, or Jamf School.
///
/// The list is saved as JSON under the UserDefaults key `jamfConnections` with
/// these field names; keep them, or saved connections are lost. The secret is
/// not part of it: it is in the Keychain (see `JamfConnectionStore.keychain`).
nonisolated struct JamfConnection: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var service: ConnectionService
    var signIn: SignInMethod
    /// Jamf Pro and Jamf School: the server address.
    var serverURL = ""
    /// Jamf Platform API.
    var region: JamfRegion = .eu
    var environmentID = ""
    /// Jamf Platform API: the Jamf Pro address, used only for "Open in Jamf Pro" links.
    var jamfProWebURL = ""
    /// The API client ID; Jamf School's Network ID.
    var clientID = ""
    var username = ""
}

/// How JTKit's connections list and editor see a saved connection.
nonisolated extension JamfConnection: ConnectionRecord {
    var connection: Connection {
        get {
            Connection(id: id, name: name, service: service, signIn: signIn,
                       serverURL: serverURL, region: region, environmentID: environmentID,
                       jamfProWebURL: jamfProWebURL, clientID: clientID, username: username)
        }
        set {
            name = newValue.name
            service = newValue.service
            signIn = newValue.signIn
            serverURL = newValue.serverURL
            region = newValue.region
            environmentID = newValue.environmentID
            jamfProWebURL = newValue.jamfProWebURL
            clientID = newValue.clientID
            username = newValue.username
        }
    }
}

/// The saved Jamf connections and the one in use. JTKit's `ConnectionStore`
/// keeps the list under the UserDefaults key `jamfConnections` and each
/// connection's secret in the login Keychain (service
/// `be.jordythery.SerialNumberReader.jamf`, account = connection UUID). The
/// connection in use is saved under `activeJamfConnectionID`.
///
/// On first launch the single settings of earlier versions become connections
/// (`LegacySettingsConversion`); those settings are only read, never changed.
@Observable
final class JamfConnectionStore {
    static let listKey = "jamfConnections"
    static let activeKey = "activeJamfConnectionID"

    let connections: ConnectionStore<JamfConnection>
    @ObservationIgnored private let defaults: UserDefaults

    var activeID: UUID? {
        didSet { defaults.set(activeID?.uuidString, forKey: Self.activeKey) }
    }

    /// - Parameters:
    ///   - defaults: where the list, the connection in use and the old settings are.
    ///   - secrets: where secrets are kept, old and new; the app's Keychain items by default.
    init(defaults: UserDefaults = .standard, secrets: any SecretStore = JamfConnectionStore.keychain) {
        self.defaults = defaults
        let logger = Self.logger
        // Can name connections, Keychain accounts and files: private in the system log.
        let log: (String) -> Void = { logger.error("\($0, privacy: .private)") }
        connections = ConnectionStore(
            storage: UserDefaultsConnectionStorage(key: Self.listKey, defaults: defaults),
            secrets: [.main: SecretLocation(store: secrets)],
            log: log
        )

        let conversion = LegacySettingsConversion.run(defaults: defaults, secrets: secrets,
                                                      into: connections, log: log)
        let stored = defaults.string(forKey: Self.activeKey).flatMap(UUID.init)
        if let stored, connections.record(id: stored) != nil {
            activeID = stored
        } else {
            activeID = conversion.activeID ?? connections.records.first?.id
            // didSet doesn't run in init. Never cleared here: while the list
            // can't be read, the saved choice must survive.
            if let activeID, activeID != stored {
                defaults.set(activeID.uuidString, forKey: Self.activeKey)
            }
        }
    }

    /// Secrets of earlier versions and of saved connections share this service.
    nonisolated static let keychain = KeychainSecretStore(
        service: "be.jordythery.SerialNumberReader.jamf",
        log: { logger.error("\($0, privacy: .private)") }
    )

    private nonisolated static let logger = Logger(subsystem: "be.jordythery.SerialNumberReader", category: "Connections")

    /// Whether the app was launched as the host of its unit tests.
    nonisolated static var isUnitTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
    }

    /// The store for the app while it hosts unit tests: an empty, throwaway
    /// settings domain and no Keychain, so running the tests never converts
    /// or changes the real settings and Keychain items.
    static let unitTestHostDomain = "be.jordythery.SerialNumberReader.unit-test-host"

    static func forUnitTestHost() -> JamfConnectionStore {
        let domain = unitTestHostDomain
        let defaults = UserDefaults(suiteName: domain) ?? .standard
        defaults.removePersistentDomain(forName: domain)
        return JamfConnectionStore(defaults: defaults, secrets: NoSecrets())
    }

    private nonisolated struct NoSecrets: SecretStore {
        func secret(for account: String) -> String? { nil }
        func setSecret(_ secret: String?, for account: String) -> Bool { secret == nil }
    }

    var activeConnection: JamfConnection? {
        activeID.flatMap(connections.record(id:))
    }

    /// The stored secret, or nil when there is none or the Keychain can't be read.
    func secret(for record: JamfConnection) -> String? {
        connections.secret(for: record.connection)
    }

    /// A new connection for + in Settings › Connections. The first one becomes active.
    func newConnection(service: ConnectionService) -> JamfConnection {
        let record = JamfConnection(name: "New Connection", service: service, signIn: service.signInMethods[0])
        if activeConnection == nil { activeID = record.id }
        return record
    }

    /// After a connection was deleted in Settings: when it was the active one,
    /// the first remaining connection becomes active.
    func connectionWasDeleted() {
        if activeConnection == nil { activeID = connections.records.first?.id }
    }
}
