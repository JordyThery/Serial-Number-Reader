import Foundation
import JTKit
import Testing
@testable import Serial_Number_Reader

/// USB actions and restores write an "Action" entry to the activity log,
/// with the device's identifiers masked in the bug-report export.
@MainActor
@Suite("Device actions in the activity log")
struct DeviceActionLogTests {
    private let target = DeviceActionController.Target(name: "iPhone 16 (F9FXK2Q3HGMN)",
                                                       identifiers: ["F9FXK2Q3HGMN", "0x1A2B3C4D5E"])

    @Test("A done action is recorded, with its device masked in the export")
    func done() async {
        let log = ActivityLog()
        let actions = DeviceActionController(activityLog: log)
        await actions.start(.reboot, for: target) { .done }?.value

        let entry = try? #require(log.entries.first)
        #expect(log.entries.count == 1)
        #expect(entry?.category == "Action")
        #expect(entry?.detail == "Restarted iPhone 16 (F9FXK2Q3HGMN) over USB")
        #expect(entry?.service == "USB")
        #expect(entry?.isFailure == false)
        let masked = ActivityLogExport.text(log.entries, masked: true)
        #expect(!masked.contains("F9FXK2Q3HGMN"))
        #expect(!masked.contains("0x1A2B3C4D5E"))
    }

    @Test("A failed action is recorded as failed, with the reason")
    func failed() async {
        let log = ActivityLog()
        let actions = DeviceActionController(activityLog: log)
        await actions.start(.dfu, for: target) { .failed("The command failed (exit 1).") }?.value

        #expect(log.entries.first?.detail == "Couldn’t put iPhone 16 (F9FXK2Q3HGMN) into DFU mode over USB")
        #expect(log.entries.first?.note == "The command failed (exit 1).")
        #expect(log.entries.first?.isFailure == true)
        #expect(actions.lastError == "The command failed (exit 1).")
    }

    @Test("A device that doesn't trust this Mac is a failed Enter Recovery")
    func trustRequired() async {
        let log = ActivityLog()
        let actions = DeviceActionController(activityLog: log)
        await actions.start(.enterRecovery, for: target) { .trustRequired(deviceID: 9) }?.value
        #expect(log.entries.first?.isFailure == true)
        #expect(log.entries.first?.note == "The device doesn’t trust this Mac.")
        #expect(actions.trustRequiredDeviceID == 9)
    }

    @Test("A cancelled administrator prompt records nothing")
    func cancelled() async {
        let log = ActivityLog()
        let actions = DeviceActionController(activityLog: log)
        await actions.start(.reboot, for: target) { .cancelled }?.value
        #expect(log.entries.isEmpty)
        #expect(actions.lastError == nil)
    }

    @Test("Every action has its own words; Remove Trust is Apple Configurator's")
    func summaries() {
        let all: [DeviceActionController.Action] = [.reboot, .dfu, .enterRecovery, .bootNormal, .removeTrust]
        let done = Set(all.map { $0.summary("X", failed: false) })
        let failed = Set(all.map { $0.summary("X", failed: true) })
        #expect(done.count == all.count)
        #expect(failed.count == all.count)
        #expect(DeviceActionController.Action.removeTrust.service == "Apple Configurator")
    }

    @Test("A restore records its start and its end")
    func restore() async {
        let log = ActivityLog()
        let controller = RestoreController(activityLog: log) { _, _ in
            AsyncThrowingStream { continuation in
                continuation.yield(.step("Restoring"))
                continuation.finish()
            }
        }
        await controller.start(.restore(ipsw: nil), ecid: "0x1A2B3C4D5E", deviceName: "iPhone 16",
                               serialNumber: "F9FXK2Q3HGMN")?.value

        #expect(log.entries.map(\.detail) == [
            "Started to restore iPhone 16 (F9FXK2Q3HGMN) with Apple Configurator",
            "Restored iPhone 16 (F9FXK2Q3HGMN) with Apple Configurator",
        ])
        #expect(log.entries.first?.note == "Firmware: the latest signed version.")
        #expect(log.entries.allSatisfy { $0.category == "Action" && $0.service == "Apple Configurator" })
        #expect(!ActivityLogExport.text(log.entries, masked: true).contains("0x1A2B3C4D5E"))
    }

    @Test("A failed revive is recorded as failed")
    func failedRevive() async {
        struct Failure: LocalizedError { var errorDescription: String? { "cfgutil exited with 1" } }
        let log = ActivityLog()
        let controller = RestoreController(activityLog: log) { _, _ in
            AsyncThrowingStream { $0.finish(throwing: Failure()) }
        }
        await controller.start(.revive, ecid: "0x1A2B3C4D5E", deviceName: "iPad")?.value

        #expect(log.entries.last?.detail == "Couldn’t revive iPad with Apple Configurator")
        #expect(log.entries.last?.note == "cfgutil exited with 1")
        #expect(log.entries.last?.isFailure == true)
    }
}
