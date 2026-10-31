import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Serial_Number_Reader

@MainActor
@Suite("Jamf School")
struct JamfSchoolTests {

    private func service(_ server: MockServer, url: String = "yourschool.jamfcloud.com") throws -> JamfService {
        let config = try #require(JamfConfiguration.make(
            urlString: url, credentials: .jamfSchool(networkID: "012345", apiKey: "KEY")))
        return try JamfService(configuration: config,
                               recorder: RequestRecorder(session: server.session, log: ActivityLog(), service: "Jamf School"))
    }

    @Test("Configuration uses the school URL and needs Network ID and API key")
    func configuration() throws {
        let config = try #require(JamfConfiguration.make(
            urlString: "yourschool.jamfcloud.com/",
            credentials: .jamfSchool(networkID: "012345", apiKey: "KEY")))
        #expect(config.serverURL?.absoluteString == "https://yourschool.jamfcloud.com")
        #expect(config.connection == nil)
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

    @Test("A serial lookup finds the UDID in the list, then reads the device's details")
    func lookup() async throws {
        let server = MockServer { request in
            if request.path == "/api/devices" {
                return .json(200, #"{"code":200,"count":1,"devices":[{"UDID":"00008130-001A2B3C4D5E6F70","serialNumber":"DMPXK1ABJG5H","isManaged":true}]}"#)
            }
            return .json(200, #"""
                {"code":200,"device":{"UDID":"00008130-001A2B3C4D5E6F70","serialNumber":"DMPXK1ABJG5H","name":"Lab iPad",
                 "assetTag":"","model":{"name":"iPad Air","identifier":"iPad13,16"},"os":{"prefix":"iOS","version":"26.0"},
                 "owner":{"name":"Jane Doe","username":"jane","email":"jane@school.example"},"isManaged":1,
                 "lastCheckin":{"date":"2026-10-25 10:22:25.000000","timezone_type":3,"timezone":"UTC"}}}
                """#)
        }
        let result = try await service(server).lookup(.serialNumber("DMPXK1ABJG5H"))
        guard case .found(let record) = result else {
            Issue.record("Expected a record, got \(result)")
            return
        }
        #expect(server.requests.map(\.path) == ["/api/devices", "/api/devices/00008130-001A2B3C4D5E6F70"])
        #expect(record.kind == .schoolDevice)
        #expect(record.jamfID == "00008130-001A2B3C4D5E6F70")
        #expect(record.name == "Lab iPad")
        #expect(record.assetTag == nil, "an empty string is none")
        #expect(record.model == "iPad Air")
        #expect(record.osVersion == "26.0")
        #expect(record.managed == true, "1 as a flag")
        #expect(record.realName == "Jane Doe")
        #expect(record.lastInventoryDate == Date(timeIntervalSince1970: 1_792_923_745)) // 2026-10-25 10:22:25 UTC
    }

    @Test("No device in the list, or DeviceNotFound, means no match")
    func noMatch() async throws {
        let empty = MockServer { _ in .json(200, #"{"code":200,"count":0,"devices":[]}"#) }
        #expect(try await service(empty).lookup(.serialNumber("DMPXK1ABJG5H")) == .noMatch)
        let missing = MockServer { _ in .json(404, #"{"code":404,"message":"DeviceNotFound"}"#) }
        #expect(try await service(missing).lookup(.udid("00008130-001A2B3C4D5E6F70")) == .noMatch)
    }

    @Test("Another 404 points at the URL; a failure under HTTP 200 is an error")
    func errors() async throws {
        let wrongURL = MockServer { _ in .json(404, "<html>Not Found</html>", headers: ["Content-Type": "text/html"]) }
        let notFound = await #expect(throws: JamfSchool.APIError.self) { _ = try await service(wrongURL).lookup(.udid("00008130-0001")) }
        #expect(notFound?.message().contains("Check the Jamf School server URL, e.g. https://yourschool.jamfcloud.com.") == true)

        let inBody = MockServer { _ in .json(200, #"{"code":400,"message":"Bad request"}"#) }
        await #expect(throws: JamfSchool.APIError.self) { _ = try await service(inBody).lookup(.udid("00008130-0001")) }
    }

    @Test("A refused API key gets JTKit's hint and the app's")
    func refusedKey() async throws {
        let server = MockServer { _ in .json(401, #"{"error":{"message":"Invalid Credentials","code":401}}"#) }
        let error = await #expect(throws: JamfSchool.APIError.self) { try await service(server).testConnection() }
        let message = try #require(error?.message())
        #expect(message.contains("Check the Network ID and API key"))
        #expect(message.contains("Serial Number Reader needs the API key to read devices, and to update their details for asset tags."))
    }

    @Test("A URL with the documented /api suffix is accepted")
    func apiSuffix() async throws {
        let server = MockServer { _ in .json(200, #"{"code":200,"count":0,"devices":[]}"#) }
        try await service(server, url: "https://yourschool.jamfcloud.com/api/").testConnection()
        #expect(server.requests.first?.url.absoluteString == "https://yourschool.jamfcloud.com/api/devices?serialnumber=CONNECTIONCHECK")
    }

    @Test("Asset tags are form-encoded so + and & survive")
    func formEncoding() async throws {
        let server = MockServer { _ in .json(200, #"{"code":200}"#) }
        let record = JamfDeviceRecord(kind: .schoolDevice, jamfID: "00008130-001A2B3C4D5E6F70", name: nil,
                                      assetTag: nil, serialNumber: nil, udid: nil, model: nil, modelIdentifier: nil,
                                      osVersion: nil, managed: nil, username: nil, realName: nil, email: nil,
                                      lastInventoryDate: nil)
        try await service(server).updateAssetTag("A+B&C=D é", record: record)
        #expect(server.requests.first?.path == "/api/devices/00008130-001A2B3C4D5E6F70/details")
        #expect(server.requests.first?.bodyString == "assetTag=A%2BB%26C%3DD%20%C3%A9")
    }
}
