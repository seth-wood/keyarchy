// Pure logic for Keyarchy. No QML imports, so test/model.test.mjs can drive it
// under node. Style follows the first-party *Model.js files in
// $OMARCHY_PATH/shell/plugins/services/.

// Hyprland modmask bits. Rendered in Omarchy's own order (see
// default/hypr/bindings/tiling.lua): SUPER, CTRL, ALT, SHIFT.
var MODIFIERS = [
  { bit: 64, name: "SUPER" },
  { bit: 4, name: "CTRL" },
  { bit: 8, name: "ALT" },
  { bit: 1, name: "SHIFT" }
]

// X11 keycodes Omarchy binds by number, because their symbols move between
// layouts. 10..19 is the number row; 20/21 are minus and equals.
var KEYCODES = {
  "10": "1", "11": "2", "12": "3", "13": "4", "14": "5",
  "15": "6", "16": "7", "17": "8", "18": "9", "19": "0",
  "20": "MINUS", "21": "EQUAL"
}

var KEY_SYMBOLS = {
  RETURN: "RETURN", LEFT: "←", RIGHT: "→", UP: "↑", DOWN: "↓",
  SLASH: "/", PERIOD: ".", COMMA: ",", MINUS: "-", EQUAL: "=", SPACE: "SPACE"
}

// Window classes that stand in for a bound app. Matched case-insensitively,
// then by substring, against the description of an app launch bind.
var APP_CLASSES = {
  "alacritty": "Terminal",
  "foot": "Terminal",
  "kitty": "Terminal",
  "com.mitchellh.ghostty": "Terminal",
  "org.wezfurlong.wezterm": "Terminal",
  "chromium": "Browser",
  "google-chrome": "Browser",
  "brave-browser": "Browser",
  "firefox": "Browser",
  "zen": "Browser",
  "org.gnome.nautilus": "File manager",
  "nautilus": "File manager",
  "spotify": "Music",
  "obsidian": "Obsidian",
  "signal": "Signal",
  "1password": "Passwords"
}

// Everything below this line arrives from something Keyarchy does not
// control: the shim's export, a Hyprland event, a state file another process
// can write. So it is all capped, and none of it is trusted to be short.
var MAX_LABEL = 120          // one description or key string
var MAX_BINDS = 512          // entries taken from a binds export
var MAX_LESSONS = 200        // rows the panel will build from state.json
var MAX_TRACKED_ACTIONS = 500 // actions state.json will keep counts for
var MAX_USAGE_KEYS = 1000    // distinct descriptions usage.json will tally

// C0, DEL, C1 and the bidi overrides. Stripped rather than escaped: none of
// them mean anything in a key name, and a bidi override in a notification
// makes the toast read as something other than what it says.
var CONTROL_CHARS = /[\u0000-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069]/g

// The shell renders tooltips, notification bodies and panel headers with
// components a plugin cannot pin to PlainText, and Qt promotes anything that
// looks like markup to rich text -- which then loads <img src=...> from
// inside the shell process. Keyarchy's own Text elements are all PlainText,
// so this is for the sinks it hands strings to rather than owns.
var MARKUP_CHARS = /[<>&]/g

// A map with no prototype. Every one of these is keyed by a string from a
// file some other process writes, and on a plain object "toString" or
// "constructor" would read back as an inherited function rather than as a
// missing entry.
function emptyMap() {
  return Object.create(null)
}

function plainLabel(text, max) {
  var limit = Number(max) > 0 ? Number(max) : MAX_LABEL
  var value = String(text === undefined || text === null ? "" : text)
  value = value.replace(CONTROL_CHARS, " ").replace(MARKUP_CHARS, " ")
  value = value.replace(/\s+/g, " ").trim()
  return value.length > limit ? value.slice(0, limit) : value
}

// omarchy-notification-send parses options both before the headline and after
// it, and it has no "--" to end that. Nothing Keyarchy sends starts with a
// dash today, but the values come from a file, so a leading space keeps a
// dash-leading string out of option position without dropping what it says.
function notifyArgument(text) {
  var value = plainLabel(text, MAX_LABEL)
  return value.charAt(0) === "-" ? " " + value : value
}

