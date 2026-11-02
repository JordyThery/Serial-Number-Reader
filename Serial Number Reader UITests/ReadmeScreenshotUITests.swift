import XCTest
import JTKitUITestSupport

/// Makes the README screenshot in demo mode: the pretend iPhone, looked up in
/// "Contoso Jamf Pro (Demo)", so it shows no real identifiers. Not part of the
/// release check; run it by hand when the interface changes. The image is kept
/// as an attachment named after its file in `docs/`.
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

        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "screenshot.png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
