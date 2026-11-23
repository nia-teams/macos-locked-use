import AppKit
import Foundation
import IOKit.pwr_mgt
import LockedUseKit
import QuartzCore

@MainActor
private final class ShieldWindow: NSPanel {
    private var pinnedFrame: NSRect?

    func pin(to frame: NSRect, force: Bool = false) {
        pinnedFrame = frame
        if force || self.frame != frame { setFrame(frame, display: true) }
        orderFrontRegardless()
        displayIfNeeded()
    }
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(pinnedFrame ?? frameRect, display: flag)
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // AppKit may constrain ordinary windows to the menu/Dock visible frame
    // after finishLaunching. A privacy surface must cover the full display.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { pinnedFrame ?? frameRect }
}

/// Shared visual surface for both the isolated preview and guarded rehearsal.
@MainActor
final class DisplayShieldSurface: NSObject {
    private var windows: [CGDirectDisplayID: ShieldWindow] = [:]
    private var appearances: [CGDirectDisplayID: ShieldAppearance] = [:]
    private var message = ""
    private var levelOffset = 0
    private var reanchoring = false
    private var staging = false
    private var recovery = LockedUseShieldRepair()
    private var observedUnlock = false
    var count: Int { windows.count }

    private func installObservers() {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didChangeScreenNotification, NSApplication.didChangeScreenParametersNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(surfaceChanged(_:)), name: name, object: nil)
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(surfaceChanged(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    @objc private func surfaceChanged(_ notification: Notification) {
        if let window = notification.object as? NSWindow,
           !windows.values.contains(where: { $0 === window }) { return }
        observeTopologyAndSupplement()
        reanchor(force: true)
    }

    func observeUnlockedSession() { observedUnlock = true }

    private func observeTopologyAndSupplement() {
        guard recovery.baselineTopology != nil else { return }
        let screens = screenIDs()
        recovery.observeTopology(topologyFingerprint(screens))
        // Notifications during initial staging must still latch, but cannot
        // recursively create windows. Existing verified windows are NEVER replaced.
        guard recovery.latchedFailure != nil, !staging else { return }
        let additions = screens.filter { windows[$0.0] == nil }
        guard !additions.isEmpty else { return }
        staging = true
        defer { staging = false }
        do {
            let staged = try stageScreens(additions)
            for (id, pair) in staged {
                windows[id] = pair.0
                appearances[id] = pair.1
            }
            CATransaction.flush()
        } catch { recovery.latch("shieldReconciliationFailed") }
    }

    private func reanchor(force: Bool = false) {
        guard !reanchoring else { return }
        reanchoring = true
        defer { reanchoring = false }
        for (id, screen) in screenIDs() {
            windows[id]?.pin(to: LockedUseShieldCoverage.surfaceFrame(for: screen.frame), force: force)
        }
        CATransaction.flush()
    }

    func updateMessage(_ message: String) {
        self.message = message
        for (id, appearance) in appearances {
            appearance.updateMessage(message)
            windows[id]?.displayIfNeeded()
        }
    }

    /// Only after root drain, an observed original-session lock and actual
    /// hardware takeover. Keep opaque coverage while loginwindow takes input.
    func allowLocalLoginInput() {
        for window in windows.values { window.ignoresMouseEvents = true }
    }

    func close() {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        // Disarm BEFORE close notifications; a later prepare starts fresh.
        recovery = LockedUseShieldRepair()
        observedUnlock = false
        staging = false
        for window in windows.values { window.close() }
        windows.removeAll()
        appearances.removeAll()
    }

    private func screenIDs() -> [(CGDirectDisplayID, NSScreen)] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (number.uint32Value, screen)
        }
    }

    func displayTopology() -> String { topologyFingerprint(screenIDs()) }

    private func topologyFingerprint(_ screens: [(CGDirectDisplayID, NSScreen)]) -> String {
        screens.sorted { $0.0 < $1.0 }.map { id, screen in
            "\(id):\(NSStringFromRect(screen.frame)):\(screen.backingScaleFactor)"
        }.joined(separator: "|")
    }

