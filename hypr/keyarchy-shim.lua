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

-- The runtime directory has exactly one acceptable shape. There is no /tmp
-- fallback: on a machine without XDG_RUNTIME_DIR, /tmp/keyarchy is a path any
-- other account can create first, and whoever owns that directory owns the
-- beacon file that decides whether Keyarchy stays quiet and the binds file
-- that decides what its notifications say. Refuse it and go silent instead,
-- which is the same degraded mode as not installing this shim at all.
--
-- Validating the shape also means state_dir below is a literal of the form
-- /run/user/<digits>/keyarchy -- no quote, space or shell metacharacter can
-- reach the one os.execute in this file.
local function validated_runtime_dir()
  local value = os.getenv("XDG_RUNTIME_DIR")
  if type(value) ~= "string" then return nil end
  value = value:gsub("/+$", "")
  if value:match("^/run/user/%d+$") == nil then return nil end
  return value
end

local runtime_dir = validated_runtime_dir()
local state_dir = runtime_dir and (runtime_dir .. "/keyarchy") or nil
local beacon_path = state_dir and (state_dir .. "/last-bind") or nil
local intent_path = state_dir and (state_dir .. "/last-workspace-intent") or nil
local binds_path = state_dir and (state_dir .. "/binds.json") or nil

-- Set once, by ensure_state_dir. Every write checks it, so a directory that
-- could not be created or that turned out to be a symlink means no writes at
-- all rather than writes that land somewhere else.
local writes_enabled = false

-- Requiring this module means Hyprland is (re)loading its config, so the bind
-- registry starts over. It lives on _G because the wrapper installed on the
-- first load keeps running across reloads, while this module table does not.
_G.__keyarchy_binds = {}
_G.__keyarchy_seen = {}

-- Create the runtime directory 0700 and decide, once, whether it is safe to
-- write into. `test ! -L` is what refuses a symlink planted on the name:
-- `test -d` alone follows one. state_dir is a validated literal here, not
-- data, which is the only reason a shell is acceptable at all.
local function ensure_state_dir()
  if state_dir == nil then return end
  os.execute("mkdir -p -m 700 '" .. state_dir .. "' 2>/dev/null")
  local ok = os.execute("test -d '" .. state_dir .. "' && test ! -L '" .. state_dir .. "'")
  writes_enabled = (ok == true or ok == 0)
end

local temp_counter = 0

-- Publish through a fresh name in the same directory, then rename over the
-- destination. rename(2) replaces a symlink sitting on the target instead of
-- writing through it, and a name the writer picks at random is not a name
-- anything else can have planted a symlink at. Plain Lua has no O_NOFOLLOW,
-- so this is the shape that closes the redirect rather than moving it.
--
-- The files land at whatever the umask allows rather than 0600, because plain
-- Lua cannot fchmod either. The directory is the boundary here: it is created
-- 0700 inside /run/user/<uid>, which systemd creates 0700 and owns, so the
-- mode on the file grants nobody anything the directory has not already
-- refused. Every read of these files still goes through bin/keyarchy-file.
local function write_file(path, contents)
  if not writes_enabled then return end

  temp_counter = temp_counter + 1
  local temp_path = string.format(
    "%s.%d.%d.%d.tmp", path, os.time(), temp_counter, math.random(0, 1073741823))

  local file = io.open(temp_path, "w")
  if not file then return end

  local written = file:write(contents)
  local closed = file:close()
  if not written or not closed then
    os.remove(temp_path)
    return
  end

  if not os.rename(temp_path, path) then os.remove(temp_path) end
end

local function json_escape(value)
  value = tostring(value)
  value = value:gsub("[\\\"]", "\\%0")
  value = value:gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
  -- Every other control character, which JSON forbids raw and which would
  -- otherwise make the whole export unparseable on the reading side.
  value = value:gsub("%c", function(c) return string.format("\\u%04x", string.byte(c)) end)
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

-- Hyprland rebuilds the hl table on every config reload, which throws away the
-- wrapper the previous load installed. A boolean on _G cannot tell "already
-- wrapped" from "was wrapped, and then replaced", so the guard compares
-- against the wrapper this shim actually installed. Getting this wrong is
-- silent: binds keep working and Keyarchy simply never hears about them again.
local function install_bind_wrap()
  if type(hl) ~= "table" or type(hl.bind) ~= "function" then return end
  if hl.bind == _G.__keyarchy_bind_wrapper then return end

  _G.__keyarchy_installed = true

  local original_bind = hl.bind

  local wrapper = function(keys, dispatcher, opts)
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

  hl.bind = wrapper
  _G.__keyarchy_bind_wrapper = wrapper
end

-- Wrapped independently of hl.bind, and guarded the same way: a reload after an
-- upgrade must be able to re-wrap. The pending intent lives on _G so the focus
-- and dispatch wrappers still share it when only one of them was replaced.
local function install_workspace_intent_wrap()
  if type(hl) ~= "table" then return end

  local wrapped_any = false

  if type(hl.dsp) == "table" and type(hl.dsp.focus) == "function"
    and hl.dsp.focus ~= _G.__keyarchy_focus_wrapper then
    local original_focus = hl.dsp.focus
    local focus_wrapper = function(opts)
      local descriptor = original_focus(opts)
      if is_workspace_only_focus(opts) then
        _G.__keyarchy_pending_intent = {
          dispatcher = descriptor,
          action = "workspace:" .. tostring(opts.workspace)
        }
      end
      return descriptor
    end
    hl.dsp.focus = focus_wrapper
    _G.__keyarchy_focus_wrapper = focus_wrapper
    wrapped_any = true
  end

  if type(hl.dispatch) == "function" and hl.dispatch ~= _G.__keyarchy_dispatch_wrapper then
    local original_dispatch = hl.dispatch
    local dispatch_wrapper = function(descriptor)
      local pending = _G.__keyarchy_pending_intent
      if pending ~= nil and descriptor == pending.dispatcher then
        write_file(intent_path, pending.action .. "\n")
      end
      return original_dispatch(descriptor)
    end
    hl.dispatch = dispatch_wrapper
    _G.__keyarchy_dispatch_wrapper = dispatch_wrapper
    wrapped_any = true
  end

  if wrapped_any then _G.__keyarchy_intent_wrapped = true end
end

-- Exposed so test/shim.test.lua can assert the rule directly: this is the one
-- thing in here that decides whether another account can own Keyarchy's files.
M.validated_runtime_dir = validated_runtime_dir

function M.install()
  -- No usable runtime directory means no beacon and no bind export, and a
  -- Keyarchy that cannot tell a keypress from a click must not guess.
  if state_dir == nil then return end
  -- Runs on every load: the wrappers this module installs close over this
  -- module's writes_enabled, so each load has to answer the question itself.
  ensure_state_dir()
  install_bind_wrap()
  install_workspace_intent_wrap()
end

M.install()

return M
