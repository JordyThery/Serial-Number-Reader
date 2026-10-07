import Foundation
import os

/// A resolved hardware model.
nonisolated struct ModelInfo: Equatable, Sendable {
    /// Apple model identifier, e.g. "iPhone14,5".
    let identifier: String
    /// Marketing name, e.g. "iPhone 13". Nil when the identifier has no known name.
    let marketingName: String?

    var displayName: String { marketingName ?? identifier }
}

/// Loads the bundled `AppleDeviceModels.json` resource, which maps
/// `CPID:BDID` (uppercase hex) pairs to model identifiers and model
/// identifiers to marketing names. The file is a plain resource so it can be
/// updated without code changes.
nonisolated final class ModelDatabase: Sendable {
    static let shared = ModelDatabase()

    private let boards: [String: String]
    private let models: [String: String]

    private struct Resource: Decodable {
        let boards: [String: String]
        let models: [String: String]
    }

    init() {
        let logger = Logger(subsystem: "be.jordythery.SerialNumberReader", category: "ModelDatabase")
        guard let url = Bundle.main.url(forResource: "AppleDeviceModels", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let resource = try? JSONDecoder().decode(Resource.self, from: data)
        else {
            logger.error("AppleDeviceModels.json missing or unreadable; all models will show as Unknown")
            boards = [:]
            models = [:]
            return
        }
        boards = resource.boards
        models = resource.models
        logger.debug("Loaded \(resource.boards.count) board mappings, \(resource.models.count) model names")
    }

    /// Resolves a model from the CPID and BDID hex strings found in a
    /// Recovery/DFU descriptor. Returns nil when the pair is unknown.
    func model(cpidHex: String?, bdidHex: String?) -> ModelInfo? {
        guard let cpidHex, let bdidHex,
              let cpid = UInt32(cpidHex, radix: 16),
              let bdid = UInt32(bdidHex, radix: 16)
        else { return nil }
        let key = String(format: "%04X:%02X", cpid, bdid)
        guard let identifier = boards[key] else { return nil }
        return ModelInfo(identifier: identifier, marketingName: models[identifier])
    }

    /// Marketing name for a bare model identifier (used for Jamf data display).
    func marketingName(forIdentifier identifier: String) -> String? {
        models[identifier]
    }
}
