# macOS Locked Use

English | [简体中文](./README_CN.md)

Computer Use lets AI agents operate desktop applications via window screenshots, Accessibility trees, and keyboard/mouse events. During unattended execution, the core requirement is that the agent can continue operating the host desktop while anyone in front of the physical Mac cannot see the desktop or operate the machine.

On macOS, however, locking the screen stops desktop window capture and restricts keyboard, mouse, and Accessibility input to the lock screen, blocking the agent; existing alternatives also fail to meet this requirement:
- **Disabling system screen lock**: The agent can continue operating, but the physical display exposes the desktop and anyone at the machine can operate the session.
- **Storing the login password locally for simulated unlock**: Persists the user's login password on disk and likewise exposes the unlocked desktop to anyone at the physical display.
- **Running inside an isolated virtual machine**: Protects the host display, but isolates execution from the host desktop so the agent cannot operate the user's logged-in applications and sessions.

`macos-locked-use` provides a standalone lock-screen session layer for Computer Use on macOS so that, without storing the user's login password, **the agent can operate host windows while anyone in front of the screen can neither see the desktop nor operate the Mac**:
- **Targeted window operations**: Temporarily unlocks the graphical session and operates target applications via `ScreenCaptureKit` desktop-independent window capture and window-ID / PID targeted event dispatch.
- **Full-screen shield and local-input relock**: Covers all displays with a full-screen blurred-wallpaper shield (showing the local user avatar, `<Host App> is Using Your Mac`, and `Press any key or click to unlock`); restores the system lock screen when the task ends, or relocks on local mouse movement or key press and requires one normal user unlock before running again (`awaitingManualUnlock`).
- **Single-use authorization permit**: Pairs a `SecurityAgent` authorization plug-in with a `root` daemon to issue a single-use 5-second unlock permit after dual-process shields are active; when the task ends, the screen relocks for the user to unlock with password or Touch ID.

```sh
./scripts/build-locked-use.sh --identity "Apple Development: Your Name (TEAMID)"
./dist/release-native/bin/locked-use enable
./dist/release-native/bin/locked-use capture --app Finder --out /tmp/finder.png
```

Skill for AI agents: [`skills/macos-locked-use/SKILL.md`](./skills/macos-locked-use/SKILL.md)

## Integration Options

This repository provides a command-line tool (`locked-use`) and a Swift library (`LockedUseKit`), backed by the same daemon and authorization plug-in:

| Target Environment | Entry Point | Integration Method |
| --- | --- | --- |
| Node.js / Python / Go / Rust processes, MCP servers, CLI agents | `locked-use` | Build the signed `LockedUse.app` bundle, run desktop actions via built-in `capture / click / type / key` or `exec`, and call `locked-use end` when finished. |
| Native Swift macOS apps (signed `.app` bundle with settings UI) | `LockedUseKit` | Add `LockedUseKit` in `Package.swift`, bundle the 4 helper components under `Contents/Resources/LockedUse/`, and invoke `LockedUseConnection` and `LockedUseGUI` in-process without exposing a CLI. |

Build and runtime requirements: macOS 14+, Xcode 15.4+, and an Apple-issued code-signing certificate with a Team ID (`Apple Development` or `Developer ID Application`). macOS `SecurityAgent` plug-in loading and mutual peer verification reject ad-hoc (`-`) signatures, so source integrations build locally with their own certificate; packaged macOS applications can ship pre-signed, notarized helper components inside their `.app` bundle.

## CLI Integration

### 1. Build and Initialize

```sh
git clone https://github.com/nia-teams/macos-locked-use.git
cd macos-locked-use

# List code-signing identities with a Team ID
security find-identity -v -p codesigning

# Build and sign ./dist/release-native/LockedUse.app and ./dist/release-native/bin/locked-use
./scripts/build-locked-use.sh --identity "Apple Development: Your Name (TEAMID)"

# Install system components while unlocked and grant host permissions
./dist/release-native/bin/locked-use enable
./dist/release-native/bin/locked-use status --json
```

