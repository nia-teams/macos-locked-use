import AppKit
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

    func testClickButtonParserDefaultsValuesAndRejections() throws {
        let base = ["click", "--app", "WeChat", "--x", "12", "--y", "20"]
        XCTAssertEqual(try LockedUseGUICommand.parse(base).button, .left)
        for button in [LockedUseMouseButton.left, .right] {
            let click = try LockedUseGUICommand.parse(base + ["--button", button.rawValue, "--pixel", "--double", "--require-locked"])
            XCTAssertEqual(click.button, button)
            XCTAssertTrue(click.pixel)
            XCTAssertTrue(click.doubleClick)
            XCTAssertTrue(click.requireLocked)
        }
        for suffix in [["--button"], ["--button", ""], ["--button", "middle"],
                       ["--button", "Right"], ["--button", "--double"],
                       ["--button", "right", "--button", "left"]] {
            XCTAssertThrowsError(try LockedUseGUICommand.parse(base + suffix)) { error in
                XCTAssertEqual((error as? LockedUseError)?.exitCode, 64)
            }
        }
        for args in [["capture", "--out", "/tmp/window.png"], ["type", "--text", "hello"], ["key", "--key", "Return"]] {
            XCTAssertThrowsError(try LockedUseGUICommand.parse(args + ["--app", "WeChat", "--button", "right"]))
        }
    }

    func testClickButtonCocoaEventEncoding() throws {
        for button in [LockedUseMouseButton.left, .right] {
            for includePrimer in [true, false] {
                for count in 1...2 {
                    let recipe = try skyClickEventRecipe(clickCount: count, button: button, includePrimer: includePrimer)
                    XCTAssertEqual(recipe.count, 1 + 2 * count + (button == .left && includePrimer ? 2 : 0))
                    XCTAssertEqual(recipe.filter { $0.pointKind == .primer }.count, button == .left && includePrimer ? 2 : 0)
                    XCTAssertEqual(recipe.first?.kind, .moved)
                    XCTAssertEqual(recipe.first?.pointKind, .target)
                    for step in recipe {
                        let mouseButton: CGMouseButton = step.kind == .moved ? .left : button.cgMouseButton
                        XCTAssertEqual(mouseButton, step.kind == .moved || button == .left ? .left : .right)
                        let event = try XCTUnwrap(CGEvent(mouseEventSource: nil,
                            mouseType: step.kind.cgEventType(button: button),
                            mouseCursorPosition: CGPoint(x: 12, y: 20), mouseButton: mouseButton))
                        let expected: CGEventType = step.kind == .moved ? .mouseMoved :
                            (step.kind == .down ? (button == .right ? .rightMouseDown : .leftMouseDown) :
                                (button == .right ? .rightMouseUp : .leftMouseUp))
                        XCTAssertEqual(event.type, expected)
                        let buttonNumber: Int64 = step.kind == .moved || button == .left ? 0 : 1
                        XCTAssertEqual(event.getIntegerValueField(.mouseEventButtonNumber), buttonNumber)
                        let cocoa = try XCTUnwrap(NSEvent(cgEvent: event))
                        XCTAssertEqual(cocoa.type.rawValue, UInt(expected.rawValue))
                        XCTAssertEqual(cocoa.buttonNumber, Int(buttonNumber))
                    }
                }
            }
        }
    }

    func testClickButtonChromiumStampEncodingWithoutPosting() throws {
        let spi = LockedUseInputSPI.shared
        guard spi.capability.isAvailable else { throw XCTSkip(spi.capability.unavailableReason) }
        let target = SkyClickTarget(screenPoint: CGPoint(x: 112, y: 120), windowPoint: CGPoint(x: 12, y: 20),
            windowBounds: CGRect(x: 100, y: 100, width: 400, height: 300), windowID: 65654, pid: 123)
        for button in [LockedUseMouseButton.left, .right] {
            for includePrimer in [true, false] {
                for count in 1...2 {
                    let recipe = try skyClickEventRecipe(clickCount: count, button: button, includePrimer: includePrimer)
                    XCTAssertEqual(recipe.count, 1 + 2 * count + (button == .left && includePrimer ? 2 : 0))
                    for step in recipe {
                        let screenPoint = step.pointKind == .target ? target.screenPoint : CGPoint(x: -1, y: -1)
                        let windowPoint = step.pointKind == .target ? target.windowPoint : CGPoint(x: -1, y: -1)
                        let event = try XCTUnwrap(CGEvent(mouseEventSource: nil,
                            mouseType: step.kind.cgEventType(button: button),
                            mouseCursorPosition: screenPoint, mouseButton: step.kind == .moved ? .left : button.cgMouseButton))
                        // Encoding only: no input is posted and no Broker lease is needed.
                        try LockedUseActionScope.withValidator({}) {
                            try LockedUseClickDispatcher.stamp(event, target: target, windowPoint: windowPoint,
                                clickState: step.clickState, phase: step.phase, button: button, clickGroupID: 1234, spi: spi)
                        }
                        XCTAssertEqual(event.type, step.kind.cgEventType(button: button))
                        let buttonNumber: Int64 = step.kind == .moved || button == .left ? 0 : 1
                        XCTAssertEqual(event.getIntegerValueField(.mouseEventButtonNumber), buttonNumber)
                        XCTAssertEqual(event.getIntegerValueField(.mouseEventClickState), step.clickState)
                        XCTAssertEqual(event.getIntegerValueField(.eventTargetUnixProcessID), 123)
                        for field in [CGEventField.mouseEventWindowUnderMousePointer, .mouseEventWindowUnderMousePointerThatCanHandleThisEvent] {
                            XCTAssertEqual(event.getIntegerValueField(field), Int64(target.windowID))
                        }
                    }
                }
            }
        }
    }

    func testSameAppPopupResolution() throws {
        let pid: pid_t = 123
        let base = CGRect(x: 100, y: 100, width: 400, height: 300)
        let popup = CGRect(x: 140, y: 350, width: 160, height: 120)
        let topPopup = CGRect(x: 150, y: 360, width: 100, height: 100)
        func info(_ id: CGWindowID, owner: pid_t = 123, bounds: CGRect,
                  layer: Int = 1, title: String = "", alpha: Double = 1) -> [String: Any] {
            [kCGWindowNumber as String: NSNumber(value: id),
             kCGWindowOwnerPID as String: NSNumber(value: owner),
             kCGWindowBounds as String: bounds.dictionaryRepresentation,
             kCGWindowLayer as String: NSNumber(value: layer),
             kCGWindowName as String: title,
             kCGWindowAlpha as String: NSNumber(value: alpha)]
        }
        let baseInfo = info(42, bounds: base, layer: 0, title: "Document")
        let windows = [
            info(90, owner: 999, bounds: topPopup),
            info(91, bounds: topPopup, alpha: 0),
            info(92, bounds: topPopup, layer: Int(CGShieldingWindowLevel())),
            info(93, bounds: topPopup, layer: 0, title: "Other document"),
            info(94, bounds: topPopup, layer: -1),
            info(95, bounds: CGRect(x: 150, y: 360, width: 1, height: 100)),
            info(44, bounds: topPopup, layer: 0, title: " \n"),
            info(43, bounds: popup, layer: 101, title: "Context menu"),
            baseInfo,
            info(45, bounds: topPopup),
        ]
        let popups = sameAppPopupsAbove(windowInfo: windows, pid: pid, baseWindowID: 42)
        XCTAssertEqual(popups.map(\.windowID), [44, 43])
        XCTAssertEqual(popups.map(\.pid), [pid, pid])
        XCTAssertEqual(popups.map(\.bounds), [topPopup, popup])
        XCTAssertTrue(sameAppPopupsAbove(windowInfo: windows, pid: pid, baseWindowID: 404).isEmpty)
        XCTAssertTrue(sameAppPopupsAbove(windowInfo: [baseInfo] + windows, pid: pid, baseWindowID: 42).isEmpty)
        XCTAssertTrue(sameAppPopupsAbove(windowInfo: [], pid: pid, baseWindowID: 42).isEmpty)
        XCTAssertTrue(sameAppPopupsAbove(windowInfo: windows, pid: pid, baseWindowID: 42, shieldLevel: 0).isEmpty)
        var untitled = info(46, bounds: topPopup, layer: 0)
        untitled.removeValue(forKey: kCGWindowAlpha as String)
        untitled.removeValue(forKey: kCGWindowName as String)
        XCTAssertEqual(sameAppPopupsAbove(windowInfo: [untitled, baseInfo], pid: pid, baseWindowID: 42).map(\.windowID), [46])

        // This point is below the base window but inside both covering popups.
        let target = SkyClickTarget(screenPoint: CGPoint(x: 170, y: 430), windowPoint: CGPoint(x: 70, y: 330),
            windowBounds: base, windowID: 42, pid: pid)
        XCTAssertFalse(CGRect(origin: .zero, size: base.size).contains(target.windowPoint))
        let resolved = resolveSkyClickTarget(target, onScreenWindowInfo: windows)
        XCTAssertEqual(resolved.windowID, 44)
        XCTAssertEqual(resolved.pid, pid)
        XCTAssertEqual(resolved.screenPoint, target.screenPoint)
        XCTAssertEqual(resolved.windowPoint, CGPoint(x: 20, y: 70))
        XCTAssertEqual(resolved.windowBounds, topPopup)
        XCTAssertTrue(CGRect(origin: .zero, size: resolved.windowBounds.size).contains(resolved.windowPoint))
        let uncovered = SkyClickTarget(screenPoint: CGPoint(x: 110, y: 110), windowPoint: CGPoint(x: 10, y: 10),
            windowBounds: base, windowID: 42, pid: pid)
        let unchanged = resolveSkyClickTarget(uncovered, onScreenWindowInfo: windows)
        XCTAssertEqual(unchanged.windowID, 42)
        XCTAssertEqual(unchanged.windowBounds, base)
        XCTAssertEqual(unchanged.screenPoint, uncovered.screenPoint)
        XCTAssertEqual(unchanged.windowPoint, uncovered.windowPoint)
        let onlyIgnored = Array(windows.prefix(6)) + [baseInfo, info(45, bounds: topPopup)]
        XCTAssertEqual(resolveSkyClickTarget(target, onScreenWindowInfo: onlyIgnored).windowID, 42)

    }

    func testPopupClickRecipePreservesTrackingAndExistingTiming() throws {
        for button in [LockedUseMouseButton.left, .right] {
            for count in 1...2 {
                let recipe = try skyClickEventRecipe(clickCount: count, button: button, includePrimer: false)
                XCTAssertEqual(recipe.count, 1 + 2 * count)
                XCTAssertTrue(recipe.allSatisfy { $0.pointKind == .target })
                XCTAssertEqual(recipe.map(\.kind), count == 1 ? [.moved, .down, .up] : [.moved, .down, .up, .down, .up])
                // Keep the existing 15ms move settle; do not send an off-menu
                // (-1, -1) primer or add speculative menu-specific timing.
                XCTAssertEqual(recipe.first?.delayAfter, 0.015)
                XCTAssertEqual(recipe.last?.delayAfter, 0)
                XCTAssertEqual(recipe.filter { $0.kind == .down }.map(\.clickState), count == 1 ? [1] : [1, 2])
                XCTAssertEqual(recipe.filter { $0.kind == .up }.map(\.delayAfter), count == 1 ? [0] : [0.080, 0])
            }
        }
        XCTAssertThrowsError(try skyClickEventRecipe(clickCount: 0, includePrimer: false))
        XCTAssertThrowsError(try skyClickEventRecipe(clickCount: 3, includePrimer: false))
    }

    func testPopupFocusCleanupResolvesWithoutPostingActivation() throws {
        let spi = LockedUseInputSPI.shared
        guard spi.capability.isAvailable else { throw XCTSkip(spi.capability.unavailableReason) }
        // Resolution alone needs no action scope and posts no activation. The
        // original base ID, not the popup ID, releases focus retained by the
        // earlier right-click even when it ran in a different CLI process.
        let context = try spi.syntheticTargetFocusContext(
            targetPID: ProcessInfo.processInfo.processIdentifier, targetWindowID: 0x12345678)
        XCTAssertEqual(context.deactivateTarget.windowID, 0x12345678)
        XCTAssertEqual(context.deactivateTarget.psn.count, 8)
        XCTAssertFalse(context.deactivateTarget.focused)
        let record = skyLightActivationRecord(windowID: context.deactivateTarget.windowID,
            focused: context.deactivateTarget.focused)
        XCTAssertEqual(record.count, 0xF8)
        XCTAssertEqual(record[0x04], 0xF8)
        XCTAssertEqual(record[0x08], 0x0D)
        XCTAssertEqual(Array(record[0x3C...0x3F]), [0x78, 0x56, 0x34, 0x12])
        XCTAssertEqual(record[0x8A], 0x02)
    }

    func testPopupMenuPressEligibilityAndInjectedOutcomes() throws {
        let target = SkyClickTarget(screenPoint: CGPoint(x: 210, y: 183), windowPoint: CGPoint(x: 30, y: 45),
            windowBounds: CGRect(x: 180, y: 138, width: 160, height: 120), windowID: 65848, pid: 123)
        for isPopup in [false, true] {
            for button in [LockedUseMouseButton.left, .right] {
                for count in 1...2 {
                    for succeeds in [false, true] {
                        var calls = 0
                        let pressed = try LockedUseActionScope.withValidator({}) {
                            try LockedUseClickDispatcher.pressPopupMenuItem(target: target,
                                isPopupTarget: isPopup, button: button, clickCount: count) { pid, point in
                                calls += 1
                                XCTAssertEqual(pid, target.pid)
                                XCTAssertEqual(point, target.screenPoint)
                                return succeeds
                            }
                        }
                        let eligible = isPopup && button == .left && count == 1
                        XCTAssertEqual(calls, eligible ? 1 : 0)
                        XCTAssertEqual(pressed, eligible && succeeds)
                    }
                }
            }
        }
    }

    func testPopupMenuPressCancellationBeforeAndAfterProbe() throws {
        let target = SkyClickTarget(screenPoint: CGPoint(x: 210, y: 183), windowPoint: CGPoint(x: 30, y: 45),
            windowBounds: CGRect(x: 180, y: 138, width: 160, height: 120), windowID: 65848, pid: 123)
        var calls = 0
        XCTAssertThrowsError(try LockedUseActionScope.withValidator({
            throw LockedUseError.stopped(reason: .physicalInput, awaitingManualUnlock: true)
        }) {
            try LockedUseClickDispatcher.pressPopupMenuItem(target: target,
                isPopupTarget: true, button: .left, clickCount: 1) { _, _ in
                calls += 1
                return true
            }
        }) { XCTAssertEqual(($0 as? LockedUseError)?.exitCode, 75) }
        XCTAssertEqual(calls, 0)

        for succeeds in [false, true] {
            // A semaphore avoids mutable captures in the @Sendable validator.
            // Revocation during either a successful press or a failed probe
            // must throw, never fall through into synthetic mouse dispatch.
            let probed = DispatchSemaphore(value: 0)
            XCTAssertThrowsError(try LockedUseActionScope.withValidator({
                if probed.wait(timeout: .now()) == .success {
                    throw LockedUseError.stopped(reason: .physicalInput, awaitingManualUnlock: true)
                }
            }) {
                try LockedUseClickDispatcher.pressPopupMenuItem(target: target,
                    isPopupTarget: true, button: .left, clickCount: 1) { _, _ in
                    probed.signal()
                    return succeeds
                }
            }) { XCTAssertEqual(($0 as? LockedUseError)?.exitCode, 75) }
        }
    }

    func testDispatchErrorsAttemptFocusCleanupForLeftRightAndPopupClicks() throws {
        let context = SkyLightSyntheticFocusContext(deactivateTarget:
            skyLightSyntheticTargetFocusPlan(targetPSN: [1, 2, 3, 4, 5, 6, 7, 8], targetWindowID: 42).deactivateTarget)
        for (button, isPopup) in [(LockedUseMouseButton.left, false), (.right, false), (.left, true)] {
            let recipe = try skyClickEventRecipe(clickCount: 1, button: button, includePrimer: !isPopup)
            for failValidation in [true, false] {
                for cleanupThrows in [false, true] {
                    let originalError = NSError(domain: "LockedUseClick.dispatch-test", code: failValidation ? 1 : 2)
                    let posted = DispatchSemaphore(value: 0)
                    var posts = 0
                    var cleanups = 0
                    // No GUI/session queries, AX calls, sleeps or input posts:
                    // exercise the production lifecycle boundary with fake I/O.
                    XCTAssertThrowsError(try LockedUseActionScope.withValidator({
                        if failValidation && posted.wait(timeout: .now()) == .success {
                            throw originalError
                        }
                    }) {
                        try LockedUseClickDispatcher.dispatchWithFocusCleanup(focusContext: context,
                            button: button, endFocus: { cleanup in
                                cleanups += 1
                                XCTAssertEqual(cleanup.deactivateTarget, context.deactivateTarget)
                                if cleanupThrows { throw NSError(domain: "LockedUseClick.cleanup-test", code: 3) }
                            }) {
                            let post: (SkyClickEventStep) throws -> Void = { _ in
                                posts += 1
                                if !failValidation && posts == 2 { throw originalError }
                                if failValidation { posted.signal() }
                            }
                            for step in recipe {
                                try LockedUseActionScope.validate()
                                try post(step)
                                try LockedUseActionScope.validate()
                            }
                        }
                    }) { XCTAssertTrue(($0 as NSError) === originalError) }
                    XCTAssertEqual(posts, failValidation ? 1 : 2)
                    XCTAssertEqual(cleanups, 1)
                }
            }
        }
    }

    func testSuccessfulRightClickRetainsFocusAndNoContextNeedsNoCleanup() throws {
        let context = SkyLightSyntheticFocusContext(deactivateTarget:
            skyLightSyntheticTargetFocusPlan(targetPSN: [1, 2, 3, 4, 5, 6, 7, 8], targetWindowID: 42).deactivateTarget)
        for button in [LockedUseMouseButton.left, .right] {
            var cleanups = 0
            var dispatched = false
            try LockedUseClickDispatcher.dispatchWithFocusCleanup(focusContext: context,
                button: button, endFocus: { _ in cleanups += 1 }) { dispatched = true }
            XCTAssertTrue(dispatched)
            XCTAssertEqual(cleanups, button == .right ? 0 : 1)

            cleanups = 0
            try LockedUseClickDispatcher.dispatchWithFocusCleanup(focusContext: nil,
                button: button, endFocus: { _ in cleanups += 1 }) {}
            XCTAssertThrowsError(try LockedUseClickDispatcher.dispatchWithFocusCleanup(focusContext: nil,
                button: button, endFocus: { _ in cleanups += 1 }) {
                throw LockedUseError.stopped(reason: .physicalInput, awaitingManualUnlock: true)
            })
            XCTAssertEqual(cleanups, 0)
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
