import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Restore sheet

/// Confirms a Restore: which device, which OS, and what will be lost.
struct RestoreSheet: View {
    let device: USBDevice
    /// Serial and Jamf name, when known, to make the device unmistakable.
    let serialNumber: String?
    let jamfName: String?
    let restore: RestoreController

    @Environment(\.dismiss) private var dismiss

    private enum Source: Hashable { case latest, ipsw }

    @State private var source: Source = .latest
    @State private var latest: FirmwareSigning.Firmware?
    @State private var ipswURL: URL?
    @State private var ipswInfo: IPSWInfo?
    @State private var ipswError: String?
    /// nil while unknown (lookup failed, or a beta ipsw.me doesn't list).
    @State private var ipswSigned: Bool?
    @State private var checkingIPSW = false

    private var productType: String? { device.modelInfo?.identifier }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Restore \(device.modelDisplayName)?")
                .font(.title2.weight(.semibold))

            DeviceIdentityGrid(device: device, serialNumber: serialNumber, jamfName: jamfName)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Version", selection: $source) {
                        Text(latestLabel).tag(Source.latest)
                        Text("Specific IPSW").tag(Source.ipsw)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()

                    if source == .ipsw {
                        HStack {
                            Text(ipswURL?.lastPathComponent ?? "No file chosen")
                                .foregroundStyle(ipswURL == nil ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("Browse…", action: chooseIPSW)
                        }
                        ipswStatus
                    }
                }
                .padding(6)
            }

            VStack(alignment: .leading, spacing: 4) {
                Label("All content and settings on the device are erased.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Activation Lock stays in place. Devices enrolled through Automated Device Enrollment re-enroll in Jamf Pro during setup. The first restore of a version downloads several GB. Keep the device connected and Serial Number Reader open until it finishes.")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                Button(role: .destructive, action: startRestore) {
                    Text("Erase & Restore")
                        .foregroundStyle(canRestore ? .red : .secondary)
                }
                .disabled(!canRestore)
            }
        }
        .padding(20)
        .frame(width: 500)
        .task { await loadLatest() }
    }

    private var latestLabel: String {
        if let latest { return "Latest available (\(osName) \(latest.version))" }
        return "Latest available version"
    }

    private var osName: String {
        if productType?.hasPrefix("iPad") == true { return "iPadOS" }
        if productType?.hasPrefix("Mac") == true { return "macOS" }
        return "iOS"
    }

    @ViewBuilder
    private var ipswStatus: some View {
        if checkingIPSW {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking the IPSW…").foregroundStyle(.secondary)
            }
            .font(.caption)
        } else if let ipswError {
            Label(ipswError, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.caption)
        } else if let info = ipswInfo {
            VStack(alignment: .leading, spacing: 2) {
                Label("\(osName) \(info.productVersion) (\(info.buildVersion)) — supports this device",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                switch ipswSigned {
                case .some(true):
                    Label("Signed by Apple", systemImage: "checkmark.seal")
                        .foregroundStyle(.secondary)
                case .some(false):
                    Label("No longer signed by Apple — the restore would fail", systemImage: "xmark.seal.fill")
                        .foregroundStyle(.red)
                case .none:
                    Label("Signing status unknown (betas aren't listed) — Apple decides when the restore starts",
                          systemImage: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
    }

    private var canRestore: Bool {
        guard device.configuratorECID != nil, !restore.isRunning else { return false }
        switch source {
        case .latest:
            return true
        case .ipsw:
            return ipswURL != nil && ipswInfo != nil && ipswError == nil && ipswSigned != false && !checkingIPSW
        }
    }

    private func loadLatest() async {
        guard let productType else { return }
        latest = await FirmwareSigning.latestSigned(productType: productType)
    }

    private func chooseIPSW() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ipsw") ?? .data]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an IPSW for \(device.modelDisplayName)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ipswURL = url
        Task { await checkIPSW(url) }
    }

    /// Rejects an IPSW for another model or one Apple no longer signs before
    /// anything is erased.
    private func checkIPSW(_ url: URL) async {
        checkingIPSW = true
        ipswInfo = nil
        ipswError = nil
        ipswSigned = nil
        defer { checkingIPSW = false }
        do {
            let info = try await Task.detached(priority: .userInitiated) { try IPSWInfo.read(from: url) }.value
            if let productType, !info.supports(productType) {
                ipswError = "This IPSW doesn't support \(device.modelDisplayName) (\(productType))."
                return
            }
            ipswInfo = info
            if let productType {
                ipswSigned = await FirmwareSigning.isSigned(productType: productType, build: info.buildVersion)
            }
        } catch {
            ipswError = error.localizedDescription
        }
    }

    private func startRestore() {
        guard let ecid = device.configuratorECID else { return }
        restore.start(.restore(ipsw: source == .ipsw ? ipswURL : nil),
                      ecid: ecid, deviceName: device.modelDisplayName)
        dismiss()
    }
}

// MARK: - Revive sheet

struct ReviveSheet: View {
    let device: USBDevice
    let serialNumber: String?
    let jamfName: String?
    let restore: RestoreController

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Revive \(device.modelDisplayName)?")
                .font(.title2.weight(.semibold))

            DeviceIdentityGrid(device: device, serialNumber: serialNumber, jamfName: jamfName)

            Text("Reinstalls the latest version of the operating system and keeps the device's content. If Revive doesn't fix the device, a full restore may still be needed. Keep the device connected and Serial Number Reader open until it finishes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                Button("Revive") {
                    guard let ecid = device.configuratorECID else { return }
                    restore.start(.revive, ecid: ecid, deviceName: device.modelDisplayName)
                    dismiss()
                }
                .disabled(device.configuratorECID == nil || restore.isRunning)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// The identifiers that make the target device unmistakable.
private struct DeviceIdentityGrid: View {
    let device: USBDevice
    let serialNumber: String?
    let jamfName: String?

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            row("Mode", device.mode.rawValue)
            if let ecid = device.ecid { row("ECID", ecid, mono: true) }
            if let serialNumber { row("Serial Number", serialNumber, mono: true) }
            if let jamfName { row("Jamf Name", jamfName) }
        }
        .font(.callout)
    }

    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospaced(mono).textSelection(.enabled)
        }
    }
}

