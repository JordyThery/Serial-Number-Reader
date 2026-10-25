import Foundation
import Testing
@testable import Serial_Number_Reader

@Suite("Jamf School")
struct JamfSchoolTests {

    @Test("Configuration uses the school URL and needs Network ID and API key")
    func configuration() throws {
        let config = try #require(JamfConfiguration.make(
            urlString: "yourschool.jamfcloud.com/",
            credentials: .jamfSchool(networkID: "012345", apiKey: "KEY")))
        #expect(config.apiBaseURL.absoluteString == "https://yourschool.jamfcloud.com")
        #expect(config.tokenURL == nil)
        #expect(config.isJamfSchool)
        #expect(config.productName == "Jamf School")
        #expect(JamfConfiguration.make(urlString: "yourschool.jamfcloud.com",
                                       credentials: .jamfSchool(networkID: "", apiKey: "KEY")) == nil)
    }

    @Test("Records link to the Jamf School device page by UDID")
    func webLink() throws {
        let record = JamfDeviceRecord(kind: .schoolDevice, jamfID: "00008130-001A2B3C4D5E6F70", name: nil,
                                      assetTag: nil, serialNumber: nil, udid: nil, model: nil, modelIdentifier: nil,
                                      osVersion: nil, managed: nil, username: nil, realName: nil, email: nil,
                                      lastInventoryDate: nil)
        let url = record.webURL(baseURL: try #require(URL(string: "https://yourschool.jamfcloud.com")))
        #expect(url?.absoluteString == "https://yourschool.jamfcloud.com/devices/details/00008130-001A2B3C4D5E6F70")
    }

    @Test("Errors are recognised in the HTTP status and in the body")
    func errors() {
        // Observed responses.
        #expect(throws: JamfError.noMatch) {
            try JamfSchoolClient.throwIfError(status: 404, data: Data(#"{"code":404,"message":"DeviceNotFound"}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try JamfSchoolClient.throwIfError(status: 401, data: Data(#"{"error":{"message":"Invalid Credentials","code":401}}"#.utf8))
        }
        // A failure reported only in the body of an HTTP 200.
        #expect(throws: (any Error).self) {
            try JamfSchoolClient.throwIfError(status: 200, data: Data(#"{"code":400,"message":"Bad request"}"#.utf8))
        }
        #expect(throws: Never.self) {
            try JamfSchoolClient.throwIfError(status: 200, data: Data(#"{"code":200,"count":0,"devices":[]}"#.utf8))
        }
    }

    @Test("Only DeviceNotFound means no match; other 404s point at the URL")
    func notFound() {
        #expect(throws: JamfError.httpError(404, "not found — check the Jamf School URL (e.g. https://yourschool.jamfcloud.com)")) {
            try JamfSchoolClient.throwIfError(status: 404, data: Data("<html>Not Found</html>".utf8))
        }
    }

    @Test("A URL with the documented /api suffix is accepted")
    func apiSuffix() throws {
        let config = try #require(JamfConfiguration.make(
            urlString: "https://yourschool.jamfcloud.com/api/",
            credentials: .jamfSchool(networkID: "012345", apiKey: "KEY")))
        #expect(config.apiBaseURL.absoluteString == "https://yourschool.jamfcloud.com")
    }

    @Test("Asset tags are form-encoded so + and & survive")
    func formEncoding() {
        #expect(JamfSchoolClient.formEncoded("LAB+01") == "LAB%2B01")
        #expect(JamfSchoolClient.formEncoded("A+B&C=D é") == "A%2BB%26C%3DD%20%C3%A9")
        #expect(JamfSchoolClient.formEncoded("Plain-tag_1.0~") == "Plain-tag_1.0~")
    }

    @Test("Check-in dates parse as a string or as an object with a time zone")
    func checkIn() throws {
        struct Wrapper: Decodable { let lastCheckin: CheckIn }
        let utc = try JSONDecoder().decode(Wrapper.self, from: Data(
            #"{"lastCheckin":{"date":"2026-10-25 10:22:25.000000","timezone_type":3,"timezone":"UTC"}}"#.utf8))
        #expect(utc.lastCheckin.date == Date(timeIntervalSince1970: 1_792_923_745)) // 2026-10-25 10:22:25 UTC
        let plain = try JSONDecoder().decode(Wrapper.self, from: Data(#"{"lastCheckin":"2026-10-25 10:22:25"}"#.utf8))
        #expect(plain.lastCheckin.date != nil)
        let empty = try JSONDecoder().decode(Wrapper.self, from: Data(#"{"lastCheckin":""}"#.utf8))
        #expect(empty.lastCheckin.date == nil)
    }

    @Test("Flags decode from booleans and from 0/1")
    func lenientBool() throws {
        struct Wrapper: Decodable { let flag: LenientBool }
        for (json, expected) in [(#"{"flag":true}"#, true), (#"{"flag":1}"#, true), (#"{"flag":0}"#, false), (#"{"flag":"1"}"#, true)] {
            #expect(try JSONDecoder().decode(Wrapper.self, from: Data(json.utf8)).flag.value == expected)
        }
    }
}
