import Foundation
import JTKit

/// The one-time conversion of the single Jamf settings of earlier versions
/// (one set per sign-in method, chosen with `jamfAuthMethod`) into saved
/// connections.
///
/// Safety rules:
/// - The old UserDefaults keys and Keychain items are only read, never
///   changed or deleted, so an older build keeps working.
/// - It runs once: `jamfConnectionsConverted` is set after the connections
///   were saved, and the old settings are not read again after that.
/// - It only adds. Each sign-in method converts to a fixed ID, so a run that
///   stopped halfway is completed without duplicates; a list that already
///   holds other connections is left alone.
nonisolated enum LegacySettingsConversion {
    static let markerKey = "jamfConnectionsConverted"

    /// The old settings, as earlier versions saved them.
    enum OldKey {
        static let authMethod = "jamfAuthMethod"
        static let serverURL = "jamfServerURL"
        static let clientID = "jamfClientID"
        static let username = "jamfUsername"
        static let platformRegion = "jamfPlatformRegion"
        static let platformClientID = "jamfPlatformClientID"
        static let platformEnvironmentID = "jamfPlatformEnvironmentID"
        static let schoolURL = "jamfSchoolURL"
        static let schoolNetworkID = "jamfSchoolNetworkID"
    }

    /// The old sign-in methods; the raw values are those of `jamfAuthMethod`.
    enum Method: String, CaseIterable, Sendable {
        case clientCredentials
        case basic
        case platform
        case jamfSchool

        /// The ID of the connection this method becomes. Never change these:
        /// they prevent duplicates when the conversion runs again.
        var connectionID: UUID {
            switch self {
            case .clientCredentials: UUID(uuidString: "CF555983-297E-458B-8572-8F874A2FD71C")!
            case .basic: UUID(uuidString: "A29DDBC2-183A-41FD-AFEE-EBDBF77886AA")!
            case .platform: UUID(uuidString: "E0D1C613-3425-4642-B398-97A90CB12FFA")!
            case .jamfSchool: UUID(uuidString: "03C8A571-7343-468C-9CE2-EDF790B5B52C")!
            }
        }

        /// The old Keychain account of its secret.
        var secretAccount: String {
            switch self {
            case .clientCredentials: "clientSecret"
            case .basic: "jamfPassword"
            case .platform: "jamfPlatformClientSecret"
            case .jamfSchool: "jamfSchoolAPIKey"
            }
        }

        /// Settings that belong to this method alone.
        var ownKeys: [String] {
            switch self {
            case .clientCredentials: [OldKey.clientID]
            case .basic: [OldKey.username]
            case .platform: [OldKey.platformClientID, OldKey.platformEnvironmentID]
            case .jamfSchool: [OldKey.schoolURL, OldKey.schoolNetworkID]
            }
        }

        /// Settings shared with another method: they count as filled in only
        /// for the method in use, so an address alone doesn't create two
        /// half-empty Jamf Pro connections.
        var sharedKeys: [String] {
            switch self {
            case .clientCredentials, .basic, .platform: [OldKey.serverURL]
            case .jamfSchool: []
            }
        }
    }

    /// A connection to create and the secret to copy to it.
    struct Item: Equatable, Sendable {
        var record: JamfConnection
        var secret: String?
    }

    /// What the old settings convert to.
    struct Plan: Equatable, Sendable {
        var items: [Item]
        var activeID: UUID?
    }

    enum Outcome: Equatable, Sendable {
        /// The marker was set by an earlier run; nothing was read.
        case alreadyDone
        /// The list already held other connections; nothing was added.
        case skippedExistingList
        case converted(added: Int, activeID: UUID?)
        /// Nothing more was saved and the marker is not set: it runs again at the next launch.
        case failed(String)

        var activeID: UUID? {
            if case .converted(_, let activeID) = self { return activeID }
            return nil
        }
    }

    /// The connections the old settings describe, without saving anything.
    /// Each method with its own setting or its secret filled in becomes one,
    /// and so does the method in use when any of its settings is filled in.
    /// That one becomes active, or else the first one.
    static func plan(defaults: UserDefaults, secrets: any SecretStore) -> Plan {
        func value(_ key: String) -> String {
            defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let inUse = defaults.string(forKey: OldKey.authMethod).flatMap(Method.init) ?? .clientCredentials

        var items = [Item]()
        for method in Method.allCases {
            let secret = secrets.secret(for: method.secretAccount).flatMap { $0.isEmpty ? nil : $0 }
            let keys = method == inUse ? method.ownKeys + method.sharedKeys : method.ownKeys
            guard secret != nil || keys.contains(where: { !value($0).isEmpty }) else { continue }
            items.append(Item(record: record(for: method, value: value), secret: secret))
        }
        let activeID = items.first { $0.record.id == inUse.connectionID }?.record.id ?? items.first?.record.id
        return Plan(items: items, activeID: activeID)
    }

    /// Converts the old settings unless that was done before. Returns what happened.
    @MainActor
    static func run(defaults: UserDefaults, secrets: any SecretStore,
                    into store: ConnectionStore<JamfConnection>,
                    log: (String) -> Void = { _ in }) -> Outcome {
        guard defaults.object(forKey: markerKey) == nil else { return .alreadyDone }
        if let problem = store.problem {
            log("[Conversion] not run: \(problem.localizedDescription)")
            return .failed(problem.localizedDescription)
        }
        let convertedIDs = Set(Method.allCases.map(\.connectionID))
        if store.records.contains(where: { !convertedIDs.contains($0.id) }) {
            defaults.set(true, forKey: markerKey)
            log("[Conversion] skipped: the list already holds connections")
            return .skippedExistingList
        }

        let plan = plan(defaults: defaults, secrets: secrets)
        var added = 0
        // Converted earlier by a run that stopped halfway: already complete,
        // as a record is saved only after its secret.
        for item in plan.items where store.record(id: item.record.id) == nil {
            var newSecrets = [ConnectionSecretKind: String]()
            if let secret = item.secret, store.secret(for: item.record.connection) == nil {
                newSecrets[.main] = secret
            }
            do {
                try store.save(item.record, secrets: newSecrets)
                added += 1
            } catch {
                log("[Conversion] stopped at \(item.record.name): \(error.localizedDescription)")
                return .failed(error.localizedDescription)
            }
        }
        defaults.set(true, forKey: markerKey)
        log("[Conversion] done: \(added) connection(s) added")
        return .converted(added: added, activeID: plan.activeID)
    }

    private static func record(for method: Method, value: (String) -> String) -> JamfConnection {
        let id = method.connectionID
        switch method {
        case .clientCredentials:
            return JamfConnection(id: id, name: "Jamf Pro (API client)", service: .jamfPro, signIn: .apiClient,
                                  serverURL: address(value(OldKey.serverURL)), clientID: value(OldKey.clientID))
        case .basic:
            return JamfConnection(id: id, name: "Jamf Pro (username and password)", service: .jamfPro,
                                  signIn: .usernamePassword, serverURL: address(value(OldKey.serverURL)),
                                  username: value(OldKey.username))
        case .platform:
            // Europe was the old default when the region was never changed.
            return JamfConnection(id: id, name: "Jamf Platform API", service: .jamfPlatform, signIn: .apiClient,
                                  region: JamfRegion(rawValue: value(OldKey.platformRegion)) ?? .eu,
                                  environmentID: value(OldKey.platformEnvironmentID),
                                  jamfProWebURL: address(value(OldKey.serverURL)),
                                  clientID: value(OldKey.platformClientID))
        case .jamfSchool:
            return JamfConnection(id: id, name: "Jamf School", service: .jamfSchool, signIn: .schoolAPIKey,
                                  serverURL: address(value(OldKey.schoolURL)), clientID: value(OldKey.schoolNetworkID))
        }
    }

    /// Earlier versions accepted `yourorg.jamfcloud.com`; the shared editor
    /// only saves addresses starting with https://, so add it.
    private static func address(_ string: String) -> String {
        JamfConfiguration.normalizedURL(string)?.absoluteString ?? string
    }
}
