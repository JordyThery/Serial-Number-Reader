import Foundation

/// A settings domain of one test, kept out of ~/Library/Preferences: the
/// domain is a file path in the temporary folder (UserDefaults stores it at
/// that path). Emptying a named domain isn't enough, because macOS writes the
/// empty file back a moment later; the tests left one such file per test and
/// run in ~/Library/Preferences before.
final class TemporaryDefaults {
    static let folder = FileManager.default.temporaryDirectory
        .appending(path: "SerialNumberReader-test-settings", directoryHint: .isDirectory)

    let domain: String
    let defaults: UserDefaults

    init(_ purpose: String) {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        domain = Self.folder.appending(path: "\(purpose)-\(UUID().uuidString)").path
        // Never the real settings: without its own domain the test stops here.
        guard let defaults = Self.suite(domain) else {
            preconditionFailure("No settings domain at \(domain); the test won't fall back to the real settings.")
        }
        self.defaults = defaults
    }

    /// The domain's settings, or nil when it can't be made: never `.standard`.
    static func suite(_ domain: String) -> UserDefaults? {
        UserDefaults(suiteName: domain)
    }

    func remove() {
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(atPath: domain + ".plist")
    }

    /// Whether nothing of this domain is in ~/Library/Preferences.
    var leavesNothingInPreferences: Bool {
        let preferences = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Preferences").path
        let name = URL(filePath: domain).lastPathComponent
        let files = (try? FileManager.default.contentsOfDirectory(atPath: preferences)) ?? []
        return !files.contains { $0.contains(name) }
    }
}
