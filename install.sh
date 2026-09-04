#!/bin/bash
# Install Keyarchy: the shell plugin, the Hyprland shim, and the one line in
# hyprland.lua that loads the shim. Safe to re-run. Migrates a leftover
# Omarkey install if one is still around.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ID="slw.keyarchy"
PLUGIN_DEST="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
SHIM_DEST="$HOME/.config/hypr/keyarchy-shim.lua"
HYPRLAND_LUA="$HOME/.config/hypr/hyprland.lua"
SHIM_LINE='require("hypr.keyarchy-shim") -- keyarchy'
ANCHOR='require("default.hypr.omarchy")'
OLD_PLUGIN_ID="slw.omarkey"
OLD_PLUGIN_DEST="$HOME/.config/omarchy/plugins/$OLD_PLUGIN_ID"
OLD_SHIM_DEST="$HOME/.config/hypr/omarkey-shim.lua"
SHELL_JSON="$HOME/.config/omarchy/shell.json"
OLD_STATE="$HOME/.local/state/omarkey"
NEW_STATE="$HOME/.local/state/keyarchy"

fail() { echo "keyarchy: $*" >&2; exit 1; }

command -v omarchy >/dev/null || fail "omarchy not found on PATH"
[[ -f $HYPRLAND_LUA ]] || fail "missing $HYPRLAND_LUA"

omarchy plugin validate "$SRC/plugin" >/dev/null || fail "plugin manifest failed validation"
luac -p "$SRC/hypr/keyarchy-shim.lua" || fail "shim has a Lua syntax error"

# Drop the previous name so the bar does not keep two coaches.
if [[ -d $OLD_PLUGIN_DEST ]] || [[ -f $OLD_SHIM_DEST ]] \
  || { [[ -f $HYPRLAND_LUA ]] && grep -qF 'hypr.omarkey-shim' "$HYPRLAND_LUA"; }; then
  echo "keyarchy: migrating from omarkey"
  omarchy plugin disable "$OLD_PLUGIN_ID" >/dev/null 2>&1 || true
  rm -rf "$OLD_PLUGIN_DEST"
  rm -f "$OLD_SHIM_DEST"
  rm -rf "${XDG_RUNTIME_DIR:-/tmp}/omarkey"
  if [[ -d $OLD_STATE && ! -e $NEW_STATE ]]; then
    mv "$OLD_STATE" "$NEW_STATE"
    echo "keyarchy: moved lesson history to ~/.local/state/keyarchy"
  fi
  if [[ -f $SHELL_JSON ]] && grep -qF "$OLD_PLUGIN_ID" "$SHELL_JSON"; then
    tmp="$(mktemp)"
    jq --arg old "$OLD_PLUGIN_ID" --arg new "$PLUGIN_ID" '
      (.bar.layout // {}) |= with_entries(.value |= map(if .id == $old then .id = $new else . end))
      | .plugins = ((.plugins // []) | map(if .id == $old then .id = $new else . end))
    ' "$SHELL_JSON" > "$tmp" && mv "$tmp" "$SHELL_JSON"
    echo "keyarchy: renamed the bar entry in shell.json"
  fi
  if grep -qF 'hypr.omarkey-shim' "$HYPRLAND_LUA"; then
    cp "$HYPRLAND_LUA" "$HYPRLAND_LUA.bak.$(date +%s)"
    sed -i \
      -e 's/^-- Omarkey: wrap hl.bind/-- Keyarchy: wrap hl.bind/' \
      -e 's/hypr\.omarkey-shim/hypr.keyarchy-shim/' \
      -e 's/-- omarkey$/-- keyarchy/' \
      "$HYPRLAND_LUA"
  fi
fi

# The plugin registry rejects symlinks, so the repo is the source and this is a
# copy. Re-running overwrites it.
rm -rf "$PLUGIN_DEST"
mkdir -p "$PLUGIN_DEST"
cp "$SRC"/plugin/* "$PLUGIN_DEST/"

cp "$SRC/hypr/keyarchy-shim.lua" "$SHIM_DEST"

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

# The shell rescans plugin folders on its own, but `plugin enable` fails with
# "unknown plugin" if it runs before that lands on a freshly copied folder.
enabled=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if omarchy plugin enable "$PLUGIN_ID" >/dev/null 2>&1; then enabled=1; break; fi
  sleep 0.5
done
[[ $enabled == 1 ]] || echo "keyarchy: could not enable automatically; run 'omarchy plugin enable $PLUGIN_ID'" >&2

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

echo "keyarchy: installed. Omarchy $(omarchy version 2>/dev/null || echo unknown)."
echo "keyarchy: click a workspace in the bar to see it work."
