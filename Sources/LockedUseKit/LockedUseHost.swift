import Darwin
import Foundation

public enum LockedUseHost {
    public static var currentExecutableURL: URL {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        if size > 0 {
            var buffer = [CChar](repeating: 0, count: Int(size))
            if _NSGetExecutablePath(&buffer, &size) == 0 {
                return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
            }
        }
        return (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
    }

    /// Also prevents requirement-language injection during administrator staging.
    public static func isValidIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255
            && value.unicodeScalars.allSatisfy { scalar in
                (scalar.value >= 65 && scalar.value <= 90)
                    || (scalar.value >= 97 && scalar.value <= 122)
                    || (scalar.value >= 48 && scalar.value <= 57)
                    || scalar == "." || scalar == "-"
            }
    }

    /// Resolve the enclosing `.app` bundle even when the executable is invoked
    /// via a symlink (e.g. `dist/release-native/bin/locked-use`).
    public static var currentBundle: Bundle {
        if let id = Bundle.main.bundleIdentifier, !id.isEmpty,
           Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main
        }
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        if size > 0 {
            var buffer = [CChar](repeating: 0, count: Int(size))
            if _NSGetExecutablePath(&buffer, &size) == 0 {
                let path = String(cString: buffer)
                let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
                let macosDir = resolved.deletingLastPathComponent()
                let contentsDir = macosDir.deletingLastPathComponent()
                let appDir = contentsDir.deletingLastPathComponent()
                if macosDir.lastPathComponent == "MacOS",
                   contentsDir.lastPathComponent == "Contents",
                   appDir.pathExtension == "app",
                   let bundle = Bundle(url: appDir) {
                    return bundle
                }
            }
        }
        return Bundle.main
    }
}
