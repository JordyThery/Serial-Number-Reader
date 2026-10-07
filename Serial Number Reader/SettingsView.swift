import SwiftUI

struct SettingsView: View {
    @Bindable var jamf: JamfStore

    @State private var testResult: TestResult?
    @State private var testing = false

    private enum TestResult: Equatable {
        case success
        case failure(String)
    }

    var body: some View {
        Form {
            Section("Jamf Pro Server") {
                TextField("Server URL", text: $jamf.serverURLString, prompt: Text("https://yourorg.jamfcloud.com"))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
            }

            Section {
                Picker("Authentication", selection: $jamf.authMethod) {
                    ForEach(JamfStore.AuthMethod.allCases) { method in
                        Text(method.label).tag(method)
                    }
                }
                .pickerStyle(.radioGroup)

                switch jamf.authMethod {
                case .clientCredentials:
                    TextField("Client ID", text: $jamf.clientID)
                        .autocorrectionDisabled()
                    SecureField("Client Secret", text: $jamf.clientSecret)
                case .basic:
                    TextField("Username", text: $jamf.username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $jamf.password)
                }
            } header: {
                Text("Credentials")
            } footer: {
                Group {
                    switch jamf.authMethod {
                    case .clientCredentials:
                        Text("Create an API client in Jamf Pro under Settings → System → API roles and clients. It needs “Read Mobile Devices” and “Read Computers” privileges — plus “Update Mobile Devices” / “Update Computers” to edit asset tags. The client secret is stored in the Keychain.")
                    case .basic:
                        Text("A classic Jamf Pro user account with permission to read mobile devices and computers (update permission is needed to edit asset tags). The password is stored in the Keychain.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
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
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
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
