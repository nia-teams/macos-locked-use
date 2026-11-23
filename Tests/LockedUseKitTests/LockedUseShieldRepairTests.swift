import XCTest
@testable import LockedUseKit

final class LockedUseShieldRepairTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let displaced = CGRect(x: -1921, y: -243, width: 2260, height: 1469)
    private let mismatch = "shieldBoundsMismatch expected={{0, 0}, {1512, 982}} actual={{-1921, -243}, {2260, 1469}}"

    private func prepared() -> LockedUseShieldRepair {
        var state = LockedUseShieldRepair()
        state.observeTopology("display-1")
        XCTAssertNil(state.failure(observed: nil, unlocked: false, now: 0))
        return state
    }

    func testReportedBoundsMatchHorizontalSpaceTranslation() {
        let target = LockedUseShieldCoverage.surfaceFrame(for: display)
        XCTAssertEqual(target, CGRect(x: -378, y: -245.5, width: 2268, height: 1473))
        XCTAssertEqual(displaced.minX - target.minX, -(display.width + 31))
        XCTAssertEqual(displaced.midY, display.midY, accuracy: 0.5)
        XCTAssertEqual(displaced.width / target.width, 0.9965, accuracy: 0.0001)
        XCTAssertEqual(displaced.height / target.height, 0.9973, accuracy: 0.0001)
    }

    func testReportedSpaceSlideSurvivesSixHundredMillisecondsAndResets() {
        XCTAssertFalse(LockedUseShieldCoverage.covers(displaced, display: display))
        XCTAssertTrue(LockedUseShieldCoverage.covers(
            LockedUseShieldCoverage.surfaceFrame(for: display), display: display))
        var state = prepared()
        // Independent polls, not a blocking wait or nested run-loop pump.
        for time in [0.1, 0.2, 0.3, 0.4, 0.5, 0.6] {
            XCTAssertNil(state.failure(observed: mismatch, unlocked: true, now: time))
            XCTAssertEqual(state.mismatchStarted, 0.1)
        }
        XCTAssertNil(state.failure(observed: nil, unlocked: true, now: 0.7))
        XCTAssertNil(state.mismatchStarted)
        XCTAssertNil(state.failure(observed: mismatch, unlocked: true, now: 1))
        XCTAssertEqual(state.mismatchStarted, 1)
    }

    func testPersistentDisplacementFailsAtDeadlineAndStaysFailed() {
        var state = prepared()
        XCTAssertNil(state.failure(observed: mismatch, unlocked: true, now: 1))
        XCTAssertNil(state.failure(observed: mismatch, unlocked: true, now: 2.19))
        XCTAssertEqual(state.failure(observed: mismatch, unlocked: true, now: 2.2), mismatch)
        XCTAssertEqual(state.failure(observed: nil, unlocked: true, now: 2.3), mismatch)
    }

    func testLateHealthyTickCannotResurrectExpiredRecovery() {
        var state = prepared()
        XCTAssertNil(state.failure(observed: mismatch, unlocked: true, now: 1))
        XCTAssertEqual(state.failure(observed: nil, unlocked: true, now: 2.3),
                       "shieldBoundsMismatch recoveryDeadlineExpired")
    }

    func testPreparationAndUnverifiedSurfacesNeverGetGrace() {
        var state = prepared()
        XCTAssertEqual(state.failure(observed: mismatch, unlocked: false, now: 0.1), mismatch)
        XCTAssertNil(state.mismatchStarted)
        var unverified = LockedUseShieldRepair()
        XCTAssertEqual(unverified.failure(observed: mismatch, unlocked: true, now: 0), mismatch)
        XCTAssertNil(unverified.mismatchStarted)
    }

    func testIntegrityFailuresImmediatelyAbortActiveRecovery() {
        for failure in ["shieldNotVisible", "shieldNotInWindowServer", "shieldOwnerMismatch",
                        "shieldAlphaMismatch", "shieldLayerMismatch", "shieldBoundsUnavailable",
                        "activeDisplayUncovered", "windowListUnavailable", "topologyChanged"] {
            var state = prepared()
            XCTAssertNil(state.failure(observed: mismatch, unlocked: true, now: 1))
            XCTAssertEqual(state.failure(observed: failure, unlocked: true, now: 1), failure)
            XCTAssertEqual(state.failure(observed: nil, unlocked: true, now: 1.1), failure)
        }
    }

    func testTopologyNotificationBeforePollLatchesAcrossSuccessfulReconciliation() {
        var state = prepared()
        // The notification observes the topology before staging/polling.
        state.observeTopology("display-1|display-2")
        // Publishing replacement windows must not reset the initial topology.
        state.observeTopology("display-1|display-2")
        for time in [0.1, 0.2, 0.3] {
            XCTAssertEqual(state.failure(observed: nil, unlocked: true, now: time), "topologyChanged")
        }
        state.observeTopology("display-1") // Returning to the old layout cannot un-latch.
        XCTAssertEqual(state.failure(observed: nil, unlocked: true, now: 0.4), "topologyChanged")
    }

    func testEmptyStagingPreservesLiveWindowsAndLatchesFailure() {
        var state = prepared()
        var live = [1: "original"]
        do {
            let staged: [Int: String] = try LockedUseShieldRepair.stage(ids: [],
                make: { _ in XCTFail("Empty enumeration"); return "new" }, discard: { _ in })
            live = staged
            XCTFail("Empty enumeration must throw")
        } catch { state.latch("shieldReconciliationFailed") }
        XCTAssertEqual(live, [1: "original"])
        XCTAssertEqual(state.failure(observed: nil, unlocked: true, now: 1), "shieldReconciliationFailed")
        XCTAssertEqual(state.failure(observed: nil, unlocked: true, now: 2), "shieldReconciliationFailed")
    }

    func testFailedStagingClosesOnlyCandidatesAndPreservesLiveWindows() {
        enum FixtureError: Error { case creation }
        var state = prepared()
        var live = [1: "original"]
        var discarded: [String] = []
        do {
            let staged = try LockedUseShieldRepair.stage(ids: [2, 3], make: { id -> String in
                if id == 3 { throw FixtureError.creation }
                return "candidate-\(id)"
            }, discard: { discarded.append($0) })
            live = staged
            XCTFail("Incomplete staging must throw")
        } catch { state.latch("shieldReconciliationFailed") }
        XCTAssertEqual(live, [1: "original"])
        XCTAssertEqual(discarded, ["candidate-2"])
        XCTAssertEqual(state.failure(observed: nil, unlocked: true, now: 1), "shieldReconciliationFailed")
    }

    func testCompleteStagingProducesAllScreensWithoutDiscardingCandidates() throws {
        let staged = try LockedUseShieldRepair.stage(ids: [1, 2], make: { "screen-\($0)" },
            discard: { _ in XCTFail("Successful staging must retain candidates") })
        XCTAssertEqual(staged, [1: "screen-1", 2: "screen-2"])
        XCTAssertThrowsError(try LockedUseShieldRepair.stage(ids: [1, 1], make: { $0 }, discard: { _ in }))
    }

    func testInvalidAndReversedClocksFailClosed() {
        for invalid in [Double.nan, .infinity, -1] {
            var state = prepared()
            XCTAssertEqual(state.failure(observed: mismatch, unlocked: true, now: invalid), "shieldClockInvalid")
        }
        var state = prepared()
        XCTAssertNil(state.failure(observed: mismatch, unlocked: true, now: 1))
        XCTAssertEqual(state.failure(observed: mismatch, unlocked: true, now: 0.9), "shieldClockInvalid")
    }

    func testPersistentMismatchRequestsRelock() throws {
        let session = LockedUseSession(state: .unlocked, userID: 501, auditSessionID: 42)
        var policy = try LockedUseGuardianPolicy(session: session, now: 0)
        try policy.prepared(topology: "display-1", now: 0)
        var state = prepared()
        XCTAssertNil(state.failure(observed: mismatch, unlocked: true, now: 0.1))
        let failure = state.failure(observed: mismatch, unlocked: true, now: 1.3)
        XCTAssertEqual(try policy.poll(session: session, topology: "display-1",
            guardsHealthy: failure == nil, now: 1.3), [.requestRelock])
        XCTAssertEqual(policy.phase, .relocking)
    }
}
