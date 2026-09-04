import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "OmarkeyModel.js" as Model

// Omarkey: teaches the keybinding for an action you just did with the mouse.
//
// The Lua shim in ~/.config/hypr/omarkey-shim.lua touches a beacon file every
// time a keybind fires. Any Hyprland event that arrives without a beacon
// alongside it came from somewhere else -- a bar click, the menu, a titlebar --
// and is worth a lesson. Without the shim no beacon ever appears, so this
// service goes quiet rather than nagging on every keystroke.
Item {
  id: root

  // Injected by omarchy-shell's service loader.
  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"
  readonly property string stateDir: home + "/.local/state/omarkey"
  readonly property string statePath: stateDir + "/state.json"
  readonly property string beaconPath: runtimeDir + "/omarkey/last-bind"
  readonly property string bindsPath: runtimeDir + "/omarkey/binds.json"

  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "slw.omarkey"

  // Config rides along in this plugin's shell.json entry, the same way bar
  // widgets carry theirs: { "id": "slw.omarkey", "lifetimeCap": 3 }.
  readonly property var pluginConfig: {
    var config = shell && shell.shellConfig ? shell.shellConfig : null
    if (!config || !Array.isArray(config.plugins)) return ({})

    for (var i = 0; i < config.plugins.length; i++) {
      var entry = config.plugins[i]
      if (entry && String(entry.id) === root.pluginId) return entry
    }
    return ({})
  }
  readonly property var settings: Model.mergeConfig(pluginConfig)

  // Only used when the shim has not written binds.json -- see refreshBinds().
  property bool shimBindsLoaded: false
  property var binds: ({})
  property var state: Model.emptyState()
  property real lastBeaconAt: 0
  property var pending: []

  // A keybind's beacon write and its Hyprland event race each other, so hold
  // judgment briefly and accept a beacon from either side of the event.
  readonly property int verdictDelayMs: 250
  readonly property int beaconLeadMs: 150

  function loadBinds(text) {
    var parsed = Model.parseShimBinds(text)
    var count = 0
    for (var key in parsed) count++
    if (count === 0) return

    root.binds = parsed
    root.shimBindsLoaded = true
  }

  function loadState(text) {
    var next = Model.emptyState()
    try {
      var parsed = JSON.parse(String(text || "{}")) || {}
      if (parsed.counts) next.counts = parsed.counts
      if (parsed.lastAt) next.lastAt = parsed.lastAt
    } catch (error) {
      // A corrupt state file only costs us the nag history; start over.
    }
    root.state = next
  }

  function persistState() {
    stateFile.setText(JSON.stringify({
      version: 1,
      counts: root.state.counts,
      lastAt: root.state.lastAt
    }, null, 2) + "\n")
  }

  function onHyprlandEvent(name, data) {
    var match = Model.classify(name, data)
    if (!match) return
    if (root.settings.categories[match.category] === false) return

    var queue = root.pending.slice()
    queue.push({ match: match, at: Date.now() })
    root.pending = queue
    verdictTimer.start()
  }

  function settleVerdicts() {
    var now = Date.now()
    var remaining = []

    for (var i = 0; i < root.pending.length; i++) {
      var entry = root.pending[i]
      if (now - entry.at < root.verdictDelayMs) {
        remaining.push(entry)
        continue
      }
      // A beacon this close means the keyboard already did it.
      if (root.lastBeaconAt >= entry.at - root.beaconLeadMs) continue

      teach(entry.match, now)
    }

    root.pending = remaining
    if (remaining.length === 0) verdictTimer.stop()
  }

  function teach(match, now) {
    if (!Model.shouldNotify(match.action, now, root.state, root.settings)) return

    var keys = Model.keysForAction(match, root.binds)
    if (!keys) return

    console.log("omarkey teach " + match.action + " -> " + keys)

    notifyProcess.command = [
      "omarchy-notification-send",
      "-u", "low",
      "-g", "󰌌",
      match.description,
      keys
    ]
    notifyProcess.running = true

    Model.recordNotified(match.action, now, root.state)
    persistState()
  }

  // Fallback for a machine where the shim is not installed yet. hyprctl cannot
  // describe the 59 code:NN binds (every workspace shortcut among them), so
  // this is strictly a degraded mode.
  function refreshBinds() {
    if (root.shimBindsLoaded) return
    hyprctlBinds.running = true
  }

  FileView {
    id: bindsFile
    path: root.bindsPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadBinds(text())
    onLoadFailed: root.refreshBinds()
    onFileChanged: reload()
  }

  FileView {
    id: beaconFile
    path: root.beaconPath
    watchChanges: true
    printErrors: false
    onFileChanged: root.lastBeaconAt = Date.now()
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadState(text())
    onLoadFailed: root.loadState("{}")
  }

  Process {
    id: hyprctlBinds
    command: ["hyprctl", "binds", "-j"]
    stdout: StdioCollector {
      onStreamFinished: {
        if (root.shimBindsLoaded) return
        root.binds = Model.parseHyprctlBinds(text)
      }
    }
  }

  Process { id: notifyProcess }

  Process {
    id: ensureStateDir
    command: ["mkdir", "-p", root.stateDir]
  }

  Timer {
    id: verdictTimer
    interval: 50
    repeat: true
    onTriggered: root.settleVerdicts()
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      root.onHyprlandEvent(event.name, event.data)
    }
  }

  Component.onCompleted: {
    ensureStateDir.running = true

    // Quickshell connects the Hyprland event socket lazily, on first use of the
    // singleton's state. A bare Connections block is not "use", so without this
    // touch rawEvent never fires for a headless service.
    var connected = Hyprland.workspaces !== null

    bindsFile.reload()
    stateFile.reload()
    refreshBinds()
    console.log("omarkey service-ready id=" + root.pluginId + " hyprland=" + connected)
  }
}