`build-locked-use.sh` defaults to a `release` build for the native architecture with bundle identifier `com.nia-teams.locked-use.app` (override with `--arch universal` or `--bundle-id <id>`). Keep the `LockedUse.app` bundle layout intact and invoke `LockedUse.app/Contents/MacOS/locked-use` or the `dist/release-native/bin/locked-use` symlink.

### 2. Lease Lifecycle and Execution

- **Unlocked state**: `locked-use` runs window actions or foreground child commands in the current desktop session.
- **Locked state**: The first `capture / click / type / key` or `exec` call wakes the display, covers all displays with shields, unlocks the graphical console session, and runs the action. After the command exits, a per-user session holder keeps the task lease open for a **30-second idle window** up to a **300-second maximum** total duration; subsequent commands within that window reuse the same shielded session.
- **Expiration and release**: Call `locked-use end` when finished to release the lease and relock. When the 30-second idle window or 300-second maximum duration expires, Broker revokes the lease, terminates any running `exec` child process, restores the system lock screen, and exits with code `76`.

**Shell Example:**

```sh
locked-use capture --app TextEdit --out /tmp/textedit.png
locked-use click --app TextEdit --x 240 --y 180 --pixel
locked-use type --app TextEdit --text "Hello from Locked Use"
locked-use key --app TextEdit --key Return
locked-use end
```

**Node.js / TypeScript Example:**

```ts
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const LOCKED_USE_BIN = "/path/to/dist/release-native/bin/locked-use";

export async function runLockedUse(args: string[]) {
  return execFileAsync(LOCKED_USE_BIN, args);
}

async function runTask() {
  try {
    const { stdout } = await runLockedUse(["capture", "--app", "TextEdit", "--out", "/tmp/win.png"]);
    const capture = JSON.parse(stdout);
    await runLockedUse(["click", "--window-id", String(capture.windowID), "--x", "240", "--y", "180", "--pixel"]);
    await runLockedUse(["type", "--window-id", String(capture.windowID), "--text", "Hello"]);
  } finally {
    await runLockedUse(["end"]);
  }
}
```

## Shield-Safe Window Operations

While shields are active, Guardian installs a session-level event tap: any global HID event (physical input, `cliclick`, `System Events click at {x, y}`, or `CGEvent.post(tap:)`) is treated as local input interruption and relocks the screen. Screenshots and input under a shielded session use window-targeted or process-targeted paths:

1. **Built-in window subcommands**: `locked-use capture / click / type / key` (backed by `ScreenCaptureKit` desktop-independent window capture and window-ID / PID targeted dispatch, supporting both native Cocoa apps and custom-rendered windows such as Chrome or Electron).
2. **Accessibility actions**: `AXUIElementPerformAction` (such as `AXPress`) or `AXUIElementSetAttributeValue` inside `locked-use exec` (no global HID events generated).

### Subcommands and Arguments

```sh
locked-use status [--json]
locked-use enable | disable | recover | end | lock
locked-use capture (--app <name-or-bundle-id> | --pid <pid> | --window-id <id>) --out <file.png> [--require-locked]
locked-use click <target> --x <coord> --y <coord> [--pixel] [--double] [--window-local | --screen] [--require-locked]
locked-use type <target> --text <text> [--require-locked]
locked-use key <target> --key <cmd+v|Return|...> [--require-locked]
locked-use exec [--require-locked] -- <command> [args...]
```

- **Window selector (`<target>`)**: Accepts `--app`, `--pid`, and `--window-id` individually or combined; omitting `--window-id` selects the frontmost normal `layer == 0` window matching the selector.
- **Coordinates and Retina scaling**: `capture` prints JSON containing `windowID`, `pid`, logical-point `bounds`, backing `pixelWidth` / `pixelHeight`, and `path`, capturing the target window without the shield overlay. `click` accepts screenshot pixel coordinates with `--pixel`, window-local logical points by default (`--window-local`), or global screen points with `--screen`.
- **Management and execution subcommands**:
  - `enable` / `disable` / `recover`: Install or upgrade components, remove components and restore native authorization rules, or repair an interrupted installation. Updating the host app does not replace installed `/Library` components; re-run `enable` if `status` reports a version mismatch.
  - `exec [--require-locked] -- <cmd> [args...]`: Run a foreground subprocess (such as an Accessibility query script) inside the shielded session. With `--require-locked`, exits with `77` if the console is unlocked and no lease is active.

