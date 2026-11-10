import Foundation
import IOKit

/// Which USB-C port of this Mac a device is plugged into, so Restart and
/// Enter DFU go to that one port and no other (docs/usb-c-port-targeting.md).
///
/// The chain, read from the IORegistry without privileges:
/// the device (`IOUSBHostDevice`, Apple, a phone, tablet or Mac product ID) →
/// its direct parent, a USB root port with no hub above it, carrying
/// `UsbIOPort` (the path of its physical port) → that `Port-USB-C@N` entry,
/// whose N matches the root port's `usb-c-port-number`, with a connection →
/// the first `AppleHPM` ancestor, listed exactly once among the AppleHPM
/// services → its `RID`.
///
/// These properties aren't documented. Any missing or ambiguous step refuses:
/// a change on Apple's side can only mean "not available", never "sent to the
/// wrong port". The app runs this before the administrator prompt to dim the
/// buttons; the root helper runs it again itself, and once more just before
/// sending.
nonisolated enum USBCPort {

    /// The port controller to send to.
    struct Target: Equatable, Sendable {
        /// The AppleHPM service's registry entry ID.
        let controllerID: UInt64
        let rid: Int32
        /// The N of `Port-USB-C@N`.
        let portNumber: Int
    }

    /// Why Restart and Enter DFU can't go to this device.
    enum Refusal: Error, Equatable, Sendable {
        /// An Intel Mac: the port commands exist only on Apple silicon.
        case intelMac
        /// The app runs under Rosetta: the root helper couldn't load the
        /// port interface (it's Apple silicon code).
        case rosetta
        /// The device's USB entry is gone (unplugged, or rebooting).
        case deviceGone
        /// Not an iPhone, iPad or Mac product ID.
        case notAppleDevice
        /// A hub (or a dock's hub) sits between the device and the Mac.
        case throughHub
        /// The chain can't be followed: a dock, an adapter, or a Mac model
        /// that doesn't name its ports.
        case portUnknown
        /// The port reports no connection.
        case portNotActive
        /// Under tests nothing is read (`USBGuard`).
        case underTest

        var message: String {
            switch self {
            case .intelMac:
                "Restart and Enter DFU work only on a Mac with Apple silicon. On this Mac, use the device’s buttons instead."
            case .rosetta:
                "Restart and Enter DFU don’t work while Serial Number Reader runs under Rosetta. Quit it, turn off “Open using Rosetta” in its Get Info window, and open it again."
            case .deviceGone:
                "The device is no longer connected."
            case .notAppleDevice:
                "This USB device isn’t an iPhone, iPad or Mac that Restart and Enter DFU can reach."
            case .throughHub:
                "This device is connected through a hub or dock. Connect it directly to a USB-C port of this Mac: the command reaches only what is plugged into the Mac’s own port."
            case .portUnknown:
                "The app can’t tell which USB-C port of this Mac the device is on. Connect it directly to a USB-C port of this Mac, not through a hub, dock or adapter."
            case .portNotActive:
                "This Mac reports no connection on the device’s USB-C port. Reconnect the cable and try again."
            case .underTest:
                UnderTest.refusal
            }
        }

        /// The tooltip of a dimmed Restart or Enter DFU; `message` is in the
        /// note under the buttons.
        var shortReason: String {
            switch self {
            case .intelMac: "Needs a Mac with Apple silicon"
            case .rosetta: "Unavailable while the app runs under Rosetta"
            case .deviceGone: "The device is no longer connected"
            case .notAppleDevice: "Not an iPhone, iPad or Mac"
            case .throughHub, .portUnknown: "Connect the device directly to the Mac"
            case .portNotActive: "No connection on this port: reconnect the cable"
            case .underTest: "Unavailable under tests"
            }
        }
    }

    typealias Check = Result<Target, Refusal>

    /// The registry keys and classes the chain uses.
    enum Key {
        static let vendorID = "idVendor"
        static let productID = "idProduct"
        static let usbIOPort = "UsbIOPort"
        static let portNumber = "usb-c-port-number"
        static let description = "Description"
        static let connectionActive = "ConnectionActive"
        static let rid = "RID"
        static let usbDeviceClass = "IOUSBHostDevice"
        static let hpmClass = "AppleHPM"
        static let portPrefix = "Port-USB-C@"
    }

    /// Product IDs of an iPhone, iPad or Mac on USB: booted, Recovery, both
    /// kinds of DFU.
    static func isAppleDeviceProduct(_ productID: Int) -> Bool {
        USBDeviceMonitor.normalModeProductIDs.contains(productID)
            || [USBDeviceMonitor.recoveryProductID, USBDeviceMonitor.dfuProductID,
                USBDeviceMonitor.debugUSBProductID].contains(productID)
    }

    /// No chain is longer than this; a loop in a bad snapshot ends here.
    static let maxDepth = 64

    /// Follows the chain from the device's registry entry to its port controller.
    /// - Parameter isTranslated: the app runs under Rosetta.
    static func locate(deviceEntryID: UInt64, in registry: some USBCPortRegistry, isAppleSilicon: Bool,
                       isTranslated: Bool = false) -> Check {
        guard isAppleSilicon else { return .failure(.intelMac) }
        guard !isTranslated else { return .failure(.rosetta) }
        guard let device = registry.entry(id: deviceEntryID) else { return .failure(.deviceGone) }
        guard device.conforms(to: Key.usbDeviceClass),
              device.integer(Key.vendorID) == USBDeviceMonitor.appleVendorID,
              let productID = device.integer(Key.productID), isAppleDeviceProduct(productID)
        else { return .failure(.notAppleDevice) }

        // Directly on a root port: no other USB device (a hub) anywhere above
        // it, proven all the way up to the registry's root.
        guard let above = registry.ancestors(of: device), let rootPort = above.first else { return .failure(.portUnknown) }
        if above.contains(where: { $0.conforms(to: Key.usbDeviceClass) }) { return .failure(.throughHub) }

        // The root port names its physical port.
        guard let path = rootPort.string(Key.usbIOPort), !path.isEmpty,
              let port = registry.entry(path: path),
              let name = port.string(Key.description), name.hasPrefix(Key.portPrefix),
              let portNumber = Int(name.dropFirst(Key.portPrefix.count)),
              rootPort.integer(Key.portNumber) == portNumber
        else { return .failure(.portUnknown) }
        guard port.bool(Key.connectionActive) == true else { return .failure(.portNotActive) }

        // The port's own controller, one of the AppleHPM services, exactly once.
        guard let controller = registry.ancestors(of: port)?.first(where: { $0.conforms(to: Key.hpmClass) }),
              registry.controllerIDs().filter({ $0 == controller.id }).count == 1,
              let rid = controller.integer(Key.rid), let rid32 = Int32(exactly: rid)
        else { return .failure(.portUnknown) }
        return .success(Target(controllerID: controller.id, rid: rid32, portNumber: portNumber))
    }

    /// True on Apple silicon, also for an Intel build under Rosetta.
    static var isAppleSilicon: Bool { sysctlFlag("hw.optional.arm64") }

    /// True while this process runs under Rosetta.
    static var isTranslated: Bool { sysctlFlag("sysctl.proc_translated") }

    private static func sysctlFlag(_ name: String) -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 && value == 1
    }
}

