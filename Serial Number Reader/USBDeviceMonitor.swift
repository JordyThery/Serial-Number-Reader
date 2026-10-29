import Foundation
import IOKit
import IOKit.usb
import Observation
import os

/// Watches IOKit for Apple USB devices (vendor ID 0x05AC) arriving and
/// leaving, classifies them by product ID, and publishes an observable list.
/// The UI consumes `devices` and nothing else touches IOKit.
///
/// In demo mode it doesn't watch USB at all and lists only `DemoUSB`'s
/// pretend iPhone: real devices are hidden and nothing is read from them.
/// When demo mode is turned off it watches again and real devices reappear.
@MainActor
@Observable
final class USBDeviceMonitor {

    /// Connection log: one entry per plug-in event, newest first. Entries
    /// stay (marked disconnected) until the user removes them, and a device
    /// reconnecting gets a fresh entry. In demo mode: the pretend iPhone's.
    var devices: [USBDevice] {
        if let demo, demo.isOn { return demo.devices }
        return realDevices
    }

    /// The real devices; always empty in demo mode.
    private var realDevices: [USBDevice] = []

    /// Whether IOKit is being watched (never in demo mode).
    var isWatchingUSB: Bool { notifyPort != nil }

    private let hardware: any USBHardware
    /// False under tests with the real doorway: the unit-test host and the
    /// release check never watch real USB, so a plugged-in device is never read.
    private let watchesRealUSB: Bool
    let demo: DemoUSB?
    @ObservationIgnored private var isStarted = false

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

    /// - Parameters:
    ///   - hardware: the lockdown and Configurator reads; the real ones by default.
    ///   - demo: demo mode's pretend iPhone; nil without demo mode.
    ///   - underTest: whether this launch is under tests (`UnderTest.isActive`).
    init(hardware: any USBHardware = LiveUSBHardware(), demo: DemoUSB? = nil, underTest: Bool = UnderTest.isActive) {
        self.hardware = hardware
        self.demo = demo
        watchesRealUSB = !(underTest && hardware is LiveUSBHardware)
    }

    // MARK: - Lifecycle

