import Foundation

/// A synchronous repair/verification budget, NOT permission to report an
/// uncovered display as healthy. Both independent guards use this same path.
public enum LockedUseShieldRepair {
    public static let timeout: TimeInterval = 0.2
    public static let interval: TimeInterval = 0.01

    /// Only displacement gets a short WindowServer commit window. Missing,
    /// transparent, wrong-owner/layer windows and topology changes fail at once.
    /// No run-loop pumping: it could reenter health/RPC and publish stale health.
    public static func verify(check: () -> String?, repair: () -> Void,
                              now: () -> TimeInterval, wait: (TimeInterval) -> Void) -> String? {
        guard var failure = check() else { return nil }
        guard failure.hasPrefix("shieldBoundsMismatch ") else { return failure }
        let started = now()
        guard started.isFinite, started >= 0 else { return failure }
        // The attempt cap also bounds a stalled/invalid clock or no-op wait.
        for _ in 0..<20 {
            repair()
            let before = now()
            guard before.isFinite, before >= started, before - started < timeout else { return failure }
            wait(min(interval, timeout - (before - started)))
            let after = now()
            guard after.isFinite, after >= before, after - started <= timeout else { return failure }
            guard let observed = check() else { return nil }
            failure = observed
            guard failure.hasPrefix("shieldBoundsMismatch ") else { return failure }
        }
        return failure
    }
}
