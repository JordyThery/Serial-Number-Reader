import AppKit
import Foundation
import os

/// A device as Apple Configurator's `cfgutil` reports it. Unlike the USB
/// descriptor, this identifies devices in every mode, including DFU.
nonisolated struct ConfiguratorDevice: Equatable, Sendable {
    /// As cfgutil writes it, e.g. "0x1A2B3C4D5E6F70"; accepted back by `-e`.
    let ecid: String
    let udid: String?
    /// Model identifier, e.g. "iPad16,1".
    let deviceType: String?
    /// USB location ID; matches the IORegistry's for the same device.
    let locationID: UInt32?
}

/// One line of cfgutil's `--progress --format JSON` output.
nonisolated enum ConfiguratorEvent: Equatable, Sendable {
    case step(String)
    case stepComplete(String)
    /// Fraction 0…1, or nil while the step has no measurable progress.
    case progress(step: String?, fraction: Double?)
    case error(String)
    case finished
}

/// Runs Apple Configurator's command-line tool. Configurator holds the Apple
/// entitlement and restore engine needed for DFU devices; nothing here talks
/// to the device directly.
nonisolated enum Configurator {

    enum Operation: Equatable, Sendable {
        /// Erase and install the latest signed OS, or the given IPSW.
        case restore(ipsw: URL?)
        /// Reinstall the OS, keeping the device's content.
        case revive
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let bundleIdentifier = "com.apple.configurator.ui"
    private static let logger = Logger(subsystem: "be.jordythery.SerialNumberReader", category: "Configurator")

    // MARK: - Locating cfgutil

    /// The cfgutil inside Apple Configurator, wherever it's installed.
    static var cfgutilURL: URL? {
        var candidates: [URL] = []
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            candidates.append(app.appending(path: "Contents/MacOS/cfgutil"))
        }
        candidates.append(URL(fileURLWithPath: "/Applications/Apple Configurator.app/Contents/MacOS/cfgutil"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var isAvailable: Bool { cfgutilURL != nil }

    // MARK: - Commands

    /// Lists connected devices. Blocking — call off the main thread.
    static func listDevices() throws -> [ConfiguratorDevice] {
        let result = try runToCompletion(["--format", "JSON", "list"])
        return try parseList(result.output)
    }

    /// Removes the pairing between this Mac and the device. Blocking.
    static func unpair(ecid: String) throws {
        let result = try runToCompletion(["--format", "JSON", "-e", ecid, "unpair"])
        if let message = errorMessage(in: result.output) ?? (result.status == 0 ? nil : result.errorText) {
            throw Failure(message: message)
        }
    }

    /// Runs a restore or revive for one device and streams its progress. The
    /// stream finishes after `.finished`, or throws with cfgutil's message.
    /// There is deliberately no cancellation: stopping halfway leaves the
    /// device in Recovery mode.
    static func run(_ operation: Operation, ecid: String) -> AsyncThrowingStream<ConfiguratorEvent, Error> {
        var arguments = ["--progress", "--format", "JSON", "-e", ecid]
        // Named in the system log instead of the last argument, which for a
        // restore from a file is its path.
        let command: String
        switch operation {
        case .restore(let ipsw):
            command = "restore"
            arguments.append("restore")
            if let ipsw { arguments += ["--ipsw", ipsw.path] }
        case .revive:
            command = "revive"
            arguments.append("revive")
        }

        return AsyncThrowingStream { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    // Second safeguard behind LiveUSBHardware: cfgutil never starts under tests.
                    try USBGuard.shared.check("cfgutil \(command)")
                    guard let cfgutil = cfgutilURL else { throw Failure(message: notInstalled) }
                    let process = Process()
                    process.executableURL = cfgutil
                    process.arguments = arguments
                    let output = Pipe(), errors = Pipe()
                    process.standardOutput = output
                    process.standardError = errors
                    try process.run()
                    // Drain stderr concurrently: if its pipe filled up while
                    // only stdout was being read, cfgutil would block forever.
                    let errorOutput = ProcessOutput.drainInBackground(errors)

                    var lastError: String?
                    for try await line in output.fileHandleForReading.bytes.lines {
                        guard let event = parseEvent(line) else { continue }
                        if case .error(let message) = event { lastError = message }
                        if event != .finished { continuation.yield(event) }
                    }
                    process.waitUntilExit()
                    let stderr = String(decoding: errorOutput(), as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    if process.terminationStatus == 0, lastError == nil {
                        continuation.yield(.finished)
                        continuation.finish()
                    } else {
                        let message = lastError ?? (stderr.isEmpty ? "cfgutil exited with status \(process.terminationStatus)." : stderr)
                        // cfgutil's message can hold the ECID or the device's name: private.
                        logger.error("cfgutil \(command, privacy: .public) failed: \(message, privacy: .private)")
                        continuation.finish(throwing: Failure(message: message))
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Parsing

    /// Parses `cfgutil --format JSON list`.
    static func parseList(_ data: Data) throws -> [ConfiguratorDevice] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "Unexpected cfgutil output.")
        }
        guard let output = root["Output"] as? [String: Any] else { return [] }
        return output.compactMap { key, value in
            guard let entry = value as? [String: Any] else { return nil }
            let location = (entry["locationID"] as? NSNumber).map { UInt32(truncatingIfNeeded: $0.int64Value) }
            return ConfiguratorDevice(
                ecid: (entry["ECID"] as? String) ?? key,
                udid: entry["UDID"] as? String,
                deviceType: entry["deviceType"] as? String,
                locationID: location
            )
        }
        .sorted { $0.ecid < $1.ecid }
    }

    /// Parses one line of `--progress --format JSON` output; nil for lines
    /// that carry nothing to show.
    static func parseEvent(_ line: String) -> ConfiguratorEvent? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["Type"] as? String
        else { return nil }
        let step = object["Step"] as? String
        switch type {
        case "Step":
            return step.map(ConfiguratorEvent.step)
        case "StepComplete":
            return step.map(ConfiguratorEvent.stepComplete)
        case "Progress":
            let value = (object["Progress"] as? NSNumber)?.doubleValue ?? -1
            return .progress(step: step, fraction: value < 0 ? nil : min(value, 1))
        case "CommandOutput":
            return errorMessage(in: data).map(ConfiguratorEvent.error) ?? .finished
        case "Error":
            return .error(message(from: object) ?? "Apple Configurator reported an error.")
        default:
            return nil
        }
    }

    /// An error carried in a cfgutil JSON document, if any: a top-level error
    /// object, or an error dictionary (Message plus Code/Domain) anywhere
    /// inside "Output" — cfgutil nests them per device and per property.
    static func errorMessage(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if (object["Type"] as? String) == "Error" { return message(from: object) ?? "Apple Configurator reported an error." }
        return object["Output"].flatMap(nestedError)
    }

    private static func nestedError(_ value: Any) -> String? {
        guard let dictionary = value as? [String: Any] else { return nil }
        if dictionary["Code"] != nil || dictionary["Domain"] != nil, let text = message(from: dictionary) {
            return text
        }
        for child in dictionary.values {
            if let text = nestedError(child) { return text }
        }
        return nil
    }

    private static func message(from object: [String: Any]) -> String? {
        for key in ["Message", "LocalizedDescription", "Description", "FailureReason"] {
            if let text = object[key] as? String, !text.isEmpty { return text }
        }
        return nil
    }

    /// ECIDs appear as "0x1A2B3C4D5E6F70" (cfgutil) and "001A2B3C4D5E6F70"
    /// (USB descriptor). Normalizes to 16 uppercase hex digits for comparing.
    static func normalizedECID(_ value: String) -> String? {
        var hex = value.trimmingCharacters(in: .whitespaces).uppercased()
        if hex.hasPrefix("0X") { hex.removeFirst(2) }
        guard !hex.isEmpty, hex.count <= 16, hex.allSatisfy(\.isHexDigit) else { return nil }
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    /// The ECID as cfgutil's `-e` option takes it.
    static func cfgutilECID(_ normalized: String) -> String {
        let trimmed = normalized.drop { $0 == "0" }
        return "0x" + (trimmed.isEmpty ? "0" : trimmed)
    }

    // MARK: - Process

    private static func runToCompletion(_ arguments: [String]) throws -> ProcessOutput {
        // Second safeguard behind LiveUSBHardware: cfgutil never starts under tests.
        try USBGuard.shared.check("cfgutil \(arguments.last ?? "")")
        guard let cfgutil = cfgutilURL else { throw Failure(message: notInstalled) }
        return try ProcessOutput.run(cfgutil, arguments)
    }

    /// Why Restore, Revive and Remove Trust can't run without it.
    static let notInstalled = "Apple Configurator isn’t installed."
    /// The same, for a disabled button's tooltip.
    static let notInstalledHelp = "Apple Configurator isn’t installed (free on the App Store)."
}
