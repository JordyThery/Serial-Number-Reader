import Foundation
import os

/// Under tests the app reaches neither a real USB device nor a saved
/// connection (JTKit ROADMAP step 11, decided by Jordy). "Under tests" is the
/// host of the unit tests and a sandbox launch (`-JTKitSandbox YES`, which
/// the UI tests use). Every attempt is refused before anything happens and
/// written down, so the release check can show it in its report and fail.
nonisolated enum UnderTest {
    /// Whether this launch is under tests.
    static let isActive: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return JamfConnectionStore.isUnitTestHost
            || environment["XCTestSessionIdentifier"] != nil
            || AppDemo.isSandboxLaunch
    }()

    /// Where refused attempts are written: the user's temporary folder, the
    /// same for the test host and the app the UI tests launch. The release
    /// check empties it before every run.
    static let folder = FileManager.default.temporaryDirectory
        .appending(path: "SerialNumberReader-under-test", directoryHint: .isDirectory)

    /// The message a refused attempt gives.
    static let refusal = "Refused under tests: the release check never reaches a real device or a saved connection."
}

/// The attempts of one kind refused under tests, one JSON line each.
nonisolated final class AttemptLog: Sendable {
    /// USB actions, device reads and `cfgutil`.
    static let usb = AttemptLog(fileURL: UnderTest.folder.appending(path: "usb-attempts.jsonl"))
    /// Requests to a saved connection. Method and path only, never the query
    /// (a lookup's query holds the serial number).
    static let savedConnections = AttemptLog(fileURL: UnderTest.folder.appending(path: "saved-connection-requests.jsonl"))

    nonisolated struct Attempt: Codable, Sendable, Equatable {
        var time: Date
        var process: String
        var what: String
    }

    let fileURL: URL
    private let lock = NSLock()
    private static let logger = Logger(subsystem: "be.jordythery.SerialNumberReader", category: "UnderTest")

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func record(_ what: String) {
        Self.logger.error("Refused under tests: \(what, privacy: .private)")
        let attempt = Attempt(time: Date(), process: ProcessInfo.processInfo.processName, what: what)
        guard let line = try? JSONEncoder().encode(attempt) else { return }
        lock.withLock {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // O_APPEND: the test host and the app the UI tests launch may both write.
            let descriptor = open(fileURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
            guard descriptor >= 0 else { return }
            defer { close(descriptor) }
            let data = line + Data("\n".utf8)
            _ = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        }
    }

    func attempts() -> [Attempt] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(Attempt.self, from: Data($0.utf8)) }
    }
}

/// Refuses everything that reaches a real USB device or starts `cfgutil`
/// while the app is under tests, and writes it down. Outside tests it does
/// nothing. The pretend iPhone is refused before this is asked, so demo mode
/// never counts as an attempt.
nonisolated struct USBGuard: Sendable {
    static let shared = USBGuard(isActive: UnderTest.isActive, log: .usb)

    let isActive: Bool
    let log: AttemptLog

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

/// The network of a store holding the saved connections while under tests:
/// every request, sign-in included, is refused before it's sent and written
/// down. Nothing leaves the Mac.
nonisolated enum SavedConnectionGuard {
    static func refusingSession(log: AttemptLog = .savedConnections) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RefusingURLProtocol.self]
        configuration.httpAdditionalHeaders = [RefusingURLProtocol.logHeader: log.fileURL.path]
        return URLSession(configuration: configuration)
    }

    final class RefusingURLProtocol: URLProtocol, @unchecked Sendable {
        static let logHeader = "X-SNR-Under-Test-Log"

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let path = request.value(forHTTPHeaderField: Self.logHeader)
            let log = path.map { AttemptLog(fileURL: URL(filePath: $0)) } ?? .savedConnections
            log.record("\(request.httpMethod ?? "GET") \(request.url?.host() ?? "")\(request.url?.path() ?? "")")
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled, userInfo: [NSLocalizedDescriptionKey: UnderTest.refusal]))
        }

        override func stopLoading() {}
    }
}
