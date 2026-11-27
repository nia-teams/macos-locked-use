import LockedUseKit
import XCTest

final class LockedUseSyntheticInputAdmissionTests: XCTestCase {
    private let initial = LockedUseSession(state: .locked, userID: 501, auditSessionID: 42)
    private let unlocked = LockedUseSession(state: .unlocked, userID: 501, auditSessionID: 42)
    private let guardianPID: Int32 = 100
    private let watchdogPID: Int32 = 101

    private func admits(
        sourcePID: Int64 = 123,
        session: LockedUseSession? = nil,
        current: LockedUseSession? = nil,
        lease: Bool = true,
        stopping: Bool = false,
        activity: Bool = false,
        healthy: Bool = true,
        guardianPID: Int32? = nil,
        watchdogPID: Int32? = nil
    ) -> Bool {
        (session ?? initial).admitsSyntheticInput(
            sourcePID: sourcePID, currentSession: current ?? unlocked,
            brokerLeaseActive: lease, stopping: stopping, physicalActivityDetected: activity,
            physicalMonitorHealthy: healthy, guardianPID: guardianPID ?? self.guardianPID,
            watchdogPID: watchdogPID ?? self.watchdogPID
        )
    }

    func testAdmitsArbitraryUserSpacePIDsWithoutProcessLookup() {
        let reparentedBackgroundPID: Int64 = 45_678
        let exitedSenderPID: Int64 = 99_999
        for pid in [2, 123, reparentedBackgroundPID, exitedSenderPID, Int64(Int32.max) + 1, Int64.max] {
            XCTAssertTrue(admits(sourcePID: pid), "PID \(pid)")
        }
    }

    func testRejectsHardwareAndSystemPIDs() {
        for pid in [-1, 0, 1] as [Int64] {
            XCTAssertFalse(admits(sourcePID: pid), "PID \(pid)")
        }
    }

    func testGuardPIDsRequireOneShotAllowances() {
        XCTAssertFalse(admits(sourcePID: Int64(guardianPID)))
        XCTAssertFalse(admits(sourcePID: Int64(watchdogPID)))
    }

    func testRejectsMissingOrReservedGuardPIDs() {
        for pid in [-1, 0, 1] as [Int32] {
            XCTAssertFalse(admits(guardianPID: pid), "Guardian PID \(pid)")
            XCTAssertFalse(admits(watchdogPID: pid), "Watchdog PID \(pid)")
        }
    }

    func testPhysicalLatchRejectsRemappedSyntheticInput() {
        XCTAssertFalse(admits(sourcePID: 42_123, activity: true))
    }

    func testRejectsUnhealthyStoppingOrRehearsal() {
        XCTAssertFalse(admits(healthy: false))
        XCTAssertFalse(admits(stopping: true))
        XCTAssertFalse(admits(lease: false))
    }

    func testRejectsLockedUnavailableOrDifferentSession() {
        for session in [initial, .init(state: .unavailable, userID: 501, auditSessionID: 42),
                        .init(state: .unlocked, userID: 502, auditSessionID: 42),
                        .init(state: .unlocked, userID: 501, auditSessionID: 43)] {
            XCTAssertFalse(admits(current: session), "Session \(session)")
        }
    }

    func testRejectsMissingOrZeroPinnedIdentityEvenIfSessionsMatch() {
        for (uid, auditID) in [(nil as UInt32?, 42 as UInt32?), (0, 42), (501, nil), (501, 0)] {
            let invalid = LockedUseSession(state: .unlocked, userID: uid, auditSessionID: auditID)
            XCTAssertFalse(admits(session: invalid, current: invalid))
        }
    }
}
