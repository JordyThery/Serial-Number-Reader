import Foundation
import JTKit

/// The app's demo mode, one per launch: JTKit's switch (saved under
/// `demoMode`) and the pretend iPhone.
@MainActor
enum AppDemo {
    static let mode = DemoMode(key: "demoMode", defaults: defaults)
    static let usb = DemoUSB(mode: mode)

    /// Where the switch is saved: the app's settings; as the unit-test host
    /// its throwaway settings, emptied first, so a switch left on by an
    /// earlier run can't turn demo mode on for this one. A sandbox run saves
    /// nothing (JTKit).
    private static var defaults: UserDefaults {
        guard TestRun.isUnitTestHost else { return .standard }
        return JamfConnectionStore.emptiedDefaults(domain: JamfConnectionStore.unitTestHostDomain)
    }

    /// The saved connections for this launch: in a sandbox run (`-JTKitSandbox
    /// YES`, UI tests) an empty list in memory and no Keychain, so the real
    /// ones are never read or written.
    static func connections() -> JamfConnectionStore {
        if TestRun.isUnitTestHost { return .forUnitTestHost() }
        if DemoMode.isSandboxLaunch { return JamfConnectionStore(defaults: DemoMode.sandboxDefaults(), secrets: SandboxSecretStore()) }
        return JamfConnectionStore()
    }
}
