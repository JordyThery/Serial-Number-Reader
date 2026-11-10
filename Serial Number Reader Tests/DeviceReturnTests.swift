import Foundation
import JTKit
import Testing
@testable import Serial_Number_Reader

/// After Restart, Enter DFU and Restore the app reports success only once
/// the same device (by ECID) is back in the expected mode.
@MainActor
@Suite("Waiting for the same device to come back")
struct DeviceReturnTests {
    /// Placeholder identifiers only.
    private static let ecid = "001A2B3C4D5E6F70"
    private static let otherECID = "00F0E0D0C0B0A090"

    private static func booted(id: UInt64 = 0x1000_0A01, ecid: String = ecid, at date: Date = .now) -> USBDevice {
        USBDevice(id: id, mode: .normal, productID: 0x12A8, usbProductName: "iPhone", descriptor: nil,
                  udid: "00008140-\(ecid)", modelInfo: nil, connectedAt: date)
    }

    private static func dfu(id: UInt64, ecid: String?, at date: Date = .now) -> USBDevice {
        var device = USBDevice(id: id, mode: .dfu, productID: 0x1881, usbProductName: "Debug USB", descriptor: nil,
                               udid: nil, modelInfo: nil, connectedAt: date)
        if let ecid {
            device.configurator = ConfiguratorDevice(ecid: Configurator.cfgutilECID(ecid), udid: nil, deviceType: nil, locationID: nil)
        }
        return device
    }

    private static func recovery(id: UInt64, ecid: String, at date: Date = .now) -> USBDevice {
        USBDevice(id: id, mode: .recovery, productID: 0x1281, usbProductName: "Apple Mobile Device (Recovery Mode)",
                  descriptor: DescriptorParser.parse("CPID:8140 BDID:08 ECID:\(ecid) SRNM:[PLACEHOLDR07]"),
                  udid: nil, modelInfo: nil, connectedAt: date)
    }

    /// A watch over a list the test changes; tiny intervals.
    private final class List { var devices: [USBDevice] = [] }
    private func watch(_ list: List) -> DeviceReturnWatch {
        DeviceReturnWatch(devices: { list.devices }, interval: .milliseconds(5), identifyGrace: .milliseconds(50))
    }

    @Test("The same ECID back in the expected mode counts; the old row, another device or another mode don't")
    func sameDeviceBack() async {
        let list = List()
        let start = Date.now
        let before = Self.booted(at: start.addingTimeInterval(-60))
        let expectation = DeviceReturnExpectation.dfu(of: before, timeout: .milliseconds(200))
        #expect(expectation.ecid == Self.ecid)

        // Only the old row, another device in DFU, and the same device in Recovery: not back.
        list.devices = [before, Self.dfu(id: 2, ecid: Self.otherECID), Self.recovery(id: 3, ecid: Self.ecid)]
        #expect(await watch(list).wait(for: expectation, since: start) == .notBack(expectation.notBackMessage))

        // A row from before the action doesn't count either.
        list.devices = [Self.dfu(id: 4, ecid: Self.ecid, at: start.addingTimeInterval(-1))]
        #expect(await watch(list).wait(for: expectation, since: start) == .notBack(expectation.notBackMessage))

        // Disconnected rows don't count.
        var gone = Self.dfu(id: 5, ecid: Self.ecid)
        gone.isConnected = false
        list.devices = [gone]
        #expect(await watch(list).wait(for: expectation, since: start) == .notBack(expectation.notBackMessage))

        list.devices = [before, Self.dfu(id: 6, ecid: Self.ecid)]
        #expect(await watch(list).wait(for: expectation, since: start) == .back)
    }

