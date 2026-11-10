import Foundation
import JTKit
import Testing
@testable import Serial_Number_Reader

/// A made-up IORegistry: entries, their parents and the paths that resolve.
nonisolated final class FakePortRegistry: USBCPortRegistry, @unchecked Sendable {
    var entries: [UInt64: USBCPortRegistryEntry] = [:]
    var parents: [UInt64: UInt64] = [:]
    var paths: [String: UInt64] = [:]
    var controllers: [UInt64] = []

    func entry(id: UInt64) -> USBCPortRegistryEntry? { entries[id] }
    func entry(path: String) -> USBCPortRegistryEntry? { paths[path].flatMap { entries[$0] } }
    func parent(of entry: USBCPortRegistryEntry) -> USBCPortRegistryEntry? { parents[entry.id].flatMap { entries[$0] } }
    func controllerIDs() -> [UInt64] { controllers }

    func add(_ id: UInt64, parent: UInt64?, classes: Set<String> = [], _ properties: [String: USBCPortRegistryEntry.Value] = [:]) {
        entries[id] = USBCPortRegistryEntry(id: id, classes: classes, properties: properties)
        if let parent { parents[id] = parent }
    }

    func set(_ id: UInt64, _ key: String, _ value: USBCPortRegistryEntry.Value?) {
        guard let old = entries[id] else { return }
        var properties = old.properties
        properties[key] = value
        entries[id] = USBCPortRegistryEntry(id: id, classes: old.classes, properties: properties)
    }

    /// A Mac like the one in docs/usb-c-port-targeting.md: three USB-C ports
    /// (controllers with RID 0, 1, 2) and MagSafe (RID 5), each USB-C port
    /// with its own USB root port. Port 1 has a charger (active, no USB
    /// device); a device is on `devicePort`. Made-up IDs and paths.
    static func mac(devicePort: Int = 2, productID: Int = 0x12A8) -> FakePortRegistry {
        let registry = FakePortRegistry()
        registry.add(1, parent: nil)                                      // root of the plane
        registry.add(2, parent: 1)                                        // the SoC's I/O
        for (index, rid) in [(1, 0), (2, 1), (3, 2)] {
            let base = UInt64(index) * 100
            // Power side: controller → HAL → Port-USB-C@N.
            registry.add(base + 1, parent: 2, classes: ["AppleHPM"], ["RID": .number(rid)])
            registry.add(base + 2, parent: base + 1)
            registry.add(base + 3, parent: base + 2, [
                "Description": .string("Port-USB-C@\(index)"),
                "ConnectionActive": .bool(index == 1 || index == devicePort),
            ])
            registry.paths["IOService:/fake/hpm\(index)/Port-USB-C@\(index)"] = base + 3
            registry.controllers.append(base + 1)
            // USB side: controller → root port (UsbIOPort, port number as bytes).
            registry.add(base + 10, parent: 2)
            registry.add(base + 11, parent: base + 10, [
                "UsbIOPort": .string("IOService:/fake/hpm\(index)/Port-USB-C@\(index)"),
                "usb-c-port-number": .data(Data([UInt8(index), 0, 0, 0])),
            ])
        }
        // MagSafe: a controller with a port that isn't USB-C.
        registry.add(501, parent: 2, classes: ["AppleHPM"], ["RID": .number(5)])
        registry.add(503, parent: 501, ["Description": .string("Port-MagSafe 3@1"), "ConnectionActive": .bool(false)])
        registry.paths["IOService:/fake/hpm5/Port-MagSafe 3@1"] = 503
        registry.controllers.append(501)
        // The device, directly on the root port of its USB-C port.
        registry.add(deviceID, parent: UInt64(devicePort) * 100 + 11, classes: ["IOUSBHostDevice"],
                     ["idVendor": .number(0x05AC), "idProduct": .number(productID)])
        return registry
    }

    static let deviceID: UInt64 = 0x1000_0A2B
}

@Suite("Restart and Enter DFU go to the device's own USB-C port")
struct USBCPortTests {
    private func locate(_ registry: FakePortRegistry, appleSilicon: Bool = true) -> USBCPort.Check {
        USBCPort.locate(deviceEntryID: FakePortRegistry.deviceID, in: registry, isAppleSilicon: appleSilicon)
    }

    // MARK: Found

    @Test("A device directly on a port leads to that port's controller, whatever else is connected")
    func directPort() {
        // A charger on port 1 doesn't matter: port 1's controller is never chosen.
        #expect(locate(.mac(devicePort: 2)) == .success(.init(controllerID: 201, rid: 1, portNumber: 2)))
        #expect(locate(.mac(devicePort: 3)) == .success(.init(controllerID: 301, rid: 2, portNumber: 3)))
        #expect(locate(.mac(devicePort: 1)) == .success(.init(controllerID: 101, rid: 0, portNumber: 1)))
    }

