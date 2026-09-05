#!/usr/bin/env bash
# Shared paths for Keyarchy verification helpers.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
# scripts/ -> verify-keyarchy/ -> skills/ -> .cursor/ -> repo
# Wait: scripts is at .cursor/skills/verify-keyarchy/scripts
# dirname = scripts, ../ = verify-keyarchy, ../../ = skills, ../../../ = .cursor, ../../../../ = repo
# That's correct.

PLUGIN_ID="slw.keyarchy"
PLUGIN_DEST="${HOME}/.config/omarchy/plugins/${PLUGIN_ID}"
SHIM_DEST="${HOME}/.config/hypr/keyarchy-shim.lua"
STATE_DIR="${HOME}/.local/state/keyarchy"
STATE_PATH="${STATE_DIR}/state.json"
USAGE_PATH="${STATE_DIR}/usage.json"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}/keyarchy"
BINDS_PATH="${RUNTIME_DIR}/binds.json"
BEACON_PATH="${RUNTIME_DIR}/last-bind"
ARTIFACT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/artifacts"
LOCK_DIR="${XDG_RUNTIME_DIR:-/tmp}/keyarchy-verify.lock"

fail() { echo "keyarchy-verify: $*" >&2; exit 1; }

qs_log() {
  local newest=""
  local f
  for f in /run/user/"$(id -u)"/quickshell/by-id/*/log.log; do
    [[ -f $f ]] || continue
    if [[ -z $newest || $f -nt $newest ]]; then newest=$f; fi
  done
  [[ -n $newest ]] || fail "no quickshell log under /run/user/$(id -u)/quickshell"
  printf '%s\n' "$newest"
}

acquire_lock() {
  if [[ -d $LOCK_DIR ]]; then
    fail "another keyarchy verify run holds $LOCK_DIR — refuse to double-drive the shared session"
  fi
  mkdir "$LOCK_DIR" || fail "could not create $LOCK_DIR"
  echo "$$" >"$LOCK_DIR/pid"
}

release_lock() {
  rm -rf "$LOCK_DIR"
}

# Live drives set these before mutating session state / opening the panel.
VERIFY_RUN_DIR=""
VERIFY_PANEL_OPEN=0

close_panel_if_open() {
  if [[ ${VERIFY_PANEL_OPEN:-0} == 1 ]]; then
    omarchy-shell -q "$PLUGIN_ID" toggle >/dev/null 2>&1 || true
    VERIFY_PANEL_OPEN=0
  fi
}

# EXIT cleanup for live drives: close panel, restore snapped state, drop lock.
verify_cleanup() {
  close_panel_if_open
  if [[ -n ${VERIFY_RUN_DIR:-} && -f $VERIFY_RUN_DIR/state.json.before ]]; then
    restore_user_state "$VERIFY_RUN_DIR" || true
  fi
  release_lock
}

usage_count_for() {
  local desc=$1
  python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],0))" "$USAGE_PATH" "$desc" 2>/dev/null || echo 0
}

# Service.qml debounces usage.json writes for 5s. Poll until the count rises.
wait_for_usage_increase() {
  local desc=$1
  local before=$2
  local deadline=$((SECONDS + 8))
  local hit
  while (( SECONDS < deadline )); do
    hit=$(usage_count_for "$desc")
    if [[ "$hit" -gt "$before" ]]; then
      printf '%s\n' "$hit"
      return 0
    fi
    sleep 0.25
  done
  usage_count_for "$desc"
  return 1
}

new_run_dir() {
  local id="${1:-$(date +%Y%m%d-%H%M%S)}"
  local dir="${ARTIFACT_ROOT}/${id}"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

snapshot_user_state() {
  local dir=$1
  mkdir -p "$dir"
  [[ -f $STATE_PATH ]] && cp "$STATE_PATH" "$dir/state.json.before" || echo '{}' >"$dir/state.json.before"
  [[ -f $USAGE_PATH ]] && cp "$USAGE_PATH" "$dir/usage.json.before" || echo '{}' >"$dir/usage.json.before"
  hyprctl activeworkspace -j >"$dir/workspace.before.json"
}

restore_user_state() {
  local dir=$1
  [[ -f $dir/state.json.before ]] && cp "$dir/state.json.before" "$STATE_PATH"
  [[ -f $dir/usage.json.before ]] && cp "$dir/usage.json.before" "$USAGE_PATH"
  if [[ -f $dir/workspace.before.json ]]; then
    local ws
    ws=$(python3 -c "import json; print(json.load(open('$dir/workspace.before.json'))['id'])")
    hyprctl dispatch "hl.dsp.focus({ workspace = '$ws' })" >/dev/null || true
  fi
}

clear_action_cooldown() {
  # Let a specific action be teachable again without wiping the whole history.
  local action=$1
  python3 - "$STATE_PATH" "$action" <<'PY'
import json, sys
path, action = sys.argv[1], sys.argv[2]
try:
    state = json.load(open(path))
except Exception:
    state = {"version": 2, "counts": {}, "lastAt": {}, "meta": {}, "lastAnyAt": 0}
state.setdefault("lastAt", {})[action] = 0
state["lastAnyAt"] = 0
json.dump(state, open(path, "w"), indent=2)
open(path, "a").write("\n")
PY
}
