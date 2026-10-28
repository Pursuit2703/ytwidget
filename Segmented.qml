import QtQuick
import qs.Commons
import qs.Ui

// A row of equal tabs inside one soft track. `model` is a list of
// { key, label, glyph? }; `current` is the selected key.
Rectangle {
  id: root

  property var model: []
  property string current: ""
  property color foreground: Color.foreground
  property real rowHeight: Style.space(30)

  signal picked(string key)

  implicitHeight: rowHeight + Style.space(6)
  radius: Style.space(12)
  color: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.06)

  Row {
    anchors.fill: parent
    anchors.margins: Style.space(3)
    spacing: Style.space(3)

    Repeater {
      model: root.model
      delegate: Rectangle {
        required property var modelData
        readonly property bool active: modelData.key === root.current
        width: (parent.width - (root.model.length - 1) * parent.spacing) / Math.max(1, root.model.length)
        height: parent.height
        radius: Style.space(9)
        color: active
          ? Style.selectedFillFor(root.foreground, Color.accent)
          : (tab.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent")
        Behavior on color { ColorAnimation { duration: 120 } }

        Row {
          anchors.centerIn: parent
          spacing: Style.space(6)
          Text {
            visible: !!modelData.glyph
            anchors.verticalCenter: parent.verticalCenter
            text: modelData.glyph || ""
            textFormat: Text.PlainText
            font.family: Style.font.family
            font.pixelSize: Style.font.body + 1
            color: active ? Style.selectedStateColor(root.foreground, Color.accent) : Qt.darker(root.foreground, 1.4)
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: modelData.label
            textFormat: Text.PlainText
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            color: active ? Style.selectedStateColor(root.foreground, Color.accent) : Qt.darker(root.foreground, 1.4)
          }
        }

        MouseArea {
          id: tab
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.picked(modelData.key)
        }
      }
    }
  }
}
