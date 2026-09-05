# Bar panel

The Keyarchy bar widget opens a popup that shows shortcut usage, unused binds,
category teaching switches, and the **Learned** lesson list. Left click toggles
the panel; right click toggles teaching off and on.

## Sub-features

- `panel-open` opens the popup from the bar or IPC.
- `panel-summary` shows `N of M shortcuts used` (or `waiting for the shim`).
- `panel-learned` lists lessons with mute controls.
- `panel-toggle-enabled` turns teaching off without removing the widget.

## How to get to it (user POV)

- Left click the Keyarchy mark (Enter/Return key silhouette) on the bar (right section by default).
- Agent path: `omarchy-shell slw.keyarchy toggle`.
- Right click the icon (or press `o` while the panel is focused) to toggle
  enabled; press `n` to walk unused shortcuts.

## Driving it with keyarchy-verify

Preconditions:

- Doctor exits 0.
- Widget is on the bar (`slw.keyarchy` in `shell.json` bar layout).

- **Open the panel.** Run
  `.cursor/skills/verify-keyarchy/scripts/open-panel`.
  Observable: IPC returns `ok`.
- **Capture UI.** The script writes `screenshot-*.png` under the run directory
  via `omarchy capture screenshot fullscreen save`.
- **Record summary numbers.** `summary.txt` includes
  `{used} of {total} shortcuts used` derived from `binds.json` + `usage.json`
  (same inputs the panel uses).
- **Close the panel.** Script toggles IPC again so the desktop is not left with
  the popup open.
- **Proof.** Keep the PNG and `summary.txt`. Visually confirm the hero title
  `Keyarchy` in the screenshot when reviewing.

## Gotchas

- IPC only has `toggle`, not separate open/close — an odd number of toggles
  leaves the panel open.
- If `binds.json` is empty the panel meta reads `waiting for the shim`; that is
  a doctor failure, not a panel bug.
- Right-click enable toggle is not automated here; mutate
  `~/.config/omarchy/shell.json` only when deliberately testing config hot-reload.
- Fullscreen screenshots include the whole desktop; look for the Keyarchy popup
  near the bar icon.
