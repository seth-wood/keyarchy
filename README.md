# Omarkey

An Omarchy shell plugin that teaches you the keyboard shortcut for something you
just did with the mouse.

Click a workspace pill in the bar and you get:

```
󰌌  Switch to workspace 3
   SUPER + 3
```

Press `SUPER + 3` and you get nothing, because you already knew.

Built for Omarchy 4.0.0.alpha / Hyprland 0.56.

## Install

```bash
git clone <this repo> ~/Developer/omarkey
cd ~/Developer/omarkey
./install.sh
```

That copies the plugin to `~/.config/omarchy/plugins/slw.omarkey/`, the Lua shim
to `~/.config/hypr/omarkey-shim.lua`, adds one `require` line to
`~/.config/hypr/hyprland.lua` (backing the file up first), and reloads Hyprland.

`./uninstall.sh` reverses all of it.

The plugin registry rejects symlinks, so the install is a copy — re-run
`./install.sh` after editing.

## How it knows you used the mouse

This is the whole trick, and it is worth understanding before you trust it.

Hyprland's event socket reports *what happened* but never *what caused it*. A
workspace change looks identical whether you pressed `SUPER + 3` or clicked the
bar. Hyprland 0.56 logs nothing on keybind dispatch, and reading `/dev/input`
directly would mean joining the `input` group — which lets every process you run
read every key you type. Not worth it for a hint popup.

So Omarkey gets the signal from the other end. Omarchy defines all its bindings
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
Omarchy defines by keycode — which includes *every workspace shortcut*, the
ones most worth teaching. The shim sees the real `"SUPER + code:12"` string at
config time and writes `$XDG_RUNTIME_DIR/omarkey/binds.json`, so Omarkey can
render `SUPER + 3`.

Bindings are matched by their **description**, never by dispatcher. Rebind
`Close window` to something else and the notification follows it.

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

Focus is off because it fires on nearly every interaction, including as a side
effect of opening and closing windows. Turn it on if you want it.

Not covered yet: opening the Omarchy menu, launcher, emoji picker, and clipboard
by clicking the bar. Those are layer-shell surfaces rather than Hyprland window
events and need separate detection.

## Configuration

Omarkey reads its own entry in `~/.config/omarchy/shell.json`, the same way bar
widgets do. Hot-reloads on save.

```jsonc
{
  "plugins": [
    {
      "id": "slw.omarkey",
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
`~/.local/state/omarkey/state.json`. Delete it to start the lessons over.

## Layout

```
plugin/
  manifest.json        kind: service, id slw.omarkey
  Service.qml          wiring: Hyprland events, file watches, notifications
  OmarkeyModel.js      all the logic, no QML imports, unit tested
hypr/
  omarkey-shim.lua     the hl.bind wrapper
test/
  model.test.mjs       node --test test/model.test.mjs
  shim.test.lua        lua test/shim.test.lua -- mocks hl, no compositor needed
```

## Caveats

- **The shim wraps every keybind on your machine.** `test/shim.test.lua` mocks
  Hyprland's `hl` table and checks the things that would break your desktop —
  return values preserved, dispatchers still fired, arguments passed through,
  mouse binds left alone, no double-wrapping on reload. Run it before installing
  any change to the shim.
- `hl.bind` and `hl.dsp` are Omarchy 4 **alpha** internals. If an update changes
  them, the shim stops beaconing and Omarkey goes quiet. It should not break
  Hyprland — the shim no-ops when `hl.bind` is missing — but check after an
  update.
- Mouse bindings (`SUPER` + drag) are deliberately not wrapped; a Lua callback
  would swallow the press/release semantics that drag-to-move depends on.
- Web app bindings (ChatGPT, Email, and friends) are not detected yet. They open
  as generic Chromium classes that need URL matching to tell apart.
