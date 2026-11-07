# AGENTS.md

## Scope and Architecture

`macos-locked-use` is a standalone, zero-dependency Swift package (`LockedUseKit`) and signed CLI (`locked-use`) that enables shielded desktop automation in an already logged-in, locked macOS console session.

Client libraries and CLI targets (in-process):
- `LockedUseNative` (`Sources/LockedUseNative`): C/ObjC kernel peer identity (`LOCAL_PEERTOKEN`, audit token, code-signing flags, ACL inspection).
- `LockedUseKit` (`Sources/LockedUseKit`): Client library, window-targeted GUI dispatch (`LockedUseGUI`), IPC framing, state machine, Broker coordinator, policy monitor, session holder, and settings orchestration.
- `LockedUseCLI` (`Sources/LockedUseCLI`): `locked-use` executable entry point (`status`, `enable`, `disable`, `recover`, `capture`, `click`, `type`, `key`, `exec`, `end`, `lock`).

System components across privilege boundaries (installed under `/Library`):
- `LockedUseInstaller` (`Sources/Installer`): Root installer that stages signed components, records `authorization-plan.json`, updates `system.login.screensaver`, and bootstraps the LaunchDaemon.
- `LockedUseService` (`Sources/Broker`): Root `LaunchDaemon` (`com.nia-teams.locked-use.broker`) managing single-use unlock permits, 30s idle / 300s max leases, console manual-unlock polling, and dual-guard release barriers.
- `LockedUseGuardian` (`Sources/Guardian`): Signed plain Mach-O helper launched as dual processes (`Guardian` + `Watchdog`) covering all displays, waking sleeping displays, driving `loginwindow` unlock, and monitoring `IOHIDManager` + `CGEvent` for physical input takeover while attributing TCC checks to the host app.
- `AuthorizationPlugin` (`AuthorizationPlugin/`): `LockedUseAuth.bundle` SecurityAgent plug-in (`LockedUseAuth:remote,privileged`).

## Non-Negotiable Invariants

1. **Zero external dependencies**: Do not add SwiftPM `.package(...)` dependencies to `Package.swift`.
2. **Code-signing and peer verification**: Never weaken `SecRequirement` checks, `LOCAL_PEERTOKEN` audit token verification, Hardened Runtime enforcement, or `ocu_has_mutating_acl` checks. Ad-hoc (`-`) signatures and `get-task-allow` entitlements must always be rejected.
3. **Dual-guard release barrier**: Broker must never release a lease or issue a new permit until both `Guardian` and `Watchdog` confirm lock-screen restoration and all in-flight actions have drained.
4. **Physical input takeover and targeted GUI dispatch**: Any real HID event (`PhysicalInputMonitor`) or unpermitted session `CGEvent` must trigger relock and transition Broker to `awaitingManualUnlock` until a genuine unlocked console session for the same UID and `auditSessionID` is observed. Built-in GUI helpers (`LockedUseGUI`, `LockedUseClick`, `LockedUseKeyboard`) must never post to a global HID/session tap (`.post(tap:)`). Do not include `NX_SYSDEFINED` (`type == 14`) in the WindowServer `CGEvent` mask.
5. **Exact HID monitor source**: `Sources/Guardian/PhysicalInputMonitor.swift` is hash-pinned in `scripts/check-source.py` (`test_exclusive_hid_patch_and_teardown_are_retained`). Do not modify it unless updating the corresponding invariant test.
6. **Silent holder idle expiry**: `LockedUseSessionHolder` must never send periodic `.action` keepalives while idle; only active `beginExec` / `validateExec` calls refresh Broker activity so idle leases expire after 30 seconds.

## Verification

Before committing any change:
1. Run portable source and invariant checks:
   ```sh
   python3 scripts/check-source.py
   bash -n scripts/*.sh
   ```
2. On macOS with Xcode, run the full debug + release build and XCTest suite:
   ```sh
   ./scripts/test-locked-use.sh
   ```
3. When changing CLI flags, public `LockedUseKit` APIs, or component packaging, update `README.md`, `README_CN.md`, and `skills/macos-locked-use/SKILL.md` together.
