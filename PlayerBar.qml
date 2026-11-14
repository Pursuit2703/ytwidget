import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui

import "Api.js" as Api

// The full player's bottom bar: what is playing on the left, the transport and
// the seek bar in the middle, the views and sound controls on the right.
//
// It follows its own width:
//   wide (>= 900)    one row, the layout above
//   narrow           two rows: track + transport, then seek + tools
//   tiny (< 520)     two rows, shuffle/repeat and the volume slider drop out
//                    (S/R and the arrow keys still work)
Rectangle {
  id: root

  property var service: null
  property color accent: Color.accent
  property color onAccent: Color.background
  property color deep: Color.background
  property bool lyricsEnabled: true
  property bool lyricsOn: false
  property bool queueOn: false
  property bool eqOn: false
  property bool outputOn: false
  property bool karaokeOn: false
  readonly property bool karaokeReady: !!(service && service.lyrics
    && (service.lyrics.status === "synced" || service.lyrics.status === "captions")
    && (service.lyrics.lines || []).length > 0)

  signal artClicked()
  signal lyricsClicked()
  signal karaokeClicked()
  signal queueClicked()
  signal eqClicked()
  signal videoClicked()
  signal outputClicked(Item anchor)

  readonly property color fg: Color.foreground
  readonly property color fgDim: Qt.darker(Color.foreground, 1.6)
  readonly property bool wide: width >= Style.space(900)
  readonly property bool tiny: width < Style.space(520)
  readonly property bool hasTrack: !!(service && service.hasTrack)

  implicitHeight: wide ? Style.space(88) : Style.space(104)
  radius: Style.space(12)
  gradient: Gradient {
    orientation: Gradient.Horizontal
    GradientStop { position: 0.0; color: root.deep }
    GradientStop { position: 0.65; color: Color.background }
  }

  // ---- pieces -------------------------------------------------------------

  component Glyph: FlatButton {
    foreground: root.fg
    accent: root.accent
    onAccent: root.onAccent
  }

  // The whole track block opens the song's page (lyrics).
  Item {
    id: trackInfo
    implicitHeight: Style.space(root.wide ? 56 : 48)
    Rectangle {
      anchors.fill: parent
      anchors.margins: -Style.space(4)
      radius: Style.space(10)
      color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06)
      visible: trackArea.containsMouse && root.hasTrack
    }
    MouseArea {
      id: trackArea
      anchors.fill: parent
      hoverEnabled: true
      enabled: root.hasTrack
      cursorShape: Qt.PointingHandCursor
      onClicked: root.artClicked()
    }
    RowLayout {
      anchors.fill: parent
      spacing: Style.space(12)
      Rectangle {
        Layout.preferredWidth: parent.height
        Layout.preferredHeight: parent.height
        radius: Style.space(8)
        color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06)
        RoundedImage {
          anchors.fill: parent
          radius: parent.radius
          source: root.service ? root.service.trackThumbnail : ""
        }
        Text {
          anchors.centerIn: parent
          visible: !root.hasTrack
          text: "\u{f075a}"
          color: root.fgDim
          font.family: Style.font.family
          font.pixelSize: Style.font.iconLarge
        }
      }
      ColumnLayout {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        spacing: Style.space(2)
        Text {
          Layout.fillWidth: true
          text: root.hasTrack ? root.service.trackTitle : "Nothing playing"
          textFormat: Text.PlainText
          color: root.fg
          font.family: Style.font.family
          font.bold: true
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }
        Text {
          Layout.fillWidth: true
          visible: text !== ""
          text: root.service ? root.service.trackArtist : ""
          textFormat: Text.PlainText
          color: root.fgDim
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }

  RowLayout {
    id: transport
    spacing: Style.space(root.wide ? 10 : 2)
    Glyph {
      visible: !root.tiny
      iconText: "\u{f049f}"
      selected: !!(root.service && root.service.shuffle)
      tooltipText: "Shuffle (S)"
      onClicked: root.service && root.service.setShuffle(!root.service.shuffle)
    }
    Glyph {
      iconText: "\u{f04ae}"
      iconSize: Style.font.iconLarge
      tooltipText: "Previous (P)"
      onClicked: root.service && root.service.previous()
    }
    Glyph {
      primary: true
      buttonSize: Style.space(root.wide ? 46 : 42)
      iconSize: Style.font.iconLarge
      iconText: root.service && root.service.effectivePlaying ? "\u{f03e4}" : "\u{f040a}"
      tooltipText: "Play / pause (Space)"
      onClicked: root.service && root.service.togglePlayback()
    }
    Glyph {
      iconText: "\u{f04ad}"
      iconSize: Style.font.iconLarge
      tooltipText: "Next (N)"
      onClicked: root.service && root.service.next()
    }
    Glyph {
      visible: !root.tiny
      iconText: root.service && root.service.repeat === "track" ? "\u{f0458}" : "\u{f0456}"
      selected: !!(root.service && root.service.repeat !== "off")
      tooltipText: root.service && root.service.repeat === "track" ? "Repeat one (R)"
        : (root.service && root.service.repeat !== "off" ? "Repeat all (R)" : "Repeat (R)")
      onClicked: root.service && root.service.cycleRepeat()
    }
  }

  RowLayout {
    id: seek
    spacing: Style.space(10)
    Text {
      text: Api.formatTime(root.service ? root.service.positionMs : 0)
      color: root.fgDim
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
    PanelSlider {
      Layout.fillWidth: true
      Layout.minimumWidth: Style.space(60)
      minimum: 0
      maximum: Math.max(1, root.service ? root.service.durationMs : 1)
      value: root.service ? root.service.positionMs : 0
      fillColor: root.accent
      knobColor: Qt.lighter(root.accent, 1.15)
      trackColor: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.14)
      onMoved: function(v) { if (root.service) root.service.seek(v) }
    }
    Text {
      text: Api.formatTime(root.service ? root.service.durationMs : 0)
      color: root.fgDim
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  RowLayout {
    id: tools
    spacing: Style.space(2)
    // Shuffle and repeat live here when the transport row has no room.
    Glyph {
      visible: root.tiny
      iconText: "\u{f049f}"
      selected: !!(root.service && root.service.shuffle)
      tooltipText: "Shuffle (S)"
      onClicked: root.service && root.service.setShuffle(!root.service.shuffle)
    }
    Glyph {
      visible: root.tiny
      iconText: root.service && root.service.repeat === "track" ? "\u{f0458}" : "\u{f0456}"
      selected: !!(root.service && root.service.repeat !== "off")
      tooltipText: "Repeat (R)"
      onClicked: root.service && root.service.cycleRepeat()
    }
    Glyph {
      visible: root.lyricsEnabled
      iconText: "\u{f0369}"
      selected: root.lyricsOn
      tooltipText: "Lyrics (L)"
      onClicked: root.lyricsClicked()
    }
    Glyph {
      // Only when the song has timed lyrics to sing along to.
      visible: root.lyricsEnabled && root.karaokeReady
      iconText: "\u{f05cb}"
      selected: root.karaokeOn
      tooltipText: root.karaokeOn ? "Leave karaoke (K)" : "Karaoke (K)"
      onClicked: root.karaokeClicked()
    }
    Glyph {
      iconText: "\u{f0cb8}"
      selected: root.queueOn
      tooltipText: "Queue (2)"
      onClicked: root.queueClicked()
    }
    Glyph {
      iconText: "\u{f0567}"
      selected: !!(root.service && root.service.videoActive)
      enabled: root.hasTrack
      tooltipText: root.service && root.service.videoActive ? "Close the video window (V)" : "Watch the video (V)"
      onClicked: root.videoClicked()
    }
    Glyph {
      iconText: "\u{f066a}"
      selected: root.eqOn
      tooltipText: root.eqOn ? "Hide equaliser (E)" : "Equaliser (E)"
      onClicked: root.eqClicked()
    }
    Glyph {
      id: outputButton
      iconText: "\u{f04c3}"
      selected: root.outputOn
      tooltipText: "Play on…"
      onClicked: root.outputClicked(outputButton)
    }
    Glyph {
      iconText: root.service && root.service.volume === 0 ? "\u{f0581}" : "\u{f057e}"
      foreground: root.fgDim
      tooltipText: root.service && root.service.volume === 0 ? "Unmute (M)" : "Mute (M)"
      onClicked: if (root.service) root.service.setVolume(root.service.volume > 0 ? 0 : 50)
    }
    PanelSlider {
      Layout.preferredWidth: Style.space(96)
      minimum: 0
      maximum: 100
      value: root.service ? root.service.volume : 80
      fillColor: root.fg
      knobColor: root.fg
      trackColor: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.14)
      onMoved: function(v) { if (root.service) root.service.setVolume(v) }
    }
  }

  // ---- arrangement --------------------------------------------------------
  // The pieces above are re-parented into whichever layout fits.

  RowLayout {
    id: wideLayout
    visible: root.wide
    anchors.fill: parent
    anchors.leftMargin: Style.space(12)
    anchors.rightMargin: Style.space(14)
    spacing: Style.space(24)

    Item {
      id: wideLeft
      Layout.preferredWidth: Style.space(300)
      Layout.fillHeight: true
    }
    ColumnLayout {
      Layout.fillWidth: true
      Layout.maximumWidth: Style.space(680)
      Layout.alignment: Qt.AlignHCenter
      spacing: Style.space(4)
      Item { id: wideTransport; Layout.alignment: Qt.AlignHCenter; implicitWidth: transport.implicitWidth; implicitHeight: transport.implicitHeight }
      Item { id: wideSeek; Layout.fillWidth: true; implicitHeight: seek.implicitHeight }
    }
    Item {
      id: wideRight
      Layout.preferredWidth: Style.space(300)
      Layout.fillHeight: true
    }
  }

  ColumnLayout {
    id: narrowLayout
    visible: !root.wide
    anchors.fill: parent
    anchors.margins: Style.space(10)
    spacing: Style.space(6)
    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(8)
      Item { id: narrowInfo; Layout.fillWidth: true; implicitHeight: trackInfo.implicitHeight }
      Item { id: narrowTransport; implicitWidth: transport.implicitWidth; implicitHeight: transport.implicitHeight }
      // Lyrics, karaoke, queue, video, EQ, output and volume, in a menu.
      Glyph {
        id: moreButton
        iconText: "\u{f01d8}"
        selected: moreMenu.opened
        tooltipText: "More"
        onClicked: moreMenu.opened ? moreMenu.close() : moreMenu.open()
      }
    }
    Item { id: narrowSeek; Layout.fillWidth: true; implicitHeight: seek.implicitHeight }
  }

  Popup {
    id: moreMenu
    parent: moreButton
    x: moreButton.width - width
    y: -height - Style.space(8)
    padding: Style.space(8)
    background: Rectangle {
      color: Color.popups.background
      radius: Style.space(12)
      border.width: Math.max(1, Style.normalBorderWidth)
      border.color: Color.popups.border
    }
    contentItem: Item {
      id: moreHolder
      implicitWidth: tools.implicitWidth
      implicitHeight: tools.implicitHeight
    }
  }

  states: [
    State {
      name: "wide"
      when: root.wide
      ParentChange { target: trackInfo; parent: wideLeft }
      ParentChange { target: transport; parent: wideTransport }
      ParentChange { target: seek; parent: wideSeek }
      ParentChange { target: tools; parent: wideRight }
      PropertyChanges { trackInfo { x: 0; y: (wideLeft.height - trackInfo.height) / 2; width: wideLeft.width; height: trackInfo.implicitHeight } }
      PropertyChanges { transport { x: 0; y: 0 } }
      PropertyChanges { seek { x: 0; y: 0; width: wideSeek.width } }
      PropertyChanges { tools { x: wideRight.width - tools.implicitWidth; y: (wideRight.height - tools.implicitHeight) / 2 } }
    },
    State {
      name: "narrow"
      when: !root.wide
      ParentChange { target: trackInfo; parent: narrowInfo }
      ParentChange { target: transport; parent: narrowTransport }
      ParentChange { target: seek; parent: narrowSeek }
      ParentChange { target: tools; parent: moreHolder }
      PropertyChanges { trackInfo { x: 0; y: 0; width: narrowInfo.width; height: trackInfo.implicitHeight } }
      PropertyChanges { transport { x: 0; y: 0 } }
      PropertyChanges { seek { x: 0; y: 0; width: narrowSeek.width } }
      PropertyChanges { tools { x: 0; y: 0 } }
    }
  ]
}
