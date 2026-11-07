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

    def test_exclusive_hid_patch_and_teardown_are_retained(self):
        # Exact PR #143 source after extraction; protects the complete fallback,
        # callback error handling and per-device unschedule/close, not just tokens.
        source = (ROOT / "Sources/Guardian/PhysicalInputMonitor.swift").read_bytes()
        self.assertEqual(hashlib.sha256(source).hexdigest(), "2dd08bff747d2e56e97b850c736911fdde376f85346d520d3a6820f6c8cc1137")

    def test_display_wake_and_secondary_coordinates_are_wired(self):
        source = read("Sources/Guardian/DisplayShieldSurface.swift")
        self.assertLess(source.index("guard Self.ensureDisplayAwake()"), source.index("let screens = screenIDs()"))
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
