import Darwin
import Dispatch
import Foundation
import LockedUseNative

// Internal wire types are intentionally testable without a signed installation.
enum LockedUseHolderRequest: Codable, Equatable {
    case beginExec(execID: UUID, requireLocked: Bool)
    case validateExec(execID: UUID)
    case finishExec(execID: UUID)
    case status
    case endSession

    var timeout: TimeInterval {
        switch self {
        case .beginExec: return 12
        case .endSession: return 7
        default: return 3
        }
    }
}

struct LockedUseHolderReply: Codable, Equatable {
    let ok: Bool
    var activeLease: Bool? = nil
    var protected: Bool? = nil
    var error: String? = nil
    var stopReason: LockedUseStateMachine.StopReason? = nil
    var awaitingManualUnlock: Bool? = nil
    var exitCode: Int32? = nil
}

/// The worker uses monotonic time; tests can exercise timeout/success without
/// a signed Broker or real sleeps. Unknown release state always fails closed.
enum LockedUseHolderReleaseWait {
    static let timeoutMessage = "Timed out waiting for Locked Use protection release"

    static func wait(timeout: TimeInterval = 5, released: () -> Bool,
                     now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                     sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) -> Bool {
        let deadline = now() + timeout
        repeat {
            if released() { return true }
            let remaining = deadline - now()
            if remaining <= 0 { return false }
            sleep(min(0.05, remaining))
        } while true
    }

    static func reply(released: Bool) -> LockedUseHolderReply {
        released ? .init(ok: true, activeLease: false)
            : .init(ok: false, activeLease: false, error: timeoutMessage)
    }
}

private enum HolderRuntime {
    static func failure() -> POSIXError { POSIXError(.init(rawValue: errno) ?? .EIO) }

    static func directory() throws -> String {
        let size = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard size > 0 else { throw failure() }
        var buffer = [CChar](repeating: 0, count: size)
        let actual = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        guard actual > 0, actual <= size else { throw failure() }
        let path = URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
            .appendingPathComponent("com.nia-teams.locked-use.holder", isDirectory: true).path
        if mkdir(path, 0o700) != 0, errno != EEXIST { throw failure() }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure() }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(),
              (info.st_mode & S_IFMT) == S_IFDIR, (info.st_mode & 0o077) == 0,
              ocu_has_mutating_acl(fd) == 0 else {
            throw LockedUseError.message("Unsafe Locked Use holder runtime directory")
        }
        _ = try LockedUseIPCSocket.address(path: path + "/h.sock")
        return path
    }

    static func lockFile(_ path: String) throws -> Int32 {
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(),
              (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
              (info.st_mode & 0o077) == 0, ocu_has_mutating_acl(fd) == 0,
              fchmod(fd, 0o600) == 0 else {
            Darwin.close(fd)
            throw LockedUseError.message("Unsafe Locked Use holder lock file")
        }
        return fd
    }

    static func verify(_ fd: Int32, me: LockedUsePeerIdentity) throws {
        guard LockedUseHost.isValidIdentifier(me.signingIdentifier), let team = me.teamIdentifier,
              team.utf8.count == 10,
              team.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else {
            throw LockedUseClientApprovals.Failure.unapproved
        }
        let requirement = "identifier \"\(me.signingIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        let peer = try LockedUsePeerIdentity.verified(socket: fd, requirement: requirement)
        guard peer.userID == me.userID, peer.auditSessionID == me.auditSessionID,
              peer.hardenedRuntime, !peer.permitsCodeInjection else {
            throw LockedUseClientApprovals.Failure.unapproved
        }
    }
}

public enum LockedUseSessionHolder {
    public static func runServer() throws {
        _ = setsid()
        signal(SIGHUP, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)
        let directory = try HolderRuntime.directory()
        let lockFD = try HolderRuntime.lockFile(directory + "/holder.lock")
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(lockFD)
            if code == EWOULDBLOCK { return }
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        defer { Darwin.close(lockFD) }
        let server = try HolderServer(directory: directory, lockFD: lockFD)
        server.start()
        withExtendedLifetime(server) { dispatchMain() }
    }

