# Teach from mouse

When the user performs a teachable action without using its keybinding (for
example switching workspace from the bar or via a non-bind dispatch), Keyarchy
shows a low notification with the shortcut and records the lesson.

## Sub-features

- `teach-workspace` records `workspace:N` after a mouse-like workspace change.
- `teach-notify` emits `omarchy-notification-send` with the bind description and keys.
- `teach-persist` writes `counts` / `meta` into `~/.local/state/keyarchy/state.json`.
- `teach-learned` surfaces the lesson under **Learned** in the bar panel.

## How to get to it (user POV)

- Click a workspace pill on the Omarchy bar.
- Move/close/float a window with the mouse (or titlebar), or open a bound app
  from a non-keybind path.
- Equivalent agent path: `hyprctl dispatch "hl.dsp.focus({ workspace = 'N' })"`
  with **no** prior write to `$XDG_RUNTIME_DIR/keyarchy/last-bind`.

## Driving it with keyarchy-verify

Preconditions:

- `.cursor/skills/verify-keyarchy/scripts/doctor` exits 0.
- No other verify lock is held.
- Prefer workspace `8` unless that is the user's current workspace.

- **Clear cooldown for the action.** The helper zeroes `lastAt` for
  `workspace:N` and waits out `globalGapMs` so a prior lesson does not block.
- **Dispatch without a beacon.** Run
  `.cursor/skills/verify-keyarchy/scripts/teach-workspace 8`.
  Observable: Hyprland focuses workspace `8`.
- **Confirm teach log.** `artifacts/<run-id>/teach.log` contains
  `keyarchy teach workspace:8 -> SUPER + 8`.
- **Confirm persistence.** `state.after.json` has `counts["workspace:8"]`
  greater than the snapped before-count, and `meta["workspace:8"].keys`
  contains `SUPER`.
- **Confirm Learned UI.** The helper opens the panel and saves
  `screenshot-*.png` under the run directory; the panel hero reads `Keyarchy`
  and **Learned** lists the workspace lesson (before state restore).
- **Proof.** Keep the run directory; do not delete screenshots after cleanup.
  Summary file records feature id `teach-from-mouse`.

## Gotchas

- Cooldown defaults to five minutes per action and five seconds globally.
  Driving the same `workspace:N` twice quickly will look like a failure.
- `hyprctl dispatch workspace N` is the wrong Omarchy 4 syntax; use
  `hl.dsp.focus({ workspace = 'N' })`.
- If a leftover beacon for the same description is still "fresh", the lesson is
  suppressed — use the suppress feature to test that path, not this one.
- Helpers restore the user's `state.json` after proof; re-check the live file
  only inside the run's `state.after.json`.
