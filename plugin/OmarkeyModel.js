// Pure logic for Omarkey. No QML imports, so test/model.test.mjs can drive it
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

  for (var key in config) {
    if (key === "categories") continue
    if (overrides[key] !== undefined && overrides[key] !== null) config[key] = overrides[key]
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
  return { counts: {}, lastAt: {}, lastAnyAt: 0 }
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
    return {}
  }

  var binds = {}
  for (var description in raw) {
    var keys = formatKeyString(raw[description])
    if (keys !== "") binds[description] = keys
  }
  return binds
}

function parseHyprctlBinds(text) {
  var list = []
  try {
    list = JSON.parse(String(text || "[]")) || []
  } catch (error) {
    return {}
  }
  if (!Array.isArray(list)) return {}

  var binds = {}
  for (var i = 0; i < list.length; i++) {
    var bind = list[i] || {}
    var description = String(bind.description || "")
    if (description === "" || bind.mouse || String(bind.submap || "") !== "") continue
    if (binds[description]) continue

    var keys = formatBind(bind)
    if (keys !== "") binds[description] = keys
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
// for everything Omarkey has nothing to teach about.
function classify(name, data) {
  var fields = String(data === undefined || data === null ? "" : data).split(",")

  switch (String(name || "")) {
    case "workspacev2":
      var workspace = fields[1] || fields[0] || ""
      if (workspace === "") return null
      return {
        action: "workspace:" + workspace,
        category: "workspace",
        description: "Switch to workspace " + workspace
      }

    case "movewindowv2":
      var target = fields[2] || fields[1] || ""
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
      return {
        action: "toggle-float",
        category: "window",
        description: "Toggle window floating/tiling"
      }

    case "activewindowv2":
      return {
        action: "focus-window",
        category: "focus",
        description: "Focus on left window",
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

function recordNotified(action, now, state) {
  state.counts[action] = (state.counts[action] || 0) + 1
  state.lastAt[action] = now
  state.lastAnyAt = now
  return state
}

function notificationBody(description, keys) {
  return description + "  →  " + keys
}

if (typeof module !== "undefined") {
  module.exports = {
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
    categoryFor: categoryFor,
    shouldNotify: shouldNotify,
    recordNotified: recordNotified,
    notificationBody: notificationBody
  }
}
