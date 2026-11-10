import Foundation

/// What an action that reboots a device waits for: the same device (by
/// ECID) appearing again on USB in one of the expected modes.
nonisolated struct DeviceReturnExpectation: Equatable, Sendable {
    /// The device's ECID (normalized, 16 hex digits); nil when it was unknown
    /// before the action, so the return can't be matched to it.
    let ecid: String?
    /// The device's row before the action; a reboot gives it a new one.
    let previousID: UInt64?
    let modes: Set<DeviceMode>
    /// How long to watch.
    let timeout: Duration
    /// What the user reads when the device didn't come back.
    let notBackMessage: String
}

/// How the watch ended.
nonisolated enum DeviceReturnResult: Equatable, Sendable {
    /// The same ECID is back in an expected mode.
    case back
    /// A device came back in an expected mode, but its ECID couldn't be read
    /// (or wasn't known before), so it can't be confirmed as the same one.
    case backUnconfirmed(String)
    /// Nothing came back in time.
    case notBack(String)

    /// The note when a device in the expected mode showed no ECID.
    static let unconfirmedNote =
        "A device appeared in the expected mode, but its ECID couldn’t be read to confirm it’s the same device."
}

/// Watches the device list until the expected device is back, or the time is up.
@MainActor
struct DeviceReturnWatch {
    /// The rows as the sidebar lists them (the monitor's, or demo mode's).
    let devices: @MainActor () -> [USBDevice]
    /// How often the list is looked at.
    var interval: Duration = .milliseconds(500)
    /// How long a device without a readable ECID gets for Apple Configurator
    /// to identify it, before it counts as back but unconfirmed.
    var identifyGrace: Duration = .seconds(10)
    /// Cuts every watch short (tests); nil watches as long as expected.
    var maximumWait: Duration?

    func wait(for expectation: DeviceReturnExpectation, since start: Date) async -> DeviceReturnResult {
        let timeout = min(expectation.timeout, maximumWait ?? expectation.timeout)
        let polls = max(1, Int(timeout / interval))
        let gracePolls = max(1, Int(identifyGrace / interval))
        var unconfirmedSince: Int?
        for poll in 0...polls {
            if poll > 0 { try? await Task.sleep(for: interval) }
            let arrived = devices().filter {
                $0.isConnected && $0.id != expectation.previousID && $0.connectedAt >= start
                    && expectation.modes.contains($0.mode)
            }
            if let wanted = expectation.ecid {
                if arrived.contains(where: { $0.normalizedECID == wanted }) { return .back }
                // A device in the expected mode whose ECID isn't known (yet): give Configurator a moment.
                if arrived.contains(where: { $0.normalizedECID == nil }) {
                    unconfirmedSince = unconfirmedSince ?? poll
                    if let since = unconfirmedSince, poll - since >= gracePolls {
                        return .backUnconfirmed(DeviceReturnResult.unconfirmedNote)
                    }
                }
            } else if !arrived.isEmpty {
                return .backUnconfirmed("The device’s ECID wasn’t known before, so the device that came back can’t be confirmed as the same one.")
            }
        }
        if unconfirmedSince != nil { return .backUnconfirmed(DeviceReturnResult.unconfirmedNote) }
        return .notBack(expectation.notBackMessage)
    }
}

extension USBDevice {
    /// The ECID as 16 hex digits, from the descriptor, Apple Configurator or
    /// a modern UDID; nil when none of them has it.
    nonisolated var normalizedECID: String? { configuratorECID.flatMap(Configurator.normalizedECID) }
}

extension DeviceReturnExpectation {
    /// After Restart: Recovery stays in Recovery, DFU starts up (or lands in
    /// Recovery without an OS), a booted device starts up again.
    nonisolated static func restart(of device: USBDevice, timeout: Duration = .seconds(120)) -> Self {
        let modes: Set<DeviceMode> = switch device.mode {
        case .recovery: [.recovery]
        case .dfu: [.normal, .recovery]
        case .normal: [.normal]
        }
        return Self(ecid: device.normalizedECID, previousID: device.id, modes: modes, timeout: timeout,
                    notBackMessage: "The device hasn’t appeared on USB again within \(timeout.wholeSeconds) seconds. "
                        + "After a restart, an iPhone or iPad appears only once it’s unlocked, and a Mac that starts up "
                        + "normally doesn’t appear at all, so check the device itself.")
    }

    /// After Enter DFU: the device in DFU mode.
    nonisolated static func dfu(of device: USBDevice, timeout: Duration = .seconds(30)) -> Self {
        Self(ecid: device.normalizedECID, previousID: device.id, modes: [.dfu], timeout: timeout,
             notBackMessage: "The device didn’t come back in DFU mode within \(timeout.wholeSeconds) seconds. Check the device; it may have restarted instead.")
    }

    /// After a Restore: the device started up.
    nonisolated static func restore(ecid: String, timeout: Duration = .seconds(120)) -> Self {
        Self(ecid: Configurator.normalizedECID(ecid), previousID: nil, modes: [.normal], timeout: timeout,
             notBackMessage: "Apple Configurator finished, but the device hasn’t appeared on USB in normal mode within \(timeout.wholeSeconds) seconds. Check the device: it may still be starting up, or be stuck in Recovery mode.")
    }

    /// The same expectation for the short watch after a missed reply.
    nonisolated func afterMissedReply(timeout: Duration = .seconds(30)) -> Self {
        Self(ecid: ecid, previousID: previousID, modes: modes, timeout: timeout,
             notBackMessage: "The device didn’t confirm the command and hasn’t come back within \(timeout.wholeSeconds) seconds. Check the device and try again if needed.")
    }
}

private extension Duration {
    nonisolated var wholeSeconds: Int64 { components.seconds }
}
