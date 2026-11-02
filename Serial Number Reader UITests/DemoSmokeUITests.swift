import XCTest
import JTKitUITestSupport

/// The release check's UI smoke tests, in demo mode:
/// the pretend iPhone and JTKit's Contoso servers, the same answers every run,
/// no tenant, nothing saved, no real USB device. Run one at a time by
/// `Scripts/release-check.sh`; minutes, not hours.
///
/// Every action here goes to the pretend iPhone (`DemoUSB`): nothing reaches
/// a USB device, and no password is asked.
final class DemoSmokeUITests: JTKitUITestCase {
    override var appName: String { "Serial Number Reader" }

    override func launchApp() {
        launchInDemo()
    }

    override func didLaunch() {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20), "The main window did not open")
    }

    // MARK: Helpers

    private var rows: XCUIElementQuery { app.outlines.firstMatch.cells }

    /// The pretend iPhone in the sidebar, selected; its detail shows.
    private func selectPretendIPhone() {
        tap(rows.firstMatch, timeout: 20)
        XCTAssertTrue(app.buttons["Restart"].firstMatch.waitForExistence(timeout: 10), "The pretend iPhone's detail didn't open")
    }

    /// The pretend iPhone's Jamf record is shown.
    private func waitForRecord(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(any("Jamf Name").waitForExistence(timeout: 20), "The lookup found no record", file: file, line: line)
    }

    /// After a simulated reboot the pretend iPhone comes back as a new row at
    /// the top: selects it until `ready` (a control of the expected mode) shows.
    private func selectNewestRow(until ready: XCUIElement, timeout: TimeInterval = 40,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if rows.firstMatch.exists {
                rows.firstMatch.click()
                if ready.waitForExistence(timeout: 1) { return }
            }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTFail("The pretend iPhone didn't come back as expected: \(ready)", file: file, line: line)
    }

    private func button(_ label: String) -> XCUIElement {
        app.windows.firstMatch.buttons[label].firstMatch
    }

    /// A Connection menu item, e.g. "Contoso Academy (Demo)" or "Demo Mode".
    private func connectionMenuItem(_ title: String) -> XCUIElement {
        tap(app.menuBars.menuBarItems["Connection"], timeout: 10)
        return app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", title)).firstMatch
    }

    private func waitForRowCount(_ count: Int, file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", count), object: rows)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 20), .completed,
                       "Expected \(count) rows, found \(rows.count)", file: file, line: line)
    }

    /// Enter Recovery from booted: back in Recovery, its serial read from USB.
    private func enterRecovery() {
        tap(button("Enter Recovery"), timeout: 10)
        selectNewestRow(until: button("Boot to Normal"))
        XCTAssertTrue(anyContaining("ZZDEMOP42RX").waitForExistence(timeout: 10), "No serial number in Recovery")
    }

    /// Restore… or Revive… from Recovery, confirmed in its sheet, until the banner says it's done.
    private func runJob(_ menuButton: String, confirm: String, done: String) {
        tap(button(menuButton), timeout: 10)
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "The \(menuButton) sheet didn't open")
        XCTAssertTrue(sheet.buttons["Cancel"].exists, "The sheet has no Cancel")
        tap(sheet.buttons[confirm], timeout: 20)
        // While it runs, Demo Mode can't be switched off.
        let demoSwitch = connectionMenuItem("Demo Mode")
        XCTAssertTrue(demoSwitch.waitForExistence(timeout: 5), "No Demo Mode switch in the Connection menu")
        XCTAssertFalse(demoSwitch.isEnabled, "The Demo Mode switch isn't dimmed during the job")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(anyContaining(done).waitForExistence(timeout: 90), "The banner never said \(done)")
    }

    // MARK: Tests

    func test1Launch() {
        XCTAssertTrue(window(titled: "Serial Number Reader").waitForExistence(timeout: 20), "The main window did not open")
        XCTAssertTrue(anyContaining("Real devices aren’t shown in Demo Mode").exists, "No demo note in the sidebar")
        selectPretendIPhone()
    }

    func test2About() {
        checkAbout()
    }

    func test3SettingsTabs() {
        // No General tab: the app has no general settings (JTKit 1.2.0).
        checkSettingsTabs(["Connections", "Updates"])
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
        waitForRecord()
        // The record comes from the connection in use, Contoso's Jamf Pro.
        let connection = app.descendants(matching: .any)
            .matching(NSPredicate(format: "title BEGINSWITH 'Connection: Contoso Jamf Pro'")).firstMatch
        XCTAssertTrue(connection.waitForExistence(timeout: 10), "The lookup didn't use Contoso Jamf Pro (Demo)")
        // The sidebar row names the record the lookup found ("Jamf: <device name>").
        XCTAssertTrue(anyContaining("Jamf: ").waitForExistence(timeout: 10), "The sidebar doesn't show the record found")

        tap(button("Restart"), timeout: 10)
        app.typeKey("l", modifierFlags: [.command, .shift])
        let log = window(titled: "Activity Log")
        XCTAssertTrue(log.waitForExistence(timeout: 10), "The activity log did not open")
        let restart = log.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Restart' OR value CONTAINS 'Restart'")).firstMatch
        XCTAssertTrue(restart.waitForExistence(timeout: 20), "The simulated Restart isn't in the activity log")
        close(log)
        // Back booted after the simulated reboot.
        selectNewestRow(until: button("Enter Recovery"))
    }

    func test6ActivityLog() {
        selectPretendIPhone()
        waitForRecord()
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

    /// Switching to Contoso Academy looks the device up again, in Jamf School,
    /// which doesn't have the pretend iPhone (it's in Contoso's Jamf Pro only).
    func test8SwitchToJamfSchool() {
        selectPretendIPhone()
        waitForRecord()
        tap(connectionMenuItem("Contoso Academy"))
        XCTAssertTrue(any("Jamf School").waitForExistence(timeout: 10), "The Jamf section isn't titled Jamf School")
        XCTAssertTrue(anyContaining("No matching device in Jamf School").waitForExistence(timeout: 20),
                      "The lookup didn't run again in Jamf School")
        tap(connectionMenuItem("Contoso Jamf Pro"))
        XCTAssertTrue(any("Jamf Pro").waitForExistence(timeout: 10), "Back to Jamf Pro: the section isn't titled Jamf Pro")
        waitForRecord()
    }

    /// Retry Lookup reads the record again, with a new entry in the activity log.
    func test9RetryLookup() {
        selectPretendIPhone()
        waitForRecord()
        app.typeKey("l", modifierFlags: [.command, .shift])
        let log = window(titled: "Activity Log")
        XCTAssertTrue(log.waitForExistence(timeout: 10), "The activity log did not open")
        let before = log.cells.count
        close(log)
        tap(button("Retry Lookup"), timeout: 10)
        waitForRecord()
        app.typeKey("l", modifierFlags: [.command, .shift])
        XCTAssertTrue(log.waitForExistence(timeout: 10))
        let more = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > %d", before), object: log.cells)
        XCTAssertEqual(XCTWaiter.wait(for: [more], timeout: 20), .completed, "Retry Lookup added nothing to the activity log")
        close(log)
    }

    /// The asset tag is saved (and read back from the demo server); Escape cancels an edit.
    func test10AssetTag() {
        selectPretendIPhone()
        waitForRecord()
        let tag = "JTKTEST-TAG-\(Int.random(in: 100...999))"
        tap(button("Edit Asset Tag"), timeout: 10)
        // the detail's only text field while editing
        let field = app.windows.firstMatch.scrollViews.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "No asset tag field")
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(tag)
        tap(button("Save"))
        XCTAssertTrue(any(tag).waitForExistence(timeout: 20), "The saved asset tag isn't shown")
        XCTAssertFalse(field.exists, "The editor stayed open after Save")

        tap(button("Edit Asset Tag"), timeout: 10)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText("-not-saved")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "Escape didn't close the asset tag editor")
        XCTAssertTrue(any(tag).exists, "Cancel changed the asset tag")
    }

    /// Copy puts the serial number on the clipboard; QR shows it as a code.
    func test11CopyAndQRCode() {
        selectPretendIPhone()
        waitForRecord()
        let copy = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Copy Serial Number'")).firstMatch
        tap(copy, timeout: 10)
        let copied = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Copied'"), object: copy)
        XCTAssertEqual(XCTWaiter.wait(for: [copied], timeout: 5), .completed, "Copy didn't confirm")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "ZZDEMOP42RX", "The clipboard doesn't hold the serial number")
        NSPasteboard.general.clearContents()

        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show Serial Number'")).firstMatch)
        let code = app.popovers.firstMatch
        XCTAssertTrue(code.waitForExistence(timeout: 5), "The QR code didn't open")
        XCTAssertTrue(code.images.matching(NSPredicate(format: "label BEGINSWITH 'QR code for'")).firstMatch.exists, "No QR code")
        XCTAssertTrue(code.staticTexts["ZZDEMOP42RX"].exists, "The QR popover doesn't show the serial number")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(code.waitForNonExistence(timeout: 5))
    }

    /// Enter DFU: back as an identified DFU device with the button steps; Restart boots it again.
    func test12EnterDFUAndRestart() {
        selectPretendIPhone()
        tap(button("Enter DFU"), timeout: 10)
        selectNewestRow(until: button("Revive…"))
        XCTAssertTrue(anyContaining("Exit DFU").exists, "No DFU section with the button steps")
        XCTAssertTrue(anyContaining("Identified through Apple Configurator").exists, "The DFU device isn't identified")
        XCTAssertFalse(button("Enter DFU").exists, "Enter DFU is offered in DFU")
        XCTAssertTrue(any("UDID").exists && any("ECID").exists, "No UDID or ECID in DFU")
        tap(button("Restart"), timeout: 10)
        selectNewestRow(until: button("Enter Recovery"))
    }

    /// Enter Recovery reads the serial from USB; Boot to Normal boots it again.
    func test13RecoveryAndBootToNormal() {
        selectPretendIPhone()
        enterRecovery()
        tap(button("Boot to Normal"), timeout: 10)
        selectNewestRow(until: button("Enter Recovery"))
    }

    /// A Restore erases the pretend iPhone: it comes back without its name
    /// and without trusting this Mac, so Enter Recovery shows the trust steps.
    func test14RestoreAndTrustGuidance() {
        selectPretendIPhone()
        enterRecovery()
        runJob("Restore…", confirm: "Erase & Restore", done: "Restored")
        selectNewestRow(until: button("Enter Recovery"), timeout: 60)
        XCTAssertFalse(button("Remove Trust").exists, "A restored device still trusts this Mac")
        tap(button("Enter Recovery"))
        XCTAssertTrue(anyContaining("only works from a Mac this device trusts").waitForExistence(timeout: 10),
                      "No trust guidance after Enter Recovery was refused")
    }

    /// A Revive keeps the content: the pretend iPhone still trusts this Mac.
    func test15Revive() {
        selectPretendIPhone()
        enterRecovery()
        runJob("Revive…", confirm: "Revive", done: "Revived")
        selectNewestRow(until: button("Remove Trust"), timeout: 60)
    }

    func test16RemoveTrust() {
        selectPretendIPhone()
        tap(button("Remove Trust"), timeout: 10)
        XCTAssertTrue(button("Remove Trust").waitForNonExistence(timeout: 10), "Remove Trust is still offered")
    }

    /// While an action runs, the others and Restore wait.
    func test17BusyState() {
        selectPretendIPhone()
        enterRecovery()
        tap(button("Restore…"), timeout: 10)
        let sheet = app.sheets.firstMatch
        tap(sheet.buttons["Erase & Restore"], timeout: 20)
        // Its Recovery stage during the restore: no action can start.
        let restore = button("Restore…")
        selectNewestRow(until: restore, timeout: 30)
        XCTAssertFalse(restore.isEnabled, "Restore… is enabled during a restore")
        XCTAssertFalse(button("Boot to Normal").isEnabled, "Boot to Normal is enabled during a restore")
        XCTAssertTrue(anyContaining("Restored").waitForExistence(timeout: 90), "The restore didn't finish")
    }

    /// Disconnected rows go with the Delete key, Device › Remove from List and
    /// Clear Disconnected. (A device that comes back in the same mode replaces
    /// its own disconnected row; a change of mode leaves the old row.)
    func test18ClearAndRemove() {
        selectPretendIPhone()
        enterRecovery()
        waitForRowCount(2)
        rows.element(boundBy: 1).click()
        app.typeKey(.delete, modifierFlags: [])
        waitForRowCount(1)

        rows.firstMatch.click()
        tap(button("Boot to Normal"), timeout: 10)
        selectNewestRow(until: button("Enter Recovery"))
        waitForRowCount(2)
        rows.element(boundBy: 1).click()
        let device = app.menuBars.menuBarItems["Device"]
        tap(device)
        tap(device.menuItems["Remove from List"])
        waitForRowCount(1)

        rows.firstMatch.click()
        enterRecovery()
        waitForRowCount(2)
        tap(app.toolbars.buttons["Clear Disconnected"], timeout: 10)
        waitForRowCount(1)
    }

    /// The Device menu holds the selected device's actions; ⌘E exports the session.
    func test19MenusAndExport() {
        selectPretendIPhone()
        let menu = app.menuBars.menuBarItems["Device"]
        tap(menu)
        for item in ["Enter Recovery", "Restart", "Enter DFU", "Remove Trust", "Retry Lookup", "Remove from List"] {
            XCTAssertTrue(menu.menuItems[item].exists, "The Device menu has no \(item)")
        }
        XCTAssertTrue(menu.menuItems["Restart"].isEnabled, "Device › Restart is dimmed for a booted device")
        XCTAssertFalse(menu.menuItems["Remove from List"].isEnabled, "A connected device can be removed from the list")
        app.typeKey(.escape, modifierFlags: [])

        app.typeKey("e", modifierFlags: .command)
        // The Save panel: canceled, nothing is written.
        let save = app.buttons.matching(NSPredicate(format: "label == 'Save' OR title == 'Save'")).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10), "⌘E didn't open the Save panel")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(save.waitForNonExistence(timeout: 10), "The Save panel didn't close")
    }

    /// Turning Demo Mode off takes the pretend iPhone and the sidebar note away.
    func test20DemoModeOff() {
        selectPretendIPhone()
        tap(connectionMenuItem("Demo Mode"))
        XCTAssertTrue(rows.firstMatch.waitForNonExistence(timeout: 10), "The pretend iPhone is still listed")
        XCTAssertFalse(anyContaining("Real devices aren’t shown in Demo Mode").exists, "The demo note is still shown")
        XCTAssertTrue(anyContaining("Connect an iPhone, iPad or Mac").waitForExistence(timeout: 5), "No empty-list guidance")
    }
}
