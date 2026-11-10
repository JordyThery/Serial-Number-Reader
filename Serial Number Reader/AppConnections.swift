import Foundation
import JTKit
import Observation
import os

// The app's saved connections in JTKit's shared list: the Jamf connections
// (`jamfConnections`) and the Apple Business and Apple School Manager
// accounts (`appleBusinessConnections`) stay in their own UserDefaults keys
// and format, and their secrets in their own Keychain services (stored data:
// never rename), and are shown as one list in Settings › Connections.

/// One entry of the shared Connections list: a Jamf connection or an Apple
/// account, each kept in its saved format.
nonisolated enum AppConnection: ConnectionRecord {
    case jamf(JamfConnection)
    case apple(AppleBusinessConnection)

    static let jamfServices: Set<ConnectionService> = [.jamfPro, .jamfPlatform, .jamfSchool]
    static let appleServices: Set<ConnectionService> = [.appleBusinessManager, .appleSchoolManager]
    /// The order of the + menu.
    static let services: [ConnectionService] = [.jamfPro, .jamfPlatform, .jamfSchool,
                                                .appleBusinessManager, .appleSchoolManager]
    /// A connection switches service only within its group: a Jamf
    /// connection can't become an Apple account, which is saved in the other
    /// list under another Keychain service. Also the sections of the + menu.
    static let serviceGroups: [[ConnectionService]] = [[.jamfPro, .jamfPlatform, .jamfSchool],
                                                       [.appleBusinessManager, .appleSchoolManager]]

    var id: UUID {
        switch self {
        case .jamf(let record): record.id
        case .apple(let record): record.id
        }
    }

    var connection: Connection {
        get {
            switch self {
            case .jamf(let record): record.connection
            case .apple(let record): record.connection
            }
        }
        set {
            switch self {
            case .jamf(var record):
                record.connection = newValue
                self = .jamf(record)
            case .apple(var record):
                record.connection = newValue
                self = .apple(record)
            }
        }
    }

    var jamf: JamfConnection? {
        if case .jamf(let record) = self { record } else { nil }
    }

    var apple: AppleBusinessConnection? {
        if case .apple(let record) = self { record } else { nil }
    }

    /// One of the release check's connections under the live-check switch
    /// (JTKit's `LiveLaunch`), in the list its service belongs to.
    static func live(_ connection: Connection) -> AppConnection {
        appleServices.contains(connection.service)
            ? .apple(AppleBusinessConnection(live: connection))
            : .jamf(JamfConnection(live: connection))
    }
}

// MARK: - Storage

/// The two lists: `jamfConnections` and `appleBusinessConnections` in
/// UserDefaults, JSON-encoded in their saved format (never rename). Jamf
/// connections come first in the shared list. A list whose entries didn't
/// change is never written, so saving an Apple account leaves
/// `jamfConnections` exactly as it was, for older versions too.
@MainActor
final class AppConnectionStorage: ConnectionStorage {
    private let jamf: UserDefaultsConnectionStorage<JamfConnection>
    private let apple: UserDefaultsConnectionStorage<AppleBusinessConnection>

    init(defaults: UserDefaults) {
        jamf = UserDefaultsConnectionStorage(key: AppConnectionStore.listKey, defaults: defaults)
        apple = UserDefaultsConnectionStorage(key: AppConnectionStore.appleListKey, defaults: defaults)
    }

    func load() throws -> [AppConnection] {
        try jamf.load().map(AppConnection.jamf) + apple.load().map(AppConnection.apple)
    }

    /// Each entry goes back to its own list, in the order of the shared list.
    func save(_ records: [AppConnection]) throws {
        let jamfRecords = records.compactMap(\.jamf)
        let appleRecords = records.compactMap(\.apple)
        if (try? jamf.load()) != jamfRecords { try jamf.save(jamfRecords) }
        if (try? apple.load()) != appleRecords { try apple.save(appleRecords) }
    }

    func backUpOnce() throws {
        try jamf.backUpOnce()
        try apple.backUpOnce()
    }

    /// Copies only the list that can't be read.
    func keepUnreadableCopy() -> String? {
        var copies = [String]()
        if (try? jamf.load()) == nil, let copy = jamf.keepUnreadableCopy() { copies.append(copy) }
        if (try? apple.load()) == nil, let copy = apple.keepUnreadableCopy() { copies.append(copy) }
        return copies.isEmpty ? nil : copies.joined(separator: " and ")
    }
}

