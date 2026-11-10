import XCTest
import JTKitUITestSupport

/// Makes the README screenshots in demo mode: the pretend iPhone, looked up in
/// "Contoso Jamf Pro (Demo)" and the demo Apple Business organization
/// "Contoso (Demo)", so they show no real identifiers. Not part of the
/// release check; run it by hand when the interface changes. Each image is
/// kept as an attachment named after its file in `docs/`.
final class ReadmeScreenshotUITests: JTKitUITestCase {
    override var appName: String { "Serial Number Reader" }

    override func launchApp() {
        // US English formats, as in the README.
        launchInDemo(arguments: ["-AppleLanguages", "(en-US)", "-AppleLocale", "en_US"])
    }

    override func didLaunch() {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20), "The main window did not open")
    }

    func testMainWindowScreenshot() {
        let window = self.window(titled: "Serial Number Reader")
        XCTAssertTrue(window.waitForExistence(timeout: 20), "The main window did not open")
        tap(app.outlines.firstMatch.cells.firstMatch, timeout: 20)
        XCTAssertTrue(any("Jamf Name").waitForExistence(timeout: 20), "The lookup found no record")
        // Larger, so the Jamf record shows too: Window › Zoom.
        tap(app.menuBars.menuBarItems["Window"])
        tap(app.menuItems["Zoom"])
        // Let the lookup's last changes settle before taking the picture.
        sleep(2)

        keep(window, as: "screenshot.png")
    }

    /// The pretend iPhone's Apple section, found in the demo organization.
    func testAppleSectionScreenshot() {
        let window = self.window(titled: "Serial Number Reader")
        XCTAssertTrue(window.waitForExistence(timeout: 20), "The main window did not open")
        tap(app.outlines.firstMatch.cells.firstMatch, timeout: 20)
        XCTAssertTrue(any("Jamf Name").waitForExistence(timeout: 20), "The lookup found no record")
        XCTAssertTrue(any("Device Management Service").waitForExistence(timeout: 20), "The Apple lookup found no record")
        tap(app.menuBars.menuBarItems["Window"])
        tap(app.menuItems["Zoom"])
        // Down to the Apple section, below the Jamf one.
        let details = window.scrollViews.allElementsBoundByIndex.last ?? window.scrollViews.firstMatch
        for _ in 0..<10 { details.scroll(byDeltaX: 0, deltaY: -400) }
        sleep(2)
        keep(window, as: "screenshot-apple.png")
    }

    /// The pointer off the toolbar (a picker's tooltip would show in the
    /// picture), resting on the empty sidebar below the device.
    private func keep(_ window: XCUIElement, as name: String) {
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.6)).hover()
        sleep(3)
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
