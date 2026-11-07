import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

/// Explicit local enrollment. The elevated shell only stages signed artifacts
/// into a protected directory and verifies the installer before executing it.
/// It never executes a repository script with administrator privileges.
@MainActor
public enum LockedUseSettings {
    /// Host mode requests TCC once in this process; Guardian is launched directly
    /// via Process (never `open -a`) to preserve the responsible host identity.
    public enum PermissionHost { case host }
    public static func handle(arguments: [String], hostBundleIdentifier: String? = nil, permissionHost: PermissionHost = .host) throws -> Bool {
        guard arguments.first == "locked-use", arguments.count > 1,
              ["enable", "disable", "recover", "certify", "settings"].contains(arguments[1]) else { return false }
        guard arguments.count == 2 else {
            throw LockedUseError.message("Usage: locked-use enable | disable | recover | certify | settings")
        }
        let action = arguments[1]
        if action == "settings" {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let alert = NSAlert()
            alert.messageText = "Locked Use"
            alert.informativeText = "在锁屏时继续使用已登录的 Mac。所有显示器会被遮蔽；移动鼠标或按键立即返回锁屏。启用需要管理员授权、辅助功能、屏幕录制和输入监控权限。"
            alert.addButton(withTitle: "启用")
            alert.addButton(withTitle: "停用并移除")
            alert.addButton(withTitle: "取消")
            switch alert.runModal() {
            case .alertFirstButtonReturn: try enable(hostBundleIdentifier: hostBundleIdentifier, permissionHost: permissionHost)
            case .alertSecondButtonReturn: try disable()
            default: break
            }
        } else if action == "enable" { try enable(hostBundleIdentifier: hostBundleIdentifier, permissionHost: permissionHost) }
        else if action == "certify" { try certify() }
        else if action == "recover" { try enable(recovering: true, hostBundleIdentifier: hostBundleIdentifier, permissionHost: permissionHost) }
        else { try disable() }
        return true
    }

