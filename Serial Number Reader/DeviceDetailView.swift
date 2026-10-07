import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct DeviceDetailView: View {
    let device: USBDevice
    let jamf: JamfStore
    /// Shared app-wide so only one action runs at a time (the VDM path
    /// targets a port, not a specific device) and errors survive selection
    /// changes.
    let actions: DeviceActionController
    /// Number of currently connected devices; the VDM actions are offered
    /// only while exactly one device is attached, because the command goes
    /// to the first connected port, not to the selected device.
    let connectedDeviceCount: Int

    /// Raw descriptor fields are collapsed by default — they're diagnostic
    /// detail and take a lot of vertical space.
    @State private var descriptorFieldsExpanded = false

    var body: some View {
        Form {
            deviceSection

            if device.isConnected {
                powerSection
            }

            identifierSection

            if device.mode == .dfu {
                dfuSection
            }

            if let descriptor = device.descriptor, !descriptor.fields.isEmpty {
                descriptorSection(descriptor)
            }

            jamfSection
        }
        .formStyle(.grouped)
        .navigationSubtitle(device.modelDisplayName)
    }

    // MARK: Device

    private var deviceSection: some View {
        Section("Device") {
            LabeledContent("Mode") {
                ModeBadge(mode: device.mode)
            }
            LabeledContent("Model", value: device.modelDisplayName)
            if let identifier = device.modelInfo?.identifier {
                LabeledContent("Model Identifier", value: identifier)
            }
            if let name = device.usbProductName {
                LabeledContent("USB Product Name", value: name)
            }
            LabeledContent("USB Product ID", value: String(format: "0x%04X", device.productID))
        }
    }

    // MARK: Power (USB-PD VDM actions)

    private var powerSection: some View {
        Section {
            HStack(spacing: 10) {
                if device.mode == .normal, device.udid != nil {
                    Button {
                        actions.enterRecovery(device: device)
                    } label: {
                        Label("Enter Recovery", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(actions.runningAction != nil)
                    .help("Reboot this device into Recovery mode — no button presses or password needed")
                }

                if device.mode == .recovery {
                    Button {
                        actions.bootToNormal(device: device)
                    } label: {
                        Label("Boot to Normal", systemImage: "power")
                    }
                    .disabled(actions.runningAction != nil)
                    .help("Reboot this device out of Recovery into normal operation")
                }

                Button {
                    actions.restart()
                } label: {
                    Label("Restart", systemImage: "restart")
                }
                .disabled(actions.runningAction != nil || vdmUnavailable)
                .help(vdmUnavailable
                      ? "Disabled while multiple devices are connected — the USB-C command targets a port, not a specific device"
                      : "Force-restart via USB-C power delivery — requires an administrator password")

                if device.mode != .dfu {
                    Button {
                        actions.enterDFU()
                    } label: {
                        Label("Enter DFU", systemImage: "bolt.horizontal")
                    }
                    .disabled(actions.runningAction != nil || vdmUnavailable)
                    .help(vdmUnavailable
                          ? "Disabled while multiple devices are connected — the USB-C command targets a port, not a specific device"
                          : "Reboot into DFU mode via USB-C power delivery — requires an administrator password")
                }

                if actions.runningAction != nil {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }

            if let error = actions.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Power")
        } footer: {
            Text(powerFooterText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The USB-PD command goes to the first connected port, so with several
    /// devices attached it could hit the wrong one — offer it only for one.
    private var vdmUnavailable: Bool { connectedDeviceCount > 1 }

    private var powerFooterText: String {
        var text = switch device.mode {
        case .normal:
            "Enter Recovery asks the device to reboot into Recovery mode — the serial number then appears here automatically, no buttons needed. Restart and Enter DFU send a USB-C power-delivery command over any port and prompt for an administrator password."
        case .recovery:
            "Boot to Normal sends “auto-boot true” and reboots the device out of Recovery. Restart and Enter DFU send a USB-C power-delivery command over any port and prompt for an administrator password."
        case .dfu:
            "Restart sends a USB-C power-delivery command over any port — it works even in DFU — and prompts for an administrator password."
        }
        if vdmUnavailable {
            text += " Restart and Enter DFU are disabled while more than one device is connected, because the command targets a port rather than a specific device."
        }
        return text
    }

    // MARK: Identifiers

    private var identifierSection: some View {
        Section("Identifiers") {
            if let serial = device.serialNumber {
                CopyableRow(label: "Serial Number", value: serial, showsQR: true)
            } else if device.mode == .recovery {
                LabeledContent("Serial Number") {
                    Text("Not reported — the descriptor contains no SRNM field")
                        .foregroundStyle(.secondary)
                }
            } else if device.mode == .dfu {
                LabeledContent("Serial Number") {
                    Text("Not readable in DFU mode")
                        .foregroundStyle(.secondary)
                }
            } else {
                normalModeSerialRow
            }

            if let udid = device.udid {
                CopyableRow(label: "UDID", value: udid)
            }
            if let ecid = device.ecid {
                CopyableRow(label: "ECID", value: ecid)
            }
        }
    }

    /// Serial row for a booted device: the serial can only come from Jamf,
    /// so state exactly why it is or isn't available.
    @ViewBuilder
    private var normalModeSerialRow: some View {
        switch jamf.state(for: device) {
        case .found(let record):
            if let serial = record.serialNumber {
                CopyableRow(label: "Serial Number (from Jamf)", value: serial, showsQR: true)
            } else {
                unavailableSerialRow("Not present in the Jamf record")
            }
        case .notConfigured:
            unavailableSerialRow("Requires a Jamf Pro lookup — configure Jamf in Settings")
        case .noMatch:
            unavailableSerialRow("No matching Jamf record")
        case .multipleMatches:
            unavailableSerialRow("Ambiguous — multiple Jamf records match")
        case .failed:
            unavailableSerialRow("Jamf lookup failed — see the Jamf Pro section")
        case .unavailable(let reason):
            unavailableSerialRow(reason)
        case .loading:
            unavailableSerialRow("Pending Jamf lookup")
        }
    }

    private func unavailableSerialRow(_ text: String) -> some View {
        LabeledContent("Serial Number") {
            Text(text).foregroundStyle(.secondary)
        }
    }

    // MARK: DFU help

    private var dfuSection: some View {
        Section("Exit DFU → Enter Recovery Mode") {
            if device.isOpaqueDFU {
                Text("This device generation exposes no model, ECID or serial over USB in DFU mode (it enumerates as a locked-down “Debug USB” function). Only its presence can be detected.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            Text("The serial number is only readable in Recovery mode. Follow these steps; the device will reappear here automatically.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(DFUExitInstructions.instructions(forModelIdentifier: device.modelInfo?.identifier))
                .font(.callout)
                .textSelection(.enabled)
        }
    }

    // MARK: Descriptor

    private func descriptorSection(_ descriptor: ParsedDescriptor) -> some View {
        Section {
            DisclosureGroup("USB Descriptor Fields (\(descriptor.fields.count))", isExpanded: $descriptorFieldsExpanded) {
                ForEach(descriptor.fields, id: \.self) { field in
                    LabeledContent(field.key) {
                        Text(field.value.isEmpty ? "—" : field.value)
                            .monospaced()
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    // MARK: Jamf

    @ViewBuilder
    private var jamfSection: some View {
        Section("Jamf Pro") {
            switch jamf.state(for: device) {
            case .notConfigured:
                Text("Jamf Pro is not configured.")
                    .foregroundStyle(.secondary)
                SettingsLink {
                    Text("Open Settings…")
                }

            case .unavailable(let reason):
                Text(reason)
                    .foregroundStyle(.secondary)

            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking up…")
                        .foregroundStyle(.secondary)
                }

            case .found(let record):
                jamfRecordRows(record)

            case .noMatch:
                Label("No matching device in Jamf Pro.", systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
                retryButton

            case .multipleMatches(let count):
                Label("\(count) devices match in Jamf Pro — the record is ambiguous.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                retryButton

            case .failed(let message):
                Label(message, systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
                retryButton
            }
        }
    }

    @ViewBuilder
    private func jamfRecordRows(_ record: JamfDeviceRecord) -> some View {
        if let name = record.name {
            LabeledContent("Device Name", value: name)
        }
        if let serial = record.serialNumber {
            CopyableRow(label: "Serial Number", value: serial, showsQR: true)
        }
        if let udid = record.udid {
            CopyableRow(label: "UDID", value: udid)
        }
        if let model = record.model {
            LabeledContent("Model", value: model + (record.modelIdentifier.map { " (\($0))" } ?? ""))
        }
        if let os = record.osVersion {
            LabeledContent("OS Version", value: os)
        }
        if let managed = record.managed {
            LabeledContent("Managed") {
                Label(managed ? "Managed" : "Unmanaged",
                      systemImage: managed ? "checkmark.seal" : "xmark.seal")
                .foregroundStyle(managed ? .green : .secondary)
            }
        }
        if record.username != nil || record.realName != nil {
            LabeledContent("Assigned User") {
                VStack(alignment: .trailing) {
                    Text(record.realName ?? record.username ?? "")
                    if let username = record.username, record.realName != nil {
                        Text(username).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        AssetTagRow(record: record, device: device, jamf: jamf)

        if let date = record.lastInventoryDate {
            LabeledContent("Last Inventory Update",
                           value: date.formatted(date: .abbreviated, time: .shortened))
        }

        HStack {
            if let baseURL = jamf.baseURL, let url = record.webURL(baseURL: baseURL) {
                Link(destination: url) {
                    Label("Open in Jamf Pro", systemImage: "arrow.up.forward.app")
                }
            }
            Spacer()
            retryButton
        }
    }

    private var retryButton: some View {
        Button {
            jamf.refresh(for: device)
        } label: {
            Label("Retry Lookup", systemImage: "arrow.clockwise")
        }
        .help("Run the Jamf Pro lookup again")
    }
}

// MARK: - Asset tag row (editable)

struct AssetTagRow: View {
    let record: JamfDeviceRecord
    let device: USBDevice
    let jamf: JamfStore

    @State private var isEditing = false
    @State private var draft = ""
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        LabeledContent("Asset Tag") {
            if isEditing {
                HStack(spacing: 6) {
                    TextField("Asset tag", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .onSubmit(save)
                        .disabled(saving)
                    if saving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Save", action: save)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        Button("Cancel") {
                            isEditing = false
                            errorMessage = nil
                        }
                        .controlSize(.small)
                    }
                }
            } else {
                HStack(spacing: 6) {
                    Text(record.assetTag ?? "—")
                        .monospaced()
                        .foregroundStyle(record.assetTag == nil ? .secondary : .primary)
                        .textSelection(.enabled)
                    Button {
                        draft = record.assetTag ?? ""
                        errorMessage = nil
                        isEditing = true
                    } label: {
                        Image(systemName: "pencil")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Edit asset tag")
                }
            }
        }

        if let errorMessage {
            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func save() {
        guard !saving else { return }
        saving = true
        errorMessage = nil
        Task {
            if let error = await jamf.saveAssetTag(draft, record: record, for: device) {
                errorMessage = error.localizedDescription
            } else {
                isEditing = false
            }
            saving = false
        }
    }
}

// MARK: - Copyable value row

struct CopyableRow: View {
    let label: String
    let value: String
    /// Shows a QR button that pops up a scannable code of the value.
    var showsQR = false

    @State private var copied = false
    @State private var showingQR = false

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Text(value)
                    .monospaced()
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(copied ? .green : .secondary)
                }
                .buttonStyle(.borderless)
                .help("Copy \(label)")

                if showsQR {
                    Button {
                        showingQR = true
                    } label: {
                        Image(systemName: "qrcode")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Show \(label) as a scannable QR code")
                    .popover(isPresented: $showingQR, arrowEdge: .bottom) {
                        QRCodeView(text: value, caption: label)
                    }
                }
            }
        }
    }
}

// MARK: - QR code popover

/// A scannable QR code containing exactly the raw value (no URL wrapper),
/// so handheld scanners read it as plain text.
struct QRCodeView: View {
    let text: String
    let caption: String

    var body: some View {
        VStack(spacing: 12) {
            if let image = Self.qrImage(for: text) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
                    .accessibilityLabel("QR code for \(caption)")
            } else {
                ContentUnavailableView("Couldn't generate QR code", systemImage: "qrcode")
                    .frame(width: 220, height: 220)
            }
            Text(text)
                .font(.title3)
                .monospaced()
                .textSelection(.enabled)
        }
        .padding(20)
    }

    private static func qrImage(for string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // Integer upscale keeps the modules pixel-crisp.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
