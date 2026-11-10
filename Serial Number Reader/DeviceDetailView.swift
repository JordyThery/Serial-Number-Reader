import AppKit
import CoreImage.CIFilterBuiltins
import JTKit
import SwiftUI

/// Runs the Apple Business lookup again when the serial number becomes known
/// or the account changes.
private struct AppleBusinessLookupKey: Hashable {
    let serial: String?
    let generation: Int
}

struct DeviceDetailView: View {
    let device: USBDevice
    let jamf: JamfStore
    let appleBusiness: AppleBusinessStore
    /// Shared app-wide so only one action runs at a time (the VDM path
    /// targets a port, not a specific device) and errors survive selection
    /// changes.
    let actions: DeviceActionController
    /// Shared app-wide: one Restore or Revive at a time.
    let restore: RestoreController
    let monitor: USBDeviceMonitor
    /// Number of currently connected devices; the VDM actions are offered
    /// only while exactly one device is attached, because the command goes
    /// to the first connected port, not to the selected device.
    let connectedDeviceCount: Int

    /// Raw descriptor fields are collapsed by default — they're diagnostic
    /// detail and take a lot of vertical space.
    @State private var descriptorFieldsExpanded = false
    @State private var showingRestore = false
    @State private var showingRevive = false
    /// The asset tag editor is open: Remove from List waits (⌘⌫ also deletes text).
    @State private var editingAssetTag = false

    var body: some View {
        Form {
            deviceSection

            if device.isConnected {
                actionsSection
            }

            identifierSection

            if device.mode == .dfu {
                dfuSection
            }

            if let descriptor = device.descriptor, !descriptor.fields.isEmpty {
                descriptorSection(descriptor)
            }

            jamfSection

            if appleBusiness.isConfigured {
                appleBusinessSection
            }
        }
        .formStyle(.grouped)
        .navigationSubtitle(device.modelDisplayName)
        .task { monitor.refreshTrust(deviceID: device.id) }
        // The serial number is known from the device (Recovery) or, in Normal
        // mode, once Jamf has answered; an account change looks up again.
        .task(id: AppleBusinessLookupKey(serial: knownSerial, generation: appleBusiness.configurationGeneration)) {
            appleBusiness.lookupIfNeeded(serial: knownSerial)
        }
        .sheet(isPresented: $showingRestore) {
            RestoreSheet(device: device, serialNumber: knownSerial, jamfName: jamfRecord?.name, restore: restore)
        }
        .sheet(isPresented: $showingRevive) {
            ReviveSheet(device: device, serialNumber: knownSerial, jamfName: jamfRecord?.name, restore: restore)
        }
        // The Device menu: the same actions, on the same conditions.
        .focusedSceneValue(\.deviceActions, menuActions)
    }

    /// What the Device menu offers for this device; nil where the button
    /// isn't shown or is dimmed, and for every device action while the
    /// Restore or Revive sheet is open.
    private var menuActions: DeviceMenuActions {
        let can = availability(sheetOpen: showingRestore || showingRevive)
        let deviceID = device.id
        return DeviceMenuActions(
            enterRecovery: can.enterRecovery ? { actions.enterRecovery(device: device) } : nil,
            bootToNormal: can.bootToNormal ? { actions.bootToNormal(device: device) } : nil,
            restart: can.restart ? { actions.restart(device: device) } : nil,
            enterDFU: can.enterDFU ? { actions.enterDFU(device: device) } : nil,
            restore: can.restore ? { showingRestore = true } : nil,
            revive: can.restore ? { showingRevive = true } : nil,
            removeTrust: can.removeTrust ? { actions.removeTrust(device: device) { monitor.markUntrusted(deviceID: deviceID) } } : nil,
            retryLookup: can.retryLookup ? { jamf.refresh(for: device) } : nil,
            removeFromList: can.removeFromList ? { monitor.removeFromList(deviceID) } : nil
        )
    }

    /// Which actions are possible now, for the buttons and the Device menu.
    private func availability(sheetOpen: Bool = false) -> DeviceActionAvailability {
        DeviceActionAvailability(device: device, busy: isBusy || sheetOpen, editingAssetTag: editingAssetTag,
                                 connectedDeviceCount: connectedDeviceCount,
                                 configuratorAvailable: actions.isConfiguratorAvailable,
                                 jamfState: jamf.state(for: device))
    }