### Exit Codes

| Exit Code | Meaning | Caller Handling |
| --- | --- | --- |
| `0` (or child exit code) | Completed; `exec` preserves the child exit code unless interrupted by protection loss | Proceed with the workflow |
| `75` | Local physical input detected or Broker is in `awaitingManualUnlock`; screen is relocked | Stop the task and return local control without prompting the user to relock |
| `76` | Lease reached the 30s idle timeout or 300s maximum duration, or another caller ran `locked-use end` while this command was in flight | Start a new lease only if work remains |
| `77` | Not installed, missing permissions, or `--require-locked` precondition unmet | Inspect `blockers` in `locked-use status --json` |
| `64` | Invalid CLI arguments | Fix command invocation |

When `locked-use` itself exits with `75` / `76` / `77` / `64`, it writes a single `locked-use: ` diagnostic line to `stderr` to distinguish its status from an `exec` child process exit code.

## Swift Client Integration

Native macOS applications (`YourApp.app`) can embed `LockedUseKit` in-process; the shield displays the host application's name and icon.

### 1. Add SwiftPM Dependency

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/nia-teams/macos-locked-use.git", from: "0.1.0")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "LockedUseKit", package: "macos-locked-use")
        ]
    )
]
```

### 2. Bundle Helper Components

Build the 4 helper components with the same signing identity and Team ID as `YourApp.app` and copy them into `YourApp.app/Contents/Resources/LockedUse/`:

```sh
./scripts/build-locked-use-components.sh \
  --identity "Developer ID Application: Your Team (TEAMID)" \
  --configuration release \
  --arch universal

mkdir -p "YourApp.app/Contents/Resources/LockedUse"
for item in LockedUseInstaller LockedUseService LockedUseGuardian LockedUseAuth.bundle; do
  ditto ".build/locked-use/components-release-universal/$item" \
    "YourApp.app/Contents/Resources/LockedUse/$item"
done
```

Add `NSInputMonitoringUsageDescription` to `YourApp.app/Contents/Info.plist`:

```xml
<key>NSInputMonitoringUsageDescription</key>
<string>Detect physical keyboard or mouse input during Locked Use and restore the lock screen.</string>
```

### 3. API Usage

```swift
import LockedUseKit

// Query installation and permission diagnostics
let diagnostics = LockedUseDiagnostics.collect()

// Enable or disable on MainActor while unlocked
@MainActor
func setLockedUseEnabled(_ enabled: Bool) throws {
    _ = try LockedUseSettings.handle(
        arguments: ["locked-use", enabled ? "enable" : "disable"]
    )
}

