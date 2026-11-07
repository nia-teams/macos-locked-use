import Darwin
import Foundation
import LockedUseNative
@testable import LockedUseKit
import XCTest

final class LockedUseStagedTreeTests: XCTestCase {
    private var parent: URL!
    private var stage: URL!
    private var app: URL { stage.appendingPathComponent("Client.app") }

    override func setUpWithError() throws {
        // Resolve only the test harness's temp location, never validator inputs.
        parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("staged-tree-\(UUID())")
        stage = parent.appendingPathComponent("stage")
        try directory("Client.app/Contents")
        try file("LockedUseInstaller")
        XCTAssertEqual(chmod(parent.path, 0o700), 0)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: parent)
    }

    private func directory(_ path: String) throws {
        try FileManager.default.createDirectory(at: stage.appendingPathComponent(path), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
    }

    private func file(_ path: String) throws {
        let url = stage.appendingPathComponent(path)
        try Data("fixture".utf8).write(to: url)
        XCTAssertEqual(chmod(url.path, 0o644), 0)
    }

    private func link(_ path: String, _ target: String) throws {
        try FileManager.default.createSymbolicLink(atPath: stage.appendingPathComponent(path).path, withDestinationPath: target)
    }

    private func validate(_ root: URL? = nil, allow: Bool = true) throws {
        try LockedUseStagedTree.validate(root ?? stage, allowContainedSymlinksUnder: allow ? app : nil,
                                        owner: geteuid(), trustedStopAncestor: parent)
    }

    private func rejected(_ root: URL? = nil, allow: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try validate(root, allow: allow), file: file, line: line) {
            XCTAssertEqual($0 as? LockedUseStagedTree.Failure, .untrusted, file: file, line: line)
        }
    }

    func testVersionedFrameworkAndWritableSymlinkModesAreAccepted() throws {
        let framework = "Client.app/Contents/Frameworks/Sparkle.framework"
        try directory(framework + "/Versions/B/Resources")
        try directory(framework + "/Versions/B/Updater.app")
        try directory(framework + "/Versions/B/XPCServices")
        try file(framework + "/Versions/B/Sparkle")
        try file(framework + "/Versions/B/Autoupdate")
        try link(framework + "/Versions/Current", "B")
        for name in ["Sparkle", "Autoupdate", "Resources", "Updater.app", "XPCServices"] {
            let path = framework + "/" + name
            try link(path, "Versions/Current/" + name)
            let command = Process()
            command.executableURL = URL(fileURLWithPath: "/bin/chmod")
            command.arguments = ["-h", "0777", stage.appendingPathComponent(path).path]
            try command.run(); command.waitUntilExit()
            XCTAssertEqual(command.terminationStatus, 0)
            let fd = open(stage.appendingPathComponent(path).path, O_RDONLY | O_SYMLINK | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(fd, 0)
            XCTAssertEqual(ocu_has_mutating_acl(fd), 0)
            close(fd)
        }
        try validate()
        rejected(allow: false)
        // A parent-relative link that stays strictly inside the app is valid too.
        try link("Client.app/Contents/parentRelative", "Frameworks/../Frameworks/Sparkle.framework/Sparkle")
        try validate()
    }

    func testTrailingSlashTargetsRequireDirectoriesAcrossChains() throws {
        let framework = "Client.app/Contents/Frameworks/Sparkle.framework"
        try directory(framework + "/Versions/B/Resources")
        try file(framework + "/Versions/B/Sparkle")
        try link(framework + "/Versions/Current", "B/")
        try link(framework + "/Resources", "Versions/Current/Resources/")
        try link(framework + "/directoryChain", "Resources/")
        try validate()
        try link(framework + "/Sparkle", "Versions/Current/Sparkle/")
        rejected()
        try FileManager.default.removeItem(at: stage.appendingPathComponent(framework + "/Sparkle"))
        try link(framework + "/Sparkle", "Versions/Current/Sparkle")
        try link(framework + "/fileChain", "Sparkle/")
        rejected()
    }

    func testHelperAndAppRootsCannotBeLinks() throws {
        for name in ["LockedUseInstaller", "LockedUseService", "LockedUseGuardian", "LockedUseAuth.bundle", "Client.app"] {
            let path = stage.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
            try link(name, ".")
            rejected()
            try FileManager.default.removeItem(at: path)
        }
    }

    func testLinksInsideHelperBundlesAreRejected() throws {
        try directory("LockedUseAuth.bundle/Contents")
        try file("LockedUseAuth.bundle/Contents/target")
        try link("LockedUseAuth.bundle/Contents/alias", "target")
        rejected()
    }

    func testAbsoluteEscapingDanglingAndLoopingLinksAreRejected() throws {
        for target in ["/etc/hosts", app.appendingPathComponent("Contents").path, "../../LockedUseInstaller", "Missing", ".//Missing"] {
            try link("Client.app/Contents/evil", target)
            rejected()
            try FileManager.default.removeItem(at: app.appendingPathComponent("Contents/evil"))
        }
        try link("Client.app/Contents/dir", "..")
        try link("Client.app/Contents/leaf", "dir/../LockedUseInstaller")
        rejected()
        try FileManager.default.removeItem(at: app.appendingPathComponent("Contents/dir"))
        try FileManager.default.removeItem(at: app.appendingPathComponent("Contents/leaf"))
        try link("Client.app/Contents/a", "b")
        try link("Client.app/Contents/b", "a")
        rejected()
    }

    func testUnsafeModesAndSpecialFilesAreRejected() throws {
        try file("Client.app/Contents/target")
        try link("Client.app/Contents/alias", "target")
        let target = app.appendingPathComponent("Contents/target")
        for mode in [mode_t(0o666), mode_t(0o4755), mode_t(0o2644)] {
            XCTAssertEqual(chmod(target.path, mode), 0)
            rejected()
        }
        XCTAssertEqual(chmod(target.path, 0o644), 0)
        let contents = app.appendingPathComponent("Contents")
        XCTAssertEqual(chmod(contents.path, 0o775), 0)
        rejected()
        XCTAssertEqual(chmod(contents.path, 0o755), 0)
        XCTAssertEqual(mkfifo(app.appendingPathComponent("Contents/pipe").path, 0o600), 0)
        rejected()
    }

    func testMutatingACLsOnFileDirectoryAndLinkAreRejected() throws {
        try file("Client.app/Contents/target")
        try link("Client.app/Contents/alias", "target")
        for name in ["target", "", "alias"] {
            let path = app.appendingPathComponent("Contents").appendingPathComponent(name).path
            let command = Process()
            command.executableURL = URL(fileURLWithPath: "/bin/chmod")
            command.arguments = ["-h", "+a", "everyone allow write", path]
            try command.run(); command.waitUntilExit()
            XCTAssertEqual(command.terminationStatus, 0)
            rejected()
            let clear = Process()
            clear.executableURL = URL(fileURLWithPath: "/bin/chmod")
            clear.arguments = ["-h", "-N", path]
            try clear.run(); clear.waitUntilExit()
            XCTAssertEqual(clear.terminationStatus, 0)
            try validate()
        }
    }

    func testOwnerAndAllowedSubtreeBoundaries() throws {
        XCTAssertThrowsError(try LockedUseStagedTree.validate(stage, allowContainedSymlinksUnder: app,
            owner: geteuid() == 0 ? 1 : 0, trustedStopAncestor: parent))
        for allowed in [stage!, parent!, stage.appendingPathComponent("Missing"), stage.appendingPathComponent("LockedUseInstaller")] {
            XCTAssertThrowsError(try LockedUseStagedTree.validate(stage, allowContainedSymlinksUnder: allowed,
                owner: geteuid(), trustedStopAncestor: parent))
        }
        // A directory link may not resolve to the app root itself.
        try link("Client.app/Contents/rootAlias", "..")
        rejected()
        try FileManager.default.removeItem(at: app.appendingPathComponent("Contents/rootAlias"))
        XCTAssertEqual(chmod(stage.path, 0o775), 0)
        rejected()
        XCTAssertEqual(chmod(stage.path, 0o755), 0)
        try validate()
    }

    func testRegularFileRootAndAncestorChecks() throws {
        let plist = stage.appendingPathComponent("daemon.plist")
        try file("daemon.plist")
        try validate(plist, allow: false)
        rejected(plist) // A file cannot designate a symlink subtree.
        for mode in [mode_t(0o666), mode_t(0o4755)] {
            XCTAssertEqual(chmod(plist.path, mode), 0)
            rejected(plist, allow: false)
        }
        XCTAssertEqual(chmod(plist.path, 0o644), 0)
        XCTAssertEqual(chmod(stage.path, 0o775), 0)
        rejected(plist, allow: false)
        XCTAssertEqual(chmod(stage.path, 0o755), 0)
        try link("daemon-link", "daemon.plist")
        rejected(stage.appendingPathComponent("daemon-link"), allow: false)
        try FileManager.default.createSymbolicLink(atPath: parent.appendingPathComponent("alias").path, withDestinationPath: "stage")
        rejected(parent.appendingPathComponent("alias/daemon.plist"), allow: false)
    }
}
