import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

public struct LockedUseWindowTarget: Equatable, Sendable {
    public let windowID: CGWindowID
    public let pid: pid_t
    /// Global top-left logical points, not Retina pixels.
    public let bounds: CGRect

    public init(windowID: CGWindowID, pid: pid_t, bounds: CGRect) {
        self.windowID = windowID; self.pid = pid; self.bounds = bounds
    }
}

/// Target-addressed GUI operations. Never posts to a global HID/session tap,
/// raises a target, or activates an application across the Guardian shield.
/// Serialize actions and use a connection's perform or a holder validator scope.
@MainActor
public enum LockedUseGUI {
    public static func findWindow(app: String? = nil, pid: pid_t? = nil, windowID: CGWindowID? = nil) throws -> LockedUseWindowTarget {
        try requireUsableComputerUseSession()
        guard app != nil || pid != nil || windowID != nil else { throw LockedUseError.usage("Specify --app, --pid, or --window-id") }
        let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        // WindowServer's list is front-to-back. Never target a layer > 0 shield.
        for item in info {
            guard let id = (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let owner = (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, owner > 0,
                  (item[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let rawBounds = item[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary),
                  bounds.width > 1, bounds.height > 1,
                  windowID == nil || windowID == id, pid == nil || pid == owner else { continue }
            if let app {
                let running = NSRunningApplication(processIdentifier: owner)
                let names = [running?.bundleIdentifier, running?.localizedName, item[kCGWindowOwnerName as String] as? String]
                guard names.contains(where: { $0?.caseInsensitiveCompare(app) == .orderedSame }) else { continue }
            }
            return .init(windowID: id, pid: owner, bounds: bounds)
        }
        throw LockedUseError.stateUnavailable("No matching normal app window; check the app, PID, and window ID")
    }

    public static func click(windowID: CGWindowID, pid: pid_t, windowBounds: CGRect, screenPoint: CGPoint, clickCount: Int = 1) throws {
        try LockedUseClickDispatcher.click(target: .init(screenPoint: screenPoint,
            windowPoint: CGPoint(x: screenPoint.x - windowBounds.minX, y: screenPoint.y - windowBounds.minY),
            windowBounds: windowBounds, windowID: windowID, pid: pid), clickCount: clickCount)
    }

    public static func click(target: LockedUseWindowTarget, x: Double, y: Double, screen: Bool = false, clickCount: Int = 1) throws {
        try click(windowID: target.windowID, pid: target.pid, windowBounds: target.bounds,
            screenPoint: CGPoint(x: x + (screen ? 0 : target.bounds.minX), y: y + (screen ? 0 : target.bounds.minY)), clickCount: clickCount)
    }

    public static func backingScaleFactor(for windowBounds: CGRect) -> Double {
        let center = CGPoint(x: windowBounds.midX, y: windowBounds.midY)
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        if CGGetDisplaysWithPoint(center, 1, &display, &count) == .success, count > 0,
           let mode = CGDisplayCopyDisplayMode(display), mode.width > 0 {
            let scale = Double(mode.pixelWidth) / Double(mode.width)
            if scale >= 1, scale.isFinite { return scale }
        }
        let scale = Double(NSScreen.main?.backingScaleFactor ?? 2)
        return scale >= 1 && scale.isFinite ? scale : 2
    }

    public static func typeText(_ text: String, windowID: CGWindowID, pid: pid_t) throws {
        try LockedUseKeyboardDispatcher.typeText(target: .init(windowID: windowID, pid: pid), text: text)
    }

    public static func pressKey(_ keySpec: String, windowID: CGWindowID, pid: pid_t) throws {
        try LockedUseKeyboardDispatcher.pressKey(target: .init(windowID: windowID, pid: pid), key: keySpec)
    }

    public static func axPress(pid: pid_t, role: String? = nil, title: String? = nil, identifier: String? = nil) throws {
        try requireUsableComputerUseSession()
        guard pid > 0, role != nil || title != nil || identifier != nil else { throw LockedUseError.usage("AX press needs a PID and role, title, or identifier") }
        var remaining = 10_000
        func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            var result: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
            return result
        }
        func search(_ element: AXUIElement, depth: Int) throws -> AXUIElement? {
            guard depth < 64, remaining > 0 else { return nil }
            remaining -= 1
            try LockedUseActionScope.validate()
            if (role == nil || value(element, kAXRoleAttribute) as? String == role),
               (title == nil || value(element, kAXTitleAttribute) as? String == title),
               (identifier == nil || value(element, kAXIdentifierAttribute) as? String == identifier) { return element }
            for child in value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                if let found = try search(child, depth: depth + 1) { return found }
            }
            return nil
        }
        guard let element = try search(AXUIElementCreateApplication(pid), depth: 0) else { throw LockedUseError.stateUnavailable("No matching AX element") }
        try LockedUseActionScope.validate()
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard result == .success else { throw LockedUseError.message("AX press failed: \(result.rawValue)") }
    }

    public struct Capture: Codable, Sendable {
        public struct Bounds: Codable, Sendable { public let x: Double; public let y: Double; public let width: Double; public let height: Double }
        public let windowID: CGWindowID
        public let pid: pid_t
        public let bounds: Bounds
        public let pixelWidth: Int
        public let pixelHeight: Int
        public let path: String
    }

    /// Single-window backing pixels, never the black composited shield desktop.
    @available(macOS 14.0, *)
    public static func captureWindow(windowID: CGWindowID, outputPath: String) async throws -> Capture {
        try requireUsableComputerUseSession()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        try LockedUseActionScope.validate()
        guard let window = content.windows.first(where: { $0.windowID == windowID }),
              let app = window.owningApplication else { throw LockedUseError.stateUnavailable("Capture window no longer exists") }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let rect = filter.contentRect
        let scale = Double(filter.pointPixelScale)
        configuration.width = max(1, Int((rect.width * scale).rounded()))
        configuration.height = max(1, Int((rect.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        try LockedUseActionScope.validate()
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try LockedUseActionScope.validate()
        let url = URL(fileURLWithPath: outputPath).standardizedFileURL
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw LockedUseError.message("Cannot create capture PNG") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw LockedUseError.message("Cannot write capture PNG") }
        let b = window.frame
        return .init(windowID: windowID, pid: app.processID, bounds: .init(x: b.minX, y: b.minY, width: b.width, height: b.height), pixelWidth: image.width, pixelHeight: image.height, path: url.path)
    }
}
