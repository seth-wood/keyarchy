#!/bin/bash
# Install Keyarchy from a clone, the way `omarchy plugin add` would: copy the
# tracked files into the plugin folder, install the Hyprland shim, enable the
# plugin. Use this when hacking on the repo; users installing from GitHub can
# `omarchy plugin add` instead (see README).
#
# Safe to re-run. Migrates a leftover Omarkey install if one is still around.

set -euo pipefail

PATH=/usr/bin:/bin
export PATH

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ID="slw.keyarchy"
PLUGIN_DEST="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
HYPRLAND_LUA="$HOME/.config/hypr/hyprland.lua"
OLD_PLUGIN_ID="slw.omarkey"
OLD_PLUGIN_DEST="$HOME/.config/omarchy/plugins/$OLD_PLUGIN_ID"
OLD_SHIM_DEST="$HOME/.config/hypr/omarkey-shim.lua"
SHELL_JSON="$HOME/.config/omarchy/shell.json"
OLD_STATE="$HOME/.local/state/omarkey"
NEW_STATE="$HOME/.local/state/keyarchy"

fail() { echo "keyarchy: $*" >&2; exit 1; }

# Replace a file through a fresh temporary in its own directory rather than
# with sed -i or cp, both of which write through a symlink planted on the
# destination name.
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

command -v omarchy >/dev/null || fail "omarchy not found on PATH"
[[ -f $HYPRLAND_LUA ]] || fail "missing $HYPRLAND_LUA"

omarchy plugin validate "$SRC" >/dev/null || fail "plugin manifest failed validation"

# Drop the previous name so the bar does not keep two coaches.
if [[ -d $OLD_PLUGIN_DEST ]] || [[ -f $OLD_SHIM_DEST ]] \
  || { [[ -f $HYPRLAND_LUA ]] && grep -qF 'hypr.omarkey-shim' "$HYPRLAND_LUA"; }; then
  echo "keyarchy: migrating from omarkey"
  omarchy plugin disable "$OLD_PLUGIN_ID" >/dev/null 2>&1 || true
  rm -rf "$OLD_PLUGIN_DEST"
  rm -f "$OLD_SHIM_DEST"
  if [[ ${XDG_RUNTIME_DIR:-} =~ ^/run/user/[0-9]+$ ]]; then
    rm -f -- "$XDG_RUNTIME_DIR/omarkey/binds.json" "$XDG_RUNTIME_DIR/omarkey/last-bind" \
      "$XDG_RUNTIME_DIR/omarkey/last-workspace-intent"
    rmdir -- "$XDG_RUNTIME_DIR/omarkey" 2>/dev/null || true
  fi
  if [[ -d $OLD_STATE && ! -e $NEW_STATE ]]; then
    mv "$OLD_STATE" "$NEW_STATE"
    echo "keyarchy: moved lesson history to ~/.local/state/keyarchy"
  fi
  if [[ -f $SHELL_JSON ]] && grep -qF "$OLD_PLUGIN_ID" "$SHELL_JSON"; then
    tmp="$(mktemp -p "$(dirname -- "$SHELL_JSON")" ".keyarchy.XXXXXXXXXX")"
    jq --arg old "$OLD_PLUGIN_ID" --arg new "$PLUGIN_ID" '
      (.bar.layout // {}) |= with_entries(.value |= map(if .id == $old then .id = $new else . end))
      | .plugins = ((.plugins // []) | map(if .id == $old then .id = $new else . end))
    ' "$SHELL_JSON" > "$tmp" \
      && chmod --reference="$SHELL_JSON" -- "$tmp" 2>/dev/null \
      && mv -f -T -- "$tmp" "$SHELL_JSON"
    rm -f -- "$tmp"
    echo "keyarchy: renamed the bar entry in shell.json"
  fi
  if grep -qF 'hypr.omarkey-shim' "$HYPRLAND_LUA"; then
    backup="$(mktemp -p "$(dirname -- "$HYPRLAND_LUA")" "hyprland.lua.bak.$(date +%s).XXXXXX")"
    cat -- "$HYPRLAND_LUA" >"$backup"
    edit="$(mktemp -p "$(dirname -- "$HYPRLAND_LUA")" ".keyarchy-edit.XXXXXXXXXX")"
    sed \
      -e 's/^-- Omarkey: wrap hl.bind/-- Keyarchy: wrap hl.bind/' \
      -e 's/hypr\.omarkey-shim/hypr.keyarchy-shim/' \
      -e 's/-- omarkey$/-- keyarchy/' \
      "$HYPRLAND_LUA" >"$edit"
    if [[ "$(wc -l <"$edit")" -eq "$(wc -l <"$HYPRLAND_LUA")" ]]; then
      publish "$edit" "$HYPRLAND_LUA"
      echo "keyarchy: renamed the shim require in hyprland.lua (backup: $backup)"
    else
      echo "keyarchy: refusing to edit $HYPRLAND_LUA; the rename changed its length" >&2
    fi
    rm -f -- "$edit"
  fi
fi

# The plugin registry rejects symlinks, so the repo is the source and this is a
# copy. `omarchy plugin add` clones instead; copying the tracked files gives the
# same tree, so `doctor` can diff the two.
[[ -d $SRC/.git ]] || fail "not a git checkout; install with 'omarchy plugin add' instead"
rm -rf "$PLUGIN_DEST"
mkdir -p "$PLUGIN_DEST"
git -C "$SRC" ls-files -z ':!.cursor' | while IFS= read -r -d '' f; do
  mkdir -p "$PLUGIN_DEST/$(dirname "$f")"
  cp -a "$SRC/$f" "$PLUGIN_DEST/$f"
done

"$SRC/install-shim.sh"

# The shell rescans plugin folders on its own, but `plugin enable` fails with
# "unknown plugin" if it runs before that lands on a freshly copied folder.
enabled=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if omarchy plugin enable "$PLUGIN_ID" >/dev/null 2>&1; then enabled=1; break; fi
  sleep 0.5
done
[[ $enabled == 1 ]] || echo "keyarchy: could not enable automatically; run 'omarchy plugin enable $PLUGIN_ID'" >&2

echo "keyarchy: installed. Omarchy $(omarchy version 2>/dev/null || echo unknown)."
