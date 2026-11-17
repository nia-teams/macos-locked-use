// Target-only input; adapted from the MIT-licensed upstream recipes.
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct SkyClickTarget {
    let screenPoint: CGPoint
    let windowPoint: CGPoint
    let windowBounds: CGRect
    let windowID: CGWindowID
    let pid: pid_t
}

extension LockedUseMouseButton {
    var cgMouseButton: CGMouseButton { self == .right ? .right : .left }
}

enum SkyClickEventKind: Equatable, Sendable {
    case moved
    case down
    case up

    func cgEventType(button: LockedUseMouseButton) -> CGEventType {
        switch self {
        case .moved:
            return .mouseMoved
        case .down:
            return button == .right ? .rightMouseDown : .leftMouseDown
        case .up:
            return button == .right ? .rightMouseUp : .leftMouseUp
        }
    }
}

enum SkyClickPointKind: Equatable, Sendable {
    case target
    case primer
}

struct SkyClickEventStep: Equatable, Sendable {
    let kind: SkyClickEventKind
    let pointKind: SkyClickPointKind
    let clickState: Int64
    let phase: Int64
    let delayAfter: TimeInterval
}

func skyClickEventRecipe(
    clickCount: Int,
    button: LockedUseMouseButton = .left,
    includePrimer: Bool = true
) throws -> [SkyClickEventStep] {
    guard (1...2).contains(clickCount) else {
        throw LockedUseError.message(
            "click_method 'sky_click' supports click_count 1 or 2"
        )
    }

    var steps = [
        SkyClickEventStep(kind: .moved, pointKind: .target, clickState: 0, phase: 2, delayAfter: 0.015),
    ]
    if button == .left && includePrimer {
        steps.append(SkyClickEventStep(kind: .down, pointKind: .primer, clickState: 1, phase: 1, delayAfter: 0.001))
        steps.append(SkyClickEventStep(kind: .up, pointKind: .primer, clickState: 1, phase: 2, delayAfter: 0.100))
    }

    for pairIndex in 1...clickCount {
        steps.append(
            SkyClickEventStep(
                kind: .down,
                pointKind: .target,
                clickState: Int64(pairIndex),
                phase: 3,
                delayAfter: 0.001
            )
        )
        steps.append(
            SkyClickEventStep(
                kind: .up,
                pointKind: .target,
                clickState: Int64(pairIndex),
                phase: 3,
                delayAfter: pairIndex < clickCount ? 0.080 : 0
            )
        )
    }

    return steps
}

/// The window must still exist and belong to the snapshot's process. It does
/// not need to be on-screen: SkyLight routes by window id, so a covered window
/// or one on another Space is a valid target (verified live on macOS 27).
func skyClickWindowMatchesTarget(
    windowInfo: [[String: Any]],
    windowID: CGWindowID,
    pid: pid_t
) -> Bool {
    skyKeyWindowMatchesTarget(windowInfo: windowInfo, windowID: windowID, pid: pid)
}

