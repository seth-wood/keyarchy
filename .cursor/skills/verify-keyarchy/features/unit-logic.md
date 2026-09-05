# Unit logic

Pure model logic and the Hyprland shim can be verified without mutating the
live desktop. This catches classification, rate limits, beacon suppression
helpers, and shim wrapping before an install.

## Sub-features

- `model-tests` run `node --test test/model.test.mjs`.
- `shim-tests` run `lua test/shim.test.lua` against a mocked `hl` table.
- `manifest-validate` runs `omarchy plugin validate plugin`.

## How to get to it (user POV)

- Developers run the tests from the repo root while hacking.
- Agents run the unit-logic helper before or instead of a live drive when the
  change is logic-only.

## Driving it with keyarchy-verify

Preconditions:

- `node`, `lua`, and `omarchy` on `PATH`.
- No Hyprland session required.

- **Run the suite.**  
  `.cursor/skills/verify-keyarchy/scripts/unit-logic`
- **Observe.** Exit code `0`; transcript in `artifacts/<run-id>/summary.txt`
  shows model tests passed, `all shim checks passed`, and plugin validation
  with no error.
- **Proof.** Keep `summary.txt`. This does **not** prove live teaching; use
  teach-from-mouse for that.

## Gotchas

- Shim tests mock `XDG_RUNTIME_DIR`; they never touch the session's real
  `$XDG_RUNTIME_DIR/keyarchy`.
- Passing unit-logic after a QML-only change is insufficient — still doctor +
  one live feature when Service/Panel/shim install paths change.
- `omarchy plugin validate` needs Omarchy installed; it does not load the
  service.
