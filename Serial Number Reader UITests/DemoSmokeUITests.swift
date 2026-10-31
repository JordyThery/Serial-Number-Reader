import XCTest
import JTKitUITestSupport

/// The release check's UI smoke tests, in demo mode:
/// the pretend iPhone and JTKit's Contoso servers, the same answers every run,
/// no tenant, nothing saved, no real USB device. Run one at a time by
/// `Scripts/release-check.sh`; minutes, not hours.
final class DemoSmokeUITests: JTKitUITestCase {
    override var appName: String { "Serial Number Reader" }

    override func launchApp() {
        launchInDemo()
    }

    override func didLaunch() {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20), "The main window did not open")
    }

    /// The pretend iPhone in the sidebar, selected; its detail shows.
    private func selectPretendIPhone() {
        let row = app.outlines.firstMatch.cells.firstMatch
        tap(row, timeout: 20)
        XCTAssertTrue(app.buttons["Restart"].firstMatch.waitForExistence(timeout: 10), "The pretend iPhone's detail didn't open")
    }

    func test1Launch() {
        XCTAssertTrue(window(titled: "Serial Number Reader").waitForExistence(timeout: 20), "The main window did not open")
        selectPretendIPhone()
    }

    func test2About() {
        checkAbout()
    }

    func test3SettingsTabs() {
        checkSettingsTabs(["General", "Connections", "Updates"])
    }

    func test4ConnectionsEditor() {
        // Made-up values: the connection lives only in this run's in-memory list.
        checkConnectionsEditor(service: "Jamf Platform API") { settings in
            let fields = settings.textFields.allElementsBoundByIndex
            if let environment = fields.firstIndex(where: { ($0.placeholderValue ?? "") == "From Jamf Account" }) {
                self.type(UUID().uuidString, into: fields[environment])
                if environment + 1 < fields.count { self.type("jtktest-client", into: fields[environment + 1]) }
            }
            self.type("jtktest-secret", into: settings.secureTextFields.firstMatch)
        }
    }

    /// The pretend iPhone appears, its lookup finds it in Contoso Jamf Pro,
    /// and a simulated Restart is logged in the activity log.
    func test5MainTask() {
        selectPretendIPhone()
        XCTAssertTrue(any("Device Name").waitForExistence(timeout: 20), "The lookup found no record")
        // The record comes from the connection in use, Contoso's Jamf Pro.
        let connection = app.descendants(matching: .any)
            .matching(NSPredicate(format: "title BEGINSWITH 'Connection: Contoso Jamf Pro'")).firstMatch
        XCTAssertTrue(connection.waitForExistence(timeout: 10), "The lookup didn't use Contoso Jamf Pro (Demo)")
        // The sidebar row names the record the lookup found ("Jamf: <device name>").
        XCTAssertTrue(anyContaining("Jamf: ").waitForExistence(timeout: 10), "The sidebar doesn't show the record found")

        tap(app.buttons["Restart"].firstMatch, timeout: 10)
        app.typeKey("l", modifierFlags: [.command, .shift])
        let log = window(titled: "Activity Log")
        XCTAssertTrue(log.waitForExistence(timeout: 10), "The activity log did not open")
        let restart = log.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Restart' OR value CONTAINS 'Restart'")).firstMatch
        XCTAssertTrue(restart.waitForExistence(timeout: 20), "The simulated Restart isn't in the activity log")
        close(log)
    }

    func test6ActivityLog() {
        selectPretendIPhone()
        XCTAssertTrue(any("Device Name").waitForExistence(timeout: 20), "The lookup found no record")
        checkActivityLog()
    }

    func test7DemoTitles() {
        tap(app.menuBars.menuBarItems[appName])
        tap(app.menuItems["About \(appName)"])
        XCTAssertTrue(window(titled: "About \(appName)").waitForExistence(timeout: 10))
        app.typeKey("l", modifierFlags: [.command, .shift])
        XCTAssertTrue(window(titled: "Activity Log").waitForExistence(timeout: 10))
        openSettings()
        checkDemoTitles()
    }
}
