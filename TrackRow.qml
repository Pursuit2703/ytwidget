import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui

import "Api.js" as Api

Rectangle {
  id: root

  property var item: null
  property var service: null
  property bool highlighted: false
  property bool compact: false
  property string playGlyph: "󰐊"
  property string queueGlyph: "󰐕"
  property string playlistGlyph: "󱁐"
  property color fg: Color.foreground
  property color fgDim: Qt.darker(Color.foreground, 1.6)
  property color rowFill: Qt.rgba(fg.r, fg.g, fg.b, 0.05)
  property color rowFillActive: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.16)

  signal playRequested()
  signal queueRequested()

  function addCurrentItemToPlaylist(playlistId) {
    if (!root.service || !root.item) return
    root.service.addToPlaylist(playlistId, root.item, function(ok) {
      if (ok) root.service.listPlaylists(function() {})
    })
  }

  function createPlaylistWithCurrentItem(name) {
    if (!root.service || !root.item) return
    var trimmed = String(name || "").trim()
    if (!trimmed) return
    root.service.createPlaylist(trimmed, [root.item], function(ok) {
      if (ok) root.service.listPlaylists(function() {})
    })
  }

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
    Chicklet {
      id: playlistButton
      visible: !!root.service
      iconText: root.playlistGlyph
      chickletSize: root.compact ? Style.space(26) : Style.space(32)
      tooltipText: "Add to playlist"
      onClicked: playlistPopup.opened ? playlistPopup.close() : playlistPopup.open()

      Popup {
        id: playlistPopup
        x: playlistButton.width - width
        y: playlistButton.height + Style.space(4)
        width: Style.space(230)
        padding: Style.space(8)
        focus: true

        property string newPlaylistName: ""

        onOpened: {
          playlistPopup.newPlaylistName = ""
          if (root.service) root.service.listPlaylists(function() {})
        }

        background: Rectangle {
          color: Color.popups.background
          radius: Style.cornerRadius
          border.width: Math.max(1, Style.normalBorderWidth)
          border.color: Color.popups.border
        }

        contentItem: ColumnLayout {
          spacing: Style.space(6)

          Label {
            text: "Add to playlist"
            color: Color.popups.text
            font.bold: true
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Item {
            Layout.fillWidth: true
            Layout.preferredHeight: Math.max(Style.space(30),
              Math.min(root.service ? root.service.playlists.length : 0, 5) * Style.space(30))

            Label {
              anchors.centerIn: parent
              visible: !root.service || root.service.playlists.length === 0
              text: "No playlists yet"
              color: Qt.darker(Color.popups.text, 1.6)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            ListView {
              anchors.fill: parent
              clip: true
              spacing: Style.space(2)
              model: root.service ? root.service.playlists : []
              ScrollBar.vertical: ScrollBar {}

              delegate: Rectangle {
                width: ListView.view.width
                height: Style.space(28)
                radius: Style.cornerRadius
                color: playlistRowHover.containsMouse
                  ? Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.08)
                  : "transparent"

                Label {
                  anchors.left: parent.left
                  anchors.right: playlistCount.left
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(6)
                  anchors.rightMargin: Style.space(4)
                  text: modelData.name
                  color: Color.popups.text
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
                Label {
                  id: playlistCount
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.rightMargin: Style.space(6)
                  text: modelData.count
                  color: Qt.darker(Color.popups.text, 1.6)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                MouseArea {
                  id: playlistRowHover
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.addCurrentItemToPlaylist(modelData.id)
                    playlistPopup.close()
                  }
                }
              }
            }
          }

          PanelSeparator { Layout.fillWidth: true }

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(6)

            TextField {
              Layout.fillWidth: true
              placeholderText: "New playlist…"
              text: playlistPopup.newPlaylistName
              onTextChanged: playlistPopup.newPlaylistName = text
              onAccepted: {
                root.createPlaylistWithCurrentItem(playlistPopup.newPlaylistName)
                playlistPopup.close()
              }
            }
            Chicklet {
              iconText: root.playlistGlyph
              chickletSize: Style.space(26)
              tooltipText: "Create & add"
              enabled: playlistPopup.newPlaylistName.trim() !== ""
              onClicked: {
                root.createPlaylistWithCurrentItem(playlistPopup.newPlaylistName)
                playlistPopup.close()
              }
            }
          }
        }
      }
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
