import SwiftUI

/// Above the device details: each device the app is waiting for after
/// Restart or Enter DFU, by name, with how long the app waits and Stop
/// Waiting; then how the wait ended until it's dismissed. The rest of the
/// app stays usable meanwhile.
struct DeviceReturnBanner: View {
    let actions: DeviceActionController

    var body: some View {
        ForEach(actions.returnWaits) { wait in
            DeviceReturnRow(wait: wait, actions: actions)
        }
    }
}

private struct DeviceReturnRow: View {
    let wait: DeviceActionController.ReturnWait
    let actions: DeviceActionController

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            if wait.state == .waiting {
                ProgressView().controlSize(.small)
                Button("Stop Waiting") { actions.stopWaiting(wait.id) }
                    .help("Stop watching for this device; the command was already sent")
            } else {
                Button("Dismiss") { actions.dismissWait(wait.id) }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
        .padding([.horizontal, .top], 12)
        .accessibilityElement(children: .contain)
        // The wait can last minutes: VoiceOver hears how it ended.
        .onChange(of: wait.state) { old, new in
            guard old == .waiting, new != .waiting else { return }
            AccessibilityNotification.Announcement([title, detail].compactMap { $0 }.joined(separator: ". ")).post()
        }
    }

    private var title: String {
        switch wait.state {
        case .waiting: wait.waitingText
        case .back: "\(wait.target.name) is back\(wait.expectation.modeText)"
        case .notConfirmed: "\(wait.target.name): not confirmed"
        case .failed: "\(wait.target.name) didn’t come back"
        }
    }

    private var detail: String? {
        switch wait.state {
        case .waiting: "Other devices can be used meanwhile."
        case .back: nil
        case .notConfirmed(let text), .failed(let text): text
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch wait.state {
        case .waiting:
            Image(systemName: "hourglass").foregroundStyle(.blue)
        case .back:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .notConfirmed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}
