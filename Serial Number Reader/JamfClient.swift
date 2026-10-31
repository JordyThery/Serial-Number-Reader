import Foundation
import JTKit

// MARK: - Configuration & errors

/// How to authenticate against Jamf Pro or Jamf School.
nonisolated enum JamfCredentials: Sendable, Equatable {
    /// OAuth client credentials (Jamf Pro API roles and clients).
    case clientCredentials(clientID: String, clientSecret: String)
    /// "Classic" Jamf Pro user account (Basic auth → bearer token).
    case basic(username: String, password: String)
    /// Jamf Platform API integration from Jamf Account, scoped to a platform
    /// environment (the scope Jamf recommends; tenant scope is not offered).
    case platform(region: JamfRegion, clientID: String, clientSecret: String, environmentID: String)
    /// Jamf School: Network ID and API key (HTTP Basic).
    case jamfSchool(networkID: String, apiKey: String)
}

/// A complete, valid connection: what JTKit's clients are made from, and the
/// web address for "Open in Jamf Pro/School" links.
nonisolated struct JamfConfiguration: Sendable, Equatable {
    /// The Jamf Pro or Jamf School server; nil for the Platform API, which
    /// goes to the region's gateway.
    let serverURL: URL?
    /// The web interface, for "Open in Jamf Pro/School" links. Optional for
    /// the Platform API, which doesn't expose the instance's address.
    let webBaseURL: URL?
    let credentials: JamfCredentials

    var isPlatform: Bool {
        if case .platform = credentials { return true }
        return false
    }

    var isJamfSchool: Bool {
        if case .jamfSchool = credentials { return true }
        return false
    }

    /// The product name shown in the UI.
    var productName: String { isJamfSchool ? "Jamf School" : "Jamf Pro" }

    /// The secret the sign-in uses.
    var secret: String {
        switch credentials {
        case .clientCredentials(_, let secret), .basic(_, let secret), .platform(_, _, let secret, _),
             .jamfSchool(_, let secret):
            secret
        }
    }

    /// The JTKit connection JTKit's Jamf Pro and Platform API client is made
    /// from (its address added to `https://` when typed without it). Nil for
    /// Jamf School.
    var connection: Connection? {
        switch credentials {
        case .clientCredentials(let clientID, _):
            Connection(name: "", service: .jamfPro, signIn: .apiClient,
                       serverURL: serverURL?.absoluteString ?? "", clientID: clientID)
        case .basic(let username, _):
            Connection(name: "", service: .jamfPro, signIn: .usernamePassword,
                       serverURL: serverURL?.absoluteString ?? "", username: username)
        case .platform(let region, let clientID, _, let environmentID):
            Connection(name: "", service: .jamfPlatform, signIn: .apiClient, region: region,
                       environmentID: environmentID, clientID: clientID)
        case .jamfSchool:
            nil
        }
    }

    /// Builds a configuration from raw settings values, or nil when incomplete
    /// or invalid. For the Platform API, `urlString` is the optional Jamf Pro
    /// address used only for links.
    static func make(urlString: String, credentials: JamfCredentials) -> JamfConfiguration? {
        let serverURL = normalizedURL(urlString)
        switch credentials {
        case .clientCredentials(let id, let secret):
            guard !id.isEmpty, !secret.isEmpty, let serverURL else { return nil }
            return JamfConfiguration(serverURL: serverURL, webBaseURL: serverURL, credentials: credentials)
        case .basic(let username, let password):
            guard !username.isEmpty, !password.isEmpty, let serverURL else { return nil }
            return JamfConfiguration(serverURL: serverURL, webBaseURL: serverURL, credentials: credentials)
        case .platform(_, let id, let secret, let environmentID):
            guard !id.isEmpty, !secret.isEmpty, isValidEnvironmentID(environmentID) else { return nil }
            return JamfConfiguration(serverURL: nil, webBaseURL: serverURL, credentials: credentials)
        case .jamfSchool(let networkID, let apiKey):
            // Jamf School's documentation shows the API address with /api;
            // JTKit accepts it and drops it.
            guard !networkID.isEmpty, !apiKey.isEmpty, let schoolURL = JamfSchool.baseURL(urlString) else { return nil }
            return JamfConfiguration(serverURL: schoolURL, webBaseURL: schoolURL, credentials: credentials)
        }
    }

    /// Environment IDs are UUIDs, copied from the integration in Jamf Account.
    static func isValidEnvironmentID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }

    /// `yourorg.jamfcloud.com` → `https://yourorg.jamfcloud.com`; nil if empty
    /// or not a URL with a host.
    static func normalizedURL(_ string: String) -> URL? {
        var normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if !normalized.contains("://") { normalized = "https://" + normalized }
        while normalized.hasSuffix("/") { normalized.removeLast() }
        guard let url = URL(string: normalized), url.host() != nil else { return nil }
        return url
    }
}