/// Each connection's secret in its own Keychain service, under the
/// connection's UUID: a Jamf connection's in the Jamf store, an Apple
/// account's private key in the Apple store. JTKit's store names an Apple
/// account `apple/<UUID>` (`account(for:)`); the prefix only picks the store.
nonisolated struct AppConnectionSecrets: SecretStore {
    let jamf: any SecretStore
    let apple: any SecretStore
    /// Told the account after every write or delete (e.g. a private key
    /// replaced in Settings), so the client using it starts again.
    var didWrite: (@Sendable (String) -> Void)?

    private static let applePrefix = "apple/"

    static func account(for connection: Connection) -> String {
        AppConnection.appleServices.contains(connection.service)
            ? applePrefix + connection.id.uuidString
            : connection.id.uuidString
    }

    private func route(_ account: String) -> (store: any SecretStore, account: String) {
        account.hasPrefix(Self.applePrefix)
            ? (apple, String(account.dropFirst(Self.applePrefix.count)))
            : (jamf, account)
    }

    func secret(for account: String) -> String? {
        let (store, account) = route(account)
        return store.secret(for: account)
    }

    @discardableResult
    func setSecret(_ secret: String?, for account: String) -> Bool {
        defer { didWrite?(account) }
        let (store, routed) = route(account)
        return store.setSecret(secret, for: routed)
    }

    // Forwarded rather than left to the protocol's defaults, so the Keychain
    // answers presence without reading the secret, and a failure keeps its
    // error code instead of reading as "no secret".
    func writeSecret(_ secret: String?, for account: String) throws {
        defer { didWrite?(account) }
        let (store, routed) = route(account)
        try store.writeSecret(secret, for: routed)
    }

    func hasSecret(for account: String) throws -> Bool {
        let (store, account) = route(account)
        return try store.hasSecret(for: account)
    }

    func readSecret(for account: String) throws -> String? {
        let (store, account) = route(account)
        return try store.readSecret(for: account)
    }
}

// MARK: - The store

/// The saved Jamf connections and Apple accounts, and the one in use of
/// each. JTKit's `ConnectionStore` keeps them as one list (`AppConnection`):
///
/// - Jamf connections under the UserDefaults key `jamfConnections`, each
///   secret in the Keychain service `be.jordythery.SerialNumberReader.jamf`
///   (account = connection UUID); the one in use under `activeJamfConnectionID`.
/// - Apple Business and Apple School Manager accounts under
///   `appleBusinessConnections`, each private key in the Keychain service
///   `be.jordythery.SerialNumberReader.appleBusiness` (account = connection
///   UUID); the one in use under `activeAppleBusinessConnectionID`.
///
/// On first launch the single settings of earlier versions become Jamf
/// connections (`LegacySettingsConversion`); those settings are only read,
/// never changed.
@Observable
final class AppConnectionStore {
    static let listKey = "jamfConnections"
    static let activeKey = "activeJamfConnectionID"
    static let appleListKey = "appleBusinessConnections"
    static let appleActiveKey = "activeAppleBusinessConnectionID"

    let connections: ConnectionStore<AppConnection>
    /// Where each connection's secret is, the same as `connections` uses,
    /// readable off the main actor: a private key is read only when the
    /// client signs in (`secretReader(for:)`).
    nonisolated let secretLocation: SecretLocation
    /// Counts the writes and deletes of secrets, so a store whose client
    /// holds a token starts again when its secret was replaced.
    let secretWrites: SecretWriteCounter
    @ObservationIgnored private let defaults: UserDefaults
    /// Whether this is the real list: the app's settings and Keychain items.
    /// Under tests its requests are refused (`TestRun.refusingSession`).
    let holdsSavedConnections: Bool

    /// The Jamf connection in use.
    var activeID: UUID? {
        didSet { defaults.set(activeID?.uuidString, forKey: Self.activeKey) }
    }

    /// The Apple account in use.
    var activeAppleID: UUID? {
        didSet { defaults.set(activeAppleID?.uuidString, forKey: Self.appleActiveKey) }
    }

    /// Why the settings of an earlier version weren't converted at this
    /// launch (e.g. the Keychain refused to read an old secret), for Settings
    /// › Connections; nil when there was nothing to convert or it worked.
    let conversionProblem: String?

