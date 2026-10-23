import AppKit
import Foundation
import UniformTypeIdentifiers

/// Turns the device list (the session log) into a CSV export and a plain
/// list of serial numbers.
nonisolated enum SessionExport {

    /// One exported device, flattened to text. Empty strings mean "unknown".
    struct Row: Equatable, Sendable {
        var connected = ""
        var disconnected = ""
        var mode = ""
        var model = ""
        var modelIdentifier = ""
        var osVersion = ""
        var deviceName = ""
        var serialNumber = ""
        var serialSource = ""
        var udid = ""
        var ecid = ""
        var jamfName = ""
        var assetTag = ""
        var managed = ""
        var jamfStatus = ""
    }

    static let header = [
        "Connected", "Disconnected", "Mode", "Model", "Model Identifier", "OS Version",
        "Device Name", "Serial Number", "Serial Source", "UDID", "ECID",
        "Jamf Name", "Asset Tag", "Managed", "Jamf Status",
    ]

    static func row(for device: USBDevice, jamf: JamfLookupState) -> Row {
        var row = Row()
        row.connected = timestamp(device.connectedAt)
        row.disconnected = device.disconnectedAt.map(timestamp) ?? ""
        row.mode = device.mode.rawValue
        row.model = device.modelDisplayName
        row.modelIdentifier = device.modelInfo?.identifier ?? ""
        row.deviceName = device.lockdownInfo?.deviceName ?? ""
        row.udid = device.udid ?? ""
        row.ecid = device.ecid ?? ""

        var record: JamfDeviceRecord?
        switch jamf {
        case .found(let found):
            record = found
            row.jamfStatus = "Found"
        case .notConfigured: row.jamfStatus = "Not configured"
        case .unavailable: row.jamfStatus = "Not available"
        case .loading: row.jamfStatus = "Pending"
        case .noMatch: row.jamfStatus = "No match"
        case .multipleMatches(let count): row.jamfStatus = "\(count) matches"
        case .failed: row.jamfStatus = "Failed"
        }

        if let serial = device.serialNumber {
            row.serialNumber = serial
            row.serialSource = "Device"
        } else if let serial = record?.serialNumber {
            row.serialNumber = serial
            row.serialSource = "Jamf"
        }
        row.osVersion = device.lockdownInfo?.osDisplayName ?? record?.osVersion ?? ""
        row.jamfName = record?.name ?? ""
        row.assetTag = record?.assetTag ?? ""
        row.managed = record?.managed.map { $0 ? "Yes" : "No" } ?? ""
        return row
    }

    /// RFC 4180 CSV (CRLF line endings), header first.
    static func csv(_ rows: [Row]) -> String {
        let lines = [header] + rows.map { row in
            [row.connected, row.disconnected, row.mode, row.model, row.modelIdentifier,
             row.osVersion, row.deviceName, row.serialNumber, row.serialSource, row.udid,
             row.ecid, row.jamfName, row.assetTag, row.managed, row.jamfStatus]
        }
        return lines.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    /// The CSV as UTF-8 with a byte-order mark, so Excel reads accented
    /// device names correctly.
    static func csvData(_ rows: [Row]) -> Data {
        Data("\u{FEFF}".utf8) + Data(csv(rows).utf8)
    }

    /// Unique serial numbers in session order.
    static func serials(_ rows: [Row]) -> [String] {
        var seen = Set<String>()
        return rows.map(\.serialNumber).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Quotes a field when needed. Fields starting with a formula character
    /// are prefixed with an apostrophe: device and asset-tag names are
    /// user-controlled, and spreadsheets would otherwise evaluate them.
    static func escape(_ field: String) -> String {
        // Compare Unicode scalars, not Characters: "\r\n" is a single Character
        // in Swift, so a Character test would miss a lone "\n" or "\r".
        let formulaStarts: Set<Unicode.Scalar> = ["=", "+", "-", "@", "\t", "\r", "\n"]
        let needsQuoting: Set<Unicode.Scalar> = [",", "\"", "\r", "\n"]
        var value = field
        if let first = value.unicodeScalars.first, formulaStarts.contains(first) {
            value = "'" + value
        }
        guard value.unicodeScalars.contains(where: needsQuoting.contains) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - Menu actions

extension SessionExport {

    /// Asks where to save, then writes the CSV.
    @MainActor
    static func presentSavePanel(rows: [Row]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        let stamp = Date.now.formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "Serial Number Reader Session \(stamp).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try csvData(rows).write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "The session couldn't be exported."
            alert.runModal()
        }
    }

    /// Puts one serial number per line on the clipboard.
    @MainActor
    static func copySerials(rows: [Row]) {
        let list = serials(rows)
        guard !list.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(list.joined(separator: "\n"), forType: .string)
    }
}
