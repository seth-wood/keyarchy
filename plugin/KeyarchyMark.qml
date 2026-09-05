import QtQuick
import QtQuick.Effects
import QtQuick.Window

Item {
  id: root

  property color foreground: "#ffffff"

  Image {
    id: markImage
    anchors.fill: parent
    fillMode: Image.PreserveAspectFit
    source: Qt.resolvedUrl("assets/mark.svg")
    sourceSize.width: Math.round(Math.min(width, height) * Screen.devicePixelRatio)
    sourceSize.height: Math.round(Math.min(width, height) * Screen.devicePixelRatio)
    visible: false
    layer.enabled: true
  }

  MultiEffect {
    anchors.fill: markImage
    source: markImage
    colorization: 1.0
    colorizationColor: root.foreground
  }
}
