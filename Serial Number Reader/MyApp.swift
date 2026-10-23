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
    @State private var actions = DeviceActionController()
    @State private var updates = UpdateChecker()

    var body: some Scene {
        WindowGroup {
            ContentView(monitor: monitor, jamf: jamf, actions: actions)
                .environment(updates)
                .frame(minWidth: 760, minHeight: 440)
                .task { await updates.checkAutomatically() }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updates.checkManually() }
            }
            CommandGroup(replacing: .importExport) {
                Button("Export Session…") { SessionExport.presentSavePanel(rows: sessionRows) }
                    .keyboardShortcut("e")
                    .disabled(monitor.devices.isEmpty)
                Button("Copy All Serial Numbers") { SessionExport.copySerials(rows: sessionRows) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(SessionExport.serials(sessionRows).isEmpty)
            }
        }

        Settings {
            SettingsView(jamf: jamf)
        }
    }

    /// The device list in connection order (oldest first), as export rows.
    private var sessionRows: [SessionExport.Row] {
        monitor.devices.reversed().map { SessionExport.row(for: $0, jamf: jamf.state(for: $0)) }
    }
}
