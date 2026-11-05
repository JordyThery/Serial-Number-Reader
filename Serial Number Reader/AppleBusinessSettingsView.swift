import JTKit
import SwiftUI

/// The Settings window's Apple Business / School Manager tab: JTKit's shared
/// list and editor for the saved API accounts (service, client ID, key ID
/// and the private key), with Test Connection and what the account needs.
struct AppleBusinessSettingsView: View {
    let store: AppleBusinessStore

    var body: some View {
        @Bindable var connections = store.connections
        let tab = ConnectionsSettingsTab(
            store: connections.connections,
            services: [.appleBusinessManager, .appleSchoolManager],
            roles: [.active(selection: $connections.activeID)],
            newRecord: { connections.newConnection(service: $0) },
            didDelete: { _ in connections.connectionWasDeleted() },
            test: { record, typed in
                let typedKey = typed[.main].flatMap { $0.isEmpty ? nil : $0 }
                return try await store.testConnection(record, typedSecret: typedKey)
            }
        ) { record in
            Section {
                Text(Self.help(for: record.wrappedValue))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // JTKit's tab names itself "Connections" and a tab item set outside
        // doesn't replace it. Inside an overlay it doesn't reach the Settings
        // toolbar, so this tab gets its own name.
        return Color.clear
            .frame(width: SettingsLayout.width, height: 480)
            .overlay { tab }
            .tabItem { Label("Apple Business", systemImage: "building.2") }
        .settingsTabName("Apple Business")
    }

    /// Where to create the API account and what it needs.
    static func help(for record: AppleBusinessConnection) -> String {
        let portal = record.service == .appleSchoolManager ? "Apple School Manager" : "Apple Business Manager"
        return "Optional: looks each device’s serial number up in \(portal). In \(portal), an Organization Administrator creates an API account (in the API section of the preferences) and downloads its private key (.pem), which is shown only once. Enter the account’s client ID and key ID, then paste the private key or import the .pem file. The private key is stored in the Keychain."
    }
}

#Preview {
    AppleBusinessSettingsView(store: .preview)
}
