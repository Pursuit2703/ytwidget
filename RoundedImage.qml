import QtQuick
import QtQuick.Effects

// An image with truly rounded corners. A Rectangle with `radius` and
// `clip: true` only clips to its square bounds, so the picture's corners
// stayed sharp; this masks the image with the rounded shape instead.
Item {
  id: root

  property alias source: img.source
  property real radius: 16
  property int fillMode: Image.PreserveAspectCrop
  readonly property int status: img.status
  // A soft shadow under the picture and a hairline edge, so the art sits
  // on the card instead of being pasted onto it.
  property bool lifted: false

  RectangularShadow {
    visible: root.lifted
    anchors.fill: parent
    anchors.topMargin: Math.round(root.height * 0.06)
    radius: root.radius
    blur: Math.round(root.height * 0.22)
    spread: -Math.round(root.height * 0.04)
    color: Qt.rgba(0, 0, 0, 0.55)
  }

  Image {
    id: img
    anchors.fill: parent
    fillMode: root.fillMode
    asynchronous: true
    visible: false
    layer.enabled: true
  }

  Rectangle {
    id: mask
    anchors.fill: parent
    radius: root.radius
    visible: false
    layer.enabled: true
    layer.smooth: true
  }

  MultiEffect {
    anchors.fill: parent
    source: img
    maskEnabled: true
    maskSource: mask
    // Soft edge on the mask so the rounded corners are antialiased.
    maskThresholdMin: 0.5
    maskSpreadAtMin: 1.0
  }

  Rectangle {
    visible: root.lifted
    anchors.fill: parent
    radius: root.radius
    color: "transparent"
    border.width: 1
    border.color: Qt.rgba(1, 1, 1, 0.10)
  }
}
