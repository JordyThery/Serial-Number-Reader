import Foundation
import IOKit
import IOKit.usb
import Observation
import os

/// Watches IOKit for Apple USB devices (vendor ID 0x05AC) arriving and
/// leaving, classifies them by product ID, and publishes an observable list.
/// The UI consumes `devices` and nothing else touches IOKit.
@MainActor
@Observable
final class USBDeviceMonitor {

    /// Connection log: one entry per plug-in event, newest first. Entries
    /// stay (marked disconnected) until the user removes them, and a device
    /// reconnecting gets a fresh entry.
    private(set) var devices: [USBDevice] = []

    static let appleVendorID = 0x05AC
    static let dfuProductID = 0x1227
    /// Newer devices (observed: iPhone 17e / USB-C era on macOS 26) enumerate
    /// in DFU mode as a vendor-specific "Debug USB" function instead of the
    /// classic DFU device. It carries no serial-number descriptor at all —
    /// no CPID/BDID/ECID — and user-client access requires a private Apple
    /// entitlement, so only its presence can be detected.
    static let debugUSBProductID = 0x1881
    static let recoveryProductID = 0x1281
    /// Product-ID range used by normally booted iPhones/iPads/iPods.
    static let normalModeProductIDs = 0x1290...0x12AF

    @ObservationIgnored private var notifyPort: IONotificationPortRef?
    @ObservationIgnored private var addedIterator: io_iterator_t = 0
    @ObservationIgnored private var removedIterator: io_iterator_t = 0

    private let logger = Logger(subsystem: "be.jordythery.SerialNumberReader", category: "USBDeviceMonitor")

    // MARK: - Lifecycle

    func start() {
        guard notifyPort == nil else { return }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            logger.error("IONotificationPortCreate failed")
            return
        }
        notifyPort = port
        // Deliver notifications on the main queue so callbacks are MainActor-safe.
        IONotificationPortSetDispatchQueue(port, .main)

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        // kIOFirstPublishNotification, not kIOFirstMatchNotification: a DFU-mode
        // device is vendor-specific and never gets a kernel driver attached, so
        // "first match" would never fire for it. "First publish" fires as soon
        // as the device is registered in the IORegistry, driver or not — and
        // the USB string descriptors are read during enumeration, so the
        // serial-number property is already populated at that point.
        var result = IOServiceAddMatchingNotification(
            port, kIOFirstPublishNotification, Self.usbDeviceMatchingDictionary(),
            usbDeviceAddedCallback, refcon, &addedIterator
        )
        if result != KERN_SUCCESS {
            logger.error("Arrival notification registration failed: \(result)")
        }

        result = IOServiceAddMatchingNotification(
            port, kIOTerminatedNotification, Self.usbDeviceMatchingDictionary(),
            usbDeviceRemovedCallback, refcon, &removedIterator
        )
        if result != KERN_SUCCESS {
            logger.error("Removal notification registration failed: \(result)")
        }

