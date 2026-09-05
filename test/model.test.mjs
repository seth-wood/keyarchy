import { test } from "node:test"
import assert from "node:assert/strict"
import { createRequire } from "node:module"

const require = createRequire(import.meta.url)
const Model = require("../KeyarchyModel.js")

test("renders code:NN binds as the digit they produce", () => {
  assert.equal(Model.formatKeyString("SUPER + code:12"), "SUPER + 3")
  assert.equal(Model.formatKeyString("SUPER + SHIFT + code:19"), "SUPER + SHIFT + 0")
  assert.equal(Model.formatKeyString("SUPER + W"), "SUPER + W")
  assert.equal(Model.formatKeyString("SUPER + LEFT"), "SUPER + ←")
})

test("parses the shim's bind export, keeping the first key for a description", () => {
  const binds = Model.parseShimBinds(JSON.stringify({
    "Switch to workspace 3": "SUPER + code:12",
    "Close window": "SUPER + W"
  }))
  assert.equal(binds["Switch to workspace 3"], "SUPER + 3")
  assert.equal(binds["Close window"], "SUPER + W")
})

test("survives a corrupt binds file", () => {
  assert.deepEqual(Model.parseShimBinds("{not json"), {})
  assert.deepEqual(Model.parseHyprctlBinds("nope"), {})
})

test("hyprctl fallback drops binds it cannot describe", () => {
  const binds = Model.parseHyprctlBinds(JSON.stringify([
    { description: "Close window", modmask: 64, key: "W", keycode: 0 },
    // What hyprctl really reports for `SUPER + code:12`.
    { description: "Switch to workspace 3", modmask: 64, key: "", keycode: 0 },
    { description: "Move window", modmask: 64, key: "mouse:272", mouse: true }
  ]))
  assert.equal(binds["Close window"], "SUPER + W")
  assert.equal(binds["Switch to workspace 3"], undefined)
  assert.equal(binds["Move window"], undefined)
})

test("classifies the teachable Hyprland events", () => {
  assert.deepEqual(Model.classify("workspacev2", "3,3"), {
    action: "workspace:3", category: "workspace", description: "Switch to workspace 3"
  })
  assert.deepEqual(Model.classify("movewindowv2", "0x55,2,2"), {
    action: "move-to-workspace:2", category: "workspace", description: "Move window to workspace 2"
  })
  assert.equal(Model.classify("closewindow", "0x55").description, "Close window")
  assert.equal(Model.classify("changefloatingmode", "0x55,1").description, "Toggle window floating/tiling")
  assert.equal(Model.classify("openwindow", "0x55,3,Alacritty,zsh").description, "Terminal")
  assert.equal(Model.classify("activewindowv2", "0x55").description, "Focus another window")
})

test("stays quiet for events with nothing to teach", () => {
  assert.equal(Model.classify("fullscreen", "0"), null)
  assert.equal(Model.classify("changefloatingmode", "0x55,0"), null)
  assert.equal(Model.classify("openwindow", "0x55,3,SomeUnboundApp,x"), null)
  assert.equal(Model.classify("monitoradded", "DP-1"), null)
  assert.equal(Model.classify("workspacev2", ""), null)
})

function replayCompositorGate(events) {
  let focus = Model.emptyFocus()
  const queued = []
  for (const [name, data] of events) {
    focus = Model.noteFocus(focus, name, data)
    const match = Model.classify(name, data)
    if (!match) continue
    if (Model.compositorOwnsAction(match, focus)) continue
    queued.push(match.action)
  }
  return { focus, queued }
}

test("does not teach fullscreen for the Omarchy screensaver windowrule", () => {
  assert.equal(Model.classify("fullscreen", "1").action, "fullscreen")

  const { focus, queued } = replayCompositorGate([
    ["openwindow", "0x1,1,org.omarchy.screensaver,foot"],
    ["activewindow", "org.omarchy.screensaver,foot"],
    ["activewindowv2", "0x1"],
    ["fullscreen", "1"]
  ])

  assert.equal(focus.className, "org.omarchy.screensaver")
  assert.equal(focus.title, "foot")
  assert.ok(!queued.includes("fullscreen"))
})

