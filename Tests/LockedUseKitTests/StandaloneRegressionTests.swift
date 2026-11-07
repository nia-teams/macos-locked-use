import Darwin
import Foundation
import XCTest
@testable import LockedUseKit

final class StandaloneRegressionTests: XCTestCase {
    func testDisplayWakeWaitsForSleepingDisplaysAndPumpsUpdates() {
        var time: TimeInterval = 0
        var wakes = 0
        var polls = 0
        XCTAssertTrue(LockedUseDisplayWake.ensureAwake(active: { polls += 1; return time >= 0.075 },
            wake: { wakes += 1 }, pump: { time += $0 }, now: { time }))
        XCTAssertEqual(wakes, 1)
        XCTAssertGreaterThanOrEqual(polls, 4)
        XCTAssertLessThan(time, 2)
    }

    func testAwakeDisplayDoesNotWakeAndMissingDisplayTimesOut() {
        var wakes = 0
        XCTAssertTrue(LockedUseDisplayWake.ensureAwake(active: { true }, wake: { wakes += 1 }, pump: { _ in XCTFail() }))
        XCTAssertEqual(wakes, 0)
        var time: TimeInterval = 0
        XCTAssertFalse(LockedUseDisplayWake.ensureAwake(timeout: 0.1, active: { false },
            wake: { wakes += 1 }, pump: { time += $0 }, now: { time }))
        XCTAssertEqual(wakes, 1)
        XCTAssertEqual(time, 0.1, accuracy: 0.0001)
        XCTAssertFalse(LockedUseDisplayWake.ensureAwake(timeout: .infinity, active: { false },
            wake: { XCTFail() }, pump: { _ in XCTFail() }))
    }

    func testPolicyCacheBoundaryCanRefreshBeforeSuspendingHealthyInstallation() {
        let monitor = LockedUsePolicyMonitor { true }
        XCTAssertEqual(monitor.refreshAndWait(timeout: 1), .valid)
        XCTAssertEqual(monitor.status(now: ProcessInfo.processInfo.systemUptime + 2), .stale)
        XCTAssertEqual(monitor.refreshAndWait(timeout: 1), .valid)
    }

    func testImmediatePolicyRefreshCannotEraseInvalidation() {
        let monitor = LockedUsePolicyMonitor { false }
        XCTAssertEqual(monitor.refreshAndWait(timeout: 1), .invalid)
        XCTAssertEqual(monitor.refreshAndWait(timeout: 1), .invalid)
    }

