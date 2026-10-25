import Foundation
import os

// MARK: - Configuration & errors

/// A Jamf Platform API gateway region. Tokens are region-locked, so the
/// token and every request must go to the same regional host.
nonisolated enum PlatformRegion: String, CaseIterable, Identifiable, Sendable {
    case eu, us, apac

    var id: Self { self }
    var label: String {
        switch self {
        case .eu: "Europe (EU)"
        case .us: "United States (US)"
        case .apac: "Asia Pacific (APAC)"
        }
    }

    var gatewayURL: URL {
        URL(string: "https://\(rawValue).api.jamfcloud.com")!
    }
}

/// How to authenticate against Jamf Pro.
nonisolated enum JamfCredentials: Sendable, Equatable {
    /// OAuth client credentials (Jamf Pro API roles and clients).
    case clientCredentials(clientID: String, clientSecret: String)
    /// "Classic" Jamf Pro user account (Basic auth → bearer token).
    case basic(username: String, password: String)
    /// Jamf Platform API integration from Jamf Account, scoped to a platform
    /// environment (the scope Jamf recommends; tenant scope is not offered).
    case platform(region: PlatformRegion, clientID: String, clientSecret: String, environmentID: String)
    /// Jamf School: Network ID and API key (HTTP Basic).
    case jamfSchool(networkID: String, apiKey: String)
}

