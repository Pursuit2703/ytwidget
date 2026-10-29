import QtQuick
import QtQuick.Controls
import qs.Commons

// Lyrics for the playing track. The line being sung sits in the middle,
// bigger and in the accent colour; the lines around it fade with distance.
//
// compact (mini card): no scrolling, a source line underneath.
// full (full player): wheel or drag to read ahead, click a line to jump the
// song there; a few seconds after you stop it glides back to the current line.
Item {
  id: root

  property var service: null
  property bool compact: false
  property color foreground: Color.foreground
  property color accent: Color.accent
  // Size of the current line in the full player: small | normal | large.
  property string size: "normal"
  // What the view sits on, for the fades at its edges.
  property color fadeTo: Color.background
  property bool active: visible

  readonly property var lyrics: service ? service.lyrics : null
  readonly property string status: lyrics ? String(lyrics.status || "none") : "none"
  readonly property var lines: lyrics && lyrics.lines ? lyrics.lines : []
  readonly property bool synced: clock.synced
  readonly property bool hasText: (status === "synced" || status === "captions" || status === "plain") && lines.length > 0
  readonly property color dim: Qt.darker(foreground, 1.6)

  // Words for where the text came from, without jargon.
  readonly property string sourceText: {
    if (!lyrics) return ""
    if (status === "synced") return "Synced"
    if (status === "captions") return lyrics.source === "auto" ? "From the video’s auto captions" : "From the video’s captions"
    if (status === "plain") return "Not timed"
    return ""
  }

  readonly property real currentSize: {
    if (compact) return Style.font.body + 3
    if (size === "small") return Style.font.body + 6
    if (size === "large") return Style.font.body + 16
    return Style.font.body + 11
  }
  readonly property real otherSize: compact ? Style.font.caption + 1 : currentSize * 0.68

  LyricsClock {
    id: clock
    service: root.service
    active: root.active
  }

  signal openPlayerRequested()

  property bool userScrolling: false
  // After reading ahead, glide back to the line being sung.
  Timer {
    id: backTimer
    interval: 5000
    onTriggered: root.backToNow()
  }
  function backToNow() {
    backTimer.stop()
    root.userScrolling = false
    if (clock.index >= 0) list.positionViewAtIndex(clock.index, ListView.Center)
  }

  function escapeHtml(text) {
    return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  }

  function formatTime(ms) {
    var s = Math.max(0, Math.floor(ms / 1000))
    return Math.floor(s / 60) + ":" + (s % 60 < 10 ? "0" : "") + (s % 60)
  }

  readonly property bool pointing: paneHover.hovered
  HoverHandler { id: paneHover }

  // ---- the lines
  ListView {
    id: list
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.bottom: footer.visible ? footer.top : parent.bottom
    visible: root.hasText
    clip: true
    model: root.hasText ? root.lines : []
    spacing: root.compact ? Style.space(4) : Style.space(10)
    interactive: true
    boundsBehavior: Flickable.StopAtBounds
    currentIndex: root.synced ? Math.max(0, clock.index) : -1
    highlightFollowsCurrentItem: true
    highlightRangeMode: root.synced && !root.userScrolling ? ListView.StrictlyEnforceRange : ListView.NoHighlightRange
    // A band around the middle sized from the font, not from the current
    // item (that fed back into itself as the item grew).
    preferredHighlightBegin: height / 2 - root.currentSize * 0.8
    preferredHighlightEnd: height / 2 + root.currentSize * 0.8
    highlightMoveDuration: 420
    highlightMoveVelocity: -1
    header: Item { height: root.synced ? list.height / 2 : 0; width: 1 }
    footer: Item { height: root.synced ? list.height / 2 : Style.space(12); width: 1 }
    // Always there on the right, so the lyrics can be dragged through.
    // Holding it stops the view following the song; it glides back a few
    // seconds after you let go.
    ScrollBar.vertical: ScrollBar {
      id: lyricsBar
      policy: list.contentHeight > list.height ? ScrollBar.AlwaysOn : ScrollBar.AsNeeded
      onPressedChanged: if (pressed) { root.userScrolling = true; backTimer.stop() } else backTimer.restart()
      onPositionChanged: if (pressed) root.userScrolling = true
    }

    onMovementStarted: { root.userScrolling = true; backTimer.restart() }
    WheelHandler {
      onWheel: function(event) {
        root.userScrolling = true
        backTimer.restart()
        list.contentY = Math.max(list.originY, Math.min(list.originY + list.contentHeight - list.height,
          list.contentY - event.angleDelta.y * (root.compact ? 0.5 : 1)))
      }
    }

    delegate: Item {
      id: lineItem
      required property var modelData
      required property int index
      readonly property string words: String(modelData.text || "").trim()
      readonly property bool isBreak: words === ""
      readonly property int distance: root.synced && clock.index >= 0 ? Math.abs(index - clock.index) : 0
      readonly property bool current: root.synced && index === clock.index
      readonly property bool passed: root.synced && index < clock.index
      readonly property bool canJump: root.synced && Number(modelData.ms) >= 0
      readonly property bool hot: lineMouse.containsMouse && canJump

      // Sung lines go quiet, the next ones stay readable.
      readonly property real restOpacity: {
        if (!root.synced) return 0.85
        if (current) return 1
        if (passed) return Math.max(0.16, 0.42 - (distance - 1) * 0.1)
        return Math.max(0.24, 0.82 - (distance - 1) * 0.2)
      }

      // Room on the right for the scrollbar.
      width: ListView.view.width - Style.space(12)
      // Pointing at a line only brightens it: nothing moves or resizes.
      height: Math.max(isBreak ? Style.space(root.compact ? 16 : 22) : 0, lineText.implicitHeight) + Style.space(4)

      // Instrumental break: three dots that light up as the next line nears.
      Row {
        visible: lineItem.isBreak
        anchors.centerIn: parent
        anchors.horizontalCenterOffset: root.compact ? 0 : -(parent.width / 2 - width / 2)
        spacing: Style.space(8)
        Repeater {
          model: 3
          Rectangle {
            required property int index
            width: Style.space(root.compact ? 6 : 8)
            height: width
            radius: width / 2
            color: root.accent
            opacity: lineItem.current
              ? (clock.progress * 3 > index ? 1 : 0.22)
              : lineItem.restOpacity * 0.6
            Behavior on opacity { NumberAnimation { duration: 300 } }
          }
        }
      }

      Text {
        id: lineText
        visible: !lineItem.isBreak
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        horizontalAlignment: root.compact ? Text.AlignHCenter : Text.AlignLeft
        wrapMode: Text.WordWrap
        maximumLineCount: root.compact ? 3 : 4
        elide: Text.ElideRight
        textFormat: Text.PlainText
        text: lineItem.words
        // The line being sung is the accent colour, whole; no word-by-word
        // fill (lyrics are timed per line, not per word).
        color: lineItem.current ? root.accent : (lineItem.hot ? Color.foreground : root.foreground)
        opacity: lineItem.hot ? 1 : lineItem.restOpacity
        font.family: Style.font.family
        font.bold: lineItem.current
        font.pixelSize: !root.synced ? root.otherSize + (root.compact ? 0 : 2)
          : (lineItem.current ? root.currentSize : root.otherSize)
        Behavior on opacity { NumberAnimation { duration: 250 } }
      }

      MouseArea {
        id: lineMouse
        anchors.fill: parent
        hoverEnabled: true
        enabled: lineItem.canJump
        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: {
          if (!root.service) return
          root.service.seek(Math.max(0, Number(lineItem.modelData.ms) + clock.offsetMs))
          root.backToNow()
        }
      }
    }
  }

  // "Back to now" while reading ahead.
  Rectangle {
    visible: root.userScrolling && root.synced && list.visible
    anchors.horizontalCenter: list.horizontalCenter
    anchors.bottom: list.bottom
    anchors.bottomMargin: Style.space(8)
    z: 3
    width: backRow.implicitWidth + Style.space(24)
    height: Style.space(28)
    radius: height / 2
    color: root.accent
    Row {
      id: backRow
      anchors.centerIn: parent
      spacing: Style.space(6)
      Text { text: "\u{f0045}"; color: Color.background; font.family: Style.font.family; font.pixelSize: Style.font.caption + 1; anchors.verticalCenter: parent.verticalCenter }
      Text { text: "Back to now"; color: Color.background; font.family: Style.font.family; font.bold: true; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter }
    }
    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.backToNow() }
  }

  // Small bar while pointing at the lyrics (mini card): timing, another
  // match, the big player.
  Rectangle {
    visible: root.compact && root.pointing && root.service && root.service.hasTrack
    anchors.right: parent.right
    anchors.top: parent.top
    z: 3
    width: toolRow.implicitWidth + Style.space(6)
    height: Style.space(32)
    radius: Style.space(10)
    color: Qt.rgba(Color.popups.background.r, Color.popups.background.g, Color.popups.background.b, 0.94)
    border.width: 1
    border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
    Row {
      id: toolRow
      anchors.centerIn: parent
      spacing: Style.space(1)
      FlatButton {
        visible: root.synced
        buttonSize: Style.space(26)
        iconSize: Style.font.caption + 2
        iconText: "\u{f0374}"
        foreground: root.foreground
        tooltipText: "Lyrics earlier"
        onClicked: if (root.service) root.service.setLyricsOffset(clock.offsetMs - 250)
      }
      Text {
        visible: root.synced
        width: Style.space(40)
        height: Style.space(26)
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        text: (clock.offsetMs > 0 ? "+" : clock.offsetMs < 0 ? "\u2212" : "") + (Math.abs(clock.offsetMs) / 1000).toFixed(2).replace(/0$/, "") + "s"
        color: root.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption - 1
      }
      FlatButton {
        visible: root.synced
        buttonSize: Style.space(26)
        iconSize: Style.font.caption + 2
        iconText: "\u{f0415}"
        foreground: root.foreground
        tooltipText: "Lyrics later"
        onClicked: if (root.service) root.service.setLyricsOffset(clock.offsetMs + 250)
      }
      Rectangle { visible: root.synced; width: 1; height: Style.space(16); anchors.verticalCenter: parent.verticalCenter; color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14) }
      FlatButton {
        buttonSize: Style.space(26)
        iconSize: Style.font.caption + 3
        iconText: "\u{f04e6}"
        foreground: root.foreground
        tooltipText: "Try another match"
        onClicked: if (root.service) root.service.lyricsTryOther()
      }
      FlatButton {
        buttonSize: Style.space(26)
        iconSize: Style.font.caption + 3
        iconText: "\u{f0293}"
        foreground: root.foreground
        tooltipText: "Open in the big player"
        onClicked: root.openPlayerRequested()
      }
    }
  }

  // Soft fade at the top and bottom edges of the list.
  Rectangle {
    visible: list.visible
    anchors.left: list.left
    anchors.right: list.right
    anchors.top: list.top
    height: Math.min(list.height * 0.28, Style.space(root.compact ? 34 : 90))
    gradient: Gradient {
      GradientStop { position: 0; color: root.fadeTo }
      GradientStop { position: 1; color: Qt.rgba(root.fadeTo.r, root.fadeTo.g, root.fadeTo.b, 0) }
    }
  }
  Rectangle {
    visible: list.visible
    anchors.left: list.left
    anchors.right: list.right
    anchors.bottom: list.bottom
    height: Math.min(list.height * 0.28, Style.space(root.compact ? 34 : 90))
    gradient: Gradient {
      GradientStop { position: 0; color: Qt.rgba(root.fadeTo.r, root.fadeTo.g, root.fadeTo.b, 0) }
      GradientStop { position: 1; color: root.fadeTo }
    }
  }

  // ---- loading / none / offline / off
  Column {
    anchors.centerIn: parent
    anchors.verticalCenterOffset: footer.visible ? -footer.height / 2 : 0
    width: parent.width - Style.space(16)
    visible: !root.hasText
    spacing: Style.space(root.compact ? 6 : 10)

    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      text: {
        if (root.status === "loading") return "Finding lyrics…"
        if (root.status === "offline") return "Can’t reach the lyrics site"
        if (root.status === "off") return "Lyrics are turned off"
        if (!root.service || !root.service.hasTrack) return "Nothing playing"
        return "No lyrics for this track"
      }
      color: root.foreground
      font.family: Style.font.family
      font.bold: true
      font.pixelSize: root.compact ? Style.font.body : Style.font.body + 3
      wrapMode: Text.WordWrap
    }
    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      visible: text !== ""
      text: {
        if (root.status === "none" && root.lyrics && root.lyrics.source === "instrumental") return "It’s an instrumental."
        if (root.status === "none" && root.service && root.service.hasTrack) return "Likely an instrumental. If that’s wrong, try another match."
        if (root.status === "offline") return "Saved lyrics still show. This one will load when you’re back online."
        return ""
      }
      color: root.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }

  // ---- where it came from (mini card)
  Item {
    id: footer
    visible: root.compact
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: Style.space(18)
    Text {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: root.sourceText
      color: root.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.caption - 1
    }
    Text {
      id: otherLink
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      visible: root.status === "none" || root.status === "plain" || root.status === "captions" || root.status === "offline"
      text: root.status === "offline" ? "Retry" : "Try another match"
      color: otherArea.containsMouse ? root.accent : Qt.darker(root.accent, 1.15)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption - 1
      MouseArea {
        id: otherArea
        anchors.fill: parent
        anchors.margins: -Style.space(4)
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: if (root.service) root.service.lyricsTryOther()
      }
    }
  }
}
