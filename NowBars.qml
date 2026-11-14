import QtQuick
import qs.Commons

// Three small bars that bob while something plays, and rest when paused:
// the "this is what's playing" mark used on cards and library rows.
Row {
  id: root

  property color color: Color.accent
  property bool running: true
  property real barHeight: Style.space(12)

  spacing: Style.space(2)
  height: barHeight

  Repeater {
    model: 3
    Rectangle {
      id: bar
      required property int index
      anchors.bottom: parent.bottom
      width: Style.space(3)
      radius: 1
      color: root.color
      property real level: [0.55, 1.0, 0.7][index]
      height: root.barHeight * level
      SequentialAnimation on level {
        running: root.running && root.visible
        loops: Animation.Infinite
        NumberAnimation { to: 0.3; duration: 260 + bar.index * 90; easing.type: Easing.InOutSine }
        NumberAnimation { to: 1.0; duration: 300 + bar.index * 70; easing.type: Easing.InOutSine }
      }
    }
  }
}