    @Test("It keeps watching until the device appears")
    func appearsLater() async {
        let list = List()
        let start = Date.now
        let expectation = DeviceReturnExpectation.restart(of: Self.recovery(id: 1, ecid: Self.ecid), timeout: .seconds(5))
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            list.devices = [Self.recovery(id: 7, ecid: Self.ecid)]
        }
        #expect(await watch(list).wait(for: expectation, since: start) == .back)
    }

    @Test("A device in the expected mode without a readable ECID is back, but not confirmed")
    func unconfirmed() async {
        let list = List()
        let start = Date.now
        list.devices = [Self.dfu(id: 8, ecid: nil)]
        let result = await watch(list).wait(for: .dfu(of: Self.booted(), timeout: .seconds(5)), since: start)
        #expect(result == .backUnconfirmed(DeviceReturnResult.unconfirmedNote))

        // Before the action the ECID wasn't known (an older device): any device in the mode, unconfirmed.
        let older = USBDevice(id: 9, mode: .normal, productID: 0x12A8, usbProductName: "iPhone", descriptor: nil,
                              udid: "0123456789abcdef0123456789abcdef01234567", modelInfo: nil, connectedAt: .distantPast)
        let expectation = DeviceReturnExpectation.dfu(of: older, timeout: .seconds(5))
        #expect(expectation.ecid == nil)
        guard case .backUnconfirmed = await watch(list).wait(for: expectation, since: start) else {
            Issue.record("Expected an unconfirmed return")
            return
        }
    }

    @Test("The expected modes per action")
    func expectedModes() {
        #expect(DeviceReturnExpectation.restart(of: Self.booted()).modes == [.normal])
        #expect(DeviceReturnExpectation.restart(of: Self.recovery(id: 1, ecid: Self.ecid)).modes == [.recovery])
        #expect(DeviceReturnExpectation.restart(of: Self.dfu(id: 1, ecid: Self.ecid)).modes == [.normal, .recovery])
        #expect(DeviceReturnExpectation.dfu(of: Self.booted()).modes == [.dfu])
        #expect(DeviceReturnExpectation.dfu(of: Self.booted()).timeout == .seconds(30))
        #expect(DeviceReturnExpectation.restore(ecid: "0x1A2B3C4D5E6F70").modes == [.normal])
        #expect(DeviceReturnExpectation.restore(ecid: "0x1A2B3C4D5E6F70").ecid == Self.ecid)
        #expect(DeviceReturnExpectation.dfu(of: Self.booted(), timeout: .seconds(90)).afterMissedReply().timeout == .seconds(30))
    }

    // MARK: The actions

    private func controller(_ hardware: TrapHardware, _ list: List, log: ActivityLog) -> DeviceActionController {
        let actions = DeviceActionController(activityLog: log, hardware: hardware)
        actions.returnWatch = watch(list)
        return actions
    }

    @Test("Enter DFU succeeds only once the device is back in DFU mode, and fails clearly when it isn't")
    func enterDFUWaits() async throws {
        let hardware = TrapHardware()
        let list = List()
        let log = ActivityLog()
        let actions = controller(hardware, list, log: log)
        let device = Self.booted(at: .distantPast)

        // Nothing comes back (the 30 seconds cut short for the test).
        actions.returnWatch = DeviceReturnWatch(devices: { list.devices }, interval: .milliseconds(5),
                                                maximumWait: .milliseconds(100))
        actions.enterDFU(device: device)
        #expect(actions.runningAction == .dfu)
        await actions.currentTask?.value
        #expect(actions.lastError == DeviceReturnExpectation.dfu(of: device).notBackMessage)
        #expect(log.entries.contains { $0.detail.hasPrefix("Sent Enter DFU to") && $0.isFailure })

        // It comes back.
        actions.returnWatch = watch(list)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            list.devices = [Self.dfu(id: 11, ecid: Self.ecid)]
        }
        actions.enterDFU(device: device)
        await actions.currentTask?.value
        #expect(actions.lastError == nil)
        #expect(log.entries.contains { $0.detail.hasPrefix("Put ") && !$0.isFailure })
        #expect(hardware.calls.filter { $0.hasPrefix("VDM dfu") }.count == 2)
    }

    @Test("A missed reply is watched for a short time instead of failing at once")
    func missedReply() async throws {
        let hardware = TrapHardware()
        hardware.vdmOutcome = .replyMissed
        let list = List()
        let log = ActivityLog()
        let actions = controller(hardware, list, log: log)
        list.devices = [Self.recovery(id: 12, ecid: Self.ecid, at: .now.addingTimeInterval(5))]
        actions.restart(device: Self.recovery(id: 1, ecid: Self.ecid, at: .distantPast))
        await actions.currentTask?.value
        #expect(actions.lastError == nil)
        #expect(log.entries.contains { $0.detail.hasPrefix("Restarted") && !$0.isFailure })

        // Without a watch, a missed reply is reported as such.
        actions.returnWatch = nil
        actions.restart(device: Self.recovery(id: 1, ecid: Self.ecid, at: .distantPast))
        await actions.currentTask?.value
        #expect(actions.lastError?.hasPrefix(VDMToolReplyMissed) == true)
    }

    @Test("A refused port asks for no password and sends nothing")
    func refusedPort() {
        let hardware = TrapHardware()
        hardware.portCheck = .failure(.throughHub)
        let actions = DeviceActionController(hardware: hardware)
        actions.restart(device: Self.booted())
        actions.enterDFU(device: Self.booted())
        #expect(actions.runningAction == nil)
        #expect(actions.lastError == USBCPort.Refusal.throughHub.message)
        #expect(!hardware.calls.contains { $0.hasPrefix("VDM") })
        #expect(actions.portRefusal(for: Self.booted()) == .throughHub)
    }

    @Test("The helper is told which device: its registry entry ID")
    func entryIDPassed() async {
        let hardware = TrapHardware()
        let actions = DeviceActionController(hardware: hardware)
        actions.restart(device: Self.booted(id: 0x1000_0ABC))
        await actions.currentTask?.value
        #expect(hardware.calls.contains("VDM reboot 10000abc"))
    }

    @Test("A Restore succeeds once the device has started up; a Mac's isn't followed")
    func restoreWaits() async throws {
        let list = List()
        let restore = RestoreController(run: { _, _ in AsyncThrowingStream { $0.finish() } })
        restore.returnWatch = DeviceReturnWatch(devices: { list.devices }, interval: .milliseconds(5))
        list.devices = [Self.booted(id: 13, at: .now.addingTimeInterval(5))]
        let job = try #require(restore.start(.restore(ipsw: nil), ecid: Configurator.cfgutilECID(Self.ecid), deviceName: "iPhone"))
        await job.value
        #expect(restore.job?.state == .succeeded)
        #expect(restore.job?.note == nil)

        let mac = try #require(restore.start(.restore(ipsw: nil), ecid: Configurator.cfgutilECID(Self.otherECID),
                                             deviceName: "Mac", isMac: true))
        await mac.value
        #expect(restore.job?.state == .succeeded)
        #expect(restore.job?.note == RestoreController.macNotFollowed)
    }
}
