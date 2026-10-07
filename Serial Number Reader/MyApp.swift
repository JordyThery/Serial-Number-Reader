import SwiftUI

@main
struct MyApp {
    static func main() {
        // When re-launched as root with `--vdm <action>`, act as a CLI that
        // sends the USB-PD VDM and exits — the GUI never starts.
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--vdm"), index + 1 < args.count {
            exit(VDMTool.run(withAction: args[index + 1]))
        }
        SerialNumberReaderApp.main()
    }
}

struct SerialNumberReaderApp: App {
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
