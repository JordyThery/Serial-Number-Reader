import Foundation
import os

/// Client for the Jamf School API: HTTP Basic authentication with the
/// Network ID as user and an API key as password, and one device resource
/// for every device type.
///
/// Two quirks shape it (also handled in Checkpoint):
/// - A response can carry its real result in the body's `code`/`message`
///   rather than the HTTP status, so both are checked.
/// - The device list and the single-device endpoint return the same values
///   with different types (`lastCheckin` is a string in one and an object in
///   the other; flags can be booleans or 0/1), so decoding is lenient.
///
/// Records are always read from the single-device endpoint, the only one that
/// reports the instance's time zone for the check-in date. A serial lookup
/// first finds the UDID through the list.
actor JamfSchoolClient {

    private let baseURL: URL
    private let authorization: String
    private let session: URLSession
    private let logger = Logger(subsystem: "be.jordythery.SerialNumberReader", category: "JamfSchool")

    init(baseURL: URL, networkID: String, apiKey: String) {
        self.baseURL = baseURL
        authorization = "Basic " + Data("\(networkID):\(apiKey)".utf8).base64EncodedString()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }

    // MARK: Lookups

    func lookup(_ query: JamfQuery) async throws -> JamfDeviceRecord {
        switch query {
        case .udid(let udid):
            return try await device(udid: JamfClient.validatedIdentifier(udid))
        case .serialNumber(let serial):
            let safe = try JamfClient.validatedIdentifier(serial)
            let data = try await send(path: "api/devices", queryItems: [URLQueryItem(name: "serialnumber", value: safe)])
            struct List: Decodable {
                struct Item: Decodable { let UDID: String?; let serialNumber: String? }
                let devices: [Item]?
            }
            let matches = (try? JSONDecoder().decode(List.self, from: data))?.devices?
                .filter { $0.serialNumber?.caseInsensitiveCompare(safe) == .orderedSame } ?? []
            guard !matches.isEmpty else { throw JamfError.noMatch }
            guard matches.count == 1, let udid = matches[0].UDID else {
                throw JamfError.multipleMatches(matches.count)
            }
            return try await device(udid: JamfClient.validatedIdentifier(udid))
        }
    }

    /// Sets or clears the asset tag. Requires an API key allowed to edit devices.
    func updateAssetTag(_ assetTag: String, udid: String) async throws {
        let safe = try JamfClient.validatedIdentifier(udid)
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "assetTag", value: assetTag)]
        _ = try await send(path: "api/devices/\(safe)/details", method: "POST",
                           body: Data((form.percentEncodedQuery ?? "").utf8))
    }

    /// Validates URL and credentials with a lookup that can't match anything.
    func testConnection() async throws {
        _ = try await send(path: "api/devices", queryItems: [URLQueryItem(name: "serialnumber", value: "CONNECTIONCHECK")])
    }

    // MARK: Device record

    private struct DeviceResponse: Decodable {
        struct Device: Decodable {
            struct Model: Decodable { let name: String?; let identifier: String? }
            struct OS: Decodable { let prefix: String?; let version: String? }
            struct Owner: Decodable { let name: String?; let username: String?; let email: String? }
            let UDID: String?
            let serialNumber: String?
            let name: String?
            let assetTag: String?
            let model: Model?
            let os: OS?
            let owner: Owner?
            let isManaged: LenientBool?
            let lastCheckin: CheckIn?
        }
        let device: Device?
    }

    private func device(udid: String) async throws -> JamfDeviceRecord {
        let data = try await send(path: "api/devices/\(udid)")
        let decoded: DeviceResponse
        do {
            decoded = try JSONDecoder().decode(DeviceResponse.self, from: data)
        } catch {
            throw JamfError.decodingFailure("Jamf School device: \(error.localizedDescription)")
        }
        guard let device = decoded.device else { throw JamfError.noMatch }
        let owner = device.owner
        return JamfDeviceRecord(
            kind: .schoolDevice,
            jamfID: device.UDID ?? udid,
            name: device.name.nonEmpty,
            assetTag: device.assetTag.nonEmpty,
            serialNumber: device.serialNumber.nonEmpty,
            udid: device.UDID ?? udid,
            model: device.model?.name.nonEmpty,
            modelIdentifier: device.model?.identifier.nonEmpty,
            osVersion: device.os?.version.nonEmpty,
            managed: device.isManaged?.value,
            username: owner?.username.nonEmpty,
            realName: owner?.name.nonEmpty,
            email: owner?.email.nonEmpty,
            lastInventoryDate: device.lastCheckin?.date
        )
    }

    // MARK: Requests

    private func send(path: String, queryItems: [URLQueryItem] = [], method: String = "GET",
                      body: Data? = nil) async throws -> Data {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        if !queryItems.isEmpty { components?.queryItems = queryItems }
        guard let url = components?.url else { throw JamfError.networkFailure("invalid request URL") }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let status: Int
        do {
            let (responseData, response) = try await session.data(for: request)
            data = responseData
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            throw JamfError.networkFailure(error.localizedDescription)
        }
        try Self.throwIfError(status: status, data: data)
        return data
    }

    /// The HTTP status alone isn't conclusive: the body's `code` (when present)
    /// can report a failure inside a 200, and errors may be wrapped in "error".
    static func throwIfError(status: Int, data: Data) throws {
        struct Envelope: Decodable {
            struct Inner: Decodable { let code: LenientInt?; let message: String? }
            let code: LenientInt?
            let message: String?
            let error: Inner?
        }
        let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        let code = envelope?.code?.value ?? envelope?.error?.code?.value
        let message = envelope?.message ?? envelope?.error?.message
        let effective = (200...299).contains(status) ? (code ?? status) : status
        guard !(200...299).contains(effective) else { return }

        switch effective {
        case 401, 403:
            throw JamfError.authenticationFailed(
                "HTTP \(effective) — check the Network ID and API key, and that the key may read devices (and edit them for asset tags)")
        case 404:
            throw JamfError.noMatch
        default:
            throw JamfError.httpError(effective, message ?? "unexpected Jamf School response")
        }
    }
}