    /// Starts watching USB, or, in demo mode, plugs in the pretend iPhone;
    /// from then on follows the demo switch.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        followDemoMode()
    }

    /// Stops everything: no more watching, the list is emptied.
    func stop() {
        isStarted = false
        stopWatching()
        demo?.disconnect()
    }

    private func followDemoMode() {
        guard isStarted else { return }
        if let demo, demo.isOn {
            // Before anything else: from here on nothing reads a real device.
            stopWatching()
            demo.connect()
        } else {
            demo?.disconnect()
            startWatching()
        }
        guard let demo else { return }
        withObservationTracking {
            _ = demo.isOn
        } onChange: { [weak self] in
            // Called before the change: apply it afterwards.
            Task { @MainActor [weak self] in self?.followDemoMode() }
        }
    }

    private func startWatching() {
        guard notifyPort == nil, demo?.isOn != true, watchesRealUSB else { return }
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

    /// Stops watching and forgets the real devices (hidden in demo mode;
    /// they're found again when watching starts).
    private func stopWatching() {
        if addedIterator != 0 { IOObjectRelease(addedIterator); addedIterator = 0 }
        if removedIterator != 0 { IOObjectRelease(removedIterator); removedIterator = 0 }
        if let notifyPort { IONotificationPortDestroy(notifyPort) }
        notifyPort = nil
        realDevices.removeAll()
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
                add(device)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    /// A real device arrived (from IOKit, or a test). Ignored in demo mode:
    /// nothing is read from it, and it isn't listed.
    func add(_ device: USBDevice) {
        guard demo?.isOn != true, !PretendIPhone.isPretend(device) else { return }
        if let index = realDevices.firstIndex(where: { $0.id == device.id }) {
            // Re-published entry: keep details already read from the device.
            var updated = device
            let existing = realDevices[index]
            if existing.lockdownInfo != nil || existing.configurator != nil {
                updated.lockdownInfo = existing.lockdownInfo
                updated.configurator = existing.configurator
                updated.modelInfo = existing.modelInfo
                updated.isTrusted = existing.isTrusted
            }
            realDevices[index] = updated
        } else {
            // Drop this device's own stale disconnected rows so a
            // device cycling modes (Normal→DFU→Normal during a restart)
            // doesn't pile up duplicates. Distinct connected devices
            // keep their own rows.
            if let key = device.identityKey {
                realDevices.removeAll { !$0.isConnected && $0.identityKey == key }
            } else if device.isOpaqueDFU {
                // Opaque DFU entries share no identity; collapse prior
                // disconnected ones so they don't accumulate either.
                realDevices.removeAll { !$0.isConnected && $0.isOpaqueDFU }
            }
            // Newest on top.
            realDevices.insert(device, at: 0)
            if device.mode == .normal, let udid = device.udid {
                readLockdownInfo(deviceID: device.id, udid: udid)
            }
            if device.mode == .dfu {
                identifyWithConfigurator(deviceID: device.id)
            }
        }
    }

    fileprivate func handleRemoved(iterator: io_iterator_t) {
        var service = IOIteratorNext(iterator)
        while service != 0 {
            var entryID: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS,
               let index = realDevices.firstIndex(where: { $0.id == entryID }) {
                // Keep the entry cached so its data stays visible after unplugging.
                realDevices[index].isConnected = false
                realDevices[index].disconnectedAt = .now
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    // MARK: - Booted-device details

    /// Reads model, OS version and name from a booted device. usbmuxd lists a
    /// device shortly after it appears on USB, so a few retries cover the gap.
    /// Failure is silent: the row keeps the USB product name.
    private func readLockdownInfo(deviceID: UInt64, udid: String) {
        Task {
            for attempt in 0..<5 {
                if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
                guard realDevices.contains(where: { $0.id == deviceID && $0.isConnected }) else { return }
                let hardware = hardware
                let info = try? await Task.detached(priority: .utility) {
                    try hardware.deviceInfo(udid: udid)
                }.value
                if let info {
                    apply(info, toDeviceID: deviceID)
                    refreshTrust(deviceID: deviceID)
                    return
                }
            }
            logger.debug("No lockdown details for device \(deviceID)")
        }
    }

    /// Re-checks whether this Mac holds a pairing for a booted device — after
    /// the user taps Trust, or after Remove Trust.
    /// In demo mode the pretend iPhone's trust is simulated: nothing is read.
    func refreshTrust(deviceID: UInt64) {
        guard demo?.isOn != true,
              let device = realDevices.first(where: { $0.id == deviceID }),
              device.mode == .normal, device.isConnected, let udid = device.udid
        else { return }
        let hardware = hardware
        Task {
            let trusted = await Task.detached(priority: .utility) { hardware.hasPairRecord(udid: udid) }.value
            if let index = realDevices.firstIndex(where: { $0.id == deviceID }) {
                realDevices[index].isTrusted = trusted
            }
        }
    }

    // MARK: - Configurator identification

    /// Identifies a DFU device through Apple Configurator, which reports the
    /// ECID, UDID and model even for "Debug USB" devices. Configurator can
    /// take a moment to see a new device, hence the retries. Silent when
    /// Configurator isn't installed or doesn't list the device.
    private func identifyWithConfigurator(deviceID: UInt64) {
        guard hardware.isConfiguratorAvailable else { return }
        let hardware = hardware
        Task {
            for attempt in 0..<4 {
                if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
                guard let device = realDevices.first(where: { $0.id == deviceID && $0.isConnected }) else { return }
                let listed = (try? await Task.detached(priority: .utility) { try hardware.listConfiguratorDevices() }.value) ?? []
                if let match = Self.configuratorMatch(in: listed, locationID: device.locationID, ecid: device.ecid) {
                    apply(match, toDeviceID: deviceID)
                    return
                }
            }
            logger.debug("Configurator didn't identify device \(deviceID)")
        }
    }

    /// Links a row to Configurator's device: by ECID when the USB descriptor
    /// has one, otherwise by USB location ID — but only when exactly one
    /// device has it, so a row is never linked to the wrong device.
    nonisolated static func configuratorMatch(
        in listed: [ConfiguratorDevice], locationID: UInt32?, ecid: String?
    ) -> ConfiguratorDevice? {
        if let ecid, let wanted = Configurator.normalizedECID(ecid) {
            return listed.first { Configurator.normalizedECID($0.ecid) == wanted }
        }
        guard let locationID else { return nil }
        let candidates = listed.filter { $0.locationID == locationID }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private func apply(_ match: ConfiguratorDevice, toDeviceID deviceID: UInt64) {
        guard let index = realDevices.firstIndex(where: { $0.id == deviceID }) else { return }
        realDevices[index].configurator = match
        if realDevices[index].modelInfo == nil, let deviceType = match.deviceType {
            realDevices[index].modelInfo = ModelDatabase.shared.model(identifier: deviceType)
        }
    }

    /// Marks a device as no longer trusted after Remove Trust succeeded
    /// (the pretend iPhone keeps its own trust).
    func markUntrusted(deviceID: UInt64) {
        if let index = realDevices.firstIndex(where: { $0.id == deviceID }) {
            realDevices[index].isTrusted = false
        }
    }

    private func apply(_ info: LockdownDeviceInfo, toDeviceID deviceID: UInt64) {
        guard let index = realDevices.firstIndex(where: { $0.id == deviceID }) else { return }
        realDevices[index].lockdownInfo = info
        if let productType = info.productType {
            realDevices[index].modelInfo = ModelDatabase.shared.model(identifier: productType)
        }
    }

    // MARK: - Cached entries

    /// Removes a cached (disconnected) entry. Connected devices can't be
    /// removed — they would immediately reappear.
    func removeFromList(_ id: USBDevice.ID) {
        if let demo, demo.isOn { return demo.removeFromList(id) }
        realDevices.removeAll { $0.id == id && !$0.isConnected }
    }

    func clearDisconnected() {
        if let demo, demo.isOn { return demo.clearDisconnected() }
        realDevices.removeAll { !$0.isConnected }
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
            serialDescriptor=\(serialString ?? "nil", privacy: .private)
            """)
        let location = (property("locationID", of: service) as NSNumber?).map { UInt32(truncatingIfNeeded: $0.int64Value) }

        switch productID {
        case Self.dfuProductID, Self.recoveryProductID, Self.debugUSBProductID:
            let mode: DeviceMode = productID == Self.recoveryProductID ? .recovery : .dfu
            let parsed = serialString.map(DescriptorParser.parse)
            let model = ModelDatabase.shared.model(cpidHex: parsed?.cpid, bdidHex: parsed?.bdid)
            return USBDevice(
                id: entryID, mode: mode, productID: productID,
                usbProductName: productName, rawSerialDescriptor: serialString,
                descriptor: parsed, udid: nil, modelInfo: model,
                locationID: location, connectedAt: .now
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
                descriptor: nil, udid: udid, modelInfo: nil,
                locationID: location, connectedAt: .now
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
