import XCTest
@testable import LockedUseKit

final class LockedUseShieldRepairTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let displaced = CGRect(x: -1921, y: -243, width: 2260, height: 1469)
    private let mismatch = "shieldBoundsMismatch expected={{0, 0}, {1512, 982}} actual={{-1921, -243}, {2260, 1469}}"

    func testReportedDisplacementRequiresVerifiedSnapBack() {
        XCTAssertFalse(LockedUseShieldCoverage.covers(displaced, display: display))
        var actual = displaced
        var time = 0.0
        var repairs = 0
        let result = LockedUseShieldRepair.verify(check: {
            LockedUseShieldCoverage.covers(actual, display: self.display) ? nil : self.mismatch
        }, repair: {
            repairs += 1
        }, now: { time }, wait: {
            time += $0
            // Simulate WindowServer publishing a repaired frame after 3 commits.
            if repairs == 3 { actual = LockedUseShieldCoverage.surfaceFrame(for: self.display) }
        })
        XCTAssertNil(result)
        XCTAssertEqual(repairs, 3)
        XCTAssertEqual(time, 0.03, accuracy: 0.000001)
    }

    func testPersistentDisplacementFailsClosedWithinBudget() {
        var time = 0.0
        var repairs = 0
        let result = LockedUseShieldRepair.verify(check: { self.mismatch },
            repair: { repairs += 1 }, now: { time }, wait: { time += $0 })
        XCTAssertEqual(result, mismatch)
        XCTAssertGreaterThan(repairs, 0)
        XCTAssertLessThanOrEqual(repairs, 20)
        XCTAssertLessThanOrEqual(time, LockedUseShieldRepair.timeout)
    }

    func testMissingOrInvalidShieldsAndTopologyNeverGetGrace() {
        for failure in ["shieldNotVisible", "shieldNotInWindowServer", "shieldOwnerMismatch",
                        "shieldAlphaMismatch", "shieldLayerMismatch", "shieldBoundsUnavailable",
                        "activeDisplayUncovered", "windowListUnavailable", "topologyChanged"] {
            XCTAssertEqual(LockedUseShieldRepair.verify(check: { failure },
                repair: { XCTFail("Must not repair \(failure)") }, now: { 0 },
                wait: { _ in XCTFail("Must not wait for \(failure)") }), failure)
        }
    }

    func testDisappearingShieldDuringRepairFailsImmediately() {
        var reads = 0
        var time = 0.0
        let result = LockedUseShieldRepair.verify(check: {
            reads += 1
            return reads == 1 ? self.mismatch : "shieldNotInWindowServer"
        }, repair: {}, now: { time }, wait: { time += $0 })
        XCTAssertEqual(result, "shieldNotInWindowServer")
        XCTAssertEqual(reads, 2)
    }

    func testHealthySurfaceDoesNotRepairOrWait() {
        XCTAssertNil(LockedUseShieldRepair.verify(check: { nil },
            repair: { XCTFail("Unnecessary repair") }, now: { 0 },
            wait: { _ in XCTFail("Unnecessary wait") }))
    }

    func testStalledInvalidAndOvershootingClocksCannotExtendBudget() {
        var repairs = 0
        XCTAssertEqual(LockedUseShieldRepair.verify(check: { self.mismatch },
            repair: { repairs += 1 }, now: { 0 }, wait: { _ in }), mismatch)
        XCTAssertEqual(repairs, 20)
        for invalid in [Double.nan, .infinity, -1] {
            XCTAssertEqual(LockedUseShieldRepair.verify(check: { self.mismatch },
                repair: { XCTFail("Invalid clock") }, now: { invalid }, wait: { _ in }), mismatch)
        }
        var time = 0.0
        var reads = 0
        XCTAssertEqual(LockedUseShieldRepair.verify(check: {
            reads += 1
            return reads == 1 ? self.mismatch : nil
        }, repair: {}, now: { time }, wait: { _ in time = 1 }), mismatch)
        XCTAssertEqual(reads, 1) // Late recovery cannot authorize coverage.
    }

    func testPersistentMismatchRequestsRelock() throws {
        let session = LockedUseSession(state: .unlocked, userID: 501, auditSessionID: 42)
        var policy = try LockedUseGuardianPolicy(session: session, now: 100)
        try policy.prepared(topology: "display-1", now: 100)
        var time = 100.0
        let failure = LockedUseShieldRepair.verify(check: { self.mismatch }, repair: {},
            now: { time }, wait: { time += $0 })
        XCTAssertEqual(try policy.poll(session: session, topology: "display-1",
            guardsHealthy: failure == nil, now: time), [.requestRelock])
        XCTAssertEqual(policy.phase, .relocking)
        XCTAssertEqual(policy.reason, .guardianFailure)
    }

    func testRecoveryBudgetResetsOnlyForAnotherVerifiedHealthCheck() {
        for _ in 0..<2 {
            var reads = 0
            var time = 0.0
            XCTAssertNil(LockedUseShieldRepair.verify(check: {
                reads += 1
                return reads == 1 ? self.mismatch : nil
            }, repair: {}, now: { time }, wait: { time += $0 }))
            XCTAssertEqual(reads, 2)
        }
    }
}
