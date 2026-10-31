import Foundation
import JTKit
import os

/// Under tests the app reaches neither a real USB device nor a saved
/// connection (JTKit ROADMAP step 11, decided by Jordy). "Under tests" is the
/// host of the unit tests and a sandbox launch (`-JTKitSandbox YES`, which
/// the UI tests use). Every attempt is refused before anything happens and
/// written down, so the release check can show it in its report and fail.
nonisolated enum UnderTest {
    /// Where refused attempts are written: the user's temporary folder, the
    /// same for the test host and the app the UI tests launch. The release
    /// check empties it before every run.
    static let folder = TestRun.attemptsFolder(named: "SerialNumberReader-under-test")

    /// The message a refused attempt gives.
    static let refusal = "Refused under tests: the release check never reaches a real device or a saved connection."
}

/// The app's attempt logs (JTKit's `TestRun.AttemptLog`, one JSON line each).
extension TestRun.AttemptLog {
    nonisolated private static let logger = Logger(subsystem: "be.jordythery.SerialNumberReader", category: "UnderTest")

    /// USB actions, device reads and `cfgutil`.
    nonisolated static let usb = TestRun.AttemptLog(
        fileURL: UnderTest.folder.appending(path: "usb-attempts.jsonl"), logger: logger)
    /// Requests to a saved connection. Method and path only, never the query
    /// (a lookup's query holds the serial number).
    nonisolated static let savedConnections = TestRun.AttemptLog(
        fileURL: UnderTest.folder.appending(path: "saved-connection-requests.jsonl"), logger: logger)
}

/// Refuses everything that reaches a real USB device or starts `cfgutil`
/// while the app is under tests, and writes it down. Outside tests it does
/// nothing. The pretend iPhone is refused before this is asked, so demo mode
/// never counts as an attempt.
nonisolated struct USBGuard: Sendable {
    static let shared = USBGuard(isActive: TestRun.isActive, log: .usb)

    let isActive: Bool
    let log: TestRun.AttemptLog

    /// Throws (and records) under tests; nothing otherwise.
    func check(_ what: String) throws {
        if let message = refusal(for: what) { throw Configurator.Failure(message: message) }
    }

    /// The refusal message (recorded) under tests; nil otherwise.
    func refusal(for what: String) -> String? {
        guard isActive else { return nil }
        log.record(what)
        return UnderTest.refusal
    }
}
