import QtQuick
import QtQuick.Effects
import qs.Commons

// The album art, enlarged and blurred, fading out downwards. Meant to sit
// behind the top of a card: short (the card sets `height`), dim, and gone
// where the content starts. With no thumbnail it draws nothing.
Item {
  id: root

  property string source: ""
  property real strength: 0.5
  // The colour of whatever this sits on; the blur fades into it.
  property color fadeTo: Color.popups.background

  clip: true
  visible: source !== ""

  Image {
    id: art
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.top: parent.top
    width: parent.width * 1.4
    height: width
    source: root.source
    fillMode: Image.PreserveAspectCrop
    asynchronous: true
    cache: true
    visible: false
    layer.enabled: true
  }

  MultiEffect {
    anchors.fill: art
    source: art
    blurEnabled: true
    blurMax: 48
    blur: 1.0
    saturation: 0.2
    opacity: root.strength
  }

  // Fade into the card's own background. A gradient laid over the blur is
  // plain and robust; masking the blur itself left a hard bottom edge.
  Rectangle {
    anchors.fill: parent
    gradient: Gradient {
      GradientStop { position: 0.0; color: Qt.rgba(root.fadeTo.r, root.fadeTo.g, root.fadeTo.b, 0.0) }
      GradientStop { position: 0.45; color: Qt.rgba(root.fadeTo.r, root.fadeTo.g, root.fadeTo.b, 0.35) }
      GradientStop { position: 1.0; color: root.fadeTo }
    }
  }
}