    @Test("Booted, Recovery, classic DFU and Debug USB product IDs are accepted", arguments: [0x1290, 0x12A8, 0x12AF, 0x1281, 0x1227, 0x1881])
    func everyMode(productID: Int) {
        #expect(locate(.mac(productID: productID)) == .success(.init(controllerID: 201, rid: 1, portNumber: 2)))
    }

    @Test("A second device on another port gets its own port")
    func twoDevices() {
        let registry = FakePortRegistry.mac(devicePort: 2)
        registry.add(0x1000_0B01, parent: 311, classes: ["IOUSBHostDevice"],
                     ["idVendor": .number(0x05AC), "idProduct": .number(0x1281)])
        registry.set(303, "ConnectionActive", .bool(true))
        #expect(locate(registry) == .success(.init(controllerID: 201, rid: 1, portNumber: 2)))
        #expect(USBCPort.locate(deviceEntryID: 0x1000_0B01, in: registry, isAppleSilicon: true)
                == .success(.init(controllerID: 301, rid: 2, portNumber: 3)))
    }

    // MARK: Refused

    @Test("An Intel Mac is refused before anything is read")
    func intelMac() {
        #expect(locate(.mac(), appleSilicon: false) == .failure(.intelMac))
        #expect(USBCPort.Refusal.intelMac.message.contains("Apple silicon"))
    }

    @Test("A device that's gone, or isn't an Apple phone, tablet or Mac, is refused")
    func notTheDevice() {
        let registry = FakePortRegistry.mac()
        #expect(USBCPort.locate(deviceEntryID: 0xDEAD, in: registry, isAppleSilicon: true) == .failure(.deviceGone))

        let keyboard = FakePortRegistry.mac(productID: 0x0250)
        #expect(locate(keyboard) == .failure(.notAppleDevice))

        let otherVendor = FakePortRegistry.mac()
        otherVendor.set(FakePortRegistry.deviceID, "idVendor", .number(0x1234))
        #expect(locate(otherVendor) == .failure(.notAppleDevice))

        // An entry that isn't a USB device at all (e.g. the root port's own ID).
        #expect(USBCPort.locate(deviceEntryID: 211, in: registry, isAppleSilicon: true) == .failure(.notAppleDevice))
    }

    @Test("A device behind a hub is refused, even though the hub's own port is known")
    func throughHub() {
        let registry = FakePortRegistry.mac()
        // Root port 211 → hub (a USB device) → hub port (with a copied UsbIOPort, to be sure) → the device.
        registry.add(900, parent: 211, classes: ["IOUSBHostDevice"], ["idVendor": .number(0x05E3), "idProduct": .number(0x0610)])
        registry.add(901, parent: 900, ["UsbIOPort": .string("IOService:/fake/hpm2/Port-USB-C@2"),
                                        "usb-c-port-number": .number(2)])
        registry.parents[FakePortRegistry.deviceID] = 901
        #expect(locate(registry) == .failure(.throughHub))
        #expect(USBCPort.Refusal.throughHub.message.contains("directly"))
    }

    @Test("A root port without UsbIOPort (a dock, or a Mac that doesn't name its ports) is refused")
    func missingProperty() {
        let registry = FakePortRegistry.mac()
        registry.set(211, "UsbIOPort", nil)
        #expect(locate(registry) == .failure(.portUnknown))
        registry.set(211, "UsbIOPort", .string(""))
        #expect(locate(registry) == .failure(.portUnknown))
        #expect(USBCPort.Refusal.portUnknown.message.contains("directly"))
    }

    @Test("A device without a parent is refused")
    func noParent() {
        let registry = FakePortRegistry.mac()
        registry.parents[FakePortRegistry.deviceID] = nil
        #expect(locate(registry) == .failure(.portUnknown))
    }

    @Test("A path that doesn't resolve is refused")
    func pathDoesNotResolve() {
        let registry = FakePortRegistry.mac()
        registry.set(211, "UsbIOPort", .string("IOService:/fake/hpm9/Port-USB-C@9"))
        #expect(locate(registry) == .failure(.portUnknown))
    }

    @Test("A port that isn't USB-C is refused")
    func notUSBC() {
        let registry = FakePortRegistry.mac()
        registry.set(211, "UsbIOPort", .string("IOService:/fake/hpm5/Port-MagSafe 3@1"))
        #expect(locate(registry) == .failure(.portUnknown))
        registry.set(203, "Description", nil)
        registry.set(211, "UsbIOPort", .string("IOService:/fake/hpm2/Port-USB-C@2"))
        #expect(locate(registry) == .failure(.portUnknown))
    }

    @Test("A port number that doesn't match, or is missing, is refused")
    func portNumberMismatch() {
        let registry = FakePortRegistry.mac()
        registry.set(211, "usb-c-port-number", .data(Data([3, 0, 0, 0])))
        #expect(locate(registry) == .failure(.portUnknown))
        registry.set(211, "usb-c-port-number", nil)
        #expect(locate(registry) == .failure(.portUnknown))
        // As a plain number it counts too.
        registry.set(211, "usb-c-port-number", .number(2))
        #expect(locate(registry) == .success(.init(controllerID: 201, rid: 1, portNumber: 2)))
    }

    @Test("A port that reports no connection is refused")
    func portNotActive() {
        let registry = FakePortRegistry.mac()
        registry.set(203, "ConnectionActive", .bool(false))
        #expect(locate(registry) == .failure(.portNotActive))
        registry.set(203, "ConnectionActive", nil)
        #expect(locate(registry) == .failure(.portNotActive))
    }

    @Test("A port without an AppleHPM controller above it is refused")
    func noController() {
        let registry = FakePortRegistry.mac()
        registry.entries[201] = USBCPortRegistryEntry(id: 201, classes: [], properties: ["RID": .number(1)])
        #expect(locate(registry) == .failure(.portUnknown))
    }

    @Test("A controller that isn't listed exactly once among the AppleHPM services is refused")
    func controllerNotListedOnce() {
        let registry = FakePortRegistry.mac()
        registry.controllers.removeAll { $0 == 201 }
        #expect(locate(registry) == .failure(.portUnknown))
        registry.controllers += [201, 201]
        #expect(locate(registry) == .failure(.portUnknown))
    }

    @Test("A controller without a RID is refused")
    func noRID() {
        let registry = FakePortRegistry.mac()
        registry.set(201, "RID", nil)
        #expect(locate(registry) == .failure(.portUnknown))
    }

    @Test("A loop in the registry ends in a refusal")
    func loop() {
        let registry = FakePortRegistry.mac()
        registry.parents[2] = 211
        #expect(locate(registry) == .failure(.portUnknown))
    }
}

