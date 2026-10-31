import Foundation
import Testing
@testable import Serial_Number_Reader

/// Lines below are real `cfgutil --progress --format JSON restore` output from
/// an iPad restore (ECID replaced).
@Suite("Configurator progress parsing")
struct ConfiguratorProgressTests {

    @Test("Steps and step completions are recognized")
    func steps() {
        #expect(Configurator.parseEvent(#"{"Devices":["0x0000000000ABCD"],"Type":"Step","Step":"Waiting for the device"}"#)
                == .step("Waiting for the device"))
        #expect(Configurator.parseEvent(#"{"Devices":["0x0000000000ABCD"],"Type":"StepComplete","Step":"Waiting for the device"}"#)
                == .stepComplete("Waiting for the device"))
    }

    @Test("Progress is a fraction, and -1 means no measurable progress")
    func progress() {
        let event = Configurator.parseEvent(#"{"Progress":0.0050005251091924992,"Type":"Progress","Step":"Step 3 of 4: Unzipping iPadOS"}"#)
        guard case .progress(let step, let fraction?) = event else {
            Issue.record("Expected a progress event, got \(String(describing: event))")
            return
        }
        #expect(step == "Step 3 of 4: Unzipping iPadOS")
        #expect(abs(fraction - 0.005) < 0.0001)
        #expect(Configurator.parseEvent(#"{"Progress":-1,"Type":"Progress","Step":"Waiting for the device"}"#)
                == .progress(step: "Waiting for the device", fraction: nil))
    }

    @Test("A clean CommandOutput finishes; one carrying an error reports it")
    func completion() {
        #expect(Configurator.parseEvent(#"{"Command":"restore","Type":"CommandOutput","Devices":["0x0000000000ABCD"]}"#)
                == .finished)
        // Assumed failure shape (not yet observed): an error dictionary per
        // device, like the one cfgutil uses for property errors.
        let failed = #"{"Command":"restore","Type":"CommandOutput","Output":{"0x0000000000ABCD":{"Domain":"com.apple.MobileDevice","Code":-1,"Message":"The device was disconnected."}}}"#
        #expect(Configurator.parseEvent(failed) == .error("The device was disconnected."))
    }

    @Test("Errors nested per device and per property are found")
    func nestedError() {
        // Shape cfgutil uses for `get` against an untrusted device.
        let data = Data(#"{"Type":"CommandOutput","Output":{"0x0000000000ABCD":{"activationState":{"Domain":"com.apple.configurator","Code":-402653034,"Message":"The user has not yet responded to the pairing request."}}}}"#.utf8)
        #expect(Configurator.errorMessage(in: data) == "The user has not yet responded to the pairing request.")
        #expect(Configurator.errorMessage(in: Data(#"{"Type":"CommandOutput","Output":{"0x1":{}}}"#.utf8)) == nil)
    }

    @Test("Non-JSON and unknown lines are ignored")
    func ignored() {
        #expect(Configurator.parseEvent("Restoring…") == nil)
        #expect(Configurator.parseEvent(#"{"Type":"Something"}"#) == nil)
    }
}

@Suite("Configurator devices and ECIDs")
struct ConfiguratorDeviceTests {

