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

    @Test("After a Restore, the restore OS on its way (product ID 0x12AC) isn't the device being back")
    func restoreOSIsNotBack() async {
        let list = List()
        let start = Date.now
        let expectation = DeviceReturnExpectation.restore(ecid: "0x1A2B3C4D5E6F70", timeout: .milliseconds(100))
        // The restore OS: booted range, same ECID, connected after the restore started.
        let restoreOS = USBDevice(id: 20, mode: .normal, productID: 0x12AC, usbProductName: "iPhone", descriptor: nil,
                                  udid: "00008140-\(Self.ecid)", modelInfo: nil, connectedAt: .now)
        list.devices = [restoreOS]
        #expect(await watch(list).wait(for: expectation, since: start) == .notBack(expectation.notBackMessage))
        // The device started up: another booted product ID.
        list.devices = [restoreOS, Self.booted(id: 21, at: .now)]
        #expect(await watch(list).wait(for: expectation, since: start) == .back)
    }

    @Test("The expected modes per action")
    func expectedModes() {
        #expect(DeviceReturnExpectation.restart(of: Self.booted()).modes == [.normal])
        // Without a known model it may be a Mac, which starts up instead (a known model: see restartNotSeenIsNotAFailure).
        #expect(DeviceReturnExpectation.restart(of: Self.recovery(id: 1, ecid: Self.ecid)).modes == [.recovery, .normal])
        #expect(DeviceReturnExpectation.restart(of: Self.dfu(id: 1, ecid: Self.ecid)).modes == [.normal, .recovery])
        #expect(DeviceReturnExpectation.dfu(of: Self.booted()).modes == [.dfu])
        #expect(DeviceReturnExpectation.dfu(of: Self.booted()).timeout == .seconds(30))
        #expect(DeviceReturnExpectation.restore(ecid: "0x1A2B3C4D5E6F70").modes == [.normal])
        #expect(DeviceReturnExpectation.restore(ecid: "0x1A2B3C4D5E6F70").ecid == Self.ecid)
        #expect(DeviceReturnExpectation.dfu(of: Self.booted(), timeout: .seconds(90)).afterMissedReply().timeout == .seconds(30))
        #expect(DeviceReturnExpectation.dfu(of: Self.booted()).timeoutText == "30 seconds")
        #expect(DeviceReturnExpectation.restart(of: Self.booted()).timeoutText == "2 minutes")
        #expect(DeviceReturnExpectation.restart(of: Self.booted()).mayStayHidden)
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
        await actions.currentTask?.value
        await actions.currentWaitTask?.value
        #expect(actions.returnWaits.last?.state == .failed(DeviceReturnExpectation.dfu(of: device).notBackMessage))
        #expect(log.entries.contains { $0.detail.hasPrefix("Sent Enter DFU to") && $0.isFailure })

        // It comes back.
        actions.returnWatch = watch(list)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            list.devices = [Self.dfu(id: 11, ecid: Self.ecid)]
        }
        actions.enterDFU(device: device)
        await actions.currentTask?.value
        await actions.currentWaitTask?.value
        #expect(actions.returnWaits.last?.state == .back)
        #expect(actions.lastError == nil)
        #expect(log.entries.contains { $0.detail.hasPrefix("Put ") && !$0.isFailure })
        #expect(hardware.calls.filter { $0.hasPrefix("VDM dfu") }.count == 2)
        // Dismiss takes a finished result away.
        let ids = actions.returnWaits.map(\.id)
        ids.forEach(actions.dismissWait)
        #expect(actions.returnWaits.isEmpty)
    }

    @Test("While the app waits for a restarted device, other devices can be used; the wait says how long")
    func waitDoesNotBlock() async throws {
        let hardware = TrapHardware()
        let list = List()
        let actions = controller(hardware, list, log: ActivityLog())
        actions.returnWatch = DeviceReturnWatch(devices: { list.devices }, interval: .milliseconds(5))
        actions.restart(device: Self.booted(id: 0x1000_0A01, at: .distantPast))
        await actions.currentTask?.value
        // The command went out; the wait runs on its own.
        #expect(actions.runningAction == nil)
        #expect(actions.returnWaits.first?.state == .waiting)
        #expect(actions.returnWaits.first?.waitingText.hasPrefix("Waiting up to 2 minutes for ") == true)
        // Another device meanwhile.
        actions.enterDFU(device: Self.recovery(id: 0x1000_0B02, ecid: Self.otherECID, at: .distantPast))
        await actions.currentTask?.value
        #expect(hardware.calls.contains("VDM dfu 10000b02"))
        #expect(actions.returnWaits.count == 2)
        #expect(actions.returnWaits.last?.waitingText.contains("up to 30 seconds") == true)
        #expect(actions.returnWaits.last?.waitingText.hasSuffix("in DFU mode") == true)
        // Stop Waiting on both: sent, not confirmed.
        for wait in actions.returnWaits { actions.stopWaiting(wait.id) }
        await actions.currentWaitTask?.value
        try await Task.sleep(for: .milliseconds(50))
        #expect(actions.returnWaits.allSatisfy {
            if case .notConfirmed = $0.state { true } else { false }
        })
    }

    @Test("A restarted device that stays off USB (locked, or a Mac) is sent, not confirmed: orange, never failed")
    func restartNotSeenIsNotAFailure() async throws {
        let hardware = TrapHardware()
        let list = List()
        let log = ActivityLog()
        let actions = controller(hardware, list, log: log)
        actions.returnWatch = DeviceReturnWatch(devices: { list.devices }, interval: .milliseconds(5),
                                                maximumWait: .milliseconds(50))

        actions.restart(device: Self.booted(at: .distantPast))
        await actions.currentTask?.value
        await actions.currentWaitTask?.value
        #expect(actions.returnWaits.last?.state == .notConfirmed(DeviceReturnExpectation.unlockToSee))
        #expect(actions.lastError == nil)
        #expect(log.entries.last?.isFailure == false)
        #expect(log.entries.last?.isWarning == true)
        #expect(log.entries.last?.detail.hasSuffix("not confirmed") == true)

        // A device in DFU whose model isn't known may be a Mac: the same, with a word about Macs.
        let unknownDFU = Self.dfu(id: 0x1000_0C03, ecid: Self.otherECID, at: .distantPast)
        #expect(DeviceReturnExpectation.restart(of: unknownDFU).mayStayHidden)
        actions.restart(device: unknownDFU)
        await actions.currentTask?.value
        await actions.currentWaitTask?.value
        #expect(actions.returnWaits.last?.state
                == .notConfirmed(DeviceReturnExpectation.unlockToSee + DeviceReturnExpectation.macMayBeHidden))
        #expect(!log.entries.contains { $0.isFailure })

        // A known iPhone in Recovery stays in Recovery: not coming back there is a failure.
        let known = USBDevice(id: 0x1000_0D04, mode: .recovery, productID: 0x1281, usbProductName: "Recovery",
                              descriptor: DescriptorParser.parse("CPID:8140 BDID:08 ECID:\(Self.ecid)"), udid: nil,
                              modelInfo: ModelInfo(identifier: "iPhone10,1", marketingName: nil), connectedAt: .distantPast)
        #expect(!DeviceReturnExpectation.restart(of: known).mayStayHidden)
        #expect(DeviceReturnExpectation.restart(of: known).modes == [.recovery])
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
        await actions.currentWaitTask?.value
        #expect(actions.returnWaits.last?.state == .back)
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