    private var jamfRecord: JamfDeviceRecord? {
        if case .found(let record) = jamf.state(for: device) { return record }
        return nil
    }

    private var knownSerial: String? { device.serialNumber ?? jamfRecord?.serialNumber }

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
            if let os = device.lockdownInfo?.osDisplayName {
                LabeledContent("OS Version", value: os)
            }
            if let name = device.lockdownInfo?.deviceName {
                LabeledContent("Device Name", value: name)
            }
            if let name = device.usbProductName {
                LabeledContent("USB Product Name", value: name)
            }
            LabeledContent("USB Product ID", value: String(format: "0x%04X", device.productID))
        }
    }

    // MARK: Actions (power, mode, restore, trust)

    /// Any action — or a Restore/Revive — in progress blocks the others: they
    /// would interrupt each other.
    private var isBusy: Bool { actions.runningAction != nil || restore.isRunning }

    private var actionsSection: some View {
        let can = availability()
        let offers = DeviceActionAvailability.Offers(device: device)
        return Section {
            // Wraps onto a second line in a narrow window instead of cutting labels off.
            WrappingHStack(spacing: 10, lineSpacing: 8) {
                if offers.enterRecovery {
                    Button {
                        actions.enterRecovery(device: device)
                    } label: {
                        Label("Enter Recovery", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(!can.enterRecovery)
                    .help("Reboot this device into Recovery mode, where its serial number is readable — no button presses or password needed")
                }

                if offers.bootToNormal {
                    Button {
                        actions.bootToNormal(device: device)
                    } label: {
                        Label("Boot to Normal", systemImage: "power")
                    }
                    .disabled(!can.bootToNormal)
                    .help("Reboot this device out of Recovery into normal operation")
                }

                Button {
                    actions.restart(device: device)
                } label: {
                    Label("Restart", systemImage: "restart")
                }
                .disabled(!can.restart)
                .help(vdmUnavailable
                      ? Self.vdmUnavailableHelp
                      : "Force-restart over USB-C power delivery — requires an administrator password")

                if offers.enterDFU {
                    Button {
                        actions.enterDFU(device: device)
                    } label: {
                        Label("Enter DFU", systemImage: "bolt.horizontal")
                    }
                    .disabled(!can.enterDFU)
                    .help(vdmUnavailable
                          ? Self.vdmUnavailableHelp
                          : "Reboot into DFU mode over USB-C power delivery — requires an administrator password")
                }

                if offers.restore {
                    Button {
                        showingRestore = true
                    } label: {
                        Label("Restore…", systemImage: "arrow.down.circle")
                    }
                    .disabled(!can.restore)
                    .help(restoreUnavailableReason ?? "Erase the device and install the latest or a specific version of its operating system")

                    Button {
                        showingRevive = true
                    } label: {
                        Label("Revive…", systemImage: "cross.case")
                    }
                    .disabled(!can.restore)
                    .help(restoreUnavailableReason ?? "Reinstall the operating system and keep the device’s content")
                }

                if offers.removeTrust {
                    Button {
                        let deviceID = device.id
                        actions.removeTrust(device: device) { monitor.markUntrusted(deviceID: deviceID) }
                    } label: {
                        Label("Remove Trust", systemImage: "lock.open.trianglebadge.exclamationmark")
                    }
                    .disabled(!can.removeTrust)
                    .help(actions.isConfiguratorAvailable
                          ? "Remove the pairing between this Mac and the device, on both sides"
                          : Configurator.notInstalledHelp)
                }

                if actions.runningAction != nil {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if actions.trustRequiredDeviceID == device.id {
                trustGuidance
            }

            if let error = actions.lastError {
                TintedLabel(error, systemImage: "xmark.octagon.fill", tint: .red)
                    .font(.caption)
            }
        } header: {
            Text("Actions")
        } footer: {
            Text(actionsFooterText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Shown when the device refused Enter Recovery because it doesn't trust
    /// this Mac (iOS 27 and later).
    private var trustGuidance: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("On iOS 27 and later, Enter Recovery only works from a Mac this device trusts.",
                  systemImage: "lock.shield")
                .font(.callout.weight(.semibold))
            Text("Unlock the device, tap Trust and enter its passcode, then click Enter Recovery again. Or enter Recovery mode with the buttons:")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(RecoveryModeInstructions.instructions(forModelIdentifier: device.modelInfo?.identifier))
                .font(.callout)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }

    /// Why Restore and Revive can't run for this device, or nil when they can.
    private var restoreUnavailableReason: String? {
        DeviceActionAvailability.restoreUnavailableReason(device: device, configuratorAvailable: actions.isConfiguratorAvailable)
    }

    /// The USB-PD command goes to a port, not a device, so with several
    /// devices attached it could hit the wrong one — offer it only for one.
    /// (The root helper refuses too when more than one port has something.)
    private var vdmUnavailable: Bool { DeviceActionAvailability.vdmUnavailable(connectedDeviceCount: connectedDeviceCount) }

    private static let vdmUnavailableHelp =
        "Disabled while more than one device is connected — the USB-C command targets a port, not a specific device"

    /// Short: each button's help says the rest.
    private var actionsFooterText: String {
        var text = switch device.mode {
        case .normal:
            "Enter Recovery makes the serial number readable; on iOS 27 and later the device must trust this Mac. Restart and Enter DFU need a USB-C device and an administrator password."
        case .recovery:
            "Restore erases the device; Revive keeps its content. Both use Apple Configurator. Restart and Enter DFU need a USB-C device and an administrator password."
        case .dfu:
            "Restore erases the device; Revive keeps its content. Both use Apple Configurator. Restart needs a USB-C device and an administrator password."
        }
        if vdmUnavailable {
            text += " With more than one device connected, Restart and Enter DFU are off: they target a port, not a device."
        }
        if PretendIPhone.isPretend(device) {
            text += " Demo Mode: every action is simulated."
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
                    Text(USBDevice.noSRNM)
                        .foregroundStyle(.secondary)
                }
            } else if device.mode == .dfu, device.jamfQuery == nil {
                LabeledContent("Serial Number") {
                    Text("Not readable in DFU mode")
                        .foregroundStyle(.secondary)
                }
            } else {
                jamfSerialRow
            }

            if let udid = device.displayUDID {
                CopyableRow(label: "UDID", value: udid)
            }
            if let ecid = device.ecid {
                CopyableRow(label: "ECID", value: ecid)
            }
        }
    }

    /// Serial row when the serial can only come from Jamf (booted devices, and
    /// DFU devices identified through Configurator), stating exactly why it
    /// is or isn't available.
    @ViewBuilder
    private var jamfSerialRow: some View {
        switch jamf.state(for: device) {
        case .found(let record):
            if let serial = record.serialNumber {
                CopyableRow(label: "Serial Number (from Jamf)", value: serial, showsQR: true)
            } else {
                unavailableSerialRow(JamfLookupState.found(record).serialUnavailableText)
            }
        case let state:
            // The sidebar's words for the same state.
            unavailableSerialRow(state.serialUnavailableText)
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
                if device.configurator != nil {
                    Text("Identified through Apple Configurator. Its serial number isn’t available over USB in DFU mode — it comes from Jamf when the device is enrolled, or appears in Recovery mode.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    WarningLabel("This device generation exposes no model, ECID or serial over USB in DFU mode (it enumerates as a locked-down “Debug USB” function). "
                         + (actions.isConfiguratorAvailable
                            ? "Apple Configurator hasn’t identified it yet."
                            : "With Apple Configurator installed, Serial Number Reader identifies it automatically."))
                        .font(.callout)
                }
            }
            Text("The serial number is readable in Recovery mode. Follow these steps; the device will reappear here automatically.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(RecoveryModeInstructions.instructions(forModelIdentifier: device.modelInfo?.identifier))
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

    // MARK: Apple Business and Apple School Manager

    private var appleBusinessSection: some View {
        Section(appleBusiness.productName) {
            switch appleBusiness.state(forSerial: knownSerial) {
            case .notConfigured:
                EmptyView()

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
                appleBusinessRecordRows(record)

            case .notInOrganization:
                Label("This device isn’t in your \(appleBusiness.productName) organization.", systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
                appleBusinessRetryButton

            case .failed(let message):
                TintedLabel(message, systemImage: "xmark.octagon.fill", tint: .red)
                    .textSelection(.enabled)
                appleBusinessRetryButton
            }
        }
    }

    @ViewBuilder
    private func appleBusinessRecordRows(_ record: AppleBusinessRecord) -> some View {
        let device = record.device
        // The serial number is in the Device section already.
        if let model = device.deviceModel {
            LabeledContent("Model", value: model)
        }
        if let family = AppleBusinessText.productFamily(device) {
            LabeledContent("Product Family", value: family)
        }
        LabeledContent("Status") {
            appleBusinessStatus(device)
        }
        if let problem = record.serverProblem {
            TintedLabel("The MDM server couldn’t be read: \(problem)", systemImage: "exclamationmark.triangle.fill", tint: .orange)
                .textSelection(.enabled)
        } else {
            LabeledContent("MDM Server", value: record.mdmServerName ?? "None")
        }
        if let order = device.orderNumber {
            LabeledContent("Order Number", value: order)
        }
        if let source = AppleBusinessText.purchaseSource(device) {
            LabeledContent("Purchase Source", value: source)
        }
        if let added = device.addedToOrgDateTime.flatMap(ABM.date) {
            LabeledContent("Added", value: added.formatted(date: .abbreviated, time: .omitted))
        }
        if let problem = record.coverageProblem {
            TintedLabel("AppleCare couldn’t be read: \(problem)", systemImage: "exclamationmark.triangle.fill", tint: .orange)
                .textSelection(.enabled)
        } else if record.coverage.isEmpty {
            LabeledContent("AppleCare", value: "No coverage listed")
        } else {
            ForEach(record.coverage) { coverage in
                LabeledContent(coverage.description ?? "AppleCare") {
                    Text(AppleBusinessText.coverage(coverage))
                        .foregroundStyle(coverage.isActive ? Color.primary : Color.secondary)
                }
            }
        }
        HStack {
            if let url = appleBusiness.portalURL {
                Link(destination: url) {
                    Label("Open in \(appleBusiness.productName)", systemImage: "arrow.up.forward.app")
                }
                .help("Opens \(appleBusiness.productName); search for the serial number there")
            }
            Spacer()
            appleBusinessRetryButton
        }
    }

    /// Green for Assigned only; Unassigned in orange (it can't enroll until
    /// it is assigned); Released and anything else neutral.
    private func appleBusinessStatus(_ device: ABM.OrgDevice) -> some View {
        let text = AppleBusinessText.status(device)
        return switch AppleBusinessText.statusKind(device) {
        case .assigned: TintedLabel(text, systemImage: "checkmark.seal.fill", tint: .green)
        case .unassigned: TintedLabel(text, systemImage: "exclamationmark.circle", tint: .orange)
        case .released: TintedLabel(text, systemImage: "xmark.seal", tint: .secondary)
        case .other: TintedLabel(text, systemImage: "questionmark.circle", tint: .secondary)
        }
    }

    private var appleBusinessRetryButton: some View {
        Button {
            appleBusiness.refresh(serial: knownSerial)
        } label: {
            Label("Retry Lookup", systemImage: "arrow.clockwise")
        }
        .help("Run the \(appleBusiness.productName) lookup again")
    }

    // MARK: Jamf

    @ViewBuilder
    private var jamfSection: some View {
        Section(jamf.productName) {
            switch jamf.state(for: device) {
            case .notConfigured:
                Text(JamfLookupState.noConnectionText)
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
                Label("No matching device in \(jamf.productName).", systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
                retryButton

            case .multipleMatches(let count):
                TintedLabel("\(count) devices match in \(jamf.productName) — the record is ambiguous.",
                            systemImage: "exclamationmark.triangle.fill", tint: .orange)
                retryButton

            case .failed(let message):
                TintedLabel(message, systemImage: "xmark.octagon.fill", tint: .red)
                    .textSelection(.enabled)
                retryButton
            }
        }
    }

    @ViewBuilder
    private func jamfRecordRows(_ record: JamfDeviceRecord) -> some View {
        if let name = record.name {
            LabeledContent("Jamf Name", value: name)
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
                TintedLabel(managed ? "Managed" : "Unmanaged",
                            systemImage: managed ? "checkmark.seal.fill" : "xmark.seal", tint: managed ? .green : .secondary)
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
        AssetTagRow(record: record, device: device, jamf: jamf, isEditing: $editingAssetTag)

        if let date = record.lastInventoryDate {
            LabeledContent("Last Inventory Update",
                           value: date.formatted(date: .abbreviated, time: .shortened))
        }

        HStack {
            if let baseURL = jamf.webBaseURL, let url = record.webURL(baseURL: baseURL) {
                Link(destination: url) {
                    Label("Open in \(jamf.productName)", systemImage: "arrow.up.forward.app")
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
        .help("Run the \(jamf.productName) lookup again")
    }
}

// MARK: - Asset tag row (editable)

struct AssetTagRow: View {
    let record: JamfDeviceRecord
    let device: USBDevice
    let jamf: JamfStore
    /// Shared with the detail view, which keeps Remove from List off meanwhile.
    @Binding var isEditing: Bool
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
                        .keyboardShortcut(.cancelAction)
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
                            // the desktop minimum hit area (20 × 20 pt)
                            .frame(minWidth: 20, minHeight: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("Edit asset tag")
                    .accessibilityLabel("Edit Asset Tag")
                }
            }
        }

        if let errorMessage {
            TintedLabel(errorMessage, systemImage: "xmark.octagon.fill", tint: .red)
                .font(.caption)
        }
    }

    private func save() {
        guard !saving else { return }
        saving = true
        errorMessage = nil
        Task {
            if let error = await jamf.saveAssetTag(draft, record: record, for: device) {
                errorMessage = error
            } else {
                isEditing = false
            }
            saving = false
        }
    }
}

// MARK: - Status text

/// A status or error line: the symbol carries the color, the text stays in
/// the primary color, so it's readable in light, dark and Increase Contrast
/// (red, orange or green text at caption size is below 4.5:1 on the window
/// background) and the meaning never rests on color alone.
struct TintedLabel: View {
    let text: String
    let systemImage: String
    let tint: Color

    init(_ text: String, systemImage: String, tint: Color) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
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
                        // the desktop minimum hit area (20 × 20 pt)
                        .frame(minWidth: 20, minHeight: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Copy \(label)")
                .accessibilityLabel("Copy \(label)")
                .accessibilityValue(copied ? "Copied" : "")

                if showsQR {
                    Button {
                        showingQR = true
                    } label: {
                        Image(systemName: "qrcode")
                            .foregroundStyle(.secondary)
                            // the desktop minimum hit area (20 × 20 pt)
                            .frame(minWidth: 20, minHeight: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("Show \(label) as a scannable QR code")
                    .accessibilityLabel("Show \(label) as QR Code")
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
                ContentUnavailableView("Couldn’t Generate QR Code", systemImage: "qrcode")
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

// MARK: - Which actions are possible

/// Which of a device's actions are offered (shown) and possible now, for the
/// detail view's buttons and the Device menu alike.
nonisolated struct DeviceActionAvailability: Equatable {
    /// Which buttons the device's mode shows.
    struct Offers: Equatable {
        var enterRecovery: Bool
        var bootToNormal: Bool
        var enterDFU: Bool
        /// Restore and Revive.
        var restore: Bool
        var removeTrust: Bool

        init(device: USBDevice) {
            enterRecovery = device.mode == .normal && device.udid != nil
            bootToNormal = device.mode == .recovery
            enterDFU = device.mode != .dfu
            restore = device.mode != .normal
            removeTrust = device.mode == .normal && device.isTrusted
        }
    }

    var enterRecovery: Bool
    var bootToNormal: Bool
    var restart: Bool
    var enterDFU: Bool
    /// Restore and Revive.
    var restore: Bool
    var removeTrust: Bool
    var retryLookup: Bool
    var removeFromList: Bool

    /// - Parameters:
    ///   - busy: an action or a Restore/Revive runs, or (for the Device
    ///     menu) the Restore or Revive sheet is open.
    ///   - editingAssetTag: the asset tag editor is open.
    init(device: USBDevice, busy: Bool, editingAssetTag: Bool, connectedDeviceCount: Int,
         configuratorAvailable: Bool, jamfState: JamfLookupState) {
        let offers = Offers(device: device)
        let ready = device.isConnected && !busy
        let vdm = ready && !Self.vdmUnavailable(connectedDeviceCount: connectedDeviceCount)
        enterRecovery = ready && offers.enterRecovery
        bootToNormal = ready && offers.bootToNormal
        restart = vdm
        enterDFU = vdm && offers.enterDFU
        restore = ready && offers.restore
            && Self.restoreUnavailableReason(device: device, configuratorAvailable: configuratorAvailable) == nil
        removeTrust = ready && offers.removeTrust && configuratorAvailable
        retryLookup = switch jamfState {
        case .found, .noMatch, .multipleMatches, .failed: true
        case .notConfigured, .unavailable, .loading: false
        }
        removeFromList = !device.isConnected && !editingAssetTag
    }

    /// The USB-PD command goes to a port, not a device, so with several
    /// devices attached it could hit the wrong one — offer it only for one.
    /// (The root helper refuses too when more than one port has something.)
    static func vdmUnavailable(connectedDeviceCount: Int) -> Bool { connectedDeviceCount > 1 }

    /// Why Restore and Revive can't run for this device, or nil when they can.
    static func restoreUnavailableReason(device: USBDevice, configuratorAvailable: Bool) -> String? {
        if !configuratorAvailable { return Configurator.notInstalledHelp }
        if device.configuratorECID == nil { return "Apple Configurator hasn’t identified this device yet." }
        return nil
    }
}

// MARK: - Wrapping row

/// Lays its views out left to right and starts a new line when the next one
/// doesn't fit, so buttons are never cut off in a narrow window.
struct WrappingHStack: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let lines = Self.lines(widths: sizes.map(\.width), available: proposal.width ?? .infinity, spacing: spacing)
        var width: CGFloat = 0
        var height: CGFloat = 0
        for line in lines {
            let lineWidth: CGFloat = line.reduce(0) { $0 + sizes[$1].width } + spacing * CGFloat(line.count - 1)
            let lineHeight: CGFloat = line.reduce(0) { max($0, sizes[$1].height) }
            width = max(width, lineWidth)
            height += lineHeight
        }
        height += lineSpacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var y = bounds.minY
        for line in Self.lines(widths: sizes.map(\.width), available: bounds.width, spacing: spacing) {
            let height: CGFloat = line.reduce(0) { max($0, sizes[$1].height) }
            var x = bounds.minX
            for index in line {
                subviews[index].place(at: CGPoint(x: x, y: y + (height - sizes[index].height) / 2),
                                      proposal: ProposedViewSize(sizes[index]))
                x += sizes[index].width + spacing
            }
            y += height + lineSpacing
        }
    }

    /// The views on each line, by index: as many as fit in `available`, at
    /// least one per line (a view wider than the line gets a line of its own).
    nonisolated static func lines(widths: [CGFloat], available: CGFloat, spacing: CGFloat) -> [[Int]] {
        var lines: [[Int]] = []
        var lineWidth: CGFloat = 0
        for (index, width) in widths.enumerated() {
            if let last = lines.indices.last, lineWidth + spacing + width <= available {
                lines[last].append(index)
                lineWidth += spacing + width
            } else {
                lines.append([index])
                lineWidth = width
            }
        }
        return lines
    }
}

// MARK: - Device menu

/// The selected device's actions for the Device menu (`DeviceMenu`), from
/// its detail view. A nil action is dimmed in the menu.
struct DeviceMenuActions {
    var enterRecovery: (() -> Void)?
    var bootToNormal: (() -> Void)?
    var restart: (() -> Void)?
    var enterDFU: (() -> Void)?
    var restore: (() -> Void)?
    var revive: (() -> Void)?
    var removeTrust: (() -> Void)?
    var retryLookup: (() -> Void)?
    var removeFromList: (() -> Void)?
}

private struct DeviceActionsKey: FocusedValueKey {
    typealias Value = DeviceMenuActions
}

extension FocusedValues {
    var deviceActions: DeviceMenuActions? {
        get { self[DeviceActionsKey.self] }
        set { self[DeviceActionsKey.self] = newValue }
    }
}

/// The menu bar's Device menu: the selected device's actions, dimmed when
/// no device is selected or an action isn't possible now.
struct DeviceMenu: View {
    @FocusedValue(\.deviceActions) private var actions

    var body: some View {
        item("Enter Recovery", actions?.enterRecovery)
        item("Boot to Normal", actions?.bootToNormal)
        item("Restart", actions?.restart)
        item("Enter DFU", actions?.enterDFU)
        Divider()
        item("Restore…", actions?.restore)
        item("Revive…", actions?.revive)
        item("Remove Trust", actions?.removeTrust)
        Divider()
        item("Retry Lookup", actions?.retryLookup)
            .keyboardShortcut("r")
        item("Remove from List", actions?.removeFromList)
            .keyboardShortcut(.delete)
    }

    private func item(_ title: String, _ action: (() -> Void)?) -> some View {
        Button(title) { action?() }
            .disabled(action == nil)
    }
}
