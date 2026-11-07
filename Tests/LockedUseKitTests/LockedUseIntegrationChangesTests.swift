import CoreGraphics
import Foundation
@testable import LockedUseKit
import XCTest

final class LockedUseIntegrationChangesTests: XCTestCase {
    private let owner = LockedUseBrokerCoordinator.Context(id: UUID(), role: .agent, userID: 501, auditSessionID: 42)
    private let unlocked = LockedUseSession(state: .unlocked, userID: 501, auditSessionID: 42)

    private func recovered(guardian: LockedUseBrokerCoordinator.Context? = nil) -> LockedUseBrokerCoordinator {
        let record = LockedUseRecoveryRecord(leaseID: UUID(), owner: owner, originalClientToken: Data(repeating: 1, count: 32), guardian: guardian, watchdog: nil, watchdogChallenge: nil, everGranted: false, observedUnlocked: false, agentDrained: true, fullyReleased: guardian == nil)
        return .init(enabled: true, backendValidated: true, recovery: record)
    }

    func testConsoleManualUnlockResetsWithoutStatusRPCAndAllowsNextLock() throws {
        var broker = recovered()
        XCTAssertEqual(broker.phase, .awaitingManualUnlock)
        try broker.observeConsoleManualUnlock(session: unlocked, now: 10)
        XCTAssertEqual(broker.phase, .idle)
        let next = try broker.handle(.init(operation: .begin, session: .init(state: .locked, userID: 501, auditSessionID: 42)), context: owner, now: 11)
        XCTAssertEqual(next.phase, .preparing)
        XCTAssertNil(next.stopReason)
    }

    func testConsoleUnlockRejectsWrongSessionUnknownAndLockedObservations() throws {
        for session in [LockedUseSession(state: .unlocked, userID: 502, auditSessionID: 42),
                        .init(state: .unlocked, userID: 501, auditSessionID: 43),
                        .init(state: .locked, userID: 501, auditSessionID: 42),
                        .init(state: .unavailable, userID: 501, auditSessionID: 42)] {
            var broker = recovered()
            XCTAssertThrowsError(try broker.observeConsoleManualUnlock(session: session, now: 10))
            XCTAssertEqual(broker.phase, .awaitingManualUnlock)
        }
    }

    func testConsoleObservationCannotBypassUnreleasedGuardsOrActivePermit() throws {
        let guardian = LockedUseBrokerCoordinator.Context(id: UUID(), role: .guardian, userID: 501, auditSessionID: 42)
        var broker = recovered(guardian: guardian)
        XCTAssertFalse(broker.isFullyReleased)
        XCTAssertThrowsError(try broker.observeConsoleManualUnlock(session: unlocked, now: 10))
        var fresh = LockedUseBrokerCoordinator(enabled: true, backendValidated: true)
        _ = try fresh.handle(.init(operation: .begin, session: .init(state: .locked, userID: 501, auditSessionID: 42)), context: owner, now: 1)
        XCTAssertThrowsError(try fresh.observeConsoleManualUnlock(session: unlocked, now: 2))
        XCTAssertEqual(fresh.phase, .preparing)
    }

    func testConsoleSessionPropertiesRequireExactIDsAndRealBooleans() {
        let dictionary: [String: Any] = ["kCGSSessionUserIDKey": UInt32(501), "kCGSSessionAuditIDKey": UInt32(42), "kCGSessionOnConsoleKey": true, "kCGSessionLoginDoneKey": true]
        func parse(_ dict: [String: Any]) -> LockedUseSession? {
            LockedUseSession.consoleSession(in: [dict], userID: 501, auditSessionID: 42)
        }
        XCTAssertEqual(parse(dictionary), unlocked)
        var alternate = dictionary
        alternate.removeValue(forKey: "kCGSessionOnConsoleKey")
        alternate["kCGSSessionOnConsoleKey"] = true
        XCTAssertEqual(parse(alternate), unlocked)
        let malformedValues: [(String, Any)] = [("kCGSSessionUserIDKey", UInt32(502)), ("kCGSSessionAuditIDKey", UInt32(43)), ("kCGSessionOnConsoleKey", NSNumber(value: 1)), ("kCGSessionLoginDoneKey", false), ("CGSSessionScreenIsLocked", NSNumber(value: 0))]
        for (key, value) in malformedValues {
            var malformed = dictionary; malformed[key] = value
            XCTAssertNil(parse(malformed), key)
        }
        var locked = dictionary; locked["CGSSessionScreenIsLocked"] = true
        XCTAssertEqual(parse(locked)?.state, .locked)
    }

