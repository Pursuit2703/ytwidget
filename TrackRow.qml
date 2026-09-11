import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui

import "Api.js" as Api

Rectangle {
  id: root

  property var item: null
  property bool highlighted: false
  property bool compact: false
  property string playGlyph: "󰐊"
  property string queueGlyph: "󰐕"
  property color fg: Color.foreground
  property color fgDim: Qt.darker(Color.foreground, 1.6)
  property color rowFill: Qt.rgba(fg.r, fg.g, fg.b, 0.05)
  property color rowFillActive: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.16)

  signal playRequested()
  signal queueRequested()

  height: compact ? Style.space(38) : Style.space(46)
  radius: Style.cornerRadius
  color: highlighted ? rowFillActive : (rowHover.containsMouse ? rowFill : "transparent")

  RowLayout {
    anchors.fill: parent
    anchors.margins: Style.space(6)
    spacing: Style.space(8)

    Rectangle {
      Layout.preferredWidth: root.compact ? Style.space(26) : Style.space(34)
      Layout.preferredHeight: root.compact ? Style.space(26) : Style.space(34)
      radius: Style.cornerRadius
      color: root.rowFill
      clip: true
      Image {
        anchors.fill: parent
        visible: !!(root.item && root.item.thumbnail)
        source: root.item ? (root.item.thumbnail || "") : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
      }
    }

    ColumnLayout {
      Layout.fillWidth: true
      spacing: Style.space(1)
      Label {
        text: root.item ? (root.item.name || "Untitled") : ""
        color: root.fg
        font.family: Style.font.family
        font.pixelSize: root.compact ? Style.font.caption : Style.font.body
        elide: Text.ElideRight
        Layout.fillWidth: true
      }
      Label {
        visible: !root.compact
        text: {
          if (!root.item) return ""
          var d = root.item.live ? "LIVE" : Api.formatTime(root.item.durationMs || 0)
          return (root.item.subtitle || "") + "  ·  " + d
        }
        color: root.fgDim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        Layout.fillWidth: true
      }
    }

    Chicklet {
      iconText: root.playGlyph
      chickletSize: root.compact ? Style.space(26) : Style.space(32)
      tooltipText: "Play now"
      onClicked: root.playRequested()
    }
    Chicklet {
      iconText: root.queueGlyph
      chickletSize: root.compact ? Style.space(26) : Style.space(32)
      tooltipText: "Queue"
      onClicked: root.queueRequested()
    }
  }

  // Clicking the row body (thumbnail/title) plays it. This sits BELOW the
  // content: `z` only orders an item against its own siblings, so putting
  // z:1 on the buttons could never lift them above this area — it is a
  // sibling of their parent RowLayout, not of the buttons. On top, it
  // swallowed every click, which made the queue (+) button play instead.
  // Underneath, the buttons get their clicks and the inert thumbnail/title
  // let clicks fall through to here.
  MouseArea {
    id: rowHover
    z: -1
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton
    onClicked: root.playRequested()
  }
}