    public static func beginExecIfNeeded(execID: UUID, requireLocked: Bool = false) throws -> (client: LockedUseSessionHolderClient.ClientConnection, protected: Bool)? {
        try LockedUseSessionHolderClient.ensureRunningAndBeginExec(execID: execID, requireLocked: requireLocked)
    }

    public static func endIfActive() throws -> Bool {
        try LockedUseSessionHolderClient.endIfActive()
    }

    /// Inventory never spawns a holder or requires a signed test host.
    public static func statusIfActive() -> Bool {
        (try? LockedUseSessionHolderClient.queryStatus()) == true
    }
}

// All mutable server and client ownership state lives on this one queue.
private final class HolderServer: @unchecked Sendable {
    private final class Client {
        let source: DispatchSourceRead
        var decoder = LockedUseIPCFrame()
        var execs: Set<UUID> = []
        init(source: DispatchSourceRead) { self.source = source }
    }
    private let queue = DispatchQueue(label: "com.nia-teams.locked-use.holder")
    private let releaseQueue = DispatchQueue(label: "com.nia-teams.locked-use.holder.release")
    private let me: LockedUsePeerIdentity
    private let socketPath: String
    private let lockFD: Int32
    private let listener: Int32
    private var acceptSource: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var clients: [Int32: Client] = [:]
    private var connection: LockedUseConnection?
    private var everAcquired = false
    private var shuttingDown = false
    private var shutdownStartedAt: TimeInterval?
    private var activeExecs: Set<UUID> = []
    private var endWaiters: Set<Int32> = []
    private var endWaitInProgress = false
    private var releaseProbeInProgress = false
    private let startedAt = ProcessInfo.processInfo.systemUptime

