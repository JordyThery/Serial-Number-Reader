import SwiftUI

struct ContentView: View {
    let monitor: USBDeviceMonitor
    let jamf: JamfStore

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
                        DeviceRow(device: device, jamfState: jamf.state(for: device))
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
            if let device = selectedDevice {
                DeviceDetailView(device: device, jamf: jamf)
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
        .navigationTitle("Serial Number Reader")
        .task {
            monitor.start()
        }
        .onChange(of: monitor.devices, initial: true) {
            for device in monitor.devices {
                jamf.lookupIfNeeded(for: device)
            }
            // Keep the selection valid and auto-select a sole device.
            if selectedDevice == nil {
                selectedDeviceID = monitor.devices.first?.id
            }
        }
    }
}

// MARK: - List row

struct DeviceRow: View {
    let device: USBDevice
    let jamfState: JamfLookupState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.title2)
                .foregroundStyle(device.isConnected ? AnyShapeStyle(modeColor) : AnyShapeStyle(.secondary))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.modelDisplayName)
                        .font(.headline)
                        .lineLimit(1)
                    ModeBadge(mode: device.mode)
                    if !device.isConnected {
                        Text("Disconnected")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.gray.opacity(0.18), in: Capsule())
                            .foregroundStyle(.secondary)
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
    }

    private var jamfSerial: String? {
        if case .found(let record) = jamfState { return record.serialNumber }
        return nil
    }

    private var serialLine: String {
        device.serialNumber ?? jamfSerial ?? device.serialStatusText
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

    private var iconName: String {
        if device.modelInfo?.identifier.hasPrefix("Mac") == true { return "laptopcomputer" }
        if device.modelDisplayName.localizedCaseInsensitiveContains("ipad") { return "ipad" }
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
    ContentView(monitor: USBDeviceMonitor(), jamf: JamfStore())
}
