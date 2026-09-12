import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: root

  property var levels: []
  // Labels are only drawn when they line up with the band count the backend
  // actually sends; the bar visualiser's band layout is free to change.
  property var labels: []
  property color foreground: Color.foreground
  property color accent: Color.accent
  property bool compact: false
  property bool showLabels: true

  readonly property int bandCount: Math.max(1, root.levels ? root.levels.length : 10)
  readonly property real labelHeight: root.showLabels
    ? (root.compact ? Style.space(12) : Style.space(14)) : 0
  readonly property real rowSpacing: root.compact ? Style.space(3) : Style.space(5)
  readonly property real minBandWidth: root.compact ? Style.space(18) : Style.space(22)
  readonly property real bandWidth: {
    var inner = Math.max(0, width - root.rowSpacing * (root.bandCount - 1))
    return Math.max(root.minBandWidth, inner / root.bandCount)
  }
  readonly property color lowColor: Qt.rgba(0.22, 0.90, 0.28, 1)
  readonly property color midColor: Qt.rgba(0.95, 0.86, 0.16, 1)
  readonly property color highColor: Qt.rgba(0.92, 0.24, 0.18, 1)

  implicitHeight: root.compact ? Style.space(52) : Style.space(68)
  implicitWidth: root.minBandWidth * root.bandCount + root.rowSpacing * (root.bandCount - 1)
  Accessible.role: Accessible.Chart
  Accessible.name: "Realtime spectrum"

  function levelAt(index) {
    if (!root.levels || index < 0 || index >= root.levels.length) return 0
    var value = Number(root.levels[index])
    if (!isFinite(value)) return 0
    return Math.max(0, Math.min(1, value))
  }

  Row {
    id: row
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    spacing: root.rowSpacing

    Repeater {
      model: root.bandCount
      delegate: Item {
        required property int index
        width: root.bandWidth
        height: root.compact ? Style.space(48) : Style.space(62)
        readonly property real level: root.levelAt(index)

        Rectangle {
          id: track
          anchors.top: parent.top
          anchors.horizontalCenter: parent.horizontalCenter
          width: parent.width - Style.space(2)
          height: parent.height - root.labelHeight - (root.showLabels ? Style.space(3) : 0)
          radius: Style.space(3)
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
          readonly property real innerHeight: Math.max(1, height - Style.space(2))

          Item {
            id: fillClip
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: Style.space(1)
            height: Math.max(Style.space(3), track.innerHeight * level)
            clip: true

            // Levels arrive in discrete frames (~43Hz), so binding the height
            // straight to them makes the bars step. Interpolating between
            // frames turns that into continuous motion; kept shorter than the
            // frame interval's reach so it smooths without trailing the audio.
            Behavior on height {
              NumberAnimation { duration: 60; easing.type: Easing.OutQuad }
            }

            Rectangle {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              height: track.innerHeight * 0.33
              color: root.lowColor
            }
            Rectangle {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              anchors.bottomMargin: track.innerHeight * 0.33
              height: track.innerHeight * 0.33
              color: root.midColor
            }
            Rectangle {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              anchors.bottomMargin: track.innerHeight * 0.66
              height: track.innerHeight * 0.34
              color: root.highColor
            }
          }
        }

        Text {
          visible: root.showLabels && index < root.labels.length
          anchors.bottom: parent.bottom
          anchors.horizontalCenter: parent.horizontalCenter
          width: parent.width
          height: root.labelHeight
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
          text: index < root.labels.length ? String(root.labels[index]) : ""
          color: Qt.darker(root.foreground, 1.35)
          font.family: Style.font.family
          font.pixelSize: root.compact ? Style.font.caption : Style.font.bodySmall
          elide: Text.ElideRight
        }
      }
    }
  }
}
