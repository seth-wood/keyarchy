# Keyarchy

Learn the keyboard by using the mouse.

![Omarchy 4](https://img.shields.io/badge/Omarchy-4%20(Quattro)-1a1a1a)
![Hyprland 0.56](https://img.shields.io/badge/Hyprland-0.56-1a1a1a)
![Quickshell plugin](https://img.shields.io/badge/omarchy--shell-service%20%2B%20bar%20widget-1a1a1a)
[![license: MIT](https://img.shields.io/badge/license-MIT-1a1a1a)](LICENSE)

Keyarchy notices when you did something with the mouse that has a keybinding —
clicked a workspace pill, closed a window, dragged something to another
workspace — and tells you the keystroke you could have pressed instead.

![Keyarchy teaching a workspace shortcut](preview.png)

Click workspace 5 in the bar and you get:

![Switch to workspace 5 — SUPER + 5](docs/notification-closeup.png)

Press `SUPER + 5` and you get nothing, because you already knew.

## Requirements

- Omarchy 4 (`omarchy-shell` / Quickshell) on Hyprland 0.56 — developed against 4.0.2 / 0.56.2
- `~/.config/hypr/hyprland.lua` — the install adds one `require` line to it

## Install

```bash
omarchy plugin add https://github.com/seth-wood/keyarchy.git --enable
~/.config/omarchy/plugins/slw.keyarchy/install-shim.sh
```

The second line is not optional. `plugin add` installs the shell plugin, but
Keyarchy cannot tell a keystroke from a mouse click without a Hyprland Lua shim
(see [How it works](#how-it-works)), and that half lives outside the plugin
folder. `install-shim.sh` copies it to `~/.config/hypr/keyarchy-shim.lua`, adds
one `require` line to `hyprland.lua` — backing the file up first — and reloads
Hyprland, aborting if Hyprland reports a config error. It is safe to re-run.

Until the shim is in place Keyarchy stays silent rather than guessing, so an
install that stops after the first line is quiet, not broken.

If you skipped the bar placement prompt: `omarchy plugin enable slw.keyarchy right`.

## Uninstall

```bash
~/.config/omarchy/plugins/slw.keyarchy/uninstall.sh
```

Removes the plugin, the shim, the `require` line, and the bar entry. Your
lesson history is left at `~/.local/state/keyarchy/`.

## What it teaches

| You did | It suggests |
|---|---|
| Switched workspace | `Switch to workspace N` |
| Moved a window to a workspace | `Move window to workspace N` |
| Closed a window | `Close window` |
| Went fullscreen | `Full screen` |
| Floated / tiled a window | `Toggle window floating/tiling` |
| Opened a bound app | that app's binding |
| Changed window focus | `Focus on <direction> window` — **off by default** |

Bindings are matched by their **description**, never by dispatcher. Rebind
`Close window` to something else and the notification follows it.

Focus is off because it fires on nearly every interaction, including as a side
effect of opening and closing windows. Turn it on in the panel if you want it.

Not covered yet: opening the Omarchy menu, launcher, emoji picker, and clipboard
by clicking the bar. Those are layer-shell surfaces rather than Hyprland window
events and need separate detection.

## The bar widget

<img src="docs/panel.png" alt="The Keyarchy panel" width="380" align="right">

Notifications can only teach you a shortcut for something you already did. The
panel covers the other half — the shortcuts you have never once thought to use.

- **How much of your keymap you actually reach for.** "27 of 212 shortcuts
  used". The shim's beacon names the binding that fired, so the service counts
  activations by description; nothing extra is needed to know what you press.
- **Shortcuts you have never used**, three at a time, with a button (or `n`) to
  walk through the rest.
- **Teaching switches** for the four categories, including the focus category
  that is otherwise off in a config file you would have to know about.
- **What it has taught you**, newest first, with a check mark once a lesson has
  hit its lifetime cap and a bell to mute one without disabling the rest. A
  reset button at the bottom forgets everything and starts over.

**Left click** opens the panel. **Right click** toggles Keyarchy off and on.

The mark sits with the other status icons:

<img src="docs/bar.png" alt="The Keyarchy mark on the Omarchy bar" width="440">

<br clear="all">

## Settings

Keyarchy reads its own entry in `~/.config/omarchy/shell.json`, the same way bar
widgets do. Hot-reloads on save, and the panel switches write to the same place.

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

How many times you have been taught each action is kept in
`~/.local/state/keyarchy/state.json`. Delete it, then `omarchy restart shell`,
to start the lessons over.

## How it works

This is the whole trick, and it is worth understanding before you trust it.

Hyprland's event socket reports *what happened* but never *what caused it*. A
workspace change looks identical whether you pressed `SUPER + 5` or clicked the
bar. Hyprland 0.56 logs nothing on keybind dispatch, and reading `/dev/input`
directly would mean joining the `input` group — which lets every process you run
read every key you type. Not worth it for a hint popup.

So Keyarchy gets the signal from the other end. Omarchy defines all its bindings
in Lua through `hl.bind`, so the shim wraps that function:

```
keypress ─► hl.bind wrapper ─► touch beacon file ─► original dispatcher
                                    │
                                    ▼ (inotify)
mouse click ─► Hyprland socket2 ─► Service.qml ─► beacon in the last 400ms?
                                                   │ no
                                                   ▼
                                            look up the bind, notify
```

The beacon is a positive "the keyboard did this" signal. Any teachable event
without one alongside it came from somewhere else. The service waits 250 ms
before judging, because the beacon write and the socket event race each other.

If the shim is not installed, no beacon ever appears — so the plugin goes silent
rather than firing on every keystroke. That is the intended failure mode.

### Why the shim also exports the bindings

`hyprctl binds -j` reports `key: ""` and `keycode: 0` for the 59 bindings
Omarchy defines by keycode — which includes *every workspace shortcut*, the ones
most worth teaching. The shim sees the real `"SUPER + code:12"` string at config
time and writes `$XDG_RUNTIME_DIR/keyarchy/binds.json`, so Keyarchy can render
`SUPER + 5`.

## Development

```bash
git clone https://github.com/seth-wood/keyarchy.git
cd keyarchy
./install.sh           # copies the tracked files into the plugin folder, then the shim
omarchy restart shell  # a service plugin is only mounted at shell startup
```

The repo root *is* the plugin folder — `omarchy plugin add` clones the whole
repo into `~/.config/omarchy/plugins/slw.keyarchy/`, so the manifest and the QML
sit at the top and everything else rides along. `./install.sh` reproduces that
copy from a checkout; the plugin registry rejects symlinks, so re-run it after
editing.

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

Gotchas worth knowing before you spend an afternoon on one:

- **Quickshell connects the Hyprland event socket lazily.** A bare
  `Connections { target: Hyprland }` in a headless service never fires, because
  declaring the connection does not count as using the singleton. `Service.qml`
  touches `Hyprland.workspaces` at startup to force the connection. Remove that
  line and Keyarchy goes silent with no error.
- **Editing the repo does not update the installed plugin.** Re-run
  `./install.sh`, then `omarchy restart shell` — a service plugin is mounted at
  shell startup, so `omarchy plugin enable` mid-session is not enough on a first
  install.
- **Deleting `state.json` needs a shell restart.** The running service holds the
  lesson history in memory and only reads the file at startup.
- **Do not name a plugin file after the type it extends.** A local `Panel.qml`
  shadows `qs.Ui.Panel`, and the shell reports it as the memorable "File name
  case mismatch". The entry point is `KeyarchyPanel.qml` for that reason.
- **A bar widget needs `implicitWidth`/`implicitHeight`.** Without them it
  occupies a zero-width slot and renders nothing, with no error anywhere.
- `omarchy plugin enable <id> <section>` will not move a plugin that is already
  enabled. Disable it first, then enable it with the placement.
- Omarchy 4 dispatches in Lua, so testing by hand means
  `hyprctl dispatch "hl.dsp.focus({ workspace = '5' })"`, not
  `hyprctl dispatch workspace 5`. The old syntax fails silently.

## Caveats

- **The shim wraps every keybind on your machine.** `test/shim.test.lua` mocks
  Hyprland's `hl` table and checks the things that would break your desktop —
  return values preserved, dispatchers still fired, arguments passed through,
  mouse binds left alone, no double-wrapping on reload. Run it before installing
  any change to the shim.
- `hl.bind` and `hl.dsp` are **undocumented** Omarchy 4 internals. If an update changes
  them, the shim stops beaconing and Keyarchy goes quiet. It should not break
  Hyprland — the shim no-ops when `hl.bind` is missing — but check after an
  update.
- Mouse bindings (`SUPER` + drag) are deliberately not wrapped; a Lua callback
  would swallow the press/release semantics that drag-to-move depends on.
- Web app bindings (ChatGPT, Email, and friends) are not detected yet. They open
  as generic Chromium classes that need URL matching to tell apart.

## License

MIT — see [LICENSE](LICENSE).
