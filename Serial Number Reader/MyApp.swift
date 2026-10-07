import SwiftUI

@main
struct MyApp: App {
    @State private var monitor = USBDeviceMonitor()
    @State private var jamf = JamfStore()

    var body: some Scene {
        WindowGroup {
            ContentView(monitor: monitor, jamf: jamf)
                .frame(minWidth: 760, minHeight: 440)
        }

        Settings {
            SettingsView(jamf: jamf)
        }
    }
}
