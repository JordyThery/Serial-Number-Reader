import Foundation

/// How a connected Apple device is enumerating on USB.
nonisolated enum DeviceMode: String, Sendable {
    case recovery = "Recovery"
    case dfu = "DFU"
    case normal = "Normal"
}

/// What to look up in Jamf Pro for a given device.
nonisolated enum JamfQuery: Hashable, Sendable {
    case serialNumber(String)
    case udid(String)
}

/// An Apple device currently connected over USB, as published by `USBDeviceMonitor`.
nonisolated struct USBDevice: Identifiable, Equatable, Sendable {
    /// IORegistry entry ID — stable for the lifetime of the connection.
    let id: UInt64
    let mode: DeviceMode
    let productID: Int
    let usbProductName: String?
    /// The raw USB serial-number string descriptor, exactly as reported.
    let rawSerialDescriptor: String?
    /// Parsed descriptor fields (Recovery/DFU only).
    let descriptor: ParsedDescriptor?
    /// Normalised UDID (Normal mode only).
    let udid: String?
    /// Model resolved from CPID/BDID (Recovery/DFU) or from the model
    /// identifier a booted device reports.
    var modelInfo: ModelInfo?
    /// Values read from a booted device before pairing (Normal mode only);
    /// nil until read, or when the device didn't answer.
    var lockdownInfo: LockdownDeviceInfo? = nil
    /// USB location ID from the IORegistry; links DFU devices to Configurator.
    var locationID: UInt32? = nil
    /// The device as Apple Configurator reports it, when identified — the only
    /// source of identifiers for "Debug USB" DFU devices.
    var configurator: ConfiguratorDevice? = nil
    /// Whether this Mac holds a pairing for the device (Normal mode only).
    var isTrusted = false
    let connectedAt: Date
    /// False once the device has been unplugged; the entry stays in the list
    /// (cached) until the user removes it.
    var isConnected: Bool = true
    var disconnectedAt: Date? = nil

    var serialNumber: String? { descriptor?.serialNumber }

    /// 16 hex digits, from the USB descriptor or from Configurator.
    var ecid: String? {
        descriptor?.ecid ?? configurator.flatMap { Configurator.normalizedECID($0.ecid) }
    }

    /// UDID for display and Jamf lookups: from a booted device's USB
    /// descriptor or from Configurator, and otherwise derived from the chip
    /// ID and ECID (Configurator reports no UDID in DFU).
    var displayUDID: String? {
        udid
            ?? configurator?.udid.flatMap(DescriptorParser.normalizedUDID)
            ?? derivedUDID
    }

    /// From the A12 onward (and on Apple silicon Macs) the UDID is
    /// "<chip ID, 8 hex>-<ECID, 16 hex>". Older devices use a hash that can't
    /// be derived, so nothing is returned for them.
    private var derivedUDID: String? {
        guard let ecid, let normalizedECID = Configurator.normalizedECID(ecid) else { return nil }
        let chip = descriptor?.cpid.flatMap { UInt32($0, radix: 16) }
            ?? modelInfo.flatMap { ModelDatabase.shared.chipID(forIdentifier: $0.identifier) }
        guard let chip, Self.usesChipECIDUDID(chip) else { return nil }
        return String(format: "%08X-%@", chip, normalizedECID)
    }

    /// A12 (0x8020) and later, plus the Mac-only chips in 0x6000–0x6FFF
    /// (M1 Pro and later variants).
    static func usesChipECIDUDID(_ chip: UInt32) -> Bool {
        chip >= 0x8020 || (0x6000...0x6FFF).contains(chip)
    }

    /// The ECID in the form cfgutil's `-e` option takes. Booted devices with
    /// a modern UDID carry it after the hyphen ("00008130-<ECID>").
    var configuratorECID: String? {
        if let configurator { return configurator.ecid }
        if let ecid, let normalized = Configurator.normalizedECID(ecid) {
            return Configurator.cfgutilECID(normalized)
        }
        if let udid, let hyphen = udid.firstIndex(of: "-"),
           let normalized = Configurator.normalizedECID(String(udid[udid.index(after: hyphen)...])) {
            return Configurator.cfgutilECID(normalized)
        }
        return nil
    }

    /// Stable identity for a physical device, used to clear its own stale
    /// disconnected rows when it reconnects. Nil for opaque DFU devices, which
    /// expose no identifiers at all.
    var identityKey: String? { serialNumber ?? displayUDID ?? ecid }

    /// True for newer devices whose DFU mode enumerates as a locked-down
    /// "Debug USB" function that exposes no identifiers at all.
    var isOpaqueDFU: Bool { mode == .dfu && descriptor == nil }

    /// Human-readable model string for list rows.
    var modelDisplayName: String {
        if let modelInfo { return modelInfo.displayName }
        if let descriptor, descriptor.cpid != nil || descriptor.bdid != nil {
            return "Unknown (CPID \(descriptor.cpid ?? "?") / BDID \(descriptor.bdid ?? "?"))"
        }
        // "Debug USB" would be confusing as a model name.
        if isOpaqueDFU { return "Apple Device" }
        return usbProductName ?? "Apple Device"
    }

    /// What this row shows in the serial column when no Jamf data is available yet.
    var serialStatusText: String {
        switch mode {
        case .recovery:
            return serialNumber ?? "No SRNM field in descriptor — serial not reported"
        case .dfu:
            return "Serial can't be read in DFU mode"
        case .normal:
            return "Serial pending Jamf lookup"
        }
    }

    /// The Jamf Pro lookup this device supports, if any.
    var jamfQuery: JamfQuery? {
        switch mode {
        case .recovery:
            if let serialNumber { return .serialNumber(serialNumber) }
            return nil
        case .dfu:
            // Only once Configurator has identified it: the UDID makes a DFU
            // device findable in Jamf, which in turn reveals its serial.
            if let udid = displayUDID { return .udid(udid) }
            return nil
        case .normal:
            if let udid { return .udid(udid) }
            return nil
        }
    }
}