        // Drain both iterators to pick up already-connected devices and arm
        // the notifications.
        handleAdded(iterator: addedIterator)
        handleRemoved(iterator: removedIterator)
    }

    func stop() {
        if addedIterator != 0 { IOObjectRelease(addedIterator); addedIterator = 0 }
        if removedIterator != 0 { IOObjectRelease(removedIterator); removedIterator = 0 }
        if let notifyPort { IONotificationPortDestroy(notifyPort) }
        notifyPort = nil
        devices.removeAll()
    }

    /// Matching dictionary for USB devices.
    ///
    /// Matches the modern `IOUSBHostDevice` class (macOS 10.11+): recent macOS
    /// releases no longer publish the legacy `IOUSBDevice` compatibility nubs,
    /// so matching `kIOUSBDeviceClassName` never fires for attached devices.
    /// No `idVendor` key here — USB matching dictionaries only honour specific
    /// key combinations, so vendor filtering happens in `makeDevice(from:)`.
    ///
    /// `IOServiceAddMatchingNotification` consumes one reference per call, so
    /// callers get a fresh dictionary each time.
    private static func usbDeviceMatchingDictionary() -> CFMutableDictionary? {
        IOServiceMatching("IOUSBHostDevice")
    }

    // MARK: - Notification handling

    fileprivate func handleAdded(iterator: io_iterator_t) {
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let device = makeDevice(from: service) {
                if let index = devices.firstIndex(where: { $0.id == device.id }) {
                    devices[index] = device
                } else {
                    // Drop this device's own stale disconnected rows so a
                    // device cycling modes (Normal→DFU→Normal during a restart)
                    // doesn't pile up duplicates. Distinct connected devices
                    // keep their own rows.
                    if let key = device.identityKey {
                        devices.removeAll { !$0.isConnected && $0.identityKey == key }
                    } else if device.isOpaqueDFU {
                        // Opaque DFU entries share no identity; collapse prior
                        // disconnected ones so they don't accumulate either.
                        devices.removeAll { !$0.isConnected && $0.isOpaqueDFU }
                    }
                    // Newest on top.
                    devices.insert(device, at: 0)
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    fileprivate func handleRemoved(iterator: io_iterator_t) {
        var service = IOIteratorNext(iterator)
        while service != 0 {
            var entryID: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS,
               let index = devices.firstIndex(where: { $0.id == entryID }) {
                // Keep the entry cached so its data stays visible after unplugging.
                devices[index].isConnected = false
                devices[index].disconnectedAt = .now
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    // MARK: - Cached entries

    /// Removes a cached (disconnected) entry. Connected devices can't be
    /// removed — they would immediately reappear.
    func removeFromList(_ id: USBDevice.ID) {
        devices.removeAll { $0.id == id && !$0.isConnected }
    }

    func clearDisconnected() {
        devices.removeAll { !$0.isConnected }
    }

    var hasDisconnectedDevices: Bool {
        devices.contains { !$0.isConnected }
    }

    // MARK: - Device construction

    private func makeDevice(from service: io_service_t) -> USBDevice? {
        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { return nil }

        guard let vendorID: Int = property("idVendor", of: service),
              vendorID == Self.appleVendorID,
              let productID: Int = property("idProduct", of: service)
        else { return nil }

        let serialString: String? = property(kUSBSerialNumberString, of: service)
            ?? property("kUSBSerialNumberString", of: service)
        let productName: String? = property(kUSBProductString, of: service)
            ?? property("kUSBProductString", of: service)

        logger.debug("""
            Apple USB device: pid=0x\(String(productID, radix: 16), privacy: .public) \
            name=\(productName ?? "nil", privacy: .public) \
            serialDescriptor=\(serialString ?? "nil", privacy: .public)
            """)

        switch productID {
        case Self.dfuProductID, Self.recoveryProductID, Self.debugUSBProductID:
            let mode: DeviceMode = productID == Self.recoveryProductID ? .recovery : .dfu
            let parsed = serialString.map(DescriptorParser.parse)
            let model = ModelDatabase.shared.model(cpidHex: parsed?.cpid, bdidHex: parsed?.bdid)
            return USBDevice(
                id: entryID, mode: mode, productID: productID,
                usbProductName: productName, rawSerialDescriptor: serialString,
                descriptor: parsed, udid: nil, modelInfo: model, connectedAt: .now
            )

        default:
            // Normally booted iPhone/iPad. Anything else from Apple
            // (keyboards, hubs, trackpads, …) is ignored.
            let lowercasedName = productName?.lowercased() ?? ""
            let looksLikeDevice = lowercasedName.contains("iphone") || lowercasedName.contains("ipad")
            guard Self.normalModeProductIDs.contains(productID) || looksLikeDevice else {
                logger.debug("Ignoring non-device Apple accessory pid=0x\(String(productID, radix: 16), privacy: .public)")
                return nil
            }
            let udid = serialString.flatMap(DescriptorParser.normalizedUDID)
            return USBDevice(
                id: entryID, mode: .normal, productID: productID,
                usbProductName: productName, rawSerialDescriptor: serialString,
                descriptor: nil, udid: udid, modelInfo: nil, connectedAt: .now
            )
        }
    }

    private func property<T>(_ key: String, of service: io_service_t) -> T? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? T
    }
}

// MARK: - C callbacks

/// IOKit C callbacks can't capture context; the monitor is passed via refcon.
/// They run on the main queue (see `IONotificationPortSetDispatchQueue`).
private nonisolated func usbDeviceAddedCallback(refcon: UnsafeMutableRawPointer?, iterator: io_iterator_t) {
    guard let refcon else { return }
    let monitor = Unmanaged<USBDeviceMonitor>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { monitor.handleAdded(iterator: iterator) }
}

private nonisolated func usbDeviceRemovedCallback(refcon: UnsafeMutableRawPointer?, iterator: io_iterator_t) {
    guard let refcon else { return }
    let monitor = Unmanaged<USBDeviceMonitor>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { monitor.handleRemoved(iterator: iterator) }
}
