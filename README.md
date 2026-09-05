# Keyarchy

Learn Omarchy's keyboard shortcuts as you use your desktop.

![Omarchy 4](https://img.shields.io/badge/Omarchy-4%20(Quattro)-1a1a1a)
![Hyprland 0.56](https://img.shields.io/badge/Hyprland-0.56-1a1a1a)
![Quickshell plugin](https://img.shields.io/badge/omarchy--shell-service%20%2B%20bar%20widget-1a1a1a)
[![license: MIT](https://img.shields.io/badge/license-MIT-1a1a1a)](LICENSE)

Keyarchy shows you the keyboard shortcut for an action you just took with the
mouse. Click a workspace, close a window, or open an app, and you'll get a small
reminder of the binding you could use next time.

![Keyarchy teaching a workspace shortcut](preview.png)

For example, clicking workspace 5 in the bar shows:

![Switch to workspace 5 — SUPER + 5](docs/notification-closeup.png)

Use `SUPER + 5` instead and there's no reminder. By default, Keyarchy shows each
lesson at most five times, with a five-minute gap between reminders for the same
action. You can mute individual lessons or adjust these limits.

## Requirements

- Omarchy 4 (`omarchy-shell` / Quickshell) on Hyprland 0.56 — developed against 4.0.2 / 0.56.2
- `~/.config/hypr/hyprland.lua` — the install adds one `require` line to it

## Install

```bash
omarchy plugin add https://github.com/seth-wood/keyarchy.git --enable
~/.config/omarchy/plugins/slw.keyarchy/install-shim.sh
```

Both commands are required. The first installs the shell plugin. The second
installs a small Hyprland Lua shim that lets Keyarchy recognize keyboard actions
(see [How it works](#how-it-works)).

`install-shim.sh` copies the shim to `~/.config/hypr/keyarchy-shim.lua`, backs up
`hyprland.lua`, adds a `require` line, and reloads Hyprland. It aborts if Hyprland
reports a config error, and is safe to run again. Keyarchy won't show reminders
until the shim is installed.

If you skipped the bar placement prompt: `omarchy plugin enable slw.keyarchy right`.

## Uninstall

```bash
~/.config/omarchy/plugins/slw.keyarchy/uninstall.sh
```

Removes the plugin, the shim, the `require` line, and the bar entry. Your
lesson history is left at `~/.local/state/keyarchy/`.

## What it teaches

Keyarchy currently recognizes these actions:

| You did | It suggests |
|---|---|
| Switched workspace | `Switch to workspace N` |
| Moved a window to a workspace | `Move window to workspace N` |
| Closed a window | `Close window` |
| Went fullscreen | `Full screen` |
| Floated / tiled a window | `Toggle window floating/tiling` |
| Opened a bound app | that app's binding |
| Changed window focus | `Focus on <direction> window` — **off by default** |

Keyarchy matches bindings by their description. If you change the keys for
`Close window` and keep its description, the reminder will show your new binding.

Focus reminders are off by default because focus changes frequently, including
when you open or close a window. You can turn them on in the panel.

Keyarchy doesn't yet detect clicks that open the Omarchy menu, launcher, emoji
picker, or clipboard from the bar. These use layer-shell surfaces and need
separate detection from regular window events.

## The bar widget

<img src="docs/panel.png" alt="The Keyarchy panel" width="380" align="right">

The panel shows which shortcuts you've used and helps you find others to try.
It includes:

- A count of the shortcuts you've used, such as "27 of 212 shortcuts used".
- Three unused shortcuts at a time. Click the next button or press `n` to see more.
- Switches for the four reminder categories: window, workspace, launch, and focus.
- Your lesson history, newest first. A check mark means a lesson has reached its
  reminder limit; the bell lets you mute it. The reset button clears your history
  and starts the lessons over.

**Left click** opens the panel. **Right click** toggles Keyarchy off and on.

Here's how the widget looks in the bar:

<img src="docs/bar.png" alt="The Keyarchy mark on the Omarchy bar" width="440">

<br clear="all">

## Settings

Settings live in Keyarchy's entry in `~/.config/omarchy/shell.json`. Changes take
effect when you save the file. The panel switches update the same settings.

```jsonc
{
  "plugins": [
    {
      "id": "slw.keyarchy",
      "enabled": true,
      "cooldownMs": 300000,   // don't repeat one lesson inside 5 minutes
      "globalGapMs": 5000,    // never two notifications inside 5 seconds
      "lifetimeCap": 5,       // stop teaching an action after 5 times
      "muted": ["close-window"],
      "categories": {
        "window": true,
        "workspace": true,
        "launch": true,
        "focus": false
      }
    }
  ]
}
```

Lesson history is stored in `~/.local/state/keyarchy/state.json`. To reset it
manually, delete that file and run `omarchy restart shell`.

## How it works

Hyprland's event socket reports what happened, but not what caused it. A
workspace change looks identical whether you pressed `SUPER + 5` or clicked the
bar. Keyarchy needs an additional signal to tell those actions apart.

Omarchy defines its bindings in Lua through `hl.bind`. The shim wraps that
function so each keyboard binding updates a small beacon file before running
its original dispatcher. This lets Keyarchy recognize shortcut use without
reading raw input from `/dev/input`.

```
keypress ─► hl.bind wrapper ─► touch beacon file ─► original dispatcher
                                    │
                                    ▼ (inotify)
mouse click ─► Hyprland socket2 ─► Service.qml ─► beacon in the last 400ms?
                                                   │ no
                                                   ▼
                                            look up the bind, notify
```

When a supported event arrives, the service checks for a recent beacon. If it
finds one, it skips the reminder. Otherwise, it looks up the matching binding
and may show a lesson. It waits 250 ms before checking to allow time for both
the beacon write and the socket event to arrive.

Reminders stay disabled when the shim isn't installed.

### Why the shim also exports the bindings

`hyprctl binds -j` reports `key: ""` and `keycode: 0` for bindings
Omarchy defines by keycode, including workspace shortcuts. The shim sees the
original `"SUPER + code:12"` string at config
time and writes `$XDG_RUNTIME_DIR/keyarchy/binds.json`, so Keyarchy can render
`SUPER + 5`.

## Development

```bash
git clone https://github.com/seth-wood/keyarchy.git
cd keyarchy
./install.sh           # copies the tracked files into the plugin folder, then the shim
omarchy restart shell  # a service plugin is only mounted at shell startup
```

The repository root doubles as the plugin folder. `omarchy plugin add` clones
it into `~/.config/omarchy/plugins/slw.keyarchy/`, with the manifest and QML files
at the top level. For local development, `./install.sh` copies your checkout
there. The plugin registry doesn't accept symlinks, so run the installer again
after editing, then restart the shell.

```
manifest.json          kinds: service + bar-widget, id slw.keyarchy
Service.qml            wiring: Hyprland events, file watches, notifications
KeyarchyPanel.qml      the bar widget and its popup
KeyarchyMark.qml       the mark drawn on the bar
ShortcutRow.qml        one "action -> keystroke" line
KeyarchyModel.js       all the logic, no QML imports, unit tested
assets/mark.svg
hypr/
  keyarchy-shim.lua    the hl.bind wrapper
test/
  model.test.mjs       node --test test/model.test.mjs
  shim.test.lua        lua test/shim.test.lua — mocks hl, no compositor needed
```

A few things to keep in mind when developing:

- **Quickshell connects the Hyprland event socket lazily.** A bare
  `Connections { target: Hyprland }` in a headless service never fires, because
  declaring the connection does not count as using the singleton. `Service.qml`
  touches `Hyprland.workspaces` at startup to force the connection. Remove that
  line and Keyarchy stops receiving events without reporting an error.
- **Editing the repo does not update the installed plugin.** Re-run
  `./install.sh`, then `omarchy restart shell` — a service plugin is mounted at
  shell startup, so `omarchy plugin enable` mid-session is not enough on a first
  install.
- **Deleting `state.json` needs a shell restart.** The running service holds the
  lesson history in memory and only reads the file at startup.
- **Do not name a plugin file after the type it extends.** A local `Panel.qml`
  shadows `qs.Ui.Panel`, and the shell reports a "File name
  case mismatch". The entry point is `KeyarchyPanel.qml` for that reason.
- **A bar widget needs `implicitWidth`/`implicitHeight`.** Without them it
  occupies a zero-width slot and renders nothing, with no error anywhere.
- `omarchy plugin enable <id> <section>` will not move a plugin that is already
  enabled. Disable it first, then enable it with the placement.
- Omarchy 4 dispatches in Lua, so testing by hand means
  `hyprctl dispatch "hl.dsp.focus({ workspace = '5' })"`, not
  `hyprctl dispatch workspace 5`. The old syntax fails silently.

## Caveats

- **The shim wraps keyboard bindings registered through `hl.bind`.**
  `test/shim.test.lua` mocks Hyprland's `hl` table to check that return values,
  dispatchers, and arguments are preserved, mouse bindings are left alone, and
  reloading doesn't wrap bindings twice. Run it before installing any change
  to the shim.
- `hl.bind` and `hl.dsp` are **undocumented** Omarchy 4 internals. If an update changes
  them, the shim may stop updating the beacon and Keyarchy may stop showing
  reminders. It should not break
  Hyprland — the shim no-ops when `hl.bind` is missing — but check after an
  update.
- Mouse bindings (`SUPER` + drag) are deliberately not wrapped; a Lua callback
  would swallow the press/release semantics that drag-to-move depends on.
- Web app bindings, such as ChatGPT and Email, are not detected yet. They open
  as generic Chromium classes that need URL matching to tell apart.

## License

MIT — see [LICENSE](LICENSE).
