import CoreGraphics
import Darwin

private enum WindowLocationSPI {
    typealias Function = @convention(c) (CGEvent, CGPoint) -> Void
    // Keep the framework loaded for the lifetime of the function pointer.
    static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_GLOBAL)
    static let function: Function? = {
        guard let handle, let symbol = dlsym(handle, "CGEventSetWindowLocation") else { return nil }
        return unsafeBitCast(symbol, to: Function.self)
    }()
}

/// Encodes a verified window-local point. This SPI grants no authentication.
public func encodeLockedUseWindowLocation(_ event: CGEvent, point: CGPoint) throws {
    guard point.x.isFinite, point.y.isFinite else {
        throw LockedUseError.message("Invalid Locked Use window location")
    }
    guard let function = WindowLocationSPI.function else {
        throw LockedUseError.stateUnavailable("CGEventSetWindowLocation is unavailable")
    }
    function(event, point)
}
