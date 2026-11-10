import JTKit
import SwiftUI

/// The Settings window's Connections tab: JTKit's shared list and editor for
/// the saved Jamf connections and Apple accounts (`AppConnection`), with two
/// roles, the Jamf connection in use and the Apple account in use, and what
/// each one needs below the fields.
struct SettingsView: View {
    let jamf: JamfStore
    let appleBusiness: AppleBusinessStore

    var body: some View {
        let connections = jamf.connections
        connectionsTab(connections)
            // The one-time conversion of an earlier version's settings didn't
            // finish (e.g. the Keychain refused): say so here, where the
            // connection would be. An inset, not a stack around the tab, so
            // the tab keeps its name and icon in the Settings toolbar.
            .safeAreaInset(edge: .top, spacing: 0) {
                if let problem = connections.conversionProblem {
                    WarningLabel(problem)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                }
            }
    }

    private func connectionsTab(_ connections: AppConnectionStore) -> some View {
        @Bindable var connections = connections
        return ConnectionsSettingsTab(
            store: connections.connections,
            services: AppConnection.services,
            optionalFields: [.jamfProWebURL],
            serviceGroups: AppConnection.serviceGroups,
            roles: [jamf.connectionRole(selection: $connections.activeID),
                    appleBusiness.connectionRole(selection: $connections.activeAppleID)],
            newRecord: { connections.newConnection(service: $0) },
            didDelete: { _ in connections.connectionWasDeleted() },
            test: { record, typed in
                let typedSecret = typed[.main].flatMap { $0.isEmpty ? nil : $0 }
                switch record {
                case .jamf(let record): return try await jamf.testConnection(record, typedSecret: typedSecret)
                case .apple(let record): return try await appleBusiness.testConnection(record, typedSecret: typedSecret)
                }
            }
        ) { record in
            Section {
                Text(Self.help(for: record.wrappedValue))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    static func help(for record: AppConnection) -> String {
        switch record {
        case .jamf(let record): help(for: record)
        case .apple(let record): help(for: record)
        }
    }

    /// Where to create the API account and what it needs.
    static func help(for record: AppleBusinessConnection) -> String {
        let product = record.service == .appleSchoolManager ? "Apple School Manager" : "Apple Business"
        return "Optional: looks each device’s serial number up in \(product). In \(product), create an API account for this app alone, with read access only (your name at the bottom of the sidebar → Preferences → API), and download its private key (.pem), which is shown only once. Enter the account’s client ID and key ID, then paste the private key or import the .pem file. The private key is stored in the Keychain. Without an Apple account the app never contacts \(product)."
    }

    /// Where to create the credentials and which permissions they need.
    static func help(for record: JamfConnection) -> String {
        switch (record.service, record.signIn) {
        case (.jamfPro, .usernamePassword):
            "A classic Jamf Pro user account with permission to read mobile devices, and computers to look up Macs (update permission is needed to edit asset tags). The password is stored in the Keychain."
        case (.jamfPro, _):
            "Create an API client in Jamf Pro under Settings → System → API roles and clients. It needs the “Read Mobile Devices” privilege, “Read Computers” to look up Macs — plus “Update Mobile Devices” / “Update Computers” to edit asset tags. The client secret is stored in the Keychain."
        case (.jamfPlatform, _):
            "Create an integration in Jamf Account scoped to a platform environment, in the region your Jamf Pro is hosted in. It needs the devices:read permission, plus devices:update to edit asset tags. Copy the environment ID from the integration’s details. Integrations expire after six months. The Jamf Pro web address is optional and used only for “Open in Jamf Pro” links. The client secret is stored in the Keychain."
        case (.jamfSchool, _):
            "Find the Network ID and create an API key in Jamf School under Organization → Settings → API. The key needs read access to devices, plus write access to edit asset tags. The API key is stored in the Keychain."
        default:
            ""
        }
    }
}

#Preview {
    SettingsTabs {
        // Never the saved connections: a throwaway store, as for the unit tests.
        SettingsView(jamf: .preview, appleBusiness: .preview)
    }
    .environment(UpdateChecker(configuration: UpdateConfiguration(owner: "JordyThery", repository: "Serial-Number-Reader", appName: "Serial Number Reader")))
}
