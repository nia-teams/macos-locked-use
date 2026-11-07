import AppKit
import CryptoKit
import Foundation
import Security
import os

/// Signed fixed fixture; trusted host callbacks supply real AX/capture evidence.
/// Never expose these callbacks or caller-supplied images as untrusted RPC inputs.
public enum LockedUseNativeValidation {
    public struct Capture {
        public let text: String
        public let image: Data
        public init(text: String, image: Data) { self.text = text; self.image = image }
    }
    public static func run(probe: LockedUseKeychainProbe, capture: () throws -> Capture, increment: () throws -> Void) throws {
        let logger = Logger(subsystem: "com.nia-teams.locked-use", category: "NativeValidation")
        logger.notice("fixtureValidationStarted")
        let identifier = "com.nia-teams.locked-use.fixture.dev"
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        guard apps.count == 1, let path = apps.first?.bundleURL,
              let team = try LockedUseSigningIdentity.current().teamIdentifier else {
            throw LockedUseError.stateUnavailable("Launch the signed LockedUseDemo first.")
        }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let expression = "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        guard SecStaticCodeCreateWithPath(path as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw LockedUseError.stateUnavailable("Native validation fixture signer is not approved.")
        }
        let before = try capture()
        let counter = try counterValue(before.text)
        try increment()
        let after = try capture()
        guard try counterValue(after.text) == counter + 1,
              !before.image.isEmpty, !after.image.isEmpty,
              SHA256.hash(data: before.image) != SHA256.hash(data: after.image) else {
            throw LockedUseKeychainProbe.Failure.verification
        }
        try probe.verify()
        logger.notice("isolatedKeychainVerified dataProtectionIncluded=\(probe.includesDataProtection, privacy: .public)")
    }

    private static func counterValue(_ text: String) throws -> Int {
        let regex = try NSRegularExpression(pattern: #"Counter: ([0-9]+)"#)
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard matches.count == 1, let range = Range(matches[0].range(at: 1), in: text),
              let value = Int(text[range]), value < Int.max else { throw LockedUseKeychainProbe.Failure.verification }
        return value
    }
}
