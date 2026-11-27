---
name: macos-locked-use
description: Capture windows, click, type, press shortcuts, and run Accessibility actions on macOS while the screen is locked using the locked-use CLI (or embed LockedUseKit into a macOS app).
---

# macOS Locked Use

During a Locked Use lease, opaque privacy shields cover all displays and local physical input takes precedence. Use window-addressed commands (`locked-use capture / click / type / key`) or `AXUIElement` actions when the target is known. Component 0.1.7 also supports user-space synthetic mouse and keyboard input in the original unlocked Broker session.

Consecutive commands share a per-user lease (30s idle window, 300s max). Call `locked-use end` when the task finishes.

Exit codes:
- `0` (or `exec` child exit code): continue.
- `75` (`awaitingManualUnlock`): local user input detected or a guard disconnected; screen is relocked. End the task and report progress. After both guards fully release, configured cooldown expiry (default 60s) resets the daemon to `idle`; password or Touch ID unlock resets it immediately. Do not retry the interrupted task in a tight loop.
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

`click --button left|right` defaults to `left`; use `--button right` to open a context menu. `capture` includes open child menus within the base window’s bounds. A subsequent single left `click` with the original window selector selects a native menu item or clicks a same-app popup window, then releases target focus.

Recovery policy: `locked-use enable --cooldown <seconds|manual>` accepts finite seconds greater than zero and at most 86400; `manual` requires normal unlock. `status --json` provides `awaitingManualUnlock`, `cooldownRemainingSeconds`, `cooldownConfiguredSeconds`, and actionable `blockers`. Missing remaining time may mean guards are still releasing or manual-only policy; use blockers rather than guessing. Exit 75 also applies to calls rejected during cooldown.

In component 0.1.7, session event taps filter mouse and keyboard input behind the opaque shields. Physical activity latched by `IOHIDManager` on a dedicated high-priority run loop, or a tap event with `sourcePID == 0`, immediately triggers relock and exit 75. While the original Broker session is unlocked and hardware monitoring remains healthy with no physical activity, user-space synthetic events (`sourcePID > 1`, excluding the guards) pass through, including fire-and-forget and background senders. Rehearsal treats all input as takeover.

Since component 0.1.5, `shieldsReleasing: true` in `status --json` means the guards have not yet released, even if the Broker is already `idle`. Wait for release; this is not an installation repair or permission blocker.

## Host Integration

For CLI / Node.js integration or in-process Swift integration (`LockedUseKit` + bundling the 4 signed helper components under `Contents/Resources/LockedUse/`), see `README.md` and `Sources/LockedUseKit/LockedUseGUI.swift`.

Staging preserves signed versioned-framework links within `Client.app`. `LockedUseStagedTree.validate` rejects links in helpers or the app root, escaping/absolute/dangling/cyclic links, unsafe ownership/modes/ACLs, and untrusted ancestors; it does not replace code-signature verification. Permission normalization never dereferences staged symlinks.

## Shield bounds protection (component 0.1.4)

Both Guardian and Watchdog pin independent shields to their assigned screens and
flush AppKit/CoreAnimation changes after re-anchoring. Preparation requires actual
full coverage before unlock. After verified preparation and observed unlock, a
bounds-only Space slide may recover across ordinary RunLoop ticks for at most
1.2 seconds from its first mismatch; neither polling nor chained action validation
blocks the main thread. This bounded continuity state is not a claim of actual
geometric coverage during the animation. Every shield must remain onscreen with
our PID, valid bounds, alpha >= 0.99 and its required level throughout the window.
Missing/invalid shields, topology changes and expired recovery fail closed.

Topology observation arms before preparation creates any windows. A failed prepare
closes its candidates and disarms the surface. After preparation, topology faults
latch until teardown: verified windows are never replaced or closed mid-lease;
only missing display IDs may receive supplemental shields. Both each shield's own
display and every active/mirrored display require verified WindowServer coverage.
Existing root-installed 0.1.3 helpers require administrator-authorized component
update; updating only the host app does not replace them. This local component
0.1.4 snapshot does not imply an upstream 0.1.4 tag is published.
