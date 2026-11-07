import Darwin
import Foundation
import LockedUseKit

@main
struct LockedUseMain {
    @MainActor
    static func main() async {
        do {
            if Array(CommandLine.arguments.dropFirst()) == ["--session-holder"] {
                try LockedUseSessionHolder.runServer()
                exit(0)
            }
            let command = try LockedUseCommand.parse(Array(CommandLine.arguments.dropFirst()))
            switch command {
            case .help: print(LockedUseCommand.usage)
            case .status(let json):
                let diagnostics = LockedUseDiagnostics.collect()
                if json { print(try diagnostics.jsonText()) } else { print(diagnostics.summary) }
            case .exec(let command, let required):
                exit(try execute(command, requireLocked: required))
            case .gui(let request):
                try await executeGUI(request)
            case .end:
                print(try LockedUseSessionHolder.endIfActive() ? "Locked Use: ended" : "Locked Use: idle")
            case .lock:
                _ = try? LockedUseSessionHolder.endIfActive()
                if LockedUseSession.current().state != .locked {
                    try LockedUseScreenLock.lockImmediately()
                }
            case .manage(let action):
                _ = try LockedUseSettings.handle(arguments: ["locked-use", action])
            }
            exit(0)
        } catch {
            fputs("locked-use: \(error.localizedDescription.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " "))\n", stderr)
            exit((error as? LockedUseError)?.exitCode ?? 77)
        }
    }

    @MainActor
    private static func executeGUI(_ request: LockedUseGUICommand) async throws {
        let execID = UUID()
        if let holder = try LockedUseSessionHolder.beginExecIfNeeded(execID: execID, requireLocked: request.requireLocked) {
            defer {
                try? holder.client.finishExec(execID: execID)
                holder.client.close()
            }
            if holder.protected {
                try await LockedUseActionScope.withAsyncValidator({ try holder.client.validateExec(execID: execID) }) {
                    try await performGUI(request)
                }
            } else { try await performGUI(request) }
        } else {
            // No holder is needed on an ordinary unlocked desktop. Admission
            // still enforces --require-locked and another owner's protected lease.
            let connection = try LockedUseConnection()
            let scoped = try connection.beginAction(requireLocked: request.requireLocked)
            defer { if scoped { connection.finishAction() }; connection.end() }
            if scoped {
                try await LockedUseActionScope.withAsyncValidator({ try connection.validateAction() }) {
                    try await performGUI(request)
                }
            } else { try await performGUI(request) }
        }
    }

    @MainActor
    private static func performGUI(_ request: LockedUseGUICommand) async throws {
        let target = try LockedUseGUI.findWindow(app: request.app, pid: request.pid, windowID: request.windowID)
        switch request.action {
        case .click:
            let scale = request.pixel ? LockedUseGUI.backingScaleFactor(for: target.bounds) : 1
            try LockedUseGUI.click(target: target, x: request.x! / scale, y: request.y! / scale, screen: request.screen, clickCount: request.doubleClick ? 2 : 1)
        case .type:
            try LockedUseGUI.typeText(request.text!, windowID: target.windowID, pid: target.pid)
        case .key:
            try LockedUseGUI.pressKey(request.key!, windowID: target.windowID, pid: target.pid)
        case .capture:
            let result = try await LockedUseGUI.captureWindow(windowID: target.windowID, outputPath: request.output!)
            print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
        }
        try LockedUseActionScope.validate()
    }

    private final class InterruptState: @unchecked Sendable {
        private let mutex = NSLock()
        private var value: Int32 = 0
        var number: Int32 {
            get { mutex.lock(); defer { mutex.unlock() }; return value }
            set { mutex.lock(); value = newValue; mutex.unlock() }
        }
    }

    @MainActor
    private static func execute(_ command: [String], requireLocked: Bool) throws -> Int32 {
        let execID = UUID()
        if let holder = try LockedUseSessionHolder.beginExecIfNeeded(execID: execID, requireLocked: requireLocked) {
            // runChild's inner defer stops/reaps the child before this outer
            // finishExec, including interruption and validation failure paths.
            defer {
                try? holder.client.finishExec(execID: execID)
                holder.client.close()
            }
            return try runChild(command, protected: holder.protected) {
                try holder.client.validateExec(execID: execID)
            }
        }
        let connection = try LockedUseConnection()
        var needsRelease = false
        defer {
            connection.end()
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while needsRelease && ProcessInfo.processInfo.systemUptime < deadline {
                if (try? connection.protectionReleased()) == true { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        return try connection.perform(requireLocked: requireLocked) {
            let protected = LockedUseActionScope.requiresScreenCaptureKit
            needsRelease = protected
            return try runChild(command, protected: protected) { try LockedUseActionScope.validate() }
        }
    }

    @MainActor
    private static func runChild(_ command: [String], protected: Bool, validate: () throws -> Void) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        let interrupted = InterruptState()
        let signals = [SIGINT, SIGTERM, SIGHUP]
        let handlers = signals.map { number -> DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { interrupted.number = number }
            source.resume()
            return source
        }
        defer {
            handlers.forEach { $0.cancel() }
            signals.forEach { signal($0, SIG_DFL) }
        }
        try process.run()
        defer { stop(process) }
        var nextValidation: TimeInterval = 0
        while process.isRunning {
            if interrupted.number != 0 { break }
            if protected && ProcessInfo.processInfo.systemUptime >= nextValidation {
                try validate()
                nextValidation = ProcessInfo.processInfo.systemUptime + 0.15
            }
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.025))
            Thread.sleep(forTimeInterval: 0.025)
        }
        if interrupted.number != 0 { return 128 + interrupted.number }
        if protected { try validate() }
        process.waitUntilExit()
        return process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus : process.terminationStatus
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.025)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

}