    @Test("Device list parses ECID, UDID, model and location")
    func list() throws {
        let data = Data(#"{"Command":"list","Output":{"0x1A2B3C4D5E6F70":{"locationID":34603008,"UDID":"00008130-001A2B3C4D5E6F70","ECID":"0x1A2B3C4D5E6F70","name":"iPad","deviceType":"iPad16,1"}},"Type":"CommandOutput","Devices":["0x1A2B3C4D5E6F70"]}"#.utf8)
        let devices = try Configurator.parseList(data)
        #expect(devices == [ConfiguratorDevice(ecid: "0x1A2B3C4D5E6F70", udid: "00008130-001A2B3C4D5E6F70",
                                               deviceType: "iPad16,1", locationID: 0x2100000)])
    }

    @Test("ECIDs from cfgutil and from the USB descriptor compare equal")
    func ecidNormalization() {
        #expect(Configurator.normalizedECID("0x1A2B3C4D5E6F70") == "001A2B3C4D5E6F70")
        #expect(Configurator.normalizedECID("001a2b3c4d5e6f70") == "001A2B3C4D5E6F70")
        #expect(Configurator.normalizedECID("not-hex") == nil)
        #expect(Configurator.cfgutilECID("001A2B3C4D5E6F70") == "0x1A2B3C4D5E6F70")
    }

    private let listed = [
        ConfiguratorDevice(ecid: "0x1A2B3C4D5E6F70", udid: nil, deviceType: "iPad16,1", locationID: 0x2100000),
        ConfiguratorDevice(ecid: "0x99887766554433", udid: nil, deviceType: "iPhone18,5", locationID: 0x100000),
    ]

    @Test("Rows link by ECID when known, otherwise by a unique location ID")
    func matching() {
        #expect(USBDeviceMonitor.configuratorMatch(in: listed, locationID: nil, ecid: "0099887766554433")?.deviceType == "iPhone18,5")
        #expect(USBDeviceMonitor.configuratorMatch(in: listed, locationID: 0x2100000, ecid: nil)?.deviceType == "iPad16,1")
        #expect(USBDeviceMonitor.configuratorMatch(in: listed, locationID: 0x9900000, ecid: nil) == nil)
    }

    @Test("An ambiguous location ID never links a row")
    func ambiguous() {
        let duplicated = listed + [ConfiguratorDevice(ecid: "0x1", udid: nil, deviceType: "iPad14,1", locationID: 0x2100000)]
        #expect(USBDeviceMonitor.configuratorMatch(in: duplicated, locationID: 0x2100000, ecid: nil) == nil)
    }

    @Test("A DFU device's UDID is derived from chip ID and ECID (Configurator reports none)")
    func derivedUDID() {
        var device = USBDevice(id: 1, mode: .dfu, productID: 0x1881, usbProductName: "Debug USB",
                               descriptor: nil, udid: nil, modelInfo: nil, connectedAt: .now)
        device.configurator = ConfiguratorDevice(ecid: "0x1A2B3C4D5E6F70", udid: nil, deviceType: "iPad16,1", locationID: 0x2100000)
        device.modelInfo = ModelDatabase.shared.model(identifier: "iPad16,1")
        #expect(device.displayUDID == "00008130-001A2B3C4D5E6F70")
        #expect(device.jamfQuery == .udid("00008130-001A2B3C4D5E6F70"))
    }

    @Test("Only chips with chip-ID/ECID UDIDs are derived")
    func derivableChips() {
        #expect(USBDevice.usesChipECIDUDID(0x8020))   // A12
        #expect(USBDevice.usesChipECIDUDID(0x8103))   // M1
        #expect(USBDevice.usesChipECIDUDID(0x6000))   // M1 Pro
        #expect(!USBDevice.usesChipECIDUDID(0x8015))  // A11: hashed UDID
        #expect(!USBDevice.usesChipECIDUDID(0x8011))  // A10X
    }

    @Test("A booted device's ECID comes from its UDID")
    func ecidFromUDID() {
        let device = USBDevice(id: 1, mode: .normal, productID: 0x12AB, usbProductName: "iPad",
                               descriptor: nil,
                               udid: "00008130-001A2B3C4D5E6F70", modelInfo: nil, connectedAt: .now)
        #expect(device.configuratorECID == "0x1A2B3C4D5E6F70")
    }
}

@Suite("IPSW checks")
struct IPSWInfoTests {

    @Test("The build manifest gives version, build and supported models")
    func manifest() throws {
        let info = try #require(IPSWInfo.parse(manifest: [
            "ProductVersion": "27.0.1",
            "ProductBuildVersion": "24A446",
            "SupportedProductTypes": ["iPad16,1", "iPad16,2"],
        ]))
        #expect(info.productVersion == "27.0.1")
        #expect(info.supports("iPad16,2"))
        #expect(!info.supports("iPhone18,5"))
    }

    @Test("A manifest without version information is rejected")
    func invalidManifest() {
        #expect(IPSWInfo.parse(manifest: ["SupportedProductTypes": ["iPad16,1"]]) == nil)
    }

    @Test("An IPSW is refused for another model, and when the model is unknown nothing is waved through")
    func modelCheck() throws {
        let info = try #require(IPSWInfo.parse(manifest: [
            "ProductVersion": "27.0.1", "ProductBuildVersion": "24A446", "SupportedProductTypes": ["iPad16,1"],
        ]))
        #expect(info.refusal(productType: "iPad16,1", deviceName: "iPad mini") == nil)
        #expect(info.refusal(productType: "iPhone18,5", deviceName: "iPhone")
                == "This IPSW doesn’t support iPhone (iPhone18,5).")
        // An unidentified DFU device: never "supports this device".
        #expect(info.refusal(productType: nil, deviceName: "Apple Device")
                == "The model of this device is unknown, so the IPSW couldn’t be checked. Use the latest available version instead.")
    }
}