    func testDeterministicExitCodesAndHolderStopReasonRoundTrip() throws {
        let cases: [(LockedUseError, Int32)] = [
            (.usage("bad arguments"), 64), (.stateUnavailable("missing permission"), 77),
            (.stopped(reason: .physicalInput, awaitingManualUnlock: false), 75),
            (.stopped(reason: .guardLost, awaitingManualUnlock: true), 75),
            (.stopped(reason: .guardLost, awaitingManualUnlock: false), 75),
            (.stopped(reason: .sessionChanged, awaitingManualUnlock: false), 75),
            (.stopped(reason: nil, awaitingManualUnlock: true), 75),
            (.stopped(reason: .leaseExpired, awaitingManualUnlock: false), 76),
            (.stopped(reason: .idleTimeout, awaitingManualUnlock: false), 76),
            (.stopped(reason: .turnEnded, awaitingManualUnlock: false), 76)]
        for (error, expected) in cases { XCTAssertEqual(error.exitCode, expected) }
        let reply = LockedUseHolderReply(ok: false, error: "takeover", stopReason: .physicalInput, awaitingManualUnlock: true, exitCode: 75)
        XCTAssertEqual(try JSONDecoder().decode(LockedUseHolderReply.self, from: JSONEncoder().encode(reply)), reply)
        let brokerReply = LockedUseIPCReply(id: UUID(), result: .denied, phase: .relocking, stopReason: .leaseExpired)
        XCTAssertEqual(try JSONDecoder().decode(LockedUseIPCReply.self, from: JSONEncoder().encode(brokerReply)).stopReason, .leaseExpired)
    }

    func testGUIParserCoordinatesTargetsAndRejections() throws {
        let click = try LockedUseGUICommand.parse(["click", "--app", "TextEdit", "--x", "12.5", "--y", "20", "--pixel", "--double", "--require-locked"])
        XCTAssertFalse(click.screen)
        XCTAssertTrue(click.pixel)
        XCTAssertEqual(click.x, 12.5)
        XCTAssertTrue(click.doubleClick)
        XCTAssertTrue(click.requireLocked)
        XCTAssertEqual(try LockedUseGUICommand.parse(["click", "--pid", "123", "--x", "1", "--y", "2", "--screen"]).pid, 123)
        XCTAssertEqual(try LockedUseGUICommand.parse(["capture", "--window-id", "42", "--out", "/tmp/window.png"]).windowID, 42)
        XCTAssertEqual(try LockedUseGUICommand.parse(["type", "--app", "TextEdit", "--text", ""]).text, "")
        for args in [["click", "--app", "A", "--x", "nan", "--y", "2"],
                     ["click", "--app", "A", "--x", "1", "--y", "2", "--screen", "--window-local"],
                     ["click", "--app", "A", "--x", "1", "--y", "2", "--screen", "--pixel"],
                     ["type", "--pid", "0", "--text", "x"], ["type", "--app", "A", "--key", "Return"],
                     ["capture", "--app", "A"], ["key", "--app", "A", "--key", "bad+Return"],
                     ["capture", "--window-id", "1", "--out", "a", "--out", "b"]] {
            XCTAssertThrowsError(try LockedUseGUICommand.parse(args), args.joined(separator: " "))
        }
    }

    func testInputRecipesAreTargetAddressedAndPreserveUnicode() throws {
        XCTAssertEqual(try skyClickEventRecipe(clickCount: 1).count, 5)
        XCTAssertEqual(try skyClickEventRecipe(clickCount: 2).count, 7)
        XCTAssertThrowsError(try skyClickEventRecipe(clickCount: 3))
        let records = skyLightKeyWindowRecords(windowID: 0x12345678)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Array(records[0][0x3C...0x3F]), [0x78, 0x56, 0x34, 0x12])
        let text = "Hello 🌍 你好 👨‍👩‍👧‍👦"
        let chunks = LockedUseKeyboardEvents.keyboardUnicodeChunks(for: text)
        XCTAssertEqual(String(decoding: chunks.flatMap { $0 }, as: UTF16.self), text)
        XCTAssertNotNil(skyMenuKeyEquivalent(for: try LockedUseKeyPressParser.parse("cmd+v")))
        XCTAssertNil(skyMenuKeyEquivalent(for: try LockedUseKeyPressParser.parse("Return")))
    }
}