@Suite("The root helper's arguments and checks")
struct PrivilegedVDMTests {
    private let guardOff = USBGuard(isActive: false, log: .usb)

    @Test("Only the exact forms are accepted")
    func parse() {
        #expect(PrivilegedVDM.parse(["--vdm", "reboot"]) == .init(action: "reboot", deviceEntryID: nil))
        #expect(PrivilegedVDM.parse(["--vdm", "dfu", "--entry", "100000aa1"]) == .init(action: "dfu", deviceEntryID: 0x1_0000_0AA1))
        #expect(PrivilegedVDM.parse(["--vdm", "dfu", "--entry", "FFFFFFFFFFFFFFFF"]) == .init(action: "dfu", deviceEntryID: .max))
        for bad in [[], ["--vdm"], ["--vdm", "erase"], ["--vdm", "reboot", "--entry"],
                    ["--vdm", "reboot", "--entry", ""], ["--vdm", "reboot", "--entry", "0x1F"],
                    ["--vdm", "reboot", "--entry", "1FFFFFFFFFFFFFFFF"], ["--vdm", "reboot", "--entry", "12;rm"],
                    ["--vdm", "reboot", "--entry", "-1"], ["--vdm", "reboot", "--entry", "+1"],
                    ["--vdm", "reboot", "--entry", "１２"], ["--vdm", "reboot", "--port", "1"],
                    ["--vdm", "reboot", "--entry", "1", "--extra"], ["reboot", "--vdm"], ["-x", "--vdm", "reboot"]] {
            #expect(PrivilegedVDM.parse(bad) == nil, "\(bad)")
        }
        let round = PrivilegedVDM.commandArguments(action: "reboot", deviceEntryID: 0x1_0000_0AA1)
        #expect(round == ["--vdm", "reboot", "--entry", "100000aa1"])
        #expect(PrivilegedVDM.parse(round)?.deviceEntryID == 0x1_0000_0AA1)
    }

