import JTKit
import SwiftUI

/// The Settings window's Connections tab: JTKit's shared list and editor for
/// the saved Jamf connections, with what each one needs below the fields.
struct SettingsView: View {
    let jamf: JamfStore

    var body: some View {
        @Bindable var connections = jamf.connections
        ConnectionsSettingsTab(
            store: connections.connections,
            services: [.jamfPro, .jamfPlatform, .jamfSchool],
            optionalFields: [.jamfProWebURL],
            roles: [jamf.connectionRole(selection: $connections.activeID)],
            newRecord: { connections.newConnection(service: $0) },
            didDelete: { _ in connections.connectionWasDeleted() },
            test: { record, typed in
                let typedSecret = typed[.main].flatMap { $0.isEmpty ? nil : $0 }
                return try await jamf.testConnection(record, typedSecret: typedSecret)
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

    /// Where to create the credentials and which permissions they need.
    static func help(for record: JamfConnection) -> String {
        switch (record.service, record.signIn) {
        case (.jamfPro, .usernamePassword):
            "A classic Jamf Pro user account with permission to read mobile devices and computers (update permission is needed to edit asset tags). The password is stored in the Keychain."
        case (.jamfPro, _):
            "Create an API client in Jamf Pro under Settings → System → API roles and clients. It needs “Read Mobile Devices” and “Read Computers” privileges — plus “Update Mobile Devices” / “Update Computers” to edit asset tags. The client secret is stored in the Keychain."
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
        SettingsView(jamf: .preview)
    }
    .environment(UpdateChecker(configuration: UpdateConfiguration(owner: "JordyThery", repository: "Serial-Number-Reader", appName: "Serial Number Reader")))
}
