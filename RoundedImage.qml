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
}
