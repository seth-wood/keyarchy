import { test } from "node:test"
import assert from "node:assert/strict"
import { createRequire } from "node:module"

const require = createRequire(import.meta.url)
const Model = require("../plugin/OmarkeyModel.js")

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
})

test("stays quiet for events with nothing to teach", () => {
  assert.equal(Model.classify("fullscreen", "0"), null)
  assert.equal(Model.classify("openwindow", "0x55,3,SomeUnboundApp,x"), null)
  assert.equal(Model.classify("monitoradded", "DP-1"), null)
  assert.equal(Model.classify("workspacev2", ""), null)
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
