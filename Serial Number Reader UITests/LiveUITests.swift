import XCTest
import JTKitUITestSupport

/// Live UI tests: the real app under JTKit's live-check switch, against the
/// release check's tenants, through its gateway. Run only by
/// `Scripts/release-check.sh` (skipped on ⌘U).
///
/// Only what the app can do without a USB device: Test Connection in
/// Settings › Connections, for each read role and for jamf-test-a. Sign-in
/// and one inventory read; nothing is written. Lookups of real records stay
/// in the unit-test live checks (`LiveCheckTests`). No USB action and no
/// device command, ever: under tests the app refuses every USB action.
final class LiveUITests: JTKitUITestCase {
    override var appName: String { "Serial Number Reader" }
    override var launchesLive: Bool { true }

    override func didLaunch() {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20), "The main window did not open")
        // A click on the title bar before the first key press (⌘,): see DemoSmokeUITests.didLaunch.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 8)).click()
    }

    /// The roles of this run.
    private var runRoles: Set<String> {
        Set((ProcessInfo.processInfo.environment["JTKIT_LIVE_ROLES"] ?? "").split(separator: ",").map(String.init))
    }

    /// Test Connection on the role's connection. A role with a Platform API
    /// and a Jamf Pro entry is listed twice ("<role> (Jamf Pro)"); this app's
    /// release check signs in over the Platform API (`via`), so that one.
    private func testConnection(role: String, via service: String? = nil, expect product: String) throws {
        _ = try liveGateway()
        guard runRoles.isEmpty || runRoles.contains(role) else {
            recordLive(step: "Test Connection on \(role)", passed: true, note: "not a role of this run")
            return
        }
        try launchLive(roles: [role])

        let settings = openSettings()
        tap(settings.toolbars.buttons["Connections"])
        var match = NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", role, role)
        if let service {
            match = NSCompoundPredicate(andPredicateWithSubpredicates: [match, NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@", service, service)])
        }
        let row = settings.staticTexts.matching(match).firstMatch
        tap(row, timeout: 10)
        tap(settings.buttons["Test Connection"], timeout: 10)
        waitForNetwork()
        let connected = settings.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH 'Connected' OR value BEGINSWITH 'Connected'")).firstMatch
        let passed = connected.waitForExistence(timeout: 60)
        let shown = passed ? ((connected.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? connected.label) : ""
        recordLive(step: "Test Connection on \(role)", passed: passed && shown.contains(product),
                   note: passed ? shown : "Settings didn't report a connection")
        XCTAssertTrue(passed, "Test Connection on \(role) didn't report Connected")
        XCTAssertTrue(shown.contains(product), "Test Connection on \(role) said “\(shown)”")
        close(settings)
    }

    /// Jamf Pro over the Platform API, read only.
    func testConnectionJamfProReadOnly() throws {
        try testConnection(role: "jamfpro-readonly", via: "Platform", expect: "Jamf Pro")
    }

    /// Jamf School, read only.
    func testConnectionJamfSchoolReadOnly() throws {
        try testConnection(role: "jamfschool-readonly", expect: "Jamf School")
    }

    /// The writable sandbox tenant, over the Platform API: Test Connection only reads.
    func testConnectionJamfTestA() throws {
        try testConnection(role: "jamf-test-a", via: "Platform", expect: "Jamf Pro")
    }
}
