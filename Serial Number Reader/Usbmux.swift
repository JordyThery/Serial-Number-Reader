import Foundation

/// Values a booted device reports before pairing. The serial number, model
/// number and region are refused ("GetProhibited") without a pairing.
nonisolated struct LockdownDeviceInfo: Equatable, Sendable {
    /// Model identifier, e.g. "iPad16,1".
    let productType: String?
    /// OS version, e.g. "27.0".
    let productVersion: String?
    /// OS build, e.g. "24A5430a".
    let buildVersion: String?
    /// "iPhone", "iPad", …
    let deviceClass: String?
    /// The name set on the device (user-editable).
    let deviceName: String?

    /// Parses the dictionary returned by an unpaired `GetValue` request.
    static func parse(_ values: [String: Any]) -> LockdownDeviceInfo {
        func string(_ key: String) -> String? {
            guard let value = values[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return LockdownDeviceInfo(
            productType: string("ProductType"),
            productVersion: string("ProductVersion"),
            buildVersion: string("BuildVersion"),
            deviceClass: string("DeviceClass"),
            deviceName: string("DeviceName")
        )
    }

    /// "iPadOS 27.0 (24A5430a)". `ProductName` reports "iPhone OS" for every
    /// device, so the OS name is derived from the device class instead.
    var osDisplayName: String? {
        guard let productVersion else { return nil }
        let os = switch deviceClass {
        case "iPad": "iPadOS"
        case "iPhone", "iPod": "iOS"
        default: "OS"
        }
        let build = buildVersion.map { " (\($0))" } ?? ""
        return "\(os) \(productVersion)\(build)"
    }
}

/// Minimal usbmuxd + lockdownd client for a normally booted iPhone/iPad:
/// reading the values it reports before pairing, and asking it to reboot into
/// Recovery mode.
///
/// Protocol: connect to the `usbmuxd` Unix socket, list attached devices, open
/// a tunnel to the device's lockdownd (port 62078), and send one request. No
/// pairing session is started, so no trust or privileges are required — the
/// same mechanism `ideviceinfo -s` and `ideviceenterrecovery` use.
nonisolated enum Usbmux {

    enum Failure: LocalizedError {
        case socketError(String)
        case deviceNotFound
        case protocolError(String)
        case lockdownError(String)
        case tlsError(String)
        /// The device only accepts the request from a Mac it trusts, and this
        /// Mac holds no (valid) pairing for it.
        case trustRequired

        var errorDescription: String? {
            switch self {
            case .socketError(let detail): "Couldn't reach usbmuxd: \(detail)"
            case .deviceNotFound: "The device is not visible to usbmuxd — is it still connected and unlocked at least once since boot?"
            case .protocolError(let detail): "Unexpected usbmuxd reply: \(detail)"
            case .lockdownError(let detail): "The device refused: \(detail)"
            case .tlsError(let detail): "The trusted connection failed: \(detail)"
            case .trustRequired: "This device only accepts Enter Recovery from a Mac it trusts."
            }
        }
    }

    private static let socketPath = "/var/run/usbmuxd"
    private static let lockdownPort: UInt16 = 62078

    /// Lockdown errors meaning "this request needs a paired session". iOS 27
    /// answers an unpaired EnterRecovery with SessionInactive.
    private static let trustRequiredErrors: Set<String> = ["SessionInactive", "InvalidHostID"]

    /// Sends lockdownd's `EnterRecovery` to the device with the given UDID.
    /// Blocking — call off the main thread. On success the device disconnects
    /// and reappears in Recovery mode on its own.
    ///
    /// Tries without pairing first (accepted up to iOS 26). If the device
    /// requires trust, retries over a paired TLS session using the pairing
    /// macOS stored when the device was trusted; throws `.trustRequired` when
    /// there is none.
    static func enterRecovery(udid: String) throws {
        do {
            try withLockdown(udid: udid) { connection in
                try sendEnterRecovery(over: SocketChannel(fd: connection.fd))
            }
        } catch Failure.lockdownError(let code) where trustRequiredErrors.contains(code) {
            try enterRecoveryPaired(udid: udid)
        }
    }

    /// Whether this Mac holds a pairing for the device (it was trusted here).
    static func hasPairRecord(udid: String) -> Bool {
        guard let serial = try? usbmuxSerial(udid: udid) else { return false }
        return (try? pairRecord(usbmuxSerial: serial)) != nil
    }

    private static func enterRecoveryPaired(udid: String) throws {
        try withLockdown(udid: udid) { connection in
            guard let record = try pairRecord(usbmuxSerial: connection.usbmuxSerial),
                  let hostID = record["HostID"] as? String,
                  let systemBUID = record["SystemBUID"] as? String,
                  let certificate = record["HostCertificate"] as? Data,
                  let privateKey = record["HostPrivateKey"] as? Data
            else { throw Failure.trustRequired }

            let plain = SocketChannel(fd: connection.fd)
            try lockdownSend(plain, [
                "Label": "SerialNumberReader",
                "Request": "StartSession",
                "HostID": hostID,
                "SystemBUID": systemBUID,
            ])
            let session = try lockdownReceive(plain)
            if let error = session["Error"] as? String {
                // The device was reset or the trust was removed on the device.
                if trustRequiredErrors.contains(error) { throw Failure.trustRequired }
                throw Failure.lockdownError(error)
            }

            if (session["EnableSessionSSL"] as? Bool) == true {
                let tls: LockdownTLS
                do {
                    tls = try LockdownTLS(socket: connection.fd, certificatePEM: certificate, privateKeyPEM: privateKey)
                } catch {
                    throw Failure.tlsError(error.localizedDescription)
                }
                defer { tls.close() }
                try sendEnterRecovery(over: TLSChannel(tls: tls))
            } else {
                try sendEnterRecovery(over: plain)
            }
        }
    }

    private static func sendEnterRecovery(over channel: LockdownChannel) throws {
        try lockdownSend(channel, [
            "Label": "SerialNumberReader",
            "Request": "EnterRecovery",
        ])
        let reply = try lockdownReceive(channel)
        if let error = reply["Error"] as? String {
            throw Failure.lockdownError(error)
        }
        guard (reply["Request"] as? String) == "EnterRecovery" else {
            throw Failure.protocolError("unexpected lockdown reply: \(reply)")
        }
    }

    /// The pairing macOS stored for the device, or nil when it isn't paired.
    private static func pairRecord(usbmuxSerial: String) throws -> [String: Any]? {
        let fd = try openSocket()
        defer { close(fd) }
        let reply = try muxRequest(fd, tag: 3, payload: [
            "MessageType": "ReadPairRecord",
            "PairRecordID": usbmuxSerial,
            "ProgName": "Serial Number Reader",
        ])
        guard let data = reply["PairRecordData"] as? Data else { return nil }
        return try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// Reads the values the device reports without pairing (model, OS
    /// version, name). Blocking — call off the main thread.
    static func deviceInfo(udid: String) throws -> LockdownDeviceInfo {
        try withLockdown(udid: udid) { connection in
            let channel = SocketChannel(fd: connection.fd)
            // GetValue without a key returns every value allowed unpaired.
            try lockdownSend(channel, [
                "Label": "SerialNumberReader",
                "Request": "GetValue",
            ])
            let reply = try lockdownReceive(channel)
            if let error = reply["Error"] as? String {
                throw Failure.lockdownError(error)
            }
            guard let values = reply["Value"] as? [String: Any] else {
                throw Failure.protocolError("GetValue reply without values")
            }
            return LockdownDeviceInfo.parse(values)
        }
    }

    /// An open tunnel to a device's lockdownd.
    private struct LockdownConnection {
        let fd: Int32
        /// The UDID exactly as usbmuxd formats it — the key for pair records.
        let usbmuxSerial: String
    }

    /// Opens a usbmux tunnel to the lockdownd of the USB device with this
    /// UDID and runs `body` on it.
    private static func withLockdown<T>(udid: String, _ body: (LockdownConnection) throws -> T) throws -> T {
        let fd = try openSocket()
        defer { close(fd) }

        // 1. Find the usbmux device ID for this UDID.
        let (deviceID, serial) = try findDevice(fd, udid: udid)

        // 2. Tunnel to lockdownd. The port travels in network byte order.
        let connectReply = try muxRequest(fd, tag: 2, payload: [
            "MessageType": "Connect",
            "DeviceID": deviceID,
            "PortNumber": Int(lockdownPort.byteSwapped),
            "ProgName": "Serial Number Reader",
        ])
        guard (connectReply["Number"] as? Int) == 0 else {
            throw Failure.protocolError("Connect failed: \(connectReply)")
        }

        // 3. From here the socket is a raw pipe to lockdownd.
        return try body(LockdownConnection(fd: fd, usbmuxSerial: serial))
    }

    private static func usbmuxSerial(udid: String) throws -> String {
        let fd = try openSocket()
        defer { close(fd) }
        return try findDevice(fd, udid: udid).serial
    }

    private static func findDevice(_ fd: Int32, udid: String) throws -> (deviceID: Int, serial: String) {
        let listReply = try muxRequest(fd, tag: 1, payload: [
            "MessageType": "ListDevices",
            "ProgName": "Serial Number Reader",
            "ClientVersionString": "1.0",
            "kLibUSBMuxVersion": 3,
        ])
        guard let deviceList = listReply["DeviceList"] as? [[String: Any]] else {
            throw Failure.protocolError("no DeviceList in reply")
        }
        let wanted = normalized(udid)
        for entry in deviceList {
            guard let props = entry["Properties"] as? [String: Any],
                  (props["ConnectionType"] as? String) == "USB",
                  let serial = props["SerialNumber"] as? String,
                  normalized(serial) == wanted,
                  let deviceID = (props["DeviceID"] as? Int) ?? (entry["DeviceID"] as? Int)
            else { continue }
            return (deviceID, serial)
        }
        throw Failure.deviceNotFound
    }

    // MARK: - Socket plumbing

    private static func openSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socketError(String(cString: strerror(errno))) }

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let ok = withUnsafeMutableBytes(of: &addr.sun_path) { raw -> Bool in
            let bytes = Array(socketPath.utf8)
            guard bytes.count < raw.count else { return false }
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
            return true
        }
        guard ok else { close(fd); throw Failure.socketError("socket path too long") }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw Failure.socketError(message)
        }
        return fd
    }

    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        var offset = 0
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard n > 0 else { throw Failure.socketError("write failed") }
                offset += n
            }
        }
    }

    private static func readExactly(_ fd: Int32, _ count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            while offset < count {
                let n = read(fd, raw.baseAddress!.advanced(by: offset), count - offset)
                guard n > 0 else { throw Failure.socketError("connection closed") }
                offset += n
            }
        }
        return data
    }

    // MARK: - usbmux framing (16-byte little-endian header + XML plist)

    private static func muxRequest(_ fd: Int32, tag: UInt32, payload: [String: Any]) throws -> [String: Any] {
        let plist = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        var packet = Data()
        for value: UInt32 in [UInt32(plist.count + 16), 1 /* version */, 8 /* plist */, tag] {
            withUnsafeBytes(of: value.littleEndian) { packet.append(contentsOf: $0) }
        }
        packet.append(plist)
        try writeAll(fd, packet)

        let header = try readExactly(fd, 16)
        let length = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }.littleEndian
        guard length >= 16, length < 1 << 24 else { throw Failure.protocolError("bad packet length") }
        let body = try readExactly(fd, Int(length) - 16)
        guard let reply = try PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any] else {
            throw Failure.protocolError("non-plist reply")
        }
        return reply
    }

    // MARK: - lockdown framing (4-byte big-endian length + XML plist)

    /// Where lockdown messages travel: the plain socket, or TLS on the same
    /// socket once a paired session has been started.
    private protocol LockdownChannel {
        func write(_ data: Data) throws
        func read(_ count: Int) throws -> Data
    }

    private struct SocketChannel: LockdownChannel {
        let fd: Int32
        func write(_ data: Data) throws { try writeAll(fd, data) }
        func read(_ count: Int) throws -> Data { try readExactly(fd, count) }
    }

    private struct TLSChannel: LockdownChannel {
        let tls: LockdownTLS
        func write(_ data: Data) throws {
            do { try tls.write(data) } catch { throw Failure.tlsError(error.localizedDescription) }
        }
        func read(_ count: Int) throws -> Data {
            do { return try tls.readLength(UInt(count)) } catch { throw Failure.tlsError(error.localizedDescription) }
        }
    }

    private static func lockdownSend(_ channel: LockdownChannel, _ payload: [String: Any]) throws {
        let plist = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        var packet = Data()
        withUnsafeBytes(of: UInt32(plist.count).bigEndian) { packet.append(contentsOf: $0) }
        packet.append(plist)
        try channel.write(packet)
    }

    private static func lockdownReceive(_ channel: LockdownChannel) throws -> [String: Any] {
        let lengthData = try channel.read(4)
        let length = lengthData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian
        guard length > 0, length < 1 << 24 else { throw Failure.protocolError("bad lockdown length") }
        let body = try channel.read(Int(length))
        guard let reply = try PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any] else {
            throw Failure.protocolError("non-plist lockdown reply")
        }
        return reply
    }

    /// UDID comparison ignoring hyphens and case (usbmuxd formatting varies).
    private static func normalized(_ value: String) -> String {
        value.lowercased().filter(\.isHexDigit)
    }
}