// WindowServer supplies front-to-back order; only same-app popups in front
// of the requested base window can receive its clicks.
func sameAppPopupsAbove(
    windowInfo: [[String: Any]],
    pid: pid_t,
    baseWindowID: CGWindowID,
    shieldLevel: Int = Int(CGShieldingWindowLevel())
) -> [LockedUseWindowTarget] {
    let baseIndex = windowInfo.firstIndex {
        ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == baseWindowID
    }
    guard let baseIndex, baseIndex > 0 else { return [] }
    var popups: [LockedUseWindowTarget] = []
    for item in windowInfo[0 ..< baseIndex] {
        guard let id = (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              id != baseWindowID,
              let owner = (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              owner == pid else { continue }
        let alpha = (item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
        guard alpha > 0,
              let layer = (item[kCGWindowLayer as String] as? NSNumber)?.intValue,
              layer >= 0, layer < shieldLevel else { continue }
        let title = (item[kCGWindowName as String] as? String) ?? ""
        guard layer > 0 || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let rawBounds = item[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary),
              bounds.width >= 2, bounds.height >= 2 else { continue }
        popups.append(LockedUseWindowTarget(windowID: id, pid: pid, bounds: bounds))
    }
    return popups
}

func resolveSkyClickTarget(_ target: SkyClickTarget, onScreenWindowInfo: [[String: Any]]) -> SkyClickTarget {
    if let popup = sameAppPopupsAbove(windowInfo: onScreenWindowInfo, pid: target.pid, baseWindowID: target.windowID)
        .first(where: { $0.bounds.contains(target.screenPoint) }) {
        return SkyClickTarget(screenPoint: target.screenPoint,
            windowPoint: CGPoint(x: target.screenPoint.x - popup.bounds.minX, y: target.screenPoint.y - popup.bounds.minY),
            windowBounds: popup.bounds, windowID: popup.windowID, pid: target.pid)
    }
    return target
}

enum LockedUseClickDispatcher {
    private static let primerScreenPoint = CGPoint(x: -1, y: -1)
    private static let primerWindowPoint = CGPoint(x: -1, y: -1)
    private static let dispatchLock = NSLock()

    // Raw private event fields used by the Chromium-compatible Cua Driver path.
    private enum EventField {
        static let gesturePhase: UInt32 = 0
        static let clickState: UInt32 = 1
        static let buttonNumber: UInt32 = 3
        static let subtype: UInt32 = 7
        static let targetPID: UInt32 = 40
        static let windowNumber: UInt32 = 51
        static let clickGroupID: UInt32 = 58
        static let windowUnderPointer: UInt32 = 91
        static let handlingWindowUnderPointer: UInt32 = 92
    }

    static func click(
        target: SkyClickTarget,
        clickCount: Int,
        button: LockedUseMouseButton = .left,
        spi: LockedUseInputSPI = .shared
    ) throws {
        try requireUsableComputerUseSession()
        guard spi.capability.isAvailable else {
            throw LockedUseError.message(
                "click_method 'sky_click' is unavailable: \(spi.capability.unavailableReason)"
            )
        }

        dispatchLock.lock()
        defer {
            dispatchLock.unlock()
        }

        try validate(target: target)
        let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let effectiveTarget = resolveSkyClickTarget(target, onScreenWindowInfo: onScreen)
        guard CGRect(origin: .zero, size: effectiveTarget.windowBounds.size).contains(effectiveTarget.windowPoint) else {
            throw LockedUseError.message("sky_click target is outside the snapshot window bounds")
        }
        let isPopupTarget = effectiveTarget.windowID != target.windowID
        // An off-menu primer dismisses a tracking NSMenu before the real click.
        let recipe = try skyClickEventRecipe(clickCount: clickCount, button: button,
            includePrimer: button == .left && !isPopupTarget)
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw LockedUseError.message("Failed to create SkyLight HID event source.")
        }

        // Cua uses the nanosecond component of wall-clock time here, which is
        // always below one billion. Keep the same narrow raw-field range;
        // WindowServer does not publish field 58's accepted width.
        let clickGroupID = Int64(DispatchTime.now().uptimeNanoseconds % 1_000_000_000)

        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let focusContext: SkyLightSyntheticFocusContext?
        if frontmostPID == effectiveTarget.pid {
            focusContext = nil
        } else if isPopupTarget {
            // The menu inherits synthetic focus from the earlier right-click,
            // possibly in another CLI process. Resolve cleanup without sending
            // an activation record that could interrupt its tracking loop.
            focusContext = try spi.syntheticTargetFocusContext(
                targetPID: target.pid,
                targetWindowID: target.windowID
            )
        } else {
            focusContext = try spi.beginSyntheticTargetFocus(
                targetPID: effectiveTarget.pid,
                targetWindowID: effectiveTarget.windowID
            )
        }

        try dispatchWithFocusCleanup(focusContext: focusContext, button: button,
            endFocus: spi.endSyntheticTargetFocus) {
            let pressedPopupMenuItem = try pressPopupMenuItem(target: effectiveTarget,
                isPopupTarget: isPopupTarget, button: button, clickCount: clickCount)
            if !pressedPopupMenuItem {
                for step in recipe {
                    try requireUsableComputerUseSession()
                    let screenPoint = step.pointKind == .target ? effectiveTarget.screenPoint : primerScreenPoint
                    let windowPoint = step.pointKind == .target ? effectiveTarget.windowPoint : primerWindowPoint
                    guard let event = CGEvent(
                        mouseEventSource: source,
                        mouseType: step.kind.cgEventType(button: button),
                        mouseCursorPosition: screenPoint,
                        mouseButton: step.kind == .moved ? .left : button.cgMouseButton
                    ) else {
                        throw LockedUseError.message(
                            "Failed to create sky_click mouse event \(step.kind.cgEventType(button: button).rawValue)."
                        )
                    }

                    try stamp(
                        event,
                        target: effectiveTarget,
                        windowPoint: windowPoint,
                        clickState: step.clickState,
                        phase: step.phase,
                        button: button,
                        clickGroupID: clickGroupID,
                        spi: spi
                    )

                    try spi.postToPid(event, pid: effectiveTarget.pid)
                    try LockedUseActionScope.validate()

                    let delay = step.delayAfter * LockedUseInputTiming.skyClickDelayScale
                    if delay > 0 {
                        Thread.sleep(forTimeInterval: delay)
                    }
                }
            }
            if focusContext != nil || pressedPopupMenuItem {
                // Let selection reach the menu/renderer before releasing synthetic
                // focus. Right-click retains it for the next popup-selection call.
                // Ending focus only deactivates the target; Guardian stays frontmost.
                let rendererSettle = 0.100 * LockedUseInputTiming.skyClickDelayScale
                if rendererSettle > 0 {
                    Thread.sleep(forTimeInterval: rendererSettle)
                }
            }
        }
    }

    // One lifecycle boundary for both acquired and inherited popup focus.
    // Failed validation/posting always attempts cleanup, including right-click;
    // only a successful right-click intentionally keeps synthetic focus.
    static func dispatchWithFocusCleanup(
        focusContext: SkyLightSyntheticFocusContext?,
        button: LockedUseMouseButton,
        endFocus: (SkyLightSyntheticFocusContext) throws -> Void,
        dispatch: () throws -> Void
    ) throws {
        do {
            try dispatch()
        } catch {
            if let focusContext {
                try? endFocus(focusContext)
            }
            throw error
        }
        if button != .right, let focusContext {
            try endFocus(focusContext)
        }
    }

    // Native NSMenu's modal tracking ignores PID-posted mouse events. Only an
    // actual menu item at this app-local hit test takes AXPress; custom popup
    // views and unsuccessful presses continue through the same sky_click path.
    static func pressPopupMenuItem(
        target: SkyClickTarget,
        isPopupTarget: Bool,
        button: LockedUseMouseButton,
        clickCount: Int,
        press: (pid_t, CGPoint) throws -> Bool = LockedUseClickDispatcher.pressAXPopupMenuItem
    ) throws -> Bool {
        guard isPopupTarget && button == .left && clickCount == 1 else { return false }
        try LockedUseActionScope.validate()
        let pressed = try press(target.pid, target.screenPoint)
        try LockedUseActionScope.validate()
        return pressed
    }

    static func pressAXPopupMenuItem(pid: pid_t, screenPoint: CGPoint) throws -> Bool {
        var element: AXUIElement?
        var role: CFTypeRef?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(pid),
                Float(screenPoint.x), Float(screenPoint.y), &element) == .success,
              let element,
              AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
              role as? String == kAXMenuItemRole as String else { return false }
        // Revalidate immediately before the action as well as around the probe.
        try LockedUseActionScope.validate()
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    private static func validate(target: SkyClickTarget) throws {
        guard
            target.screenPoint.x.isFinite,
            target.screenPoint.y.isFinite,
            target.windowPoint.x.isFinite,
            target.windowPoint.y.isFinite,
            target.windowBounds.origin.x.isFinite,
            target.windowBounds.origin.y.isFinite,
            target.windowBounds.width.isFinite,
            target.windowBounds.height.isFinite,
            target.windowBounds.width > 0,
            target.windowBounds.height > 0
        else {
            throw LockedUseError.message("sky_click requires finite target coordinates and window bounds")
        }

        if NSRunningApplication(processIdentifier: target.pid)?.isHidden == true {
            throw LockedUseError.stateUnavailable(
                "sky_click target app is hidden. Unhide it first; sky_click does not change window visibility."
            )
        }
        let windowInfo = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        guard skyClickWindowMatchesTarget(
            windowInfo: windowInfo,
            windowID: target.windowID,
            pid: target.pid
        ) else {
            throw LockedUseError.stateUnavailable(
                "sky_click target window no longer exists or is no longer owned by the target app. Run get_app_state again."
            )
        }
    }

    static func stamp(
        _ event: CGEvent,
        target: SkyClickTarget,
        windowPoint: CGPoint,
        clickState: Int64,
        phase: Int64,
        button: LockedUseMouseButton,
        clickGroupID: Int64,
        spi: LockedUseInputSPI
    ) throws {
        let windowID = Int64(target.windowID)
        try spi.setIntegerField(event, field: EventField.gesturePhase, value: phase)
        try spi.setIntegerField(event, field: EventField.clickState, value: clickState)
        try spi.setIntegerField(event, field: EventField.buttonNumber, value: event.type == .mouseMoved ? 0 : Int64(button.cgMouseButton.rawValue))
        try spi.setIntegerField(event, field: EventField.subtype, value: 3)
        try spi.setIntegerField(event, field: EventField.targetPID, value: Int64(target.pid))
        try spi.setIntegerField(event, field: EventField.windowNumber, value: windowID)
        try spi.setIntegerField(event, field: EventField.clickGroupID, value: clickGroupID)
        try spi.setIntegerField(event, field: EventField.windowUnderPointer, value: windowID)
        try spi.setIntegerField(event, field: EventField.handlingWindowUnderPointer, value: windowID)
        try spi.setWindowLocation(event, point: windowPoint)
    }

}
