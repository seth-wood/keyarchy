-- Mocks Hyprland's `hl` table and exercises the shim without touching the
-- running compositor. Run: lua test/shim.test.lua
--
-- The shim wraps every keybind on the machine, so a bug here breaks the whole
-- desktop. This runs before anything is installed.

local failures = 0

local function check(label, ok)
  if ok then
    print("ok   " .. label)
  else
    failures = failures + 1
    print("FAIL " .. label)
  end
end

-- The shim only accepts /run/user/<uid> as a runtime directory, so these tests
-- run against the real one rather than a directory under /tmp -- which is the
-- point: /tmp is a path another account can create first. The three files it
-- writes are snapshotted and put back, so running the tests on a live desktop
-- does not cost you the beacon state the running shell is watching.
local temp_dir = os.getenv("XDG_RUNTIME_DIR")
if temp_dir == nil or temp_dir:match("^/run/user/%d+$") == nil then
  print("SKIP no /run/user/<uid> runtime directory; run this inside a user session")
  os.exit(0)
end

local managed = { "/keyarchy/binds.json", "/keyarchy/last-bind", "/keyarchy/last-workspace-intent" }
local saved = {}

local function slurp(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local contents = file:read("*a")
  file:close()
  return contents
end

for _, name in ipairs(managed) do saved[name] = slurp(temp_dir .. name) end

local function restore()
  for _, name in ipairs(managed) do
    local path = temp_dir .. name
    if saved[name] == nil then
      os.remove(path)
    else
      local file = io.open(path, "w")
      if file then
        file:write(saved[name])
        file:close()
      end
    end
  end
end

local dispatched = {}
local registered = {}

_G.hl = {
  dispatch = function(descriptor)
    dispatched[#dispatched + 1] = descriptor
    return "dispatched:" .. tostring(descriptor)
  end,
  bind = function(keys, dispatcher, opts)
    registered[#registered + 1] = { keys = keys, dispatcher = dispatcher, opts = opts }
    return "bind-handle:" .. tostring(keys)
  end,
  dsp = {
    focus = function(opts)
      return { kind = "focus", opts = opts }
    end
  }
}

local original_bind = _G.hl.bind
local original_focus = _G.hl.dsp.focus
local original_dispatch = _G.hl.dispatch
package.path = os.getenv("HOME") .. "/.config/?.lua;" .. package.path
local here = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
local shim_path = here .. "../hypr/keyarchy-shim.lua"
dofile(shim_path)

check("wraps hl.bind", _G.hl.bind ~= original_bind)
check("wraps hl.dsp.focus", _G.hl.dsp.focus ~= original_focus)
check("wraps hl.dispatch", _G.hl.dispatch ~= original_dispatch)

local handle = hl.bind("SUPER + code:12", "descriptor-workspace-3", { description = "Switch to workspace 3" })
check("preserves hl.bind's return value (submaps collect it)", handle == "bind-handle:SUPER + code:12")

hl.bind("SUPER + W", "descriptor-close", { description = "Close window" })
hl.bind("SUPER + mouse:272", "descriptor-drag", { description = "Move window", mouse = true })
hl.bind("SUPER + X", "descriptor-undescribed", {})

local function read_file(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local contents = file:read("*a")
  file:close()
  return contents
end

local binds = read_file(temp_dir .. "/keyarchy/binds.json")
check("exports the real key string for a code:NN bind",
  binds ~= nil and binds:find('"Switch to workspace 3":"SUPER %+ code:12"') ~= nil)
check("exports plain binds", binds:find('"Close window":"SUPER %+ W"') ~= nil)
check("leaves mouse binds out of the export", binds:find("Move window") == nil)
check("leaves binds without a description out of the export", binds:find("SUPER %+ X") == nil)

-- The mouse bind must reach hl.bind untouched, or drag-to-move breaks.
local mouse_entry
for _, entry in ipairs(registered) do
  if entry.keys == "SUPER + mouse:272" then mouse_entry = entry end
end
check("passes mouse binds through unwrapped", mouse_entry ~= nil and mouse_entry.dispatcher == "descriptor-drag")

-- Firing a wrapped bind must beacon and still dispatch the original.
local close_entry
for _, entry in ipairs(registered) do
  if entry.keys == "SUPER + W" then close_entry = entry end
end
check("wraps a descriptor bind in a callable", type(close_entry.dispatcher) == "function")

local result = close_entry.dispatcher()
check("still dispatches the original descriptor", dispatched[#dispatched] == "descriptor-close")
check("returns the dispatch result", result == "dispatched:descriptor-close")

local beacon = read_file(temp_dir .. "/keyarchy/last-bind")
check("beacons the description and keys", beacon == "Close window\nSUPER + W")

-- A Lua-function dispatcher must be called with its arguments intact.
local received
hl.bind("SUPER + Z", function(...) received = { ... } return "fn-result" end, { description = "Custom" })
local custom_entry = registered[#registered]
check("wrapping a function dispatcher preserves its return value", custom_entry.dispatcher(1, "two") == "fn-result")
check("wrapping a function dispatcher preserves its arguments",
  received ~= nil and received[1] == 1 and received[2] == "two")

local intent_path = temp_dir .. "/keyarchy/last-workspace-intent"

local window_d = hl.dsp.focus({ window = "address:0xabc" })
hl.dispatch(window_d)
check("window focus dispatch does not write workspace intent", read_file(intent_path) == nil)

local workspace_d = hl.dsp.focus({ workspace = 3 })
check("workspace-only focus does not write intent", read_file(intent_path) == nil)
hl.dispatch(workspace_d)
check("workspace-only focus+dispatch writes intent", read_file(intent_path) == "workspace:3\n")

-- Reloading the config re-requires the shim; it must not wrap twice.
local wrapped_bind = _G.hl.bind
local wrapped_focus = _G.hl.dsp.focus
local wrapped_dispatch = _G.hl.dispatch
dofile(shim_path)
check("does not double-wrap on config reload", _G.hl.bind == wrapped_bind)
check("does not double-wrap dsp.focus on config reload", _G.hl.dsp.focus == wrapped_focus)
check("does not double-wrap dispatch on config reload", _G.hl.dispatch == wrapped_dispatch)

-- Older shims set __keyarchy_installed without intent wraps. A reload after
-- upgrade must still install focus/dispatch wraps once.
_G.__keyarchy_intent_wrapped = nil
_G.hl.dsp.focus = original_focus
_G.hl.dispatch = original_dispatch
dofile(shim_path)
check("upgrade reload wraps dsp.focus when intent flag was missing", _G.hl.dsp.focus ~= original_focus)
check("upgrade reload wraps dispatch when intent flag was missing", _G.hl.dispatch ~= original_dispatch)
local upgrade_d = hl.dsp.focus({ workspace = 9 })
hl.dispatch(upgrade_d)
check("upgrade reload intent wrap writes the intent file", read_file(intent_path) == "workspace:9\n")

-- The runtime directory rule itself: a /tmp fallback is what let another
-- account own the beacon, so it has to stay refused.
local shim = dofile(shim_path)
check("refuses /tmp as a runtime directory", shim.validated_runtime_dir ~= nil and (function()
  local original = os.getenv
  os.getenv = function(name) if name == "XDG_RUNTIME_DIR" then return "/tmp" end return original(name) end
  local result = shim.validated_runtime_dir()
  os.getenv = original
  return result == nil
end)())
check("refuses an unset runtime directory", (function()
  local original = os.getenv
  os.getenv = function(name) if name == "XDG_RUNTIME_DIR" then return nil end return original(name) end
  local result = shim.validated_runtime_dir()
  os.getenv = original
  return result == nil
end)())
check("refuses a runtime directory carrying shell metacharacters", (function()
  local original = os.getenv
  os.getenv = function(name)
    if name == "XDG_RUNTIME_DIR" then return "/run/user/1000'; touch /tmp/pwned; '" end
    return original(name)
  end
  local result = shim.validated_runtime_dir()
  os.getenv = original
  return result == nil
end)())
check("accepts /run/user/<uid>", (function()
  local original = os.getenv
  os.getenv = function(name) if name == "XDG_RUNTIME_DIR" then return "/run/user/1000/" end return original(name) end
  local result = shim.validated_runtime_dir()
  os.getenv = original
  return result == "/run/user/1000"
end)())

restore()

if failures > 0 then
  print(failures .. " failing")
  os.exit(1)
end
print("all shim checks passed")
