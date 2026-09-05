import QtQuick
import qs.Commons
import qs.Ui

// One "action → keystroke" line. Used for both halves of the panel: the
// shortcuts you have never pressed, and the lessons Keyarchy has given you.
//
// The keystroke is the point of the row, so it gets the trailing edge where
// the eye lands, and the description truncates before it does.
Item {
  id: root

  property string description: ""
  property string keys: ""
  property string trailing: ""
  property bool faded: false
  property string actionIcon: ""
  property string actionTooltip: ""

  signal actionClicked()

  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  readonly property color dim: Qt.darker(foreground, 1.55)

  implicitHeight: Math.max(descriptionText.implicitHeight, keysText.implicitHeight, actionButton.height)
  opacity: faded ? 0.45 : 1.0

  Text {
    id: descriptionText
    anchors.left: parent.left
    anchors.right: keysText.left
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    text: root.description
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    elide: Text.ElideRight
  }

  Text {
    id: keysText
    anchors.right: trailingText.visible ? trailingText.left : (actionButton.visible ? actionButton.left : parent.right)
    anchors.rightMargin: trailingText.visible || actionButton.visible ? Style.space(8) : 0
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    text: root.keys
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  Text {
    id: trailingText
    visible: root.trailing !== ""
    anchors.right: actionButton.visible ? actionButton.left : parent.right
    anchors.rightMargin: actionButton.visible ? Style.space(8) : 0
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    text: root.trailing
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  PanelActionButton {
    id: actionButton
    visible: root.actionIcon !== ""
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    iconText: root.actionIcon
    tooltipText: root.actionTooltip
    foreground: root.dim
    hoverColor: root.foreground
    fontFamily: root.fontFamily
    fontSize: Style.font.bodySmall
    onClicked: root.actionClicked()
  }
}
