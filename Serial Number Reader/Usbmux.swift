import Foundation

/// Minimal usbmuxd + lockdownd client, used for exactly one job: asking a
/// normally booted iPhone/iPad to reboot into Recovery mode.
///
/// Protocol: connect to the `usbmuxd` Unix socket, list attached devices,
/// open a tunnel to the device's lockdownd (port 62078), and send an
/// `EnterRecovery` request. No pairing, trust, or privileges are required —
/// this is the same mechanism `ideviceenterrecovery` uses.
nonisolated enum Usbmux {

    enum Failure: LocalizedError {
        case socketError(String)
        case deviceNotFound
        case protocolError(String)
        case lockdownError(String)

        var errorDescription: String? {
            switch self {
            case .socketError(let detail): "Couldn't reach usbmuxd: \(detail)"
            case .deviceNotFound: "The device is not visible to usbmuxd — is it still connected and unlocked at least once since boot?"
            case .protocolError(let detail): "Unexpected usbmuxd reply: \(detail)"
            case .lockdownError(let detail): "The device refused: \(detail)"
            }
        }
    }

    private static let socketPath = "/var/run/usbmuxd"
    private static let lockdownPort: UInt16 = 62078

    /// Sends lockdownd's `EnterRecovery` to the device with the given UDID.
    /// Blocking — call off the main thread. On success the device disconnects
    /// and reappears in Recovery mode on its own.
    static func enterRecovery(udid: String) throws {
        let fd = try openSocket()
        defer { close(fd) }

        // 1. Find the usbmux device ID for this UDID.
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
        var deviceID: Int?
        for entry in deviceList {
            guard let props = entry["Properties"] as? [String: Any],
                  (props["ConnectionType"] as? String) == "USB",
                  let serial = props["SerialNumber"] as? String,
                  normalized(serial) == wanted
            else { continue }
            deviceID = (props["DeviceID"] as? Int) ?? (entry["DeviceID"] as? Int)
            break
        }
        guard let deviceID else { throw Failure.deviceNotFound }

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
        try lockdownSend(fd, [
            "Label": "SerialNumberReader",
            "Request": "EnterRecovery",
        ])
        let reply = try lockdownReceive(fd)
        if let error = reply["Error"] as? String {
            throw Failure.lockdownError(error)
        }
        guard (reply["Request"] as? String) == "EnterRecovery" else {
            throw Failure.protocolError("unexpected lockdown reply: \(reply)")
        }
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

    private static func lockdownSend(_ fd: Int32, _ payload: [String: Any]) throws {
        let plist = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        var packet = Data()
        withUnsafeBytes(of: UInt32(plist.count).bigEndian) { packet.append(contentsOf: $0) }
        packet.append(plist)
        try writeAll(fd, packet)
    }

    private static func lockdownReceive(_ fd: Int32) throws -> [String: Any] {
        let lengthData = try readExactly(fd, 4)
        let length = lengthData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian
        guard length > 0, length < 1 << 24 else { throw Failure.protocolError("bad lockdown length") }
        let body = try readExactly(fd, Int(length))
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
