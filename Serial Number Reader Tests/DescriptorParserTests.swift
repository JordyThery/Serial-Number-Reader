import Testing
@testable import Serial_Number_Reader

@Suite("Descriptor parsing")
struct DescriptorParserTests {

    // MARK: Recovery mode

    @Test("Recovery descriptor with bracketed SRNM and IMEI")
    func recoveryDescriptor() {
        let raw = "CPID:8110 CPRV:11 CPFM:03 SCEP:01 BDID:0C ECID:001A2B3C4D5E6F70 IBFL:3C SRNM:[F2LXK1ABCD6M] IMEI:[356728111234567]"
        let parsed = DescriptorParser.parse(raw)

        #expect(parsed.fields.count == 9)
        #expect(parsed.cpid == "8110")
        #expect(parsed.bdid == "0C")
        #expect(parsed.ecid == "001A2B3C4D5E6F70")
        // Brackets must be stripped.
        #expect(parsed.serialNumber == "F2LXK1ABCD6M")
        #expect(parsed.imei == "356728111234567")
        // Raw access and order preservation.
        #expect(parsed["CPRV"] == "11")
        #expect(parsed.fields.first?.key == "CPID")
        #expect(parsed.fields.last?.key == "IMEI")
    }

    @Test("Unbracketed SRNM is also accepted")
    func unbracketedSerial() {
        let parsed = DescriptorParser.parse("CPID:8030 BDID:04 SRNM:C8QZX0LMN72J")
        #expect(parsed.serialNumber == "C8QZX0LMN72J")
    }

    // MARK: DFU mode

    @Test("DFU descriptor has no SRNM but exposes CPID/BDID/ECID")
    func dfuDescriptor() {
        let raw = "CPID:8110 CPRV:11 CPFM:01 SCEP:01 BDID:0C ECID:001A2B3C4D5E6F70 IBFL:3C SRTG:[iBoot-8419.0.0.100.5]"
        let parsed = DescriptorParser.parse(raw)

        #expect(parsed.serialNumber == nil)
        #expect(parsed.cpid == "8110")
        #expect(parsed.bdid == "0C")
        #expect(parsed.ecid == "001A2B3C4D5E6F70")
        #expect(parsed.bootTag == "iBoot-8419.0.0.100.5")
    }

    // MARK: Missing / malformed SRNM

    @Test("Missing SRNM reports nil, never a guess")
    func missingSerial() {
        let parsed = DescriptorParser.parse("CPID:8015 CPRV:11 CPFM:03 SCEP:01 BDID:02 ECID:000F00112233445A IBFL:3C")
        #expect(parsed.serialNumber == nil)
        #expect(parsed["SRNM"] == nil)
    }

    @Test("Empty bracketed SRNM is treated as missing")
    func emptySerial() {
        let parsed = DescriptorParser.parse("CPID:8015 BDID:02 SRNM:[] IMEI:[]")
        #expect(parsed["SRNM"] == "")       // field is present…
        #expect(parsed.serialNumber == nil) // …but the serial accessor treats it as missing
        #expect(parsed.imei == nil)
    }

    @Test("Garbage input produces no fields")
    func garbage() {
        #expect(DescriptorParser.parse("not a descriptor at all").fields.isEmpty)
        #expect(DescriptorParser.parse("").fields.isEmpty)
    }
}

@Suite("UDID normalisation")
struct UDIDNormalizationTests {

    @Test("24-hex-char UDID gets the 8-4 hyphen and uppercase")
    func modernUDID() {
        #expect(DescriptorParser.normalizedUDID("00008110001a2b3c4d5e6f70")
                == "00008110-001A2B3C4D5E6F70")
    }

    @Test("Already-hyphenated modern UDID is preserved")
    func hyphenatedUDID() {
        #expect(DescriptorParser.normalizedUDID("00008110-001A2B3C4D5E6F70")
                == "00008110-001A2B3C4D5E6F70")
    }

    @Test("Legacy 40-char UDID stays unhyphenated, lowercase")
    func legacyUDID() {
        let legacy = "a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0"
        #expect(DescriptorParser.normalizedUDID(legacy.uppercased()) == legacy)
    }

    @Test("Non-UDID strings are rejected")
    func invalidUDID() {
        #expect(DescriptorParser.normalizedUDID("F2LXK1ABCD6M") == nil)   // a serial number
        #expect(DescriptorParser.normalizedUDID("") == nil)
        #expect(DescriptorParser.normalizedUDID("zz008110001a2b3c4d5e6f70") == nil)
    }
}
