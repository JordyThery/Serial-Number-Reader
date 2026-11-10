import Foundation
import JTKit
import Observation

/// Passes the Apple Business and Apple School Manager requests on to the
/// app's activity log, with Apple's order number and the reseller's ID
/// marked as identifiers, so "Export for Bug Report…" masks them wherever
/// they appear (JTKit's masker knows serial numbers, not these).
///
/// JTKit's client records into `staging`; each entry moves to the app's log
/// as soon as it is there, in order.
@MainActor
final class AppleActivityRelay {
    /// Where the Apple client records; emptied as entries move on.
    let staging = ActivityLog()
    private let target: ActivityLog

    /// The keys of Apple's device record that identify a purchase.
    nonisolated static let purchaseKeys: Set<String> = ["orderNumber", "purchaseSourceId"]

    init(target: ActivityLog) {
        self.target = target
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = staging.entries
        } onChange: { [weak self] in
            // Called before the change: move the entries afterwards.
            Task { @MainActor [weak self] in
                self?.forward()
                self?.observe()
            }
        }
    }

    /// Moves everything recorded so far; also called when a lookup or Test
    /// Connection ends, so its entries are in the app's log right away.
    func forward() {
        let entries = staging.entries
        guard !entries.isEmpty else { return }
        staging.clear()
        for var entry in entries {
            for found in Self.purchaseIdentifiers(in: entry) where !entry.identifiers.contains(found) {
                entry.identifiers.append(found)
            }
            target.append(entry)
        }
    }

    /// The order numbers and reseller IDs in an entry's recorded bodies.
    nonisolated static func purchaseIdentifiers(in entry: ActivityLogEntry) -> [FoundIdentifier] {
        [entry.request?.responseBody, entry.request?.requestBody].compactMap { $0 }.flatMap { body in
            guard let object = try? JSONSerialization.jsonObject(with: Data(body.utf8), options: [.fragmentsAllowed])
            else { return [FoundIdentifier]() }
            return values(in: object).map { FoundIdentifier(.device, $0) }
        }
    }

    private nonisolated static func values(in object: Any) -> [String] {
        if let dictionary = object as? [String: Any] {
            return dictionary.flatMap { key, value -> [String] in
                if purchaseKeys.contains(key), let text = value as? String,
                   text.trimmingCharacters(in: .whitespaces).count >= 3 {
                    return [text]
                }
                return values(in: value)
            }
        }
        if let array = object as? [Any] { return array.flatMap(values(in:)) }
        return []
    }
}
