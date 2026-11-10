import Foundation
import JTKit

/// A saved Jamf connection: Jamf Pro (API client or username and password),
/// the Jamf Platform API, or Jamf School.
///
/// The list is saved as JSON under the UserDefaults key `jamfConnections` with
/// these field names; keep them, or saved connections are lost. The secret is
/// not part of it: it is in the Keychain (see `AppConnectionStore.jamfKeychain`).
nonisolated struct JamfConnection: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var service: ConnectionService
    var signIn: SignInMethod
    /// Jamf Pro and Jamf School: the server address.
    var serverURL = ""
    /// Jamf Platform API.
    var region: JamfRegion = .eu
    var environmentID = ""
    /// Jamf Platform API: the Jamf Pro address, used only for "Open in Jamf Pro" links.
    var jamfProWebURL = ""
    /// The API client ID; Jamf School's Network ID.
    var clientID = ""
    var username = ""
}

nonisolated extension JamfConnection {
    /// One of the release check's connections under the live-check switch
    /// (JTKit's `LiveLaunch`), kept in memory with its own ID.
    init(live connection: Connection) {
        self.init(id: connection.id, name: connection.name, service: connection.service, signIn: connection.signIn)
        self.connection = connection
    }
}

/// How JTKit's connections list and editor see a saved connection.
nonisolated extension JamfConnection: ConnectionRecord {
    var connection: Connection {
        get {
            Connection(id: id, name: name, service: service, signIn: signIn,
                       serverURL: serverURL, region: region, environmentID: environmentID,
                       jamfProWebURL: jamfProWebURL, clientID: clientID, username: username)
        }
        set {
            name = newValue.name
            service = newValue.service
            signIn = newValue.signIn
            serverURL = newValue.serverURL
            region = newValue.region
            environmentID = newValue.environmentID
            jamfProWebURL = newValue.jamfProWebURL
            clientID = newValue.clientID
            username = newValue.username
        }
    }
}
