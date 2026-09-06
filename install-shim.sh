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

# Fixed PATH: everything below resolves through it, and a prepended directory
# is the cheapest way to get a different `jq` or `awk` than the one meant.
PATH=/usr/bin:/bin
export PATH

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

# cp writes through a symlink planted on the destination name; a fresh
# temporary in the same directory followed by mv does not, because rename(2)
# replaces the link rather than following it.
publish() {
  local source=$1 dest=$2 mode=$3 temp
  temp="$(mktemp -p "$(dirname -- "$dest")" ".keyarchy.XXXXXXXXXX")" || return 1
  if ! cat -- "$source" >"$temp"; then
    rm -f -- "$temp"
    return 1
  fi
  chmod "$mode" -- "$temp"
  mv -f -T -- "$temp" "$dest"
}

publish "$SHIM_SRC" "$SHIM_DEST" 644 || fail "could not install $SHIM_DEST"

if grep -qF 'hypr.keyarchy-shim' "$HYPRLAND_LUA"; then
  echo "keyarchy: shim already loaded from hyprland.lua"
else
  grep -qF "$ANCHOR" "$HYPRLAND_LUA" \
    || fail "could not find '$ANCHOR' in $HYPRLAND_LUA; add '$SHIM_LINE' above it by hand"

  BACKUP="$(mktemp -p "$(dirname -- "$HYPRLAND_LUA")" "hyprland.lua.bak.$(date +%s).XXXXXX")"
  cat -- "$HYPRLAND_LUA" >"$BACKUP"
  echo "keyarchy: backed up hyprland.lua to $BACKUP"

  # The shim must wrap hl.bind before Omarchy registers any binding. Written
  # to an unpredictable name in the same directory rather than a fixed .tmp
  # sibling, then renamed into place.
  EDIT="$(mktemp -p "$(dirname -- "$HYPRLAND_LUA")" ".keyarchy-edit.XXXXXXXXXX")"
  trap 'rm -f -- "$EDIT"' EXIT
  awk -v line="$SHIM_LINE" -v anchor="$ANCHOR" '
    index($0, anchor) && !done { print "-- Keyarchy: wrap hl.bind before any binding is registered."; print line; done = 1 }
    { print }
  ' "$HYPRLAND_LUA" > "$EDIT"

  # Refuse to publish an edit that did not do what it claimed: an anchor that
  # moved between the grep above and the rewrite would otherwise silently
  # produce a config without the shim line in it.
  grep -qF "$SHIM_LINE" "$EDIT" || fail "the edit did not add the shim line; $HYPRLAND_LUA is unchanged"
  [ "$(wc -l <"$EDIT")" -eq "$(( $(wc -l <"$HYPRLAND_LUA") + 2 ))" ] \
    || fail "the edit changed more than the two lines it should have; $HYPRLAND_LUA is unchanged"

  mv -f -T -- "$EDIT" "$HYPRLAND_LUA"
  trap - EXIT
fi

if command -v hyprctl >/dev/null && [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
  hyprctl reload >/dev/null
  # Hyprland prints nothing here when the config is clean.
  errors="$(hyprctl configerrors | grep -v '^[[:space:]]*$' || true)"
  if [[ -n $errors ]]; then
    echo "keyarchy: Hyprland reported config errors after reload:" >&2
    echo "$errors" >&2
    # Roll back to the exact bytes that were there before, rather than leaving
    # a broken config behind and asking someone to run the uninstaller.
    if [[ -n ${BACKUP:-} && -f $BACKUP ]]; then
      publish "$BACKUP" "$HYPRLAND_LUA" 644 \
        && rm -f -- "$SHIM_DEST" \
        && hyprctl reload >/dev/null \
        && echo "keyarchy: rolled hyprland.lua back to $BACKUP" >&2
    fi
    exit 1
  fi
  echo "keyarchy: hyprland reloaded cleanly ($(hyprctl binds -j | grep -c '"description"') binds registered)"
fi

echo "keyarchy: shim installed. Click a workspace in the bar to see it work."