    @Test("Every refusal exits 5 with its message and sends nothing")
    func refusals() {
        let cases: [(FakePortRegistry, Bool, USBCPort.Refusal)] = {
            let hub = FakePortRegistry.mac()
            hub.add(900, parent: 211, classes: ["IOUSBHostDevice"])
            hub.add(901, parent: 900)
            hub.parents[FakePortRegistry.deviceID] = 901
            let unknown = FakePortRegistry.mac()
            unknown.set(211, "UsbIOPort", nil)
            let inactive = FakePortRegistry.mac()
            inactive.set(203, "ConnectionActive", .bool(false))
            return [(.mac(), false, .intelMac), (hub, true, .throughHub), (unknown, true, .portUnknown),
                    (inactive, true, .portNotActive)]
        }()
        for (registry, appleSilicon, refusal) in cases {
            var messages: [String] = []
            var sent = false
            let code = PrivilegedVDM.run(.init(action: "dfu", deviceEntryID: FakePortRegistry.deviceID),
                                         registry: registry, isAppleSilicon: appleSilicon, underTest: guardOff,
                                         send: { _, _, _ in sent = true; return 0 },
                                         sendWithoutDevice: { _ in sent = true; return 0 },
                                         error: { messages.append($0) })
            #expect(code == 5)
            #expect(!sent)
            #expect(messages == [refusal.message])
        }
        // A device that's gone.
        var sent = false
        #expect(PrivilegedVDM.run(.init(action: "reboot", deviceEntryID: 0xDEAD), registry: FakePortRegistry.mac(),
                                  isAppleSilicon: true, underTest: guardOff,
                                  send: { _, _, _ in sent = true; return 0 }, error: { _ in }) == 5)
        #expect(!sent)
    }

    @Test("The helper sends to the device's controller, and the last check before sending follows the device")
    func sendsToItsOwnPort() {
        let registry = FakePortRegistry.mac(devicePort: 3)
        var sentTo: UInt64?
        var recheck: (() -> Bool)?
        let code = PrivilegedVDM.run(.init(action: "reboot", deviceEntryID: FakePortRegistry.deviceID),
                                     registry: registry, isAppleSilicon: true, underTest: guardOff,
                                     send: { _, controller, check in sentTo = controller; recheck = check; return 0 },
                                     error: { _ in })
        #expect(code == 0)
        #expect(sentTo == 301)
        #expect(recheck?() == true)
        // Moved to another port (or behind a hub, or unplugged) after the check: the last check says no.
        registry.parents[FakePortRegistry.deviceID] = 211
        registry.set(203, "ConnectionActive", .bool(true))
        #expect(recheck?() == false)
        registry.entries[FakePortRegistry.deviceID] = nil
        #expect(recheck?() == false)
    }

    @Test("Without a device, the rule of one connected port applies; under tests nothing runs")
    func withoutDeviceAndUnderTest() {
        var withoutDevice: String?
        #expect(PrivilegedVDM.run(.init(action: "dfu", deviceEntryID: nil), registry: FakePortRegistry.mac(),
                                  isAppleSilicon: true, underTest: guardOff,
                                  send: { _, _, _ in 0 }, sendWithoutDevice: { withoutDevice = $0; return 4 },
                                  error: { _ in }) == 4)
        #expect(withoutDevice == "dfu")
        // Intel refuses this form too.
        #expect(PrivilegedVDM.run(.init(action: "dfu", deviceEntryID: nil), registry: FakePortRegistry.mac(),
                                  isAppleSilicon: false, underTest: guardOff,
                                  sendWithoutDevice: { _ in 0 }, error: { _ in }) == 5)
        // Under tests: refused before anything, and written down (in a log of this test's own).
        let folder = FileManager.default.temporaryDirectory.appending(path: "snr-vdm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = TestRun.AttemptLog(fileURL: folder.appending(path: "attempts.jsonl"))
        var sent = false
        #expect(PrivilegedVDM.run(.init(action: "dfu", deviceEntryID: FakePortRegistry.deviceID),
                                  registry: FakePortRegistry.mac(), isAppleSilicon: true,
                                  underTest: USBGuard(isActive: true, log: log),
                                  send: { _, _, _ in sent = true; return 0 }, error: { _ in }) == 2)
        #expect(!sent)
        #expect(log.attempts().map(\.what) == ["--vdm dfu"])
    }

    @Test("A missed reply is told apart from a failure")
    func missedReply() {
        #expect(DeviceActionController.runResult(status: 1, errorText: "0:1: execution error: \(VDMToolReplyMissed) (6)") == .replyMissed)
        #expect(DeviceActionController.runResult(status: 1, errorText: USBCPort.Refusal.throughHub.message)
                == .failure(USBCPort.Refusal.throughHub.message))
    }

    @Test("The buttons follow the port check: offered whatever else is connected, dimmed with a refusal")
    func availability() {
        let device = USBDevice(id: FakePortRegistry.deviceID, mode: .normal, productID: 0x12A8, usbProductName: "iPhone",
                               descriptor: nil, udid: "00008140-001A2B3C4D5E6F70", modelInfo: nil, connectedAt: .now)
        let open = DeviceActionAvailability(device: device, busy: false, editingAssetTag: false, portRefusal: nil,
                                            configuratorAvailable: true, jamfState: .notConfigured)
        #expect(open.restart && open.enterDFU)
        for refusal in [USBCPort.Refusal.intelMac, .throughHub, .portUnknown, .portNotActive, .deviceGone] {
            let closed = DeviceActionAvailability(device: device, busy: false, editingAssetTag: false, portRefusal: refusal,
                                                  configuratorAvailable: true, jamfState: .notConfigured)
            #expect(!closed.restart && !closed.enterDFU)
            #expect(closed.enterRecovery)
        }
    }
}
