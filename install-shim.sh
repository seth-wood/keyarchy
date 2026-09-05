#!/bin/bash
# Install the Hyprland side of Keyarchy: the hl.bind shim and the one line in
# hyprland.lua that loads it. The shell plugin alone cannot see the keyboard —
# without this, Keyarchy stays silent.
#
# Run this after `omarchy plugin add`:
#   ~/.config/omarchy/plugins/slw.keyarchy/install-shim.sh
#
# Safe to re-run. `./uninstall.sh` reverses it.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM_SRC="$SRC/hypr/keyarchy-shim.lua"
SHIM_DEST="$HOME/.config/hypr/keyarchy-shim.lua"
HYPRLAND_LUA="$HOME/.config/hypr/hyprland.lua"
SHIM_LINE='require("hypr.keyarchy-shim") -- keyarchy'
ANCHOR='require("default.hypr.omarchy")'

fail() { echo "keyarchy: $*" >&2; exit 1; }

[[ -f $SHIM_SRC ]] || fail "missing $SHIM_SRC"
[[ -f $HYPRLAND_LUA ]] || fail "missing $HYPRLAND_LUA"
command -v luac >/dev/null && { luac -p "$SHIM_SRC" || fail "shim has a Lua syntax error"; }

cp "$SHIM_SRC" "$SHIM_DEST"

if grep -qF 'hypr.keyarchy-shim' "$HYPRLAND_LUA"; then
  echo "keyarchy: shim already loaded from hyprland.lua"
else
  grep -qF "$ANCHOR" "$HYPRLAND_LUA" \
    || fail "could not find '$ANCHOR' in $HYPRLAND_LUA; add '$SHIM_LINE' above it by hand"

  BACKUP="$HYPRLAND_LUA.bak.$(date +%s)"
  cp "$HYPRLAND_LUA" "$BACKUP"
  echo "keyarchy: backed up hyprland.lua to $BACKUP"

  # The shim must wrap hl.bind before Omarchy registers any binding.
  awk -v line="$SHIM_LINE" -v anchor="$ANCHOR" '
    index($0, anchor) && !done { print "-- Keyarchy: wrap hl.bind before any binding is registered."; print line; done = 1 }
    { print }
  ' "$HYPRLAND_LUA" > "$HYPRLAND_LUA.keyarchy-tmp"
  mv "$HYPRLAND_LUA.keyarchy-tmp" "$HYPRLAND_LUA"
fi

if command -v hyprctl >/dev/null && [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
  hyprctl reload >/dev/null
  # Hyprland prints nothing here when the config is clean.
  errors="$(hyprctl configerrors | grep -v '^[[:space:]]*$' || true)"
  if [[ -n $errors ]]; then
    echo "keyarchy: Hyprland reported config errors after reload:" >&2
    echo "$errors" >&2
    echo "keyarchy: run ./uninstall.sh to back this out" >&2
    exit 1
  fi
  echo "keyarchy: hyprland reloaded cleanly ($(hyprctl binds -j | grep -c '"description"') binds registered)"
fi

echo "keyarchy: shim installed. Click a workspace in the bar to see it work."
