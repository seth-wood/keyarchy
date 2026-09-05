-- Keyarchy shim.
--
-- Wraps hl.bind so that:
--   1. Every keybind activation touches a beacon file. The Keyarchy shell plugin
--      uses that as a positive "this came from the keyboard" signal, so it can
--      stay quiet when you already used the shortcut.
--   2. Every bind's real key string is exported to binds.json. This is better
--      than `hyprctl binds -j`, which reports an empty key for the 59 `code:NN`
--      binds -- including every workspace switch.
--
-- Wraps hl.dsp.focus / hl.dispatch to stamp last-workspace-intent only when a
-- workspace-only focus descriptor is actually dispatched. Bind registration
-- calls focus without dispatch; a window-targeted focus is not a workspace switch.
--
-- Installed to ~/.config/hypr/keyarchy-shim.lua and required from hyprland.lua
-- BEFORE require("default.hypr.omarchy"). Removing that require fully disables
-- this file; the plugin then degrades to silence rather than misfiring.

local M = {}

local runtime_dir = os.getenv("XDG_RUNTIME_DIR")
if not runtime_dir or runtime_dir == "" then
  runtime_dir = "/tmp"
end

local state_dir = runtime_dir .. "/keyarchy"
local beacon_path = state_dir .. "/last-bind"
local intent_path = state_dir .. "/last-workspace-intent"
local binds_path = state_dir .. "/binds.json"

-- Requiring this module means Hyprland is (re)loading its config, so the bind
-- registry starts over. It lives on _G because the wrapper installed on the
-- first load keeps running across reloads, while this module table does not.
_G.__keyarchy_binds = {}
_G.__keyarchy_seen = {}

local function write_file(path, contents)
  local file = io.open(path, "w")
  if not file then return end
  file:write(contents)
  file:close()
end

local function json_escape(value)
  value = tostring(value)
  value = value:gsub("[\\\"]", "\\%0")
  value = value:gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
  return value
end

-- Rewritten only when a new description shows up, so this costs one write per
-- bind at config load and nothing at all while you use the desktop.
local function flush_binds()
  local parts = {}
  local binds = _G.__keyarchy_binds
  for index = 1, #binds do
    parts[#parts + 1] = "\"" .. json_escape(binds[index].description)
      .. "\":\"" .. json_escape(binds[index].keys) .. "\""
  end
  write_file(binds_path, "{" .. table.concat(parts, ",") .. "}")
end

local function record_bind(keys, description)
  if not keys or not description or description == "" then return end
  if _G.__keyarchy_seen[description] then return end

  _G.__keyarchy_seen[description] = true
  local binds = _G.__keyarchy_binds
  binds[#binds + 1] = { keys = keys, description = description }
  flush_binds()
end

local function beacon(keys, description)
  write_file(beacon_path, (description or "") .. "\n" .. (keys or ""))
end

-- Mouse binds (SUPER + drag to move/resize) rely on press/release semantics
-- that a plain Lua callback would swallow, and they are not shortcuts worth
-- teaching, so they pass through untouched.
local function is_mouse_bind(keys, opts)
  if type(opts) == "table" and opts.mouse then return true end
  return type(keys) == "string" and keys:lower():find("mouse") ~= nil
end

local function is_workspace_only_focus(opts)
  return type(opts) == "table" and opts.workspace ~= nil and opts.window == nil
end

local function install_bind_wrap()
  if _G.__keyarchy_installed then return end
  if type(hl) ~= "table" or type(hl.bind) ~= "function" then return end

  _G.__keyarchy_installed = true
  os.execute("mkdir -p '" .. state_dir .. "' 2>/dev/null")

  local original_bind = hl.bind

  hl.bind = function(keys, dispatcher, opts)
    local key_string = type(keys) == "string" and keys or nil
    local description = type(opts) == "table" and opts.description or nil

    if is_mouse_bind(keys, opts) then
      return original_bind(keys, dispatcher, opts)
    end

    record_bind(key_string, description)

    local wrapped
    if type(dispatcher) == "function" then
      wrapped = function(...)
        beacon(key_string, description)
        return dispatcher(...)
      end
    else
      wrapped = function()
        beacon(key_string, description)
        return hl.dispatch(dispatcher)
      end
    end

    -- The return value matters: submaps in default/hypr/bindings/utilities.lua
    -- collect hl.bind(...) results into a list.
    return original_bind(keys, wrapped, opts)
  end
end

-- Separate flag so a config reload after upgrading Keyarchy can add intent
-- wraps even when the bind wrap was already installed by an older shim.
local function install_workspace_intent_wrap()
  if _G.__keyarchy_intent_wrapped then return end
  if type(hl) ~= "table" then return end

  local pending_workspace_intent = nil
  local wrapped_any = false

  if type(hl.dsp) == "table" and type(hl.dsp.focus) == "function" then
    local original_focus = hl.dsp.focus
    hl.dsp.focus = function(opts)
      local descriptor = original_focus(opts)
      if is_workspace_only_focus(opts) then
        pending_workspace_intent = {
          dispatcher = descriptor,
          action = "workspace:" .. tostring(opts.workspace)
        }
      end
      return descriptor
    end
    wrapped_any = true
  end

  if type(hl.dispatch) == "function" then
    local original_dispatch = hl.dispatch
    hl.dispatch = function(descriptor)
      if pending_workspace_intent ~= nil and descriptor == pending_workspace_intent.dispatcher then
        write_file(intent_path, pending_workspace_intent.action .. "\n")
      end
      return original_dispatch(descriptor)
    end
    wrapped_any = true
  end

  if wrapped_any then
    _G.__keyarchy_intent_wrapped = true
    os.execute("mkdir -p '" .. state_dir .. "' 2>/dev/null")
  end
end

function M.install()
  install_bind_wrap()
  install_workspace_intent_wrap()
end

M.install()

return M
