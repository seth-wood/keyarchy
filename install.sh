#!/bin/bash
# Install Omarkey: the shell plugin, the Hyprland shim, and the one line in
# hyprland.lua that loads the shim. Safe to re-run.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ID="slw.omarkey"
PLUGIN_DEST="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
SHIM_DEST="$HOME/.config/hypr/omarkey-shim.lua"
HYPRLAND_LUA="$HOME/.config/hypr/hyprland.lua"
SHIM_LINE='require("hypr.omarkey-shim") -- omarkey'
ANCHOR='require("default.hypr.omarchy")'

fail() { echo "omarkey: $*" >&2; exit 1; }

command -v omarchy >/dev/null || fail "omarchy not found on PATH"
[[ -f $HYPRLAND_LUA ]] || fail "missing $HYPRLAND_LUA"

omarchy plugin validate "$SRC/plugin" >/dev/null || fail "plugin manifest failed validation"
luac -p "$SRC/hypr/omarkey-shim.lua" || fail "shim has a Lua syntax error"

# The plugin registry rejects symlinks, so the repo is the source and this is a
# copy. Re-running overwrites it.
rm -rf "$PLUGIN_DEST"
mkdir -p "$PLUGIN_DEST"
cp "$SRC/plugin/manifest.json" "$SRC/plugin/Service.qml" "$SRC/plugin/OmarkeyModel.js" "$PLUGIN_DEST/"

cp "$SRC/hypr/omarkey-shim.lua" "$SHIM_DEST"

if grep -qF 'hypr.omarkey-shim' "$HYPRLAND_LUA"; then
  echo "omarkey: shim already loaded from hyprland.lua"
else
  grep -qF "$ANCHOR" "$HYPRLAND_LUA" \
    || fail "could not find '$ANCHOR' in $HYPRLAND_LUA; add '$SHIM_LINE' above it by hand"

  BACKUP="$HYPRLAND_LUA.bak.$(date +%s)"
  cp "$HYPRLAND_LUA" "$BACKUP"
  echo "omarkey: backed up hyprland.lua to $BACKUP"

  # The shim must wrap hl.bind before Omarchy registers any binding.
  awk -v line="$SHIM_LINE" -v anchor="$ANCHOR" '
    index($0, anchor) && !done { print "-- Omarkey: wrap hl.bind before any binding is registered."; print line; done = 1 }
    { print }
  ' "$HYPRLAND_LUA" > "$HYPRLAND_LUA.omarkey-tmp"
  mv "$HYPRLAND_LUA.omarkey-tmp" "$HYPRLAND_LUA"
fi

# The shell rescans plugin folders on its own, but `plugin enable` fails with
# "unknown plugin" if it runs before that lands on a freshly copied folder.
enabled=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if omarchy plugin enable "$PLUGIN_ID" >/dev/null 2>&1; then enabled=1; break; fi
  sleep 0.5
done
[[ $enabled == 1 ]] || echo "omarkey: could not enable automatically; run 'omarchy plugin enable $PLUGIN_ID'" >&2

if command -v hyprctl >/dev/null && [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
  hyprctl reload >/dev/null
  # Hyprland prints nothing here when the config is clean.
  errors="$(hyprctl configerrors | grep -v '^[[:space:]]*$' || true)"
  if [[ -n $errors ]]; then
    echo "omarkey: Hyprland reported config errors after reload:" >&2
    echo "$errors" >&2
    echo "omarkey: run ./uninstall.sh to back this out" >&2
    exit 1
  fi
  echo "omarkey: hyprland reloaded cleanly ($(hyprctl binds -j | grep -c '"description"') binds registered)"
fi

echo "omarkey: installed. Omarchy $(omarchy version 2>/dev/null || echo unknown)."
echo "omarkey: click a workspace in the bar to see it work."
