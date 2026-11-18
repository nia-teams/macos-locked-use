import Foundation
@testable import LockedUseKit
import XCTest

final class LockedUseCooldownTests: XCTestCase {
    private let token = Data(repeating: 9, count: 32)
    private let locked = LockedUseSession(state: .locked, userID: 501, auditSessionID: 42)
    private let unlocked = LockedUseSession(state: .unlocked, userID: 501, auditSessionID: 42)
    private let guards = LockedUseStateMachine.Guards(allDisplaysCovered: true, inputTapHealthy: true, watchdogHealthy: true, displayGeneration: 1)
    private func context(_ role: LockedUseBrokerCoordinator.Role, _ byte: UInt8) -> LockedUseBrokerCoordinator.Context {
        .init(id: UUID(), role: role, userID: 501, auditSessionID: 42,
              auditToken: Data(repeating: byte, count: 32), processID: Int32(100 + byte), codeHash: Data(repeating: byte, count: 20))
    }
    private func record(owner: LockedUseBrokerCoordinator.Context, guardian: LockedUseBrokerCoordinator.Context? = nil,
                        watchdog: LockedUseBrokerCoordinator.Context? = nil, remaining: TimeInterval? = nil) -> LockedUseRecoveryRecord {
        .init(leaseID: UUID(), owner: owner, originalClientToken: token, guardian: guardian, watchdog: watchdog,
              watchdogChallenge: nil, everGranted: false, observedUnlocked: false, agentDrained: true,
              fullyReleased: guardian == nil && watchdog == nil, cooldownRemainingSeconds: remaining)
    }

    func testConfigurationLegacyNullAndNumericRoundTrips() throws {
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        let legacy = try decoder.decode(LockedUseBrokerConfiguration.self, from: Data(#"{"schemaVersion":1,"enabled":true}"#.utf8))
        XCTAssertEqual(legacy.schemaVersion, 1)
        XCTAssertEqual(legacy.cooldownSeconds, 60)
        for value in [nil, 60, 15, 0.5, 86400] as [TimeInterval?] {
            let data = try encoder.encode(LockedUseBrokerConfiguration(enabled: true, cooldownSeconds: value))
            XCTAssertEqual(try decoder.decode(LockedUseBrokerConfiguration.self, from: data).cooldownSeconds, value)
            if value == nil { XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"cooldownSeconds\":null")) }
        }
        for value in [0.0, -1, .nan, .infinity, -.infinity, 90000] {
            XCTAssertThrowsError(try LockedUseBrokerConfiguration.validatedCooldownSeconds(value))
            XCTAssertThrowsError(try encoder.encode(LockedUseBrokerConfiguration(enabled: true, cooldownSeconds: value)))
        }
        for text in ["0", "-1", "90000", "1e309", "\"NaN\""] {
            let data = Data("{\"schemaVersion\":1,\"enabled\":true,\"cooldownSeconds\":\(text)}".utf8)
            XCTAssertThrowsError(try decoder.decode(LockedUseBrokerConfiguration.self, from: data))
        }
    }

    func testCommandParserPreservesManagementAndStrictlyValidatesCooldown() throws {
        XCTAssertEqual(try LockedUseCommand.parse(["enable"]), .manage("enable"))
        XCTAssertEqual(try LockedUseCommand.parse(["enable", "--cooldown", "60"]), .enable(cooldownSeconds: 60))
        XCTAssertEqual(try LockedUseCommand.parse(["enable", "--cooldown", "manual"]), .enable(cooldownSeconds: nil))
        XCTAssertEqual(try LockedUseCommand.parse(["enable", "--cooldown", "0.5"]), .enable(cooldownSeconds: 0.5))
        for arguments in invalidArguments {
            XCTAssertThrowsError(try LockedUseCommand.parse(arguments)) { error in
                XCTAssertEqual((error as? LockedUseError)?.exitCode, 64)
            }
        }
    }

    private var invalidArguments: [[String]] {
        ["0", "-5", "nan", "inf", "abc", "90000"].map { ["enable", "--cooldown", $0] }
        + [["enable", "--cooldown"], ["enable", "--cooldown", "5", "--cooldown", "10"], ["enable", "--other", "5"]]
        + ["disable", "recover", "certify"].map { [$0, "--cooldown", "60"] }
    }

