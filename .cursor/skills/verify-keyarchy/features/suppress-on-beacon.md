# Suppress on beacon

When the user already pressed the keybinding, the shim writes a beacon and
Keyarchy stays quiet for the matching Hyprland event while still counting the
press toward shortcut usage.

## Sub-features

- `suppress-timing` ignores events that race a recent beacon (lead window).
- `suppress-description` ignores delayed events whose description matches the
  beacon (within the match window).
- `usage-count` increments `usage.json` for the beaconed bind description.

## How to get to it (user POV)

- Press the real shortcut (for example `SUPER + 9` to switch workspace).
- Agent equivalent: write the beacon file, then dispatch the same workspace.

## Driving it with keyarchy-verify

Preconditions:

- Doctor exits 0.
- Prefer workspace `9`.

- **Simulate the keypress beacon.** Run
  `.cursor/skills/verify-keyarchy/scripts/suppress-workspace 9`.
  The script writes
  `$XDG_RUNTIME_DIR/keyarchy/last-bind` as
  `Switch to workspace 9\nSUPER + 9\n`, then dispatches focus to workspace `9`.
- **Confirm silence.** `teach.log` is empty (no `keyarchy teach workspace:9`).
- **Confirm lesson count unchanged.** `after_count` equals `before_count` for
  `workspace:9` in `summary.txt`.
- **Confirm usage.** `usage.json` (restored after, but summary records the hit)
  shows a positive count for `Switch to workspace 9`.
- **Proof.** Retain `artifacts/<run-id>/summary.txt` and `state.after.json`.

## Gotchas

- Writing the beacon **after** the dispatch loses the race; order matters.
- Description must match the bind export exactly (`Switch to workspace N`).
- Usage persist may lag up to five seconds inside the service; the helper
  asserts the in-memory file after the beacon path has counted.
- Restoring `usage.json` from the snapshot undoes the usage bump on disk after
  proof — trust `summary.txt` for the observed hit.