// MARK: - The registry

/// One registry entry, with only what the chain reads.
nonisolated struct USBCPortRegistryEntry: Equatable, Sendable {
    enum Value: Equatable, Sendable {
        case number(Int)
        case string(String)
        case bool(Bool)
        /// Little-endian bytes, as `usb-c-port-number` is stored.
        case data(Data)
    }

    let id: UInt64
    /// The classes (of those the chain asks about) it conforms to.
    let classes: Set<String>
    let properties: [String: Value]

    func conforms(to className: String) -> Bool { classes.contains(className) }

    func integer(_ key: String) -> Int? {
        switch properties[key] {
        case .number(let value): return value
        case .data(let bytes) where (1...8).contains(bytes.count):
            return bytes.reversed().reduce(0) { $0 << 8 | Int($1) }
        default: return nil
        }
    }

    func string(_ key: String) -> String? {
        if case .string(let value) = properties[key] { return value }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        if case .bool(let value) = properties[key] { return value }
        return nil
    }
}

/// Where the chain is read: the IORegistry, or made-up data in tests.
nonisolated protocol USBCPortRegistry {
    func entry(id: UInt64) -> USBCPortRegistryEntry?
    /// The entry at an IORegistry path such as `IOService:/…/Port-USB-C@2`.
    func entry(path: String) -> USBCPortRegistryEntry?
    /// Every entry above this one in the IOService plane, nearest first,
    /// ending at the registry's root; nil when the walk can't reach the root
    /// (a parent that can't be read, a loop), so nothing above is proven.
    func ancestors(of entry: USBCPortRegistryEntry) -> [USBCPortRegistryEntry]?
    /// The entry IDs of every AppleHPM service.
    func controllerIDs() -> [UInt64]
}

