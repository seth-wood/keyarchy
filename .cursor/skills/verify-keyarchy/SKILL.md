---
name: verify-keyarchy
description: >
  Verify Keyarchy — an Omarchy shell plugin + Hyprland shim that teaches
  keyboard shortcuts for mouse-driven actions. Use when proving install health,
  mouse-vs-keyboard teaching, the bar panel, or the node/lua unit suite on a
  live Omarchy desktop.
---

# Verify Keyarchy

Keyarchy is not a standalone server. It runs inside the user's Omarchy
`quickshell` process and wraps `hl.bind` via a Hyprland Lua shim. Live drives
mutate the **shared** session (workspace, notifications, `~/.local/state/keyarchy`).
Never start a second live drive while one is running — helpers take
`$XDG_RUNTIME_DIR/keyarchy-verify.lock` and refuse if it exists.

## Launch

There is no app binary to keep alive. "Launch" means the installed plugin and
shim match this checkout and the shell has loaded the service.

```bash
cd /home/slw/Developer/keyarchy   # or this checkout
./install.sh
omarchy restart shell             # required after first install / service edits
```

Ready when doctor passes (especially `keyarchy service-ready … hyprland=true`
in the newest quickshell log).

Teardown for a verify run is **not** uninstall. Helpers restore snapped
`state.json` / `usage.json` and the prior workspace. Proof artifacts stay under
`.cursor/skills/verify-keyarchy/artifacts/<run-id>/`.

To fully remove Keyarchy from the machine (not part of ordinary verify cleanup):
`./uninstall.sh`.

## Doctor

```bash
.cursor/skills/verify-keyarchy/scripts/doctor
```

Read-only. Confirms: Hyprland session, plugin enabled, shim require present,
`binds.json` populated, installed plugin/shim match the repo, quickshell
running, and `service-ready` logged. Run this first whenever anything looks
off. Concurrent-run locking is enforced by the live drive helpers, not doctor.

## Drive

Harness = shell helpers + `hyprctl` + `omarchy-shell` IPC + screenshots.

| Concern | Command |
|---|---|
| Unit logic (no desktop mutation) | `.cursor/skills/verify-keyarchy/scripts/unit-logic` |
| Teach from mouse-like dispatch | `.cursor/skills/verify-keyarchy/scripts/teach-workspace [N]` |
| Stay quiet after keyboard beacon | `.cursor/skills/verify-keyarchy/scripts/suppress-workspace [N]` |
| Open bar panel + screenshot | `.cursor/skills/verify-keyarchy/scripts/open-panel` |

Stable handles:

- Plugin / IPC target: `slw.keyarchy`
- Panel toggle: `omarchy-shell slw.keyarchy toggle` (returns `ok`)
- Mouse-like workspace change (no beacon):  
  `hyprctl dispatch "hl.dsp.focus({ workspace = 'N' })"`
- Keyboard simulation: write  
  `$XDG_RUNTIME_DIR/keyarchy/last-bind`  
  with `Switch to workspace N\nSUPER + N\n` **before** the matching dispatch
- Lesson side effect: `~/.local/state/keyarchy/state.json` (`counts`, `meta`)
- Usage side effect: `~/.local/state/keyarchy/usage.json`
- Teach log line: `keyarchy teach workspace:N -> SUPER + N` in the newest  
  `/run/user/$UID/quickshell/by-id/*/log.log`
- Screenshot: `OMARCHY_SCREENSHOT_DIR=<dir> omarchy capture screenshot fullscreen save`

Read the feature map before proving a path:
`.cursor/skills/verify-keyarchy/features/README.md`

## Evidence

Proof root: `.cursor/skills/verify-keyarchy/artifacts/<run-id>/`

Standards:

- Exercise the real user path (Hyprland event without beacon = mouse; beacon =
  keyboard). Do not call internal QML setters.
- Capture the action **and** resulting state: `drive.txt`, `state.after.json`,
  teach log excerpt, and for panel/teach UI a fullscreen PNG.
- Live helpers snapshot and restore the user's state files after the run;
  artifacts keep the before/after copies.
- Unit-logic proof is the tee'd test transcript (exit 0).
- Mocks belong only in `test/shim.test.lua` / `test/model.test.mjs`, not in
  live drive scripts.

## Cleanup

- Live helpers release the verify lock on exit and restore snapped state +
  workspace.
- Close the panel with `omarchy-shell -q slw.keyarchy toggle` if you opened it
  outside a helper.
- Never `pkill quickshell` / `pkill omarchy` by name — you did not start them.
- Do not delete `artifacts/`; do not run `./uninstall.sh` as verify cleanup.

Stale lock (crash mid-run): `rm -rf "${XDG_RUNTIME_DIR:-/tmp}/keyarchy-verify.lock"`

## Helpers

All executable under `.cursor/skills/verify-keyarchy/scripts/`:

```bash
.cursor/skills/verify-keyarchy/scripts/doctor
.cursor/skills/verify-keyarchy/scripts/unit-logic
.cursor/skills/verify-keyarchy/scripts/teach-workspace 8
.cursor/skills/verify-keyarchy/scripts/suppress-workspace 9
.cursor/skills/verify-keyarchy/scripts/open-panel
```

Shared paths/lock/snapshot logic: `scripts/common.sh` (sourced, not run).
