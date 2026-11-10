import Foundation
import JTKit

/// How Apple Business and Apple School Manager values are worded in the
/// detail view and the CSV export.
nonisolated enum AppleBusinessText {

    /// How the detail view shows a status: only an assigned device looks
    /// done (green); an unassigned one needs a device management service
    /// before it can enroll (orange); anything else is neutral.
    enum StatusKind: Equatable {
        case assigned, unassigned, released, other
    }

    static func statusKind(_ device: ABM.OrgDevice) -> StatusKind {
        if device.isReleased { return .released }
        switch device.status?.uppercased() {
        case "ASSIGNED": return .assigned
        case "UNASSIGNED": return .unassigned
        default: return .other
        }
    }

    /// "Assigned", "Unassigned" or "Released"; Apple's own word for anything else.
    static func status(_ device: ABM.OrgDevice) -> String {
        switch statusKind(device) {
        case .assigned: "Assigned"
        case .unassigned: "Unassigned"
        case .released: "Released"
        case .other: device.status.map(\.capitalized) ?? "Unknown"
        }
    }

    /// Apple's own spelling, "iPhone", "iPad", "Mac": never recapitalized
    /// (`capitalized` would make "Iphone").
    static func productFamily(_ device: ABM.OrgDevice) -> String? {
        guard let family = device.productFamily, !family.isEmpty else { return nil }
        return family
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
