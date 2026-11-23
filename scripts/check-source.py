#!/usr/bin/env python3
"""Portable source invariants only; does not replace macOS builds/device tests."""
from pathlib import Path
import hashlib
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parent.parent


def read(name):
    return (ROOT / name).read_text()


class SourceTests(unittest.TestCase):
    def test_shield_pinning_and_nonblocking_bounded_repair(self):
        surface = read("Sources/Guardian/DisplayShieldSurface.swift")
        for token in ["private var pinnedFrame: NSRect?", "pinnedFrame ?? frameRect",
                      "super.setFrame(pinnedFrame ?? frameRect, display: flag)",
                      "NSWindow.didMoveNotification", "NSWindow.didResizeNotification",
                      "NSWindow.didChangeScreenNotification", "NSWorkspace.activeSpaceDidChangeNotification",
                      "NSApplication.didChangeScreenParametersNotification", "guard !reanchoring",
                      "reanchor(force: true)", "recovery.failure(observed:", "CATransaction.flush()", "import QuartzCore",
                      "[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]",
                      "LockedUseShieldCoverage.screenLocalRect", "CGDisplayBounds(id)",
                      "window.windowNumber", "getpid()", "alpha.isFinite, alpha >= 0.99, alpha <= 1"]:
            self.assertIn(token, surface)
        health = surface[surface.index("    func coverageFailure()"):]
        for forbidden in ["Thread.sleep", "RunLoop.main.run", "RunLoop.current.run", "try? reconcileScreens()"]:
            self.assertNotIn(forbidden, health)
        repair = read("Sources/LockedUseKit/LockedUseShieldRepair.swift")
        for token in ["timeout: TimeInterval = 1.2", "mismatchStarted", "verifiedCoverage",
                      "guard unlocked, verifiedCoverage", "now - mismatchStarted >= Self.timeout",
                      "if latchedFailure == nil", "baselineTopology", 'latch("topologyChanged")']:
            self.assertIn(token, repair)
        self.assertNotIn("Thread.sleep", repair)
        self.assertIn("shields.observeUnlockedSession()", read("Sources/Guardian/DisplayGuardian.swift"))
        self.assertIn("surface.observeUnlockedSession()", read("Sources/Guardian/WatchdogShield.swift"))
        self.assertIn("let healthFailure = shield?.healthFailure", read("Sources/Guardian/GuardianMain.swift"))

    def test_topology_is_armed_before_staging_and_old_shields_are_never_replaced(self):
        surface = read("Sources/Guardian/DisplayShieldSurface.swift")
        notification = surface[surface.index("    @objc private func surfaceChanged"):surface.index("    func observeUnlockedSession")]
        self.assertIn("observeTopologyAndSupplement()", notification)
        supplement = surface[surface.index("    private func observeTopologyAndSupplement"):surface.index("    private func reanchor")]
        self.assertLess(supplement.index("recovery.observeTopology("), supplement.index("!staging"))
        self.assertIn("screens.filter { windows[$0.0] == nil }", supplement)
        self.assertNotIn(".close()", supplement)
        self.assertNotIn("removeAll()", supplement)
        self.assertIn('catch { recovery.latch("shieldReconciliationFailed") }', supplement)
        prepare = surface[surface.index("    func coverDisplays("):surface.index("    private func stageScreens")]
        self.assertLess(prepare.index("recovery.observeTopology(displayTopology())"), prepare.index("Self.ensureDisplayAwake()"))
        self.assertLess(prepare.index("recovery.observeTopology(displayTopology())"), prepare.index("try stageScreens("))
        self.assertGreaterEqual(prepare.count("recovery.observeTopology(displayTopology())"), 2)
        self.assertIn("unlocked: false", prepare)
        self.assertIn("close() // Includes all published candidates", prepare)
        close = surface[surface.index("    func close()"):surface.index("    private func screenIDs()")]
        self.assertLess(close.index("recovery = LockedUseShieldRepair()"), close.index("window.close()"))
        self.assertIn("observedUnlock = false", close)
        self.assertNotIn("try?", surface)

    def test_every_active_and_mirrored_display_requires_verified_geometry(self):
        surface = read("Sources/Guardian/DisplayShieldSurface.swift")
        raw = surface[surface.index("    private func rawCoverageFailure()"):]
        for token in ["var verifiedBounds:", "verifiedBounds[id] = rect", "for activeID in active.prefix(Int(count))",
                      "LockedUseShieldCoverage.coveringShieldID", "CGDisplayMirrorsDisplay(activeID)",
                      "let activeDisplay = CGDisplayBounds(activeID)", "let ownDisplay = CGDisplayBounds(shieldID)",
                      "LockedUseShieldCoverage.coversAssignedAndActive", "count > 0, Int(count) <= active.count"]:
            self.assertIn(token, raw)
        self.assertLess(raw.index("verifiedBounds[id] = rect"), raw.index("for activeID in active.prefix"))
        coverage = read("Sources/LockedUseKit/LockedUseShieldCoverage.swift")
        self.assertIn("covers(surface, display: assigned) && covers(surface, display: active)", coverage)
        tests = read("Tests/LockedUseKitTests/LockedUseShieldCoverageTests.swift")
        self.assertIn("testMirroredDisplaySelectionDoesNotStandInForCoverage", tests)
        self.assertIn("testActiveCoverageAlsoRequiresAssignedDisplayAndValidGeometry", tests)

    def test_space_recovery_and_atomic_staging_regressions_are_exercised(self):
        tests = read("Tests/LockedUseKitTests/LockedUseShieldRepairTests.swift")
        for token in ["width: 1512, height: 982", "x: -1921, y: -243, width: 2260, height: 1469",
                      "testReportedSpaceSlideSurvivesSixHundredMillisecondsAndResets",
                      "testTopologyNotificationBeforePollLatchesAcrossSuccessfulReconciliation",
                      "testTopologyBaselineIsArmedBeforeFirstCandidateAndNeverRebased",
                      "testSupplementalStagingNeverReplacesVerifiedEntries",
                      "testEmptyStagingPreservesLiveWindowsAndLatchesFailure",
                      "testFailedStagingClosesOnlyCandidatesAndPreservesLiveWindows",
                      "testPreparationAndUnverifiedSurfacesNeverGetGrace",
                      "testIntegrityFailuresImmediatelyAbortActiveRecovery",
                      "testPersistentMismatchRequestsRelock"]:
            self.assertIn(token, tests)
        self.assertIn("testChainedActionSurvivesBoundedSpaceSlideButPersistentDriftRelocks",
                      read("Tests/LockedUseKitTests/LockedUseBrokerCoordinatorTests.swift"))

    def test_manifest_is_standalone(self):
        manifest = read("Package.swift")
        self.assertIn("// swift-tools-version: 5.10", manifest)
        self.assertIn(".macOS(.v14)", manifest)
        self.assertNotIn(".package(", manifest)
        for name in ["LockedUseNative", "LockedUseKit", "LockedUseCLI", "LockedUseInstaller", "LockedUseService", "LockedUseGuardian", "LockedUseKitTests"]:
            self.assertIn(f'name: "{name}"', manifest)
        for directory in ["Sources/LockedUseNative/include", "Sources/LockedUseKit", "Sources/LockedUseCLI", "Sources/Installer", "Sources/Broker", "Sources/Guardian", "Tests/LockedUseKitTests"]:
            self.assertTrue((ROOT / directory).is_dir())

    def test_no_extracted_non_locked_use_dependencies(self):
        forbidden = re.compile(r"\b(ComputerUseError|ComputerUseService|ToolCallResult|SkyLightSPI|SkyClickDispatcher|SkyKeyboardDispatcher|parseLockedUseCLI)\b")
        for parent in ["Sources", "Tests"]:
            for path in (ROOT / parent).rglob("*.swift"):
                self.assertIsNone(forbidden.search(path.read_text()), str(path))
        for path in (ROOT / "scripts").glob("*.sh"):
            self.assertNotRegex(path.read_text(), r"experiments/LockedUse|packages/|plugins/open-computer-use|assets/app-icons")
            subprocess.run(["bash", "-n", str(path)], check=True)

    def test_namespace_has_no_vendor_tokens(self):
        # Split spellings so this check also scans itself without exemptions.
        forbidden = ["open" + "computeruse", "Open" + "ComputerUse", "OCU" + "Lock", "OCU" + "Guardian"]
        paths = [ROOT / "Package.swift"]
        for directory in ["Sources", "AuthorizationPlugin", "Tests", "scripts"]:
            paths.extend(p for p in (ROOT / directory).rglob("*") if p.is_file() and "__pycache__" not in p.parts)
        for path in paths:
            text = path.read_text()
            for token in forbidden:
                self.assertNotIn(token, text, str(path))

    def test_plain_helper_and_single_host_permissions(self):
        helper = read("scripts/build-locked-use-guardian.sh")
        self.assertNotIn("Contents/", helper)
        self.assertNotIn(".app", helper)
        self.assertIn("--force --options runtime,library --timestamp --identifier com.nia-teams.locked-use.guardian", helper)
        components = read("scripts/build-locked-use-components.sh")
        for token in ["LockedUseDemo.app", "com.nia-teams.locked-use.fixture.dev", 'ditto "$guardian_source" "$output/LockedUseGuardian"']:
            self.assertIn(token, components)
        self.assertIn("bundle_id=com.nia-teams.locked-use.app", read("scripts/build-locked-use.sh"))
        settings = read("Sources/LockedUseKit/LockedUseSettings.swift")
        self.assertIn("case host }", settings)
        for token in ["AXIsProcessTrustedWithOptions", "CGRequestScreenCaptureAccess", "CGRequestListenEventAccess", '["--permission-status"]', "toggle Accessibility, Screen Recording, and Input Monitoring ON for the HOST app"]:
            self.assertIn(token, settings)
        self.assertNotIn("guardian.terminationStatus == 0", settings)
        for name in ["LockedUseInstaller", "LockedUseService", "LockedUseGuardian", "LockedUseAuth.bundle"]:
            self.assertIn(name, settings + read("Sources/Installer/InstallerMain.swift"))
        rules = read("Sources/LockedUseKit/LockedUseAuthorizationRules.swift")
        for token in ["LockedUseAuth:remote,privileged", "LockedUseAuth:remote", "LockedUseAuth:load-check,privileged", "com.nia-teams.locked-use.load-check", "com.nia-teams.locked-use.remote"]:
            self.assertIn(token, rules)
        for name in ["Sources/Installer/InstallerMain.swift", "AuthorizationPlugin/RemotePlugin.m", "AuthorizationPlugin/RemotePluginTests.c"]:
            self.assertIn("LockedUseAuth-loaded-v1", read(name))
        license = read("LICENSE")
        self.assertIn("Copyright (c) 2026 Leo", license)
        self.assertIn("Copyright (c) 2026 Nia Teams", license)

    def test_staged_tree_confines_bundle_symlinks(self):
        tree = read("Sources/LockedUseKit/LockedUseStagedTree.swift")
        for token in ["public enum LockedUseStagedTree", "case untrusted", "owner: 0",
                      "trustedStopAncestor", "ancestors.reversed()", "lstat(path, &info)",
                      "O_SYMLINK", "O_NOFOLLOW", "O_CLOEXEC", "fstat(fd, &opened)",
                      "opened.st_dev == info.st_dev", "opened.st_ino == info.st_ino",
                      "opened.st_uid == owner", "ocu_has_mutating_acl(fd) == 0",
                      "0o6022", "Darwin.readlink", "Int(PATH_MAX)",
                      '!text.hasPrefix("/")', "hops <= 16", "guard !stack.isEmpty",
                      "isInside(path, allowed)", "O_DIRECTORY", "directories.popLast()",
                      "FileManager.default.contentsOfDirectory(atPath: directory)", "directories.append(path)",
                      'parts.dropLast().allSatisfy({ !$0.isEmpty })', 'parts[parts.count - 1] = "."']:
            self.assertIn(token, tree)
        self.assertNotIn("resolvingSymlinksInPath", tree)
        self.assertNotIn(".enumerator(", tree)
        link_case = tree[tree.index("                case S_IFLNK:"):tree.index("                default: throw Failure.untrusted")]
        self.assertNotIn("directories.append", link_case)
        installer = read("Sources/Installer/InstallerMain.swift")
        self.assertIn("LockedUseStagedTree.validate(url, allowContainedSymlinksUnder: allowed)", installer)
        self.assertIn('trustedTree(source, allowContainedSymlinksUnder: source.appendingPathComponent("Client.app", isDirectory: true))', installer)
        self.assertIn("try trustedTree(daemon)", installer)
        settings = read("Sources/LockedUseKit/LockedUseSettings.swift")
        enable = settings[settings.index('let shell = "set -eu'):settings.index("try elevate(shell)")]
        self.assertEqual(enable.count("/usr/bin/ditto --noacl "), 2)
        for token in ['quote(stage + "/Client.app")', '"/bin/test ! -L "', '"/bin/test -d "',
                      '" -path "', '" -prune -o -type l', '/usr/sbin/chown -hR -P',
                      '/usr/bin/find -P', '/bin/chmod -R -P -N', '/bin/chmod -R -P go-w']:
            self.assertIn(token, enable)
        self.assertLess(enable.index('"/bin/test ! -e "'), enable.index('quote(LockedUseHost.currentBundle.bundleURL.path)'))
        self.assertLess(enable.index('" -prune -o -type l'), enable.index('/usr/sbin/chown -hR -P'))
        self.assertLess(enable.index('/bin/chmod -R -P -N'), enable.index('quote(LockedUseHost.currentBundle.bundleURL.path)'))
        self.assertLess(enable.index('/bin/chmod -R -P go-w'), enable.index('/usr/bin/codesign'))
        self.assertNotIn('quote(stage) + " -type l', enable)
        self.assertNotIn('/bin/chmod -h -N', enable)
        self.assertNotIn('--noxattr', enable)
        self.assertNotIn('--norsrc', enable)
        self.assertEqual(read("VERSION").strip(), "0.1.5")
        tests = read("Tests/LockedUseKitTests/LockedUseStagedTreeTests.swift")
        for token in ["testVersionedFramework", "testHelperAndAppRoots", "testAbsoluteEscaping",
                      "testUnsafeModes", "testMutatingACLs", "testRegularFileRoot", "testTrailingSlashTargetsRequireDirectoriesAcrossChains"]:
            self.assertIn(token, tests)
        self.assertNotIn("lchmod(", tests)
        self.assertIn('["-h", "0777",', tests)

    def test_console_unlock_observer_is_gated_and_identity_matched(self):
        broker = read("Sources/Broker/BrokerMain.swift")
        for token in ["coordinator.phase == .awaitingManualUnlock", "coordinator.isFullyReleased", "LockedUseSession.consoleSession(userID: owner.userID, auditSessionID: owner.auditSessionID)", "observeConsoleManualUnlock(session: session, now: now)"]:
            self.assertIn(token, broker)
        coordinator = read("Sources/LockedUseKit/LockedUseBrokerCoordinator.swift")
        method = coordinator[coordinator.index("public mutating func observeConsoleManualUnlock"):coordinator.index("public mutating func tick")]
        for token in ["isFullyReleased", "issued == nil", "session.userID == owner.userID", "session.auditSessionID == owner.auditSessionID", "session.state == .unlocked", "machine.observe(session: session, now: now)"]:
            self.assertIn(token, method)
        session = read("Sources/LockedUseKit/LockedUseDiagnostics.swift")
        for token in ["SLSSessionCopyAllSessionProperties", "CGSSessionCopyAllSessionProperties", "@convention(c) () -> Unmanaged<CFArray>?", "CFGetTypeID(number) == CFBooleanGetTypeID()"]:
            self.assertIn(token, session)

    def test_cooldown_configuration_release_barrier_and_durable_cleanup(self):
        configuration = read("Sources/LockedUseKit/LockedUseBrokerConfiguration.swift")
        for token in ["defaultCooldownSeconds: TimeInterval = 60", "maximumCooldownSeconds: TimeInterval = 86_400",
                      "cooldownSeconds: TimeInterval?", "validatedCooldownSeconds", "value.isFinite", "value <= 0",
                      "value > maximumCooldownSeconds", "c.contains(.cooldownSeconds)", "c.decodeNil(forKey: .cooldownSeconds)",
                      "c.encodeNil(forKey: .cooldownSeconds)", "schemaVersion = 1"]:
            self.assertIn(token, configuration)
        for name in ["LockedUseCommand.swift", "LockedUseSettings.swift"]:
            self.assertIn("--cooldown", read("Sources/LockedUseKit/" + name))
        self.assertIn("LockedUseCommand.parse(Array(arguments.dropFirst()))", read("Sources/LockedUseKit/LockedUseSettings.swift"))
        installer = read("Sources/Installer/InstallerMain.swift")
        self.assertIn('LockedUseCommand.parse(["enable"] + rest)', installer)
        self.assertIn("cooldownSeconds: existing.cooldownSeconds", installer)
        coordinator = read("Sources/LockedUseKit/LockedUseBrokerCoordinator.swift")
        arm = coordinator[coordinator.index("private mutating func armCooldownIfReady"):coordinator.index("public mutating func tick")]
        tick = coordinator[coordinator.index("public mutating func tick"):coordinator.index("public mutating func disconnected")]
        for method in [arm, tick]:
            for token in ["machine.phase == .awaitingManualUnlock", "isFullyReleased", "issued == nil", "unshieldedDiagnostic == nil", "!recoveryProbe"]:
                self.assertIn(token, method)
        apply = coordinator[coordinator.index("private mutating func apply"):coordinator.index("private mutating func reply")]
        self.assertIn("armCooldownIfReady(now: receiptTime)", apply)
        self.assertIn("cooldownDeadline = now + remaining", arm)
        self.assertIn("now >= deadline", tick)
        self.assertIn("machine.completeCooldown(now: now)", tick)
        for operation in ["guardianReleased", "watchdogReleased"]:
            section = coordinator.split("case ." + operation + ":", 1)[1].split("        case .", 1)[0]
            self.assertIn("armCooldownIfReady(now: now)", section)
        record = coordinator[coordinator.index("public func recoveryRecord"):coordinator.index("public mutating func handle")]
        self.assertIn("phase != .idle || !isFullyReleased", record)
        self.assertIn("cooldownRemainingSeconds: cooldownRemainingAtRelease", record)
        self.assertNotIn("cooldownDeadline -", record)
        self.assertIn("min(cooldownSeconds, recovery.cooldownRemainingSeconds ?? cooldownSeconds)", coordinator)
        broker = read("Sources/Broker/BrokerMain.swift")
        self.assertIn("cooldownSeconds: configuration.cooldownSeconds", broker)
        persistence = broker[broker.index("private func persistRecovery"):broker.index("private func persistValidation")]
        for token in ["lease-recovery.json", "if data == lastRecoveryData { return }", "unlink(path)", "fsync(directory)"]:
            self.assertIn(token, persistence)
        self.assertIn("cooldownRemainingSeconds", read("Sources/LockedUseKit/LockedUseRecoveryRecord.swift"))
        self.assertIn("public let cooldownRemainingSeconds: TimeInterval?", read("Sources/LockedUseKit/LockedUseIPC.swift"))
        diagnostics = read("Sources/LockedUseKit/LockedUseDiagnostics.swift")
        self.assertIn("reply?.guardsReleased == false", diagnostics)
        self.assertLess(diagnostics.index("if shieldsReleasing {"), diagnostics.index("else if let remaining"))
        for token in ["cooldownRemainingSeconds: Int?", "cooldownConfiguredSeconds: Int?", "awaitingManualUnlock: Bool?", "shieldsReleasing: Bool?"]:
            self.assertIn(token, diagnostics)
        self.assertTrue((ROOT / "Tests/LockedUseKitTests/LockedUseCooldownTests.swift").is_file())

    def test_guard_release_is_replayed_and_process_exits_are_reaped(self):
        coordinator = read("Sources/LockedUseKit/LockedUseBrokerCoordinator.swift")
        for operation in ["guardianReport", "pluginFinished"]:
            section = coordinator.split("case ." + operation + ":", 1)[1].split("        case .", 1)[0]
            self.assertIn("let owner = stoppableOwner", section)
        self.assertIn("[.idle, .relocking, .awaitingManualUnlock].contains(machine.phase) ? nil : machine.owner", coordinator)
        reply = coordinator.split("private mutating func reply", 1)[1]
        guardian = reply.split("if isGuardian(context)", 1)[1].split("if isWatchdog(context)", 1)[0]
        self.assertIn('if effects.contains("releaseGuards") { releaseSent = true }', guardian)
        self.assertIn('else if releaseSent { effects.append("releaseGuards") }', guardian)
        self.assertIn('effects.contains("releaseGuards") ? .release', reply)
        broker = read("Sources/Broker/BrokerMain.swift")
        self.assertIn("kill(watchdog.processID, 0) != 0, errno == ESRCH", broker)
        self.assertIn("try self.coordinator.watchdogProcessExited()", broker)

    def test_guards_consume_recovery_effects_without_relocking_denied_leases(self):
        guardian = read("Sources/Guardian/DisplayGuardian.swift")
        for token in ["try handleBrokerEffects(hello.effects)", "try handleBrokerEffects(reply.effects)",
                      'hello.effects.contains("releaseGuards")', "case .stopRequested: reason = nil",
                      "requested: policy.phase == .relocking && policy.isQuiesced",
                      "execute(policy.releaseForDeniedLease(), deniedLease: true)", "now >= nextBrokerRetry"]:
            self.assertIn(token, guardian)
        policy = read("Sources/LockedUseKit/LockedUseGuardianPolicy.swift")
        denied = policy.split("func releaseForDeniedLease", 1)[1].split("public mutating func poll", 1)[0]
        self.assertIn("phase = .finished", denied)
        self.assertIn("return [.releaseShield]", denied)
        self.assertNotIn(".requestRelock", denied)
        watchdog = read("Sources/Guardian/WatchdogBrokerLink.swift")
        for token in ['recovery.effects.contains("releaseWatchdog")', "systemUptime >= nextRetry"]:
            self.assertIn(token, watchdog)
        denial = watchdog.split("if recovery.result == .denied", 1)[1].split("hasRegisteredOnce = true", 1)[0]
        self.assertRegex(denial, r"if hasRegisteredOnce \{\s+leaseDenied = true\s+\} else \{")
        self.assertIn("operation: .watchdogHello, leaseID: bootstrap.leaseID, token: bootstrap.token", denial)
        self.assertIn("leaseDenied = hello.result == .denied", denial)
        self.assertRegex(denial, r"if leaseDenied \{\s+candidate\.close\(\)\s+mutex\.lock\(\); release = \.deniedLease; mutex\.unlock\(\)\s+return")
        main = read("Sources/Guardian/GuardianMain.swift")
        self.assertLess(main.index("if brokerRelease == .deniedLease"), main.index("let presentationReady = lockPresentation.ready"))

    def test_structured_exec_stops_and_gui_dispatch(self):
        error = read("Sources/LockedUseKit/LockedUseError.swift")
        for code in [64, 75, 76, 77]:
            self.assertRegex(error, rf"\b{code}\b")
        for name in ["LockedUseIPC.swift", "LockedUseSessionHolder.swift", "LockedUseConnection.swift"]:
            self.assertIn("stopReason", read("Sources/LockedUseKit/" + name))
        cli = read("Sources/LockedUseCLI/LockedUseMain.swift")
        self.assertIn("if protected { try validate() }", cli)
        self.assertIn("withAsyncValidator", cli)
        for action in ["click", "type", "key", "capture"]:
            self.assertIn(action, read("Sources/LockedUseKit/LockedUseGUICommand.swift"))
        for name in ["LockedUseGUI.swift", "LockedUseClick.swift", "LockedUseKeyboard.swift", "LockedUseKeyboardEvents.swift", "LockedUseInputSPI.swift"]:
            text = read("Sources/LockedUseKit/" + name)
            self.assertNotIn(".post(tap:", text)
            self.assertIn("LockedUseActionScope.validate()", text)
        spi = read("Sources/LockedUseKit/LockedUseInputSPI.swift")
        for token in ["SLEventPostToPid", "SLEventSetIntegerValueField", "CGEventSetWindowLocation", "SLPSPostEventRecordTo"]:
            self.assertIn(token, spi)
        gui = read("Sources/LockedUseKit/LockedUseGUI.swift")
        self.assertIn("SCContentFilter(desktopIndependentWindow: window)", gui)
        self.assertIn("SCScreenshotManager.captureImage", gui)
        self.assertIn("ignoreShadowsSingleWindow = true", gui)
        self.assertIn("com.nia-teams.locked-use.holder", read("Sources/LockedUseKit/LockedUseSessionHolder.swift"))

    def test_mouse_button_is_carried_through_targeted_dispatch(self):
        parser = read("Sources/LockedUseKit/LockedUseGUICommand.swift")
        for token in ['public enum LockedUseMouseButton: String, Sendable', 'case left, right',
                      'public let button: LockedUseMouseButton',
                      'LockedUseMouseButton(rawValue: values["--button"] ?? "left")',
                      'case .click: allowed.formUnion(["--x", "--y", "--button"])']:
            self.assertIn(token, parser)
        gui = read("Sources/LockedUseKit/LockedUseGUI.swift")
        self.assertEqual(gui.count("button: LockedUseMouseButton = .left"), 2)
        self.assertEqual(gui.count("clickCount: clickCount, button: button)"), 2)
        self.assertIn("button: request.button)", read("Sources/LockedUseCLI/LockedUseMain.swift"))
        click = read("Sources/LockedUseKit/LockedUseClick.swift")
        for token in ['self == .right ? .right : .left',
                      'return button == .right ? .rightMouseDown : .leftMouseDown',
                      'return button == .right ? .rightMouseUp : .leftMouseUp',
                      'return .mouseMoved', 'mouseType: step.kind.cgEventType(button: button)',
                      'mouseButton: step.kind == .moved ? .left : button.cgMouseButton', 'button: button,',
                      'static let buttonNumber: UInt32 = 3',
                      'field: EventField.buttonNumber, value: event.type == .mouseMoved ? 0 : Int64(button.cgMouseButton.rawValue)',
                      'skyClickEventRecipe(clickCount: clickCount, button: button,',
                      'includePrimer: button == .left && !isPopupTarget)',
                      'if button == .left && includePrimer',
                      'if button == .left', 'if button != .right',
                      'let effectiveTarget = resolveSkyClickTarget(target, onScreenWindowInfo: onScreen)',
                      'try spi.postToPid(event, pid: effectiveTarget.pid)']:
            self.assertIn(token, click)
        self.assertEqual(click.count('try spi.postToPid(event, pid: effectiveTarget.pid)'), 1)
        self.assertNotIn('event.postToPid(', click)
        # Single-window capture already includes child NSMenus on macOS 15.6.1.
        self.assertEqual(gui.count('SCScreenshotManager.captureImage('), 1)
        self.assertEqual(gui.count('SCContentFilter(desktopIndependentWindow:'), 1)
        for token in ['sameAppPopupsAbove', 'lockedUsePopupDrawRect', 'CGContext(', 'overlay']:
            self.assertNotIn(token, gui)
        self.assertNotIn('lockedUsePopupDrawRect', click)
        self.assertIn('func sameAppPopupsAbove(', click)
        self.assertIn('let isPopupTarget = effectiveTarget.windowID != target.windowID', click)
        popup_focus = click[click.index('} else if isPopupTarget {'):click.index('} else {', click.index('} else if isPopupTarget {'))]
        self.assertIn('spi.syntheticTargetFocusContext(', popup_focus)
        self.assertIn('targetPID: target.pid', popup_focus)
        self.assertIn('targetWindowID: target.windowID', popup_focus)
        self.assertNotIn('beginSyntheticTargetFocus', popup_focus)
        self.assertNotIn('makeSyntheticTargetWindowKey', click)
        spi = read("Sources/LockedUseKit/LockedUseInputSPI.swift")
        resolve_focus = spi[spi.index('    func syntheticTargetFocusContext('):spi.index('    func beginSyntheticTargetFocus(')]
        self.assertIn('getProcessForPIDFunction(targetPID, bytes.baseAddress)', resolve_focus)
        self.assertNotIn('postActivationCommand(', resolve_focus)
        self.assertNotIn('postEventRecordFunction(', resolve_focus)
        end_focus = spi[spi.index('    func endSyntheticTargetFocus('):spi.index('    private func unavailableError(')]
        self.assertEqual(end_focus.count('postActivationCommand('), 1)
        self.assertIn('postActivationCommand(context.deactivateTarget)', end_focus)
        self.assertNotIn('beginSyntheticTargetFocus', end_focus)
        # The production boundary covers AX selection and every mouse post.
        self.assertIn('try dispatchWithFocusCleanup(focusContext: focusContext, button: button,', click)
        self.assertIn('endFocus: spi.endSyntheticTargetFocus) {', click)
        lifecycle = click[click.index('    static func dispatchWithFocusCleanup('):click.index('    // Native NSMenu')]
        failure = lifecycle[lifecycle.index('} catch {'):lifecycle.index('        if button != .right')]
        self.assertIn('if let focusContext {', failure)
        self.assertIn('try? endFocus(focusContext)', failure)
        self.assertLess(failure.index('try? endFocus(focusContext)'), failure.index('throw error'))
        self.assertIn('if button != .right, let focusContext {', lifecycle)
        self.assertIn('try endFocus(focusContext)', lifecycle)
        settle = click[click.index('let rendererSettle ='):click.index('    static func dispatchWithFocusCleanup(')]
        self.assertIn('0.100 * LockedUseInputTiming.skyClickDelayScale', settle)
        self.assertIn('Thread.sleep(', settle)
        self.assertIn('phase: 2, delayAfter: 0.015)', click)
        menu_press = click[click.index('    static func pressPopupMenuItem('):click.index('    static func pressAXPopupMenuItem(')]
        self.assertIn('guard isPopupTarget && button == .left && clickCount == 1 else { return false }', menu_press)
        self.assertEqual(menu_press.count('try LockedUseActionScope.validate()'), 2)
        self.assertLess(menu_press.index('try LockedUseActionScope.validate()'), menu_press.index('let pressed = try press('))
        self.assertLess(menu_press.index('let pressed = try press('), menu_press.rindex('try LockedUseActionScope.validate()'))
        ax_press = click[click.index('    static func pressAXPopupMenuItem('):click.index('    private static func validate(')]
        for token in ['AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(pid)',
                      'Float(screenPoint.x), Float(screenPoint.y)',
                      'AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)',
                      'role as? String == kAXMenuItemRole as String',
                      'AXUIElementPerformAction(element, kAXPressAction as CFString) == .success']:
            self.assertIn(token, ax_press)
        self.assertLess(ax_press.index('try LockedUseActionScope.validate()'), ax_press.index('AXUIElementPerformAction('))
        dispatch = click[click.index('        try dispatchWithFocusCleanup('):click.index('    static func dispatchWithFocusCleanup(')]
        self.assertLess(dispatch.index('try pressPopupMenuItem('), dispatch.index('if !pressedPopupMenuItem {'))
        self.assertLess(dispatch.index('if !pressedPopupMenuItem {'), dispatch.index('for step in recipe {'))
        self.assertIn('if focusContext != nil || pressedPopupMenuItem {', dispatch)
        tests = read("Tests/LockedUseKitTests/LockedUseIntegrationChangesTests.swift")
        for name in ['testClickButtonParserDefaultsValuesAndRejections',
                     'testClickButtonCocoaEventEncoding',
                     'testClickButtonChromiumStampEncodingWithoutPosting',
                     'testSameAppPopupResolution',
                     'testPopupClickRecipePreservesTrackingAndExistingTiming',
                     'testPopupFocusCleanupResolvesWithoutPostingActivation',
                     'testPopupMenuPressEligibilityAndInjectedOutcomes',
                     'testPopupMenuPressCancellationBeforeAndAfterProbe',
                     'testDispatchErrorsAttemptFocusCleanupForLeftRightAndPopupClicks',
                     'testSuccessfulRightClickRetainsFocusAndNoContextNeedsNoCleanup']:
            self.assertIn(name, tests)
        for name in ['README.md', 'README_CN.md', 'skills/macos-locked-use/SKILL.md',
                     'Sources/LockedUseKit/LockedUseCommand.swift']:
            self.assertIn('--button left|right', read(name))

    def test_public_docs_keep_portable_metadata_and_usage_contracts(self):
        skill = read("skills/macos-locked-use/SKILL.md")
        frontmatter = skill.split("---", 2)[1]
        self.assertEqual([line.split(":", 1)[0] for line in frontmatter.strip().splitlines()],
                         ["name", "description"])
        for name in ["README.md", "README_CN.md", "skills/macos-locked-use/SKILL.md"]:
            text = read(name)
            self.assertNotIn("15.6.1", text)
            self.assertNotIn("title:", text)
        self.assertNotRegex(read("README_CN.md"), r"\bCLI\b|mouse-up|自动")

    def test_exclusive_hid_patch_and_teardown_are_retained(self):
        # Exact PR #143 source after extraction; protects the complete fallback,
        # callback error handling and per-device unschedule/close, not just tokens.
        source = (ROOT / "Sources/Guardian/PhysicalInputMonitor.swift").read_bytes()
        self.assertEqual(hashlib.sha256(source).hexdigest(), "2dd08bff747d2e56e97b850c736911fdde376f85346d520d3a6820f6c8cc1137")

    def test_display_wake_and_secondary_coordinates_are_wired(self):
        source = read("Sources/Guardian/DisplayShieldSurface.swift")
        prepare = source[source.index("    func coverDisplays("):source.index("    private func stageScreens")]
        # Baseline observation deliberately precedes wake; actual shield staging
        # still waits for active displays to wake, before any window publication.
        self.assertLess(prepare.index("guard Self.ensureDisplayAwake()"), prepare.index("try stageScreens(screenIDs())"))
        self.assertIn("IOPMAssertionDeclareUserActivity", source)
        self.assertIn("IOPMAssertionRelease", source)
        self.assertIn("contentRect: local", source)
        self.assertIn("window.setFrame(frame", source)
        self.assertIn("DisplayShieldSurface.ensureDisplayAwake()", read("Sources/Guardian/LockScreenPresentation.swift"))
        self.assertIn("0.025", read("Sources/LockedUseKit/LockedUseDisplayWake.swift"))
        self.assertIn("testSecondaryScreenInitRectIsScreenLocal", read("Tests/LockedUseKitTests/LockedUseShieldCoverageTests.swift"))

    def test_stale_policy_is_refreshed_before_suspend(self):
        source = read("Sources/Broker/BrokerMain.swift")
        self.assertIn("lastPolicyCheck >= 0.8", source)
        function = source[source.index("private func checkInstallationPolicy"):]
        self.assertLess(function.index("policyMonitor.refreshAndWait()"), function.index("suspendForPolicyObservation()"))
        self.assertIn("completed.wait(timeout:", read("Sources/LockedUseKit/LockedUsePolicyMonitor.swift"))

    def test_debug_date_workaround_and_local_identity(self):
        self.assertIn("Date().isBefore(deadline)", read("Sources/LockedUseKit/LockedUseDiagnostics.swift"))
        self.assertIn("timeIntervalSinceReferenceDate <", read("Sources/LockedUseKit/DateComparison.swift"))
        connection = read("Sources/LockedUseKit/LockedUseConnection.swift")
        self.assertIn("socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets)", connection)
        self.assertIn("localIdentitySocket = sockets[0]", connection)
        self.assertIn("Darwin.close(localIdentitySocket)", connection)
        self.assertIn("defer { connection.end() }", connection)
        self.assertIn("connection.end()", read("Sources/LockedUseCLI/LockedUseMain.swift"))

    def test_exec_holder_is_wired_and_security_boundaries_retained(self):
        holder = read("Sources/LockedUseKit/LockedUseSessionHolder.swift")
        cli = read("Sources/LockedUseCLI/LockedUseMain.swift")
        command = read("Sources/LockedUseKit/LockedUseCommand.swift")
        for token in ["--session-holder", "endIfActive", "beginExecIfNeeded", "finishExec", "validateExec", "case .exec"]:
            self.assertIn(token, cli)
        for token in ["case begin(", "case .begin(", "defaultTTL", "maximumTTL"]:
            self.assertNotIn(token, cli + command)
        for token in ["beginSession", "leaseDeadline", "lastActionRefresh", "remainingSeconds"]:
            self.assertNotIn(token, holder)
        for token in ["_CS_DARWIN_USER_TEMP_DIR", "O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC",
                      "ocu_has_mutating_acl(fd) == 0", "peer.auditSessionID == me.auditSessionID",
                      "peer.hardenedRuntime", "!peer.permitsCodeInjection", "LOCK_EX | LOCK_NB",
                      "LockedUseIPCFrame.encode", "client.decoder.append", "setsid()",
                      "signal(SIGHUP, SIG_IGN)", "FileHandle.nullDevice",
                      "LockedUseHost.currentExecutableURL", "client.execs", "activeExecs.remove(id)",
                      "connection?.finishAction()"]:
            self.assertIn(token, holder)
        self.assertNotIn("NSTemporaryDirectory", holder)
        connection = read("Sources/LockedUseKit/LockedUseConnection.swift")
        self.assertNotIn("inFlight", connection)
        for token in ["activeActionCount += 1", "max(0, activeActionCount - 1)",
                      "activeActionCount == 0", "public var hasActiveLease", "public var isFinished"]:
            self.assertIn(token, connection)
        timer = holder[holder.index("timer.setEventHandler"):holder.index("self.timer = timer")]
        self.assertNotIn("validateAction", timer)
        self.assertIn("defer { stop(process) }", cli)
        self.assertIn("systemUptime + 0.15", cli)
        self.assertIn("connection.end()", cli)
        self.assertIn('case ["end"]: return .end', command)
        diagnostics = read("Sources/LockedUseKit/LockedUseDiagnostics.swift")
        self.assertIn("protectedSessionActive", diagnostics)
        self.assertIn("LockedUseSessionHolder.statusIfActive()", diagnostics)
        self.assertNotIn("protectedSessionRemainingSeconds", diagnostics)
        self.assertIn("locked-use exec", read("README.md"))
        self.assertNotIn("locked-use begin", read("README.md"))

    def test_holder_review_fixes_remain_enforced(self):
        holder = read("Sources/LockedUseKit/LockedUseSessionHolder.swift")
        self.assertIn("guard !required || conn.hasActiveLease", holder)
        self.assertIn("beginAction(requireLocked: required)", holder)
        self.assertIn("connection = nil", holder)  # Unscoped connections are not retained.
        ending = holder[holder.index("private func startEnding"):holder.index("private func probeRelease")]
        self.assertLess(ending.index("shuttingDown = true"), ending.index("releaseQueue.async"))
        self.assertIn("queue.async", ending)
        self.assertIn("let completed = released && activeExecs.isEmpty", ending)
        self.assertIn("let drained = self.queue.sync { self.activeExecs.isEmpty }", ending)
        self.assertIn("guard drained else { return false }", ending)
        self.assertIn("if completed { shutdownServer() }", ending)
        self.assertNotIn("unlink(", ending)
        self.assertIn("(try? conn.protectionReleased()) == true", holder)
        self.assertIn("Timed out waiting for Locked Use protection release", holder)
        self.assertIn("guard !shuttingDown", holder)
        self.assertIn("activeLease: !shuttingDown", holder)
        accept = holder[holder.index("private func acceptClients"):holder.index("private func disconnect")]
        self.assertNotIn("while !shuttingDown", accept)

    def test_admission_serialization_and_bounded_shutdown(self):
        connection = read("Sources/LockedUseKit/LockedUseConnection.swift")
        admission = connection[connection.index("public func beginAction"):connection.index("public func finishAction")]
        self.assertIn("private let admissionLock = NSLock()", connection)
        self.assertEqual(connection.count("admissionLock.lock()"), 1)
        self.assertLess(admission.index("admissionLock.lock()"), admission.index("mutex.lock()"))
        self.assertIn("defer { admissionLock.unlock() }", admission)
        # Both reuse and acquisition recheck revocation in their count critical section.
        self.assertEqual(admission.count("guard !stopped && !clientDisconnected"), 2)
        holder = read("Sources/LockedUseKit/LockedUseSessionHolder.swift")
        self.assertIn("deadline: ProcessInfo.processInfo.systemUptime + 0.5", holder)
        timer = holder[holder.index("timer.setEventHandler"):holder.index("self.timer = timer")]
        self.assertLess(timer.index("guard activeExecs.isEmpty"), timer.index("shutdownStartedAt > 10"))
        self.assertLess(timer.index("shutdownStartedAt > 10"), timer.index("guard !endWaitInProgress"))
        self.assertIn("if shutdownStartedAt == nil", holder)

    def test_all_authorization_sources_present(self):
        for name in ["Plugin.c", "PluginTests.c", "RemotePlugin.m", "RemotePluginTests.c", "TaskVerifier.swift", "TaskVerifierDiagnostics.swift", "TaskVerifierTests.c"]:
            self.assertTrue((ROOT / "AuthorizationPlugin" / name).is_file())


if __name__ == "__main__":
    unittest.main()