// Run serialized window click and typing inside a lease
@MainActor
func clickAndType(connection: LockedUseConnection) throws {
    try connection.perform(requireLocked: false) {
        let target = try LockedUseGUI.findWindow(app: "TextEdit")
        try LockedUseGUI.click(target: target, x: 120, y: 90)
        try LockedUseGUI.typeText("Hello", windowID: target.windowID, pid: target.pid)
        try LockedUseActionScope.validate()
    }
}
```

For async single-window capture (`LockedUseGUI.captureWindow(windowID:outputPath:)`), pair `LockedUseConnection.beginAction` / `finishAction` with `LockedUseActionScope.withAsyncValidator`, keeping GUI operations serialized per connection.

## System Permissions

Grant three permissions to the **host application** under **System Settings → Privacy & Security**:

| Entry | Permissions | Purpose |
| --- | --- | --- |
| Host application (`LockedUse` or `YourApp`) | Accessibility, Screen Recording, Input Monitoring | Operate target windows and lock-screen UI, capture independent windows, and detect physical input takeover |

`LockedUseGuardian` is built as a signed plain Mach-O executable rather than an `.app` bundle and is spawned by the signed host via `Process`. macOS TCC attributes its Accessibility and Input Monitoring checks to the host application, so no second Guardian entry appears in System Settings. Broker and the authorization plug-in require no TCC grants.

Installation and removal prompt for administrator password or Touch ID. `enable` completes installation even before TCC switches are toggled; after enabling all three permissions for the host app (and restarting the host if macOS requests it), run `locked-use status --json` to confirm `"available": true`.

## Installed Components

In the table below, `ROOT` denotes `/Library/Application Support/LockedUse`:

| Component / File | Installation Path | Purpose |
| --- | --- | --- |
| `LockedUseGuardian` | `ROOT/LockedUseGuardian` | Render full-screen shields, wake displays, drive lock-screen unlock, and monitor physical input takeover |
| `LockedUseService` | `ROOT/LockedUseService` | Root Broker daemon managing single-use unlock permits, task leases, and dual-guard release barriers |
| `LockedUseInstaller` | `ROOT/LockedUseInstaller` | Install, remove, and recover system components and authorization rules |
| `LockedUseAuth.bundle` | `/Library/Security/SecurityAgentPlugins/LockedUseAuth.bundle` | `SecurityAgent` plug-in that claims a single-use permit from Broker during lock-screen authentication |
| `com.nia-teams.locked-use.broker.plist` | `/Library/LaunchDaemons/com.nia-teams.locked-use.broker.plist` | Launch and maintain the `LockedUseService` daemon |
| Runtime state and sockets | `ROOT/*.json`, `ROOT/run/` | Enrolled client approvals, saved authorization plan, recovery records, and local UNIX domain sockets |

`enable` inserts a `LockedUseAuth` branch into `system.login.screensaver` while preserving native password and Touch ID authentication; `disable` restores the original rule and removes the installed files.

## Component Workflow

When the Mac is locked, the host application (or `locked-use`) requests a lease from Broker and launches both `LockedUseGuardian` and an independent `Watchdog` process to cover every display. Once both guards report full coverage, Broker issues a single-use 5-second permit and Guardian wakes the display to trigger lock-screen authentication; `SecurityAgent` loads `LockedUseAuth.bundle` to consume that permit and complete unlock. When a lease is ended or reaches its 30-second idle / 300-second maximum limit, the Mac relocks and Broker returns to `idle`. If either guard disconnects or physical input is detected during a lease, the screen relocks and Broker enters `awaitingManualUnlock`; once the user unlocks the Mac normally with password or Touch ID, Broker observes the unlocked console session for the same UID and `auditSessionID` and resets to `idle`.

## Security and Risks

- **Local process boundary**: Broker verifies connecting peers via kernel `LOCAL_PEERTOKEN` (signing identifier, Team ID, Hardened Runtime, and absence of `get-task-allow` or code-injection environment variables). Embedding `LockedUseKit` in-process inside a signed app without shipping the `locked-use` CLI prevents other local processes from borrowing its signature to unlock the screen. Deploying the standalone `locked-use` CLI allows any process running under the same logged-in macOS user to invoke `locked-use` and capture or interact with windows while the screen is locked.
- **Lock-screen recovery over SSH**: Modifying `system.login.screensaver` sits on the macOS screen-unlock path. Enable **Remote Login (SSH)** under **System Settings → General → Sharing** before installation. If the plug-in malfunctions or the lock screen stalls, connect over SSH from another device and restore native authentication rules:
  ```sh
  sudo "/Library/Application Support/LockedUse/LockedUseInstaller" recover
  ```
- **Login Keychain remains locked**: Passwordless session unlock does not supply the user's login password, so the macOS Login Keychain stays locked during a Locked Use session; apps that read secrets from an unlocked Login Keychain cannot access those items until normal user unlock.
- **Verified macOS versions**: Tested on Apple Silicon Mac running macOS 15.6; minimum deployment target is macOS 14.0.

## Verification

```sh
python3 scripts/check-source.py
./scripts/test-locked-use.sh
```

## License

[MIT](./LICENSE). Refactored from the Locked Use module of [open-computer-use](https://github.com/iFurySt/open-computer-use).