    /// - Parameters:
    ///   - defaults: where the lists, the ones in use and the old settings are.
    ///   - secrets: where Jamf secrets are kept, old and new; the app's Keychain items by default.
    ///   - appleSecrets: where Apple accounts' private keys are kept. By
    ///     default the app's own Keychain service when `secrets` is a
    ///     Keychain, else `secrets` too (each under its connection's UUID), so
    ///     a store made for a test never reaches the real Keychain.
    ///   - countsAsSaved: tests only: treat this store as the saved connections.
    init(defaults: UserDefaults = .standard, secrets: any SecretStore = AppConnectionStore.jamfKeychain,
         appleSecrets: (any SecretStore)? = nil, countsAsSaved: Bool = false) {
        let appleSecrets = appleSecrets ?? (secrets is KeychainSecretStore ? Self.appleKeychain : secrets)
        self.defaults = defaults
        // Under the live-check switch JTKit's store holds only the release
        // check's connections, in memory: the saved ones are never reached.
        holdsSavedConnections = countsAsSaved || (!LiveLaunch.isSwitched
            && (defaults === UserDefaults.standard || secrets is KeychainSecretStore
                || appleSecrets is KeychainSecretStore))
        let logger = Self.logger
        // Can name connections, Keychain accounts and files: private in the system log.
        let log: (String) -> Void = { logger.error("\($0, privacy: .private)") }

        // Never under the live-check switch: the old settings and their
        // Keychain items are the real ones. Only Jamf connections are
        // converted, into their own list, before the shared list reads it.
        let conversion: LegacySettingsConversion.Outcome
        if LiveLaunch.isSwitched || defaults.object(forKey: LegacySettingsConversion.markerKey) != nil {
            conversion = .alreadyDone
        } else {
            let jamfOnly = ConnectionStore<JamfConnection>(
                storage: UserDefaultsConnectionStorage(key: Self.listKey, defaults: defaults),
                secrets: [.main: SecretLocation(store: secrets)],
                log: log
            )
            conversion = LegacySettingsConversion.run(defaults: defaults, secrets: secrets, into: jamfOnly, log: log)
        }
        if case .failed(let reason) = conversion {
            conversionProblem = LegacySettingsConversion.notice(reason)
        } else {
            conversionProblem = nil
        }

        let writes = SecretWriteCounter()
        secretWrites = writes
        let routed = AppConnectionSecrets(jamf: secrets, apple: appleSecrets, didWrite: { _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { writes.count += 1 }
            } else {
                Task { @MainActor in writes.count += 1 }
            }
        })
        let location = SecretLocation(store: routed, account: AppConnectionSecrets.account(for:))
        connections = ConnectionStore(
            storage: AppConnectionStorage(defaults: defaults),
            secrets: [.main: location],
            log: log,
            liveRecord: AppConnection.live
        )
        // The same choice JTKit's store makes: under the live-check switch
        // the run's own secrets, by connection ID.
        secretLocation = LiveLaunch.isSwitched ? SecretLocation(store: LiveLaunch.secrets(for: .main)) : location

