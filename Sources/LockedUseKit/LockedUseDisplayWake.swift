import Foundation

/// Bounded polling independent of WindowServer, for deterministic tests.
public enum LockedUseDisplayWake {
    public static func ensureAwake(timeout: TimeInterval = 2,
                                   active: () -> Bool,
                                   wake: () -> Void,
                                   pump: (TimeInterval) -> Void,
                                   now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) -> Bool {
        if active() { return true }
        guard timeout.isFinite, timeout > 0 else { return false }
        wake()
        let deadline = now() + timeout
        while now() < deadline {
            if active() { return true }
            pump(min(0.025, max(0, deadline - now())))
        }
        return active()
    }
}
