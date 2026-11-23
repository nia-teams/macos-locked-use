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
    private var topology = ""
    private var message = ""
    private var levelOffset = 0
    private var reanchoring = false
    private var reconciling = false
    private var recovery = LockedUseShieldRepair()
    private var observedUnlock = false
    var count: Int { windows.count }

    override init() {
        super.init()
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
        reconcileTopologyIfNeeded()
        reanchor(force: true)
    }

    func observeUnlockedSession() { observedUnlock = true }

    private func reconcileTopologyIfNeeded() {
        guard !windows.isEmpty, !reconciling else { return }
        let current = displayTopology()
        recovery.observeTopology(current) // Latch BEFORE staging mutates topology.
        guard current != topology else { return }
        do { try reconcileScreens() }
        catch { recovery.latch("shieldReconciliationFailed") }
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
        guard Self.ensureDisplayAwake() else { throw GuardianError.message("No active display after wake timeout") }
        self.message = message
        self.levelOffset = levelOffset
        do {
            try reconcileScreens()
            // Initial preparation never uses the active transition allowance.
            if let failure = coverageFailure() { throw GuardianError.message(failure) }
        } catch { recovery.latch("shieldReconciliationFailed"); throw error }
    }

    private func reconcileScreens() throws {
        guard !reconciling else { throw GuardianError.message("Recursive shield reconciliation") }
        reconciling = true
        defer { reconciling = false }
        let screens = screenIDs()
        let nextTopology = topologyFingerprint(screens)
        let staged: [CGDirectDisplayID: (ShieldWindow, ShieldAppearance)] = try LockedUseShieldRepair.stage(ids: screens.map { $0.0 }, make: { id in
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
        // No live collection is mutated until ALL candidates are constructed.
        let oldWindows = windows
        windows = staged.mapValues { $0.0 }
        appearances = staged.mapValues { $0.1 }
        topology = nextTopology
        recovery.observeTopology(nextTopology)
        CATransaction.flush()
        for window in oldWindows.values { window.close() }
    }

    /// WindowServer evidence, not just `isVisible`. Other secure/system overlays
    /// and hotplug races still require live validation; this is not a proof that
    /// ordinary windows provide an OS-enforced privacy barrier.
    func coverageHealthy() -> Bool { coverageFailure() == nil }

    func coverageFailure() -> String? {
        reconcileTopologyIfNeeded()
        if let failure = recovery.latchedFailure { return failure }
        reanchor(force: recovery.mismatchStarted != nil)
        var observed = rawCoverageFailure()
        if observed?.hasPrefix("shieldBoundsMismatch ") == true {
            // One immediate re-anchor/flush/re-read; NEVER sleep or pump the
            // run loop. Later ticks and Space notifications drive recovery.
            reanchor(force: true)
            observed = rawCoverageFailure()
        }
        return recovery.failure(observed: observed, unlocked: observedUnlock,
                                now: ProcessInfo.processInfo.systemUptime)
    }

    private func rawCoverageFailure() -> String? {
        guard displayTopology() == topology else { return "topologyChanged" }
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0, count <= 64 else { return "activeDisplayCountUnavailable" }
        var active = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &active, &count) == .success else { return "activeDisplayListUnavailable" }
        for id in active.prefix(Int(count)) {
            let mirrored = CGDisplayMirrorsDisplay(id)
            guard windows[id] != nil || (mirrored != kCGNullDirectDisplay && windows[mirrored] != nil) else { return "activeDisplayUncovered" }
        }
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return "windowListUnavailable" }
        var boundsFailure: String?
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
            if !LockedUseShieldCoverage.covers(rect, display: CGDisplayBounds(id)), boundsFailure == nil {
                boundsFailure = "shieldBoundsMismatch expected=\(NSStringFromRect(CGDisplayBounds(id))) actual=\(NSStringFromRect(rect)) displayID=\(id) window=\(window.windowNumber) cocoaFrame=\(NSStringFromRect(window.frame))"
            }
        }
        // Validate integrity of EVERY shield before considering bounds repair.
        return boundsFailure
    }

}
