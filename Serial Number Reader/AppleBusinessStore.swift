import Foundation
import JTKit
import Observation
import os

/// What Apple Business or Apple School Manager knows about one device.
nonisolated struct AppleBusinessRecord: Equatable, Sendable {
    var device: ABM.OrgDevice
    /// The device management service the device is assigned to; nil when it
    /// has none.
    var mdmServerName: String?
    var coverage: [ABM.AppleCareCoverage]
    /// Why the coverage isn't shown, when only that request failed.
    var coverageProblem: String?
}

/// Lookup state for one serial number.
nonisolated enum AppleBusinessLookupState: Equatable, Sendable {
    /// No account in use, or the one in use is incomplete.
    case notConfigured
    /// There is no serial number to look up (yet).
    case unavailable(String)
    case loading
    case found(AppleBusinessRecord)
    /// The device isn't in the organization (never added, or released).
    case notInOrganization
    case failed(String)
}

/// Owns the active Apple Business or Apple School Manager client and the
/// per-serial lookup results, like `JamfStore` does for Jamf. The feature is
/// optional: without a saved account the detail view shows nothing.
///
/// In demo mode the account is JTKit's "Contoso (Demo)" organization,
/// answered inside the app; the saved accounts are never used. Test
/// Connection always uses the real account and the real network.
@MainActor
@Observable
final class AppleBusinessStore {

    let connections: AppleBusinessConnectionStore
    /// JTKit's activity log (Window › Activity Log), filled by every request.
    let activityLog: ActivityLog

    /// The active account with its private key; nil when it is incomplete.
    private(set) var configuration: Configuration?
    /// Why the account in use can't be used although it is filled in (the
    /// Keychain can't be read).
    private(set) var connectionProblem: String?

    private(set) var lookupStates: [String: AppleBusinessLookupState] = [:]
    /// Bumped whenever the account changes; the UI looks up again.
    private(set) var configurationGeneration = 0

    /// A saved account and its private key.
    struct Configuration: Equatable, Sendable {
        let connection: Connection
        let privateKey: String
    }

    @ObservationIgnored private let demo: DemoMode?
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var client: ABM.Client?
    @ObservationIgnored private var clientKey: String?
    /// The organization's device management services by ID, read once per client.
    @ObservationIgnored private var serverNames: [String: String]?
    @ObservationIgnored private var inFlight: Set<String> = []
    private let logger = Logger(subsystem: "be.jordythery.SerialNumberReader", category: "AppleBusinessStore")

    /// - Parameters:
    ///   - connections: the saved accounts; the app's own by default.
    ///   - activityLog: where requests are recorded; a new log by default.
    ///   - session: sends the requests; a fake server in tests.
    ///   - demo: the app's demo mode; nil without demo mode.
    init(connections: AppleBusinessConnectionStore? = nil, activityLog: ActivityLog? = nil,
         session: URLSession = JamfStore.session, demo: DemoMode? = nil) {
        let connections = connections ?? AppleBusinessConnectionStore()
        self.connections = connections
        self.activityLog = activityLog ?? ActivityLog()
        self.demo = demo
        // Under tests the saved accounts are never reached: every request
        // for them is refused and written down (demo requests are unaffected).
        self.session = TestRun.isActive && connections.holdsSavedConnections
            ? TestRun.refusingSession(log: .savedConnections, message: UnderTest.refusal) : session
        (configuration, connectionProblem) = activeSetup()
        observeConnections()
    }

    /// The saved account in use, or in demo mode the demo organization.
    var isDemo: Bool { demo?.isOn == true }

    /// Whether the section is shown at all: an account is in use (or the
    /// problem with it is). Demo mode always has one.
    var isConfigured: Bool { isDemo || configuration != nil || connectionProblem != nil }

    /// "Apple Business" or "Apple School Manager", for the section title.
    var productName: String {
        if isDemo { return ABM.Service.business.label }
        return connections.activeConnection.flatMap { ABM.Service($0.service) }?.label ?? ABM.Service.business.label
    }

