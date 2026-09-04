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