/// A problem found before anything is sent, e.g. settings not filled in.
nonisolated struct JamfSetupError: Error, LocalizedError, Equatable {
    let message: String

    var errorDescription: String? { message }
}

// MARK: - Unified device record

nonisolated struct JamfDeviceRecord: Sendable, Equatable {
    enum Kind: String, Sendable {
        case mobileDevice = "Mobile Device"
        case computer = "Computer"
        /// A Jamf School device; `jamfID` is its UDID.
        case schoolDevice = "Jamf School Device"
    }

    let kind: Kind
    let jamfID: String
    let name: String?
    var assetTag: String?
    let serialNumber: String?
    let udid: String?
    let model: String?
    let modelIdentifier: String?
    let osVersion: String?
    let managed: Bool?
    let username: String?
    let realName: String?
    let email: String?
    let lastInventoryDate: Date?

    /// Deep link to the record in the Jamf Pro or Jamf School web UI.
    func webURL(baseURL: URL) -> URL? {
        switch kind {
        case .schoolDevice:
            return URL(string: "\(baseURL.absoluteString)/devices/details/\(jamfID)")
        case .computer:
            return URL(string: "\(baseURL.absoluteString)/computers.html?id=\(jamfID)&o=r")
        case .mobileDevice:
            return URL(string: "\(baseURL.absoluteString)/mobileDevices.html?id=\(jamfID)&o=r")
        }
    }
}

nonisolated extension JamfDeviceRecord {
    /// From JTKit's mobile device record; nil without a Jamf Pro ID.
    init?(_ device: JamfPro.MobileDevice) {
        guard let id = device.id else { return nil }
        self.init(kind: .mobileDevice, jamfID: id, name: device.general?.displayName,
                  assetTag: device.general?.assetTag, serialNumber: device.serialNumber, udid: device.udid,
                  model: device.hardware?.model, modelIdentifier: device.hardware?.modelIdentifier,
                  osVersion: device.general?.osVersion, managed: device.general?.managed,
                  username: device.userAndLocation?.username, realName: device.userAndLocation?.realName,
                  email: device.userAndLocation?.email, lastInventoryDate: device.general?.lastInventoryUpdateDate)
    }

    /// From JTKit's computer record; nil without a Jamf Pro ID. The date is
    /// the last inventory report, or else the last check-in.
    init?(_ computer: JamfPro.Computer) {
        guard let id = computer.id else { return nil }
        self.init(kind: .computer, jamfID: id, name: computer.general?.name, assetTag: computer.general?.assetTag,
                  serialNumber: computer.serialNumber, udid: computer.udid, model: computer.hardware?.model,
                  modelIdentifier: computer.hardware?.modelIdentifier, osVersion: computer.operatingSystem?.version,
                  managed: computer.general?.managed, username: computer.userAndLocation?.username,
                  realName: computer.userAndLocation?.realName, email: computer.userAndLocation?.email,
                  lastInventoryDate: computer.general?.reportDate ?? computer.general?.lastCheckIn)
    }

    /// From JTKit's Jamf School device.
    init(_ device: JamfSchool.Device) {
        self.init(kind: .schoolDevice, jamfID: device.udid, name: device.name, assetTag: device.assetTag,
                  serialNumber: device.serialNumber, udid: device.udid, model: device.modelName,
                  modelIdentifier: device.modelIdentifier, osVersion: device.osVersion, managed: device.isManaged,
                  username: device.ownerUsername, realName: device.ownerName, email: device.ownerEmail,
                  lastInventoryDate: device.lastCheckIn)
    }
}

/// What a lookup found.
nonisolated enum JamfLookupResult: Sendable, Equatable {
    case found(JamfDeviceRecord)
    case noMatch
    case multipleMatches(Int)
}

// MARK: - Client

