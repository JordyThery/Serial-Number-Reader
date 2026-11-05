import Foundation
import JTKit

/// How Apple Business and Apple School Manager's values are worded in the
/// detail view and the CSV export.
nonisolated enum AppleBusinessText {

    /// "Assigned", "Unassigned" or "Released"; Apple's own word for anything else.
    static func status(_ device: ABM.OrgDevice) -> String {
        if device.isReleased { return "Released" }
        switch device.status?.uppercased() {
        case "ASSIGNED": return "Assigned"
        case "UNASSIGNED": return "Unassigned"
        case let other?: return other.capitalized
        case nil: return "Unknown"
        }
    }

    /// "Apple", "Reseller" and so on, with the reseller's ID when Apple gives one.
    static func purchaseSource(_ device: ABM.OrgDevice) -> String? {
        guard let type = device.purchaseSourceType, !type.isEmpty else { return nil }
        let name = type.replacingOccurrences(of: "_", with: " ").capitalized
        guard let id = device.purchaseSourceId, !id.isEmpty else { return name }
        return "\(name) (\(id))"
    }

    /// "Active until 12 Mar 2028", "Expired 3 Jan 2025", or the plain status.
    static func coverage(_ coverage: ABM.AppleCareCoverage, now: Date = Date()) -> String {
        let end = coverage.endDateTime.flatMap(ABM.date)?.formatted(date: .abbreviated, time: .omitted)
        if coverage.isActive { return end.map { "Active until \($0)" } ?? "Active" }
        if coverage.hasExpired(now: now), let end { return "Expired \(end)" }
        let status = coverage.status?.capitalized ?? "Not active"
        return end.map { "\(status), ends \($0)" } ?? status
    }

    /// The CSV's "Apple Business Status" column.
    static func exportStatus(_ state: AppleBusinessLookupState) -> String {
        switch state {
        case .notConfigured: ""
        case .unavailable: "Not available"
        case .loading: "Pending"
        case .found(let record): status(record.device)
        case .notInOrganization: "Not in organization"
        case .failed: "Failed"
        }
    }
}