// MARK: - Lenient decoding

/// A flag sent as a boolean or as 0/1.
nonisolated struct LenientBool: Decodable, Sendable {
    let value: Bool
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) { value = bool }
        else if let number = try? container.decode(Int.self) { value = number != 0 }
        else { value = (try container.decode(String.self)) == "1" }
    }
}

/// A number sent as an integer or a string.
nonisolated struct LenientInt: Decodable, Sendable {
    let value: Int?
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) { value = number }
        else { value = Int((try? container.decode(String.self)) ?? "") }
    }
}

/// The last check-in: a "yyyy-MM-dd HH:mm:ss" string, or an object with the
/// date and the instance's time zone.
nonisolated struct CheckIn: Decodable, Sendable {
    let date: Date?

    init(from decoder: Decoder) throws {
        struct Object: Decodable { let date: String?; let timezone: String? }
        let container = try decoder.singleValueContainer()
        if let object = try? container.decode(Object.self) {
            date = Self.parse(object.date, timeZone: object.timezone.flatMap(TimeZone.init(identifier:)))
        } else {
            date = Self.parse(try? container.decode(String.self), timeZone: nil)
        }
    }

    /// Parses the date part, ignoring fractional seconds. Without a time zone
    /// the Mac's own is assumed.
    static func parse(_ text: String?, timeZone: TimeZone?) -> Date? {
        guard let text, text.count >= 19 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = timeZone ?? .current
        return formatter.date(from: String(text.prefix(19)))
    }
}

private extension Optional where Wrapped == String {
    /// Jamf School sends empty strings for unset values.
    var nonEmpty: String? {
        guard let self, !self.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return self
    }
}
