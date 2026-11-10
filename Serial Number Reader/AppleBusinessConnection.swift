import Foundation
import JTKit

/// A saved Apple Business or Apple School Manager API account.
///
/// The list is saved as JSON under the UserDefaults key
/// `appleBusinessConnections` with these field names; keep them, or saved
/// accounts are lost. The private key is not part of it: it is in the
/// Keychain (service `be.jordythery.SerialNumberReader.appleBusiness`, see
/// `AppConnectionStore.appleKeychain`). It is separate from the Jamf
/// connections, which stay as they are.
nonisolated struct AppleBusinessConnection: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var service: ConnectionService
    var signIn: SignInMethod
    /// The API account's client ID.
    var clientID = ""
    /// The ID of the private key (.pem) downloaded with the account.
    var keyID = ""
}

nonisolated extension AppleBusinessConnection {
    /// One of the release check's connections under the live-check switch
    /// (JTKit's `LiveLaunch`), kept in memory with its own ID.
    init(live connection: Connection) {
        self.init(id: connection.id, name: connection.name, service: connection.service, signIn: connection.signIn)
        self.connection = connection
    }
}

/// How JTKit's connections list and editor see a saved account.
nonisolated extension AppleBusinessConnection: ConnectionRecord {
    var connection: Connection {
        get {
            Connection(id: id, name: name, service: service, signIn: signIn, clientID: clientID, keyID: keyID)
        }
        set {
            name = newValue.name
            service = newValue.service
            signIn = newValue.signIn
            clientID = newValue.clientID
            keyID = newValue.keyID
        }
    }
}
