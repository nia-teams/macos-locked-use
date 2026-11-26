import Foundation
import XCTest
@testable import LockedUseKit

final class LockedUseHostProcessFilterTests: XCTestCase {
    private typealias Filter = LockedUseHostProcessFilter
    private let session = LockedUseSession(state: .unlocked, userID: 501, auditSessionID: 77)
    private let hostID = "com.example.enrolled-host"
    private let team = "EXAMPLE123"
    private let helperPath = "/Applications/Enrolled Host.app/Contents/Resources/device-bridge-daemon"
    private let unsignedMemory = "com.apple.security.cs.allow-unsigned-executable-memory"

    private func snapshot(_ ppid: Int32 = 1, uid: UInt32 = 501, sec: Int = 100, usec: Int32 = 12,
                          path: String? = nil) -> Filter.ProcessSnapshot {
        .init(euid: uid, ppid: ppid, startSec: sec, startUsec: usec, executablePath: path)
    }

    private func approval(role: LockedUseClientApprovals.Role = .agent, uid: UInt32 = 501) throws -> LockedUseClientApprovals.Approval {
        try .init(userID: uid, role: role, signingIdentifier: hostID, teamIdentifier: team)
    }

    private func hostEvidence(entitlements: [String: Any] = [:], hardened: Bool = true) throws -> Filter.SigningEvidence {
        let expected = try approval().requirement()
        return .init(identifier: hostID, hardenedRuntime: hardened, entitlements: entitlements,
                     satisfiesRequirement: { $0 == expected })
    }

    private func makeFilter(inspect: @escaping (Int32) -> Filter.ProcessSnapshot?,
                            signing: @escaping (Int32) -> Filter.SigningEvidence?,
                            bundle: @escaping (URL, String, String) -> Bool = { _, _, _ in false }) throws -> Filter {
        try .init(approvals: .init(approvals: [approval()]), userID: session.userID, inspect: inspect,
                  signingEvidence: signing, bundleSatisfiesRequirement: bundle)
    }

    private func admits(_ pid: Int32, _ filter: inout Filter) -> Bool {
        filter.accepts(sourcePID: pid, session: session, currentSession: session, stopping: false)
    }

    func testReservedPIDsAndInvalidSessionDoNotInspectProcesses() throws {
        var filter = try makeFilter(inspect: { _ in XCTFail("Unexpected process inspection"); return nil }, signing: { _ in nil })
        for pid in [Int32(-5), 0, 1] { XCTAssertFalse(admits(pid, &filter)) }
        for invalid in [LockedUseSession(state: .locked, userID: 501, auditSessionID: 77),
                        .init(state: .unavailable, userID: 501, auditSessionID: 77),
                        .init(state: .unlocked, userID: 502, auditSessionID: 77),
                        .init(state: .unlocked, userID: 501, auditSessionID: 78)] {
            XCTAssertFalse(filter.accepts(sourcePID: 42, session: session, currentSession: invalid, stopping: false))
        }
        for invalid in [LockedUseSession(state: .unlocked, userID: 0, auditSessionID: 77),
                        .init(state: .unlocked, userID: 501, auditSessionID: 0),
                        .init(state: .unlocked, userID: nil, auditSessionID: 77),
                        .init(state: .unlocked, userID: 501, auditSessionID: nil),
                        .init(state: .locked, userID: 501, auditSessionID: 77)] {
            XCTAssertFalse(filter.accepts(sourcePID: 42, session: invalid, currentSession: invalid, stopping: false))
        }
        XCTAssertFalse(filter.accepts(sourcePID: 42, session: session, currentSession: session, stopping: true))
    }

    func testDirectAgentAndItsShellAndOsascriptDescendantsAreAdmitted() throws {
        let chain = [Int32(30): snapshot(), 31: snapshot(30), 32: snapshot(31)]
        let host = try hostEvidence()
        var filter = try makeFilter(inspect: { chain[$0] }, signing: { $0 == 30 ? host : nil })
        XCTAssertTrue(admits(30, &filter))
        XCTAssertTrue(admits(31, &filter))
        XCTAssertTrue(admits(32, &filter))
    }