    /// Wake sleeping displays before enumerating AppKit screens or testing
    /// coverage. Failure remains fail-closed; no empty set counts as coverage.
    static func ensureDisplayAwake(timeout: TimeInterval = 2.0) -> Bool {
        LockedUseDisplayWake.ensureAwake(timeout: timeout, active: {
            var count: UInt32 = 0
            guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0, count <= 64 else { return false }
            var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
            guard CGGetActiveDisplayList(count, &displays, &count) == .success, count > 0 else { return false }
            return displays.prefix(Int(count)).allSatisfy { CGDisplayIsAsleep($0) == 0 }
        }, wake: {
            var assertionID: IOPMAssertionID = 0
            if IOPMAssertionDeclareUserActivity("Locked Use display wake" as CFString,
                                               kIOPMUserActiveLocal, &assertionID) == kIOReturnSuccess {
                _ = IOPMAssertionRelease(assertionID)
            }
        }, pump: { interval in
            let deadline = ProcessInfo.processInfo.systemUptime + interval
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: interval))
            // RunLoop can return immediately when no input sources are ready.
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
        })
    }

    func coverDisplays(message: String, levelOffset: Int = 0) throws {
        guard windows.isEmpty, !staging else { throw GuardianError.message("Shield already prepared") }
        recovery = LockedUseShieldRepair()
        observedUnlock = false
        // Arm the immutable baseline BEFORE waking, observers or window creation.
        recovery.observeTopology(displayTopology())
        installObservers()
        staging = true
        defer { staging = false }
        self.message = message
        self.levelOffset = levelOffset
        do {
            guard Self.ensureDisplayAwake() else { throw GuardianError.message("No active display after wake timeout") }
            let staged = try stageScreens(screenIDs())
            windows = staged.mapValues { $0.0 }
            appearances = staged.mapValues { $0.1 }
            reanchor(force: true)
            let observed = rawCoverageFailure()
            recovery.observeTopology(displayTopology())
            if let failure = recovery.latchedFailure { throw GuardianError.message(failure) }
            // Preparation explicitly forbids bounds recovery, even on reuse.
            if let failure = recovery.failure(observed: observed, unlocked: false,
                                               now: ProcessInfo.processInfo.systemUptime) {
                throw GuardianError.message(failure)
            }
        } catch {
            close() // Includes all published candidates; partial stages clean themselves.
            throw error
        }
    }

    private func stageScreens(_ screens: [(CGDirectDisplayID, NSScreen)]) throws -> [CGDirectDisplayID: (ShieldWindow, ShieldAppearance)] {
        try LockedUseShieldRepair.stage(ids: screens.map { $0.0 }, make: { id in
            guard let screen = screens.first(where: { $0.0 == id })?.1 else {
                throw GuardianError.message("Display disappeared while staging")
            }
            // `NSWindow(contentRect:screen:)` positions contentRect relative to
            // the given screen's origin, while `surfaceFrame` is global Cocoa
            // space. On the primary display (origin 0,0) both agree; on any
            // secondary display (e.g. the 1920x1080 agent virtual display) the
            // initial window lands offset by the screen origin and WindowServer
            // reports bounds that never contain the display
            // (`shieldBoundsMismatch`). Pass screen-local coordinates to init and
            // keep the global frame for setFrame.
            let frame = LockedUseShieldCoverage.surfaceFrame(for: screen.frame)
            let local = LockedUseShieldCoverage.screenLocalRect(frame, screenOrigin: screen.frame.origin)
            let window = ShieldWindow(contentRect: local, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false, screen: screen)
            window.animationBehavior = .none
            window.hidesOnDeactivate = false
            window.isFloatingPanel = true
            window.becomesKeyOnlyIfNeeded = true
            window.setFrame(frame, display: true)
            window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1 + levelOffset)
            // Default user windows disappear at loginwindow. Both protection
            // surfaces must remain onscreen across the lock/unlock transition.
            window.canBecomeVisibleWithoutLogin = true
            window.canHide = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.backgroundColor = .black
            window.isOpaque = true
            window.alphaValue = 1
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.sharingType = .none
            window.isReleasedWhenClosed = false
            let appearance = ShieldAppearance(frame: NSRect(origin: .zero, size: frame.size), screen: screen, message: message)
            window.contentView = appearance
            window.pin(to: frame)
            guard window.windowNumber > 0, window.isVisible else {
                window.close()
                throw GuardianError.message("Shield window creation failed")
            }
            return (window, appearance)
        }, discard: { $0.0.close() })
    }

    /// WindowServer evidence, not just `isVisible`. Other secure/system overlays
    /// and hotplug races still require live validation; this is not a proof that
    /// ordinary windows provide an OS-enforced privacy barrier.
    func coverageHealthy() -> Bool { coverageFailure() == nil }

    func coverageFailure() -> String? {
        guard recovery.baselineTopology != nil, !staging else { return "shieldNotPrepared" }
        observeTopologyAndSupplement()
        if let failure = recovery.latchedFailure { return failure }
        reanchor(force: recovery.mismatchStarted != nil)
        var observed = rawCoverageFailure()
        if observed?.hasPrefix("shieldBoundsMismatch ") == true {
            // One immediate re-anchor/flush/re-read; NEVER sleep or pump the
            // run loop. Later ticks and Space notifications drive recovery.
            reanchor(force: true)
            observed = rawCoverageFailure()
        }
        recovery.observeTopology(displayTopology())
        return recovery.failure(observed: observed, unlocked: observedUnlock,
                                now: ProcessInfo.processInfo.systemUptime)
    }

    private func rawCoverageFailure() -> String? {
        guard displayTopology() == recovery.baselineTopology else { return "topologyChanged" }
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0, count <= 64 else { return "activeDisplayCountUnavailable" }
        var active = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &active, &count) == .success,
              count > 0, Int(count) <= active.count else { return "activeDisplayListUnavailable" }
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return "windowListUnavailable" }
        var boundsFailure: String?
        var verifiedBounds: [CGDirectDisplayID: CGRect] = [:]
        for (id, window) in windows {
            guard window.isVisible else { return "shieldNotVisible" }
            guard let info = infos.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == window.windowNumber }) else { return "shieldNotInWindowServer" }
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == getpid() else { return "shieldOwnerMismatch" }
            guard let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
                  alpha.isFinite, alpha >= 0.99, alpha <= 1 else { return "shieldAlphaMismatch" }
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == window.level.rawValue else { return "shieldLayerMismatch" }
            guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  LockedUseShieldCoverage.covers(rect, display: rect) else { return "shieldBoundsUnavailable" }
            let ownDisplay = CGDisplayBounds(id)
            guard LockedUseShieldCoverage.covers(ownDisplay, display: ownDisplay) else { return "displayBoundsUnavailable" }
            verifiedBounds[id] = rect
            if !LockedUseShieldCoverage.covers(rect, display: ownDisplay), boundsFailure == nil {
                boundsFailure = "shieldBoundsMismatch expected=\(NSStringFromRect(CGDisplayBounds(id))) actual=\(NSStringFromRect(rect)) displayID=\(id) window=\(window.windowNumber) cocoaFrame=\(NSStringFromRect(window.frame))"
            }
        }
        // Mirror membership is not coverage evidence: check the chosen shield
        // against BOTH its assigned display and each actual active display.
        for activeID in active.prefix(Int(count)) {
            guard let shieldID = LockedUseShieldCoverage.coveringShieldID(activeID: activeID,
                mirrorID: CGDisplayMirrorsDisplay(activeID), available: Set(verifiedBounds.keys)),
                  let rect = verifiedBounds[shieldID] else { return "activeDisplayUncovered" }
            let ownDisplay = CGDisplayBounds(shieldID)
            let activeDisplay = CGDisplayBounds(activeID)
            guard LockedUseShieldCoverage.covers(ownDisplay, display: ownDisplay),
                  LockedUseShieldCoverage.covers(activeDisplay, display: activeDisplay) else { return "displayBoundsUnavailable" }
            if !LockedUseShieldCoverage.coversAssignedAndActive(rect, assigned: ownDisplay, active: activeDisplay), boundsFailure == nil {
                boundsFailure = "shieldBoundsMismatch expected=\(NSStringFromRect(activeDisplay)) actual=\(NSStringFromRect(rect)) displayID=\(activeID) shieldDisplayID=\(shieldID)"
            }
        }
        // Validate integrity of EVERY window and active display before grace.
        return boundsFailure
    }

}
