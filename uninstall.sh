#!/bin/bash
# Remove Keyarchy and put hyprland.lua back the way it was.

set -euo pipefail

PLUGIN_ID="slw.keyarchy"
PLUGIN_DEST="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
SHIM_DEST="$HOME/.config/hypr/keyarchy-shim.lua"
HYPRLAND_LUA="$HOME/.config/hypr/hyprland.lua"

# Drop the require and the comment above it. A leftover require pointing at a
# deleted file would break the whole Hyprland config, so this runs first.
if [[ -f $HYPRLAND_LUA ]] && grep -qE 'hypr\.(keyarchy|omarkey)-shim' "$HYPRLAND_LUA"; then
  cp "$HYPRLAND_LUA" "$HYPRLAND_LUA.bak.$(date +%s)"
  sed -i \
    -e '/^-- Keyarchy: wrap hl.bind before any binding is registered\.$/d' \
    -e '/^-- Omarkey: wrap hl.bind before any binding is registered\.$/d' \
    -e '/hypr\.keyarchy-shim/d' \
    -e '/hypr\.omarkey-shim/d' \
    "$HYPRLAND_LUA"
  echo "keyarchy: removed the shim require from hyprland.lua"
fi

rm -f "$SHIM_DEST" "$HOME/.config/hypr/omarkey-shim.lua"
rm -rf "$PLUGIN_DEST" "$HOME/.config/omarchy/plugins/slw.omarkey"
rm -rf "${XDG_RUNTIME_DIR:-/tmp}/keyarchy" "${XDG_RUNTIME_DIR:-/tmp}/omarkey"

omarchy plugin disable "$PLUGIN_ID" >/dev/null 2>&1 || true
omarchy plugin disable slw.omarkey >/dev/null 2>&1 || true

# `plugin disable` leaves the bar layout entry behind on some paths; strip it
# so the bar does not hold a slot for a plugin that no longer exists.
SHELL_JSON="$HOME/.config/omarchy/shell.json"
if [[ -f $SHELL_JSON ]] && grep -qE 'slw\.(keyarchy|omarkey)' "$SHELL_JSON"; then
  tmp="$(mktemp)"
  jq '
    (.bar.layout // {}) |= with_entries(.value |= map(select(.id != "slw.keyarchy" and .id != "slw.omarkey")))
    | .plugins = ((.plugins // []) | map(select(.id != "slw.keyarchy" and .id != "slw.omarkey")))
  ' "$SHELL_JSON" > "$tmp" && mv "$tmp" "$SHELL_JSON"
  echo "keyarchy: removed the bar entry from shell.json"
fi

if command -v hyprctl >/dev/null && [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
  hyprctl reload >/dev/null
  hyprctl configerrors
fi

echo "keyarchy: removed. Notification history is kept at ~/.local/state/keyarchy."