    private static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func elevate(_ commands: String) throws {
        // AppleScript receives one data string through an argument, avoiding
        // interpolation into AppleScript syntax or shell command substitution.
        let script = "on run argv\nreturn do shell script (item 1 of argv) with administrator privileges\nend run"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, commands]
        let output = Pipe(); process.standardOutput = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw LockedUseError.message("Locked Use administrator installation did not complete. Existing recovery records were retained.") }
        print(text, terminator: "")
    }
    private static func enable(recovering: Bool = false, hostBundleIdentifier: String? = nil, permissionHost: PermissionHost = .host) throws {
        guard LockedUseSession.current().state == .unlocked else { throw LockedUseError.message("Unlock the Mac normally before administrator installation or recovery.") }
        let identity = try LockedUseSigningIdentity.current()
        let host = hostBundleIdentifier ?? LockedUseHost.currentBundle.bundleIdentifier
        guard identity.userID > 0, let host, LockedUseHost.isValidIdentifier(host),
              host == identity.signingIdentifier,
              let team = identity.teamIdentifier else { throw LockedUseError.message("Use a signed host app with a matching bundle/signing identifier to enable Locked Use.") }
        let source = LockedUseHost.currentBundle.bundleURL.appendingPathComponent("Contents/Resources/LockedUse")
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("LockedUseInstaller").path) else {
            throw LockedUseError.message("Signed Locked Use components are missing from Contents/Resources/LockedUse.")
        }
        // Administrator staging has a protected parent; /tmp ancestry would
        // permit path replacement even when a leaf happens to be root owned.
        let requirement = "=identifier \"com.nia-teams.locked-use.installer\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        let stageParent = "/Library/Application Support/LockedUseStaging"
        let stage = stageParent + "/" + UUID().uuidString
        let existingInstalled = FileManager.default.fileExists(atPath: "/Library/Application Support/LockedUse") ||
            FileManager.default.fileExists(atPath: "/Library/Security/SecurityAgentPlugins/LockedUseAuth.bundle") ||
            FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/com.nia-teams.locked-use.broker.plist")
        let preinstalledCommand = existingInstalled ? (quote(stage + "/LockedUseInstaller") + " uninstall\n") : ""
        let shell = "set -eu\numask 077\n" +
            "/bin/test ! -L " + quote(stageParent) + "\n" +
            "/bin/mkdir -p " + quote(stageParent) + "\n" +
            "/usr/sbin/chown root:wheel " + quote(stageParent) + "\n" +
            "/bin/chmod -N " + quote(stageParent) + "\n" +
            "/bin/chmod 700 " + quote(stageParent) + "\n" +
            "/bin/mkdir " + quote(stage) + "\n" +
            "trap " + quote("/bin/rm -rf " + quote(stage)) + " EXIT\n" +
            "/usr/bin/ditto " + quote(source.path) + " " + quote(stage) + "\n" +
            "/usr/bin/ditto " + quote(LockedUseHost.currentBundle.bundleURL.path) + " " + quote(stage + "/Client.app") + "\n" +
            "/usr/bin/find " + quote(stage) + " -type l -print -quit | /usr/bin/awk 'END { exit(NR != 0) }'\n" +
            "/usr/sbin/chown -hR -P root:wheel " + quote(stage) + "\n" +
            "/bin/chmod -RN " + quote(stage) + "\n" +
            "/bin/chmod -R go-w " + quote(stage) + "\n" +
            "/usr/bin/codesign --verify --strict -R " + quote(requirement) + " " + quote(stage + "/LockedUseInstaller") + "\n" +
            (recovering ? (quote(stage + "/LockedUseInstaller") + " recover") : (preinstalledCommand + quote(stage + "/LockedUseInstaller") + " install " + quote(stage) + " " + String(identity.userID) + " " + "production " + quote(host)))
        try elevate(shell)
        if !recovering { try requestPermissions(permissionHost: permissionHost) }
    }

    private static func requestPermissions(permissionHost: PermissionHost) throws {
        let team = try LockedUseSigningIdentity.current().teamIdentifier!
        // Verify the administrator-installed components before launching Guardian.
        _ = try LockedUseComponentValidation.current(team: team)
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        _ = CGRequestListenEventAccess()
        let guardian = Process()
        guardian.executableURL = URL(fileURLWithPath: "/Library/Application Support/LockedUse/LockedUseGuardian")
        guardian.arguments = ["--permission-status"]
        try guardian.run()
        guardian.waitUntilExit()
        // Fresh installs report false until the human toggles the host switches.
        // Permission status is advisory here; enabling must not require approval yet.
        print("Locked Use installed. In System Settings > Privacy & Security, toggle Accessibility, Screen Recording, and Input Monitoring ON for the HOST app. Then run locked-use status; restart the host if macOS requests it.")
    }
    private static func certify() throws {
        guard LockedUseSession.current().state == .unlocked else {
            throw LockedUseError.message("Unlock normally before reviewing production validation.")
        }
        let alert = NSAlert()
        alert.messageText = "确认 Locked Use 实机验证"
        alert.informativeText = "请仅在这些测试均通过后继续：所有物理屏幕持续遮蔽；Secure Input 下键盘和鼠标立即接管；Guardian、watchdog、app agent、Broker 故障及显示器变化安全重锁；正常密码及 Touch ID 解锁。专用窗口 AX / ScreenCaptureKit 与两类 Keychain 测试证据还会由安装器独立检查。升级 macOS 或保护组件后须重新验证。"
        alert.addButton(withTitle: "全部通过，启用")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try installedAction("promote")
    }
    private static func installedAction(_ action: String) throws {
        let team = try LockedUseSigningIdentity.current().teamIdentifier!
        let bundled = LockedUseHost.currentBundle.bundleURL.appendingPathComponent("Contents/Resources/LockedUse/LockedUseInstaller")
        if action == "uninstall", FileManager.default.fileExists(atPath: bundled.path) {
            // Upgrade/removal must run the current fix, not an older installed
            // installer that may fail while deleting the OS-managed cache.
            let parent = "/Library/Application Support/LockedUseStaging"
            let stage = parent + "/" + UUID().uuidString
            let requirement = "=identifier \"com.nia-teams.locked-use.installer\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
            let commands = "set -eu\numask 077\n" +
                "/bin/test ! -L " + quote(parent) + "\n" +
                "/bin/mkdir -p " + quote(parent) + "\n" +
                "/usr/sbin/chown root:wheel " + quote(parent) + "\n" +
                "/bin/chmod -N " + quote(parent) + "\n" +
                "/bin/chmod 700 " + quote(parent) + "\n" +
                "/bin/mkdir " + quote(stage) + "\n" +
                "trap " + quote("/bin/rm -rf " + quote(stage)) + " EXIT\n" +
                "/usr/bin/ditto " + quote(bundled.path) + " " + quote(stage + "/LockedUseInstaller") + "\n" +
                "/bin/test ! -L " + quote(stage + "/LockedUseInstaller") + "\n" +
                "/bin/test -f " + quote(stage + "/LockedUseInstaller") + "\n" +
                "/usr/sbin/chown root:wheel " + quote(stage + "/LockedUseInstaller") + "\n" +
                "/bin/chmod -N " + quote(stage + "/LockedUseInstaller") + "\n" +
                "/bin/chmod 700 " + quote(stage + "/LockedUseInstaller") + "\n" +
                "/usr/bin/codesign --verify --strict -R " + quote(requirement) + " " + quote(stage + "/LockedUseInstaller") + "\n" +
                quote(stage + "/LockedUseInstaller") + " uninstall"
            try elevate(commands)
            return
        }
        let base = "/Library/Application Support/LockedUse/"
        let current = base + "LockedUseInstaller"
        let path = current
        let requirement = "=identifier \"com.nia-teams.locked-use.installer\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        try elevate("set -eu\n/usr/bin/codesign --verify --strict -R " + quote(requirement) + " " + quote(path) + "\n" + quote(path) + " " + quote(action))
    }

    private static func disable() throws {
        guard LockedUseSession.current().state == .unlocked else { throw LockedUseError.message("Unlock the Mac normally before administrator removal.") }
        try installedAction("uninstall")
    }
}