    init(directory: String, lockFD: Int32) throws {
        self.lockFD = lockFD
        socketPath = directory + "/h.sock"
        me = try LockedUseSigningIdentity.current()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HolderRuntime.failure() }
        do {
            try LockedUseIPCSocket.configure(fd)
            guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw HolderRuntime.failure() }
            // Only the exclusive holder.lock owner may remove a stale socket.
            unlink(socketPath)
            var address = try LockedUseIPCSocket.address(path: socketPath)
            let oldMask = umask(0o177)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            let bindError = errno
            umask(oldMask)
            guard result == 0 else { throw POSIXError(.init(rawValue: bindError) ?? .EIO) }
            guard chmod(socketPath, 0o600) == 0, listen(fd, 16) == 0 else { throw HolderRuntime.failure() }
            listener = fd
        } catch { Darwin.close(fd); throw error }
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source.setEventHandler { [self] in acceptClients() }
        acceptSource = source
        source.resume()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [self] in
            // No .action RPCs here: Broker alone owns idle/max lease expiry.
            guard activeExecs.isEmpty else { return }
            // Stop retaining a wedged Broker forever, but never abandon live
            // executions. This fallback does not report clean release success.
            if let shutdownStartedAt, ProcessInfo.processInfo.systemUptime - shutdownStartedAt > 10 {
                shutdownServer()
            }
            guard !endWaitInProgress else { return }
            if !shuttingDown, !everAcquired, connection?.isFinished != false,
               ProcessInfo.processInfo.systemUptime - startedAt > 5 {
                shutdownServer()
            }
            if let conn = connection {
                if conn.isFinished { probeRelease(conn) }
            } else if everAcquired || ProcessInfo.processInfo.systemUptime - startedAt > 5 {
                shutdownServer()
            }
        }
        self.timer = timer
        timer.resume()
    }

    private func shutdownServer() -> Never {
        unlink(socketPath)
        Darwin.close(listener)
        Darwin.close(lockFD)
        exit(0)
    }

    private func acceptClients() {
        while true {
            let fd = accept(listener, nil, nil)
            if fd < 0 { return }
            do {
                try LockedUseIPCSocket.configure(fd)
                guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw HolderRuntime.failure() }
                try HolderRuntime.verify(fd, me: me)
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                let client = Client(source: source)
                clients[fd] = client
                source.setEventHandler { [self] in readClient(fd) }
                // Close only after dispatch has relinquished the descriptor.
                source.setCancelHandler { Darwin.close(fd) }
                source.resume()
            } catch { Darwin.close(fd) }
        }
    }

    private func disconnect(_ fd: Int32) {
        guard let client = clients.removeValue(forKey: fd) else { return }
        endWaiters.remove(fd)
        for id in client.execs {
            if activeExecs.remove(id) != nil { connection?.finishAction() }
        }
        client.source.cancel()
    }

    private func readClient(_ fd: Int32) {
        guard let client = clients[fd] else { return }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(fd, &bytes, bytes.count)
        if count < 0, [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { return }
        guard count > 0 else { disconnect(fd); return }
        do {
            for frame in try client.decoder.append(Data(bytes.prefix(count))) {
                let request = try JSONDecoder().decode(LockedUseHolderRequest.self, from: frame)
                // A socket has at most one outstanding synchronous request.
                guard !endWaiters.contains(fd) else { throw LockedUseIPCFrame.Failure.malformed }
                if case .endSession = request {
                    startEnding(replyTo: fd)
                    continue
                }
                let reply: LockedUseHolderReply
                do { reply = try handle(request, client: client) }
                catch {
                    let typed = error as? LockedUseError
                    if let typed, case .stopped(let reason, let manual) = typed {
                        reply = .init(ok: false, error: error.localizedDescription, stopReason: reason, awaitingManualUnlock: manual, exitCode: typed.exitCode)
                    } else {
                        reply = .init(ok: false, error: error.localizedDescription, exitCode: typed?.exitCode ?? 77)
                    }
                }
                send(reply, to: fd)
            }
        } catch { disconnect(fd) }
    }

    private func send(_ reply: LockedUseHolderReply, to fd: Int32) {
        guard clients[fd] != nil else { return }
        do {
            try LockedUseIPCSocket.writeAll(try LockedUseIPCFrame.encode(reply), descriptor: fd,
                deadline: ProcessInfo.processInfo.systemUptime + 0.5)
        }
        catch { disconnect(fd) }
    }

    /// Only the worker waits for native relock. Accept/status/finishExec and
    /// disconnect draining stay responsive on the state queue throughout.
    private func startEnding(replyTo fd: Int32) {
        shuttingDown = true
        if shutdownStartedAt == nil { shutdownStartedAt = ProcessInfo.processInfo.systemUptime }
        endWaiters.insert(fd)
        guard !endWaitInProgress else { return }
        endWaitInProgress = true
        let conn = connection
        releaseQueue.async { [self, conn] in
            conn?.end()
            let released = LockedUseHolderReleaseWait.wait(released: { [self, conn] in
                // Access ownership only on its state queue. Never synchronously
                // wait for this worker from that queue: finishExec/disconnect
                // must remain able to remove executions while we wait.
                let drained = self.queue.sync { self.activeExecs.isEmpty }
                guard drained else { return false }
                if let conn { return (try? conn.protectionReleased()) == true }
                return true
            })
            queue.async { [self] in
                endWaitInProgress = false
                let waiters = endWaiters
                endWaiters.removeAll()
                let completed = released && activeExecs.isEmpty
                for fd in waiters { send(LockedUseHolderReleaseWait.reply(released: completed), to: fd) }
                // Timeout is an error; the timer retries release verification
                // and applies the ten-second fallback only after actions drain.
                if completed { shutdownServer() }
            }
        }
    }

    private func probeRelease(_ conn: LockedUseConnection) {
        guard !releaseProbeInProgress else { return }
        releaseProbeInProgress = true
        releaseQueue.async { [self, conn] in
            let released = (try? conn.protectionReleased()) == true
            queue.async { [self] in
                releaseProbeInProgress = false
                if released, !endWaitInProgress, activeExecs.isEmpty,
                   connection === conn, conn.isFinished { shutdownServer() }
            }
        }
    }

    private func handle(_ request: LockedUseHolderRequest, client: Client) throws -> LockedUseHolderReply {
        switch request {
        case .status:
            return .init(ok: true, activeLease: !shuttingDown && connection?.hasActiveLease == true)
        case .beginExec(let id, let required):
            guard !shuttingDown else { throw LockedUseError.message("Locked Use holder is stopping") }
            guard !activeExecs.contains(id) else { throw LockedUseError.message("Duplicate execution ID") }
            if let conn = connection, !conn.isFinished {
                // Only THIS still-active protected lease may bypass the console
                // locked bit for --require-locked; never reuse an unscoped one.
                guard !required || conn.hasActiveLease else {
                    throw LockedUseError.stateUnavailable("--require-locked requires a locked console session or an active protected lease")
                }
            } else {
                guard activeExecs.isEmpty else { throw LockedUseError.message("Previous Locked Use actions are draining") }
                if let old = connection {
                    guard (try? old.protectionReleased()) == true else {
                        throw LockedUseError.message("Previous Locked Use protection is still releasing")
                    }
                    old.end()
                }
                connection = try LockedUseConnection()
            }
            let scoped = try connection!.beginAction(requireLocked: required)
            if scoped {
                activeExecs.insert(id)
                client.execs.insert(id)
                everAcquired = true
            } else {
                // Do not retain a non-leased connection for subsequent calls.
                connection = nil
                guard !required else {
                    throw LockedUseError.stateUnavailable("--require-locked requires an active protected lease")
                }
                try LockedUseActionScope.validate()
            }
            return .init(ok: true, activeLease: connection?.hasActiveLease, protected: scoped)
        case .validateExec(let id):
            guard !shuttingDown, client.execs.contains(id), activeExecs.contains(id), let connection else {
                throw LockedUseError.message("Unknown or stopped protected execution")
            }
            try connection.validateAction()
            return .init(ok: true, activeLease: connection.hasActiveLease)
        case .finishExec(let id):
            if client.execs.remove(id) != nil, activeExecs.remove(id) != nil { connection?.finishAction() }
            return .init(ok: true, activeLease: !shuttingDown && connection?.hasActiveLease == true)
        case .endSession:
            // Dispatched asynchronously by readClient, never synchronously here.
            throw LockedUseIPCFrame.Failure.malformed
        }
    }
}

