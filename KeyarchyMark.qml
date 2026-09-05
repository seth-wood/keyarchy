import QtQuick
import qs.Commons

Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  readonly property real unit: root.iconSize / 24

  Rectangle {
    x: 3 * root.unit
    y: 3 * root.unit
    width: 6 * root.unit
    height: 6 * root.unit
    color: root.color
  }

  Rectangle {
    x: 12 * root.unit
    y: 3 * root.unit
    width: 9 * root.unit
    height: 6 * root.unit
    color: root.color
  }

  Rectangle {
    x: 3 * root.unit
    y: 12 * root.unit
    width: 18 * root.unit
    height: 9 * root.unit
    color: root.color
  }
}
