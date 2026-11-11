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
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20), "The main window did not open")
        // A click on the title bar first: in a fresh test runner, a key press
        // sent before any click (⌘, for Settings) crashes the runner in
        // CoreGraphics (CGS_REQUIRE_INIT). The release check runs each test
        // in its own runner.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 8)).click()
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
            .matching(NSPredicate(format: "title BEGINSWITH 'Jamf: Contoso Jamf Pro'")).firstMatch
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
        // The demo Apple Business organization answers inside the app under
        // Apple's own hosts, as JTKit's demo Intune does under Microsoft's.
        checkActivityLog(alsoAllowedHosts: ["account.apple.com", "api-business.apple.com"])
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
    /// Whatever was on the clipboard is put back afterwards.
    func test11CopyAndQRCode() {
        let saved = ClipboardContents.save()
        defer { saved.restore() }
        selectPretendIPhone()
        waitForRecord()
        let copy = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Copy Serial Number'")).firstMatch
        tap(copy, timeout: 10)
        let copied = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Copied'"), object: copy)
        XCTAssertEqual(XCTWaiter.wait(for: [copied], timeout: 5), .completed, "Copy didn't confirm")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "ZZDEMOP42RX", "The clipboard doesn't hold the serial number")

        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show Serial Number'")).firstMatch)
        let code = app.popovers.firstMatch
        XCTAssertTrue(code.waitForExistence(timeout: 5), "The QR code didn't open")
        XCTAssertTrue(code.images.matching(NSPredicate(format: "label BEGINSWITH 'QR code for'")).firstMatch.exists, "No QR code")
        XCTAssertTrue(code.staticTexts["ZZDEMOP42RX"].exists, "The QR popover doesn't show the serial number")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(code.waitForNonExistence(timeout: 5))
    }

    /// Enter DFU: back as an identified DFU device with the button steps, and said so in the bar, which closes by itself; Restart boots it again.
    func test12EnterDFUAndRestart() {
        selectPretendIPhone()
        tap(button("Enter DFU"), timeout: 10)
        selectNewestRow(until: button("Revive…"))
        XCTAssertTrue(anyContaining("Exit DFU").exists, "No DFU section with the button steps")
        XCTAssertTrue(anyContaining("Identified through Apple Configurator").exists, "The DFU device isn't identified")
        XCTAssertFalse(button("Enter DFU").exists, "Enter DFU is offered in DFU")
        XCTAssertTrue(any("UDID").exists && any("ECID").exists, "No UDID or ECID in DFU")
        // The bar above the details: back in DFU mode, then closed by itself (green results do).
        let back = anyContaining("is back in DFU mode")
        XCTAssertTrue(back.waitForExistence(timeout: 10), "No “back in DFU mode” in the bar")
        XCTAssertTrue(back.waitForNonExistence(timeout: 20), "The green result didn't close by itself")
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

    /// Behind the Restore sheet the Device menu offers no action. (The
    /// wrapping of the action buttons in a narrow window is a unit test:
    /// synthesized drags don't resize windows here.)
    func test21DeviceMenuBehindSheet() {
        selectPretendIPhone()
        enterRecovery()
        XCTAssertTrue(any("Actions").exists, "No Actions section")

        tap(button("Restore…"), timeout: 10)
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "The Restore sheet didn't open")
        // Behind the sheet, the Device menu offers no action.
        let menu = app.menuBars.menuBarItems["Device"]
        tap(menu)
        for item in ["Boot to Normal", "Restart", "Enter DFU", "Restore…", "Revive…"] {
            XCTAssertFalse(menu.menuItems[item].isEnabled, "Device › \(item) is enabled behind the Restore sheet")
        }
        app.typeKey(.escape, modifierFlags: [])
        tap(sheet.buttons["Cancel"])
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
    }

    /// While an asset tag is typed, Device › Remove from List (⌘⌫, which also
    /// deletes text) is off for the disconnected device being edited.
    func test22RemoveFromListWaitsForAssetTagEdit() {
        selectPretendIPhone()
        waitForRecord()
        enterRecovery()
        // the booted row it left, disconnected, with its Jamf record
        rows.element(boundBy: 1).click()
        waitForRecord()
        let menu = app.menuBars.menuBarItems["Device"]
        tap(menu)
        XCTAssertTrue(menu.menuItems["Remove from List"].isEnabled, "Remove from List is off for a disconnected device")
        app.typeKey(.escape, modifierFlags: [])

        tap(button("Edit Asset Tag"), timeout: 10)
        tap(menu)
        XCTAssertFalse(menu.menuItems["Remove from List"].isEnabled, "Remove from List is on while the asset tag is edited")
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
        tap(menu)
        XCTAssertTrue(menu.menuItems["Remove from List"].isEnabled, "Remove from List stayed off after the edit")
        app.typeKey(.escape, modifierFlags: [])
    }

    /// The pretend iPhone is found in the demo Apple Business organization:
    /// its Apple section shows the record, and the Connection menu has the
    /// Apple role with the demo organization.
    func test23AppleBusinessSection() {
        selectPretendIPhone()
        XCTAssertTrue(any("Apple Business").waitForExistence(timeout: 20), "No Apple Business section")
        XCTAssertTrue(any("Device Management Service").waitForExistence(timeout: 20), "The Apple Business lookup found no record")
        XCTAssertFalse(anyContaining("Open in Apple Business").exists, "The demo organization has no web pages to open")
        let organization = connectionMenuItem("Contoso (Demo)")
        XCTAssertTrue(organization.waitForExistence(timeout: 5), "The Connection menu doesn't offer the demo Apple organization")
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Settings › Connections lists an Apple account in the same list as the
    /// Jamf connections; the first one saved is the Apple account in use.
    func test24AppleRoleInSettings() {
        let settings = openSettings()
        tap(settings.toolbars.buttons["Connections"])
        let add = settings.buttons["Add Connection"].exists ? settings.buttons["Add Connection"] : settings.menuButtons["Add Connection"]
        tap(add, timeout: 10)
        XCTAssertTrue(app.menuItems["Apple School Manager"].waitForExistence(timeout: 5), "+ doesn't offer Apple School Manager")
        tap(app.menuItems["Apple Business"])
        // The name field by its label, or (unlabeled) by the new account's name.
        let labelled = settings.textFields["Name"].firstMatch
        let nameField = labelled.waitForExistence(timeout: 2)
            ? labelled
            : settings.textFields.matching(NSPredicate(format: "value BEGINSWITH 'New '")).firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "The new account's editor didn't open")
        let name = "JTKTEST Apple \(Int.random(in: 1000...9999))"
        nameField.click()
        nameField.typeKey("a", modifierFlags: .command)
        nameField.typeText(name)
        tap(settings.buttons["Save"])
        let row = settings.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", name, name)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The Apple account isn't listed")
        // The role: marked as the Apple account in use, not offered for Jamf.
        XCTAssertTrue(settings.staticTexts["Apple"].waitForExistence(timeout: 5), "The Apple role isn't shown")
        XCTAssertFalse(settings.buttons["Use This Connection"].exists, "An Apple account is offered as the Jamf connection")
        XCTAssertTrue(anyContaining("so you can revoke it on its own").exists, "No help text for the API account")

        row.click()
        tap(settings.buttons["Delete Connection"])
        tap(dialogButton("Delete"))
        XCTAssertTrue(row.waitForNonExistence(timeout: 10), "The Apple account wasn't deleted")
        close(settings)
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

/// The clipboard as it was before a test that copies, put back afterwards,
/// so the release check doesn't take what the person running it had copied.
private struct ClipboardContents {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    static func save() -> ClipboardContents {
        let items = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
        return ClipboardContents(items: items)
    }

    func restore() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let restored = items.map { saved -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in saved { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}
