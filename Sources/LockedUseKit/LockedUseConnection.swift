import Darwin
import Foundation
import os

/// One authenticated Broker connection per app-agent client. Only GUI requests
/// acquire a lease; inventory, diagnostics and protocol discovery do not unlock.
public final class LockedUseConnection: @unchecked Sendable {
    private let mutex = NSLock()
    // Admission always takes this lock before mutex; no other path takes it.
    private let admissionLock = NSLock()
    private let logger = Logger(subsystem: "com.nia-teams.locked-use", category: "AgentRecovery")
    private let clientSocket: Int32
    private var localIdentitySocket: Int32 = -1
    private var broker: LockedUseIPCClient?
    private var lease: UUID?
    private var guardian: Process?
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var stopError: LockedUseError?
    private var clientDisconnected = false
    private var activeActionCount = 0
    private var validationLease: UUID?
    private var recoveryProbeStarted = false
    private let recoveryDeadline = LockedUseRecoveryDeadline {
        // Exit our own automation agent, not the Guardian/watchdog or a user
        // application. Root still requires observed lock and unlock-work drain
        // before either shield can be released.
        fputs("Locked Use recovery deadline expired; stopping automation agent.\n", stderr)
        _exit(70)
    }

    public init(clientSocket: Int32) {
        self.clientSocket = dup(clientSocket)
        if self.clientSocket >= 0 { _ = fcntl(self.clientSocket, F_SETFD, FD_CLOEXEC) }
    }
    /// Both socket ends belong to this signed process. The retained peer keeps
    /// LOCAL_PEERTOKEN identity and disconnect detection alive until teardown.
    public convenience init() throws {
        var sockets: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(sockets[1]) }
        self.init(clientSocket: sockets[1])
        guard clientSocket >= 0 else {
            Darwin.close(sockets[0])
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        localIdentitySocket = sockets[0]
        _ = fcntl(localIdentitySocket, F_SETFD, FD_CLOEXEC)
    }

    /// The action validator is process-scoped: GUI integrations should serialize
    /// requests and validate every GUI action inside `perform`.
    public static func withProtectedSession<T>(requireLocked: Bool = false, body: () throws -> T) throws -> T {
        let connection = try LockedUseConnection()
        defer { connection.end() }
        return try connection.perform(requireLocked: requireLocked, body)
    }

    deinit {
        if clientSocket >= 0 { Darwin.close(clientSocket) }
        if localIdentitySocket >= 0 { Darwin.close(localIdentitySocket) }
    }

    // Internal diagnostic snapshot; mutation remains confined to begin/finish.
    var activeActions: Int {
        mutex.lock(); defer { mutex.unlock() }
        return activeActionCount
    }

    public var hasActiveLease: Bool {
        mutex.lock(); defer { mutex.unlock() }
        return lease != nil && !stopped && !clientDisconnected
    }

    public var isFinished: Bool {
        mutex.lock(); defer { mutex.unlock() }
        return lease == nil
    }

    public func beginAction(requireLocked: Bool = false) throws -> Bool {
        admissionLock.lock()
        defer { admissionLock.unlock() }
        let session = LockedUseSession.current()
        guard session.state != .unavailable else {
            throw LockedUseError.stateUnavailable("No completed console session is available")
        }
        mutex.lock(); let existing = lease != nil; mutex.unlock()
        if existing {
            // The protected lease itself unlocked the console. Revalidate and
            // refresh Broker activity before admitting even --require-locked.
            try validateAction()
            mutex.lock(); defer { mutex.unlock() }
            guard !stopped && !clientDisconnected else {
                throw stopError ?? LockedUseError.stopped(reason: nil, awaitingManualUnlock: true)
            }
            activeActionCount += 1
            return true
        } else {
            guard !requireLocked || session.state == .locked else {
                throw LockedUseError.stateUnavailable("--require-locked requires a locked console session")
            }
            mutex.lock(); let needsRecovery = stopped && lease == nil; mutex.unlock()
            if session.state == .unlocked, needsRecovery || FileManager.default.fileExists(atPath: LockedUseIPCEndpoint.observer.path) {
                guard try observeManualUnlock() else {
                    throw LockedUseError.stateUnavailable("Locked Use lease is held by another session or still releasing.")
                }
            }
            if session.state == .locked {
                try acquire(session: session)
                try validateAction()
            }
        }
        mutex.lock(); defer { mutex.unlock() }
        guard !stopped && !clientDisconnected else {
            throw stopError ?? LockedUseError.stopped(reason: nil, awaitingManualUnlock: true)
        }
        // The stop/disconnect check above and the increment share mutex, so
        // end() cannot observe an empty drain between admission and counting.
        if lease != nil {
            activeActionCount += 1
            return true
        }
        return false
    }

