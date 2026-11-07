import Darwin

public enum LockedUseScreenLock {
    /// Private macOS API; fail explicitly if unavailable on this OS version.
    public static func lockImmediately() throws {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_NOW),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else {
            throw LockedUseError.stateUnavailable("SACLockScreenImmediate is unavailable")
        }
        defer { dlclose(handle) }
        typealias Function = @convention(c) () -> Void
        unsafeBitCast(symbol, to: Function.self)()
    }
}
