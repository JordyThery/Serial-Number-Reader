import Foundation
import JTKit
import Testing
@testable import Serial_Number_Reader

@Suite("Lockdown device info")
struct LockdownDeviceInfoTests {

    @Test("Parses the values an unpaired iPad reports")
    func parsesIPad() {
        // Shape of a real unpaired GetValue reply (iPad mini A17 Pro).
        let info = LockdownDeviceInfo.parse([
            "ProductType": "iPad16,1",
            "ProductVersion": "27.0",
            "BuildVersion": "24A5430a",
            "DeviceClass": "iPad",
            "DeviceName": "Lab iPad",
            "ProductName": "iPhone OS",
            "ChipID": 33072,
        ])
        #expect(info.productType == "iPad16,1")
        #expect(info.deviceName == "Lab iPad")
        #expect(info.osDisplayName == "iPadOS 27.0 (24A5430a)")
    }

    @Test("OS name follows the device class, not ProductName")
    func osName() {
        let phone = LockdownDeviceInfo.parse(["ProductVersion": "26.6.1", "DeviceClass": "iPhone"])
        #expect(phone.osDisplayName == "iOS 26.6.1")
        let none = LockdownDeviceInfo.parse(["DeviceClass": "iPhone"])
        #expect(none.osDisplayName == nil)
    }

    @Test("Missing, empty or non-text values are treated as absent")
    func absentValues() {
        let info = LockdownDeviceInfo.parse(["DeviceName": "  ", "ProductType": 42])
        #expect(info.deviceName == nil)
        #expect(info.productType == nil)
    }
}

@Suite("Session export")
struct SessionExportTests {

    @Test("Plain fields are written as-is")
    func plain() {
        #expect(SessionExport.escape("F2LXK1ABCD6M") == "F2LXK1ABCD6M")
        #expect(SessionExport.escape("00008150-001A2B3C4D5E6F70") == "00008150-001A2B3C4D5E6F70")
    }

    @Test("Commas, quotes and line breaks are quoted per RFC 4180")
    func quoting() {
        #expect(SessionExport.escape("iPad16,1") == "\"iPad16,1\"")
        #expect(SessionExport.escape("Jordy's \"lab\" iPad") == "\"Jordy's \"\"lab\"\" iPad\"")
        #expect(SessionExport.escape("line\nbreak") == "\"line\nbreak\"")
        #expect(SessionExport.escape("line\rbreak") == "\"line\rbreak\"")
        #expect(SessionExport.escape("line\r\nbreak") == "\"line\r\nbreak\"")
    }

    @Test("Formula-like values are neutralised")
    func formulaInjection() {
        #expect(SessionExport.escape("=HYPERLINK(\"x\")") == "\"'=HYPERLINK(\"\"x\"\")\"")
        #expect(SessionExport.escape("+1") == "'+1")
        #expect(SessionExport.escape("@SUM") == "'@SUM")
    }

    @Test("CSV has a header, one line per row, and CRLF endings")
    func csvShape() {
        var row = SessionExport.Row()
        row.serialNumber = "ABC123"
        let csv = SessionExport.csv([row, row])
        let lines = csv.components(separatedBy: "\r\n")
        #expect(lines.count == 4) // header, two rows, trailing empty
        #expect(lines[0].hasPrefix("Connected,Disconnected,Mode"))
        #expect(lines[1].split(separator: ",", omittingEmptySubsequences: false).count == SessionExport.header.count)
        #expect(SessionExport.csvData([row]).starts(with: [0xEF, 0xBB, 0xBF]))
    }

    @Test("Serial list is unique and keeps session order")
    func serialList() {
        let rows = ["B", "", "A", "B"].map { serial -> SessionExport.Row in
            var row = SessionExport.Row()
            row.serialNumber = serial
            return row
        }
        #expect(SessionExport.serials(rows) == ["B", "A"])
    }
}

@Suite("Jamf configuration")
struct JamfConfigurationTests {

    private let environmentID = "11111111-2222-3333-4444-555555555555"

    @Test("Platform API routes through the regional gateway with the environment header")
    func platform() throws {
        let config = try #require(JamfConfiguration.make(
            urlString: "",
            credentials: .platform(region: .eu, clientID: "id", clientSecret: "secret", environmentID: environmentID)))
        let connection = try #require(config.connection)
        #expect(connection.service == .jamfPlatform)
        #expect(connection.jamfBaseURL?.absoluteString == "https://eu.api.jamfcloud.com")
        #expect(connection.environmentID == environmentID)
        #expect(config.webBaseURL == nil)
    }

    @Test("The optional Jamf Pro URL becomes the link base")
    func platformWebURL() throws {
        let config = try #require(JamfConfiguration.make(
            urlString: "yourorg.jamfcloud.com/",
            credentials: .platform(region: .us, clientID: "id", clientSecret: "secret", environmentID: environmentID)))
        #expect(config.webBaseURL?.absoluteString == "https://yourorg.jamfcloud.com")
        #expect(config.connection?.jamfBaseURL?.host() == "us.api.jamfcloud.com")
    }

    @Test("Incomplete or invalid Platform settings are not a configuration")
    func platformInvalid() {
        #expect(JamfConfiguration.make(urlString: "", credentials:
            .platform(region: .eu, clientID: "id", clientSecret: "secret", environmentID: "not-a-uuid")) == nil)
        #expect(JamfConfiguration.make(urlString: "", credentials:
            .platform(region: .eu, clientID: "", clientSecret: "secret", environmentID: environmentID)) == nil)
    }

    @Test("Direct Jamf Pro keeps its existing addresses and sends no context header")
    func jamfPro() throws {
        let config = try #require(JamfConfiguration.make(
            urlString: "https://yourorg.jamfcloud.com",
            credentials: .clientCredentials(clientID: "id", clientSecret: "secret")))
        let connection = try #require(config.connection)
        #expect(connection.service == .jamfPro)
        #expect(connection.signIn == .apiClient)
        #expect(connection.jamfBaseURL?.absoluteString == "https://yourorg.jamfcloud.com")
        #expect(connection.clientID == "id")

        // Typed without https://: the app adds it, as before.
        let basic = try #require(JamfConfiguration.make(
            urlString: "yourorg.jamfcloud.com",
            credentials: .basic(username: "user", password: "pass")))
        #expect(basic.connection?.signIn == .usernamePassword)
        #expect(basic.connection?.username == "user")
        #expect(basic.connection?.jamfBaseURL?.absoluteString == "https://yourorg.jamfcloud.com")
    }
}

@Suite("Model database")
struct ModelDatabaseTests {

    @Test("A booted device's identifier resolves to its marketing name")
    func identifierLookup() {
        let info = ModelDatabase.shared.model(identifier: "iPad16,1")
        #expect(info.displayName == "iPad mini (A17 Pro, WiFi)")
        // Unknown identifiers still display, just without a marketing name.
        #expect(ModelDatabase.shared.model(identifier: "iPhone99,9").displayName == "iPhone99,9")
    }
}