test("still teaches fullscreen for an ordinary focused window", () => {
  const match = Model.classify("fullscreen", "1")
  const focus = { className: "Alacritty", title: "zsh" }
  assert.equal(Model.compositorOwnsAction(match, focus), false)
})

test("still teaches fullscreen when an ordinary window maps then goes fullscreen", () => {
  const { queued } = replayCompositorGate([
    ["openwindow", "0x2,1,Alacritty,zsh"],
    ["activewindow", "Alacritty,zsh"],
    ["activewindowv2", "0x2"],
    ["fullscreen", "1"]
  ])
  assert.ok(queued.includes("fullscreen"))
})

test("treats other Omarchy auto-fullscreen windowrules as compositor-owned", () => {
  const match = Model.classify("fullscreen", "1")
  assert.equal(
    Model.compositorOwnsAction(match, { className: "com.moonlight_stream.Moonlight", title: "" }),
    true
  )
  assert.equal(
    Model.compositorOwnsAction(match, { className: "com.libretro.RetroArch", title: "" }),
    true
  )
  assert.equal(
    Model.compositorOwnsAction(match, {
      className: "resolve",
      title: "DaVinci Resolve - Untitled Project"
    }),
    true
  )
  assert.equal(
    Model.compositorOwnsAction(match, { className: "resolve", title: "Project Manager" }),
    false
  )
})

test("noteFocus only learns identity from activewindow", () => {
  let focus = Model.emptyFocus()
  focus = Model.noteFocus(focus, "openwindow", "0x1,1,org.omarchy.screensaver,foot")
  assert.equal(focus.className, "")
  focus = Model.noteFocus(focus, "activewindowv2", "0x1")
  assert.equal(focus.className, "")
  focus = Model.noteFocus(focus, "activewindow", "org.omarchy.screensaver,foot")
  assert.equal(focus.className, "org.omarchy.screensaver")
  assert.equal(focus.title, "foot")
})

test("fails open when focus identity is unknown", () => {
  const match = Model.classify("fullscreen", "1")
  assert.equal(Model.compositorOwnsAction(match, Model.emptyFocus()), false)
})

test("collapses the four directional focus binds into one hint", () => {
  const binds = {
    "Focus on left window": "SUPER + ←",
    "Focus on right window": "SUPER + →",
    "Focus on above window": "SUPER + ↑",
    "Focus on below window": "SUPER + ↓"
  }
  assert.equal(Model.focusHint(binds), "SUPER + ← → ↑ ↓")
  // One missing direction means no honest hint to give.
  delete binds["Focus on above window"]
  assert.equal(Model.focusHint(binds), null)
})

test("suppresses delayed openwindow when the beacon named that launch", () => {
  const match = { description: "Browser", category: "launch", action: "launch:Browser" }
  // Beacon at t=0, window maps 2s later — outside the lead window, inside match window.
  assert.equal(Model.beaconSuppresses(match, 1000, "Browser", 3000, 3250, {}), true)
  assert.equal(Model.beaconSuppresses(match, 1000, "Terminal", 3000, 3250, {}), false)
  assert.equal(Model.beaconSuppresses(match, 1000, "Browser", 3000, 8000, {}), false)
})

test("suppresses near-synchronous events by beacon timing alone", () => {
  const match = { description: "Close window", action: "close-window" }
  assert.equal(Model.beaconSuppresses(match, 1000, "Close window", 1050, 1300, {}), true)
  // Beacon long before the event and for a different action: do not suppress.
  assert.equal(Model.beaconSuppresses(match, 1000, "Full screen", 3000, 3250, {}), false)
})