    func testOnlyAgentApprovalForLeaseUIDIsUsed() throws {
        let approvals = try LockedUseClientApprovals(approvals: [approval(role: .client), approval(uid: 502)])
        var filter = Filter(approvals: approvals, userID: session.userID, inspect: { _ in
            XCTFail("No matching .agent approval"); return nil
        }, signingEvidence: { _ in nil })
        XCTAssertFalse(admits(30, &filter))
    }

    func testReparentedBundledHelperRequiresTeamAndEnclosingHostBundle() throws {
        let hostRequirement = try approval().requirement()
        let teamRequirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        for (path, sameTeam, isHostBundle, expected) in [
            (helperPath, true, true, true),
            (helperPath, true, false, false),
            (helperPath, false, true, false),
            ("/tmp/Enrolled Host.app/ContentsX/device-bridge-daemon", true, true, false),
            ("/tmp/Enrolled Host.app/Contents/../device-bridge-daemon", true, true, false),
        ] {
            let chain = [Int32(40): snapshot(path: path), 41: snapshot(40), 42: snapshot(41)]
            let helper = Filter.SigningEvidence(identifier: "com.example.helper", hardenedRuntime: true,
                                                 entitlements: [unsignedMemory: true],
                                                 satisfiesRequirement: { sameTeam && $0 == teamRequirement })
            var bundleChecks = 0
            var filter = try makeFilter(inspect: { chain[$0] }, signing: { $0 == 40 ? helper : nil }, bundle: { url, executablePath, req in
                bundleChecks += 1
                XCTAssertEqual(url.path, "/Applications/Enrolled Host.app")
                XCTAssertEqual(executablePath, path)
                XCTAssertEqual(req, hostRequirement)
                return isHostBundle
            })
            XCTAssertEqual(admits(42, &filter), expected)
            XCTAssertEqual(bundleChecks, path == helperPath && sameTeam ? 1 : 0)
        }
    }

    func testDirectRootNeedsHardenedRuntimeAndNoInjectionEntitlements() throws {
        let forbidden = ["com.apple.security.get-task-allow", "get-task-allow", "com.apple.security.cs.disable-library-validation",
                         "com.apple.security.cs.allow-dyld-environment-variables", unsignedMemory]
        for entitlement in forbidden {
            let host = try hostEvidence(entitlements: [entitlement: true])
            let process = snapshot()
            var filter = try makeFilter(inspect: { _ in process }, signing: { _ in host })
            XCTAssertFalse(admits(30, &filter), entitlement)
        }
        let host = try hostEvidence(hardened: false)
        let process = snapshot()
        var filter = try makeFilter(inspect: { _ in process }, signing: { _ in host })
        XCTAssertFalse(admits(30, &filter))
    }

    func testExternalRemapperAndMissingProcessAreRejected() throws {
        let external = Filter.SigningEvidence(identifier: "com.example.remapper", hardenedRuntime: true, entitlements: [:],
                                              satisfiesRequirement: { _ in false })
        let process = snapshot(path: "/Applications/Remapper.app/Contents/MacOS/Remapper")
        var filter = try makeFilter(inspect: { $0 == 50 ? process : nil }, signing: { _ in external })
        XCTAssertFalse(admits(50, &filter))
        XCTAssertFalse(admits(51, &filter))
    }

    func testUIDBoundaryStopsAncestryWalk() throws {
        let chain = [Int32(30): snapshot(), 31: snapshot(30, uid: 502), 32: snapshot(31)]
        var inspected: [Int32] = []
        var filter = try makeFilter(inspect: { inspected.append($0); return chain[$0] }, signing: { _ in nil })
        XCTAssertFalse(admits(32, &filter))
        XCTAssertEqual(inspected, [32, 31])
    }

