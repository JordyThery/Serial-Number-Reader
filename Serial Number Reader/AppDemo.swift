import Foundation
import JTKit

/// The app's demo mode, one per launch: JTKit's switch (saved under
/// `demoMode`) and the pretend iPhone.
@MainActor
enum AppDemo {
    static let mode = DemoMode(key: "demoMode", defaults: defaults)
    static let usb = DemoUSB(mode: mode)

    /// Where the switch is saved: the app's settings; as the unit-test host
    /// its throwaway settings. A sandbox run saves nothing (JTKit).
    private static var defaults: UserDefaults {
        guard JamfConnectionStore.isUnitTestHost else { return .standard }
        return UserDefaults(suiteName: JamfConnectionStore.unitTestHostDomain) ?? .standard
    }

    /// The saved connections for this launch: in a sandbox run (`-JTKitSandbox
    /// YES`, UI tests) an empty list in memory and no Keychain, so the real
    /// ones are never read or written.
    static func connections() -> JamfConnectionStore {
        if JamfConnectionStore.isUnitTestHost { return .forUnitTestHost() }
        if isSandboxLaunch { return JamfConnectionStore(defaults: DemoMode.sandboxDefaults(), secrets: SandboxSecretStore()) }
        return JamfConnectionStore()
    }

    /// Started with `-JTKitSandbox YES`: no update check and no ipsw.me lookups.
    nonisolated static var isSandboxLaunch: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.lastIndex(of: DemoMode.sandboxArgument), arguments.indices.contains(index + 1)
        else { return false }
        return ["yes", "true", "1"].contains(arguments[index + 1].lowercased())
    }
}
