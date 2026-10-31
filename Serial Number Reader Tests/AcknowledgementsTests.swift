import Foundation
import JTKit
import Testing
@testable import Serial_Number_Reader

@Suite("Acknowledgements")
struct AcknowledgementsTests {
    /// The license shown in About must be the one in THIRD-PARTY-NOTICES.md, unchanged.
    @Test func licenseMatchesThirdPartyNotices() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let notices = try String(contentsOf: repository.appendingPathComponent("THIRD-PARTY-NOTICES.md"), encoding: .utf8)
        let start = try #require(notices.range(of: "```\n"))
        let end = try #require(notices.range(of: "\n```", range: start.upperBound..<notices.endIndex))
        let fromNotices = String(notices[start.upperBound..<end.lowerBound])
        let inApp = try #require(Acknowledgement.macvdmtool.license)
        #expect(inApp == fromNotices)
        #expect(inApp.contains("Version 2.0, January 2004"))
        #expect(Acknowledgement.macvdmtool.licenseName == "Apache License")
    }

    @Test func creditsBothCopyrightHolders() throws {
        let summary = try #require(Acknowledgement.macvdmtool.summary)
        #expect(summary.contains("Copyright (C) 2019 osy86"))
        #expect(summary.contains("Copyright (C) 2021 The Asahi Linux Contributors"))
        #expect(Acknowledgement.macvdmtool.links.map(\.url.absoluteString) == [
            "https://github.com/AsahiLinux/macvdmtool",
            "https://github.com/osy/ThunderboltPatcher",
        ])
    }

    @Test func aboutShowsTheAcknowledgement() {
        let about = AboutConfiguration.serialNumberReader
        #expect(about.acknowledgements == [.macvdmtool])
        #expect(about.windowTitle == "About Serial Number Reader")
        // Matches LICENSE: MIT, Copyright (c) 2026 Jordy Thery.
        #expect(about.copyright?.text == "© 2026 Jordy Thery. Released under the MIT License.")
        #expect(about.links.map(\.url.absoluteString) == ["https://github.com/JordyThery/Serial-Number-Reader"])
    }
}