    @MainActor
    func testSettingsRejectsInvalidArgumentsBeforeAnyEnrollmentSideEffects() {
        for arguments in invalidArguments {
            XCTAssertThrowsError(try LockedUseSettings.handle(arguments: ["locked-use"] + arguments)) { error in
                XCTAssertEqual((error as? LockedUseError)?.exitCode, 64)
            }
        }
    }

    func testDualReleaseBarrierCooldownReentryStatusStableFenceAndExactExpiry() throws {
        for guardianFirst in [true, false] {
            let owner = context(.agent, 1), guardian = context(.guardian, 2), watchdog = context(.guardian, 3)
            let seed = record(owner: owner, guardian: guardian, watchdog: watchdog)
            var broker = LockedUseBrokerCoordinator(enabled: true, backendValidated: true, requiresWatchdog: true, recovery: seed, cooldownSeconds: 5)
            _ = try broker.handle(.init(operation: .guardianReport, leaseID: seed.leaseID, session: locked, guards: guards, unlockWorkPending: false), context: guardian, now: 1)
            XCTAssertEqual(broker.phase, .awaitingManualUnlock)
            XCTAssertNil(broker.cooldownDeadline)
            try broker.tick(now: 100)
            XCTAssertEqual(broker.phase, .awaitingManualUnlock)
            XCTAssertNil(broker.cooldownDeadline)
            // A status observation cannot bypass either unreleased guard.
            _ = try broker.handle(.init(operation: .status, session: unlocked), context: owner, now: 101)
            XCTAssertEqual(broker.phase, .awaitingManualUnlock)
            let first = guardianFirst ? guardian : watchdog, second = guardianFirst ? watchdog : guardian
            _ = try broker.handle(.init(operation: guardianFirst ? .guardianReleased : .watchdogReleased, leaseID: seed.leaseID), context: first, now: 102)
            try broker.tick(now: 200)
            XCTAssertNil(broker.cooldownDeadline)
            XCTAssertEqual(broker.phase, .awaitingManualUnlock)
            _ = try broker.handle(.init(operation: guardianFirst ? .watchdogReleased : .guardianReleased, leaseID: seed.leaseID), context: second, now: 201)
            XCTAssertEqual(broker.cooldownDeadline, 206)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let fence = try encoder.encode(XCTUnwrap(broker.recoveryRecord(clientToken: token)))
            for now in [202.0, 203, 205.9] {
                let status = try broker.handle(.init(operation: .status), context: owner, now: now)
                XCTAssertEqual(status.phase, .awaitingManualUnlock)
                XCTAssertGreaterThan(try XCTUnwrap(status.cooldownRemainingSeconds), 0)
                XCTAssertThrowsError(try broker.handle(.init(operation: .begin, session: locked), context: owner, now: now)) { error in
                    XCTAssertEqual(error as? LockedUseStateMachine.Failure, .manualUnlockRequired)
                }
                XCTAssertEqual(try encoder.encode(XCTUnwrap(broker.recoveryRecord(clientToken: token))), fence)
            }
            try broker.tick(now: 206)
            XCTAssertEqual(broker.phase, .idle)
            XCTAssertNil(broker.cooldownDeadline)
            XCTAssertNil(broker.recoveryRecord(clientToken: token))
            XCTAssertEqual(broker.recordedOwner?.id, owner.id)
            XCTAssertEqual(try broker.handle(.init(operation: .begin, session: locked), context: owner, now: 207).phase, .preparing)
            XCTAssertNil(broker.cooldownDeadline)
        }
    }

