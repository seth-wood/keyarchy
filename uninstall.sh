#!/bin/bash
# Remove Keyarchy and put hyprland.lua back the way it was. Works from a clone
# or from the installed plugin folder (where `omarchy plugin add` puts it).

set -euo pipefail

PATH=/usr/bin:/bin
export PATH

PLUGIN_ID="slw.keyarchy"
PLUGIN_DEST="$HOME/.config/omarchy/plugins/$PLUGIN_ID"

# Installed via `omarchy plugin add`, this script lives inside the folder it is
# about to delete, and bash reads a script as it runs. Re-exec from a copy.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
if [[ ${KEYARCHY_UNINSTALL_RELOCATED:-} != 1 && $SELF == "$PLUGIN_DEST"/* ]]; then
  relocated="$(mktemp)"
  cp "$SELF" "$relocated"
  chmod +x "$relocated"
  status=0
  KEYARCHY_UNINSTALL_RELOCATED=1 "$relocated" "$@" || status=$?
  rm -f "$relocated"
  exit $status
fi
SHIM_DEST="$HOME/.config/hypr/keyarchy-shim.lua"
HYPRLAND_LUA="$HOME/.config/hypr/hyprland.lua"

# Replace a file through a fresh temporary in its own directory. sed -i and cp
# both resolve the destination name a second time and write through a symlink
# planted on it; rename(2) replaces the link instead.
publish() {
  local source=$1 dest=$2 temp
  temp="$(mktemp -p "$(dirname -- "$dest")" ".keyarchy.XXXXXXXXXX")" || return 1
  if ! cat -- "$source" >"$temp"; then
    rm -f -- "$temp"
    return 1
  fi
  chmod --reference="$dest" -- "$temp" 2>/dev/null || chmod 644 -- "$temp"
  mv -f -T -- "$temp" "$dest"
}

# Drop the require and the comment above it. A leftover require pointing at a
# deleted file would break the whole Hyprland config, so this runs first.
if [[ -f $HYPRLAND_LUA ]] && grep -qE 'hypr\.(keyarchy|omarkey)-shim' "$HYPRLAND_LUA"; then
  BACKUP="$(mktemp -p "$(dirname -- "$HYPRLAND_LUA")" "hyprland.lua.bak.$(date +%s).XXXXXX")"
  cat -- "$HYPRLAND_LUA" >"$BACKUP"

  EDIT="$(mktemp -p "$(dirname -- "$HYPRLAND_LUA")" ".keyarchy-edit.XXXXXXXXXX")"
  trap 'rm -f -- "$EDIT"' EXIT
  grep -vE '^-- (Keyarchy|Omarkey): wrap hl\.bind before any binding is registered\.$|hypr\.(keyarchy|omarkey)-shim' \
    "$HYPRLAND_LUA" >"$EDIT" || true

  # Refuse an edit that removed more than the block this plugin added.
  removed=$(( $(wc -l <"$HYPRLAND_LUA") - $(wc -l <"$EDIT") ))
  if (( removed >= 1 && removed <= 4 )); then
    publish "$EDIT" "$HYPRLAND_LUA"
    echo "keyarchy: removed the shim require from hyprland.lua (backup: $BACKUP)"
  else
    echo "keyarchy: refusing to edit $HYPRLAND_LUA; it would have removed $removed lines" >&2
    echo "keyarchy: remove the 'hypr.keyarchy-shim' require by hand" >&2
  fi
  rm -f -- "$EDIT"
  trap - EXIT
fi

rm -f "$SHIM_DEST" "$HOME/.config/hypr/omarkey-shim.lua"
rm -rf "$PLUGIN_DEST" "$HOME/.config/omarchy/plugins/slw.omarkey"

# The runtime files by their literal names, in a runtime directory of the one
# shape Keyarchy accepts. No rm -rf and no ${XDG_RUNTIME_DIR:-/tmp}: this
# plugin should not be deleting a /tmp directory it cannot prove it created.
RUNTIME="${XDG_RUNTIME_DIR:-}"
if [[ $RUNTIME =~ ^/run/user/[0-9]+/?$ ]]; then
  RUNTIME="${RUNTIME%/}"
  for dir in "$RUNTIME/keyarchy" "$RUNTIME/omarkey"; do
    [[ -d $dir && ! -L $dir ]] || continue
    rm -f -- "$dir/binds.json" "$dir/last-bind" "$dir/last-workspace-intent"
    rmdir -- "$dir" 2>/dev/null || echo "keyarchy: left $dir in place; it holds files Keyarchy did not write" >&2
  done
fi

omarchy plugin disable "$PLUGIN_ID" >/dev/null 2>&1 || true
omarchy plugin disable slw.omarkey >/dev/null 2>&1 || true

# `plugin disable` leaves the bar layout entry behind on some paths; strip it
# so the bar does not hold a slot for a plugin that no longer exists.
SHELL_JSON="$HOME/.config/omarchy/shell.json"
if [[ -f $SHELL_JSON ]] && grep -qE 'slw\.(keyarchy|omarkey)' "$SHELL_JSON"; then
  tmp="$(mktemp -p "$(dirname -- "$SHELL_JSON")" ".keyarchy.XXXXXXXXXX")"
  jq '
    (.bar.layout // {}) |= with_entries(.value |= map(select(.id != "slw.keyarchy" and .id != "slw.omarkey")))
    | .plugins = ((.plugins // []) | map(select(.id != "slw.keyarchy" and .id != "slw.omarkey")))
  ' "$SHELL_JSON" > "$tmp" \
    && chmod --reference="$SHELL_JSON" -- "$tmp" 2>/dev/null \
    && mv -f -T -- "$tmp" "$SHELL_JSON"
  rm -f -- "$tmp"
  echo "keyarchy: removed the bar entry from shell.json"
fi

if command -v hyprctl >/dev/null && [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
  hyprctl reload >/dev/null
  hyprctl configerrors
fi

echo "keyarchy: removed."
echo "keyarchy: kept: ~/.local/state/keyarchy/ (lesson history and the per-shortcut"
echo "keyarchy:        usage tally) and any hyprland.lua.bak.* backups in ~/.config/hypr/."
