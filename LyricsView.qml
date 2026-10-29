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

  property bool userScrolling: false
  Timer {
    id: backTimer
    interval: 3000
    onTriggered: {
      root.userScrolling = false
      if (clock.index >= 0) list.positionViewAtIndex(clock.index, ListView.Center)
    }
  }

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
    spacing: root.compact ? Style.space(6) : Style.space(14)
    interactive: !root.compact
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
    ScrollBar.vertical: ScrollBar { visible: !root.compact && !root.synced }

    onMovementStarted: { root.userScrolling = true; backTimer.restart() }
    WheelHandler {
      enabled: !root.compact
      onWheel: function(event) {
        root.userScrolling = true
        backTimer.restart()
        list.contentY = Math.max(list.originY, Math.min(list.originY + list.contentHeight - list.height,
          list.contentY - event.angleDelta.y))
      }
    }

    delegate: Item {
      id: lineItem
      required property var modelData
      required property int index
      readonly property int distance: root.synced && clock.index >= 0 ? Math.abs(index - clock.index) : 0
      readonly property bool current: root.synced && index === clock.index
      readonly property bool passed: root.synced && index < clock.index
      width: ListView.view.width
      height: lineText.implicitHeight

      Text {
        id: lineText
        width: parent.width
        horizontalAlignment: root.compact ? Text.AlignHCenter : Text.AlignLeft
        wrapMode: Text.WordWrap
        maximumLineCount: root.compact ? 2 : 4
        elide: Text.ElideRight
        // An empty LRC line is a musical break: show a quiet dot.
        text: String(lineItem.modelData.text || "") || "·  ·  ·"
        color: lineItem.current ? root.accent : root.foreground
        opacity: !root.synced ? 0.85
          : (lineItem.current ? 1 : Math.max(0.18, 0.62 - lineItem.distance * 0.12))
        font.family: Style.font.family
        font.bold: lineItem.current
        font.pixelSize: !root.synced ? root.otherSize + (root.compact ? 0 : 2)
          : (lineItem.current ? root.currentSize : root.otherSize)
        Behavior on font.pixelSize { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        Behavior on opacity { NumberAnimation { duration: 250 } }
      }

      MouseArea {
        anchors.fill: parent
        enabled: !root.compact && root.synced && Number(lineItem.modelData.ms) >= 0
        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: {
          if (!root.service) return
          root.userScrolling = false
          root.service.seek(Math.max(0, Number(lineItem.modelData.ms) + clock.offsetMs))
        }
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
