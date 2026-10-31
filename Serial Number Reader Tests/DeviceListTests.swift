import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Serial_Number_Reader

/// The device list: rows arriving and leaving, what the CSV exports, and the
/// words shown when a serial number isn't known. Placeholder identifiers.
@MainActor
@Suite("Device list")
struct DeviceListTests {

    /// A DFU device Apple Configurator identified: no descriptor, so its UDID
    /// comes from Configurator.
    private let identifiedDFU = USBDevice(
        id: 0x1000_0C01, mode: .dfu, productID: 0x1881, usbProductName: "Debug USB",
        descriptor: nil, udid: nil, modelInfo: nil,
        configurator: ConfiguratorDevice(ecid: "0x1A2B3C4D5E6F70", udid: "00008140-001A2B3C4D5E6F70",
                                         deviceType: "iPhone17,3", locationID: 0x0130_0000),
        connectedAt: .now)

    private func recovery(id: UInt64, serial: String = "PLACEHOLDR09") -> USBDevice {
        USBDevice(id: id, mode: .recovery, productID: 0x1281, usbProductName: "Apple Mobile Device (Recovery Mode)",
                  descriptor: DescriptorParser.parse("CPID:8140 BDID:08 ECID:001A2B3C4D5E6F70 SRNM:[\(serial)]"),
                  udid: nil, modelInfo: nil, connectedAt: .now)
    }

    @Test("The CSV exports the UDID the detail view shows, also for a DFU device identified through Configurator")
    func csvUDID() {
        let row = SessionExport.row(for: identifiedDFU, jamf: .noMatch)
        #expect(identifiedDFU.udid == nil)
        #expect(row.udid == "00008140-001A2B3C4D5E6F70")
        #expect(row.udid == identifiedDFU.displayUDID)
        #expect(SessionExport.row(for: identifiedDFU, jamf: .notConfigured).jamfStatus == "No connection")
    }

    @Test("Unplugging keeps the row; plugging back in replaces the same device's old row only")
    func rowsCollapse() {
        let monitor = USBDeviceMonitor(hardware: NoUSBHardware())
        monitor.add(recovery(id: 1))
        monitor.add(recovery(id: 2, serial: "PLACEHOLDR10"))
        monitor.markDisconnected(entryID: 1)
        #expect(monitor.devices.count == 2)
        #expect(monitor.devices.first { $0.id == 1 }?.isConnected == false)
        #expect(monitor.devices.first { $0.id == 1 }?.disconnectedAt != nil)

        // The same device again (a new IORegistry entry): its stale row goes, the other stays.
        monitor.add(recovery(id: 3))
        #expect(monitor.devices.map(\.id) == [3, 2])

        // A re-published entry keeps the details already read from the device.
        var withDetails = identifiedDFU
        monitor.add(withDetails)
        withDetails.configurator = nil
        monitor.add(withDetails)
        #expect(monitor.devices.first { $0.id == identifiedDFU.id }?.configurator != nil)
        monitor.markDisconnected(entryID: 999) // unknown: nothing happens
        #expect(monitor.devices.count == 3)
    }

    @Test("The sidebar and the detail view use the same words for a serial only Jamf can give")
    func serialWords() {
        let states: [JamfLookupState] = [.notConfigured, .loading, .noMatch, .multipleMatches(2), .failed("x"),
                                         .unavailable("The device reported no UDID")]
        let words = states.map(\.serialUnavailableText)
        #expect(words == ["No Jamf connection in use", "Waiting for the Jamf lookup", "No matching Jamf record",
                          "Several Jamf records match", "The Jamf lookup failed", "The device reported no UDID"])
        #expect(recovery(id: 4).serialStatusText == "PLACEHOLDR09")
        let noSerial = USBDevice(id: 5, mode: .recovery, productID: 0x1281, usbProductName: nil,
                                 descriptor: DescriptorParser.parse("CPID:8140 BDID:08"), udid: nil,
                                 modelInfo: nil, connectedAt: .now)
        #expect(noSerial.serialStatusText == USBDevice.noSRNM)
    }

    @Test("Test Connection succeeds with JTKit's words")
    func testConnectionWords() async throws {
        let server = MockServer { request in
            request.path == "/api/oauth/token" ? .json(200, #"{"access_token": "t", "expires_in": 1200}"#) : .json(200, "{}")
        }
        let store = JamfStore(connections: .forUnitTestHost(), session: server.session)
        let record = JamfConnection(name: "Test", service: .jamfPro, signIn: .apiClient,
                                    serverURL: "pro.example.com", clientID: "client")
        #expect(try await store.testConnection(record, typedSecret: "secret") == "Connected · Jamf Pro")
        await #expect(throws: JamfSetupError(message: "Fill in the server URL and credentials first.")) {
            try await store.testConnection(record, typedSecret: "")
        }
    }

    // MARK: Previews

    @Test("Xcode's previews never reach a real device or the saved connections")
    func previewsStayAway() async {
        let monitor = USBDeviceMonitor.preview
        #expect(monitor.demo?.isOn == true)
        // Even with demo mode off, it doesn't watch USB.
        let demoOff = USBDeviceMonitor(hardware: LiveUSBHardware(underTest: USBGuard(isActive: true, log: .usb)),
                                       underTest: true)
        demoOff.start()
        defer { demoOff.stop() }
        #expect(!demoOff.isWatchingUSB)
        #expect(!JamfStore.preview.connections.holdsSavedConnections)
        #expect(JamfStore.preview.demoConnection != nil)

        let actions = DeviceActionController.preview
        #expect(!actions.isConfiguratorAvailable || PreviewSupport.usb.isOn)
        let hardware = NoUSBHardware()
        #expect(hardware.runPrivilegedVDM("reboot") == .failed(NoUSBHardware.refusal))
        #expect(hardware.sendRecoveryCommands(["reboot"], toRegistryEntryID: 1) == NoUSBHardware.refusal)
        #expect(throws: Configurator.Failure.self) { try hardware.enterRecovery(udid: "x") }
        #expect(throws: Configurator.Failure.self) { try hardware.listConfiguratorDevices() }
    }

    @Test("A test's settings domain is never the real settings")
    func testSettingsNeverReal() {
        // UserDefaults refuses the global domain as a suite: the test gets nil, not `.standard`.
        #expect(TemporaryDefaults.suite("NSGlobalDomain") == nil)
        let settings = TemporaryDefaults("device-list")
        defer { settings.remove() }
        #expect(settings.defaults !== UserDefaults.standard)
    }
}