public enum LockedUseSessionHolderClient {
    public final class ClientConnection: @unchecked Sendable {
        private let mutex = NSLock()
        private var fd: Int32
        private var decoder = LockedUseIPCFrame()
        fileprivate init(fd: Int32) { self.fd = fd }
        deinit { if fd >= 0 { Darwin.close(fd) } }

        public func close() {
            mutex.lock(); defer { mutex.unlock() }
            if fd >= 0 { shutdown(fd, SHUT_RDWR); Darwin.close(fd); fd = -1 }
        }

        fileprivate func request(_ message: LockedUseHolderRequest, timeout: TimeInterval? = nil) throws -> LockedUseHolderReply {
            mutex.lock(); defer { mutex.unlock() }
            guard fd >= 0 else { throw POSIXError(.ENOTCONN) }
            let reply: LockedUseHolderReply
            do {
                let deadline = ProcessInfo.processInfo.systemUptime + (timeout ?? message.timeout)
                try LockedUseIPCSocket.writeAll(try LockedUseIPCFrame.encode(message), descriptor: fd, deadline: deadline)
                var bytes = [UInt8](repeating: 0, count: 4096)
                while true {
                    try LockedUseIPCSocket.wait(descriptor: fd, events: Int16(POLLIN), deadline: deadline)
                    let count = Darwin.read(fd, &bytes, bytes.count)
                    if count < 0, [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
                    guard count > 0 else { throw POSIXError(.init(rawValue: count == 0 ? ECONNRESET : errno) ?? .EIO) }
                    let frames = try decoder.append(Data(bytes.prefix(count)))
                    guard frames.count <= 1 else { throw LockedUseIPCFrame.Failure.malformed }
                    if let frame = frames.first {
                        reply = try JSONDecoder().decode(LockedUseHolderReply.self, from: frame)
                        break
                    }
                }
            } catch {
                shutdown(fd, SHUT_RDWR); Darwin.close(fd); fd = -1
                throw error
            }
            // Application rejection is not a transport failure: do not retry it.
            guard reply.ok else {
                if reply.exitCode == 75 || reply.exitCode == 76 {
                    throw LockedUseError.stopped(reason: reply.stopReason, awaitingManualUnlock: reply.awaitingManualUnlock == true)
                }
                throw LockedUseError.stateUnavailable(reply.error ?? "Locked Use holder rejected request")
            }
            return reply
        }
        public func validateExec(execID: UUID) throws { _ = try request(.validateExec(execID: execID)) }
        public func finishExec(execID: UUID) throws { _ = try request(.finishExec(execID: execID)) }
    }