    func testWedgedPolicyRefreshIsBounded() {
        let release = DispatchSemaphore(value: 0)
        let monitor = LockedUsePolicyMonitor { release.wait(); return true }
        defer { release.signal() }
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertNotEqual(monitor.refreshAndWait(timeout: 0.01), .valid)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5)
    }

    func testDebugDateComparisonsUseReferenceIntervals() {
        let first = Date(timeIntervalSinceReferenceDate: 100)
        let later = Date(timeIntervalSinceReferenceDate: 101)
        XCTAssertTrue(first.isBefore(later))
        XCTAssertFalse(later.isBefore(first))
        XCTAssertFalse(first.isBefore(first))
        XCTAssertTrue(first.isAtOrAfter(first))
        XCTAssertTrue(later.isAtOrAfter(first))
    }

    func testStandaloneCLIParsingPreservesChildArguments() throws {
        XCTAssertEqual(try LockedUseCommand.parse(["exec", "--", "echo", "--json", "a b"]),
                       .exec(command: ["echo", "--json", "a b"], requireLocked: false))
        XCTAssertEqual(try LockedUseCommand.parse(["exec", "--require-locked", "--", "echo", "--ttl", "90"]),
                       .exec(command: ["echo", "--ttl", "90"], requireLocked: true))
        XCTAssertEqual(try LockedUseCommand.parse(["status"]), .status(json: false))
        XCTAssertEqual(try LockedUseCommand.parse(["status", "--json"]), .status(json: true))
        XCTAssertEqual(try LockedUseCommand.parse(["lock"]), .lock)
        XCTAssertEqual(try LockedUseCommand.parse(["end"]), .end)
        for action in ["enable", "disable", "recover", "certify"] {
            XCTAssertEqual(try LockedUseCommand.parse([action]), .manage(action))
            XCTAssertThrowsError(try LockedUseCommand.parse([action, "--extra"]))
        }
        for args in [[], ["--help"], ["-h"]] {
            XCTAssertEqual(try LockedUseCommand.parse(args), .help)
        }
    }

    func testStandaloneCLIRejectsManualBeginTTLAndMalformedExec() {
        let invalid = [
            ["begin"], ["begin", "--ttl", "90"], ["begin", "--require-locked"],
            ["exec"], ["exec", "--"], ["exec", "--", ""], ["exec", "echo"],
            ["exec", "--ttl", "90", "--", "echo"],
            ["exec", "--require-locked", "--require-locked", "--", "echo"],
            ["exec", "--require-locked"], ["exec", "--unknown", "--", "echo"],
            ["end", "--extra"], ["end", "foo"], ["lock", "--extra"],
            ["status", "--extra"], ["status", "--json", "--json"], ["unknown"]
        ]
        for args in invalid { XCTAssertThrowsError(try LockedUseCommand.parse(args), args.joined(separator: " ")) }
    }

    func testHostIdentifiersAreDynamicButCannotInjectSigningRequirements() {
        for identifier in ["com.nia-teams.locked-use.app", "com.nia.teams", "com.ifuryst.lockeduse"] {
            XCTAssertTrue(LockedUseHost.isValidIdentifier(identifier))
        }
        for identifier in ["", "a\" or true", "a/b", "a b", String(repeating: "a", count: 256)] {
            XCTAssertFalse(LockedUseHost.isValidIdentifier(identifier))
        }
    }

    func testLocalConnectionCanBeCreatedWithoutRPCOrSignedHost() throws {
        // Constructor only creates and retains socket descriptors. Admission
        // remains the Broker's responsibility, never bypassed by this helper.
        let connection = try LockedUseConnection()
        XCTAssertFalse(connection.hasActiveLease)
        XCTAssertTrue(connection.isFinished)
        XCTAssertEqual(connection.activeActions, 0)
        // Defensive duplicate finishes cannot underflow the drain counter.
        connection.finishAction()
        connection.finishAction()
        XCTAssertEqual(connection.activeActions, 0)
        connection.end()
        XCTAssertFalse(connection.hasActiveLease)
        XCTAssertTrue(connection.isFinished)
    }

    func testHolderRequestsRoundTripAcrossFragmentedFrames() throws {
        let id = UUID()
        let requests: [LockedUseHolderRequest] = [
            .beginExec(execID: id, requireLocked: true),
            .beginExec(execID: UUID(), requireLocked: false),
            .validateExec(execID: id), .finishExec(execID: id), .status, .endSession
        ]
        var decoder = LockedUseIPCFrame()
        for request in requests {
            let wire = try LockedUseIPCFrame.encode(request)
            var frames: [Data] = []
            for byte in wire { frames += try decoder.append(Data([byte])) }
            XCTAssertEqual(frames.count, 1)
            XCTAssertEqual(try JSONDecoder().decode(LockedUseHolderRequest.self, from: XCTUnwrap(frames.first)), request)
        }
        try decoder.finish()
    }

    func testHolderRepliesAndDeadlines() throws {
        let replies: [LockedUseHolderReply] = [
            .init(ok: true, activeLease: true, protected: true),
            .init(ok: true, activeLease: false, protected: false),
            .init(ok: false, error: "Lease revoked"), .init(ok: true)
        ]
        var decoder = LockedUseIPCFrame()
        for reply in replies {
            let frames = try decoder.append(LockedUseIPCFrame.encode(reply))
            XCTAssertEqual(try JSONDecoder().decode(LockedUseHolderReply.self, from: XCTUnwrap(frames.first)), reply)
        }
        XCTAssertEqual(LockedUseHolderRequest.beginExec(execID: UUID(), requireLocked: true).timeout, 12)
        XCTAssertEqual(LockedUseHolderRequest.endSession.timeout, 7)
        XCTAssertEqual(LockedUseHolderRequest.status.timeout, 3)
        XCTAssertEqual(LockedUseHolderRequest.validateExec(execID: UUID()).timeout, 3)
        XCTAssertEqual(LockedUseHolderRequest.finishExec(execID: UUID()).timeout, 3)
    }

    func testHolderProtocolRejectsMalformedPayloadAndTruncatedFrame() throws {
        XCTAssertThrowsError(try JSONDecoder().decode(LockedUseHolderRequest.self, from: Data("{\"unknown\":{}}".utf8)))
        var decoder = LockedUseIPCFrame()
        let wire = try LockedUseIPCFrame.encode(LockedUseHolderRequest.status)
        XCTAssertTrue(try decoder.append(Data(wire.dropLast())).isEmpty)
        XCTAssertThrowsError(try decoder.finish())
    }

    func testHolderStatusInspectionIsNonthrowingWithoutEnrollment() {
        // Inventory must remain usable in unsigned XCTest/unenrolled hosts.
        let active = LockedUseSessionHolder.statusIfActive()
        if (try? LockedUseSigningIdentity.current()) == nil { XCTAssertFalse(active) }
    }

    func testProtectionReleaseWaitRequiresPositiveEvidence() {
        var time: TimeInterval = 0
        let released = LockedUseHolderReleaseWait.wait(timeout: 1,
            released: { time >= 0.1 }, now: { time }, sleep: { time += $0 })
        XCTAssertTrue(released)
        XCTAssertEqual(time, 0.1, accuracy: 0.0001)
        let reply = LockedUseHolderReleaseWait.reply(released: released)
        XCTAssertTrue(reply.ok)
        XCTAssertEqual(reply.activeLease, false)
        XCTAssertNil(reply.error)
    }

    func testProtectionReleaseTimeoutIsHonestAndBounded() {
        let observations: [Bool?] = [false, nil]
        for observed in observations {
            var time: TimeInterval = 0
            let released = LockedUseHolderReleaseWait.wait(timeout: 5,
                released: { observed == true }, now: { time }, sleep: { time += $0 })
            XCTAssertFalse(released)
            XCTAssertEqual(time, 5, accuracy: 0.0001)
            let reply = LockedUseHolderReleaseWait.reply(released: released)
            XCTAssertFalse(reply.ok)
            XCTAssertEqual(reply.error, "Timed out waiting for Locked Use protection release")
        }
    }

    func testDiagnosticsExposeProtectedSessionInSummaryAndJSON() throws {
        func diagnostics(active: Bool) -> LockedUseDiagnostics {
            .init(schemaVersion: 1, stage: "test", enabled: true, available: true,
                  clientApproved: true, authenticationPolicyIntact: true,
                  session: .init(state: .unlocked, userID: 501, auditSessionID: 1),
                  protectedSessionActive: active,
                  accessibility: true, screenRecording: true, inputMonitoring: true,
                  installedPluginVersion: nil, bundledPluginVersion: nil,
                  pluginInstalled: true, brokerInstalled: true,
                  guardianAccessibility: true, guardianInputMonitoring: true,
                  otherAuthorizationPlugins: [], blockers: [])
        }
        let active = diagnostics(active: true)
        XCTAssertTrue(active.summary.contains("Protected session: active"))
        let roundTrip = try JSONDecoder().decode(LockedUseDiagnostics.self, from: Data(active.jsonText().utf8))
        XCTAssertTrue(roundTrip.protectedSessionActive)
        let inactive = diagnostics(active: false)
        XCTAssertTrue(inactive.summary.contains("Protected session: inactive"))
        XCTAssertFalse(inactive.protectedSessionActive)
    }

    func testErrorDescriptionsAreStable() {
        XCTAssertEqual(LockedUseError.message("failure").localizedDescription, "failure")
        XCTAssertEqual(LockedUseError.stateUnavailable("locked"), .stateUnavailable("locked"))
    }
}