    func testCycleAndSixteenHopLimit() throws {
        var inspected: [Int32] = []
        let cycle = [Int32(81): snapshot(82), 82: snapshot(81)]
        var filter = try makeFilter(inspect: { inspected.append($0); return cycle[$0] }, signing: { _ in nil })
        XCTAssertFalse(admits(81, &filter))
        XCTAssertEqual(inspected, [81, 82])

        inspected.removeAll()
        let chain = Dictionary(uniqueKeysWithValues: (Int32(30)...46).map { ($0, snapshot($0 - 1)) })
        let host = try hostEvidence()
        filter = try makeFilter(inspect: { inspected.append($0); return chain[$0] }, signing: { $0 == 30 ? host : nil })
        XCTAssertFalse(admits(46, &filter))
        XCTAssertEqual(inspected, Array((Int32(31)...46).reversed()))
        XCTAssertTrue(admits(45, &filter)) // 16th candidate, including the source PID.
    }

    func testGuardianRejectionStopsWalkAndIsCached() throws {
        let chain = [Int32(30): snapshot(), 31: snapshot(30)]
        let guardian = Filter.SigningEvidence(identifier: "com.nia-teams.locked-use.guardian", hardenedRuntime: true, entitlements: [:],
                                               satisfiesRequirement: { _ in true })
        var evaluated: [Int32] = []
        var filter = try makeFilter(inspect: { chain[$0] }, signing: { evaluated.append($0); return guardian })
        XCTAssertFalse(admits(31, &filter))
        XCTAssertFalse(admits(31, &filter))
        XCTAssertEqual(evaluated, [31])
    }

    func testFiftyScrollEventsUseOneSigningEvaluationAndReusedPIDMisses() throws {
        var process = snapshot()
        let host = try hostEvidence()
        var evaluated = 0
        var filter = try makeFilter(inspect: { _ in process }, signing: { _ in
            evaluated += 1; return evaluated == 1 ? host : nil
        })
        for _ in 0..<50 { XCTAssertTrue(admits(30, &filter)) }
        XCTAssertEqual(evaluated, 1)
        process = snapshot(usec: 13)
        XCTAssertFalse(admits(30, &filter))
        XCTAssertEqual(evaluated, 2)
    }

    func testCachedDescendantChainIsRejectedAfterAncestorOrLeafPIDReuse() throws {
        let host = try hostEvidence()
        for (reusedPID, newSnapshot) in [(Int32(30), snapshot(sec: 105, usec: 0)),
                                         (Int32(32), snapshot(sec: 106, usec: 0))] {
            var chain = [Int32(30): snapshot(), 31: snapshot(30, sec: 101, usec: 0), 32: snapshot(31, sec: 102, usec: 0)]
            var evaluated: [Int32] = []
            var filter = try makeFilter(inspect: { chain[$0] }, signing: { pid in
                evaluated.append(pid)
                return pid == 30 && chain[pid]?.startSec == 100 ? host : nil
            })
            XCTAssertTrue(admits(32, &filter))
            XCTAssertTrue(admits(32, &filter))
            XCTAssertEqual(evaluated, [32, 31, 30])
            chain[reusedPID] = newSnapshot
            XCTAssertFalse(admits(32, &filter), "Reused PID \(reusedPID)")
            XCTAssertEqual(evaluated, [32, 31, 30, reusedPID])
        }
    }

    func testApprovalDuringProcessExitOrReuseFailsClosedAndIsNotCached() throws {
        let host = try hostEvidence()
        let original = snapshot()
        for changed in [nil, snapshot(sec: 101), snapshot(usec: 13), snapshot(uid: 502)] {
            var evaluated = 0
            var inspected = 0
            var filter = try makeFilter(inspect: { _ in
                inspected += 1
                return inspected == 2 ? changed : original
            }, signing: { _ in evaluated += 1; return host })
            XCTAssertFalse(admits(30, &filter))
            XCTAssertTrue(admits(30, &filter))
            XCTAssertEqual(evaluated, 2)
        }
    }

    func testCacheEvictsAtCapacity() throws {
        let host = try hostEvidence()
        let process = snapshot()
        var evaluated = 0
        var filter = try makeFilter(inspect: { _ in process }, signing: { _ in evaluated += 1; return host })
        for pid in Int32(2)...258 { XCTAssertTrue(admits(pid, &filter)) }
        XCTAssertTrue(admits(2, &filter))
        XCTAssertEqual(evaluated, 258)
    }
}