test("suppresses directional focus beacons against the collapsed focus lesson", () => {
  const match = { description: "Focus another window", hint: "arrows", action: "focus-window" }
  assert.equal(Model.beaconSuppresses(match, 1000, "Focus on left window", 2000, 2250, {}), true)
  assert.equal(Model.beaconSuppresses(match, 1000, "Close window", 2000, 2250, {}), false)
})

test("rate limits repeats of the same action", () => {
  const config = Model.mergeConfig({ globalGapMs: 0 })
  const state = Model.emptyState()

  assert.equal(Model.shouldNotify("close-window", 1000, state, config), true)
  Model.recordNotified("close-window", 1000, state)
  assert.equal(Model.shouldNotify("close-window", 2000, state, config), false)
  assert.equal(Model.shouldNotify("close-window", 1000 + config.cooldownMs, state, config), true)
})

test("gives up on an action after the lifetime cap", () => {
  const config = Model.mergeConfig({ globalGapMs: 0, lifetimeCap: 2 })
  const state = Model.emptyState()
  let now = 0

  for (let i = 0; i < 2; i++) {
    assert.equal(Model.shouldNotify("fullscreen", now, state, config), true)
    Model.recordNotified("fullscreen", now, state)
    now += config.cooldownMs
  }
  assert.equal(Model.shouldNotify("fullscreen", now, state, config), false)
})

test("holds a global gap so a burst yields one notification", () => {
  const config = Model.mergeConfig({})
  const state = Model.emptyState()

  const base = Date.now()
  Model.recordNotified("workspace:1", base, state)
  assert.equal(Model.shouldNotify("workspace:2", base + 100, state, config), false)
  assert.equal(Model.shouldNotify("workspace:2", base + config.globalGapMs, state, config), true)
})

test("respects disabled categories and muted actions", () => {
  const state = Model.emptyState()
  assert.equal(
    Model.shouldNotify("focus-window", 0, state, Model.mergeConfig({})),
    false,
    "focus is off by default"
  )
  assert.equal(
    Model.shouldNotify("focus-window", 0, state, Model.mergeConfig({ categories: { focus: true } })),
    true
  )
  assert.equal(
    Model.shouldNotify("close-window", 0, state, Model.mergeConfig({ muted: ["close-window"] })),
    false
  )
})

test("merging config keeps untouched defaults", () => {
  const config = Model.mergeConfig({ lifetimeCap: 1, categories: { launch: false } })
  assert.equal(config.lifetimeCap, 1)
  assert.equal(config.categories.launch, false)
  assert.equal(config.categories.window, true)
  assert.equal(config.cooldownMs, Model.defaultConfig().cooldownMs)
})

test("merging config ignores a non-array muted value", () => {
  const config = Model.mergeConfig({ muted: "close-window" })
  assert.deepEqual(config.muted, [])
  assert.deepEqual(Model.mergeConfig({ muted: ["close-window"] }).muted, ["close-window"])
})

test("summarises how much of your keymap you actually reach for", () => {
  const binds = { "Close window": "SUPER + W", "Toggle scratchpad": "SUPER + S", "Full screen": "SUPER + F" }
  assert.deepEqual(Model.usageSummary(binds, { "Close window": 4 }), { used: 1, total: 3 })
  assert.deepEqual(Model.usageSummary(binds, {}), { used: 0, total: 3 })
  assert.deepEqual(Model.usageSummary({}, {}), { used: 0, total: 0 })
})

test("lists never-triggered bindings in stable order", () => {
  const binds = { "Close window": "SUPER + W", "Toggle scratchpad": "SUPER + S", "Full screen": "SUPER + F" }
  const unused = Model.unusedBinds(binds, { "Close window": 1 })
  assert.deepEqual(unused.map((b) => b.description), ["Full screen", "Toggle scratchpad"])
})

