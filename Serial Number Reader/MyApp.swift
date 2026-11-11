import JTKit
import os
import SwiftUI

@main
struct MyApp {
    static func main() {
        // When re-launched as root with `--vdm <action> --entry <hex>`, act as
        // a CLI that sends the USB-PD VDM to that device's port and exits —
        // the GUI never starts. Any other use of `--vdm` exits too.
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--vdm") {
            guard let parsed = PrivilegedVDM.parse(args) else {
                FileHandle.standardError.write(Data("Unknown arguments.\n".utf8))
                exit(1)
            }
            exit(PrivilegedVDM.run(parsed))
        }
        SerialNumberReaderApp.main()
    }
}

/// Owns the restore controller so quitting can be confirmed while a Restore
/// or Revive runs, and the USB actions, linked to it so neither starts while
/// the other runs; and the device list both watch for a device to come back.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = USBDeviceMonitor(demo: AppDemo.usb)
    let restore = RestoreController(activityLog: .app, demo: AppDemo.usb)
    let actions = DeviceActionController(activityLog: .app, demo: AppDemo.usb)

    override init() {
        super.init()
        actions.restore = restore
        restore.actions = actions
        let watch = DeviceReturnWatch { [monitor] in monitor.devices }
        actions.returnWatch = watch
        restore.returnWatch = watch
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard restore.isRunning else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = restore.job?.kind == .revive ? "A revive is in progress." : "A restore is in progress."
        alert.informativeText = "Quitting interrupts it, which leaves the device in Recovery mode until it’s restored again."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Quit Anyway").hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}

struct SerialNumberReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var jamf = JamfStore(connections: AppDemo.connections, activityLog: .app, demo: AppDemo.mode)
    @State private var appleBusiness = AppleBusinessStore(connections: AppDemo.connections, activityLog: .app, demo: AppDemo.mode)
    @State private var updates: UpdateChecker = {
        let logger = Logger(subsystem: "be.jordythery.SerialNumberReader", category: "Updates")
        return UpdateChecker(
            configuration: UpdateConfiguration(owner: "JordyThery", repository: "Serial-Number-Reader", appName: "Serial Number Reader"),
            // A failed check can hold GitHub's answer: private in the system log.
            activity: { logger.info("\($0, privacy: .private)") }
        )
    }()

    private var monitor: USBDeviceMonitor { appDelegate.monitor }

    var body: some Scene {
        WindowGroup {
            ContentView(monitor: monitor, jamf: jamf, appleBusiness: appleBusiness, actions: appDelegate.actions, restore: appDelegate.restore)
                .environment(updates)
                .frame(minWidth: 760, minHeight: 440)
                .task {
                    // No update check under tests: neither in a sandbox run nor
                    // as the unit-test host (it shares the app's settings).
                    guard !TestRun.isActive else { return }
                    await updates.checkAutomatically()
                }
        }
        .commands {
            AppInfoCommands(appName: "Serial Number Reader") { updates.checkManually() }
            // The toolbar pickers' items, as JTKit's Connection menu: Jamf,
            // then Apple, each under its role's title.
            ConnectionCommands(
                store: jamf.connections.connections,
                roles: [jamf.connectionRole(selection: Binding(get: { jamf.connections.activeID },
                                                               set: { jamf.connections.activeID = $0 })),
                        appleBusiness.connectionRole(selection: Binding(get: { jamf.connections.activeAppleID },
                                                                        set: { jamf.connections.activeAppleID = $0 }))]
            ) {
                DemoModeSwitch(actions: appDelegate.actions, restore: appDelegate.restore)
            }
            // The selected device's actions, as in its detail view.
            CommandMenu("Device") {
                DeviceMenu()
            }
            CommandGroup(replacing: .importExport) {
                Button("Export Session…") { SessionExport.presentSavePanel(rows: sessionRows) }
                    .keyboardShortcut("e")
                    .disabled(monitor.devices.isEmpty)
                Button("Copy All Serial Numbers") { SessionExport.copySerials(rows: sessionRows) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(SessionExport.serials(sessionRows).isEmpty)
                Divider()
                // The toolbar button's command, also in the menu bar.
                Button("Clear Disconnected") { monitor.clearDisconnected() }
                    .disabled(!monitor.hasDisconnectedDevices)
            }
        }

        // JTKit's Settings window: Connections and Updates (no General tab:
        // the app has no general settings; it follows the Mac's appearance).
        SettingsWindow(updates: updates, opensTabsByName: true) {
            SettingsView(jamf: jamf, appleBusiness: appleBusiness)
                // Settings › Connections notes that these are the real connections.
                .environment(AppDemo.mode)
        }

        AboutWindow(configuration: .serialNumberReader)

        // JTKit's shared activity log (Window › Activity Log, ⇧⌘L).
        ActivityLogWindow(
            log: jamf.activityLog,
            emptyDescription: "Sign-ins, Jamf lookups, asset tag changes, connection tests, retries and USB actions appear here as they happen."
        )
    }

    /// The Apple Business lookup of a device, as far as it already ran (never
    /// starts one): the serial from the device, or from its Jamf record.
    private func appleBusinessState(for device: USBDevice) -> AppleBusinessLookupState? {
        guard appleBusiness.isConfigured else { return nil }
        var serial = device.serialNumber
        if serial == nil, case .found(let record) = jamf.state(for: device) { serial = record.serialNumber }
        return appleBusiness.stateSoFar(forSerial: serial)
    }

    /// The device list in connection order (oldest first), as export rows.
    private var sessionRows: [SessionExport.Row] {
        monitor.devices.reversed().map { SessionExport.row(for: $0, jamf: jamf.state(for: $0), appleBusiness: appleBusinessState(for: $0)) }
    }
}

extension ActivityLog {
    /// The app's one activity log: Jamf requests, and the USB actions and
    /// restores (Window › Activity Log).
    static let app = ActivityLog()
}
