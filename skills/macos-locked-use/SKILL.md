---
name: macos-locked-use
description: Capture windows, click, type, press shortcuts, and run Accessibility actions on macOS while the screen is locked using the locked-use CLI (or embed LockedUseKit into a macOS app).
---

# macOS Locked Use

During a Locked Use session, all displays remain covered by privacy shields and local physical input takes precedence over automation. Operate applications through window-addressed channels (`locked-use capture / click / type / key` and `AXUIElement` actions); events on the global input stream are treated as local user input and relock the screen.

Consecutive commands share a per-user lease (30s idle window, 300s max). Call `locked-use end` when the task finishes.

Exit codes:
- `0` (or `exec` child exit code): continue.
- `75` (`awaitingManualUnlock`): local user input detected or a guard disconnected; screen is relocked. End the task and report progress. Once the user unlocks with password or Touch ID, the daemon resets to `idle`.
- `76`: 30s idle window or 300s max lease expired. Run the next command to open a new lease if work remains.
- `77`: not ready or `--require-locked` unmet. Check `blockers` in `locked-use status --json`.

## CLI Workflow

```sh
locked-use status --json
locked-use capture --app TextEdit --out /tmp/win.png
locked-use click --window-id 1234 --x 240 --y 180 --pixel
locked-use type --window-id 1234 --text "Hello"
locked-use key --window-id 1234 --key Return
locked-use exec -- /usr/bin/osascript -e 'tell application "System Events" to get name of every process whose background only is false'
locked-use end
```

`capture` prints JSON containing `windowID` and `pid`; pass `windowID` to subsequent `click / type / key` calls. `click` accepts screenshot pixel coordinates with `--pixel`, window-local logical points by default (`--window-local`), or global screen points with `--screen`.

## Host Integration

For CLI / Node.js integration or in-process Swift integration (`LockedUseKit` + bundling the 4 signed helper components under `Contents/Resources/LockedUse/`), see `README.md` and `Sources/LockedUseKit/LockedUseGUI.swift`.
