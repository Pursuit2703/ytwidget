import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// One of the mini card's tools: its icon above its name, in an equal share
// of the row. No box of its own (so the row never reads as a second set of
// tabs); only a tool that is on gets the cover colour behind it.
Rectangle {
  id: tile

  property string glyph: ""
  property string label: ""
  property string tip: ""
  property bool on: false
  property bool enabled: true
  property color accent: Color.accent
  property color foreground: Color.foreground

  signal picked()

  Layout.fillWidth: true
  Layout.preferredWidth: Style.space(40) * Layout.horizontalStretchFactor
  Layout.horizontalStretchFactor: 1
  Layout.minimumWidth: Style.space(36)
  Layout.preferredHeight: Style.space(label !== "" ? 52 : 40)
  radius: Style.space(12)
  opacity: enabled ? 1 : 0.4
  color: on ? Qt.rgba(accent.r, accent.g, accent.b, tileArea.containsMouse ? 0.2 : 0.14)
    : (tileArea.containsMouse ? Qt.rgba(foreground.r, foreground.g, foreground.b, 0.06) : "transparent")
  Behavior on color { ColorAnimation { duration: 120 } }

  Accessible.role: Accessible.Button
  Accessible.name: tile.tip

  Column {
    anchors.centerIn: parent
    spacing: Style.space(5)
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: tile.glyph
      textFormat: Text.PlainText
      color: tile.on ? tile.accent : Qt.darker(tile.foreground, 1.08)
      font.family: Style.font.family
      font.pixelSize: Style.font.icon + 3
    }
    Text {
      visible: tile.label !== ""
      anchors.horizontalCenter: parent.horizontalCenter
      text: tile.label
      textFormat: Text.PlainText
      color: tile.on ? tile.accent : Qt.darker(tile.foreground, 1.08)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption - 1
    }
  }

  MouseArea {
    id: tileArea
    anchors.fill: parent
    hoverEnabled: true
    enabled: tile.enabled
    cursorShape: Qt.PointingHandCursor
    onClicked: tile.picked()
  }

  PanelToolTip {
    visible: tile.tip !== "" && tileArea.containsMouse
    text: tile.tip
  }
}