    func testNormalPhysicalInterruptionArmsOnlyAfterLastGuardRelease() throws {
        let owner = context(.agent, 1), guardian = context(.guardian, 2), watchdog = context(.guardian, 3), plugin = context(.plugin, 4)
        var broker = LockedUseBrokerCoordinator(enabled: true, backendValidated: true, requiresWatchdog: true, cooldownSeconds: 10)
        let begin = try broker.handle(.init(operation: .begin, session: locked), context: owner, now: 1)
        let lease = try XCTUnwrap(begin.leaseID)
        let hello = try broker.handle(.init(operation: .guardianHello, leaseID: lease, token: begin.token), context: guardian, now: 1.1)
        _ = try broker.handle(.init(operation: .watchdogHello, leaseID: lease, token: hello.token), context: watchdog, now: 1.2)
        _ = try broker.handle(.init(operation: .watchdogReport, leaseID: lease, session: locked, guards: guards), context: watchdog, now: 1.3)
        _ = try broker.handle(.init(operation: .guardianReport, leaseID: lease, session: locked, guards: guards), context: guardian, now: 1.4)
        let claim = try broker.handle(.init(operation: .pluginClaim), context: plugin, now: 1.5)
        XCTAssertNil(broker.cooldownDeadline)
        _ = try broker.handle(.init(operation: .pluginConsume, leaseID: lease, token: claim.token), context: plugin, now: 1.6)
        _ = try broker.handle(.init(operation: .guardianReport, leaseID: lease, session: unlocked, guards: guards, stopReason: .physicalInput, unlockWorkPending: false), context: guardian, now: 1.7)
        _ = try broker.handle(.init(operation: .quiesced, leaseID: lease), context: owner, now: 1.8)
        _ = try broker.handle(.init(operation: .guardianReport, leaseID: lease, session: locked, guards: guards, unlockWorkPending: false), context: guardian, now: 1.9)
        XCTAssertEqual(broker.phase, .awaitingManualUnlock)
        try broker.tick(now: 20)
        XCTAssertNil(broker.cooldownDeadline)
        _ = try broker.handle(.init(operation: .guardianReleased, leaseID: lease), context: guardian, now: 21)
        XCTAssertNil(broker.cooldownDeadline)
        _ = try broker.handle(.init(operation: .watchdogReleased, leaseID: lease), context: watchdog, now: 22)
        XCTAssertEqual(broker.cooldownDeadline, 32)
        try broker.tick(now: 31.999)
        XCTAssertEqual(broker.phase, .awaitingManualUnlock)
        try broker.tick(now: 32)
        XCTAssertEqual(broker.phase, .idle)
        XCTAssertEqual(broker.stopReason, .physicalInput)
    }

    func testPreparingFailureWithoutRegisteredGuardsArmsImmediatelyOnSafeRelock() throws {
        let owner = context(.agent, 1)
        var broker = LockedUseBrokerCoordinator(enabled: true, backendValidated: true, cooldownSeconds: 5)
        let begin = try broker.handle(.init(operation: .begin, session: locked), context: owner, now: 1)
        _ = try broker.handle(.init(operation: .end, stopReason: .operationFailed), context: owner, now: 2)
        _ = try broker.handle(.init(operation: .quiesced, leaseID: begin.leaseID), context: owner, now: 3)
        XCTAssertEqual(broker.phase, .awaitingManualUnlock)
        XCTAssertTrue(broker.isFullyReleased)
        XCTAssertEqual(broker.cooldownDeadline, 8)
        try broker.tick(now: 8)
        XCTAssertEqual(broker.phase, .idle)
    }

    func testOwnerProcessExitArmsImmediatelyWithoutRegisteredGuards() throws {
        let owner = context(.agent, 1)
        var broker = LockedUseBrokerCoordinator(enabled: true, backendValidated: true, cooldownSeconds: 5)
        _ = try broker.handle(.init(operation: .begin, session: locked), context: owner, now: 1)
        _ = try broker.handle(.init(operation: .end, stopReason: .operationFailed), context: owner, now: 2)
        XCTAssertEqual(broker.phase, .relocking)
        XCTAssertTrue(broker.isFullyReleased)
        XCTAssertNil(broker.cooldownDeadline)
        try broker.ownerProcessExited()
        // No tick between the process-exit transition and this assertion.
        XCTAssertEqual(broker.phase, .awaitingManualUnlock)
        XCTAssertEqual(broker.cooldownDeadline, 7)
        XCTAssertNotNil(broker.recoveryRecord(clientToken: token))
        try broker.tick(now: 6.999)
        XCTAssertEqual(broker.phase, .awaitingManualUnlock)
        try broker.tick(now: 7)
        XCTAssertEqual(broker.phase, .idle)
    }