        let jamfIDs = connections.records.compactMap(\.jamf).map(\.id)
        let appleIDs = connections.records.compactMap(\.apple).map(\.id)
        activeID = Self.restoredChoice(defaults: defaults, key: Self.activeKey, among: jamfIDs,
                                       fallback: conversion.activeID ?? jamfIDs.first)
        activeAppleID = Self.restoredChoice(defaults: defaults, key: Self.appleActiveKey, among: appleIDs,
                                            fallback: appleIDs.first)
    }

    /// The saved choice while it is in the list, else the fallback, which is
    /// saved. Never cleared here: while the list can't be read, the saved
    /// choice must survive. (didSet doesn't run in init.)
    private static func restoredChoice(defaults: UserDefaults, key: String, among ids: [UUID], fallback: UUID?) -> UUID? {
        let stored = defaults.string(forKey: key).flatMap(UUID.init)
        if let stored, ids.contains(stored) { return stored }
        if let fallback, fallback != stored {
            defaults.set(fallback.uuidString, forKey: key)
        }
        return fallback
    }

    /// Secrets of earlier versions and of saved Jamf connections share this service.
    nonisolated static let jamfKeychain = KeychainSecretStore(
        service: "be.jordythery.SerialNumberReader.jamf",
        log: { logger.error("\($0, privacy: .private)") }
    )

    /// The private keys of the saved Apple accounts: a service of their own,
    /// apart from the Jamf secrets.
    nonisolated static let appleKeychain = KeychainSecretStore(
        service: "be.jordythery.SerialNumberReader.appleBusiness",
        log: { logger.error("\($0, privacy: .private)") }
    )

    private nonisolated static let logger = Logger(subsystem: "be.jordythery.SerialNumberReader", category: "Connections")

    /// The store for the app while it hosts unit tests: an empty, throwaway
    /// settings domain and no Keychain, so running the tests never converts
    /// or changes the real settings and Keychain items.
    static let unitTestHostDomain = "be.jordythery.SerialNumberReader.unit-test-host"

    static func forUnitTestHost() -> AppConnectionStore {
        AppConnectionStore(defaults: emptiedDefaults(domain: unitTestHostDomain), secrets: NoSecrets(), appleSecrets: NoSecrets())
    }

    /// A throwaway settings domain, emptied before anything reads it.
    static func emptiedDefaults(domain: String) -> UserDefaults {
        // Never the real settings instead: the unit-test host would change them.
        guard let defaults = UserDefaults(suiteName: domain) else {
            preconditionFailure("No settings domain \(domain).")
        }
        defaults.removePersistentDomain(forName: domain)
        return defaults
    }

    private nonisolated struct NoSecrets: SecretStore {
        func secret(for account: String) -> String? { nil }
        func setSecret(_ secret: String?, for account: String) -> Bool { secret == nil }
    }

    // MARK: Jamf

    var jamfConnections: [JamfConnection] { connections.records.compactMap(\.jamf) }

    var activeConnection: JamfConnection? {
        activeID.flatMap { id in jamfConnections.first { $0.id == id } }
    }

    /// The stored secret, or nil when there is none.
    /// - Throws: when the Keychain can't be read (refused, locked): show
    ///   that, not "no connection".
    func readSecret(for record: JamfConnection) throws -> String? {
        try connections.readSecret(for: record.connection)
    }

    // MARK: Apple

    var appleConnections: [AppleBusinessConnection] { connections.records.compactMap(\.apple) }

    var activeAppleConnection: AppleBusinessConnection? {
        activeAppleID.flatMap { id in appleConnections.first { $0.id == id } }
    }

    /// Whether a private key is stored, asking the Keychain for the item's
    /// attributes only, never the key.
    /// - Throws: when the Keychain can't tell (refused, locked).
    func hasSecret(for record: AppleBusinessConnection) throws -> Bool {
        try connections.hasSecret(for: record.connection)
    }

    /// Reads a connection's secret from the Keychain each time it is
    /// called, for a client's sign-in; nothing is kept in between.
    /// - Throws: `MissingSecretError` when none is stored, or the Keychain's error.
    nonisolated func secretReader(for connection: Connection) -> @Sendable () throws -> String {
        let location = secretLocation
        return {
            guard let secret = try location.store.readSecret(for: location.account(connection)), !secret.isEmpty else {
                throw MissingSecretError(connection: connection.name, secretName: connection.signIn.secretName ?? "secret")
            }
            return secret
        }
    }

    // MARK: Settings

    /// A new connection for + in Settings › Connections. The first of its
    /// kind becomes the one in use.
    func newConnection(service: ConnectionService) -> AppConnection {
        if AppConnection.appleServices.contains(service) {
            let record = AppleBusinessConnection(name: "New Account", service: service, signIn: service.signInMethods[0])
            if activeAppleConnection == nil { activeAppleID = record.id }
            return .apple(record)
        }
        let record = JamfConnection(name: "New Connection", service: service, signIn: service.signInMethods[0])
        if activeConnection == nil { activeID = record.id }
        return .jamf(record)
    }

    /// After a connection was deleted in Settings: when it was the one in
    /// use, the first remaining one of its kind takes its place.
    func connectionWasDeleted() {
        if activeConnection == nil { activeID = jamfConnections.first?.id }
        if activeAppleConnection == nil { activeAppleID = appleConnections.first?.id }
    }
}

/// How many times a secret was written or deleted since launch.
@Observable
final class SecretWriteCounter {
    var count = 0
}
