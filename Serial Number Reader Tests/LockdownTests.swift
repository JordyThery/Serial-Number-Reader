import Foundation
import Security
import Testing
@testable import Serial_Number_Reader

/// usbmuxd and lockdown framing, device matching and the masked replies, on
/// fake channels: no socket, no device.
@Suite("usbmuxd and lockdown")
struct UsbmuxTests {

    /// A lockdown channel in memory: what is written, and replies to read.
    final class FakeChannel: Usbmux.LockdownChannel {
        var written = Data()
        var toRead: Data
        init(replies: [[String: Any]]) throws {
            toRead = Data()
            for reply in replies {
                let plist = try PropertyListSerialization.data(fromPropertyList: reply, format: .xml, options: 0)
                withUnsafeBytes(of: UInt32(plist.count).bigEndian) { toRead.append(contentsOf: $0) }
                toRead.append(plist)
            }
        }
        func write(_ data: Data) throws { written.append(data) }
        func read(_ count: Int) throws -> Data {
            guard toRead.count >= count else { throw Usbmux.Failure.socketError("connection closed") }
            let chunk = toRead.prefix(count)
            toRead.removeFirst(count)
            return Data(chunk)
        }
    }

    @Test("A usbmuxd request: 16-byte little-endian header, then the plist; a reply's length is checked")
    func muxFraming() throws {
        let packet = try Usbmux.muxPacket(["MessageType": "ListDevices"], tag: 7)
        let words = (0..<4).map { index in
            packet.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self) }.littleEndian
        }
        #expect(words == [UInt32(packet.count), 1, 8, 7])
        let body = packet.dropFirst(16)
        #expect(try Usbmux.muxReply(body: Data(body))["MessageType"] as? String == "ListDevices")
        #expect(try Usbmux.muxBodyLength(header: packet.prefix(16)) == body.count)

        var tooLong = Data(count: 16)
        tooLong[3] = 0x10 // 256 MB
        #expect(throws: Usbmux.Failure.self) { try Usbmux.muxBodyLength(header: tooLong) }
        #expect(throws: Usbmux.Failure.self) { try Usbmux.muxBodyLength(header: Data(count: 4)) }
        #expect(throws: Usbmux.Failure.self) { try Usbmux.muxReply(body: Data("not a plist".utf8)) }
    }

    @Test("The device is found by UDID over USB, ignoring case and hyphens; Wi-Fi entries are skipped")
    func findsDevice() {
        let list: [[String: Any]] = [
            ["DeviceID": 3, "Properties": ["ConnectionType": "Network", "SerialNumber": "00008140-001A2B3C4D5E6F70"]],
            ["Properties": ["ConnectionType": "USB", "SerialNumber": "00008140-0000000000000002", "DeviceID": 4]],
            ["Properties": ["ConnectionType": "USB", "SerialNumber": "00008140001a2b3c4d5e6f70", "DeviceID": 5]],
        ]
        let match = Usbmux.device(in: list, udid: "00008140-001A2B3C4D5E6F70")
        #expect(match?.deviceID == 5)
        #expect(match?.serial == "00008140001a2b3c4d5e6f70")
        #expect(Usbmux.device(in: list, udid: "00008140-0000000000000009") == nil)
    }

    @Test("Enter Recovery: the request, then the device's answer")
    func enterRecovery() throws {
        let accepted = try FakeChannel(replies: [["Request": "EnterRecovery"]])
        try Usbmux.sendEnterRecovery(over: accepted)
        let length = accepted.written.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian
        #expect(Int(length) == accepted.written.count - 4)
        let sent = try #require(try PropertyListSerialization.propertyList(
            from: accepted.written.dropFirst(4), format: nil) as? [String: Any])
        #expect(sent["Request"] as? String == "EnterRecovery")

        // iOS 27 without a session: the code the app falls back to the pairing on.
        let refused = try FakeChannel(replies: [["Request": "EnterRecovery", "Error": "SessionInactive"]])
        #expect {
            try Usbmux.sendEnterRecovery(over: refused)
        } throws: { error in
            if case Usbmux.Failure.lockdownError("SessionInactive") = error { return true }
            return false
        }
    }

    @Test("An unexpected reply is shown without the device's values")
    func unexpectedReplyMasked() throws {
        let udid = "00008140-001A2B3C4D5E6F70"
        let odd = try FakeChannel(replies: [["Request": "GetValue", "Value": ["UniqueDeviceID": udid,
                                                                              "SerialNumber": "PLACEHOLDR08"]]])
        do {
            try Usbmux.sendEnterRecovery(over: odd)
            Issue.record("Expected an error")
        } catch {
            let text = error.localizedDescription
            #expect(text == "The device sent an unexpected reply (Request GetValue).")
            #expect(!text.contains(udid))
            #expect(!text.contains("PLACEHOLDR08"))
        }
        #expect(Usbmux.summary(of: ["Number": 3, "DeviceList": [["SerialNumber": udid]]]) == "Number 3")
        #expect(Usbmux.summary(of: ["Secret": udid]) == "no request, error or result code")
    }

    @Test("Messages are sentences with curly apostrophes")
    func messages() {
        #expect(Usbmux.Failure.deviceNotFound.localizedDescription
                == "The device isn’t visible to usbmuxd. Check that it’s connected and has been unlocked once since it started.")
        #expect(Usbmux.Failure.socketError("connection refused").localizedDescription
                == "Couldn’t reach usbmuxd: connection refused.")
    }
}