// MARK: - Progress banner

/// Shown at the top of the window while a Restore or Revive runs, and after
/// it ends until dismissed. Tied to the job rather than to a list row, since
/// the device reboots and reconnects several times along the way.
struct RestoreBanner: View {
    let restore: RestoreController

    @State private var showsLog = false

    var body: some View {
        if let job = restore.job {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    icon(for: job.state)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(for: job))
                            .font(.headline)
                        Text(detail(for: job))
                            .font(.callout)
                            .foregroundStyle(job.state.isFailure ? .red : .secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button(showsLog ? "Hide Log" : "Show Log") { showsLog.toggle() }
                        .buttonStyle(.link)
                    if job.state != .running {
                        Button("Dismiss") { restore.dismiss() }
                    }
                }
                if job.state == .running {
                    if let fraction = job.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                if showsLog {
                    ScrollView {
                        Text(job.log.joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
            }
            .padding(12)
            .background(.regularMaterial, in: .rect(cornerRadius: 10))
            .padding([.horizontal, .top], 12)
        }
    }

    private func title(for job: RestoreController.Job) -> String {
        switch (job.kind, job.state) {
        case (.restore, .running): "Restoring \(job.deviceName)"
        case (.restore, .succeeded): "Restored \(job.deviceName)"
        case (.restore, .failed): "Restore of \(job.deviceName) failed"
        case (.revive, .running): "Reviving \(job.deviceName)"
        case (.revive, .succeeded): "Revived \(job.deviceName)"
        case (.revive, .failed): "Revive of \(job.deviceName) failed"
        }
    }

    private func detail(for job: RestoreController.Job) -> String {
        switch job.state {
        case .running:
            let percent = job.fraction.map { " · \(Int(($0 * 100).rounded()))%" } ?? ""
            return job.step + percent
        case .succeeded:
            return job.kind == .restore
                ? "The device restarts into Setup Assistant."
                : "The device restarts with its content in place."
        case .failed(let message):
            return message
        }
    }

    @ViewBuilder
    private func icon(for state: RestoreController.Job.State) -> some View {
        switch state {
        case .running:
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.blue)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}

private extension RestoreController.Job.State {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
