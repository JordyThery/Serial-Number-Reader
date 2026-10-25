import SwiftUI

struct ContentView: View {
    let monitor: USBDeviceMonitor
    let jamf: JamfStore
    let actions: DeviceActionController
    let restore: RestoreController

    @Environment(UpdateChecker.self) private var updates
    @State private var selectedDeviceID: USBDevice.ID?

    private var selectedDevice: USBDevice? {
        monitor.devices.first { $0.id == selectedDeviceID }
    }

    var body: some View {
        NavigationSplitView {
            Group {
                if monitor.devices.isEmpty {
                    ContentUnavailableView(
                        "Connect an iPhone or iPad via USB",
                        systemImage: "cable.connector",
                        description: Text("Devices in Normal, Recovery and DFU mode are detected automatically — including devices that won't boot.")
                    )
                } else {
                    List(monitor.devices, selection: $selectedDeviceID) { device in
                        DeviceRow(device: device, jamfState: jamf.state(for: device),
                                  isPartOfRestore: restore.isPart(of: device))
                            .contextMenu {
                                Button("Remove from List", role: .destructive) {
                                    monitor.removeFromList(device.id)
                                }
                                .disabled(device.isConnected)
                            }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 340)
            .toolbar {
                Button {
                    monitor.clearDisconnected()
                } label: {
                    Label("Clear Disconnected", systemImage: "trash")
                }
                .help("Remove all disconnected devices from the list")
                .disabled(!monitor.hasDisconnectedDevices)
            }
        } detail: {
            Group {
                if let device = selectedDevice {
                    DeviceDetailView(
                        device: device,
                        jamf: jamf,
                        actions: actions,
                        restore: restore,
                        monitor: monitor,
                        connectedDeviceCount: monitor.devices.count(where: \.isConnected)
                    )
                    .id(device.id) // reset per-device view state on selection change
                } else {
                    ContentUnavailableView(
                        "No Device Selected",
                        systemImage: "sidebar.left",
                        description: Text(monitor.devices.isEmpty
                            ? "Connect an iPhone or iPad via USB."
                            : "Select a device from the list.")
                    )
                }
            }
            // In the detail column only, so it never covers the device list.
            .safeAreaInset(edge: .top, spacing: 0) {
                RestoreBanner(restore: restore)
            }
        }
        .navigationTitle("Serial Number Reader")
        .sheet(isPresented: Bindable(updates).isPresented) {
            UpdateView()
        }
        .task {
            monitor.start()
        }
        .onChange(of: monitor.devices, initial: true) {
            for device in monitor.devices {
                jamf.lookupIfNeeded(for: device)
            }
            // If nothing valid is selected, select the newest connection.
            if selectedDevice == nil {
                selectedDeviceID = monitor.devices.first?.id
            }
        }
        .onChange(of: jamf.configurationGeneration) {
            // Settings changed: cached results were dropped — look up again.
            for device in monitor.devices {
                jamf.lookupIfNeeded(for: device)
            }
        }
    }
}

// MARK: - List row

struct DeviceRow: View {
    let device: USBDevice
    let jamfState: JamfLookupState
    /// The device is passing through this mode as part of a Restore
    /// or Revive, so missing identifiers are expected rather than a problem.
    var isPartOfRestore = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.title2)
                .foregroundStyle(device.isConnected ? AnyShapeStyle(modeColor) : AnyShapeStyle(.secondary))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    // The model name wins space over the OS version; badges
                    // never truncate.
                    Text(device.modelDisplayName)
                        .font(.headline)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let os = device.lockdownInfo?.productVersion {
                        Text(osShortName + " " + os)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    ModeBadge(mode: device.mode)
                        .fixedSize()
                    if !device.isConnected {
                        Text("Disconnected")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.gray.opacity(0.18), in: Capsule())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                Text(serialLine)
                    .font(.callout)
                    .monospaced()
                    .foregroundStyle(device.serialNumber == nil && jamfSerial == nil ? .secondary : .primary)
                    .lineLimit(1)
                Text(jamfStatusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .help(connectionTooltip)
    }

    private var jamfSerial: String? {
        if case .found(let record) = jamfState { return record.serialNumber }
        return nil
    }

    private var serialLine: String {
        if let serial = device.serialNumber ?? jamfSerial { return serial }
        if isPartOfRestore { return "Part of the restore — no serial in this stage" }
        // Booted devices, and DFU devices identified through Configurator,
        // can only get their serial from Jamf.
        let serialComesFromJamf = device.mode == .normal || (device.mode == .dfu && device.jamfQuery != nil)
        guard serialComesFromJamf else { return device.serialStatusText }
        // A booted device's serial can only come from Jamf — be precise
        // about why it isn't available.
        switch jamfState {
        case .notConfigured: return "Serial requires Jamf Pro (not configured)"
        case .noMatch: return "Serial unknown — no Jamf match"
        case .multipleMatches: return "Serial ambiguous — multiple Jamf matches"
        case .failed: return "Serial unavailable — Jamf lookup failed"
        case .unavailable: return "Serial unavailable — no UDID reported"
        case .found: return "Serial not present in the Jamf record"
        case .loading: return "Serial pending Jamf lookup"
        }
    }

    private var connectionTooltip: String {
        let connected = "Connected \(device.connectedAt.formatted(date: .omitted, time: .standard))"
        guard let disconnectedAt = device.disconnectedAt else { return connected }
        return "\(connected) · Disconnected \(disconnectedAt.formatted(date: .omitted, time: .standard))"
    }

    private var jamfStatusLine: String {
        switch jamfState {
        case .notConfigured: "Jamf: not configured (see Settings)"
        case .unavailable(let reason): "Jamf: \(reason)"
        case .loading: "Jamf: looking up…"
        case .found(let record): "Jamf: \(record.name ?? "matched") · \(record.managed == true ? "Managed" : "Unmanaged")"
        case .noMatch: "Jamf: no match"
        case .multipleMatches(let count): "Jamf: \(count) matches"
        case .failed: "Jamf: lookup failed"
        }
    }

    private var osShortName: String {
        device.lockdownInfo?.deviceClass == "iPad" ? "iPadOS" : "iOS"
    }

    private var iconName: String {
        // A booted device reports its class; trust that over name heuristics.
        switch device.lockdownInfo?.deviceClass {
        case "iPad": return "ipad"
        case "iPhone", "iPod": return "iphone"
        default: break
        }
        if device.modelInfo?.identifier.hasPrefix("Mac") == true { return "laptopcomputer" }
        if device.modelDisplayName.localizedCaseInsensitiveContains("ipad") { return "ipad" }
        // Opaque DFU devices expose no identifiers — don't imply a device type.
        if device.isOpaqueDFU { return "apple.logo" }
        return "iphone"
    }

    private var modeColor: Color {
        switch device.mode {
        case .normal: .green
        case .recovery: .orange
        case .dfu: .red
        }
    }
}

struct ModeBadge: View {
    let mode: DeviceMode

    var body: some View {
        Text(mode.rawValue)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch mode {
        case .normal: .green
        case .recovery: .orange
        case .dfu: .red
        }
    }
}

#Preview {
    ContentView(monitor: USBDeviceMonitor(), jamf: JamfStore(), actions: DeviceActionController(),
                restore: RestoreController())
        .environment(UpdateChecker())
}
