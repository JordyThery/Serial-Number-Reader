import Foundation
import JTKit
import Observation
import os
import SwiftUI

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

/// Owns the active Jamf connection's API client and per-device lookup
/// results. The saved connections are in `connections`.
///
/// In demo mode the connection in use is one of JTKit's demo connections
/// ("Contoso Jamf Pro (Demo)" or "Contoso Academy (Demo)", in `demoChoice`),
/// answered by JTKit's demo servers inside the app; the saved connections and
/// the one in use stay as they are. Test Connection always uses the real
/// connection and the real network.
@MainActor
@Observable
final class JamfStore {

    let connections: JamfConnectionStore
    /// JTKit's activity log (Window › Activity Log), filled by every request.
    let activityLog: ActivityLog

    /// The active connection with its secret; nil when it is incomplete.
    private(set) var configuration: JamfConfiguration?

    private(set) var lookupStates: [JamfQuery: JamfLookupState] = [:]
    /// Bumped whenever the configuration changes; the UI observes it to re-run
    /// lookups, and in-flight results from an older generation are discarded
    /// instead of being cached against the new server.
    private(set) var configurationGeneration = 0

    /// Demo mode's connections; nil without demo mode.
    let demoChoice: DemoConnectionChoice?

    @ObservationIgnored private var client: JamfService?
    /// The connection (ID and name) the client is for: the log names it.
    @ObservationIgnored private var clientKey: String?
    /// The demo connection in use when the lookups were last reset.
    @ObservationIgnored private var demoConnectionID: UUID?
    @ObservationIgnored private var inFlight: Set<JamfQuery> = []
    @ObservationIgnored private let session: URLSession
    private let logger = Logger(subsystem: "be.jordythery.SerialNumberReader", category: "JamfStore")

    /// - Parameters:
    ///   - connections: the saved connections; the app's own by default.
    ///   - session: sends the requests; a fake server in tests.
    ///   - activityLog: where requests are recorded; a new log by default.
    ///   - demo: the app's demo mode; nil without demo mode.
    init(connections: JamfConnectionStore? = nil, activityLog: ActivityLog? = nil,
         session: URLSession = JamfStore.session, demo: DemoMode? = nil) {
        let connections = connections ?? JamfConnectionStore()
        self.connections = connections
        self.activityLog = activityLog ?? ActivityLog()
        // Under tests the saved connections are never reached: every request
        // for them, sign-in and Test Connection included, is refused and
        // written down for the release check (demo connections are unaffected).
        self.session = UnderTest.isActive && connections.holdsSavedConnections
            ? SavedConnectionGuard.refusingSession() : session
        demoChoice = demo.map { DemoConnectionChoice(mode: $0, connections: [.demoJamfPro, .demoJamfSchool]) }
        configuration = activeConfiguration()
        demoConnectionID = demoConnection?.id
        observeConnections()
    }

    /// The picker's, the Connection menu's and Settings' role: the saved
    /// connection in use, or in demo mode the demo connections.
    func connectionRole(selection: Binding<UUID?>) -> ConnectionRole {
        .active(selection: selection, demo: demoChoice)
    }

    /// The demo connection in use while demo mode is on, else nil.
    var demoConnection: Connection? {
        guard let demoChoice, demoChoice.isActive else { return nil }
        return demoChoice.selected
    }

    /// No cookies or cache kept between requests; 30 s per request.
    nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    /// Sends and records the requests of one connection, named in the log.
    private func recorder(for record: JamfConnection) -> RequestRecorder {
        RequestRecorder(session: session, log: activityLog, service: record.service.displayName,
                        connection: record.name)
    }

    /// Builds the client configuration for a connection and its secret, or
    /// nil when incomplete or invalid.
    nonisolated static func configuration(for record: JamfConnection, secret: String) -> JamfConfiguration? {
        let credentials: JamfCredentials
        let url: String
        switch record.service {
        case .jamfPro:
            credentials = record.signIn == .usernamePassword
                ? .basic(username: record.username, password: secret)
                : .clientCredentials(clientID: record.clientID, clientSecret: secret)
            url = record.serverURL
        case .jamfPlatform:
            credentials = .platform(
                region: record.region,
                clientID: record.clientID.trimmingCharacters(in: .whitespacesAndNewlines),
                clientSecret: secret,
                environmentID: record.environmentID.trimmingCharacters(in: .whitespacesAndNewlines))
            url = record.jamfProWebURL
        case .jamfSchool:
            credentials = .jamfSchool(
                networkID: record.clientID.trimmingCharacters(in: .whitespacesAndNewlines),
                apiKey: secret.trimmingCharacters(in: .whitespacesAndNewlines))
            url = record.serverURL
        case .intune, .appleBusinessManager, .appleSchoolManager:
            return nil
        }
        return JamfConfiguration.make(urlString: url, credentials: credentials)
    }

    /// "Jamf Pro" or "Jamf School", for section titles and messages.
    var productName: String {
        let service = demoConnection?.service ?? connections.activeConnection?.service
        return service == .jamfSchool ? "Jamf School" : "Jamf Pro"
    }

    var isConfigured: Bool { demoConnection != nil || configuration != nil }

