import Foundation
import JTKit
import Testing
@testable import Serial_Number_Reader

/// What keeps Restart, Enter DFU, Boot to Normal and the administrator prompt
/// aimed at the right device and the signed app. The hardware itself can't
/// run here; these are the rules the hardware code follows.
@MainActor
@Suite("Power action safeguards")
struct PowerActionSafetyTests {

    // MARK: Restart and Enter DFU: one port only

    @Test("The root helper sends Restart or Enter DFU only when exactly one USB-C port has something connected")
    func onePortOnly() {
        #expect(VDMTool.exitCode(forConnectedPorts: 1) == 0)
        #expect(VDMTool.refusal(forConnectedPorts: 1) == nil)
        // Nothing connected: code 2.
        #expect(VDMTool.exitCode(forConnectedPorts: 0) == 2)
        #expect(VDMTool.refusal(forConnectedPorts: 0) == "No device is connected to a USB-C port.")
        // A second device, a charger or a hub: refused, code 4, before anything is sent.
        for count in [2, 3, 8] {
            #expect(VDMTool.exitCode(forConnectedPorts: count) == 4)
            let message = VDMTool.refusal(forConnectedPorts: count) ?? ""
            #expect(message.hasPrefix("More than one USB-C port has something connected"))
            #expect(message.hasSuffix("try again."))
        }
    }

    @Test("A bad action never reaches a port")
    func unknownAction() {
        #expect(VDMTool.run(withAction: "restart-everything") == 1)
    }

    // MARK: Boot to Normal

    @Test("Any send error on reboot means the device took it; earlier commands stay strict")
    func rebootDetaches() {
        #expect(RecoveryCommands.failureMeansSent("reboot"))
        #expect(!RecoveryCommands.failureMeansSent("setenv auto-boot true"))
        #expect(!RecoveryCommands.failureMeansSent("saveenv"))
    }

    // MARK: The administrator prompt

    @Test("osascript's answer: done, cancelled at the prompt (nothing recorded), or the helper's message")
    func promptResults() {
        typealias Run = DeviceActionController
        #expect(Run.runResult(status: 0, errorText: "") == .success)
        #expect(Run.runResult(status: 1, errorText: "execution error: User canceled. (-128)") == .cancelled)
        #expect(Run.runResult(status: 1, errorText: "-128") == .cancelled)
        let refusal = VDMTool.refusal(forConnectedPorts: 2) ?? ""
        #expect(Run.runResult(status: 1, errorText: refusal) == .failure(refusal))
        #expect(Run.runResult(status: 3, errorText: "") == .failure("The command failed (exit 3)."))
    }

    @Test("Only the signed app on disk is ever run as root")
    func onlyTheSignedApp() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "snr-signature-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // A file that isn't code at all.
        let garbage = folder.appending(path: "Garbage")
        try Data("#!/bin/sh\necho swapped\n".utf8).write(to: garbage)
        #expect(DeviceActionController.signatureRefusal(executable: garbage.path, bundle: garbage)
                == DeviceActionController.unverifiedApp)

        // The app's own executable, copied out of its bundle and changed.
        let executable = try #require(Bundle.main.executableURL)
        var bytes = try Data(contentsOf: executable)
        bytes[bytes.count / 2] ^= 0xFF
        let swapped = folder.appending(path: "Swapped")
        try bytes.write(to: swapped)
        #expect(DeviceActionController.signatureRefusal(executable: swapped.path, bundle: swapped)
                == DeviceActionController.unverifiedApp)

        // The real bundle, but another executable than its own.
        #expect(DeviceActionController.signatureRefusal(executable: garbage.path, bundle: Bundle.main.bundleURL)
                == DeviceActionController.unverifiedApp)
    }

    // MARK: One thing at a time

    @Test("No action starts while a Restore or Revive runs, and no Restore while an action runs")
    func actionsAndRestoresExcludeEachOther() async throws {
        let hardware = TrapHardware()
        let actions = DeviceActionController(hardware: hardware)
        let (stream, continuation) = AsyncThrowingStream<ConfiguratorEvent, any Error>.makeStream()
        let restore = RestoreController(run: { _, _ in stream })
        actions.restore = restore
        restore.actions = actions

        let job = try #require(restore.start(.revive, ecid: "0x1A2B3C4D5E6F70", deviceName: "iPad"))
        actions.restart(device: recoveryDevice)
        #expect(actions.runningAction == nil)
        #expect(actions.lastError == DeviceActionController.restoreRunning)
        #expect(!hardware.calls.contains("VDM reboot"))
        continuation.finish()
        await job.value

        // And the other way round: an action holds the Restore back.
        actions.start(.reboot, for: .init(name: "iPad", identifiers: [])) {
            Thread.sleep(forTimeInterval: 0.3)
            return .done
        }
        #expect(actions.runningAction == .reboot)
        #expect(restore.start(.revive, ecid: "0x1A2B3C4D5E6F70", deviceName: "iPad") == nil)
        #expect(restore.refusal == "Another USB action is still running. Wait until it finishes, then try again.")
        await actions.currentTask?.value
    }

    @Test("Apple Configurator is looked for on disk at most every few seconds, not on every redraw")
    func configuratorCheckIsKept() {
        let hardware = TrapHardware()
        var now = Date(timeIntervalSinceReferenceDate: 0)
        let actions = DeviceActionController(hardware: hardware, now: { now })
        for _ in 0..<50 { _ = actions.isConfiguratorAvailable }
        #expect(hardware.calls.filter { $0 == "Configurator lookup" }.count == 1)
        now += DeviceActionController.configuratorCheckLifetime + 1
        _ = actions.isConfiguratorAvailable
        #expect(hardware.calls.filter { $0 == "Configurator lookup" }.count == 2)
    }

    // MARK: Blocking work

    @Test("A program that writes a lot to both outputs never blocks on a full pipe")
    func bothPipesDrained() throws {
        // 256 KB on each output: far beyond a pipe's 64 KB buffer.
        let script = "head -c 262144 /dev/zero | tr '\\0' o; head -c 262144 /dev/zero | tr '\\0' e >&2; exit 3"
        let result = try ProcessOutput.run(URL(fileURLWithPath: "/bin/sh"), ["-c", script])
        #expect(result.status == 3)
        #expect(result.output.count == 262_144)
        #expect(result.errors.count == 262_144)
    }

    @Test("Blocking work runs off Swift's shared threads and hands back its result or error")
    func blockingWork() async throws {
        // More waits than a Mac has cores, at once: they don't hold each other up.
        let started = ContinuousClock.now
        try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<32 {
                group.addTask {
                    await BlockingWork.run { Thread.sleep(forTimeInterval: 0.2); return index }
                }
            }
            var sum = 0
            for try await value in group { sum += value }
            #expect(sum == (0..<32).reduce(0, +))
        }
        #expect(started.duration(to: .now) < .seconds(3))
        await #expect(throws: Configurator.Failure.self) {
            try await BlockingWork.run { () throws -> Int in throw Configurator.Failure(message: "no") }
        }
    }
}

/// A real device in Recovery mode (placeholder identifiers).
private let recoveryDevice = USBDevice(
    id: 0x1000_0B01, mode: .recovery, productID: 0x1281, usbProductName: "Apple Mobile Device (Recovery Mode)",
    descriptor: DescriptorParser.parse("CPID:8140 BDID:08 ECID:001A2B3C4D5E6F70 SRNM:[PLACEHOLDR07]"),
    udid: nil, modelInfo: nil, connectedAt: .now)