test("'show another' walks the list instead of repeating", () => {
  const list = [{ description: "a" }, { description: "b" }, { description: "c" }]
  assert.deepEqual(Model.sampleUnused(list, 0, 2).map((x) => x.description), ["a", "b"])
  assert.deepEqual(Model.sampleUnused(list, 2, 2).map((x) => x.description), ["c", "a"])
  assert.deepEqual(Model.sampleUnused([], 0, 3), [])
  // Asking for more than exists must not repeat entries.
  assert.equal(Model.sampleUnused(list, 0, 9).length, 3)
})

test("builds lesson rows newest first, marking graduated and muted ones", () => {
  const config = Model.mergeConfig({ lifetimeCap: 3, muted: ["fullscreen"] })
  const state = Model.emptyState()
  const base = Date.now()

  state.counts = { "close-window": 3, "fullscreen": 1 }
  state.lastAt = { "close-window": base, "fullscreen": base + 100 }
  state.meta = {
    "close-window": { description: "Close window", keys: "SUPER + W" },
    "fullscreen": { description: "Full screen", keys: "SUPER + F" }
  }

  const rows = Model.lessonRows(state, config)
  assert.deepEqual(rows.map((r) => r.action), ["fullscreen", "close-window"])
  assert.equal(rows[1].graduated, true)
  assert.equal(rows[0].graduated, false)
  assert.equal(rows[0].muted, true)
  assert.equal(rows[1].keys, "SUPER + W")
})

test("a lesson row stays readable when metadata is missing", () => {
  const state = Model.emptyState()
  state.counts = { "workspace:5": 1, "close-window": 1, "launch:Browser": 1 }
  state.lastAt = { "workspace:5": 3, "close-window": 2, "launch:Browser": 1 }
  const rows = Model.lessonRows(state, Model.mergeConfig({}))
  assert.deepEqual(rows.map((r) => r.description), ["Switch to workspace 5", "Close window", "Browser"])
  assert.equal(rows[0].keys, "")
})

test("describeAction leaves an unknown action alone", () => {
  assert.equal(Model.describeAction("something-new"), "something-new")
  assert.equal(Model.describeAction(""), "")
})

test("recordNotified stores what the panel needs to render the row", () => {
  const state = Model.emptyState()
  Model.recordNotified("close-window", 5, state, { description: "Close window" }, "SUPER + W")
  assert.deepEqual(state.meta["close-window"], { description: "Close window", keys: "SUPER + W" })
  assert.equal(state.counts["close-window"], 1)
})

test("muting toggles both ways", () => {
  assert.deepEqual(Model.toggleMuted([], "fullscreen"), ["fullscreen"])
  assert.deepEqual(Model.toggleMuted(["fullscreen", "close-window"], "fullscreen"), ["close-window"])
})

test("parseCounts survives junk", () => {
  assert.deepEqual(Model.parseCounts('{"a":1}'), { a: 1 })
  assert.deepEqual(Model.parseCounts("nope"), {})
  assert.deepEqual(Model.parseCounts(""), {})
})

test("requiresWorkspaceIntent only for workspace:N, never move-to-workspace", () => {
  assert.equal(Model.requiresWorkspaceIntent({ action: "workspace:3" }), true)
  assert.equal(Model.requiresWorkspaceIntent({ action: "move-to-workspace:2" }), false)
  assert.equal(Model.requiresWorkspaceIntent({ action: "close-window" }), false)
})

test("workspaceIntentAllows fail-closes workspace teaches without a fresh matching intent", () => {
  const match = { action: "workspace:3", category: "workspace", description: "Switch to workspace 3" }
  assert.equal(Model.workspaceIntentAllows(match, 0, "", 1000, 1250, {}), false)
  assert.equal(Model.workspaceIntentAllows(match, 1000, "workspace:3", 1050, 1300, {}), true)
  assert.equal(Model.workspaceIntentAllows(match, 1000, "workspace:2", 1050, 1300, {}), false)
  assert.equal(Model.workspaceIntentAllows(
    { action: "move-to-workspace:2", category: "workspace", description: "Move window to workspace 2" },
    0, "", 1000, 1250, {}
  ), true)
})
