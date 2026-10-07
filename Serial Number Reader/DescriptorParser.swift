import Foundation

/// A single `KEY:VALUE` pair from a Recovery/DFU USB serial-number descriptor,
/// kept in the order it appeared in the descriptor.
nonisolated struct DescriptorField: Hashable, Sendable {
    let key: String
    let value: String
}

/// The parsed form of a Recovery/DFU USB serial-number string descriptor.
nonisolated struct ParsedDescriptor: Equatable, Sendable {
    let fields: [DescriptorField]

    /// Returns the value for a key, or nil when the key is absent.
    subscript(key: String) -> String? {
        fields.first { $0.key == key }?.value
    }

    /// Returns the value for a key, treating empty values as missing.
    private func nonEmpty(_ key: String) -> String? {
        guard let value = self[key], !value.isEmpty else { return nil }
        return value
    }

    var cpid: String? { nonEmpty("CPID") }
    var bdid: String? { nonEmpty("BDID") }
    var ecid: String? { nonEmpty("ECID") }
    /// The device serial number (SRNM). Present in Recovery mode, never in DFU.
    var serialNumber: String? { nonEmpty("SRNM") }
    var imei: String? { nonEmpty("IMEI") }
    /// iBoot tag (SRTG). Typically present in DFU mode.
    var bootTag: String? { nonEmpty("SRTG") }
}

/// Pure parsing helpers for Apple USB serial-number string descriptors.
/// No I/O, no state — fully unit-testable.
nonisolated enum DescriptorParser {

    /// Parses a Recovery/DFU descriptor such as:
    ///
    /// `CPID:8110 CPRV:11 CPFM:03 SCEP:01 BDID:0C ECID:001A2B3C4D5E6F70 IBFL:3C SRNM:[F2LXXXXXXXXX] IMEI:[35...]`
    ///
    /// Values may be wrapped in `[brackets]`; the brackets are stripped.
    /// Unrecognised tokens are ignored; key order is preserved.
    static func parse(_ descriptor: String) -> ParsedDescriptor {
        // KEY:VALUE where VALUE is either a [bracketed] run (may contain spaces) or a non-space run.
        let pattern = /([A-Za-z0-9_]+):(\[[^\]]*\]|\S+)/
        var fields: [DescriptorField] = []
        for match in descriptor.matches(of: pattern) {
            let key = String(match.1)
            var value = String(match.2)
            if value.hasPrefix("["), value.hasSuffix("]") {
                value = String(value.dropFirst().dropLast())
            }
            value = value.trimmingCharacters(in: .whitespaces)
            fields.append(DescriptorField(key: key, value: value))
        }
        return ParsedDescriptor(fields: fields)
    }

    /// Normalises a UDID read from the USB serial-number descriptor of a
    /// normally booted device.
    ///
    /// - Older devices use a 40-character hex UDID (kept lowercase).
    /// - Newer devices (A12+) use `XXXXXXXX-XXXXXXXXXXXXXXXX`; the USB
    ///   descriptor reports the 24 hex characters without the hyphen, so the
    ///   hyphen is inserted after the first 8 characters and hex is uppercased.
    ///
    /// Returns nil for strings that don't look like a UDID at all.
    static func normalizedUDID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = trimmed.replacingOccurrences(of: "-", with: "")
        guard !compact.isEmpty, compact.allSatisfy(\.isHexDigit) else { return nil }
        switch compact.count {
        case 40:
            return compact.lowercased()
        case 24:
            let upper = compact.uppercased()
            let prefix = upper.prefix(8)
            let suffix = upper.dropFirst(8)
            return "\(prefix)-\(suffix)"
        default:
            return nil
        }
    }
}
