import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui

import "Api.js" as Api

// One track in any list. Quiet by default: cover, title, channel and length.
// Pointing at the row shows Play and a ⋯ menu (queue, playlist, YouTube);
// right-click opens the same menu. The track that is playing gets moving bars
// over its cover and an accent title, so it can be found at a glance.
Rectangle {
  id: root

  property var item: null
  property var service: null
  property bool highlighted: false
  property bool compact: false
  property string playGlyph: "\u{f040a}"
  // f0415 (+) means "add to queue", f0156 (×) means "remove from queue";
  // the menu wording follows it.
  property string queueGlyph: "\u{f0415}"
  property string playlistGlyph: "\u{f0412}"
  property color fg: Color.foreground
  property color fgDim: Qt.darker(Color.foreground, 1.6)
  property color rowFill: Qt.rgba(fg.r, fg.g, fg.b, 0.05)
  property color rowFillActive: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.16)

  readonly property bool removes: queueGlyph === "\u{f0156}"
  readonly property bool isCurrent: !!(service && service.track && item
    && item.videoId && service.track.videoId === item.videoId)
  readonly property bool showActions: hover.hovered || menu.opened

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

  function openMenu(x, y) {
    menu.pickingPlaylist = false
    menu.x = Math.min(x, root.width - menu.width)
    menu.y = y
    menu.open()
  }

  height: compact ? Style.space(40) : Style.space(48)
  radius: Style.space(10)
  color: highlighted || isCurrent ? rowFillActive : (showActions ? rowFill : "transparent")

  HoverHandler { id: hover }

  component MenuRow: Rectangle {
    id: menuRow
    property string glyph: ""
    property string label: ""
    property color tint: Color.popups.text
    signal picked()
    Layout.fillWidth: true
    implicitHeight: Style.space(32)
    radius: Style.space(8)
    color: menuRowArea.containsMouse
      ? Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.08)
      : "transparent"
    Row {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(10)
      Text {
        width: Style.space(16)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
        text: menuRow.glyph
        color: menuRow.tint
        font.family: Style.font.family
        font.pixelSize: Style.font.body + 1
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: menuRow.label
        color: menuRow.tint
        font.family: Style.font.family
        font.pixelSize: Style.font.caption + 1
      }
    }
    MouseArea {
      id: menuRowArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: menuRow.picked()
    }
  }


  RowLayout {
    anchors.fill: parent
    anchors.leftMargin: Style.space(6)
    anchors.rightMargin: Style.space(8)
    spacing: Style.space(10)

    Rectangle {
      Layout.preferredWidth: root.compact ? Style.space(28) : Style.space(36)
      Layout.preferredHeight: root.compact ? Style.space(28) : Style.space(36)
      radius: Style.space(6)
      color: root.rowFill
      clip: true
      Image {
        anchors.fill: parent
        visible: !!(root.item && root.item.thumbnail)
        source: root.item ? (root.item.thumbnail || "") : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
      }
      // Now-playing bars: three bars that bob while the track plays and rest
      // when it is paused.
      Rectangle {
        anchors.fill: parent
        visible: root.isCurrent
        color: Qt.rgba(0, 0, 0, 0.55)
        Row {
          anchors.centerIn: parent
          spacing: Style.space(2)
          Repeater {
            model: 3
            Rectangle {
              id: nowBar
              required property int index
              width: Style.space(3)
              anchors.bottom: parent.bottom
              radius: 1
              color: Color.accent
              property real level: [0.6, 1.0, 0.45][index]
              height: Style.space(root.compact ? 14 : 16) * level
              SequentialAnimation on level {
                running: root.isCurrent && !!(root.service && root.service.effectivePlaying)
                loops: Animation.Infinite
                NumberAnimation { to: 0.3; duration: 260 + nowBar.index * 90; easing.type: Easing.InOutSine }
                NumberAnimation { to: 1.0; duration: 300 + nowBar.index * 70; easing.type: Easing.InOutSine }
              }
            }
          }
          height: Style.space(root.compact ? 14 : 16)
        }
      }
    }

    ColumnLayout {
      Layout.fillWidth: true
      spacing: Style.space(2)
      Label {
        text: root.item ? (root.item.name || "Untitled") : ""
        color: root.isCurrent ? Color.accent : root.fg
        font.family: Style.font.family
        font.bold: root.isCurrent
        font.pixelSize: root.compact ? Style.font.caption : Style.font.body
        elide: Text.ElideRight
        Layout.fillWidth: true
      }
      Label {
        visible: !root.compact && text !== ""
        text: root.item ? (root.item.subtitle || "") : ""
        color: root.fgDim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        Layout.fillWidth: true
      }
    }

    FlatButton {
      visible: root.showActions
      iconText: root.playGlyph
      foreground: root.fg
      buttonSize: root.compact ? Style.space(28) : Style.space(32)
      tooltipText: "Play"
      onClicked: root.playRequested()
    }
    FlatButton {
      id: moreButton
      visible: root.showActions
      iconText: "\u{f01d8}"
      foreground: root.fg
      selected: menu.opened
      buttonSize: root.compact ? Style.space(28) : Style.space(32)
      tooltipText: "More"
      onClicked: {
        if (menu.opened) { menu.close(); return }
        var p = moreButton.mapToItem(root, 0, moreButton.height + Style.space(4))
        root.openMenu(moreButton.x + moreButton.width - menu.width, p.y)
      }
    }
    Label {
      visible: !root.showActions
      Layout.preferredWidth: Style.space(44)
      horizontalAlignment: Text.AlignRight
      text: root.item ? (root.item.live ? "Live" : Api.formatTime(root.item.durationMs || 0)) : ""
      color: root.fgDim
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  Popup {
    id: menu
    width: Style.space(230)
    padding: Style.space(6)
    focus: true

    property bool pickingPlaylist: false
    property string newPlaylistName: ""

    onOpened: {
      menu.newPlaylistName = ""
      if (root.service) root.service.listPlaylists(function() {})
    }

    background: Rectangle {
      color: Color.popups.background
      radius: Style.space(12)
      border.width: Math.max(1, Style.normalBorderWidth)
      border.color: Color.popups.border
    }

    contentItem: ColumnLayout {
      spacing: Style.space(2)

      // ---- actions
      MenuRow {
        visible: !menu.pickingPlaylist
        glyph: root.playGlyph
        label: "Play"
        onPicked: { menu.close(); root.playRequested() }
      }
      MenuRow {
        visible: !menu.pickingPlaylist && !root.removes
        glyph: "\u{f0415}"
        label: "Add to queue"
        onPicked: { menu.close(); root.queueRequested() }
      }
      MenuRow {
        visible: !menu.pickingPlaylist && !!root.service
        glyph: root.playlistGlyph
        label: "Add to playlist"
        onPicked: menu.pickingPlaylist = true
      }
      MenuRow {
        visible: !menu.pickingPlaylist && !!(root.item && root.item.videoId)
        glyph: "\u{f03cc}"
        label: "Open on YouTube"
        onPicked: {
          menu.close()
          Qt.openUrlExternally("https://www.youtube.com/watch?v=" + root.item.videoId)
        }
      }
      MenuRow {
        visible: !menu.pickingPlaylist && root.removes
        glyph: "\u{f0156}"
        label: "Remove from queue"
        tint: Color.urgent
        onPicked: { menu.close(); root.queueRequested() }
      }

      // ---- playlist picker
      MenuRow {
        visible: menu.pickingPlaylist
        glyph: "\u{f004d}"
        label: "Add to playlist"
        onPicked: menu.pickingPlaylist = false
      }
      Item {
        visible: menu.pickingPlaylist
        Layout.fillWidth: true
        Layout.preferredHeight: Math.max(Style.space(32),
          Math.min(root.service ? root.service.playlists.length : 0, 5) * Style.space(34))

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

          delegate: MenuRow {
            width: ListView.view.width
            glyph: root.playlistGlyph
            label: modelData.name
            onPicked: {
              root.addCurrentItemToPlaylist(modelData.id)
              menu.close()
            }
          }
        }
      }
      RowLayout {
        visible: menu.pickingPlaylist
        Layout.fillWidth: true
        Layout.topMargin: Style.space(4)
        spacing: Style.space(6)

        TextField {
          Layout.fillWidth: true
          placeholderText: "New playlist…"
          text: menu.newPlaylistName
          onTextChanged: menu.newPlaylistName = text
          onAccepted: {
            root.createPlaylistWithCurrentItem(menu.newPlaylistName)
            menu.close()
          }
        }
        FlatButton {
          iconText: "\u{f0415}"
          buttonSize: Style.space(30)
          foreground: Color.popups.text
          tooltipText: "Create and add"
          enabled: menu.newPlaylistName.trim() !== ""
          onClicked: {
            root.createPlaylistWithCurrentItem(menu.newPlaylistName)
            menu.close()
          }
        }
      }
    }
  }

  // Clicking the row body plays it; right-click opens the menu. This sits
  // BELOW the content: `z` only orders an item against its own siblings, so
  // the buttons, being inside the RowLayout, are always above it and keep
  // their own clicks.
  MouseArea {
    id: rowArea
    z: -1
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onClicked: function(mouse) {
      if (mouse.button === Qt.RightButton) root.openMenu(mouse.x, mouse.y)
      else root.playRequested()
    }
  }
}