// The runtime directory, or "" when Keyarchy should stay quiet. There is no
// /tmp fallback: a runtime path another account can pre-create is a runtime
// path another account owns, and the beacon that arrives through it decides
// what the notification says.
function runtimeStateDir(value) {
  var dir = String(value || "").replace(/\/+$/, "")
  return /^\/run\/user\/[0-9]+$/.test(dir) ? dir + "/keyarchy" : ""
}

// file:///a/b -> /a/b, for resolving a helper next to this plugin's QML.
function localPath(url) {
  return String(url || "").replace(/^file:\/\//, "")
}

var CATEGORY_OF_ACTION = {
  "workspace": "workspace",
  "move-to-workspace": "workspace",
  "close-window": "window",
  "fullscreen": "window",
  "toggle-float": "window",
  "focus-window": "focus",
  "launch": "launch"
}

function defaultConfig() {
  return {
    enabled: true,
    // Don't teach the same action again for five minutes...
    cooldownMs: 300000,
    // ...never two notifications inside five seconds...
    globalGapMs: 5000,
    // ...and give up on an action once you've been told this many times.
    lifetimeCap: 5,
    muted: [],
    categories: {
      window: true,
      workspace: true,
      launch: true,
      // Off by default: focus changes fire constantly, including as a side
      // effect of opening, closing, and switching workspaces.
      focus: false
    }
  }
}

function mergeConfig(overrides) {
  var config = defaultConfig()
  if (!overrides || typeof overrides !== "object") return config

  // Timings are numbers with a sane range, not "whatever the file said". A
  // string or a NaN here would make every comparison below false and turn the
  // cooldown off altogether.
  var LIMITS = { cooldownMs: 86400000, globalGapMs: 86400000, lifetimeCap: 1000 }
  for (var key in config) {
    if (key === "categories" || key === "muted") continue
    var value = overrides[key]
    if (value === undefined || value === null) continue
    if (key === "enabled") { config[key] = !!value; continue }
    var number = Number(value)
    if (!isFinite(number) || number < 0) continue
    config[key] = Math.min(Math.floor(number), LIMITS[key])
  }

  if (Array.isArray(overrides.muted)) {
    var muted = []
    for (var i = 0; i < overrides.muted.length && i < MAX_TRACKED_ACTIONS; i++) {
      muted.push(plainLabel(overrides.muted[i], MAX_LABEL))
    }
    config.muted = muted
  }

  if (overrides.categories && typeof overrides.categories === "object") {
    for (var category in config.categories) {
      if (overrides.categories[category] !== undefined) {
        config.categories[category] = !!overrides.categories[category]
      }
    }
  }

  return config
}

function emptyState() {
  return { counts: emptyMap(), lastAt: emptyMap(), meta: emptyMap(), lastAnyAt: 0 }
}

// Copy a parsed JSON object into a prototype-free map, dropping anything that
// is not a plain own key and stopping at `limit` entries rather than growing
// to whatever the file on disk asked for.
function adoptMap(source, limit, coerce) {
  var map = emptyMap()
  if (!source || typeof source !== "object") return map

  var count = 0
  for (var key in source) {
    if (!Object.prototype.hasOwnProperty.call(source, key)) continue
    if (count >= limit) break
    var label = plainLabel(key, MAX_LABEL)
    if (label === "") continue
    var value = coerce ? coerce(source[key]) : source[key]
    if (value === null) continue
    map[label] = value
    count++
  }
  return map
}

function finiteCount(value) {
  var number = Number(value)
  if (!isFinite(number) || number < 0) return null
  return Math.floor(number)
}

// "code:12" -> "3", "LEFT" -> "left arrow glyph", anything else uppercased.
function prettyKey(key) {
  var text = String(key || "").trim()
  if (text === "") return ""

  var codeMatch = text.match(/^code:(\d+)$/i)
  if (codeMatch) text = KEYCODES[codeMatch[1]] || ("code:" + codeMatch[1])

  var upper = text.toUpperCase()
  return KEY_SYMBOLS[upper] || upper
}

// "SUPER + SHIFT + code:12" -> "SUPER + SHIFT + 3"
function formatKeyString(keys) {
  var parts = String(keys || "").split("+")
  var rendered = []

  for (var i = 0; i < parts.length; i++) {
    var part = prettyKey(parts[i])
    if (part !== "") rendered.push(part)
  }

  return rendered.join(" + ")
}

// Fallback path only. hyprctl reports key "" and keycode 0 for every code:NN
// bind, so this cannot describe workspace shortcuts -- those entries are
// dropped rather than shown wrong.
function formatBind(bind) {
  var names = []
  var modmask = Number(bind.modmask || 0)

  for (var i = 0; i < MODIFIERS.length; i++) {
    if (modmask & MODIFIERS[i].bit) names.push(MODIFIERS[i].name)
  }

  var key = String(bind.key || "")
  if (key === "" && Number(bind.keycode || 0) > 0) key = "code:" + bind.keycode
  if (key === "") return ""

  names.push(prettyKey(key))
  return names.join(" + ")
}

// Shim output: { description: "SUPER + code:12" }. First wins, matching the
// shim's own dedupe, so "Browser" resolves to SUPER + SHIFT + RETURN rather
// than the later SUPER + SHIFT + B.
function parseShimBinds(text) {
  var raw = {}
  try {
    raw = JSON.parse(String(text || "{}")) || {}
  } catch (error) {
    return emptyMap()
  }
  if (typeof raw !== "object") return emptyMap()

  var binds = emptyMap()
  var count = 0
  for (var description in raw) {
    if (!Object.prototype.hasOwnProperty.call(raw, description)) continue
    if (count >= MAX_BINDS) break
    var label = plainLabel(description, MAX_LABEL)
    var keys = plainLabel(formatKeyString(raw[description]), MAX_LABEL)
    if (label === "" || keys === "") continue
    if (binds[label] !== undefined) continue
    binds[label] = keys
    count++
  }
  return binds
}

function parseHyprctlBinds(text) {
  var list = []
  try {
    list = JSON.parse(String(text || "[]")) || []
  } catch (error) {
    return emptyMap()
  }
  if (!Array.isArray(list)) return emptyMap()

  var binds = emptyMap()
  var count = 0
  for (var i = 0; i < list.length && count < MAX_BINDS; i++) {
    var bind = list[i] || {}
    var description = plainLabel(bind.description, MAX_LABEL)
    if (description === "" || bind.mouse || String(bind.submap || "") !== "") continue
    if (binds[description] !== undefined) continue

    var keys = plainLabel(formatBind(bind), MAX_LABEL)
    if (keys === "") continue
    binds[description] = keys
    count++
  }
  return binds
}

function appDescriptionForClass(windowClass) {
  var key = String(windowClass || "").toLowerCase()
  if (key === "") return null
  if (APP_CLASSES[key]) return APP_CLASSES[key]

  for (var candidate in APP_CLASSES) {
    if (key.indexOf(candidate) !== -1) return APP_CLASSES[candidate]
  }
  return null
}

// Turn a Hyprland socket2 event into the action it represents and the
// description of the bind that would have done the same thing. Returns null
// for everything Keyarchy has nothing to teach about.
function classify(name, data) {
  var fields = String(data === undefined || data === null ? "" : data).split(",")

  switch (String(name || "")) {
    case "workspacev2":
      // A workspace name is whatever a client last called it, and it ends up
      // in a notification summary, so it is bounded here at the door.
      var workspace = plainLabel(fields[1] || fields[0] || "", 48)
      if (workspace === "") return null
      return {
        action: "workspace:" + workspace,
        category: "workspace",
        description: "Switch to workspace " + workspace
      }

    case "movewindowv2":
      var target = plainLabel(fields[2] || fields[1] || "", 48)
      if (target === "") return null
      return {
        action: "move-to-workspace:" + target,
        category: "workspace",
        description: "Move window to workspace " + target
      }

    case "closewindow":
      return { action: "close-window", category: "window", description: "Close window" }

    case "fullscreen":
      // 0 is leaving fullscreen, which needs no separate lesson.
      if (String(fields[0]) !== "1") return null
      return { action: "fullscreen", category: "window", description: "Full screen" }

    case "changefloatingmode":
      // 0 is leaving floating (back to tiling); only teach the float direction.
      if (String(fields[1]) !== "1") return null
      return {
        action: "toggle-float",
        category: "window",
        description: "Toggle window floating/tiling"
      }

    case "activewindowv2":
      return {
        action: "focus-window",
        category: "focus",
        // Honest label: the lesson collapses all four arrow binds into one hint.
        description: "Focus another window",
        hint: "arrows"
      }

    case "openwindow":
      var description = appDescriptionForClass(fields[2])
      if (!description) return null
      return {
        action: "launch:" + description,
        category: "launch",
        description: description
      }
  }

  return null
}

// The four directional focus binds share a modifier, so present them as one
// lesson instead of naming an arbitrary direction.
function focusHint(binds) {
  var directions = ["left", "right", "above", "below"]
  var arrows = []
  var modifier = null

  for (var i = 0; i < directions.length; i++) {
    var keys = binds["Focus on " + directions[i] + " window"]
    if (!keys) return null

    var split = keys.lastIndexOf(" + ")
    if (split === -1) return null

    var prefix = keys.slice(0, split)
    if (modifier === null) modifier = prefix
    else if (modifier !== prefix) return null

    arrows.push(keys.slice(split + 3))
  }

  return modifier + " + " + arrows.join(" ")
}

function keysForAction(match, binds) {
  if (match.hint === "arrows") return focusHint(binds)
  return binds[match.description] || null
}

// Did a recent keybind beacon mean this event came from the keyboard?
// Timing covers near-synchronous events (workspace, close). Description
// matching covers delayed ones (openwindow can land seconds after the bind).
function beaconSuppresses(match, lastBeaconAt, lastBeaconDescription, entryAt, now, options) {
  if (!lastBeaconAt) return false

  var leadMs = options && options.beaconLeadMs != null ? options.beaconLeadMs : 150
  var matchMs = options && options.beaconMatchMs != null ? options.beaconMatchMs : 5000

  if (lastBeaconAt >= entryAt - leadMs) return true
  if (now - lastBeaconAt > matchMs) return false

  var beacon = String(lastBeaconDescription || "")
  if (beacon === "") return false

  if (match && match.hint === "arrows") {
    return /^Focus on .+ window$/.test(beacon)
  }

  return beacon === String(match && match.description || "")
}

function requiresWorkspaceIntent(match) {
  return /^workspace:/.test(String(match && match.action || ""))
}

function workspaceIntentAllows(match, lastIntentAt, lastIntentAction, entryAt, now, options) {
  if (!requiresWorkspaceIntent(match)) return true
  if (!lastIntentAt) return false

  var leadMs = options && options.intentLeadMs != null ? options.intentLeadMs : 150
  var matchMs = options && options.intentMatchMs != null ? options.intentMatchMs : 5000
  if (now - lastIntentAt > matchMs) return false
  if (String(lastIntentAction || "") !== String(match.action || "")) return false
  if (lastIntentAt >= entryAt - leadMs) return true
  return false
}

function categoryFor(action) {
  var prefix = String(action || "").split(":")[0]
  return CATEGORY_OF_ACTION[prefix] || null
}

function shouldNotify(action, now, state, config) {
  if (!config.enabled) return false

  var category = categoryFor(action)
  if (category && config.categories[category] === false) return false
  if (config.muted && config.muted.indexOf(action) !== -1) return false
  if ((state.counts[action] || 0) >= config.lifetimeCap) return false

  // An absent timestamp means "never taught", which must not read as
  // "taught at epoch 0" and get swallowed by the cooldown.
  if (state.lastAnyAt && now - state.lastAnyAt < config.globalGapMs) return false
  if (state.lastAt[action] && now - state.lastAt[action] < config.cooldownMs) return false

  return true
}

function recordNotified(action, now, state, match, keys) {
  // Fail closed rather than tracking an unbounded number of actions: the
  // actions are Keyarchy's own vocabulary plus a workspace name, and a name
  // per switch would otherwise grow state.json forever.
  if (state.counts[action] === undefined) {
    var tracked = 0
    for (var key in state.counts) tracked++
    if (tracked >= MAX_TRACKED_ACTIONS) return state
  }
  state.counts[action] = (state.counts[action] || 0) + 1
  state.lastAt[action] = now
  state.lastAnyAt = now
  if (match) state.meta[action] = { description: match.description, keys: keys || "" }
  return state
}

// ------------------------------------------------------------------ panel

function parseCounts(text) {
  try {
    var parsed = JSON.parse(String(text || "{}"))
    return adoptMap(parsed, MAX_USAGE_KEYS, finiteCount)
  } catch (error) {
    return emptyMap()
  }
}

// One more activation of `description`, refusing to grow past MAX_USAGE_KEYS
// so a session that sees a new description every time cannot grow the tally
// without bound in a process that stays loaded for days.
function countUsage(usage, description) {
  var label = plainLabel(description, MAX_LABEL)
  var next = emptyMap()
  var count = 0
  for (var key in usage) {
    next[key] = usage[key]
    count++
  }
  if (label === "") return next
  if (next[label] === undefined && count >= MAX_USAGE_KEYS) return next
  next[label] = (next[label] || 0) + 1
  return next
}

// The three maps in state.json, adopted the same way the usage tally is.
function parseState(text) {
  var next = emptyState()
  var parsed = null
  try {
    parsed = JSON.parse(String(text || "{}"))
  } catch (error) {
    // A corrupt state file only costs the nag history; start over.
    return next
  }
  if (!parsed || typeof parsed !== "object") return next

  next.counts = adoptMap(parsed.counts, MAX_TRACKED_ACTIONS, finiteCount)
  next.lastAt = adoptMap(parsed.lastAt, MAX_TRACKED_ACTIONS, finiteCount)
  next.meta = adoptMap(parsed.meta, MAX_TRACKED_ACTIONS, function(value) {
    if (!value || typeof value !== "object") return null
    return { description: plainLabel(value.description, MAX_LABEL), keys: plainLabel(value.keys, MAX_LABEL) }
  })
  next.lastAnyAt = finiteCount(parsed.lastAnyAt) || 0
  return next
}

// What persistState writes back. Plain objects, because JSON.stringify walks
// a null-prototype map fine but the shell's own config writer does not.
function serializeState(state) {
  return {
    version: 2,
    counts: state.counts,
    lastAt: state.lastAt,
    meta: state.meta,
    lastAnyAt: state.lastAnyAt || 0
  }
}

// How much of your own keymap you actually reach for. `usage` is keyed by bind
// description and filled in from the shim's beacon, one entry per activation.
function usageSummary(binds, usage) {
  var total = 0
  var used = 0

  for (var description in binds) {
    total++
    if ((usage[description] || 0) > 0) used++
  }

  return { used: used, total: total }
}

// Bindings you have never once triggered, most useful first. Ordering is
// alphabetical rather than arbitrary so the list is stable between reads.
function unusedBinds(binds, usage) {
  var list = []

  for (var description in binds) {
    if ((usage[description] || 0) > 0) continue
    list.push({ description: description, keys: binds[description] })
  }

  list.sort(function(a, b) { return a.description < b.description ? -1 : a.description > b.description ? 1 : 0 })
  return list
}

// Deterministic for a given offset, so "show another" walks the list instead
// of reshuffling and repeating what it just showed.
function sampleUnused(list, offset, count) {
  var picked = []
  if (list.length === 0) return picked

  for (var i = 0; i < count && i < list.length; i++) {
    picked.push(list[(offset + i) % list.length])
  }
  return picked
}

// A readable label for an action recorded before its description was stored,
// so an older history reads as "Close window" rather than "close-window".
function describeAction(action) {
  var parts = String(action || "").split(":")

  switch (parts[0]) {
    case "workspace": return "Switch to workspace " + parts[1]
    case "move-to-workspace": return "Move window to workspace " + parts[1]
    case "close-window": return "Close window"
    case "fullscreen": return "Full screen"
    case "toggle-float": return "Toggle window floating/tiling"
    case "focus-window": return "Focus another window"
    case "launch": return parts.slice(1).join(":")
  }

  return String(action || "")
}

// Lessons already delivered, most recently taught first, with the ones that
// hit the lifetime cap marked so you can see what you have finished learning.
function lessonRows(state, config) {
  var rows = []

  for (var action in state.counts) {
    var meta = state.meta && state.meta[action] ? state.meta[action] : {}
    rows.push({
      action: action,
      description: meta.description || describeAction(action),
      keys: meta.keys || "",
      count: state.counts[action],
      lastAt: state.lastAt[action] || 0,
      graduated: state.counts[action] >= config.lifetimeCap,
      muted: config.muted.indexOf(action) !== -1
    })
  }

  rows.sort(function(a, b) { return b.lastAt - a.lastAt })
  return rows.length > MAX_LESSONS ? rows.slice(0, MAX_LESSONS) : rows
}

// Toggling one entry of the muted list, returned as a new array so the caller
// can hand it straight to a config write.
function toggleMuted(muted, action) {
  var next = []
  var removed = false

  for (var i = 0; i < muted.length; i++) {
    if (muted[i] === action) { removed = true; continue }
    next.push(muted[i])
  }

  if (!removed) next.push(action)
  return next
}

function notificationBody(description, keys) {
  return description + "  →  " + keys
}

// Windowrules that force fullscreen without a user gesture. Mirrored from
// Omarchy's shipped apps/*.lua so Keyarchy does not teach SUPER + F for them.
var DEFAULT_COMPOSITOR_FULLSCREEN_RULES = [
  { className: "org.omarchy.screensaver" },
  { className: "com.moonlight_stream.Moonlight" },
  { className: "com.libretro.RetroArch" },
  { classRegex: ".*[Rr]esolve.*", titleRegex: "^DaVinci Resolve( Studio)? - .+$" }
]

function emptyFocus() {
  return { className: "", title: "" }
}

function parseActiveWindow(data) {
  var text = String(data === undefined || data === null ? "" : data)
  var comma = text.indexOf(",")
  if (comma === -1) return { className: text, title: "" }
  return { className: text.slice(0, comma), title: text.slice(comma + 1) }
}

function noteFocus(focus, name, data) {
  if (String(name || "") !== "activewindow") {
    return focus && typeof focus === "object" ? focus : emptyFocus()
  }
  return parseActiveWindow(data)
}

function ruleMatchesFocus(rule, focus) {
  if (!rule || !focus) return false
  var className = String(focus.className || "")
  if (className === "") return false

  var classOk = false
  if (rule.classRegex) {
    classOk = new RegExp(rule.classRegex, "i").test(className)
  } else {
    classOk = className.toLowerCase() === String(rule.className || "").toLowerCase()
  }
  if (!classOk) return false

  if (rule.titleRegex) {
    return new RegExp(rule.titleRegex).test(String(focus.title || ""))
  }
  return true
}

function compositorOwnsFullscreen(focus) {
  for (var i = 0; i < DEFAULT_COMPOSITOR_FULLSCREEN_RULES.length; i++) {
    if (ruleMatchesFocus(DEFAULT_COMPOSITOR_FULLSCREEN_RULES[i], focus)) return true
  }
  return false
}

function compositorOwnsAction(match, focus) {
  if (!match || String(match.action || "") !== "fullscreen") return false
  return compositorOwnsFullscreen(focus)
}

if (typeof module !== "undefined") {
  module.exports = {
    emptyMap: emptyMap,
    plainLabel: plainLabel,
    notifyArgument: notifyArgument,
    runtimeStateDir: runtimeStateDir,
    localPath: localPath,
    adoptMap: adoptMap,
    countUsage: countUsage,
    parseState: parseState,
    serializeState: serializeState,
    defaultConfig: defaultConfig,
    mergeConfig: mergeConfig,
    emptyState: emptyState,
    prettyKey: prettyKey,
    formatKeyString: formatKeyString,
    formatBind: formatBind,
    parseShimBinds: parseShimBinds,
    parseHyprctlBinds: parseHyprctlBinds,
    appDescriptionForClass: appDescriptionForClass,
    classify: classify,
    focusHint: focusHint,
    keysForAction: keysForAction,
    beaconSuppresses: beaconSuppresses,
    requiresWorkspaceIntent: requiresWorkspaceIntent,
    workspaceIntentAllows: workspaceIntentAllows,
    categoryFor: categoryFor,
    shouldNotify: shouldNotify,
    recordNotified: recordNotified,
    parseCounts: parseCounts,
    usageSummary: usageSummary,
    unusedBinds: unusedBinds,
    sampleUnused: sampleUnused,
    describeAction: describeAction,
    lessonRows: lessonRows,
    toggleMuted: toggleMuted,
    notificationBody: notificationBody,
    emptyFocus: emptyFocus,
    parseActiveWindow: parseActiveWindow,
    noteFocus: noteFocus,
    ruleMatchesFocus: ruleMatchesFocus,
    compositorOwnsFullscreen: compositorOwnsFullscreen,
    compositorOwnsAction: compositorOwnsAction
  }
}
