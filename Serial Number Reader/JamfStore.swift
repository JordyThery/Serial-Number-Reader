import Foundation
import Observation
import os

/// Lookup state for one device, keyed by its Jamf query.
nonisolated enum JamfLookupState: Equatable, Sendable {
    /// Jamf settings are incomplete.
    case notConfigured
    /// This device exposes nothing Jamf can be queried with (e.g. DFU mode).
    case unavailable(String)
    case loading
    case found(JamfDeviceRecord)
    case noMatch
    case multipleMatches(Int)
    case failed(String)
}

/// Owns the Jamf settings (URL + client ID in UserDefaults, secret in the
/// Keychain), the API client, and per-device lookup results.
@MainActor
@Observable
final class JamfStore {

    /// How to authenticate. Raw values are persisted in UserDefaults.
    enum AuthMethod: String, CaseIterable, Identifiable {
        case clientCredentials
        case basic

        var id: Self { self }
        var label: String {
            switch self {
            case .clientCredentials: "API Client (OAuth)"
            case .basic: "Username & Password (Classic)"
            }
        }
    }

    private enum DefaultsKey {
        static let serverURL = "jamfServerURL"
        static let clientID = "jamfClientID"
        static let username = "jamfUsername"
        static let authMethod = "jamfAuthMethod"
    }

    var serverURLString: String {
        didSet {
            UserDefaults.standard.set(serverURLString, forKey: DefaultsKey.serverURL)
            invalidateClient()
        }
    }

    var authMethod: AuthMethod {
        didSet {
            UserDefaults.standard.set(authMethod.rawValue, forKey: DefaultsKey.authMethod)
            invalidateClient()
        }
    }

    var clientID: String {
        didSet {
            UserDefaults.standard.set(clientID, forKey: DefaultsKey.clientID)
            invalidateClient()
        }
    }

    /// Backed by the Keychain — never stored in UserDefaults.
    var clientSecret: String {
        didSet {
            KeychainStore.save(clientSecret, account: .clientSecret)
            invalidateClient()
        }
    }

    var username: String {
        didSet {
            UserDefaults.standard.set(username, forKey: DefaultsKey.username)
            invalidateClient()
        }
    }

    /// Backed by the Keychain — never stored in UserDefaults.
    var password: String {
        didSet {
            KeychainStore.save(password, account: .password)
            invalidateClient()
        }
    }

    private(set) var lookupStates: [JamfQuery: JamfLookupState] = [:]
    /// Bumped (debounced) whenever the configuration changes; the UI observes
    /// it to re-run lookups, and in-flight results from an older generation
    /// are discarded instead of being cached against the new server.
    private(set) var configurationGeneration = 0

    @ObservationIgnored private var client: JamfClient?
    @ObservationIgnored private var inFlight: Set<JamfQuery> = []
    @ObservationIgnored private var invalidationTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "be.jordythery.SerialNumberReader", category: "JamfStore")

    init() {
        serverURLString = UserDefaults.standard.string(forKey: DefaultsKey.serverURL) ?? ""
        authMethod = UserDefaults.standard.string(forKey: DefaultsKey.authMethod)
            .flatMap(AuthMethod.init(rawValue:)) ?? .clientCredentials
        clientID = UserDefaults.standard.string(forKey: DefaultsKey.clientID) ?? ""
        clientSecret = KeychainStore.load(account: .clientSecret) ?? ""
        username = UserDefaults.standard.string(forKey: DefaultsKey.username) ?? ""
        password = KeychainStore.load(account: .password) ?? ""
    }

    var configuration: JamfConfiguration? {
        let credentials: JamfCredentials = switch authMethod {
        case .clientCredentials: .clientCredentials(clientID: clientID, clientSecret: clientSecret)
        case .basic: .basic(username: username, password: password)
        }
        return JamfConfiguration.make(urlString: serverURLString, credentials: credentials)
    }

    var isConfigured: Bool { configuration != nil }

    /// Base URL for "Open in Jamf Pro" links.
    var baseURL: URL? { configuration?.baseURL }

    private func invalidateClient() {
        client = nil
        // Debounced: typing in Settings changes the configuration on every
        // keystroke. Once the user pauses, drop cached results (they may
        // belong to a different server) and signal observers to re-run.
        invalidationTask?.cancel()
        invalidationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self, !Task.isCancelled else { return }
            self.lookupStates.removeAll()
            self.configurationGeneration += 1
        }
    }

    private func activeClient() -> JamfClient? {
        if let client { return client }
        guard let configuration else { return nil }
        let newClient = JamfClient(config: configuration)
        client = newClient
        return newClient
    }

    // MARK: - Lookups

    func state(for device: USBDevice) -> JamfLookupState {
        guard let query = device.jamfQuery else {
            switch device.mode {
            case .dfu:
                return .unavailable("No lookup possible in DFU mode")
            case .recovery:
                return .unavailable("No serial number to look up")
            case .normal:
                return .unavailable("No UDID reported by the device")
            }
        }
        guard isConfigured else { return .notConfigured }
        return lookupStates[query] ?? .loading
    }

    /// Starts a lookup for the device unless one already ran or is running.
    func lookupIfNeeded(for device: USBDevice) {
        guard let query = device.jamfQuery, lookupStates[query] == nil else { return }
        performLookup(query)
    }

    /// Re-runs the lookup, discarding any cached result.
    func refresh(for device: USBDevice) {
        guard let query = device.jamfQuery else { return }
        lookupStates[query] = nil
        performLookup(query)
    }

    private func performLookup(_ query: JamfQuery) {
        guard let client = activeClient() else { return }
        guard !inFlight.contains(query) else { return }
        inFlight.insert(query)
        lookupStates[query] = .loading
        let generation = configurationGeneration

        Task {
            let state: JamfLookupState
            do {
                state = .found(try await client.lookup(query))
            } catch JamfError.noMatch {
                state = .noMatch
            } catch JamfError.multipleMatches(let count) {
                state = .multipleMatches(count)
            } catch let error as JamfError {
                logger.error("Jamf lookup failed: \(error.localizedDescription, privacy: .public)")
                state = .failed(error.localizedDescription)
            } catch {
                state = .failed(error.localizedDescription)
            }
            inFlight.remove(query)
            if generation == configurationGeneration {
                lookupStates[query] = state
            } else if lookupStates[query] == nil {
                // The configuration changed mid-flight: discard this result
                // and look up again against the current server.
                performLookup(query)
            }
        }
    }

    /// Writes a new asset tag to Jamf Pro and updates the cached record.
    /// Returns nil on success, or the error to show.
    func saveAssetTag(_ tag: String, record: JamfDeviceRecord, for device: USBDevice) async -> JamfError? {
        guard let query = device.jamfQuery, let client = activeClient() else {
            return .authenticationFailed("Jamf Pro is not configured")
        }
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await client.updateAssetTag(trimmed, kind: record.kind, jamfID: record.jamfID)
            var updated = record
            updated.assetTag = trimmed.isEmpty ? nil : trimmed
            lookupStates[query] = .found(updated)
            return nil
        } catch let error as JamfError {
            return error
        } catch {
            return .networkFailure(error.localizedDescription)
        }
    }

    /// Validates the current credentials by requesting a fresh token.
    func testConnection() async -> Result<Void, JamfError> {
        guard let configuration else {
            return .failure(.authenticationFailed("Fill in the server URL and credentials first"))
        }
        do {
            try await JamfClient(config: configuration).testConnection()
            return .success(())
        } catch let error as JamfError {
            return .failure(error)
        } catch {
            return .failure(.networkFailure(error.localizedDescription))
        }
    }
}
