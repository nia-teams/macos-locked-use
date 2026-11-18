import Foundation

/// Administrator-owned configuration. Enabled and validation evidence are
/// independent: installation/enrollment alone cannot validate session unlock.
public struct LockedUseBrokerConfiguration: Codable, Sendable {
    public static let defaultCooldownSeconds: TimeInterval = 60
    public static let maximumCooldownSeconds: TimeInterval = 86_400
    public let cooldownSeconds: TimeInterval?
    public let schemaVersion: Int
    public let enabled: Bool
    public let validatedOSBuild: String?
    public let validatedBrokerHash: String?
    public let validatedGuardianHash: String?
    public let validatedPluginHash: String?

    public init(enabled: Bool, cooldownSeconds: TimeInterval? = Self.defaultCooldownSeconds, validatedOSBuild: String? = nil,
                validatedBrokerHash: String? = nil, validatedGuardianHash: String? = nil,
                validatedPluginHash: String? = nil) {
        self.cooldownSeconds = cooldownSeconds
        schemaVersion = 1; self.enabled = enabled; self.validatedOSBuild = validatedOSBuild
        self.validatedBrokerHash = validatedBrokerHash; self.validatedGuardianHash = validatedGuardianHash
        self.validatedPluginHash = validatedPluginHash
    }

    public static func validatedCooldownSeconds(_ value: TimeInterval?) throws -> TimeInterval? {
        if let value, !value.isFinite || value <= 0 || value > maximumCooldownSeconds {
            throw LockedUseError.usage("Cooldown must be a finite number greater than 0 and at most 86400, or manual.")
        }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, enabled, cooldownSeconds, validatedOSBuild, validatedBrokerHash, validatedGuardianHash, validatedPluginHash
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        validatedOSBuild = try c.decodeIfPresent(String.self, forKey: .validatedOSBuild)
        validatedBrokerHash = try c.decodeIfPresent(String.self, forKey: .validatedBrokerHash)
        validatedGuardianHash = try c.decodeIfPresent(String.self, forKey: .validatedGuardianHash)
        validatedPluginHash = try c.decodeIfPresent(String.self, forKey: .validatedPluginHash)
        let value: TimeInterval?
        if !c.contains(.cooldownSeconds) { value = Self.defaultCooldownSeconds }
        else if try c.decodeNil(forKey: .cooldownSeconds) { value = nil }
        else { value = try c.decode(Double.self, forKey: .cooldownSeconds) }
        do { cooldownSeconds = try Self.validatedCooldownSeconds(value) }
        catch { throw DecodingError.dataCorruptedError(forKey: .cooldownSeconds, in: c, debugDescription: "Invalid cooldown duration") }
    }

    public func encode(to encoder: Encoder) throws {
        _ = try Self.validatedCooldownSeconds(cooldownSeconds)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(enabled, forKey: .enabled)
        if let cooldownSeconds { try c.encode(cooldownSeconds, forKey: .cooldownSeconds) }
        else { try c.encodeNil(forKey: .cooldownSeconds) }
        try c.encodeIfPresent(validatedOSBuild, forKey: .validatedOSBuild)
        try c.encodeIfPresent(validatedBrokerHash, forKey: .validatedBrokerHash)
        try c.encodeIfPresent(validatedGuardianHash, forKey: .validatedGuardianHash)
        try c.encodeIfPresent(validatedPluginHash, forKey: .validatedPluginHash)
    }

    public static func loadInstalled() throws -> Self {
        let data = try LockedUseSecureStore.read(components: ["Library", "Application Support", "LockedUse", "configuration.json"])
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schemaVersion == 1 else { throw LockedUseClientApprovals.Failure.invalidRecord }
        return value
    }

    public func matchesValidation(osBuild: String, brokerHash: String, guardianHash: String, pluginHash: String) -> Bool {
        enabled && !osBuild.isEmpty && !brokerHash.isEmpty && !guardianHash.isEmpty && !pluginHash.isEmpty
            && validatedOSBuild == osBuild && validatedBrokerHash == brokerHash
            && validatedGuardianHash == guardianHash && validatedPluginHash == pluginHash
    }
}