/// Model-specific button steps to put a device into Recovery mode (where the
/// serial number becomes readable), from DFU or from a booted state.
nonisolated enum RecoveryModeInstructions {

    private static let homeButtoniPhones: Set<String> = [
        "iPhone10,1", "iPhone10,4",   // iPhone 8
        "iPhone10,2", "iPhone10,5",   // iPhone 8 Plus
        "iPhone12,8",                 // iPhone SE (2nd gen)
        "iPhone14,6",                 // iPhone SE (3rd gen)
    ]

    /// iPad families with a Home button (2017 iPad, iPad 6th–9th gen, Air 3, mini 5).
    private static let homeButtoniPadMajors: Set<Int> = [6, 7, 11, 12]

    static func instructions(forModelIdentifier identifier: String?) -> String {
        guard let identifier else { return genericInstructions }

        if identifier.hasPrefix("iPhone") {
            if homeButtoniPhones.contains(identifier) {
                return """
                Home-button iPhone:
                1. Press and hold the Home button and the Side (or Top) button together.
                2. Keep holding past the black screen and the Apple logo.
                3. Release when the Recovery screen (cable pointing at a computer) appears.
                """
            }
            return """
            Face ID iPhone:
            1. Press and quickly release Volume Up.
            2. Press and quickly release Volume Down.
            3. Press and hold the Side button; keep holding past the Apple logo.
            4. Release when the Recovery screen (cable pointing at a computer) appears.
            """
        }

        if identifier.hasPrefix("iPad") {
            let major = Int(identifier.dropFirst("iPad".count).prefix(while: \.isNumber)) ?? 0
            if homeButtoniPadMajors.contains(major) {
                return """
                Home-button iPad:
                1. Press and hold the Home button and the Top button together.
                2. Keep holding past the Apple logo.
                3. Release when the Recovery screen appears.
                """
            }
            return """
            iPad with Face ID or a Touch ID top button:
            1. Press and quickly release the Volume button nearest the Top button.
            2. Press and quickly release the Volume button farthest from the Top button.
            3. Press and hold the Top button; keep holding past the Apple logo.
            4. Release when the Recovery screen appears.
            """
        }

        if identifier.hasPrefix("Mac") {
            return """
            Apple Silicon Mac:
            1. Press and hold the power button for about 10 seconds to shut it down.
            2. Press and hold the power button again until "Loading startup options" appears,
               then use macOS Recovery — or use Apple Configurator on another Mac to revive.
            """
        }

        return genericInstructions
    }

    private static let genericInstructions = """
    iPhone or iPad without a Home button:
    1. Press and quickly release Volume Up.
    2. Press and quickly release Volume Down.
    3. Press and hold the Side button (iPhone) or Top button (iPad); keep holding past the Apple logo.
    4. Release when the Recovery screen appears.

    iPhone or iPad with a Home button: press and hold the Home button and the Side/Top button \
    together until the Recovery screen appears.
    """
}
