import QtQuick

Item {
  id: root

  property color foreground: "#ffffff"

  readonly property real unit: Math.min(width, height) / 24

  Rectangle {
    x: 3 * root.unit
    y: 3 * root.unit
    width: 6 * root.unit
    height: 6 * root.unit
    color: root.foreground
  }

  Rectangle {
    x: 12 * root.unit
    y: 3 * root.unit
    width: 9 * root.unit
    height: 6 * root.unit
    color: root.foreground
  }

  Rectangle {
    x: 3 * root.unit
    y: 12 * root.unit
    width: 18 * root.unit
    height: 9 * root.unit
    color: root.foreground
  }
}