    public func finishAction() {
        mutex.lock()
        activeActionCount = max(0, activeActionCount - 1)
        let drain = activeActionCount == 0 && stopped
        mutex.unlock()
        if drain { acknowledgeDrain() }
    }

    public func perform<T>(requireLocked: Bool = false, _ body: () throws -> T) throws -> T {
        let scoped = try beginAction(requireLocked: requireLocked)
        defer { if scoped { finishAction() } }
        if scoped {
            return try LockedUseActionScope.withValidator({ [self] in try validateAction() }, body: body)
        } else {
            return try body()
        }
    }

    private func acquire(session: LockedUseSession, recoveryProbe: Bool = false) throws {
        mutex.lock(); let existing = lease; let denied = stopped || clientDisconnected; mutex.unlock()
        if existing != nil || denied { try validateAction(); return }
        let connection = try LockedUseIPCClient(endpoint: .agent,
            brokerRequirement: LockedUseSigningIdentity.brokerRequirement(), clientSocket: clientSocket)
        let reply = try connection.request(.init(operation: recoveryProbe ? .beginRecoveryProbe : .begin, session: session))
        let now = ProcessInfo.processInfo.systemUptime
        let startupDeadline = reply.startupDeadline ?? now + LockedUseStateMachine.unlockTimeout
        guard reply.result != .denied, reply.phase == .preparing,
              startupDeadline.isFinite, startupDeadline > now,
              startupDeadline <= now + LockedUseStateMachine.validationUnlockTimeout,
              let lease = reply.leaseID, let token = reply.token else {
            connection.close()
            if reply.phase == .awaitingManualUnlock {
                throw LockedUseError.stopped(reason: reply.stopReason, awaitingManualUnlock: true)
            }
            throw LockedUseError.stateUnavailable("Locked Use is unavailable. Enable and validate it using locked-use enable.")
        }
        mutex.lock(); broker = connection; self.lease = lease; stopError = nil; let disconnected = clientDisconnected; mutex.unlock()
        if recoveryProbe { mutex.lock(); recoveryProbeStarted = true; mutex.unlock() }
        // Follow the authenticated root's bounded deadline, plus its existing
        // two-second RPC budget for stop/drain. The client cannot extend it.
        recoveryDeadline.arm(after: startupDeadline - now + 2)
        do {
            guard !disconnected else { throw LockedUseError.stateUnavailable("Computer Use client disconnected during lease acquisition.") }
            let child = Process()
            // The installer fixes this location; caller arguments cannot select
            // another guardian or executable while holding a capability.
            child.executableURL = URL(fileURLWithPath: "/Library/Application Support/LockedUse/LockedUseGuardian")
            child.arguments = ["--broker-guardian"]
            let input = Pipe()
            child.standardInput = input
            let directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/LockedUse", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let logURL = directory.appendingPathComponent(UUID().uuidString + ".jsonl")
            let logFD = open(logURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard logFD >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            let log = FileHandle(fileDescriptor: logFD, closeOnDealloc: true)
            defer { try? log.close() }
            child.standardOutput = log
            child.standardError = FileHandle.nullDevice
            try child.run()
            guardian = child
            try input.fileHandleForWriting.write(contentsOf: LockedUseIPCFrame.encode(LockedUseGuardianBootstrap(leaseID: lease, token: token, startupDeadline: startupDeadline)))
            try input.fileHandleForWriting.close()
            startPolling()
            let deadline = startupDeadline
            while ProcessInfo.processInfo.systemUptime < deadline {
                let status = try connection.request(.init(operation: .status, leaseID: lease, session: .current()))
                receive(status)
                if status.result == .active { recoveryDeadline.cancel(); return }
                if status.result == .denied || status.phase == .relocking || status.phase == .awaitingManualUnlock || !child.isRunning { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            throw LockedUseError.stateUnavailable("Locked Use could not observe a protected GUI session becoming unlocked.")
        } catch {
            mutex.lock(); let failure = stopError; mutex.unlock()
            end()
            if let failure { throw failure }
            throw error
        }
    }

    public func validateAction() throws {
        mutex.lock(); let connection = broker; let lease = lease; let denied = stopped || clientDisconnected; let failure = stopError; mutex.unlock()
        guard !denied, let connection, let lease else {
            throw failure ?? LockedUseError.stopped(reason: .disconnected, awaitingManualUnlock: false)
        }
        let reply: LockedUseIPCReply
        do { reply = try connection.request(.init(operation: .action, leaseID: lease, session: .current())) }
        catch {
            // Polling may have consumed the terminal reply and closed the socket
            // between our snapshot and request. That must not turn takeover into
            // a generic transport/unavailable error.
            mutex.lock(); let failure = stopError; mutex.unlock()
            throw failure ?? LockedUseError.stateUnavailable("Locked Use Broker validation is unavailable: \(error.localizedDescription)")
        }
        receive(reply)
        guard reply.result == .active else {
            mutex.lock(); let failure = stopError; mutex.unlock()
            throw failure ?? LockedUseError.stopped(reason: reply.stopReason, awaitingManualUnlock: reply.phase == .awaitingManualUnlock)
        }
    }

    /// Exercise real dual-guard cleanup without allowing a single unlock. The
    /// installed validation Broker rejects this mode in a production profile.
    public func validateRecovery() throws -> Bool {
        let session = LockedUseSession.current()
        guard session.state == .locked else { throw LockedUseError.stateUnavailable("Recovery probe requires a locked session") }
        mutex.lock(); recoveryProbeStarted = false; mutex.unlock()
        do { try acquire(session: session, recoveryProbe: true) }
        catch { logger.notice("recoveryProbeAcquireEnded") }
        mutex.lock(); let started = recoveryProbeStarted; mutex.unlock()
        guard started else { throw LockedUseError.stateUnavailable("Recovery probe was not admitted") }
        let observer = try LockedUseIPCClient(endpoint: .observer, brokerRequirement: LockedUseSigningIdentity.brokerRequirement())
        defer { observer.close() }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < deadline {
            let reply = try observer.request(.init(operation: .status, session: .current()))
            if reply.phase == .awaitingManualUnlock, reply.guardsReleased == true,
               reply.recoveryProbePrepared == true,
               LockedUseSession.current() == session { return true }
            if reply.phase == .awaitingManualUnlock, reply.guardsReleased == true {
                throw LockedUseError.stateUnavailable("Recovery probe stopped before both guards became ready")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw LockedUseError.stateUnavailable("Recovery probe did not observe both guards released")
    }

    /// A fresh CLI connection still has to report an actual normal unlock.
    /// Wall-clock waiting or merely creating a new client cannot reset the
    /// Broker's failed locked episode.
    public func observeManualUnlock() throws -> Bool {
        let session = LockedUseSession.current()
        guard session.state == .unlocked else { return false }
        let observer = try LockedUseIPCClient(endpoint: .observer, brokerRequirement: LockedUseSigningIdentity.brokerRequirement())
        defer { observer.close() }
        let reply = try observer.request(.init(operation: .status, session: session))
        if reply.phase == .idle {
            mutex.lock(); if lease == nil { stopped = false }; mutex.unlock()
        }
        return reply.phase == .idle && reply.guardsReleased == true
    }

    public func protectionReleased() throws -> Bool {
        let observer = try LockedUseIPCClient(endpoint: .observer, brokerRequirement: LockedUseSigningIdentity.brokerRequirement())
        defer { observer.close() }
        let reply = try observer.request(.init(operation: .status, session: .current()))
        return reply.guardsReleased == true && (reply.phase == .idle || reply.phase == .awaitingManualUnlock)
    }

    public func recordValidation(manual: Bool = false) throws {
        mutex.lock(); let lease = manual ? validationLease : lease; mutex.unlock()
        guard let lease else { throw LockedUseError.stateUnavailable("No native validation lease.") }
        if manual {
            let connection = try LockedUseIPCClient(endpoint: .agent, brokerRequirement: LockedUseSigningIdentity.brokerRequirement(), clientSocket: clientSocket)
            defer { connection.close() }
            let reply = try connection.request(.init(operation: .validationManual, leaseID: lease, session: .current()))
            guard reply.result != .denied else { throw LockedUseError.stateUnavailable("Validation manual-unlock confirmation denied.") }
        } else {
            try validateAction()
            mutex.lock(); let connection = broker; mutex.unlock()
            let reply = try connection?.request(.init(operation: .validationPassed, leaseID: lease))
            guard reply?.result != .denied, reply != nil else { throw LockedUseError.stateUnavailable("Validation evidence denied.") }
            mutex.lock(); validationLease = lease; mutex.unlock()
        }
    }

    public func end(disconnecting: Bool = false) {
        mutex.lock()
        stopped = lease != nil
        clientDisconnected = clientDisconnected || disconnecting
        let connection = broker; let lease = lease; let drain = activeActionCount == 0
        mutex.unlock()
        if lease != nil { recoveryDeadline.arm(after: 5) }
        if let connection, let lease {
            if let reply = try? connection.request(.init(operation: .end, leaseID: lease, stopReason: disconnecting ? .disconnected : .turnEnded)) { receive(reply) }
            if drain { acknowledgeDrain() }
        }
    }

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.nia-teams.locked-use.connection"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(200))
        timer.setEventHandler { [self] in
            mutex.lock(); let connection = broker; let lease = lease; mutex.unlock()
            guard let lease else { return }
            do {
                let active: LockedUseIPCClient
                if let connection { active = connection }
                else {
                    let candidate = try LockedUseIPCClient(endpoint: .agent, brokerRequirement: LockedUseSigningIdentity.brokerRequirement(), clientSocket: clientSocket)
                    let hello = try candidate.request(.init(operation: .ownerRecoveryHello, leaseID: lease, session: .current()))
                    guard hello.result != .denied else { candidate.close(); throw LockedUseError.stateUnavailable("Broker recovery denied") }
                    mutex.lock(); broker = candidate; mutex.unlock()
                    active = candidate
                }
                let reply = try active.request(.init(operation: .status, leaseID: lease, session: .current()))
                receive(reply)
                mutex.lock(); let drain = stopped && activeActionCount == 0; mutex.unlock()
                if drain { acknowledgeDrain() }
            } catch {
                logger.error("brokerPollingFailed recoveryDeadlineArmed=true")
                recoveryDeadline.arm(after: 5)
                mutex.lock(); stopped = true; let failed = broker; broker = nil; mutex.unlock()
                failed?.close()
                // Guardian independently observes Broker failure and relocks.
                // Do not kill it, its watchdog, or its shields on IPC failure.
            }
        }
        self.timer = timer; timer.resume()
    }

    private func receive(_ reply: LockedUseIPCReply) {
        mutex.lock(); defer { mutex.unlock() }
        if reply.stopReason != nil || reply.phase == .awaitingManualUnlock || reply.phase == .relocking || reply.effects.contains("stopActions") {
            stopError = .stopped(reason: reply.stopReason, awaitingManualUnlock: reply.phase == .awaitingManualUnlock)
        }
        if reply.effects.contains("stopActions") || reply.phase == .relocking {
            stopped = true
            recoveryDeadline.arm(after: 5)
        }
        if reply.phase == .idle || reply.phase == .awaitingManualUnlock {
            recoveryDeadline.cancel()
            timer?.cancel(); timer = nil
            // This acknowledgment follows Guardian's lock observation and drain.
            lease = nil
            if reply.phase == .idle { stopped = false }
            broker?.close(); broker = nil
        }
    }

    private func acknowledgeDrain() {
        mutex.lock(); let connection = broker; let lease = lease; mutex.unlock()
        guard let connection, let lease else {
            logger.notice("actionDrainDeferred brokerAvailable=\(connection != nil, privacy: .public) leaseAvailable=\(lease != nil, privacy: .public)")
            return
        }
        logger.notice("actionDrainSubmitting")
        do {
            let reply = try connection.request(.init(operation: .quiesced, leaseID: lease))
            logger.notice("actionDrainReply phase=\(reply.phase.rawValue, privacy: .public) denied=\(reply.result == .denied, privacy: .public)")
            receive(reply)
        } catch {
            logger.error("actionDrainRPCFailed recoveryDeadlinePending=true")
        }
    }
}