nonisolated struct JamfConfiguration: Sendable, Equatable {
    /// Base for API paths such as `v2/mobile-devices/detail`:
    /// `https://server/api` for Jamf Pro, `https://{region}.api.jamfcloud.com/pro`
    /// for the Platform API gateway.
    let apiBaseURL: URL
    /// nil for Jamf School, which authenticates every request directly.
    let tokenURL: URL?
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

    /// Request headers that identify the context; the gateway serves every
    /// customer in a region from one host.
    var contextHeaders: [String: String] {
        if case .platform(_, _, _, let environmentID) = credentials {
            return ["X-Environment-Id": environmentID]
        }
        return [:]
    }

    /// Builds a configuration from raw settings values, or nil when incomplete
    /// or invalid. For the Platform API, `urlString` is the optional Jamf Pro
    /// address used only for links.
    static func make(urlString: String, credentials: JamfCredentials) -> JamfConfiguration? {
        let serverURL = normalizedURL(urlString)
        switch credentials {
        case .clientCredentials(let id, let secret):
            guard !id.isEmpty, !secret.isEmpty, let serverURL else { return nil }
            return JamfConfiguration(
                apiBaseURL: serverURL.appending(path: "api"),
                tokenURL: serverURL.appending(path: "api/oauth/token"),
                webBaseURL: serverURL, credentials: credentials)
        case .basic(let username, let password):
            guard !username.isEmpty, !password.isEmpty, let serverURL else { return nil }
            return JamfConfiguration(
                apiBaseURL: serverURL.appending(path: "api"),
                tokenURL: serverURL.appending(path: "api/v1/auth/token"),
                webBaseURL: serverURL, credentials: credentials)
        case .platform(let region, let id, let secret, let environmentID):
            guard !id.isEmpty, !secret.isEmpty, isValidEnvironmentID(environmentID) else { return nil }
            return JamfConfiguration(
                apiBaseURL: region.gatewayURL.appending(path: "pro"),
                tokenURL: region.gatewayURL.appending(path: "auth/token"),
                webBaseURL: serverURL, credentials: credentials)
        case .jamfSchool(let networkID, let apiKey):
            guard !networkID.isEmpty, !apiKey.isEmpty, let serverURL else { return nil }
            // Paths such as "api/devices" are appended by JamfSchoolClient.
            return JamfConfiguration(
                apiBaseURL: serverURL, tokenURL: nil,
                webBaseURL: serverURL, credentials: credentials)
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

nonisolated enum JamfError: Error, LocalizedError, Equatable {
    case authenticationFailed(String)
    case httpError(Int, String)
    case networkFailure(String)
    case decodingFailure(String)
    case invalidIdentifier
    case noMatch
    case multipleMatches(Int)

    var errorDescription: String? {
        switch self {
        case .authenticationFailed(let detail): "Jamf authentication failed: \(detail)"
        case .httpError(let code, let detail): "Jamf returned HTTP \(code): \(detail)"
        case .networkFailure(let detail): "Network error: \(detail)"
        case .decodingFailure(let detail): "Unexpected Jamf response: \(detail)"
        case .invalidIdentifier: "The device identifier contains unexpected characters"
        case .noMatch: "No matching device found in Jamf"
        case .multipleMatches(let count): "\(count) devices in Jamf match — record is ambiguous"
        }
    }
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

// MARK: - Client

/// Jamf Pro API client, reached directly or through the Jamf Platform API
/// gateway (same endpoints and schemas). The access token is cached and
/// refreshed shortly before expiry.
actor JamfClient {

    private let config: JamfConfiguration
    private let session: URLSession
    private var cachedToken: (value: String, expiry: Date)?
    private let logger = Logger(subsystem: "be.jordythery.SerialNumberReader", category: "JamfClient")

    init(config: JamfConfiguration) {
        self.config = config
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 30
        session = URLSession(configuration: sessionConfig)
    }

    // MARK: Public lookups

    /// Looks up a device. Serial queries try mobile devices first, then
    /// computers (recovery-mode Macs report a serial too). UDID queries are
    /// mobile-device only.
    func lookup(_ query: JamfQuery) async throws -> JamfDeviceRecord {
        switch query {
        case .udid(let udid):
            let safe = try Self.validatedIdentifier(udid)
            return try await lookupMobileDevice(filter: "udid==\"\(safe)\"")
        case .serialNumber(let serial):
            let safe = try Self.validatedIdentifier(serial)
            do {
                return try await lookupMobileDevice(filter: "serialNumber==\"\(safe)\"")
            } catch JamfError.noMatch {
                return try await lookupComputer(serial: safe)
            }
        }
    }

    /// Serials and UDIDs are alphanumeric plus hyphens. The values originate
    /// from USB descriptors — device-controlled data — so anything else is
    /// rejected rather than interpolated into an RSQL filter.
    static func validatedIdentifier(_ value: String) throws -> String {
        guard !value.isEmpty, value.count <= 64,
              value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
        else { throw JamfError.invalidIdentifier }
        return value
    }

    /// Validates the configuration; used by Settings. For the Platform API a
    /// token alone doesn't prove the environment ID is right, so it also makes
    /// one cheap request through the environment — an inventory read, which
    /// the required devices:read permission covers.
    func testConnection() async throws {
        _ = try await validToken(forceRefresh: true)
        if config.isPlatform {
            _ = try await authorizedGET(path: "v1/computers-inventory", queryItems: [
                URLQueryItem(name: "section", value: "GENERAL"),
                URLQueryItem(name: "page", value: "0"),
                URLQueryItem(name: "page-size", value: "1"),
            ])
        }
    }

    // MARK: Token handling

    private func validToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let cachedToken, cachedToken.expiry > Date.now.addingTimeInterval(30) {
            return cachedToken.value
        }
        let token: (value: String, expiry: Date)
        switch config.credentials {
        case .clientCredentials(let clientID, let clientSecret):
            token = try await fetchOAuthToken(clientID: clientID, clientSecret: clientSecret)
        case .basic(let username, let password):
            token = try await fetchBasicAuthToken(username: username, password: password)
        case .platform(_, let clientID, let clientSecret, _):
            // Same OAuth client-credentials exchange, against the regional
            // gateway; tokens last 900 s and are renewed like any other.
            token = try await fetchOAuthToken(clientID: clientID, clientSecret: clientSecret)
        case .jamfSchool:
            // Served by JamfSchoolClient, which needs no tokens.
            throw JamfError.authenticationFailed("Jamf School is not handled by the Jamf Pro client")
        }
        cachedToken = token
        return token.value
    }

    /// OAuth client credentials (form-encoded): `/api/oauth/token` on Jamf Pro,
    /// `/auth/token` on the Platform API gateway.
    private func fetchOAuthToken(clientID: String, clientSecret: String) async throws -> (value: String, expiry: Date) {
        guard let tokenURL = config.tokenURL else { throw JamfError.networkFailure("no token address") }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "client_credentials"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "client_secret", value: clientSecret),
        ]
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)

        let data = try await performTokenRequest(request)

        struct TokenResponse: Decodable {
            let access_token: String
            let expires_in: Double?
        }
        guard let token = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw JamfError.decodingFailure("token response")
        }
        return (token.access_token, Date.now.addingTimeInterval(token.expires_in ?? 600))
    }

    /// Classic user account: POST /api/v1/auth/token with Basic auth.
    /// Returns a bearer token (default lifetime 30 minutes).
    private func fetchBasicAuthToken(username: String, password: String) async throws -> (value: String, expiry: Date) {
        guard let tokenURL = config.tokenURL else { throw JamfError.networkFailure("no token address") }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        let basic = Data("\(username):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data = try await performTokenRequest(request)

        struct TokenResponse: Decodable {
            let token: String
            let expires: String?
        }
        guard let token = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw JamfError.decodingFailure("auth token response")
        }
        // "expires" is an ISO 8601 timestamp; fall back to 25 minutes.
        let expiry = Self.parseDate(token.expires) ?? Date.now.addingTimeInterval(25 * 60)
        return (token.token, expiry)
    }

    private func performTokenRequest(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await perform(request)
        guard response.statusCode == 200 else {
            logger.error("Token request failed: HTTP \(response.statusCode)")
            if config.isPlatform, (400...401).contains(response.statusCode) {
                throw JamfError.authenticationFailed(
                    "HTTP \(response.statusCode) — check the client ID, secret and region. Jamf Account integrations expire after six months.")
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            throw JamfError.authenticationFailed("HTTP \(response.statusCode) \(body.prefix(200))")
        }
        return data
    }

    // MARK: Requests

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw JamfError.networkFailure("non-HTTP response")
            }
            return (data, http)
        } catch let error as JamfError {
            throw error
        } catch {
            throw JamfError.networkFailure(error.localizedDescription)
        }
    }

    private func authorizedGET(path: String, queryItems: [URLQueryItem]) async throws -> Data {
        try await authorizedRequest(method: "GET", path: path, queryItems: queryItems, body: nil)
    }

    private func authorizedRequest(
        method: String, path: String, queryItems: [URLQueryItem], body: Data?
    ) async throws -> Data {
        let token = try await validToken()
        var components = URLComponents(
            url: config.apiBaseURL.appending(path: path),
            resolvingAgainstBaseURL: false
        )
        if !queryItems.isEmpty { components?.queryItems = queryItems }
        guard let url = components?.url else { throw JamfError.networkFailure("invalid request URL") }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (header, value) in config.contextHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        var (data, response) = try await perform(request)
        if response.statusCode == 401 {
            // Token may have been revoked server-side; retry once with a fresh one.
            let fresh = try await validToken(forceRefresh: true)
            request.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
            (data, response) = try await perform(request)
        }
        guard (200...299).contains(response.statusCode) else {
            switch response.statusCode {
            case 401:
                throw JamfError.authenticationFailed("HTTP 401 — check the credentials and their Jamf Pro privileges")
            case 400 where config.isPlatform
                && String(decoding: data, as: UTF8.self).contains("INVALID_REQUEST_CONTEXT_ID"):
                throw JamfError.httpError(400, "the environment ID doesn't belong to this integration — copy it from the integration's details in Jamf Account")
            case 403 where config.isPlatform:
                throw JamfError.httpError(403, "check that the integration is scoped to this platform environment and has the devices:read permission (devices:update to edit asset tags)")
            case 403:
                throw JamfError.httpError(403, "the account lacks the privilege for this action")
            default:
                throw JamfError.httpError(response.statusCode, String(data: data, encoding: .utf8)?.prefix(200).description ?? "")
            }
        }
        return data
    }

    // MARK: Asset tag updates

    /// Writes a new asset tag to the Jamf Pro record. Requires the
    /// "Update Mobile Devices" / "Update Computers" privilege, or
    /// `devices:update` on the Platform API.
    func updateAssetTag(_ assetTag: String, kind: JamfDeviceRecord.Kind, jamfID: String) async throws {
        let path: String
        let body: [String: Any]
        switch kind {
        case .mobileDevice:
            path = "v2/mobile-devices/\(jamfID)"
            body = ["assetTag": assetTag]
        case .computer:
            path = "v1/computers-inventory-detail/\(jamfID)"
            body = ["general": ["assetTag": assetTag]]
        case .schoolDevice:
            throw JamfError.httpError(400, "Jamf School records are updated by the Jamf School client")
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        _ = try await authorizedRequest(method: "PATCH", path: path, queryItems: [], body: data)
    }

    // MARK: Mobile devices (GET /api/v2/mobile-devices/detail)

    private struct MobileDetailResponse: Decodable {
        struct Result: Decodable {
            struct General: Decodable {
                let displayName: String?
                let assetTag: String?
                let udid: String?
                let osVersion: String?
                let managed: Bool?
                let lastInventoryUpdateDate: String?
            }
            struct Hardware: Decodable {
                let serialNumber: String?
                let udid: String?
                let model: String?
                let modelIdentifier: String?
            }
            struct UserAndLocation: Decodable {
                let username: String?
                let realName: String?
                let emailAddress: String?
            }
            let mobileDeviceId: String?
            let udid: String?
            let general: General?
            let hardware: Hardware?
            let userAndLocation: UserAndLocation?
        }
        let totalCount: Int?
        let results: [Result]
    }

    private func lookupMobileDevice(filter: String) async throws -> JamfDeviceRecord {
        let data = try await authorizedGET(
            path: "v2/mobile-devices/detail",
            queryItems: [
                URLQueryItem(name: "section", value: "GENERAL"),
                URLQueryItem(name: "section", value: "HARDWARE"),
                URLQueryItem(name: "section", value: "USER_AND_LOCATION"),
                URLQueryItem(name: "page", value: "0"),
                URLQueryItem(name: "page-size", value: "10"),
                URLQueryItem(name: "filter", value: filter),
            ]
        )
        let decoded: MobileDetailResponse
        do {
            decoded = try JSONDecoder().decode(MobileDetailResponse.self, from: data)
        } catch {
            throw JamfError.decodingFailure("mobile-devices detail: \(error.localizedDescription)")
        }

        guard let result = decoded.results.first else { throw JamfError.noMatch }
        let count = decoded.totalCount ?? decoded.results.count
        guard count == 1 else { throw JamfError.multipleMatches(count) }
        guard let id = result.mobileDeviceId else {
            throw JamfError.decodingFailure("mobile device record has no ID")
        }

        return JamfDeviceRecord(
            kind: .mobileDevice,
            jamfID: id,
            name: result.general?.displayName,
            assetTag: result.general?.assetTag,
            serialNumber: result.hardware?.serialNumber,
            udid: result.udid ?? result.general?.udid ?? result.hardware?.udid,
            model: result.hardware?.model,
            modelIdentifier: result.hardware?.modelIdentifier,
            osVersion: result.general?.osVersion,
            managed: result.general?.managed,
            username: result.userAndLocation?.username,
            realName: result.userAndLocation?.realName,
            email: result.userAndLocation?.emailAddress,
            lastInventoryDate: Self.parseDate(result.general?.lastInventoryUpdateDate)
        )
    }

    // MARK: Computers (GET /api/v1/computers-inventory)

    private struct ComputerInventoryResponse: Decodable {
        struct Result: Decodable {
            struct General: Decodable {
                struct RemoteManagement: Decodable { let managed: Bool? }
                let name: String?
                let assetTag: String?
                let lastContactTime: String?
                let reportDate: String?
                let remoteManagement: RemoteManagement?
            }
            struct Hardware: Decodable {
                let serialNumber: String?
                let model: String?
                let modelIdentifier: String?
            }
            struct OperatingSystem: Decodable { let version: String? }
            struct UserAndLocation: Decodable {
                let username: String?
                let realname: String?
                let email: String?
            }
            let id: String?
            let udid: String?
            let general: General?
            let hardware: Hardware?
            let operatingSystem: OperatingSystem?
            let userAndLocation: UserAndLocation?
        }
        let totalCount: Int?
        let results: [Result]
    }

    private func lookupComputer(serial: String) async throws -> JamfDeviceRecord {
        let data = try await authorizedGET(
            path: "v1/computers-inventory",
            queryItems: [
                URLQueryItem(name: "section", value: "GENERAL"),
                URLQueryItem(name: "section", value: "HARDWARE"),
                URLQueryItem(name: "section", value: "OPERATING_SYSTEM"),
                URLQueryItem(name: "section", value: "USER_AND_LOCATION"),
                URLQueryItem(name: "page", value: "0"),
                URLQueryItem(name: "page-size", value: "10"),
                URLQueryItem(name: "filter", value: "hardware.serialNumber==\"\(serial)\""),
            ]
        )
        let decoded: ComputerInventoryResponse
        do {
            decoded = try JSONDecoder().decode(ComputerInventoryResponse.self, from: data)
        } catch {
            throw JamfError.decodingFailure("computers-inventory: \(error.localizedDescription)")
        }

        guard let result = decoded.results.first else { throw JamfError.noMatch }
        let count = decoded.totalCount ?? decoded.results.count
        guard count == 1 else { throw JamfError.multipleMatches(count) }
        guard let id = result.id else {
            throw JamfError.decodingFailure("computer record has no ID")
        }

        return JamfDeviceRecord(
            kind: .computer,
            jamfID: id,
            name: result.general?.name,
            assetTag: result.general?.assetTag,
            serialNumber: result.hardware?.serialNumber,
            udid: result.udid,
            model: result.hardware?.model,
            modelIdentifier: result.hardware?.modelIdentifier,
            osVersion: result.operatingSystem?.version,
            managed: result.general?.remoteManagement?.managed,
            username: result.userAndLocation?.username,
            realName: result.userAndLocation?.realname,
            email: result.userAndLocation?.email,
            lastInventoryDate: Self.parseDate(result.general?.reportDate ?? result.general?.lastContactTime)
        )
    }

    // MARK: Helpers

    private static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        return plain.date(from: string)
    }
}