/// The Mac's own IORegistry. Reads only; needs no privileges.
nonisolated struct LiveUSBCPortRegistry: USBCPortRegistry {
    private static let classes = [USBCPort.Key.usbDeviceClass, USBCPort.Key.hpmClass]
    private static let keys = [USBCPort.Key.vendorID, USBCPort.Key.productID, USBCPort.Key.usbIOPort,
                               USBCPort.Key.portNumber, USBCPort.Key.description,
                               USBCPort.Key.connectionActive, USBCPort.Key.rid]

    func entry(id: UInt64) -> USBCPortRegistryEntry? {
        guard let matching = IORegistryEntryIDMatching(id) else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        return Self.read(service)
    }

    func entry(path: String) -> USBCPortRegistryEntry? {
        Self.read(IORegistryEntryFromPath(kIOMainPortDefault, path))
    }

    /// Walks the live entries with `IORegistryEntryGetParentEntry`, never
    /// looking an entry up again by ID, and checks the walk ends at the root.
    func ancestors(of entry: USBCPortRegistryEntry) -> [USBCPortRegistryEntry]? {
        guard let matching = IORegistryEntryIDMatching(entry.id) else { return nil }
        var current = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard current != 0 else { return nil }
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        var rootID: UInt64 = 0
        guard root != 0, IORegistryEntryGetRegistryEntryID(root, &rootID) == KERN_SUCCESS else {
            IOObjectRelease(current)
            return nil
        }
        var chain: [USBCPortRegistryEntry] = []
        for _ in 0..<USBCPort.maxDepth {
            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            IOObjectRelease(current)
            guard result == KERN_SUCCESS, parent != 0 else { return nil }
            var parentID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(parent, &parentID) == KERN_SUCCESS else {
                IOObjectRelease(parent)
                return nil
            }
            if parentID == rootID {
                IOObjectRelease(parent)
                return chain
            }
            IOObjectRetain(parent)
            guard let read = Self.read(parent) else {
                IOObjectRelease(parent)
                return nil
            }
            chain.append(read)
            current = parent
        }
        IOObjectRelease(current)
        return nil
    }

    func controllerIDs() -> [UInt64] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(USBCPort.Key.hpmClass),
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var ids: [UInt64] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            var id: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS { ids.append(id) }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return ids
    }

    /// Reads an entry and releases it.
    private static func read(_ object: io_registry_entry_t) -> USBCPortRegistryEntry? {
        guard object != 0 else { return nil }
        defer { IOObjectRelease(object) }
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(object, &id) == KERN_SUCCESS else { return nil }
        let classes = Set(Self.classes.filter { IOObjectConformsTo(object, $0) != 0 })
        var properties: [String: USBCPortRegistryEntry.Value] = [:]
        for key in keys {
            guard let value = IORegistryEntryCreateCFProperty(object, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() else { continue }
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                properties[key] = .bool((value as? NSNumber)?.boolValue == true)
            } else if let number = value as? NSNumber {
                properties[key] = .number(number.intValue)
            } else if let string = value as? String {
                properties[key] = .string(string)
            } else if let data = value as? Data {
                properties[key] = .data(data)
            }
        }
        return USBCPortRegistryEntry(id: id, classes: classes, properties: properties)
    }
}
