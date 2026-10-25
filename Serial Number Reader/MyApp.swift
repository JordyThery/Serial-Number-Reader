import JTKit
import os
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

/// Owns the restore controller so quitting can be confirmed while a Restore
/// or Revive runs.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let restore = RestoreController()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard restore.isRunning else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "A restore is in progress"
        alert.informativeText = "Quitting interrupts it, which leaves the device in Recovery mode until it's restored again."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}

struct SerialNumberReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var monitor = USBDeviceMonitor()
    @State private var jamf = JamfStore()
    @State private var actions = DeviceActionController()
    @State private var updates: UpdateChecker = {
        let logger = Logger(subsystem: "be.jordythery.SerialNumberReader", category: "Updates")
        return UpdateChecker(
            configuration: UpdateConfiguration(owner: "JordyThery", repository: "Serial-Number-Reader", appName: "Serial Number Reader"),
            activity: { logger.info("\($0, privacy: .public)") }
        )
    }()

    var body: some Scene {
        WindowGroup {
            ContentView(monitor: monitor, jamf: jamf, actions: actions, restore: appDelegate.restore)
                .environment(updates)
                .frame(minWidth: 760, minHeight: 440)
                .task { await updates.checkAutomatically() }
        }
        .commands {
            AppInfoCommands(appName: "Serial Number Reader") { updates.checkManually() }
            CommandGroup(replacing: .importExport) {
                Button("Export Session…") { SessionExport.presentSavePanel(rows: sessionRows) }
                    .keyboardShortcut("e")
                    .disabled(monitor.devices.isEmpty)
                Button("Copy All Serial Numbers") { SessionExport.copySerials(rows: sessionRows) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(SessionExport.serials(sessionRows).isEmpty)
            }
        }

        SettingsWindow(updates: updates) {
            SettingsTab("Connections", systemImage: "network") {
                SettingsView(jamf: jamf)
            }
        }

        AboutWindow(configuration: .serialNumberReader)
    }

    /// The device list in connection order (oldest first), as export rows.
    private var sessionRows: [SessionExport.Row] {
        monitor.devices.reversed().map { SessionExport.row(for: $0, jamf: jamf.state(for: $0)) }
    }
}
