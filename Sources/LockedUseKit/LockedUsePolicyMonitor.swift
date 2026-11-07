import Dispatch
import Foundation

/// AuthorizationRightGet talks to authd. Never run it on the queue that must
/// answer a mechanism currently waiting for this Broker or drain a GUI lease.
/// A slow check makes permits unavailable, without blocking recovery messages.
public final class LockedUsePolicyMonitor: @unchecked Sendable {
    public enum Status: Equatable, Sendable { case pending, valid, invalid, stale }
    private let mutex = NSLock()
    private let queue = DispatchQueue(label: "com.nia-teams.locked-use.policy-observation")
    private let observe: @Sendable () throws -> Bool
    private var started: TimeInterval?
    private var checked: TimeInterval?
    private var result = false
    private var running = false
    private var invalidated = false
    public static let maximumAge: TimeInterval = 2

    public init(observe: @escaping @Sendable () throws -> Bool) { self.observe = observe }

    public func refresh(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        mutex.lock()
        guard !running else { mutex.unlock(); return }
        running = true
        if started == nil { started = now }
        mutex.unlock()
        queue.async { [self] in
            let observationStarted = ProcessInfo.processInfo.systemUptime
            let value = (try? observe()) == true
            mutex.lock()
            invalidated = invalidated || !value
            result = value; checked = observationStarted; running = false
            mutex.unlock()
        }
    }

    /// Enqueue behind any running observation, but never wait indefinitely for
    /// authd on the Broker's recovery/heartbeat queue. A late result still updates
    /// the cache, and a genuine timeout remains fail-closed.
    @discardableResult
    public func refreshAndWait(timeout: TimeInterval = 0.25) -> Status {
        refresh()
        let completed = DispatchSemaphore(value: 0)
        queue.async { completed.signal() }
        _ = completed.wait(timeout: .now() + max(0, timeout))
        return status()
    }

    public func status(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Status {
        mutex.lock(); defer { mutex.unlock() }
        if invalidated { return .invalid }
        if let checked {
            guard now.isFinite, now >= checked, now - checked < Self.maximumAge else { return .stale }
            return result ? .valid : .invalid
        }
        guard let started, now.isFinite, now >= started, now - started < Self.maximumAge else { return .stale }
        return .pending
    }
}