/// The pairing record's keys and certificates, and the check that the
/// device's TLS certificate belongs to that pairing. Made-up certificates.
@Suite("Lockdown TLS")
struct LockdownTLSTests {
    static let rootPEM = Data("""
-----BEGIN CERTIFICATE-----
MIIDAjCCAeqgAwIBAgIUeM6nq/PC797ZzZ+WUz8gZrks2+wwDQYJKoZIhvcNAQEL
BQAwIDEeMBwGA1UEAwwVUGxhY2Vob2xkZXIgVGVzdCBSb290MCAXDTI2MTAzMTE1
MDg0OVoYDzIxMjYxMDA3MTUwODQ5WjAgMR4wHAYDVQQDDBVQbGFjZWhvbGRlciBU
ZXN0IFJvb3QwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCopqhDJAFb
1YFMdCeNyeuNh4fjHi1ZwIR/gsbHgeyNzPVlxRx+xAP+kSsb5/aZuMWHMTNe9gkQ
EsPslJj4C6yOiJVoxiiRDSuiHf0or1M8SCzc1dQOzYBPn20pYR4+xgq/gBn/Y3vs
ddjyPIQXqgc1fL53BwzQzR5baX/oszeerdSeqlayjtGCQHaDkwd3NgQcu70sl9qj
Lld2dR9LO2jHH1RK/l1rotvAjXJ0ztu8aSAmBz3w/2yrujUN/vytpXcZ522hJ47T
GWueB3ve1wJqy8Y2Al77fkUe20QfZHdywp/f0O8dOWaZSsiTJO6c0sVpJy46keYn
vNX2V9PWGt/VAgMBAAGjMjAwMB0GA1UdDgQWBBQ3S0qWbbd06yHb5mSUwSrTAgQC
VjAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQAdHeHkLHGw7N2u
PAcgnyo9/iTgi/l9XRL/Xn+TAcqpj0K8FZbSpBHAXqWzxsTya75/fZ1/arDlwDWW
xJzeESFlDYtE3NZuuK1I4EEXhuFksqT9/XSwJY8YIEXZxMWN/SlyZL5/Lm41Gb0N
X+mw4+vpJ6Isk9VzPctH4Ai4axXgweobE8guc0hP7zJrwhViaFvkAixXTjWQ3NXG
dNsPIVU4H03sEUVwn2hcmbN0urLtzUpEcBXuRSFbNzb4+EuJZ/9BMVox8jv6Bb9I
p6MFDu4xHr2RaOCW3YMmk9G3kitxJ5/mzRm5Jqa8Zfjgt+TQsZfUic83+yS5K1ZG
OT/Eieez
-----END CERTIFICATE-----
""".utf8)
    /// Issued by `rootPEM`.
    static let devicePEM = Data("""
-----BEGIN CERTIFICATE-----
MIIC7DCCAdSgAwIBAgIUMd7tFtQwIgL2xD0kUDCJhFM7GfAwDQYJKoZIhvcNAQEL
BQAwIDEeMBwGA1UEAwwVUGxhY2Vob2xkZXIgVGVzdCBSb290MCAXDTI2MTAzMTE1
MDg1MFoYDzIxMjYxMDA3MTUwODUwWjAiMSAwHgYDVQQDDBdQbGFjZWhvbGRlciBU
ZXN0IERldmljZTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAJPvgj68
rYFJdtFX34LpKrpUjhP7DjV0rDsFoerbZbFgg/MDlEcVGMSdRUXcL+eAE5UH7SSY
YrAsrVqJsYMUJalwT8vSx9GFdXtEpXK8SNQokcwEDdy9esZEz9gIbDDxqPe/3IVn
0APx1R8W3FWV7r/Toyo822/lb0vbFRIkRQamfARK46dtFqgWp+p793TM1ziK0vUn
dexkZF+IgUCoSkk7RgdhIlt0frpJFepBuZXQMqQtRnv43k/OajpyIa4/5uHUJF0k
CElltDrH5m4Nyy51tKd+70+RUcvjqjgznD/GLgILtFKWkkXejSKujK6VIq1gTRMo
NMvachoUDvUVkBECAwEAAaMaMBgwCQYDVR0TBAIwADALBgNVHQ8EBAMCBaAwDQYJ
KoZIhvcNAQELBQADggEBAB0HICFUApaQ0PjcoexFmjGmuYC3faf+ZeN+u0KGZUsA
6Nq1slur5EUJVDNTHjjBw+i+pthKQ0fuaGhvvL39Vyt57ulZv2+BxZgX7hKmSEjt
mxjZy6Y75C3Lyys9hKyAa1qIta6rayxXU6wzcY8z5ePiymuarAd2FrUEFzlnYxrQ
S+Sz+nuOtTU1TUu7hM63Lu8KfGViuKn/DIh22Jzw373TheLSMeafSYtUPga3e39r
ZLiMarZ/GgJ6BxZ0SZFwBVqzoql/govRi5foKZjChXZsjxdM9r6HUBim8NrUFWtF
MfntDZCSagOgbogmQ1srKNBQPu2/EM1p5hR0tkAtrt4=
-----END CERTIFICATE-----
""".utf8)
    /// Self-signed, unrelated to the pairing.
    static let otherPEM = Data("""
-----BEGIN CERTIFICATE-----
MIIDCDCCAfCgAwIBAgIUPJc8tHMVmCUBQOtueXe+gzWwXXswDQYJKoZIhvcNAQEL
BQAwIzEhMB8GA1UEAwwYUGxhY2Vob2xkZXIgT3RoZXIgRGV2aWNlMCAXDTI2MTAz
MTE1MDg1MFoYDzIxMjYxMDA3MTUwODUwWjAjMSEwHwYDVQQDDBhQbGFjZWhvbGRl
ciBPdGhlciBEZXZpY2UwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCz
a/3IHFj75vDb2/smIW1g/N58sbD6w+Eb8Ep8CKpv7ZR0soXa61+Ki/CyOAzwlrZj
8Wxdg2fgnZKqGKGT4HOM1krWnWjyQTv18qZf7AzZviP1djMOS4LOFJ3So1N9l02p
Z2YHw2aDHYfFskOpbZhg+gt3NTZLsQTWrwBOV9Xv15NzM/96rmgPT2uY59zVjYXK
Rv52/bI40Z/05BvcFECOiHh7yMF1y+wyigD6J/0BprGSFBd0Igv8Shu2INvTnwsE
pYAlDx+zKeiE01mzqW+vkkgdgQCZWeoOAPdsrvRyP77+Q3UkzUCmUr9YgZjfmZBC
YrgAwxAYUQf8poBsbTtTAgMBAAGjMjAwMB0GA1UdDgQWBBSzyxUtWeHHNCde9CTk
TrXyp8sI2DAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQAEhNK7
SDEpKXRvWQwE15unU6vzY9TK2NXDl6P0GpTiiqdWpnojhSD2GzraQCShOgukSaVx
e6Mwe9qtLXaKK+ePyQyUPx7wLLCrL8QUe/tLRk/nERHSFeMaj9NlNs6fIEb1Zr3x
sgp0KLJQ+gaaha7JP2/4TnBMma57iY8Dg/asx1ZXFuNatTuCYPLUOU3NRN9QWDGo
1y8mqF+iYLUIDBN6kuy6AifMO8HM4X0Xq1YScWGHp00ZVNz4NoF09Ez+kV+TQ+8E
gefH1xELwLiHimNmG19iLc12/m7yObgXQzZKVU633p07teGEvepEep7W3ld2qff3
f/LVy3SN9PcrMwO+
-----END CERTIFICATE-----
""".utf8)

