import Foundation
import os

// MARK: - Configuration & errors

/// How to authenticate against Jamf Pro.
nonisolated enum JamfCredentials: Sendable, Equatable {
    /// OAuth client credentials (API roles and clients).
    case clientCredentials(clientID: String, clientSecret: String)
    /// "Classic" Jamf Pro user account (Basic auth → bearer token).
    case basic(username: String, password: String)
}

nonisolated struct JamfConfiguration: Sendable, Equatable {
    let baseURL: URL
    let credentials: JamfCredentials

    /// Builds a configuration from raw settings values, or nil when incomplete.
    static func make(urlString: String, credentials: JamfCredentials) -> JamfConfiguration? {
        switch credentials {
        case .clientCredentials(let id, let secret):
            guard !id.isEmpty, !secret.isEmpty else { return nil }
        case .basic(let username, let password):
            guard !username.isEmpty, !password.isEmpty else { return nil }
        }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var normalized = trimmed
        if !normalized.contains("://") { normalized = "https://" + normalized }
        while normalized.hasSuffix("/") { normalized.removeLast() }
        guard let url = URL(string: normalized), url.host() != nil else { return nil }
        return JamfConfiguration(baseURL: url, credentials: credentials)
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
        case .httpError(let code, let detail): "Jamf Pro returned HTTP \(code): \(detail)"
        case .networkFailure(let detail): "Network error: \(detail)"
        case .decodingFailure(let detail): "Unexpected Jamf response: \(detail)"
        case .invalidIdentifier: "The device identifier contains unexpected characters"
        case .noMatch: "No matching device found in Jamf Pro"
        case .multipleMatches(let count): "\(count) devices in Jamf Pro match — record is ambiguous"
        }
    }
}

// MARK: - Unified device record

nonisolated struct JamfDeviceRecord: Sendable, Equatable {
    enum Kind: String, Sendable {
        case mobileDevice = "Mobile Device"
        case computer = "Computer"
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

    /// Deep link to the record in the Jamf Pro web UI.
    func webURL(baseURL: URL) -> URL? {
        let page = kind == .computer ? "computers.html" : "mobileDevices.html"
        return URL(string: "\(baseURL.absoluteString)/\(page)?id=\(jamfID)&o=r")
    }
}

// MARK: - Client

/// Jamf Pro API client using OAuth client credentials. The access token is
/// cached and refreshed shortly before expiry.
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
    private static func validatedIdentifier(_ value: String) throws -> String {
        guard !value.isEmpty, value.count <= 64,
              value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
        else { throw JamfError.invalidIdentifier }
        return value
    }

    /// Fetches a token; used by Settings to validate credentials.
    func testConnection() async throws {
        _ = try await validToken(forceRefresh: true)
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
        }
        cachedToken = token
        return token.value
    }

    /// OAuth client credentials: POST /api/oauth/token (form-encoded).
    private func fetchOAuthToken(clientID: String, clientSecret: String) async throws -> (value: String, expiry: Date) {
        var request = URLRequest(url: config.baseURL.appending(path: "api/oauth/token"))
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
        var request = URLRequest(url: config.baseURL.appending(path: "api/v1/auth/token"))
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
            let body = String(data: data, encoding: .utf8) ?? ""
            logger.error("Token request failed: HTTP \(response.statusCode)")
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
            url: config.baseURL.appending(path: path),
            resolvingAgainstBaseURL: false
        )
        if !queryItems.isEmpty { components?.queryItems = queryItems }
        guard let url = components?.url else { throw JamfError.networkFailure("invalid request URL") }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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
    /// "Update Mobile Devices" / "Update Computers" privilege.
    func updateAssetTag(_ assetTag: String, kind: JamfDeviceRecord.Kind, jamfID: String) async throws {
        let path: String
        let body: [String: Any]
        switch kind {
        case .mobileDevice:
            path = "api/v2/mobile-devices/\(jamfID)"
            body = ["assetTag": assetTag]
        case .computer:
            path = "api/v1/computers-inventory-detail/\(jamfID)"
            body = ["general": ["assetTag": assetTag]]
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
            path: "api/v2/mobile-devices/detail",
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
            path: "api/v1/computers-inventory",
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
