import Foundation

/// Per-surface, monotonic bounds recovery. Integrity/topology failures latch
/// until teardown; only a previously verified, unlocked surface gets grace.
public struct LockedUseShieldRepair: Sendable {
    public static let timeout: TimeInterval = 1.2
    public private(set) var latchedFailure: String?
    public private(set) var mismatchStarted: TimeInterval?
    public private(set) var baselineTopology: String?
    private var verifiedCoverage = false
    private var lastNow: TimeInterval?

    public init() {}

    public mutating func observeTopology(_ topology: String) {
        if let baselineTopology {
            if topology != baselineTopology { latch("topologyChanged") }
        } else if !topology.isEmpty {
            baselineTopology = topology
        } else { latch("topologyUnavailable") }
    }

    public mutating func latch(_ failure: String) {
        if latchedFailure == nil { latchedFailure = failure }
    }

    /// Nil during active bounds-only recovery means continued protection under
    /// the bounded transition policy, NOT geometrically verified full coverage.
    /// The caller must validate every window's integrity on every tick first.
    public mutating func failure(observed: String?, unlocked: Bool, now: TimeInterval) -> String? {
        if let latchedFailure { return latchedFailure }
        guard now.isFinite, now >= 0, lastNow.map({ now >= $0 }) ?? true else {
            latch("shieldClockInvalid")
            return latchedFailure
        }
        lastNow = now
        if let observed, !observed.hasPrefix("shieldBoundsMismatch ") {
            latch(observed)
            return latchedFailure
        }
        // A delayed tick must not resurrect a surface after its deadline, even
        // if the first new observation is geometrically healthy.
        if let mismatchStarted, now - mismatchStarted >= Self.timeout {
            latch(observed ?? "shieldBoundsMismatch recoveryDeadlineExpired")
            return latchedFailure
        }
        if observed == nil {
            verifiedCoverage = true
            mismatchStarted = nil
            return nil
        }
        guard unlocked, verifiedCoverage else { return observed }
        if mismatchStarted == nil { mismatchStarted = now }
        return nil
    }

    public enum StagingFailure: Error { case noDisplays, duplicateDisplay }

    /// Construct a complete replacement off to the side. On any error dispose
    /// only staged candidates; ownership of the live collection never changes.
    public static func stage<Key: Hashable, Value>(ids: [Key], make: (Key) throws -> Value,
                                                   discard: (Value) -> Void) throws -> [Key: Value] {
        guard !ids.isEmpty else { throw StagingFailure.noDisplays }
        guard Set(ids).count == ids.count else { throw StagingFailure.duplicateDisplay }
        var staged: [Key: Value] = [:]
        do {
            for id in ids { staged[id] = try make(id) }
            return staged
        } catch {
            for value in staged.values { discard(value) }
            throw error
        }
    }
}
