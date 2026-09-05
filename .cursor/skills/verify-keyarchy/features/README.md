# Keyarchy verification map

This directory is the maintained source for verifying Keyarchy's user-facing
behavior on a live Omarchy / Hyprland desktop. Read this index before driving,
then use the matching feature file as the recipe.

## Baseline preconditions

- Checkout is `/home/slw/Developer/keyarchy` (or another clone with the same layout).
- `./install.sh` has been run so `~/.config/omarchy/plugins/slw.keyarchy` and
  `~/.config/hypr/keyarchy-shim.lua` match the repo.
- Omarchy shell is running; doctor sees `keyarchy service-ready … hyprland=true`.
- Plugin `slw.keyarchy` is enabled on the bar (`omarchy plugin enable slw.keyarchy right`).
- Only one live verify run at a time (helpers use `$XDG_RUNTIME_DIR/keyarchy-verify.lock`).
- Prefer workspaces `8` / `9` for teach/suppress recipes so you are less likely
  to yank the user off their active work.

## Driving conventions

- Start from doctor-healthy unless a feature says otherwise.
- Live recipes go through `.cursor/skills/verify-keyarchy/scripts/*`.
- Treat every command as literal.
- Restore snapped `state.json` / `usage.json` after mutating recipes (helpers do this).
- Unit-logic may run without a display; live features must not.

## Proof and skip reporting

- Capture the action and the resulting state, not only a final screenshot.
- Live teach proof includes the `keyarchy teach …` log line **and** an increased
  `counts` entry (plus panel screenshot when the recipe opens the panel).
- Suppress proof includes **no** teach line and an unchanged lesson count, plus
  a usage bump for the beaconed description.
- Record the feature ID and run directory with every artifact.
- Report an unreachable path with the unmet doctor check — do not claim a unit
  test verified a live entry point.

## Feature entry contract

Each feature file starts with an H1 and one paragraph, then exactly four H2s:

1. `Sub-features`
2. `How to get to it (user POV)`
3. `Driving it with keyarchy-verify`
4. `Gotchas`

## Features

- [Teach from mouse](./teach-from-mouse.md) — mouse-like actions produce a lesson.
- [Suppress on beacon](./suppress-on-beacon.md) — keyboard path stays quiet.
- [Bar panel](./bar-panel.md) — open the widget popup and see coaching UI.
- [Unit logic](./unit-logic.md) — model + shim checks without the desktop.
