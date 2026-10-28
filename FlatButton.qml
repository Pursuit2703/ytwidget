import QtQuick
import qs.Commons
import qs.Ui

// A flat icon button: no outline, a soft fill on hover and when selected.
// `primary` draws the filled disc used for play/pause. The glyph sits in a
// box of the button's own size, centred on both axes, so every glyph lands on
// the same centre whatever its ink extents are.
Item {
  id: root

  property string iconText: ""
  property string tooltipText: ""
  property bool selected: false
  property bool primary: false
  property bool enabled: true
  property color foreground: Color.foreground
  property real iconSize: Style.font.icon
  property real buttonSize: Style.space(34)

  signal clicked()

  readonly property bool hot: mouseArea.containsMouse

  implicitWidth: buttonSize
  implicitHeight: buttonSize
  width: buttonSize
  height: buttonSize

  Accessible.role: Accessible.Button
  Accessible.name: root.tooltipText
  Accessible.onPressAction: if (root.enabled) root.clicked()

  Rectangle {
    anchors.fill: parent
    radius: root.primary ? height / 2 : Style.space(9)
    opacity: root.enabled ? 1 : 0.4
    color: root.primary
      ? (mouseArea.pressed ? Qt.darker(Color.accent, 1.15) : Color.accent)
      : (mouseArea.pressed && root.enabled
        ? Style.pressedFillFor(root.foreground, Color.accent)
        : ((root.selected || root.hot) && root.enabled
          ? Style.selectedFillFor(root.foreground, Color.accent)
          : "transparent"))
    Behavior on color { ColorAnimation { duration: 120 } }
  }

  Text {
    anchors.fill: parent
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
    text: root.iconText
    textFormat: Text.PlainText
    font.family: Style.font.family
    font.pixelSize: root.iconSize
    opacity: root.enabled ? 1 : 0.4
    color: root.primary ? Color.background
      : (root.selected ? Style.selectedStateColor(root.foreground, Color.accent) : root.foreground)
  }

  MouseArea {
    id: mouseArea
    anchors.fill: parent
    hoverEnabled: true
    enabled: root.enabled
    cursorShape: root.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: root.clicked()
  }

  PanelToolTip {
    visible: root.tooltipText !== "" && mouseArea.containsMouse
    text: root.tooltipText
  }
}
