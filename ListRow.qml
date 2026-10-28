import QtQuick
import QtQuick.Layouts
import qs.Commons

// A playlist (saved or smart) in the Playlists tab. Same shape for every
// kind: a 44 px tile (a glyph for smart lists, a 2x2 cover grid for saved
// ones), the name, "N songs · length", and a chevron. Pointing at it swaps
// the chevron for a Play button.
Rectangle {
  id: root

  property string glyph: ""
  property var covers: []
  property string title: ""
  property string detail: ""
  property color foreground: Color.foreground

  signal opened()
  signal played()

  readonly property color dim: Qt.darker(foreground, 1.6)

  implicitHeight: Style.space(60)
  radius: Style.space(12)
  color: hover.hovered ? Qt.rgba(foreground.r, foreground.g, foreground.b, 0.05) : "transparent"

  HoverHandler { id: hover }

  RowLayout {
    anchors.fill: parent
    anchors.leftMargin: Style.space(8)
    anchors.rightMargin: Style.space(10)
    spacing: Style.space(14)

    Rectangle {
      Layout.preferredWidth: Style.space(44)
      Layout.preferredHeight: Style.space(44)
      radius: Style.space(10)
      clip: true
      color: root.glyph !== ""
        ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.16)
        : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
      Text {
        anchors.fill: parent
        visible: root.glyph !== ""
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        text: root.glyph
        color: Color.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.iconLarge
      }
      Grid {
        anchors.fill: parent
        visible: root.glyph === ""
        columns: 2
        spacing: 1
        Repeater {
          model: (root.covers || []).slice(0, 4)
          delegate: Image {
            required property var modelData
            width: (parent.width - 1) / 2
            height: (parent.height - 1) / 2
            source: modelData
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
          }
        }
      }
    }

    ColumnLayout {
      Layout.fillWidth: true
      spacing: Style.space(3)
      Text {
        Layout.fillWidth: true
        text: root.title
        color: root.foreground
        font.family: Style.font.family
        font.bold: true
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }
      Text {
        Layout.fillWidth: true
        text: root.detail
        color: root.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    FlatButton {
      visible: hover.hovered
      iconText: "\u{f040a}"
      foreground: Color.accent
      tooltipText: "Play"
      onClicked: root.played()
    }
    Text {
      visible: !hover.hovered
      Layout.preferredWidth: Style.space(34)
      horizontalAlignment: Text.AlignHCenter
      text: "\u{f0142}"
      color: root.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.icon
    }
  }

  MouseArea {
    z: -1
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: root.opened()
  }
}