    func testRecoveryProbeStaysManualOnlyPastShortConfiguredCooldown() throws {
        let owner = context(.agent, 1), guardian = context(.guardian, 2), watchdog = context(.guardian, 3)
        let observer = context(.observer, 4)
        var broker = LockedUseBrokerCoordinator(enabled: true, backendValidated: true,
            requiresWatchdog: true, cooldownSeconds: 0.05, validationMode: true)
        let begin = try broker.handle(.init(operation: .beginRecoveryProbe, session: locked), context: owner, now: 1)
        let lease = try XCTUnwrap(begin.leaseID)
        let hello = try broker.handle(.init(operation: .guardianHello, leaseID: lease, token: begin.token), context: guardian, now: 1.1)
        _ = try broker.handle(.init(operation: .watchdogHello, leaseID: lease, token: hello.token), context: watchdog, now: 1.2)
        _ = try broker.handle(.init(operation: .watchdogReport, leaseID: lease, session: locked, guards: guards), context: watchdog, now: 1.3)
        _ = try broker.handle(.init(operation: .guardianReport, leaseID: lease, session: locked, guards: guards, unlockWorkPending: false), context: guardian, now: 1.4)
        _ = try broker.handle(.init(operation: .quiesced, leaseID: lease), context: owner, now: 1.5)
        _ = try broker.handle(.init(operation: .guardianReport, leaseID: lease, session: locked, guards: guards, unlockWorkPending: false), context: guardian, now: 1.6)
        _ = try broker.handle(.init(operation: .guardianReleased, leaseID: lease), context: guardian, now: 1.7)
        _ = try broker.handle(.init(operation: .watchdogReleased, leaseID: lease), context: watchdog, now: 1.8)
        XCTAssertNil(broker.cooldownDeadline)
        for now in [2.0, 100, 100000] {
            try broker.tick(now: now)
            let status = try broker.handle(.init(operation: .status, session: locked), context: observer, now: now)
            XCTAssertEqual(status.phase, .awaitingManualUnlock)
            XCTAssertEqual(status.guardsReleased, true)
            XCTAssertEqual(status.recoveryProbePrepared, true)
            XCTAssertNil(status.cooldownRemainingSeconds)
            XCTAssertNil(broker.cooldownDeadline)
        }
        try broker.observeConsoleManualUnlock(session: unlocked, now: 100001)
        XCTAssertEqual(broker.phase, .idle)
        XCTAssertNil(broker.recoveryRecord(clientToken: token))
    }

    func testRestartCapsBudgetAndKeepsPersistenceStableAndManualOnlyPolicy() throws {
        let owner = context(.agent, 1)
        for remaining in [nil, 0, 3, 60] as [TimeInterval?] {
            let seed = try record(owner: owner, remaining: remaining).validated()
            var broker = LockedUseBrokerCoordinator(enabled: true, backendValidated: true, recovery: seed, cooldownSeconds: 10)
            XCTAssertNil(broker.cooldownDeadline)
            try broker.tick(now: 100)
            let budget = min(10, remaining ?? 10)
            if budget == 0 { XCTAssertEqual(broker.phase, .idle); continue }
            XCTAssertEqual(broker.cooldownDeadline, 100 + budget)
            let stored = try XCTUnwrap(broker.recoveryRecord(clientToken: token))
            try broker.tick(now: 101)
            XCTAssertEqual(broker.recoveryRecord(clientToken: token)?.cooldownRemainingSeconds, stored.cooldownRemainingSeconds)
            var restarted = LockedUseBrokerCoordinator(enabled: true, backendValidated: true, recovery: stored, cooldownSeconds: 10)
            try restarted.tick(now: 500)
            XCTAssertEqual(restarted.cooldownDeadline, 500 + budget)
            try restarted.tick(now: 500 + budget)
            XCTAssertNil(restarted.recoveryRecord(clientToken: token))
        }
        var manual = LockedUseBrokerCoordinator(enabled: true, backendValidated: true, recovery: record(owner: owner, remaining: 3), cooldownSeconds: nil)
        try manual.tick(now: 1)
        try manual.tick(now: 100000)
        XCTAssertEqual(manual.phase, .awaitingManualUnlock)
        XCTAssertNil(manual.cooldownDeadline)
        XCTAssertNotNil(manual.recoveryRecord(clientToken: token))
        try manual.observeConsoleManualUnlock(session: unlocked, now: 100001)
        XCTAssertEqual(manual.phase, .idle)
    }

    func testRecoveryRejectsMalformedBudgetsAndDecodesLegacyRecord() throws {
        let owner = context(.agent, 1)
        for remaining in [-1.0, .nan, .infinity, 90000] {
            XCTAssertThrowsError(try record(owner: owner, remaining: remaining).validated())
        }
        let data = try JSONEncoder().encode(record(owner: owner))
        let legacy = try JSONDecoder().decode(LockedUseRecoveryRecord.self, from: data).validated()
        XCTAssertNil(legacy.cooldownRemainingSeconds)
    }

