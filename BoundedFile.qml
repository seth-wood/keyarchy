import QtQuick
import Quickshell
import Quickshell.Io

// One file that some other process writes, read the only way Keyarchy trusts.
//
// The FileView here is a watcher and nothing else: preload is off and text()
// is never called, so binding the path sets up the inotify watch without ever
// opening the file through the shell process. Every byte instead comes from
// bin/keyarchy-file, which opens the path once with O_NOFOLLOW|O_NONBLOCK,
// checks the descriptor it actually got, and reads at most maxBytes + 1 so an
// oversized file is refused rather than truncated into shape.
//
// That matters because all five of these files are writable by other processes
// running as the same user. A symlink on the name would redirect a plain read;
// a FIFO on the name would hang omarchy-shell, which hosts every widget on the
// desktop.
Item {
  id: root

  // Absolute path to bin/keyarchy-file.
  property string helper: ""
  // "state" or "runtime" -- which directory chain the helper walks.
  property string rootName: ""
  property string fileName: ""
  // Absolute path, watched for changes. Empty leaves this file unwatched.
  property string watchPath: ""
  property var environment: ({})
  property int maxBytes: 65536
  property int deadlineMs: 5000

  // Set false to make this file inert -- used for the runtime files when
  // there is no acceptable runtime directory to read them from. Named
  // "active" rather than "enabled" so it does not shadow Item.enabled.
  property bool active: true

  readonly property bool ready: active && helper !== "" && rootName !== "" && fileName !== ""

  // Emitted only for a read that succeeded. An absent file is a successful
  // read of nothing; a refused one is failed(), so a caller never mistakes
  // "this file was rejected" for "this file is empty, start over".
  signal loaded(string text)
  signal failed()
  // Emitted the moment the watch fires, before the read starts. Keyarchy's
  // beacon suppression is a race against a Hyprland event, so it needs the
  // timestamp of the change rather than the timestamp of the read.
  signal watchFired()

  property string _buf: ""
  property bool _overflow: false
  property bool _rereadQueued: false
  property string _payload: ""
  property bool _rewriteQueued: false

  function reload() {
    if (!ready) return
    if (reader.running) { root._rereadQueued = true; return }
    root._buf = ""
    root._overflow = false
    reader.running = true
    readDeadline.restart()
  }

  // Last write wins: a queued payload replaces any earlier one rather than
  // stacking up a backlog of writes of stale state.
  function write(text) {
    if (!ready) return
    root._payload = text
    if (writer.running) { root._rewriteQueued = true; return }
    writer.running = true
  }

  FileView {
    id: watcher
    path: root.watchPath
    preload: false
    watchChanges: root.watchPath !== ""
    printErrors: false
    onFileChanged: {
      root.watchFired()
      root.reload()
    }
  }

  Process {
    id: reader
    command: ["/usr/bin/python3", "-I", "-S", root.helper, "read", root.rootName, root.fileName]
    clearEnvironment: true
    environment: root.environment

    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        // The byte ceiling lives in the helper; length here counts UTF-16
        // units, so this is a second line rather than the first one.
        if (root._buf.length + chunk.length > root.maxBytes) {
          root._overflow = true
          reader.signal(15)
          readKill.restart()
          return
        }
        root._buf += chunk
      }
    }

    onExited: function(code, status) {
      readDeadline.stop()
      readKill.stop()
      var text = root._buf
      var overflowed = root._overflow
      root._buf = ""
      root._overflow = false

      if (code === 0 && !overflowed) root.loaded(text)
      else root.failed()

      if (root._rereadQueued) {
        root._rereadQueued = false
        root.reload()
      }
    }
  }

  Process {
    id: writer
    command: ["/usr/bin/python3", "-I", "-S", root.helper, "write", root.rootName, root.fileName]
    clearEnvironment: true
    environment: root.environment
    stdinEnabled: true

    onStarted: {
      writer.write(root._payload)
      // Closing stdin is what ends the helper's read; without it the deadline
      // below would be doing the work instead.
      writer.stdinEnabled = false
      writeDeadline.restart()
    }

    onExited: function(code, status) {
      writeDeadline.stop()
      writeKill.stop()
      writer.stdinEnabled = true
      if (root._rewriteQueued) {
        root._rewriteQueued = false
        writer.running = true
      }
    }
  }

  // TERM, a short grace, then KILL -- for both the deadline and an overflow.
  Timer {
    id: readDeadline
    interval: root.deadlineMs
    onTriggered: { reader.signal(15); readKill.restart() }
  }
  Timer {
    id: readKill
    interval: 2000
    onTriggered: reader.signal(9)
  }
  Timer {
    id: writeDeadline
    interval: root.deadlineMs
    onTriggered: { writer.signal(15); writeKill.restart() }
  }
  Timer {
    id: writeKill
    interval: 2000
    onTriggered: writer.signal(9)
  }

  Component.onDestruction: {
    if (reader.running) reader.signal(9)
    if (writer.running) writer.signal(9)
  }
}