    /// The web portal of the account in use, for "Open in Apple Business
    /// Manager" / "Open in Apple School Manager"; nil in demo mode (the demo
    /// organization has no web pages) and without an account. Apple documents
    /// no address for a single device, so the link opens the portal itself.
    var portalURL: URL? {
        guard !isDemo, let service = connections.activeConnection.flatMap({ ABM.Service($0.service) }) else { return nil }
        return Self.portalURL(for: service)
    }

    /// "Apple Business Manager" or "Apple School Manager", for the link's name.
    var portalName: String {
        connections.activeConnection?.service == .appleSchoolManager ? "Apple School Manager" : "Apple Business Manager"
    }

    nonisolated static func portalURL(for service: ABM.Service) -> URL {
        switch service {
        case .business: URL(string: "https://business.apple.com")!
        case .school: URL(string: "https://school.apple.com")!
        }
    }

    /// A configuration for an account and its private key, or nil when it is
    /// incomplete or not an Apple service.
    nonisolated static func configuration(for record: AppleBusinessConnection, privateKey: String) -> Configuration? {
        guard ABM.Service(record.service) != nil,
              !record.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !record.keyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Configuration(connection: record.connection, privateKey: privateKey)
    }

    private func activeSetup() -> (Configuration?, problem: String?) {
        guard let record = connections.activeConnection else { return (nil, nil) }
        do {
            return (Self.configuration(for: record, privateKey: try connections.readSecret(for: record) ?? ""), nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    private func observeConnections() {
        withObservationTracking {
            _ = connections.activeConnection
            _ = demo?.isOn
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.connectionsChanged()
                self?.observeConnections()
            }
        }
    }

    private func connectionsChanged() {
        let (updated, problem) = activeSetup()
        let demoKey = clientKeyForDemo
        guard updated != configuration || problem != connectionProblem || demoKey != lastDemoKey else { return }
        configuration = updated
        connectionProblem = problem
        lastDemoKey = demoKey
        client = nil
        clientKey = nil
        serverNames = nil
        lookupStates.removeAll()
        configurationGeneration += 1
    }

    @ObservationIgnored private var lastDemoKey: String?
    private var clientKeyForDemo: String? { isDemo ? "demo" : nil }

    // MARK: - Client

    /// The client of the account in use; nil when there is none.
    private func activeClient() throws -> ABM.Client? {
        if isDemo {
            guard let demo, let source = demo.source(for: .demoAppleBusiness) else { return nil }
            if let client, clientKey == "demo" { return client }
            let newClient = try ABM.Client(connection: source.connection, privateKey: source.secret,
                                           session: source.session, log: activityLog)
            client = newClient
            clientKey = "demo"
            serverNames = nil
            return newClient
        }
        guard let configuration else { return nil }
        let key = "\(configuration.connection.id) \(configuration.connection.name)"
        if let client, clientKey == key { return client }
        let newClient = try Self.makeClient(configuration, session: session, log: activityLog)
        client = newClient
        clientKey = key
        serverNames = nil
        return newClient
    }

    nonisolated static func makeClient(_ configuration: Configuration, session: URLSession,
                                       log: ActivityLog?) throws -> ABM.Client {
        let key = configuration.privateKey
        return try ABM.Client(connection: configuration.connection, privateKey: { key }, session: session, log: log)
    }

    // MARK: - Lookups

    /// A serial number the way lookups and results are keyed.
    nonisolated static func normalized(_ serial: String?) -> String? {
        guard let serial = serial?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), !serial.isEmpty else { return nil }
        return serial
    }

    func state(forSerial serial: String?) -> AppleBusinessLookupState {
        guard let serial = Self.normalized(serial) else { return .unavailable("No serial number to look up yet") }
        if !isDemo, let connectionProblem { return .failed(connectionProblem) }
        guard isConfigured else { return .notConfigured }
        return lookupStates[serial] ?? .loading
    }

    /// The state as far as a lookup already ran, for the CSV export: a
    /// device that was never looked up is "not available", not pending.
    func stateSoFar(forSerial serial: String?) -> AppleBusinessLookupState {
        guard let key = Self.normalized(serial), lookupStates[key] == nil else { return state(forSerial: serial) }
        return isConfigured ? .unavailable("Not looked up") : .notConfigured
    }

    /// Starts a lookup unless one already ran or is running.
    func lookupIfNeeded(serial: String?) {
        guard let serial = Self.normalized(serial), isConfigured, lookupStates[serial] == nil else { return }
        performLookup(serial)
    }

    /// Looks up again, discarding any cached result.
    func refresh(serial: String?) {
        guard let serial = Self.normalized(serial), isConfigured else { return }
        lookupStates[serial] = nil
        performLookup(serial)
    }

    private func performLookup(_ serial: String) {
        let client: ABM.Client
        do {
            if !isDemo, let connectionProblem {
                lookupStates[serial] = .failed(connectionProblem)
                return
            }
            guard let active = try activeClient() else { return }
            client = active
        } catch {
            lookupStates[serial] = .failed(error.localizedDescription)
            return
        }
        guard !inFlight.contains(serial) else { return }
        inFlight.insert(serial)
        lookupStates[serial] = .loading
        let generation = configurationGeneration
        let knownNames = serverNames

        Task {
            let state: AppleBusinessLookupState
            var names = knownNames
            do {
                (state, names) = try await Self.lookup(serial: serial, client: client, serverNames: knownNames)
            } catch is CancellationError {
                state = .failed("Stopped while waiting to try again. Choose Retry Lookup to look it up again.")
            } catch {
                // Apple's message (status, error codes, hints). It can hold
                // the server's answer: private in the system log.
                logger.error("Apple Business lookup failed: \(error.localizedDescription, privacy: .private)")
                state = .failed(error.localizedDescription)
            }
            inFlight.remove(serial)
            if generation == configurationGeneration {
                if let names { serverNames = names }
                lookupStates[serial] = state
            } else if lookupStates[serial] == nil {
                // The account changed mid-flight: look up again with the current one.
                performLookup(serial)
            }
        }
    }

    /// One device: its record, the service it is assigned to and its
    /// AppleCare coverage. Only a failure of the device record itself fails
    /// the lookup; a failed coverage request is shown next to the rest.
    nonisolated static func lookup(serial: String, client: ABM.Client, serverNames: [String: String]?)
        async throws -> (AppleBusinessLookupState, [String: String]?) {
        guard let device = try await client.device(serial: serial) else { return (.notInOrganization, serverNames) }
        var names = serverNames
        var serverName: String?
        if !device.isReleased, let serverID = try await client.assignedServerID(serial: serial) {
            if names == nil { names = Dictionary(try await client.mdmServers().map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }) }
            serverName = names?[serverID] ?? serverID
        }
        var coverage: [ABM.AppleCareCoverage] = []
        var coverageProblem: String?
        do {
            coverage = try await client.appleCareCoverage(serial: serial)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            coverageProblem = error.localizedDescription
        }
        let record = AppleBusinessRecord(device: device, mdmServerName: serverName, coverage: coverage,
                                         coverageProblem: coverageProblem)
        return (.found(record), names)
    }

    /// Test Connection in Settings, with the editor's values, saved or not.
    /// A private key typed or imported in the editor is used instead of the
    /// stored one. Always the real account and the real network.
    func testConnection(_ record: AppleBusinessConnection, typedSecret: String?) async throws -> String {
        let key = try typedSecret ?? connections.readSecret(for: record) ?? ""
        guard let configuration = Self.configuration(for: record, privateKey: key) else {
            throw JamfSetupError(message: "Fill in the client ID, key ID and private key first.")
        }
        let client = try Self.makeClient(configuration, session: session, log: activityLog)
        let count = try await client.testConnection()
        let product = ABM.Service(record.service)?.label ?? record.service.displayName
        return "Connected · \(product) · \(count) device management service\(count == 1 ? "" : "s")"
    }
}