    func testManualUnlockClearsCooldownForConsoleOwnerObserverAndValidation() throws {
        let owner = context(.agent, 1), observer = context(.observer, 2)
        for method in 0..<4 {
            var broker = LockedUseBrokerCoordinator(enabled: true, backendValidated: true, recovery: record(owner: owner))
            try broker.tick(now: 1)
            XCTAssertEqual(broker.cooldownDeadline, 61)
            if method == 0 { try broker.observeConsoleManualUnlock(session: unlocked, now: 2) }
            else {
                _ = try broker.handle(.init(operation: method == 3 ? .validationManual : .status, session: unlocked), context: method == 2 ? observer : owner, now: 2)
            }
            XCTAssertEqual(broker.phase, .idle)
            XCTAssertNil(broker.cooldownDeadline)
            XCTAssertNil(broker.recoveryRecord(clientToken: token))
        }
        for session in [LockedUseSession(state: .unlocked, userID: 502, auditSessionID: 42),
                        .init(state: .unlocked, userID: 501, auditSessionID: 43), locked,
                        .init(state: .unavailable, userID: 501, auditSessionID: 42)] {
            var broker = LockedUseBrokerCoordinator(enabled: true, backendValidated: true, recovery: record(owner: owner))
            try broker.tick(now: 1)
            XCTAssertThrowsError(try broker.observeConsoleManualUnlock(session: session, now: 2))
            XCTAssertEqual(broker.phase, .awaitingManualUnlock)
            XCTAssertEqual(broker.cooldownDeadline, 61)
        }
    }

    func testStatusCannotResetCooldownFromForeignObserverOrInvalidSession() throws {
        let owner = context(.agent, 1)
        for foreign in [LockedUseBrokerCoordinator.Context(id: UUID(), role: .observer, userID: 502, auditSessionID: 42),
                        .init(id: UUID(), role: .observer, userID: 501, auditSessionID: 43)] {
            var broker = LockedUseBrokerCoordinator(enabled: true, backendValidated: true, recovery: record(owner: owner))
            _ = try broker.handle(.init(operation: .status, session: .init(state: .unlocked, userID: foreign.userID, auditSessionID: foreign.auditSessionID)), context: foreign, now: 1)
            XCTAssertEqual(broker.phase, .awaitingManualUnlock)
        }
        for session in [locked, LockedUseSession(state: .unavailable, userID: 501, auditSessionID: 42)] {
            var broker = LockedUseBrokerCoordinator(enabled: true, backendValidated: true, recovery: record(owner: owner))
            _ = try broker.handle(.init(operation: .status, session: session), context: owner, now: 1)
            XCTAssertEqual(broker.phase, .awaitingManualUnlock)
        }
    }

    func testUnshieldedDiagnosticNeverArmsOrCompletesCooldown() throws {
        let guardian = context(.guardian, 2)
        var broker = LockedUseBrokerCoordinator(enabled: true, backendValidated: false, requiresWatchdog: true, cooldownSeconds: 1, validationMode: true)
        _ = try broker.handle(.init(operation: .beginUnshieldedDiagnostic, session: locked), context: guardian, now: 1)
        try broker.tick(now: 21)
        XCTAssertEqual(broker.phase, .awaitingManualUnlock)
        XCTAssertTrue(broker.isFullyReleased)
        try broker.tick(now: 100000)
        XCTAssertEqual(broker.phase, .awaitingManualUnlock)
        XCTAssertNil(broker.cooldownDeadline)
        let status = try broker.handle(.init(operation: .status, session: locked), context: guardian, now: 100001)
        XCTAssertNil(status.cooldownRemainingSeconds)
    }

    func testOldDiagnosticsAndIPCJSONDecodeWithoutNewKeys() throws {
        let data = Data(#"{"schemaVersion":1,"stage":"not-installed","enabled":false,"available":false,"clientApproved":false,"authenticationPolicyIntact":false,"session":{"state":"unlocked"},"protectedSessionActive":false,"accessibility":false,"screenRecording":false,"inputMonitoring":false,"pluginInstalled":false,"brokerInstalled":false,"otherAuthorizationPlugins":[],"blockers":[]}"#.utf8)
        let diagnostics = try JSONDecoder().decode(LockedUseDiagnostics.self, from: data)
        XCTAssertNil(diagnostics.cooldownRemainingSeconds)
        XCTAssertNil(diagnostics.cooldownConfiguredSeconds)
        XCTAssertNil(diagnostics.awaitingManualUnlock)
        let reply = LockedUseIPCReply(id: UUID(), result: .waiting, phase: .awaitingManualUnlock)
        XCTAssertNil(try JSONDecoder().decode(LockedUseIPCReply.self, from: JSONEncoder().encode(reply)).cooldownRemainingSeconds)
    }
}
