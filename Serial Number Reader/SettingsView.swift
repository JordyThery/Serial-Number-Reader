import SwiftUI

struct SettingsView: View {
    @Bindable var jamf: JamfStore

    @AppStorage(UpdateChecker.automaticCheckKey) private var checksForUpdates = true
    @State private var testResult: TestResult?
    @State private var testing = false

    private enum TestResult: Equatable {
        case success
        case failure(String)
    }

    var body: some View {
        Form {
            Section("Authentication") {
                Picker("Method", selection: $jamf.authMethod) {
                    ForEach(JamfStore.AuthMethod.allCases) { method in
                        Text(method.label).tag(method)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            if jamf.authMethod == .platform {
                platformSections
            } else {
                jamfProSections
            }

            Section {
                HStack {
                    Button {
                        testConnection()
                    } label: {
                        if testing {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Test Connection")
                        }
                    }
                    .disabled(testing || !jamf.isConfigured)

                    switch testResult {
                    case .success:
                        Label("Authenticated successfully", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failure(let message):
                        Label(message, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    case nil:
                        EmptyView()
                    }
                }
            }

            Section {
                Toggle("Check for updates automatically", isOn: $checksForUpdates)
            } header: {
                Text("Updates")
            } footer: {
                Text("Checks GitHub for a new release at most once a day. Use Serial Number Reader → Check for Updates… to check now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Jamf Pro (direct)

    @ViewBuilder
    private var jamfProSections: some View {
        Section("Jamf Pro Server") {
            TextField("Server URL", text: $jamf.serverURLString, prompt: Text("https://yourorg.jamfcloud.com"))
                .textContentType(.URL)
                .autocorrectionDisabled()
        }

        Section {
            switch jamf.authMethod {
            case .basic:
                TextField("Username", text: $jamf.username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                SecureField("Password", text: $jamf.password)
            default:
                TextField("Client ID", text: $jamf.clientID)
                    .autocorrectionDisabled()
                SecureField("Client Secret", text: $jamf.clientSecret)
            }
        } header: {
            Text("Credentials")
        } footer: {
            Group {
                switch jamf.authMethod {
                case .basic:
                    Text("A classic Jamf Pro user account with permission to read mobile devices and computers (update permission is needed to edit asset tags). The password is stored in the Keychain.")
                default:
                    Text("Create an API client in Jamf Pro under Settings → System → API roles and clients. It needs “Read Mobile Devices” and “Read Computers” privileges — plus “Update Mobile Devices” / “Update Computers” to edit asset tags. The client secret is stored in the Keychain.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Jamf Platform API

    @ViewBuilder
    private var platformSections: some View {
        Section {
            Picker("Region", selection: $jamf.platformRegion) {
                ForEach(PlatformRegion.allCases) { region in
                    Text(region.label).tag(region)
                }
            }
            TextField("Client ID", text: $jamf.platformClientID)
                .autocorrectionDisabled()
            SecureField("Client Secret", text: $jamf.platformClientSecret)
            TextField("Environment ID", text: $jamf.platformEnvironmentID,
                      prompt: Text("xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"))
                .autocorrectionDisabled()
                .monospaced()
            if !jamf.platformEnvironmentIDLooksValid {
                Label("Not a valid environment ID — copy it from the integration's details in Jamf Account", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Platform API Integration")
        } footer: {
            Text("Create an integration in Jamf Account scoped to a platform environment, in the region your Jamf Pro is hosted in. It needs the devices:read permission, plus devices:update to edit asset tags. Copy the environment ID from the integration's details. Integrations expire after six months. The client secret is stored in the Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section {
            TextField("Jamf Pro URL", text: $jamf.serverURLString, prompt: Text("https://yourorg.jamfcloud.com (optional)"))
                .textContentType(.URL)
                .autocorrectionDisabled()
        } header: {
            Text("Jamf Pro Web Address")
        } footer: {
            Text("Optional. Used only for “Open in Jamf Pro” links — the Platform API doesn't provide your instance's address.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func testConnection() {
        testing = true
        testResult = nil
        Task {
            let result = await jamf.testConnection()
            switch result {
            case .success:
                testResult = .success
            case .failure(let error):
                testResult = .failure(error.localizedDescription)
            }
            testing = false
        }
    }
}

#Preview {
    SettingsView(jamf: JamfStore())
}