    static func connectIfRunning(timeout: TimeInterval = 2) throws -> ClientConnection? {
        let directory = try HolderRuntime.directory()
        guard FileManager.default.fileExists(atPath: directory + "/h.sock") else { return nil }
        let me = try LockedUseSigningIdentity.current()
        let fd: Int32
        do { fd = try LockedUseIPCSocket.connect(path: directory + "/h.sock", timeout: timeout) }
        catch let error as POSIXError where error.code == .ENOENT || error.code == .ECONNREFUSED { return nil }
        do {
            try HolderRuntime.verify(fd, me: me)
            return ClientConnection(fd: fd)
        } catch { Darwin.close(fd); throw error }
    }

    private static func begin(_ client: ClientConnection, execID: UUID, requireLocked: Bool) throws -> (client: ClientConnection, protected: Bool) {
        do {
            let reply = try client.request(.beginExec(execID: execID, requireLocked: requireLocked))
            return (client, reply.protected == true)
        } catch { client.close(); throw error }
    }

    private static func isUnlocked() throws -> Bool {
        let session = LockedUseSession.current()
        guard session.state != .unavailable else {
            throw LockedUseError.stateUnavailable("No completed console session is available")
        }
        return session.state == .unlocked
    }

    public static func ensureRunningAndBeginExec(execID: UUID, requireLocked: Bool) throws -> (client: ClientConnection, protected: Bool)? {
        if let client = try connectIfRunning() {
            do { return try begin(client, execID: execID, requireLocked: requireLocked) }
            catch let error as POSIXError where [.ECONNRESET, .EPIPE, .ENOTCONN].contains(error.code) {
                // Only transport EOF is retryable; never bypass Broker denial.
            }
        }
        if try isUnlocked() { return nil }
        let directory = try HolderRuntime.directory()
        let lockFD = try HolderRuntime.lockFile(directory + "/spawn.lock")
        defer { _ = flock(lockFD, LOCK_UN); Darwin.close(lockFD) }
        while flock(lockFD, LOCK_EX) != 0 {
            if errno != EINTR { throw HolderRuntime.failure() }
        }
        var client = try connectIfRunning()
        if client == nil {
            if try isUnlocked() { return nil }
            let process = Process()
            process.executableURL = LockedUseHost.currentExecutableURL
            process.arguments = ["--session-holder"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while ProcessInfo.processInfo.systemUptime < deadline {
                if let candidate = try connectIfRunning() {
                    do { _ = try candidate.request(.status); client = candidate; break }
                    catch { candidate.close(); throw error }
                }
                Thread.sleep(forTimeInterval: 0.025)
            }
        }
        guard let client else { throw LockedUseError.message("Locked Use session holder did not start") }
        _ = flock(lockFD, LOCK_UN)
        return try begin(client, execID: execID, requireLocked: requireLocked)
    }

    static func queryStatus() throws -> Bool {
        guard let client = try connectIfRunning(timeout: 0.25) else { return false }
        defer { client.close() }
        let reply = try client.request(.status, timeout: 0.25)
        return reply.activeLease == true
    }

    static func endIfActive() throws -> Bool {
        guard let client = try connectIfRunning() else { return false }
        defer { client.close() }
        _ = try client.request(.endSession)
        return true
    }
}