    /// Base URL for "Open in Jamf Pro" links; nil when unknown (Platform API
    /// without the optional Jamf Pro URL), and in demo mode: the demo
    /// servers have no web pages.
    var webBaseURL: URL? { demoConnection == nil ? configuration?.webBaseURL : nil }

    private func activeConfiguration() -> JamfConfiguration? {
        guard let record = connections.activeConnection else { return nil }
        return Self.configuration(for: record, secret: connections.secret(for: record) ?? "")
    }

    /// Follows the connection in use: switching to another one, or saving
    /// it in Settings (the list is saved with every change, secrets included).
    private func observeConnections() {
        withObservationTracking {
            _ = connections.activeConnection
            _ = demoConnection
        } onChange: { [weak self] in
            // Called before the change: read the new values afterwards.
            Task { @MainActor [weak self] in
                self?.connectionsChanged()
                self?.observeConnections()
            }
        }
    }

    private func connectionsChanged() {
        let updated = activeConfiguration()
        let demoID = demoConnection?.id
        guard updated != configuration || demoID != demoConnectionID else { return }
        configuration = updated
        demoConnectionID = demoID
        invalidateClient()
    }

    private func invalidateClient() {
        client = nil
        // Drop cached results (they may belong to a different server) and
        // signal observers to re-run.
        lookupStates.removeAll()
        configurationGeneration += 1
    }

    /// The client of the connection in use; nil when there is none.
    /// - Throws: why JTKit can't make one, e.g. an address that isn't HTTPS.
    private func activeClient() throws -> JamfService? {
        if let demo = demoConnection {
            // Demo mode: JTKit's demo server, its fake secret and its private network.
            let key = "demo \(demo.id)"
            if let client, clientKey == key { return client }
            guard let source = demoChoice?.mode.source(for: demo) else { return nil }
            let recorder = RequestRecorder(session: source.session, log: activityLog,
                                           service: demo.service.displayName, connection: demo.name)
            let newClient = try JamfService(demo: source, recorder: recorder)
            client = newClient
            clientKey = key
            return newClient
        }
        let record = connections.activeConnection
        // A renamed connection gets a new client, so the log shows the new name.
        let key = record.map { "\($0.id) \($0.name)" }
        if let client, clientKey == key { return client }
        guard let configuration, let record else { return nil }
        let newClient = try JamfService(configuration: configuration, recorder: recorder(for: record))
        client = newClient
        clientKey = key
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
        let client: JamfService
        do {
            guard let active = try activeClient() else { return }
            client = active
        } catch {
            lookupStates[query] = .failed(error.localizedDescription)
            return
        }
        guard !inFlight.contains(query) else { return }
        inFlight.insert(query)
        lookupStates[query] = .loading
        let generation = configurationGeneration

        Task {
            let state: JamfLookupState
            do {
                switch try await client.lookup(query) {
                case .found(let record): state = .found(record)
                case .noMatch: state = .noMatch
                case .multipleMatches(let count): state = .multipleMatches(count)
                }
            } catch {
                // JTKit's message (status, Jamf's error, Trace ID, hints). It
                // can hold the server's answer: private in the system log.
                logger.error("Jamf lookup failed: \(error.localizedDescription, privacy: .private)")
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

    /// Writes a new asset tag to Jamf Pro or Jamf School and updates the
    /// cached record. Returns nil on success, or the message to show.
    func saveAssetTag(_ tag: String, record: JamfDeviceRecord, for device: USBDevice) async -> String? {
        let active: JamfService?
        do {
            active = try activeClient()
        } catch {
            return error.localizedDescription
        }
        guard let query = device.jamfQuery, let client = active else {
            return "\(productName) is not configured."
        }
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        let generation = configurationGeneration
        do {
            try await client.updateAssetTag(trimmed, record: record)
            // Show what Jamf stored, not what was typed: read the record back.
            // If that read fails, the saved value is shown as typed.
            var updated = record
            updated.assetTag = trimmed.isEmpty ? nil : trimmed
            if case .found(let stored)? = try? await client.lookup(query), stored.jamfID == record.jamfID {
                updated = stored
            }
            // Saved on the server that was in use; if the connection changed
            // meanwhile, its result doesn't belong in the new server's list.
            if generation == configurationGeneration {
                lookupStates[query] = .found(updated)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Test Connection in Settings, with the editor's values, saved or not.
    /// A secret typed in the editor is used instead of the stored one.
    /// Always the real connection and the real network, also in demo mode.
    func testConnection(_ record: JamfConnection, typedSecret: String?) async throws -> String {
        let secret = typedSecret ?? connections.secret(for: record) ?? ""
        guard let configuration = Self.configuration(for: record, secret: secret) else {
            let missing = switch record.service {
            case .jamfPlatform: "Fill in the client ID, client secret and a valid environment ID first"
            case .jamfSchool: "Fill in the Jamf School URL, Network ID and API key first"
            default: "Fill in the server URL and credentials first"
            }
            throw JamfSetupError(message: missing)
        }
        try await JamfService(configuration: configuration, recorder: recorder(for: record)).testConnection()
        return "Authenticated successfully"
    }
}
