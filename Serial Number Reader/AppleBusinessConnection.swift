import Foundation
import JTKit
import Observation
import os

/// A saved Apple Business Manager or Apple School Manager API account.
///
/// The list is saved as JSON under the UserDefaults key
/// `appleBusinessConnections` with these field names; keep them, or saved
/// accounts are lost. The private key is not part of it: it is in the
/// Keychain (see `AppleBusinessConnectionStore.keychain`). It is separate
/// from the Jamf connections, which stay as they are.
nonisolated struct AppleBusinessConnection: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var service: ConnectionService
    var signIn: SignInMethod
    /// The API account's client ID.
    var clientID = ""
    /// The ID of the private key (.pem) downloaded with the account.
    var keyID = ""
}

/// How JTKit's connections list and editor see a saved account.
nonisolated extension AppleBusinessConnection: ConnectionRecord {
    var connection: Connection {
        get {
            Connection(id: id, name: name, service: service, signIn: signIn, clientID: clientID, keyID: keyID)
        }
        set {
            name = newValue.name
            service = newValue.service
            signIn = newValue.signIn
            clientID = newValue.clientID
            keyID = newValue.keyID
        }
    }
}

/// The saved Apple Business and Apple School Manager accounts and the one in
/// use. JTKit's `ConnectionStore` keeps the list under the UserDefaults key
/// `appleBusinessConnections` and each account's private key in the login
/// Keychain (service `be.jordythery.SerialNumberReader.appleBusiness`,
/// account = the connection's UUID). The account in use is saved under
/// `activeAppleBusinessConnectionID`.
@Observable
final class AppleBusinessConnectionStore {
    static let listKey = "appleBusinessConnections"
    static let activeKey = "activeAppleBusinessConnectionID"

    let connections: ConnectionStore<AppleBusinessConnection>
    @ObservationIgnored private let defaults: UserDefaults
    /// Whether this is the real list: the app's settings and Keychain items.
    /// Under tests its requests are refused (`TestRun.refusingSession`).
    let holdsSavedConnections: Bool

    var activeID: UUID? {
        didSet { defaults.set(activeID?.uuidString, forKey: Self.activeKey) }
    }

    /// - Parameters:
    ///   - defaults: where the list and the account in use are saved.
    ///   - secrets: where private keys are kept; the app's Keychain items by default.
    init(defaults: UserDefaults = .standard, secrets: any SecretStore = AppleBusinessConnectionStore.keychain) {
        self.defaults = defaults
        holdsSavedConnections = !LiveLaunch.isSwitched
            && (defaults === UserDefaults.standard || secrets is KeychainSecretStore)
        let logger = Self.logger
        // Can name accounts and Keychain items: private in the system log.
        connections = ConnectionStore(
            storage: UserDefaultsConnectionStorage(key: Self.listKey, defaults: defaults),
            secrets: [.main: SecretLocation(store: secrets)],
            log: { logger.error("\($0, privacy: .private)") }
        )
        let stored = defaults.string(forKey: Self.activeKey).flatMap(UUID.init)
        if let stored, connections.record(id: stored) != nil {
            activeID = stored
        } else {
            activeID = connections.records.first?.id
            // didSet doesn't run in init. Never cleared here: while the list
            // can't be read, the saved choice must survive.
            if let activeID, activeID != stored {
                defaults.set(activeID.uuidString, forKey: Self.activeKey)
            }
        }
    }

    /// The private keys of the saved accounts; a service of their own, apart
    /// from the Jamf secrets.
    nonisolated static let keychain = KeychainSecretStore(
        service: "be.jordythery.SerialNumberReader.appleBusiness",
        log: { logger.error("\($0, privacy: .private)") }
    )

    private nonisolated static let logger = Logger(subsystem: "be.jordythery.SerialNumberReader", category: "AppleBusiness")

    /// The store while the app hosts unit tests: an empty, throwaway settings
    /// domain and no Keychain.
    static func forUnitTestHost() -> AppleBusinessConnectionStore {
        let defaults = JamfConnectionStore.emptiedDefaults(domain: JamfConnectionStore.unitTestHostDomain + ".apple")
        return AppleBusinessConnectionStore(defaults: defaults, secrets: NoSecrets())
    }

    private nonisolated struct NoSecrets: SecretStore {
        func secret(for account: String) -> String? { nil }
        func setSecret(_ secret: String?, for account: String) -> Bool { secret == nil }
    }

    var activeConnection: AppleBusinessConnection? {
        activeID.flatMap(connections.record(id:))
    }

    /// The stored private key, or nil when there is none.
    /// - Throws: when the Keychain can't be read (refused, locked).
    func readSecret(for record: AppleBusinessConnection) throws -> String? {
        try connections.readSecret(for: record.connection)
    }

    /// A new account for + in Settings. The first one becomes active.
    func newConnection(service: ConnectionService) -> AppleBusinessConnection {
        let record = AppleBusinessConnection(name: service.displayName, service: service, signIn: service.signInMethods[0])
        if activeConnection == nil { activeID = record.id }
        return record
    }

    /// After an account was deleted in Settings: when it was the one in use,
    /// the first remaining one becomes active.
    func connectionWasDeleted() {
        if activeConnection == nil { activeID = connections.records.first?.id }
    }
}