    private func der(_ pem: Data) throws -> Data { try #require(LockdownTLS.der(fromPEM: pem)) }

    @Test("PEM to DER: the base64 body between the BEGIN and END lines")
    func pemToDER() throws {
        let der = try der(Self.devicePEM)
        #expect(der.first == 0x30) // a DER SEQUENCE
        #expect(SecCertificateCreateWithData(nil, der as CFData) != nil)
    }

    @Test("A PKCS#8 private key, as pair records store it, becomes a key Security accepts")
    func pkcs8Key() throws {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        let key = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let pkcs1 = try #require(SecKeyCopyExternalRepresentation(key, nil) as Data?)
        let pem = Self.pem("PRIVATE KEY", Self.pkcs8(wrapping: pkcs1))

        let unwrapped = try #require(LockdownTLS.pkcs1Key(fromPEM: pem))
        #expect(unwrapped == pkcs1)
        let keyAttributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        #expect(SecKeyCreateWithData(unwrapped as CFData, keyAttributes as CFDictionary, nil) != nil)
        // Already PKCS#1 ("BEGIN RSA PRIVATE KEY"): used as it is.
        #expect(LockdownTLS.pkcs1Key(fromPEM: Self.pem("RSA PRIVATE KEY", pkcs1)) == pkcs1)
        #expect(LockdownTLS.pkcs1Key(fromPEM: Data("not a key".utf8)) == nil)
    }

    @Test("Only the pairing's device certificate, or one issued by the pairing's root, is accepted")
    func peerCheck() throws {
        let device = try der(Self.devicePEM)
        let other = try der(Self.otherPEM)
        #expect(LockdownTLS.peerCertificate(device, matchesDeviceCertificatePEM: Self.devicePEM, rootCertificatePEM: nil))
        #expect(LockdownTLS.peerCertificate(device, matchesDeviceCertificatePEM: nil, rootCertificatePEM: Self.rootPEM))
        #expect(!LockdownTLS.peerCertificate(other, matchesDeviceCertificatePEM: Self.devicePEM,
                                            rootCertificatePEM: Self.rootPEM))
        #expect(!LockdownTLS.peerCertificate(device, matchesDeviceCertificatePEM: nil, rootCertificatePEM: nil))
        #expect(!LockdownTLS.peerCertificate(Data(), matchesDeviceCertificatePEM: Self.devicePEM,
                                            rootCertificatePEM: Self.rootPEM))
    }

    // MARK: Helpers

    private static func pem(_ label: String, _ der: Data) -> Data {
        Data("-----BEGIN \(label)-----\n\(der.base64EncodedString(options: .lineLength64Characters))\n-----END \(label)-----\n".utf8)
    }

    /// PrivateKeyInfo { version 0, rsaEncryption, OCTET STRING pkcs1 }.
    private static func pkcs8(wrapping pkcs1: Data) -> Data {
        let version: [UInt8] = [0x02, 0x01, 0x00]
        let algorithm: [UInt8] = [0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00]
        let key = [0x04] + length(pkcs1.count) + [UInt8](pkcs1)
        let body = version + algorithm + key
        return Data([0x30] + length(body.count) + body)
    }

    private static func length(_ count: Int) -> [UInt8] {
        if count < 0x80 { return [UInt8(count)] }
        var bytes: [UInt8] = []
        var value = count
        while value > 0 { bytes.insert(UInt8(value & 0xFF), at: 0); value >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }
}
