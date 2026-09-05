import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "KeyarchyModel.js" as Model

// Keyarchy's bar widget and its popup.
//
// The service does the teaching; this is the window onto it. It reads the same
// three files the service writes -- the shim's bind export, the lesson history,
// and the usage counts -- and writes config back into shell.json the way every
// other bar widget does.
//
// Left click opens the panel, right click toggles Keyarchy off and on.
Panel {
  id: root
  moduleName: "slw.keyarchy"
  ipcTarget: "slw.keyarchy"

  readonly property string home: Quickshell.env("HOME")
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"
  readonly property string stateDir: home + "/.local/state/keyarchy"

  readonly property var config: Model.mergeConfig(settings)
  readonly property bool enabled: config.enabled

  property var binds: ({})
  property var usage: ({})
  property var state: Model.emptyState()
  property int unusedOffset: 0

  readonly property var summary: Model.usageSummary(binds, usage)
  readonly property var unused: Model.unusedBinds(binds, usage)
  readonly property var suggestions: Model.sampleUnused(unused, unusedOffset, 3)
  readonly property var lessons: Model.lessonRows(state, config)

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color barIconColor: enabled ? barForeground : Qt.darker(barForeground, 1.55)

  readonly property string summaryText: summary.total === 0
    ? "waiting for the shim"
    : summary.used + " of " + summary.total + " shortcuts used"

  // Writes one or more keys into this widget's shell.json entry. Applied
  // locally first so the switch moves on the click rather than after the
  // round trip through the config file.
  function writeSettings(patch) {
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    for (var patchKey in patch) entry[patchKey] = patch[patchKey]

    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function toggleEnabled() {
    writeSettings({ enabled: !root.enabled })
  }

  function toggleCategory(name) {
    var categories = ({})
    for (var key in root.config.categories) categories[key] = root.config.categories[key]
    categories[name] = !categories[name]
    writeSettings({ categories: categories })
  }

  function toggleMute(action) {
    writeSettings({ muted: Model.toggleMuted(root.config.muted, action) })
  }

  function showAnother() {
    root.unusedOffset = root.unused.length === 0 ? 0 : (root.unusedOffset + 3) % root.unused.length
  }

  // The service watches this file, so clearing it takes effect immediately
  // rather than waiting for a shell restart.
  function resetProgress() {
    stateFile.setText(JSON.stringify({ version: 2, counts: {}, lastAt: {}, meta: {}, lastAnyAt: 0 }, null, 2) + "\n")
    root.state = Model.emptyState()
  }

  FileView {
    id: bindsFile
    path: root.runtimeDir + "/keyarchy/binds.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.binds = Model.parseShimBinds(text())
    onFileChanged: reload()
  }

  FileView {
    id: usageFile
    path: root.stateDir + "/usage.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.usage = Model.parseCounts(text())
    onFileChanged: reload()
  }

  FileView {
    id: stateFile
    path: root.stateDir + "/state.json"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      var next = Model.emptyState()
      try {
        var parsed = JSON.parse(text() || "{}") || {}
        if (parsed.counts) next.counts = parsed.counts
        if (parsed.lastAt) next.lastAt = parsed.lastAt
        if (parsed.meta) next.meta = parsed.meta
        if (parsed.lastAnyAt) next.lastAnyAt = Number(parsed.lastAnyAt) || 0
      } catch (error) {
        // Nothing to show is the right answer for an unreadable history.
      }
      root.state = next
    }
    onFileChanged: reload()
  }

  // Without these the widget occupies a zero-width slot and renders nothing.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.enabled ? "Keyarchy — " + root.summaryText : "Keyarchy — off"
    iconComponent: Component {
      Item {
        KeyarchyMark {
          anchors.centerIn: parent
          iconSize: Style.space(12)
          color: root.barIconColor
        }
      }
    }

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.toggleEnabled()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(character) {
        if (character === "n" || character === "N") root.showAnother()
        else if (character === "o" || character === "O") root.toggleEnabled()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Keyarchy"
            meta: root.enabled ? root.summaryText : "Off"
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.enabled ? 1.0 : 0.5

            iconComponent: Component {
              KeyarchyMark {
                iconSize: Style.font.display
                color: root.enabled ? root.foreground : root.dim
              }
            }

            trailingControl: Component {
              ToggleSwitch {
                checked: root.enabled
                foreground: root.foreground
                onToggled: root.toggleEnabled()
              }
            }
          }

          // ---------------------------------------------------- never used
          PanelSeparator {
            width: parent.width
            foreground: root.foreground
            visible: root.suggestions.length > 0
          }

          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.suggestions.length > 0

            PanelSectionHeader {
              text: "You never use"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.suggestions
              delegate: ShortcutRow {
                width: column.width
                description: modelData.description
                keys: modelData.keys
              }
            }

            PanelActionButton {
              iconText: "󰑐"
              tooltipText: "Show another (n)"
              foreground: root.dim
              hoverColor: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.showAnother()
            }
          }

          // ----------------------------------------------------- teaching
          PanelSeparator {
            width: parent.width
            foreground: root.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader {
              text: "Teaching"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: [
                { key: "window", label: "Window actions" },
                { key: "workspace", label: "Workspaces" },
                { key: "launch", label: "App launches" },
                { key: "focus", label: "Focus changes" }
              ]

              delegate: Item {
                width: column.width
                implicitHeight: Math.max(categoryLabel.implicitHeight, categorySwitch.implicitHeight)

                Text {
                  id: categoryLabel
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: modelData.label
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                ToggleSwitch {
                  id: categorySwitch
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  checked: root.config.categories[modelData.key] === true
                  foreground: root.foreground
                  onToggled: root.toggleCategory(modelData.key)
                }
              }
            }
          }

          // ---------------------------------------------------- learned
          PanelSeparator {
            width: parent.width
            foreground: root.foreground
            visible: root.lessons.length > 0
          }

          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.lessons.length > 0

            PanelSectionHeader {
              text: "Learned"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.lessons
              delegate: ShortcutRow {
                width: column.width
                description: modelData.description
                keys: modelData.keys
                // A check mark means Keyarchy has stopped bringing this one up.
                trailing: modelData.graduated ? "󰄬" : "×" + modelData.count
                faded: modelData.muted
                actionIcon: modelData.muted ? "󰂛" : "󰂚"
                actionTooltip: modelData.muted ? "Unmute this lesson" : "Mute this lesson"
                onActionClicked: root.toggleMute(modelData.action)
              }
            }
          }

          PanelActionButton {
            iconText: "󰺬"
            tooltipText: "Forget everything and start teaching again"
            visible: root.lessons.length > 0
            foreground: root.dim
            hoverColor: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.resetProgress()
          }
        }
      }
    }
  }
}
