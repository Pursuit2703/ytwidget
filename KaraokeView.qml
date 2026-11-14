import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

import "Api.js" as Api

// Karaoke: the song fills the window. The line being sung is large and
// fills with the cover colour from left to right across its own timing (the
// lyrics are timed per line, so the sweep is even, not word by word). The
// lines before fade upwards, the next one is already readable. Before the
// first line and in long instrumental breaks a count-in shows how long until
// singing starts. The lyric settings (match, language, timing, another
// match) stay on screen.
Item {
  id: root

  property var service: null
  property bool active: visible
  property color accent: Color.accent
  property color onAccent: Color.background
  property color deep: Color.background
  // small | medium | large | huge
  property string textSize: "large"
  property bool settingsOpen: false
  property bool showNextLine: true
  property bool countInEnabled: true

  signal exitRequested()
  signal sizeCycled()
  signal sizePicked(string size)

  readonly property color fg: "#f4efe9"
  readonly property color fgDim: Qt.rgba(1, 1, 1, 0.55)
  readonly property bool narrow: width < Style.space(760)

  readonly property var lyrics: service ? service.lyrics : null
  readonly property var lines: lyrics && lyrics.lines ? lyrics.lines : []
  readonly property bool synced: clock.synced && lines.length > 0

  readonly property real sizeScale: (textSize === "small" ? 0.72 : textSize === "medium" ? 0.86
    : textSize === "huge" ? 1.25 : 1.0) * (narrow ? 0.62 : 1.0)

  // No lead here: the lyrics page lights a line a moment early so the eye
  // keeps up, but karaoke sings along, so lines and the fill run on the dot.
  LyricsClock {
    id: clock
    service: root.service
    active: root.active
    leadMs: 0
  }

  function wordsAt(i) {
    if (i < 0 || i >= root.lines.length) return ""
    return String(root.lines[i].text || "").trim()
  }
  // The next line with words after `i`.
  function nextSung(i) {
    for (var j = i + 1; j < root.lines.length; j++) if (wordsAt(j) !== "") return j
    return -1
  }
  function prevSung(i) {
    for (var j = i - 1; j >= 0; j--) if (wordsAt(j) !== "") return j
    return -1
  }

  // Which line is being sung, from the same per-frame clock that drives
  // the fill. (Taking it from the 50 ms lyrics clock instead let the line
  // switch while the smoother fill clock was still a little behind, so the
  // colour never finished before the next line took over.)
  readonly property int cur: {
    var ls = root.lines
    if (!root.synced || ls.length === 0) return -1
    var t = root.localT >= 0 ? root.localT : clock.nowMs - clock.offsetMs + clock.leadMs
    var lo = 0, hi = ls.length - 1, found = -1
    while (lo <= hi) {
      var mid = (lo + hi) >> 1
      if (Number(ls[mid].ms) <= t) { found = mid; lo = mid + 1 }
      else hi = mid - 1
    }
    return found
  }
  readonly property bool inBreak: cur < 0 || wordsAt(cur) === ""
  readonly property int upcoming: nextSung(cur)
  // Milliseconds until the next sung line starts.
  readonly property real untilNext: {
    if (upcoming < 0) return -1
    var t = root.localT >= 0 ? root.localT : clock.nowMs - clock.offsetMs + clock.leadMs
    return Math.max(0, Number(root.lines[upcoming].ms) - t)
  }
  // Count in when nothing is being sung for a while.
  readonly property bool countIn: countInEnabled && synced && inBreak && upcoming >= 0 && untilNext > 1200

  // Left / right: the previous / next sung line. Left in the first moment of
  // a line goes back one; later in a line it starts that line again.
  function stepLine(dir) {
    if (!root.synced || !root.service) return false
    var ls = root.sungLines
    if (ls.length === 0) return false
    var pos = root.sungPos(root.focusLine)
    var target
    if (dir > 0) target = root.inBreak ? pos : pos + 1
    else {
      var startMs = Number(root.lines[ls[pos].i].ms)
      var into = root.localT - startMs
      target = (!root.inBreak && into > 1500) ? pos : pos - 1
    }
    target = Math.max(0, Math.min(ls.length - 1, target))
    var ms = Number(root.lines[ls[target].i].ms) + clock.offsetMs
    root.service.seek(Math.max(0, ms))
    root.localT = -1
    return true
  }

  // Space during a count-in: jump to just before the next line.
  function skipAhead() {
    if (!root.countIn || !root.service || root.untilNext < 3000) return false
    var target = Number(root.lines[root.upcoming].ms) + clock.offsetMs - 2000
    root.service.seek(Math.max(0, target))
    return true
  }
  readonly property int focusLine: inBreak ? upcoming : cur

  // Song time, advanced every frame by real time and gently steered by the
  // player's position reports, so the fill sweeps smoothly instead of in
  // 50 ms steps (same as the lyric strip in the bar).
  property real localT: -1
  readonly property real liveProgress: {
    if (root.inBreak || root.cur < 0 || root.cur + 1 >= root.lines.length) return root.inBreak ? 0 : 1
    var a = Number(root.lines[root.cur].ms), b = Number(root.lines[root.cur + 1].ms)
    return b > a ? Math.max(0, Math.min(1, (root.localT - a) / (b - a))) : 1
  }
  FrameAnimation {
    running: root.active && root.synced
    onTriggered: {
      var svc = root.service
      if (!svc) return
      var playing = !!svc.effectivePlaying
      var target = Number(svc.positionMs || 0)
      if (playing && svc.positionStampMs > 0) target += Math.max(0, Date.now() - svc.positionStampMs)
      target += clock.leadMs - clock.offsetMs
      if (root.localT < 0 || Math.abs(target - root.localT) > 1200) root.localT = target
      else {
        if (playing) root.localT += frameTime * 1000
        root.localT += (target - root.localT) * Math.min(1, frameTime * 2)
      }
    }
  }

  // Only the lines with words, for the scrolling column.
  readonly property var sungLines: {
    var out = []
    for (var i = 0; i < root.lines.length; i++) {
      var w = root.wordsAt(i)
      if (w !== "") out.push({ i: i, text: w })
    }
    return out
  }
  function sungPos(lineIndex) {
    var ls = root.sungLines
    for (var k = 0; k < ls.length; k++) if (ls[k].i >= lineIndex) return k
    return Math.max(0, ls.length - 1)
  }

  // ---- background: the cover, blurred over the whole window ----
  Rectangle { anchors.fill: parent; color: root.deep }
  CoverBlur {
    anchors.fill: parent
    source: root.service ? root.service.trackThumbnail : ""
    strength: 0.75
    fadeTo: root.deep
  }
  Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.32) }

  // Pill used across the screen.
  component Chip: Rectangle {
    id: chip
    property string label: ""
    property string glyph: ""
    property bool on: false
    property color tint: "#f4efe9"
    property bool enabledChip: true
    signal picked()
    implicitHeight: Style.space(34)
    implicitWidth: chipRow.implicitWidth + Style.space(28)
    radius: height / 2
    opacity: enabledChip ? 1 : 0.45
    color: on ? Qt.rgba(tint.r, tint.g, tint.b, 0.24)
      : (chipArea.containsMouse ? Qt.rgba(1, 1, 1, 0.18) : Qt.rgba(1, 1, 1, 0.10))
    Row {
      id: chipRow
      anchors.centerIn: parent
      spacing: Style.space(7)
      Text {
        visible: chip.glyph !== ""
        anchors.verticalCenter: parent.verticalCenter
        text: chip.glyph
        color: chip.on ? chip.tint : "#f4efe9"
        font.family: Style.font.family
        font.pixelSize: Style.font.icon
      }
      Text {
        visible: chip.label !== ""
        anchors.verticalCenter: parent.verticalCenter
        text: chip.label
        color: chip.on ? chip.tint : "#f4efe9"
        font.family: Style.font.family
        font.bold: chip.on
        font.pixelSize: Style.font.caption + 1
      }
    }
    MouseArea {
      id: chipArea
      anchors.fill: parent
      hoverEnabled: true
      enabled: chip.enabledChip
      cursorShape: Qt.PointingHandCursor
      onClicked: chip.picked()
    }
  }

  // ---- top strip ----
  RowLayout {
    id: topStrip
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.margins: Style.space(22)
    spacing: Style.space(12)

    Rectangle {
      Layout.preferredWidth: Style.space(44)
      Layout.preferredHeight: Style.space(44)
      radius: Style.space(8)
      color: Qt.rgba(1, 1, 1, 0.08)
      RoundedImage {
        anchors.fill: parent
        radius: parent.radius
        source: root.service ? root.service.trackThumbnail : ""
      }
    }
    ColumnLayout {
      Layout.fillWidth: true
      Layout.minimumWidth: 0
      spacing: Style.space(2)
      Text {
        Layout.fillWidth: true
        text: root.service && root.service.hasTrack ? root.service.trackTitle : "Nothing playing"
        textFormat: Text.PlainText
        color: root.fg
        font.family: Style.font.family
        font.bold: true
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }
      Text {
        Layout.fillWidth: true
        text: root.service ? root.service.trackArtist : ""
        textFormat: Text.PlainText
        color: root.fgDim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Chip {
      visible: !root.narrow
      on: true
      tint: root.accent
      glyph: "\u{f05cb}"
      label: "Karaoke"
      enabledChip: true
    }

    Chip {
      visible: !root.narrow
      label: "Aa · " + root.textSize.charAt(0).toUpperCase() + root.textSize.slice(1)
      onPicked: root.sizeCycled()
    }
    Chip {
      glyph: "\u{f0493}"
      on: root.settingsOpen
      tint: root.accent
      onPicked: root.settingsOpen = !root.settingsOpen
    }
    Chip {
      glyph: "\u{f0156}"
      label: root.narrow ? "" : "Exit · Esc"
      onPicked: root.exitRequested()
    }
  }

  // ---- lyric settings: always on screen here, timing matters most ----
  Rectangle {
    id: lyricBar
    visible: root.lyrics && root.lyrics.status !== "none"
    anchors.top: topStrip.bottom
    anchors.topMargin: Style.space(12)
    anchors.horizontalCenter: parent.horizontalCenter
    width: Math.min(parent.width - Style.space(32), lyricRow.implicitWidth + Style.space(10))
    height: Style.space(44)
    radius: height / 2
    color: Qt.rgba(0, 0, 0, 0.28)
    border.width: 1
    border.color: Qt.rgba(1, 1, 1, 0.08)
    clip: true

    Row {
      id: lyricRow
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      anchors.leftMargin: Style.space(5)
      spacing: Style.space(6)

      Chip {
        id: sourceChip
        on: true
        tint: root.accent
        glyph: root.synced ? "\u{f04e6}" : ""
        label: sourceText.sourceText !== "" ? sourceText.sourceText + "  \u{f0140}" : "Lyrics  \u{f0140}"
        onPicked: {
          karaokeMenu.y = sourceChip.height + Style.space(6)
          karaokeMenu.open()
        }
        LyricsMenu {
          id: karaokeMenu
          service: root.service
          maxHeight: Math.max(Style.space(200), root.height * 0.6)
        }
      }
      Chip {
        id: langChip
        visible: !!root.lyrics && !!(root.lyrics.langName || root.lyrics.translatedName)
        glyph: "\u{f05ca}"
        label: root.lyrics ? String(root.lyrics.translatedName || root.lyrics.langName || "") + "  \u{f0140}" : ""
        onPicked: {
          karaokeMenu.y = sourceChip.height + Style.space(6)
          karaokeMenu.open()
        }
      }
      Rectangle {
        visible: root.synced
        height: Style.space(34)
        width: timing.implicitWidth + Style.space(10)
        radius: height / 2
        color: Qt.rgba(1, 1, 1, 0.10)
        Row {
          id: timing
          anchors.centerIn: parent
          spacing: Style.space(2)
          FlatButton {
            anchors.verticalCenter: parent.verticalCenter
            buttonSize: Style.space(28)
            iconText: "\u{f0374}"
            foreground: root.fg
            accent: root.accent
            tooltipText: "Lyrics earlier ( [ )"
            onClicked: root.nudge(-250)
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(root.narrow ? 54 : 104)
            horizontalAlignment: Text.AlignHCenter
            text: (root.narrow ? "" : "Timing ") + (clock.offsetMs > 0 ? "+" : clock.offsetMs < 0 ? "−" : "")
              + (Math.abs(clock.offsetMs) / 1000).toFixed(2).replace(/0$/, "") + "s"
            color: root.fg
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          FlatButton {
            anchors.verticalCenter: parent.verticalCenter
            buttonSize: Style.space(28)
            iconText: "\u{f0415}"
            foreground: root.fg
            accent: root.accent
            tooltipText: "Lyrics later ( ] )"
            onClicked: root.nudge(250)
          }
        }
      }
      Chip {
        glyph: "\u{f0450}"
        label: root.narrow ? "" : "Wrong song? Try another"
        onPicked: if (root.service) root.service.lyricsTryOther()
      }
      Text {
        visible: !root.narrow && text !== ""
        anchors.verticalCenter: parent.verticalCenter
        rightPadding: Style.space(12)
        text: {
          var l = root.lyrics
          if (!l || !l.title) return ""
          var note = Api.syncNote(l)
          return "Lyrics of " + l.artist + " – " + l.title + (note !== "" ? " · " + note : "")
        }
        color: Qt.rgba(1, 1, 1, 0.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }

  // Source wording, from the lyrics view's own logic.
  LyricsView {
    id: sourceText
    visible: false
    service: root.service
    active: false
  }

  function nudge(deltaMs) {
    if (root.service) root.service.setLyricsOffset(clock.offsetMs + deltaMs)
  }

  // ---- the lines ----
  Item {
    id: stage
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: lyricBar.visible ? lyricBar.bottom : topStrip.bottom
    anchors.bottom: bottomBlock.top
    anchors.leftMargin: Style.space(root.narrow ? 20 : 90)
    anchors.rightMargin: Style.space(root.narrow ? 20 : 90)

    // No timed lyrics: say so and offer the way out.
    ColumnLayout {
      anchors.centerIn: parent
      width: Math.min(parent.width, Style.space(560))
      visible: !root.synced
      spacing: Style.space(16)
      Text {
        Layout.fillWidth: true
        horizontalAlignment: Text.AlignHCenter
        text: !root.lyrics || root.lyrics.status === "loading" ? "Looking for lyrics…"
          : (root.lyrics.status === "plain" ? "These lyrics aren’t timed" : "No lyrics for this song")
        color: root.fg
        font.family: Style.font.family
        font.bold: true
        font.pixelSize: Style.font.subtitle + 8
        wrapMode: Text.WordWrap
      }
      Text {
        Layout.fillWidth: true
        horizontalAlignment: Text.AlignHCenter
        text: "Karaoke needs timed lyrics. Another match often has them."
        color: root.fgDim
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        wrapMode: Text.WordWrap
      }
      Row {
        Layout.alignment: Qt.AlignHCenter
        spacing: Style.space(10)
        Chip { label: "Try another match"; on: true; tint: root.accent; onPicked: if (root.service) root.service.lyricsTryOther() }
        Chip { label: "Leave karaoke"; onPicked: root.exitRequested() }
      }
    }

    // Count-in before the first line and in long breaks.
    ColumnLayout {
      anchors.centerIn: parent
      width: parent.width
      visible: root.synced && root.countIn
      spacing: Style.space(26)
      Text {
        Layout.alignment: Qt.AlignHCenter
        text: root.cur < 0 ? "GET READY" : "INSTRUMENTAL"
        color: root.accent
        font.family: Style.font.family
        font.bold: true
        font.letterSpacing: 2
        font.pixelSize: Style.font.caption
      }
      Item {
        Layout.alignment: Qt.AlignHCenter
        Layout.preferredWidth: Style.space(root.narrow ? 120 : 170)
        Layout.preferredHeight: Layout.preferredWidth
        // Ring that empties towards the first word.
        Canvas {
          id: ring
          anchors.fill: parent
          readonly property real frac: {
            if (!root.countIn) return 0
            var total = root.cur >= 0 ? Math.max(1, Number(root.lines[root.upcoming].ms) - Number(root.lines[root.cur].ms))
              : Math.max(1, Number(root.lines[root.upcoming].ms))
            return Math.max(0, Math.min(1, root.untilNext / total))
          }
          onFracChanged: requestPaint()
          onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            var r = width / 2 - 4
            ctx.lineWidth = 4
            ctx.strokeStyle = Qt.rgba(1, 1, 1, 0.14)
            ctx.beginPath(); ctx.arc(width / 2, height / 2, r, 0, Math.PI * 2); ctx.stroke()
            ctx.strokeStyle = root.accent
            ctx.lineCap = "round"
            ctx.beginPath()
            ctx.arc(width / 2, height / 2, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * frac)
            ctx.stroke()
          }
        }
        Text {
          anchors.centerIn: parent
          text: root.untilNext > 5000 ? Api.formatTime(root.untilNext) : String(Math.ceil(root.untilNext / 1000))
          color: root.fg
          font.family: Style.font.family
          font.bold: true
          font.pixelSize: root.untilNext > 5000 ? Style.space(root.narrow ? 26 : 38) : Style.space(root.narrow ? 54 : 80)
        }
      }
      Row {
        Layout.alignment: Qt.AlignHCenter
        spacing: Style.space(12)
        Repeater {
          model: 3
          Rectangle {
            required property int index
            width: Style.space(12)
            height: width
            radius: width / 2
            // Light up 3, 2, 1 as the first word nears.
            color: root.untilNext <= (3 - index) * 1000 ? root.accent : Qt.rgba(1, 1, 1, 0.22)
            Behavior on color { ColorAnimation { duration: 200 } }
          }
        }
      }
      Text {
        Layout.alignment: Qt.AlignHCenter
        text: "Next line"
        color: root.fgDim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
      Text {
        Layout.fillWidth: true
        horizontalAlignment: Text.AlignHCenter
        text: root.wordsAt(root.upcoming)
        textFormat: Text.PlainText
        color: Qt.rgba(1, 1, 1, 0.8)
        font.family: Style.font.family
        font.bold: true
        font.pixelSize: Style.space(34) * root.sizeScale
        wrapMode: Text.WordWrap
      }
      Text {
        Layout.alignment: Qt.AlignHCenter
        visible: root.untilNext > 3000
        text: (root.cur < 0 ? "Intro" : "Break") + " · " + Api.formatTime(root.untilNext) + " to go · Space skips ahead"
        color: Qt.rgba(1, 1, 1, 0.45)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }

    // Singing: every sung line in one column that scrolls continuously.
    // The current line is full size and fills with colour; the others are
    // scaled down and faded by distance. On a line change the sizes glide
    // and the column eases up, so it moves like an animation, never a cut.
    ListView {
      id: lineView
      anchors.fill: parent
      visible: root.synced && !root.countIn
      clip: true
      interactive: false
      spacing: Style.space(18) * Math.max(0.6, root.sizeScale)
      model: root.sungLines
      cacheBuffer: 4000
      readonly property int currentPos: root.sungPos(root.focusLine)

      delegate: Item {
        id: lineItem
        required property var modelData
        required property int index
        readonly property int dist: index - lineView.currentPos
        readonly property bool isCurrent: dist === 0
        // Where the size is heading (used for wrapping, set once per line
        // change) and the size drawn this frame (animated).
        readonly property real targetSc: isCurrent ? 1.0 : (Math.abs(dist) === 1 ? 0.74 : 0.62)
        property real sc: targetSc
        Behavior on sc { NumberAnimation { duration: 480; easing.type: Easing.OutCubic } }
        property real fade: {
          if (isCurrent) return 1
          if (dist > 0 && !root.showNextLine) return 0
          if (dist === -1) return 0.32
          if (dist === 1) return 0.5
          if (Math.abs(dist) === 2) return dist < 0 ? 0.14 : 0.24
          return 0
        }
        Behavior on fade { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }

        width: ListView.view.width
        height: lineText.implicitHeight * sc
        readonly property real column: Math.min(ListView.view.width, Math.max(Style.space(480), ListView.view.width * 0.8))
        opacity: fade

        Text {
          id: lineText
          // Wrapped at the size it is heading to, so a long line does not
          // re-wrap on every frame of the animation.
          width: lineItem.column / lineItem.targetSc
          anchors.horizontalCenter: parent.horizontalCenter
          scale: lineItem.sc
          // Distance-field text scales smoothly; hinted glyphs would snap
          // to the pixel grid and shimmer while the size animates.
          renderType: Text.QtRendering
          transformOrigin: Item.Top
          horizontalAlignment: Text.AlignHCenter
          text: lineItem.modelData.text
          textFormat: Text.PlainText
          color: lineItem.isCurrent ? Qt.rgba(1, 1, 1, 0.78) : root.fg
          font.family: Style.font.family
          font.bold: true
          font.pixelSize: Style.space(46) * root.sizeScale
          lineHeight: 1.06
          wrapMode: Text.WordWrap

          // Where each wrapped row sits, collected as the text is laid out,
          // so the fill can run in reading order: the first row fills from
          // left to right, then the next one, and so on.
          property var rows: []
          property var rowsBuild: []
          onLineLaidOut: function(line) {
            if (line.number === 0) rowsBuild = []
            rowsBuild.push({ y: line.y, h: line.height, w: line.implicitWidth })
            if (line.isLast) { rows = rowsBuild; rowsBuild = [] }
          }
          readonly property real totalRowWidth: {
            var t = 0
            for (var i = 0; i < rows.length; i++) t += rows[i].w
            return t
          }
          readonly property real fillPx: totalRowWidth * (root.inBreak ? 0 : root.liveProgress)

          // The part already sung, in the cover colour: one clip per row.
          Repeater {
            model: lineItem.isCurrent ? lineText.rows : []
            delegate: Item {
              id: rowFill
              required property var modelData
              required property int index
              readonly property real before: {
                var t = 0
                for (var i = 0; i < index; i++) t += lineText.rows[i].w
                return t
              }
              x: (lineText.width - modelData.w) / 2
              y: modelData.y
              width: Math.max(0, Math.min(modelData.w, lineText.fillPx - before))
              height: modelData.h
              clip: true
              Text {
                x: -rowFill.x
                y: -rowFill.y
                width: lineText.width
                horizontalAlignment: Text.AlignHCenter
                text: lineText.text
                textFormat: Text.PlainText
                color: Qt.lighter(root.accent, 1.12)
                renderType: Text.QtRendering
                font: lineText.font
                lineHeight: lineText.lineHeight
                wrapMode: Text.WordWrap
              }
            }
          }
        }
      }

      // Ease the column so the current line sits in the middle, every frame:
      // it follows the sizes as they animate instead of jumping to them.
      FrameAnimation {
        running: lineView.visible && root.active
        onTriggered: {
          var item = lineView.itemAtIndex(lineView.currentPos)
          if (!item) { lineView.positionViewAtIndex(Math.max(0, lineView.currentPos), ListView.Center); return }
          var target = item.y + item.height / 2 - lineView.height / 2
          var d = target - lineView.contentY
          lineView.contentY = Math.abs(d) < 0.5 ? target : lineView.contentY + d * Math.min(1, frameTime * 7)
        }
      }
    }
  }

  // ---- bottom: transport, progress with line marks, keys ----
  ColumnLayout {
    id: bottomBlock
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.margins: Style.space(22)
    spacing: Style.space(12)

    Row {
      Layout.alignment: Qt.AlignHCenter
      spacing: Style.space(16)
      FlatButton {
        anchors.verticalCenter: parent.verticalCenter
        iconText: "\u{f04ae}"
        iconSize: Style.font.iconLarge
        foreground: root.fg
        accent: root.accent
        tooltipText: "Previous (P)"
        onClicked: root.service && root.service.previous()
      }
      FlatButton {
        anchors.verticalCenter: parent.verticalCenter
        primary: true
        buttonSize: Style.space(56)
        iconSize: Style.font.iconLarge
        accent: root.accent
        onAccent: root.onAccent
        iconText: root.service && root.service.effectivePlaying ? "\u{f03e4}" : "\u{f040a}"
        tooltipText: "Play / pause (Space)"
        onClicked: root.service && root.service.togglePlayback()
      }
      FlatButton {
        anchors.verticalCenter: parent.verticalCenter
        iconText: "\u{f04ad}"
        iconSize: Style.font.iconLarge
        foreground: root.fg
        accent: root.accent
        tooltipText: "Next (N)"
        onClicked: root.service && root.service.next()
      }
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(12)
      Text {
        text: Api.formatTime(root.service ? root.service.positionMs : 0)
        color: root.fgDim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
      Item {
        Layout.fillWidth: true
        implicitHeight: seekSlider.implicitHeight
        PanelSlider {
          id: seekSlider
          anchors.fill: parent
          minimum: 0
          maximum: Math.max(1, root.service ? root.service.durationMs : 1)
          value: root.service ? root.service.positionMs : 0
          fillColor: root.accent
          knobColor: Qt.lighter(root.accent, 1.15)
          trackColor: Qt.rgba(1, 1, 1, 0.14)
          onMoved: function(v) { if (root.service) root.service.seek(v) }
        }
        // Where each sung line starts.
        Repeater {
          model: root.synced && root.service && root.service.durationMs > 0 ? root.lines : []
          delegate: Rectangle {
            required property var modelData
            visible: String(modelData.text || "").trim() !== ""
            x: seekSlider.knobSize / 2 + (seekSlider.width - seekSlider.knobSize)
               * Math.min(1, Math.max(0, (Number(modelData.ms) + clock.offsetMs) / root.service.durationMs)) - 1
            anchors.verticalCenter: parent.verticalCenter
            width: 2
            height: Style.space(10)
            radius: 1
            color: Qt.rgba(1, 1, 1, 0.22)
          }
        }
      }
      Text {
        text: Api.formatTime(root.service ? root.service.durationMs : 0)
        color: root.fgDim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }

    Text {
      Layout.fillWidth: true
      visible: !root.narrow
      horizontalAlignment: Text.AlignHCenter
      text: "Space pause · ← → previous / next line · ↑ ↓ volume · [ ] timing · T another match · K or Esc leave"
      color: Qt.rgba(1, 1, 1, 0.42)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  // ---- settings sheet (gear) ----
  component Seg: Rectangle {
    id: seg
    property var options: []      // [{ key, label }]
    property string current: ""
    property color accent: "#ffffff"
    property color textOnAccent: "#000000"
    signal picked(string key)
    implicitHeight: Style.space(38)
    radius: Style.space(12)
    color: Qt.rgba(0, 0, 0, 0.3)
    Row {
      anchors.fill: parent
      anchors.margins: Style.space(3)
      spacing: Style.space(2)
      Repeater {
        model: seg.options
        delegate: Rectangle {
          id: segCell
          required property var modelData
          readonly property bool picked: seg.current === modelData.key
          width: (parent.width - (seg.options.length - 1) * parent.spacing) / Math.max(1, seg.options.length)
          height: parent.height
          radius: Style.space(9)
          color: picked ? seg.accent : (segArea.containsMouse ? Qt.rgba(1, 1, 1, 0.08) : "transparent")
          Text {
            anchors.centerIn: parent
            text: segCell.modelData.label
            color: segCell.picked ? seg.textOnAccent : "#f4efe9"
            font.family: Style.font.family
            font.bold: segCell.picked
            font.pixelSize: Style.font.caption
          }
          MouseArea {
            id: segArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: seg.picked(segCell.modelData.key)
          }
        }
      }
    }
  }
  component KSwitch: RowLayout {
    id: sw
    property string label: ""
    property bool checked: false
    property color accent: "#ffffff"
    signal toggled()
    spacing: Style.space(10)
    Text {
      Layout.fillWidth: true
      text: sw.label
      color: "#f4efe9"
      font.family: Style.font.family
      font.pixelSize: Style.font.caption + 1
    }
    Rectangle {
      implicitWidth: Style.space(40)
      implicitHeight: Style.space(22)
      radius: height / 2
      color: sw.checked ? sw.accent : Qt.rgba(1, 1, 1, 0.18)
      Rectangle {
        width: Style.space(16)
        height: width
        radius: width / 2
        y: Style.space(3)
        x: sw.checked ? parent.width - width - Style.space(3) : Style.space(3)
        color: sw.checked ? "#1a1416" : "#f4efe9"
        Behavior on x { NumberAnimation { duration: 140 } }
      }
      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: sw.toggled()
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    visible: root.settingsOpen
    z: 19
    onClicked: root.settingsOpen = false
  }
  Rectangle {
    id: sheet
    visible: root.settingsOpen
    z: 20
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.margins: Style.space(18)
    width: Math.min(parent.width - Style.space(36), Style.space(380))
    radius: Style.space(18)
    color: Qt.rgba(0.11, 0.07, 0.09, 0.92)
    border.width: 1
    border.color: Qt.rgba(1, 1, 1, 0.08)
    MouseArea { anchors.fill: parent }

    Flickable {
      anchors.fill: parent
      anchors.margins: Style.space(20)
      contentHeight: sheetCol.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds

      ColumnLayout {
        id: sheetCol
        width: parent.width
        spacing: Style.space(18)

        RowLayout {
          Layout.fillWidth: true
          Text { text: "\u{f05cb}"; color: root.accent; font.family: Style.font.family; font.pixelSize: Style.font.icon + 2 }
          Text { Layout.fillWidth: true; text: "Karaoke"; color: root.fg; font.family: Style.font.family; font.bold: true; font.pixelSize: Style.font.subtitle }
          FlatButton {
            buttonSize: Style.space(30)
            iconText: "\u{f0156}"
            foreground: root.fg
            accent: root.accent
            tooltipText: "Close"
            onClicked: root.settingsOpen = false
          }
        }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)
          Text { text: "LYRICS"; color: root.fgDim; font.family: Style.font.family; font.bold: true; font.letterSpacing: 1; font.pixelSize: Style.font.caption }
          Chip {
            Layout.fillWidth: true
            on: true
            tint: root.accent
            label: (sourceText.sourceText !== "" ? sourceText.sourceText : "Lyrics") + "  \u{f0140}"
            onPicked: {
              karaokeMenu.y = sourceChip.height + Style.space(6)
              karaokeMenu.open()
            }
          }
          Chip {
            Layout.fillWidth: true
            label: "Wrong song? Try another match"
            onPicked: if (root.service) root.service.lyricsTryOther()
          }
        }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)
          Text { text: "TEXT SIZE"; color: root.fgDim; font.family: Style.font.family; font.bold: true; font.letterSpacing: 1; font.pixelSize: Style.font.caption }
          Seg {
            Layout.fillWidth: true
            accent: root.accent
            textOnAccent: root.onAccent
            options: [{ key: "small", label: "S" }, { key: "medium", label: "M" }, { key: "large", label: "L" }, { key: "huge", label: "XL" }]
            current: root.textSize
            onPicked: function(key) { root.sizePicked(key) }
          }
        }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)
          Text { text: "TIMING"; color: root.fgDim; font.family: Style.font.family; font.bold: true; font.letterSpacing: 1; font.pixelSize: Style.font.caption }
          RowLayout {
            Layout.fillWidth: true
            Chip { label: "\u2212"; onPicked: root.nudge(-250) }
            Text {
              Layout.fillWidth: true
              horizontalAlignment: Text.AlignHCenter
              text: (clock.offsetMs > 0 ? "+" : clock.offsetMs < 0 ? "\u2212" : "") + (Math.abs(clock.offsetMs) / 1000).toFixed(2) + " s"
              color: root.fg
              font.family: Style.font.family
              font.bold: true
              font.pixelSize: Style.font.body + 1
            }
            Chip { label: "+"; onPicked: root.nudge(250) }
          }
          Text {
            Layout.fillWidth: true
            text: "Same offset as the lyrics page. [ and ] while singing."
            color: root.fgDim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(12)
          Text { text: "SHOW"; color: root.fgDim; font.family: Style.font.family; font.bold: true; font.letterSpacing: 1; font.pixelSize: Style.font.caption }
          KSwitch {
            Layout.fillWidth: true
            label: "Next line"
            accent: root.accent
            checked: root.showNextLine
            onToggled: root.showNextLine = !root.showNextLine
          }
          KSwitch {
            Layout.fillWidth: true
            label: "Count-in before verses"
            accent: root.accent
            checked: root.countInEnabled
            onToggled: root.countInEnabled = !root.countInEnabled
          }
          KSwitch {
            Layout.fillWidth: true
            label: "Open the video window behind"
            accent: root.accent
            checked: !!(root.service && root.service.videoActive)
            onToggled: {
              if (!root.service || !root.service.hasTrack) return
              if (root.service.videoActive) root.service.hideVideo()
              else root.service.showVideo("")
            }
          }
        }
      }
    }
  }
}
