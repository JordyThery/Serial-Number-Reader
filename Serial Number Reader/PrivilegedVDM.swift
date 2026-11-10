import Foundation

/// The root side of Restart and Enter DFU: the app re-launches itself as
/// root with `--vdm reboot|dfu --entry <hex>` (the selected device's registry
/// entry ID). Before anything else, `MyApp.main` hands such a launch to this;
/// the GUI never starts as root.
///
/// The helper trusts nothing it is given: it follows the device's chain to
/// its USB-C port itself (`USBCPort`), opens only that port, and checks the
/// chain once more just before sending. A wrong or stale entry ID can only be
/// refused, never sent elsewhere.
nonisolated enum PrivilegedVDM {

    struct Arguments: Equatable {
        /// `reboot` or `dfu`.
        let action: String
        /// The device's registry entry ID; nil for a device without a USB
        /// entry, which keeps the rule of one connected port.
        let deviceEntryID: UInt64?
    }

    static let actions: Set<String> = ["reboot", "dfu"]

    /// The arguments after the executable, accepted only in these exact
    /// forms: `--vdm <action>` or `--vdm <action> --entry <1–16 hex digits>`.
    static func parse(_ arguments: [String]) -> Arguments? {
        guard arguments.count == 2 || arguments.count == 4,
              arguments[0] == "--vdm", actions.contains(arguments[1])
        else { return nil }
        guard arguments.count == 4 else { return Arguments(action: arguments[1], deviceEntryID: nil) }
        let hex = arguments[3]
        guard arguments[2] == "--entry", (1...16).contains(hex.count),
              hex.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let id = UInt64(hex, radix: 16)
        else { return nil }
        return Arguments(action: arguments[1], deviceEntryID: id)
    }

    /// What the app passes to the helper for a device.
    static func commandArguments(action: String, deviceEntryID: UInt64) -> [String] {
        ["--vdm", action, "--entry", String(deviceEntryID, radix: 16)]
    }

    /// Exit code for a refusal of the port check: nothing was sent.
    static let refusedExitCode: Int32 = 5

    /// Runs as root. Returns the process's exit code; the message goes to
    /// standard error, which the app shows.
    static func run(_ arguments: Arguments, registry: some USBCPortRegistry = LiveUSBCPortRegistry(),
                    isAppleSilicon: Bool = USBCPort.isAppleSilicon, underTest: USBGuard = .shared,
                    send: (String, UInt64, @escaping () -> Bool) -> Int32 = { action, controller, recheck in
                        VDMTool.run(withAction: action, onControllerWithEntryID: controller, recheck: recheck)
                    },
                    sendWithoutDevice: (String) -> Int32 = { VDMTool.run(withAction: $0) },
                    error: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }) -> Int32 {
        // Never under tests (a third safeguard: the prompt that starts this is refused too).
        if underTest.refusal(for: "--vdm \(arguments.action)") != nil { return 2 }
        guard isAppleSilicon else {
            error(USBCPort.Refusal.intelMac.message)
            return refusedExitCode
        }
        guard let deviceEntryID = arguments.deviceEntryID else { return sendWithoutDevice(arguments.action) }
        switch USBCPort.locate(deviceEntryID: deviceEntryID, in: registry, isAppleSilicon: isAppleSilicon) {
        case .failure(let refusal):
            error(refusal.message)
            return refusedExitCode
        case .success(let target):
            return send(arguments.action, target.controllerID) {
                USBCPort.locate(deviceEntryID: deviceEntryID, in: registry, isAppleSilicon: isAppleSilicon) == .success(target)
            }
        }
    }
}