/// The configured backend behind the operations the app needs: Jamf Pro
/// (directly or through the Platform API gateway) or Jamf School, both on
/// JTKit (sign-in, retries, the activity log, the error format), with the
/// app's own hints on top.
nonisolated enum JamfService: Sendable {
    case pro(JamfPlatform.Client, isPlatform: Bool)
    case school(JamfSchool.Client)

    /// - Parameter recorder: sends and records each request (activity log).
    init(configuration: JamfConfiguration, recorder: RequestRecorder) throws {
        if case .jamfSchool(let networkID, let apiKey) = configuration.credentials {
            self = .school(try JamfSchool.Client(address: configuration.serverURL?.absoluteString ?? "",
                                                 networkID: networkID, apiKey: apiKey, recorder: recorder,
                                                 hints: Self.schoolHints))
        } else if let connection = configuration.connection {
            let secret = configuration.secret
            self = .pro(try JamfPlatform.Client(connection: connection, secret: { secret }, recorder: recorder,
                                                hints: Self.proHints),
                        isPlatform: configuration.isPlatform)
        } else {
            throw JamfSetupError(message: "The connection is incomplete.")
        }
    }

    /// A client for one of JTKit's demo connections (demo mode): its demo
    /// server, fake secret and private network, through the same JTKit code.
    init(demo source: DemoSource, recorder: RequestRecorder) throws {
        let connection = source.connection
        if connection.service == .jamfSchool {
            self = .school(try JamfSchool.Client(address: connection.serverURL, networkID: connection.clientID,
                                                 apiKey: try source.secret(), recorder: recorder,
                                                 hints: Self.schoolHints))
        } else {
            self = .pro(try JamfPlatform.Client(connection: connection, secret: source.secret, recorder: recorder,
                                                hints: Self.proHints),
                        isPlatform: connection.service == .jamfPlatform)
        }
    }

    /// Looks up a device. Serial queries try mobile devices first, then
    /// computers (recovery-mode Macs report a serial too). UDID queries are
    /// mobile-device only. Jamf School records are read from the
    /// single-device endpoint, the only one with the instance's time zone.
    func lookup(_ query: JamfQuery) async throws -> JamfLookupResult {
        switch self {
        case .pro(let client, _):
            switch query {
            case .udid(let udid):
                return try Self.result(await client.mobileDevice(udid: udid), JamfDeviceRecord.init)
            case .serialNumber(let serial):
                let mobile = try await client.mobileDevice(serial: serial)
                if mobile != .none { return try Self.result(mobile, JamfDeviceRecord.init) }
                return try Self.result(await client.computer(serial: serial), JamfDeviceRecord.init)
            }
        case .school(let client):
            let udid: String
            switch query {
            case .udid(let value):
                udid = value
            case .serialNumber(let serial):
                switch try await client.device(serial: serial) {
                case .none: return .noMatch
                case .several(let count): return .multipleMatches(count)
                case .one(let device): udid = device.udid
                }
            }
            guard let device = try await client.device(udid: udid) else { return .noMatch }
            return .found(JamfDeviceRecord(device))
        }
    }

    func updateAssetTag(_ assetTag: String, record: JamfDeviceRecord) async throws {
        switch (self, record.kind) {
        case (.pro(let client, _), .computer):
            try await client.setAssetTag(assetTag, computerID: record.jamfID)
        case (.pro(let client, _), .mobileDevice):
            try await client.setAssetTag(assetTag, mobileDeviceID: record.jamfID)
        case (.school(let client), .schoolDevice):
            try await client.setAssetTag(assetTag, udid: record.jamfID)
        default:
            throw JamfSetupError(message: "This record belongs to another connection. Look the device up again.")
        }
    }

    /// Signs in afresh. For the Platform API a token alone doesn't prove the
    /// environment ID is right, so it also makes one cheap request through the
    /// environment: an inventory read, which devices:read covers.
    func testConnection() async throws {
        switch self {
        case .pro(let client, let isPlatform):
            try await client.signIn()
            if isPlatform {
                _ = try await client.json("pro/v4/computers-inventory", query: [
                    URLQueryItem(name: "section", value: "GENERAL"),
                    URLQueryItem(name: "page", value: "0"),
                    URLQueryItem(name: "page-size", value: "1"),
                ], privilege: .readComputers)
            }
        case .school(let client):
            try await client.testConnection()
        }
    }

    private static func result<Record: Sendable & Hashable>(
        _ match: DeviceMatch<Record>, _ convert: (Record) -> JamfDeviceRecord?
    ) throws -> JamfLookupResult {
        switch match {
        case .none:
            return .noMatch
        case .several(let count):
            return .multipleMatches(count)
        case .one(let record):
            guard let converted = convert(record) else {
                throw JamfPlatform.APIError(.invalidResponse("The Jamf Pro record has no ID."))
            }
            return .found(converted)
        }
    }

    /// The app's hints on top of JTKit's: which Platform API permissions it needs.
    @Sendable private static func proHints(_ error: JamfPlatform.APIError) -> [String] {
        guard error.status == 403, error.server == .platformAPI else { return [] }
        return ["Serial Number Reader needs the devices:read permission, and devices:update to edit asset tags."]
    }

    /// … and what a Jamf School API key must be allowed to do.
    @Sendable private static func schoolHints(_ error: JamfSchool.APIError) -> [String] {
        guard error.status == 401 || error.status == 403 else { return [] }
        return ["Serial Number Reader needs the API key to read devices, and to update their details for asset tags."]
    }
}
