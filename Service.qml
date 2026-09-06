import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "KeyarchyModel.js" as Model

// Keyarchy: teaches the keybinding for an action you just did with the mouse.
//
// The Lua shim in ~/.config/hypr/keyarchy-shim.lua touches a beacon file every
// time a keybind fires. Events without a beacon came from somewhere else.
// Workspace switches also need last-workspace-intent, stamped only when a
// workspace-only focus descriptor is dispatched, so focusing a window on
// another workspace does not teach "Switch to workspace N". Without the shim
// both files stay empty, so this service goes quiet rather than nagging.
Item {
  id: root

  // Injected by omarchy-shell's service loader.
  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: home + "/.local/state/keyarchy"

  // "" when XDG_RUNTIME_DIR is not /run/user/<uid>. There is deliberately no
  // /tmp fallback: those three files decide whether Keyarchy stays quiet and
  // what its notifications say, and a path another account can create first
  // is a path another account owns. Without them Keyarchy goes silent, which
  // is the same degraded mode as running without the shim.
  readonly property string runtimeStateDir: Model.runtimeStateDir(Quickshell.env("XDG_RUNTIME_DIR"))

  // Helpers ship next to this file, so they are resolved relative to it
  // rather than found on a PATH another process can prepend to.
  readonly property string fileHelper: Model.localPath(Qt.resolvedUrl("bin/keyarchy-file"))
  readonly property string boundedHelper: Model.localPath(Qt.resolvedUrl("bin/keyarchy-bounded"))

  // Every helper runs with a cleared environment and exactly what it needs,
  // so nothing inherited (PATH, PYTHONPATH, BASH_ENV) decides what runs.
  readonly property var helperEnvironment: ({
    "HOME": root.home,
    "XDG_RUNTIME_DIR": Quickshell.env("XDG_RUNTIME_DIR") || "",
    "PATH": "/usr/bin"
  })

  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "slw.keyarchy"

  // Config rides along in this plugin's shell.json entry. The bar widget and
  // the service share it, so this mirrors the precedence shell.qml's
  // updateEntryInline writes with: the bar layout entry when the widget is on
  // the bar, the top-level plugins[] entry otherwise.
  readonly property var pluginConfig: {
    var config = shell && shell.shellConfig ? shell.shellConfig : null
    if (!config) return ({})

    var sections = ["left", "center", "right"]
    var layout = config.bar && config.bar.layout ? config.bar.layout : null
    for (var s = 0; layout && s < sections.length; s++) {
      var entries = layout[sections[s]]
      if (!Array.isArray(entries)) continue
      for (var i = 0; i < entries.length; i++) {
        if (entries[i] && String(entries[i].id) === root.pluginId) return entries[i]
      }
    }

    if (!Array.isArray(config.plugins)) return ({})
    for (var j = 0; j < config.plugins.length; j++) {
      var entry = config.plugins[j]
      if (entry && String(entry.id) === root.pluginId) return entry
    }
    return ({})
  }
  readonly property var settings: Model.mergeConfig(pluginConfig)

  // Only used when the shim has not written binds.json -- see refreshBinds().
  property bool shimBindsLoaded: false
  property var binds: Model.emptyMap()
  property var state: Model.emptyState()
  property real lastBeaconAt: 0
  property string lastBeaconDescription: ""
  property bool countNextBeacon: false
  property real lastWorkspaceIntentAt: 0
  property string lastWorkspaceIntentAction: ""
  property var pending: []

  // Which bindings you actually press, counted by description. The beacon
  // already names the bind that fired, so this needs nothing extra from the
  // shim -- every activation passes through here anyway.
  property var usage: Model.emptyMap()
  property bool usageDirty: false

  // Last activewindow class/title. fullscreen>>1 carries no address, so this
  // is how we recognize compositor windowrules (screensaver, etc.).
  // Named focusIdentity: Item.focus is FINAL and cannot be overridden.
  property var focusIdentity: ({ className: "", title: "" })

  // A keybind's beacon write and its Hyprland event race each other, so hold
  // judgment briefly and accept a beacon from either side of the event.
  // Description matching covers delayed events (app windows mapping late).
  readonly property int verdictDelayMs: 250
  readonly property int beaconLeadMs: 150
  readonly property int beaconMatchMs: 5000
  readonly property int intentLeadMs: 150
  readonly property int intentMatchMs: 5000

  function loadBinds(text) {
    var parsed = Model.parseShimBinds(text)
    var count = 0
    for (var key in parsed) count++
    if (count === 0) return

    root.binds = parsed
    root.shimBindsLoaded = true
    console.log("keyarchy binds-loaded count=" + count)
  }

  function loadUsage(text) {
    root.usage = Model.parseCounts(text)
  }

  // A refused read is not an empty file. Keeping what is already in memory
  // means a planted symlink or an oversized state file costs a refresh, not
  // the lesson history.
  function readRefused(what) {
    console.warn("keyarchy: refused to read " + what)
  }

  // Remember what the keyboard just claimed, for suppression. Counting usage
  // is separate so a shell restart does not re-tally the leftover beacon file.
  function noteBeacon(text) {
    var description = Model.plainLabel(String(text || "").split("\n")[0])
    root.lastBeaconDescription = description
    return description
  }

  function noteWorkspaceIntent(text) {
    var action = Model.plainLabel(String(text || "").split("\n")[0])
    root.lastWorkspaceIntentAction = action
    return action
  }

  function countUsage(description) {
    if (description === "") return

    root.usage = Model.countUsage(root.usage, description)
    root.usageDirty = true
    usagePersistTimer.restart()
  }

  // Debounced: a fast typist can fire several binds a second, and this is a
  // real disk write rather than the shim's tmpfs one.
  function persistUsage() {
    if (!root.usageDirty) return
    root.usageDirty = false
    usageFile.write(JSON.stringify(root.usage, null, 2) + "\n")
  }

  function loadState(text) {
    root.state = Model.parseState(text)
  }

  function persistState() {
    stateFile.write(JSON.stringify(Model.serializeState(root.state), null, 2) + "\n")
  }

  function onHyprlandEvent(name, data) {
    root.focusIdentity = Model.noteFocus(root.focusIdentity, name, data)

    var match = Model.classify(name, data)
    if (!match) return
    if (root.settings.categories[match.category] === false) return
    if (Model.compositorOwnsAction(match, root.focusIdentity)) return

    var queue = root.pending.slice()
    queue.push({ match: match, at: Date.now() })
    root.pending = queue
    verdictTimer.start()
  }

  function settleVerdicts() {
    var now = Date.now()
    var remaining = []
    var beaconOpts = { beaconLeadMs: root.beaconLeadMs, beaconMatchMs: root.beaconMatchMs }
    var intentOpts = { intentLeadMs: root.intentLeadMs, intentMatchMs: root.intentMatchMs }

    for (var i = 0; i < root.pending.length; i++) {
      var entry = root.pending[i]
      if (now - entry.at < root.verdictDelayMs) {
        remaining.push(entry)
        continue
      }
      // A recent beacon for this action means the keyboard already did it.
      if (Model.beaconSuppresses(
        entry.match, root.lastBeaconAt, root.lastBeaconDescription,
        entry.at, now, beaconOpts
      )) continue
      if (!Model.workspaceIntentAllows(
        entry.match, root.lastWorkspaceIntentAt, root.lastWorkspaceIntentAction,
        entry.at, now, intentOpts
      )) continue

      teach(entry.match, now)
    }

    root.pending = remaining
    if (remaining.length === 0) verdictTimer.stop()
  }

  function teach(match, now) {
    if (!Model.shouldNotify(match.action, now, root.state, root.settings)) return

    var keys = Model.keysForAction(match, root.binds)
    if (!keys) {
      // Worth saying out loud: this is the difference between "Keyarchy is
      // quiet because you used the keyboard" and "Keyarchy has no idea what
      // the shortcut is", and they look identical from outside.
      console.warn("keyarchy: no bind known for " + match.action + " (" + match.description + ")")
      return
    }

    // Both of these came from outside: the description carries a workspace
    // name any client can set, and the keys come out of the shim's export.
    // The notification daemon renders summary and body with components this
    // plugin cannot pin to PlainText, so markup and controls come out here,
    // and notifyArgument keeps a dash-leading value out of option position --
    // omarchy-notification-send parses options on both sides of the headline
    // and has no "--" to stop it.
    var summary = Model.notifyArgument(match.description)
    var body = Model.notifyArgument(keys)
    if (summary === "") return

    console.log("keyarchy teach " + match.action)

    notifyProcess.command = [
      "/usr/bin/omarchy-notification-send",
      "-u", "low",
      "-g", "󰌌",
      summary,
      body
    ]
    notifyProcess.running = true
    notifyDeadline.restart()

    Model.recordNotified(match.action, now, root.state, match, keys)
    persistState()
  }

  // Fallback for a machine where the shim is not installed yet. hyprctl cannot
  // describe the 59 code:NN binds (every workspace shortcut among them), so
  // this is strictly a degraded mode.
  function refreshBinds() {
    if (root.shimBindsLoaded) return
    hyprctlBinds.running = true
  }

  // Every one of these is a file some other process writes, so none of them
  // is read by the shell process itself -- see BoundedFile.qml.
  BoundedFile {
    id: bindsFile
    helper: root.fileHelper
    environment: root.helperEnvironment
    rootName: "runtime"
    fileName: "binds.json"
    active: root.runtimeStateDir !== ""
    watchPath: root.runtimeStateDir === "" ? "" : root.runtimeStateDir + "/binds.json"
    onLoaded: function(text) {
      if (text === "") root.refreshBinds()
      else root.loadBinds(text)
    }
    onFailed: root.readRefused("binds.json")
  }

  BoundedFile {
    id: beaconFile
    helper: root.fileHelper
    environment: root.helperEnvironment
    rootName: "runtime"
    fileName: "last-bind"
    active: root.runtimeStateDir !== ""
    watchPath: root.runtimeStateDir === "" ? "" : root.runtimeStateDir + "/last-bind"
    // Timestamp on the watch event, not on the read: suppression is a race
    // against the Hyprland event and must not wait for a helper to start.
    onWatchFired: {
      root.lastBeaconAt = Date.now()
      root.countNextBeacon = true
    }
    onLoaded: function(text) {
      var description = root.noteBeacon(text)
      // Only tally activations that triggered a watch event -- not the
      // leftover file read on service start.
      if (root.countNextBeacon) {
        root.countNextBeacon = false
        root.countUsage(description)
      }
    }
    onFailed: root.readRefused("last-bind")
  }

  BoundedFile {
    id: workspaceIntentFile
    helper: root.fileHelper
    environment: root.helperEnvironment
    rootName: "runtime"
    fileName: "last-workspace-intent"
    active: root.runtimeStateDir !== ""
    watchPath: root.runtimeStateDir === "" ? "" : root.runtimeStateDir + "/last-workspace-intent"
    onWatchFired: root.lastWorkspaceIntentAt = Date.now()
    onLoaded: function(text) { root.noteWorkspaceIntent(text) }
    onFailed: root.readRefused("last-workspace-intent")
  }

  BoundedFile {
    id: usageFile
    helper: root.fileHelper
    environment: root.helperEnvironment
    rootName: "state"
    fileName: "usage.json"
    onLoaded: function(text) { root.loadUsage(text) }
    onFailed: root.readRefused("usage.json")
  }

  Timer {
    id: usagePersistTimer
    interval: 5000
    repeat: false
    onTriggered: root.persistUsage()
  }

  BoundedFile {
    id: stateFile
    helper: root.fileHelper
    environment: root.helperEnvironment
    rootName: "state"
    fileName: "state.json"
    // The panel resets progress by rewriting this file; pick that up live
    // instead of holding stale counts until the next shell restart.
    watchPath: root.stateDir + "/state.json"
    onLoaded: function(text) { root.loadState(text) }
    onFailed: root.readRefused("state.json")
  }

  // Degraded-mode fallback, and the only command Keyarchy runs. It goes
  // through keyarchy-bounded, which caps the output at the producer and kills
  // the whole process group on the deadline -- hyprctl's output is not large
  // today, but it is not this plugin's to promise.
  Process {
    id: hyprctlBinds
    command: ["/usr/bin/bash", root.boundedHelper, "/usr/bin/hyprctl", "binds", "-j"]
    clearEnvironment: true
    environment: root.helperEnvironment

    property string buffer: ""

    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        if (hyprctlBinds.buffer.length + chunk.length > 262144) {
          hyprctlBinds.buffer = ""
          hyprctlBinds.signal(15)
          return
        }
        hyprctlBinds.buffer += chunk
      }
    }

    onExited: function(code, status) {
      var text = hyprctlBinds.buffer
      hyprctlBinds.buffer = ""
      if (code !== 0 || root.shimBindsLoaded) return
      root.binds = Model.parseHyprctlBinds(text)
    }
  }

  Process { id: notifyProcess }

  Timer {
    id: notifyDeadline
    interval: 5000
    onTriggered: if (notifyProcess.running) notifyProcess.signal(9)
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
    // Quickshell connects the Hyprland event socket lazily, on first use of the
    // singleton's state. A bare Connections block is not "use", so without this
    // touch rawEvent never fires for a headless service.
    var connected = Hyprland.workspaces !== null

    if (root.runtimeStateDir === "") {
      console.warn("keyarchy: XDG_RUNTIME_DIR is not /run/user/<uid>; staying silent")
    }

    bindsFile.reload()
    stateFile.reload()
    usageFile.reload()
    if (root.runtimeStateDir === "") refreshBinds()
    console.log("keyarchy service-ready id=" + root.pluginId + " hyprland=" + connected)
  }

  // The shell outlives any one plugin, so nothing Keyarchy started may outlive
  // Keyarchy.
  Component.onDestruction: {
    if (hyprctlBinds.running) hyprctlBinds.signal(9)
    if (notifyProcess.running) notifyProcess.signal(9)
  }
}
