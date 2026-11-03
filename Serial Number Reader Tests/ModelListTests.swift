import Testing
@testable import Serial_Number_Reader

/// The Apple silicon Macs of 2020–2021 in `AppleDeviceModels.json`: each
/// CPID/BDID pair a Recovery or DFU descriptor reports resolves to its model.
@Suite("Model list: M1 Macs")
struct ModelListTests {
    @Test("Each M1 Mac resolves from its CPID and BDID, as a Mac", arguments: [
        ("8103", "22", "Macmini9,1", "Mac mini (M1, 2020)"),
        ("8103", "24", "MacBookPro17,1", "MacBook Pro (13-inch, M1, 2020)"),
        ("8103", "26", "MacBookAir10,1", "MacBook Air (M1, 2020)"),
        ("8103", "28", "iMac21,1", "iMac (24-inch, M1, Two Ports, 2021)"),
        ("8103", "2A", "iMac21,2", "iMac (24-inch, M1, Four Ports, 2021)"),
        ("6000", "08", "MacBookPro18,3", "MacBook Pro (14-inch, M1 Pro, 2021)"),
        ("6001", "08", "MacBookPro18,4", "MacBook Pro (14-inch, M1 Max, 2021)"),
        ("6000", "0A", "MacBookPro18,1", "MacBook Pro (16-inch, M1 Pro, 2021)"),
        ("6001", "0A", "MacBookPro18,2", "MacBook Pro (16-inch, M1 Max, 2021)"),
    ])
    func resolves(cpid: String, bdid: String, identifier: String, name: String) throws {
        let model = try #require(ModelDatabase.shared.model(cpidHex: cpid, bdidHex: bdid))
        #expect(model.identifier == identifier)
        #expect(model.marketingName == name)
        #expect(model.isMac)
        // As a Recovery or DFU descriptor reports it.
        let parsed = DescriptorParser.parse("CPID:\(cpid) BDID:\(bdid) ECID:001A2B3C4D5E6F70 SRNM:[PLACEHOLDR31]")
        #expect(ModelDatabase.shared.model(cpidHex: parsed.cpid, bdidHex: parsed.bdid)?.identifier == identifier)
    }

    @Test("An M1 Mac in Recovery also looks for a computer in Jamf Pro")
    func m1MacLooksForComputer() {
        let descriptor = DescriptorParser.parse("CPID:8103 BDID:28 ECID:001A2B3C4D5E6F70 SRNM:[PLACEHOLDR32]")
        let device = USBDevice(id: 1, mode: .recovery, productID: 0x1281, usbProductName: nil, descriptor: descriptor,
                               udid: nil, modelInfo: ModelDatabase.shared.model(cpidHex: "8103", bdidHex: "28"),
                               connectedAt: .now)
        #expect(device.modelDisplayName == "iMac (24-inch, M1, Two Ports, 2021)")
        #expect(device.computerLookup == .always)
    }
}
