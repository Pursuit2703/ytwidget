import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Ui
import qs.Commons

import "Api.js" as Api

BarWidget {
  id: root
  moduleName: "omar.ytwidget"

  // bar.shell.serviceFor() reliably returned null here (a third-party bar
  // widget looking up its own service through the host's scoped facade), so
  // this widget holds its own direct connection to the backend instead of
  // depending on that lookup — see PlayerConnection.qml for why that's safe.
  readonly property var ytService: conn
  PlayerConnection { id: conn }

  readonly property bool hasTrack: !!(ytService && ytService.hasTrack)
  // While the video window is open, the audio deck is deliberately paused
  // (they'd otherwise both play sound) — so "playing" has to come from the
  // video window's own mpv state, not the deck's, or the mini player reads
  // as paused/idle the whole time a video is actually up and playing.
  readonly property bool playing: !!(ytService &&
    (ytService.videoActive ? ytService.videoPlaying : ytService.playing))
  readonly property string title: ytService ? ytService.trackTitle : ""
  readonly property string artist: ytService ? ytService.trackArtist : ""
  // Tighter than before so the chip stays compact now that the waveform
  // shares the row; still overridable per-widget via the maxWidth setting.
  readonly property real maxLabelWidth: Style.space(Math.max(90, Number(root.setting("maxWidth", 150)) || 150))
  readonly property string playIcon: playing ? "\u{f03e4}" : "\u{f040a}"
  // Plain ASCII, not a nerd-font codepoint: guaranteed to render in any font,
  // no tofu risk. Used both as the idle glyph and the art placeholder.
  readonly property string idleGlyph: "YT"

  // Ambient full-bar spectrum. Off by default: it paints across the whole
  // screen width, which is a bigger change to someone's desktop than a bar
  // widget has any business making uninvited.
  readonly property bool ambientEnabled: String(root.setting("ambientWave", "false")) === "true"
  readonly property real ambientOpacity: Math.max(0, Math.min(1,
    Number(root.setting("ambientOpacity", 0.55)) || 0.55))
  readonly property real ambientHeight: Math.max(0.1, Math.min(1,
    Number(root.setting("ambientHeight", 0.40)) || 0.40))

  property bool popupOpen: false
  property string miniSearchText: ""
  property var miniSearchResults: []
  property int miniSelected: 0
  property bool miniSearching: false
  property bool miniQueueOpen: false
  // The EQ section is opt-in: the mini player is a now-playing card first,
  // and ten sliders is not what you want to see every time it opens.
  property bool miniEqOpen: false

  visible: true
  implicitWidth: row.implicitWidth + Style.space(14)
  implicitHeight: barSize

  // PopupCard opens a separate popup surface — nothing inside it gets
  // keyboard focus automatically. Same fix SearchableDropdown/go-prompt use.
  // A short delay (not Qt.callLater, which fires next tick) gives the
  // HyprlandFocusGrab time to actually establish the compositor-level
  // keyboard grab before we ask Qt for active focus — otherwise the field
  // can look focused (blinking cursor) while keystrokes never arrive.
  onPopupOpenChanged: {
    if (!popupOpen) return
    focusFieldTimer.start()
    // Opening this card is a good predictor that the video button is about to
    // be pressed; resolving now means the click costs no extraction.
    if (ytService && ytService.hasTrack && !ytService.videoReady) ytService.prepareVideo("")
  }

  Timer {
    id: focusFieldTimer
    interval: 60
    repeat: false
    onTriggered: if (miniSearchField) miniSearchField.forceActiveFocus()
  }

  // PopupCard.close() does `owner.close()` if the owner has one, else it
  // directly sets its own `open` property — which permanently breaks the
  // one-way `open: root.popupOpen` binding below (QML destroys a binding
  // the moment its target is assigned directly). Without this function,
  // the very first outside-click dismissal kills the binding for good and
  // the popup can never be reopened again.
  function close() { popupOpen = false }

  function openFullPlayer() {
    popupOpen = false
    toggleProcess.running = false
    toggleProcess.command = ["/usr/bin/omarchy-shell", "shell", "toggle", moduleName, "{}"]
    toggleProcess.running = true
  }

  function runMiniSearch(playFirstWhenDone) {
    if (!miniSearchText.trim()) { miniSearchResults = []; miniSelected = 0; return }
    if (!ytService) return
    miniSearching = true
    ytService.search(miniSearchText.trim(), 6, function(ok, result) {
      miniSearching = false
      miniSearchResults = ok && result ? (result.items || []) : []
      miniSelected = 0
      if (playFirstWhenDone && miniSearchResults.length > 0)
        root.playSelectedResult()
    })
  }

  // Enter plays whatever row is selected (the first one by default), so a
  // search is type-then-Enter. Arrow keys move the selection.
  function playSelectedResult() {
    if (!ytService || miniSearchResults.length === 0) return
    var i = Math.max(0, Math.min(miniSelected, miniSearchResults.length - 1))
    ytService.playNow(miniSearchResults[i])
  }

  readonly property bool miniSearchIsLink: Api.isYouTubeLink(miniSearchText)

  // Settings declared in manifest.json only reach the daemon if something
  // pushes them. Do it every time the connection comes up: the daemon is
  // shared and outlives any one surface, so it may be carrying whatever the
  // last client set rather than this widget's configuration.
  function pushSettings() {
    if (!ytService) return
    var fade = Number(root.setting("crossfadeMs", 500))
    ytService.setCrossfadeMs(isFinite(fade) ? Math.max(0, Math.min(3000, fade)) : 500)
    var idle = Number(root.setting("idleShutdownMinutes", 15))
    ytService.setIdleMinutes(isFinite(idle) ? Math.max(0, Math.min(1440, idle)) : 15)
    ytService.setSubtitleLang(String(root.setting("subtitleLang", "en") || "en"))
    var q = Number(root.setting("videoQuality", 1080))
    ytService.setVideoDefaults(isFinite(q) ? Math.max(144, Math.min(2160, q)) : 1080,
                               Math.max(20, Math.min(100, Number(root.setting("videoWindowPercent", 70)) || 70)),
                               String(root.setting("videoGpu", "integrated") || "integrated"))
  }

  Connections {
    target: root.ytService
    function onBackendReadyChanged() {
      if (root.ytService && root.ytService.backendReady) root.pushSettings()
    }
  }

  function toggleVideo() {
    if (!ytService || !ytService.hasTrack) return
    if (ytService.videoActive) ytService.hideVideo()
    else ytService.showVideo("")
  }

  function openMiniLink() {
    var link = root.miniSearchText.trim()
    if (!link || !ytService) return
    miniSearching = true
    ytService.openLink(link, function(ok) {
      miniSearching = false
      if (!ok) return
      root.miniSearchResults = []
      root.miniSearchText = ""
      root.miniQueueOpen = true
    })
  }

  function moveMiniSelection(delta) {
    if (miniSearchResults.length === 0) return
    miniSelected = Math.max(0, Math.min(miniSelected + delta,
                                        miniSearchResults.length - 1))
  }

  Process {
    id: toggleProcess
    running: false
  }

  // Tracks whether the pointer is anywhere over the pill, independent of the
  // transport buttons' own MouseAreas on top of it. A plain MouseArea here
  // would have its containsMouse flip false whenever the cursor sits over an
  // overlapping child MouseArea (the buttons), flickering the controls/
  // waveform crossfade as the pointer moves across them — HoverHandler
  // doesn't have that "topmost claims hover" limitation.
  HoverHandler {
    id: pillHover
  }

  Rectangle {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.topMargin: 2
    anchors.bottomMargin: 2
    z: -1
    radius: height / 2
    color: Qt.rgba(0, 0, 0, 0)
    // No outline at rest — the waveform and title carry the chip on their own,
    // and a permanent ring around them just boxes in an otherwise open bar.
    // It fades in only while hovered, where it does real work: showing the
    // hit area of the transport controls that have just swapped in.
    border.width: Style.normalBorderWidth
    border.color: Qt.rgba(root.bar.barForeground.r, root.bar.barForeground.g, root.bar.barForeground.b,
      pillHover.hovered ? 0.30 : 0.0)
    visible: !root.bar.vertical

    Behavior on border.color { ColorAnimation { duration: 120 } }
  }

  Row {
    id: row
    // Sit above the click-to-open MouseArea below so the transport buttons
    // get first claim on clicks landing on them (same trick omamusic uses:
    // its inline bar buttons set z:1 over the chip's own click handler).
    z: 1
    anchors.centerIn: parent
    spacing: Style.space(4)

    // Controls and waveform occupy the exact same slot, crossfading on pill
    // hover — prev/pause/next on top while hovered, the live waveform
    // underneath otherwise. The slot is sized to fit whichever is wider so
    // the pill never resizes when it swaps.
    Item {
      id: mediaSlot
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(controlsRow.width, waveform.width)
      height: root.barSize

      Row {
        id: controlsRow
        anchors.centerIn: parent
        spacing: Style.space(4)
        enabled: pillHover.hovered
        opacity: pillHover.hovered ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 120 } }

        WidgetButton {
          id: prevButton
          bar: root.bar
          text: "\u{f04ae}"
          fontSize: Style.font.bodySmall
          foreground: root.bar.barForeground
          fixedWidth: Style.space(20)
          fixedHeight: root.barSize
          tooltipText: "Previous"
          onPressed: function(mouseButton) {
            if (mouseButton === Qt.LeftButton && root.ytService) root.ytService.previous()
          }
        }
        WidgetButton {
          id: playButton
          bar: root.bar
          text: root.hasTrack ? root.playIcon : "󰝚"
          fontSize: Style.font.bodySmall
          foreground: root.bar.barForeground
          fixedWidth: Style.space(20)
          fixedHeight: root.barSize
          tooltipText: root.hasTrack ? (root.playing ? "Pause" : "Play") : "Nothing playing"
          onPressed: function(mouseButton) {
            if (mouseButton === Qt.LeftButton && root.ytService) root.ytService.togglePlayback()
          }
        }
        WidgetButton {
          id: nextButton
          bar: root.bar
          text: "\u{f04ad}"
          fontSize: Style.font.bodySmall
          foreground: root.bar.barForeground
          fixedWidth: Style.space(20)
          fixedHeight: root.barSize
          tooltipText: "Next"
          onPressed: function(mouseButton) {
            if (mouseButton === Qt.LeftButton && root.ytService) root.ytService.next()
          }
        }
      }

      BarWave {
        id: waveform
        anchors.centerIn: parent
        visible: root.hasTrack && !root.bar.vertical
        opacity: pillHover.hovered ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: 120 } }
        levels: root.ytService ? root.ytService.spectrumBands : []
        color: root.bar.barForeground
        // The pill insets 2 units top and bottom, so the tallest a bar can go
        // on a 26 unit bar is about 20 — 0.66 leaves a little air at the peaks
        // instead of letting them touch the border.
        maxHeight: Math.max(Style.space(14), root.barSize * 0.66)
      }
    }

    // Scrolling title. Two copies separated by a gap, scrolled by exactly
    // one copy-plus-gap, so the second lands where the first started and the
    // loop is seamless with no visible jump.
    //
    // The earlier marquee here left a stray glyph in the bar. The guards that
    // prevent that: a hard clip, a width that can never go negative or zero,
    // scrolling only when the text genuinely overflows, and x reset to 0
    // whenever it stops — so a partial frame can't be left parked on screen.
    Item {
      id: marquee
      anchors.verticalCenter: parent.verticalCenter
      visible: !root.bar.vertical
      clip: true
      height: titleA.implicitHeight
      width: Math.max(0, Math.min(root.maxLabelWidth, titleA.implicitWidth))

      readonly property string fullText: root.hasTrack
        ? Api.barTrackText(root.title, root.artist, true, true)
        : "Nothing playing"
      readonly property real gapPx: Style.space(28)
      readonly property bool overflowing: titleA.implicitWidth > width + 1

      Row {
        id: ticker
        spacing: marquee.gapPx

        Text {
          id: titleA
          textFormat: Text.PlainText
          text: marquee.fullText
          color: root.hasTrack && root.playing
            ? root.bar.barForeground : Qt.darker(root.bar.barForeground, 1.5)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
        }
        Text {
          textFormat: Text.PlainText
          visible: marquee.overflowing
          text: marquee.fullText
          color: titleA.color
          font.family: titleA.font.family
          font.pixelSize: titleA.font.pixelSize
        }
      }

      NumberAnimation {
        id: scrollAnim
        target: ticker
        property: "x"
        running: marquee.overflowing && marquee.visible
        loops: Animation.Infinite
        from: 0
        to: -(titleA.implicitWidth + marquee.gapPx)
        duration: Math.max(4000, (titleA.implicitWidth + marquee.gapPx) * 22)
        onRunningChanged: if (!running) ticker.x = 0
      }
    }
  }

  MouseArea {
    id: mouseArea
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

    onClicked: function(mouse) {
      if (mouse.button === Qt.MiddleButton) {
        if (root.ytService) root.ytService.previous()
      } else if (mouse.button === Qt.RightButton) {
        if (root.ytService) root.ytService.next()
      } else {
        root.popupOpen = !root.popupOpen
      }
    }
    onWheel: function(wheel) {
      if (!root.ytService) return
      var delta = wheel.angleDelta.y > 0 ? 5 : -5
      root.ytService.setVolume(Math.max(0, Math.min(100, root.ytService.volume + delta)))
    }
    onEntered: if (root.bar) root.bar.showTooltip(root,
      root.hasTrack ? (root.title + (root.artist ? " — " + root.artist : "")) : "Nothing playing")
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  // Where the bar is actually empty.
  //
  // The strip behind the bar has no way to ask for this: island-bar's IPC
  // exposes only syncHidden(), and the PluginBarApi facade handed to widgets
  // carries scalars alone — barSize, colours, position — with no island
  // geometry on it. But that same facade notes it "cannot isolate a visual
  // child from the parent hierarchy of the QML scene that renders it", and
  // that is the way in: this widget really is an item inside the bar's own
  // tree, so it can walk up to the bar's root and measure what is drawn.
  //
  // Occupancy is taken from the leaves — the items with no visible children,
  // i.e. the text and icons that actually paint — rather than from the three
  // island hosts. Leaves are what "empty" is really about, and reading them
  // needs no knowledge of how island-bar names or nests its containers, so a
  // layout change degrades to a wrong-ish gap rather than a broken binding.
  property var ambientGaps: []

  readonly property real ambientGapPad: Style.space(10)
  readonly property real ambientMinGap: Style.space(40)

  function barRootItem() {
    var node = root
    var guard = 0
    while (node && node.parent && guard < 64) {
      node = node.parent
      guard++
    }
    return node
  }

  // Only things that actually put ink on the bar count as occupied. The first
  // attempt at this treated any childless item as occupied, which handed the
  // whole width over to a bar-wide MouseArea and left no gaps at all.
  function paintsInk(item) {
    if (item.opacity !== undefined && item.opacity <= 0.02) return false
    if (item.text !== undefined && String(item.text).length > 0) return true
    if (item.source !== undefined && String(item.source).length > 0) return true
    var c = item.color
    if (c !== undefined && c !== null && c.a !== undefined && c.a > 0.05) return true
    var b = item.border
    if (b !== undefined && b !== null && b.width > 0
        && b.color !== undefined && b.color !== null && b.color.a > 0.05) return true
    return false
  }

  // Spans are clamped to whatever clips them on the way down.
  //
  // Without this the scrolling title wrecks the result: the marquee's Text is
  // far wider than the window it shows through and slides continuously, so its
  // measured span crawls leftwards and drags the gap edge with it, popping
  // bars off one at a time. Intersecting with each clipping ancestor gives the
  // span you can actually see, which for a marquee is a fixed window.
  function collectOccupied(item, out, depth, clipLo, clipHi) {
    if (!item || depth > 24) return
    if (!item.visible || !(item.width > 0) || !(item.height > 0)) return
    if (clipHi <= clipLo) return

    var at = item.mapToItem(null, 0, 0)
    if (!at) return
    var lo = at.x
    var hi = at.x + item.width

    if (root.paintsInk(item)) {
      var vlo = Math.max(lo, clipLo)
      var vhi = Math.min(hi, clipHi)
      if (vhi > vlo) out.push([vlo, vhi])
    }

    var nextLo = clipLo
    var nextHi = clipHi
    if (item.clip) {
      nextLo = Math.max(clipLo, lo)
      nextHi = Math.min(clipHi, hi)
    }

    var kids = item.children || []
    for (var i = 0; i < kids.length; i++)
      root.collectOccupied(kids[i], out, depth + 1, nextLo, nextHi)
  }

  function recomputeAmbientGaps() {
    if (!ambientEnabled) return
    var barItem = barRootItem()
    if (!barItem || !(barItem.width > 0)) { ambientGaps = []; return }

    var spans = []
    collectOccupied(barItem, spans, 0, 0, barItem.width)
    if (spans.length === 0) { ambientGaps = [[0, barItem.width]]; return }

    spans.sort(function(a, b) { return a[0] - b[0] })

    // Merge, padded, so two glyphs a few pixels apart do not leave a sliver
    // of spectrum stranded between them.
    var merged = []
    var curLo = spans[0][0] - ambientGapPad
    var curHi = spans[0][1] + ambientGapPad
    for (var i = 1; i < spans.length; i++) {
      var lo = spans[i][0] - ambientGapPad
      var hi = spans[i][1] + ambientGapPad
      if (lo <= curHi) {
        if (hi > curHi) curHi = hi
      } else {
        merged.push([curLo, curHi])
        curLo = lo
        curHi = hi
      }
    }
    merged.push([curLo, curHi])

    // The complement is what is left over.
    var gaps = []
    var cursor = 0
    for (var m = 0; m < merged.length; m++) {
      var start = Math.max(0, merged[m][0])
      if (start - cursor >= ambientMinGap) gaps.push([cursor, start])
      cursor = Math.max(cursor, merged[m][1])
    }
    if (barItem.width - cursor >= ambientMinGap) gaps.push([cursor, barItem.width])

    // Ignore sub-pixel reflow (a clock digit changing width, say) so bars are
    // not switched on and off for a change nobody can see.
    var prev = root.ambientGaps
    if (prev && prev.length === gaps.length) {
      var same = true
      for (var q = 0; q < gaps.length; q++) {
        if (Math.abs(prev[q][0] - gaps[q][0]) > 2 || Math.abs(prev[q][1] - gaps[q][1]) > 2) {
          same = false
          break
        }
      }
      if (same) return
    }
    ambientGaps = gaps
  }

  // The bar's contents resize constantly — a scrolling title, a ticking
  // clock — so this is re-measured on a timer rather than hooked to any one
  // widget's geometry. Cheap: a few hundred item reads, four times a second.
  Timer {
    interval: 250
    repeat: true
    running: root.ambientEnabled
    triggeredOnStart: true
    onTriggered: root.recomputeAmbientGaps()
  }

  // The ambient spectrum behind the bar.
  //
  // WlrLayer.Bottom puts it above the wallpaper and below the bar, and the
  // bar's exclusive zone means no ordinary window is ever in that strip, so
  // it cannot be covered. exclusionMode Ignore is essential: reserving space
  // of its own would push every window down by a second bar's height.
  //
  // It fades out whenever nothing is playing, so an idle machine looks
  // exactly as it did before this existed.
  PanelWindow {
    id: ambient
    visible: root.ambientEnabled && !!root.bar && !root.bar.vertical
    anchors { top: true; left: true; right: true }
    implicitHeight: root.barSize
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omar-ytwidget-ambient"
    WlrLayershell.layer: WlrLayer.Bottom
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    AmbientWave {
      anchors.fill: parent
      levels: root.ytService ? root.ytService.spectrumBands : []
      color: root.bar ? root.bar.barForeground : "white"
      heightFraction: root.ambientHeight
      gaps: root.ambientGaps
      opacity: root.hasTrack && root.playing ? root.ambientOpacity : 0
      Behavior on opacity { NumberAnimation { duration: 420; easing.type: Easing.OutQuad } }
    }
  }

  // PopupCard (a HyprlandFocusGrab-based popup) never reliably delivered
  // keyboard input to the search field here — sometimes a blinking cursor
  // with no characters landing, only "working" after the window lost and
  // regained focus. go-prompt (omar.go-prompt/GoPrompt.qml), a plugin on
  // this same system whose text input demonstrably works, uses a real
  // WlrLayershell surface with Exclusive keyboard focus instead of a
  // Hyprland focus grab — so this popup is built the same way.
  PanelWindow {
    id: popup
    visible: root.popupOpen
    // Full-screen + transparent, same trick go-prompt uses: a background
    // MouseArea catches outside clicks to dismiss, while the actual card
    // is just anchored to a corner of it. PanelWindow has no usable
    // focus-loss signal in this Quickshell version to hang dismiss off
    // of instead.
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omar-ytwidget-popup"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    MouseArea {
      anchors.fill: parent
      onClicked: root.popupOpen = false
    }

    BorderSurface {
      id: card
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.topMargin: Style.gapsOut
      anchors.rightMargin: Style.gapsOut
      width: Style.space(320)
      height: column.implicitHeight + contentTopInset + contentBottomInset
      radius: Style.cornerRadius
      color: Color.popups.background
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
      padding: Style.spacing.panelPadding

    MouseArea {
      // Swallow clicks so they don't fall through to the dismiss area above.
      anchors.fill: parent
      onClicked: {}
    }

    FocusScope {
      anchors.fill: parent
      anchors.topMargin: card.contentTopInset
      anchors.rightMargin: card.contentRightInset
      anchors.bottomMargin: card.contentBottomInset
      anchors.leftMargin: card.contentLeftInset
      focus: true
      Keys.onEscapePressed: root.popupOpen = false

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(10)

      Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        width: Style.space(96)
        height: Style.space(96)
        radius: Style.cornerRadius
        color: Qt.rgba(root.bar.barForeground.r, root.bar.barForeground.g, root.bar.barForeground.b, 0.06)
        clip: true

        Image {
          anchors.fill: parent
          visible: root.ytService && root.ytService.trackThumbnail !== ""
          source: root.ytService ? root.ytService.trackThumbnail : ""
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
        }
        Text {
          anchors.centerIn: parent
          visible: !root.ytService || root.ytService.trackThumbnail === ""
          text: root.idleGlyph
          color: root.bar.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.displayLarge
        }

        // Click the artwork to toggle play/pause of the current track.
        MouseArea {
          anchors.fill: parent
          enabled: root.hasTrack
          cursorShape: root.hasTrack ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: root.ytService && root.ytService.togglePlayback()
        }
      }

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        textFormat: Text.PlainText
        text: root.hasTrack ? root.title : "Nothing playing"
        color: root.bar.foreground
        font.family: Style.font.family
        font.bold: true
        font.pixelSize: Style.font.subtitle
        elide: Text.ElideRight

        MouseArea {
          anchors.fill: parent
          enabled: root.hasTrack
          cursorShape: root.hasTrack ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: root.ytService && root.ytService.togglePlayback()
        }
      }
      Text {
        width: parent.width
        visible: root.artist !== ""
        horizontalAlignment: Text.AlignHCenter
        textFormat: Text.PlainText
        text: root.artist
        color: Qt.darker(root.bar.foreground, 1.4)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      ColumnLayout {
        width: parent.width
        spacing: Style.space(2)

        PanelSlider {
          Layout.fillWidth: true
          minimum: 0
          maximum: Math.max(1, root.ytService ? root.ytService.durationMs : 1)
          value: root.ytService ? root.ytService.positionMs : 0
          onMoved: function(v) { if (root.ytService) root.ytService.seek(v) }
        }
        RowLayout {
          Layout.fillWidth: true
          Text {
            text: Api.formatTime(root.ytService ? root.ytService.positionMs : 0)
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          Item { Layout.fillWidth: true }
          Text {
            text: Api.formatTime(root.ytService ? root.ytService.durationMs : 0)
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }

      // Playback transport only. The view toggles used to share this row,
      // which pushed it to 304 units inside a ~276 unit content box — that is
      // what clipped the outer buttons against the card edge.
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(8)

        Chicklet {
          iconText: "󰒟"
          selected: !!(root.ytService && root.ytService.shuffle)
          foreground: root.bar.foreground
          tooltipText: "Shuffle"
          onClicked: root.ytService && root.ytService.setShuffle(!root.ytService.shuffle)
        }
        Chicklet {
          iconText: "󰒮"
          foreground: root.bar.foreground
          tooltipText: "Previous"
          onClicked: root.ytService && root.ytService.previous()
        }
        Chicklet {
          iconText: root.playing ? "\u{f03e4}" : "\u{f040a}"
          chickletSize: Style.space(38)
          iconSize: Style.font.iconLarge
          foreground: root.bar.foreground
          tooltipText: root.playing ? "Pause" : "Play"
          onClicked: root.ytService && root.ytService.togglePlayback()
        }
        Chicklet {
          iconText: "󰒭"
          foreground: root.bar.foreground
          tooltipText: "Next"
          onClicked: root.ytService && root.ytService.next()
        }
        Chicklet {
          iconText: root.ytService && root.ytService.repeat === "track" ? "󰑘" : "󰑖"
          selected: root.ytService && root.ytService.repeat !== "off"
          foreground: root.bar.foreground
          tooltipText: "Repeat"
          onClicked: root.ytService && root.ytService.cycleRepeat()
        }
      }

      RowLayout {
        width: parent.width
        spacing: Style.space(8)

        Text {
          text: "VOL"
          color: Qt.darker(root.bar.foreground, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        PanelSlider {
          Layout.fillWidth: true
          minimum: 0
          maximum: 100
          value: root.ytService ? root.ytService.volume : 80
          onMoved: function(v) { if (root.ytService) root.ytService.setVolume(v) }
        }
        Text {
          text: (root.ytService ? root.ytService.volume : 80) + "%"
          color: Qt.darker(root.bar.foreground, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      PanelSeparator { width: parent.width; foreground: root.bar.foreground }

      // View toggles, sitting directly above the sections they reveal so the
      // cause and its effect are next to each other. Kept apart from the
      // transport row above: those act on playback, these only change what
      // this card is showing.
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(8)

        Chicklet {
          iconText: "󰕧"
          selected: !!(root.ytService && root.ytService.videoActive)
          enabled: !!(root.ytService && root.ytService.hasTrack)
          foreground: root.bar.foreground
          tooltipText: root.ytService && root.ytService.videoActive
                       ? "Close the video window"
                       : "Watch the video"
          onClicked: root.toggleVideo()
        }
        Chicklet {
          iconText: "󰝚"
          selected: root.miniQueueOpen
          foreground: root.bar.foreground
          tooltipText: root.miniQueueOpen ? "Hide queue" : "Show queue"
          onClicked: root.miniQueueOpen = !root.miniQueueOpen
        }
        Chicklet {
          iconText: "󰓃"
          selected: root.miniEqOpen
          foreground: root.bar.foreground
          tooltipText: root.miniEqOpen ? "Hide equaliser" : "Show equaliser"
          onClicked: root.miniEqOpen = !root.miniEqOpen
        }
      }

      // Video controls, only while a window is actually open. Quality and
      // speed are the two things YouTube exposes that mpv's own OSC does not,
      // so they live here rather than being left to mpv keybindings.
      Column {
        width: parent.width
        spacing: Style.space(4)
        visible: !!(root.ytService && root.ytService.videoActive)

        RowLayout {
          width: parent.width
          spacing: Style.space(8)
          Text {
            text: "QUALITY"
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          Dropdown {
            Layout.fillWidth: true
            showLabel: false
            options: {
              var out = []
              var hs = root.ytService ? root.ytService.videoHeights : []
              for (var i = 0; i < hs.length; i++)
                out.push({ value: String(hs[i]), label: hs[i] + "p" })
              return out
            }
            value: root.ytService ? String(root.ytService.videoHeight) : ""
            foreground: root.bar.foreground
            onChanged: function(value) {
              if (root.ytService) root.ytService.setVideoQuality(parseInt(value, 10))
            }
          }
        }

        RowLayout {
          width: parent.width
          spacing: Style.space(8)
          Text {
            text: "SPEED"
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          Dropdown {
            Layout.fillWidth: true
            showLabel: false
            options: {
              var out = []
              var sp = root.ytService ? root.ytService.videoSpeeds : []
              for (var i = 0; i < sp.length; i++)
                out.push({ value: String(sp[i]), label: (sp[i] === 1 ? "Normal" : sp[i] + "x") })
              return out
            }
            value: root.ytService ? String(root.ytService.videoSpeed) : "1"
            foreground: root.bar.foreground
            onChanged: function(value) {
              if (root.ytService) root.ytService.setVideoSpeed(parseFloat(value))
            }
          }
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(6)
        visible: root.miniEqOpen

        // The visualiser belongs with the equaliser, not pinned under the
        // volume slider: it is the display half of the same idea, and it is
        // decoration the card should not spend height on by default.
        SpectrumBar {
          width: parent.width
          compact: true
          showLabels: false
          levels: root.ytService ? root.ytService.spectrumBands : []
          foreground: root.bar.foreground
          accent: Color.accent
        }

        RowLayout {
          width: parent.width
          spacing: Style.space(8)

          Text {
            text: "MODE"
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          Dropdown {
            Layout.fillWidth: true
            showLabel: false
            options: root.ytService ? root.ytService.eqPresets : []
            // "Custom" is what the backend reports once a band has been
            // dragged by hand; it is a state, not something you can pick.
            value: root.ytService ? root.ytService.eq.preset : "Flat"
            foreground: root.bar.foreground
            onChanged: function(value) {
              if (root.ytService) root.ytService.setEqPreset(value)
            }
          }
        }

        EqBar {
          width: parent.width
          compact: true
          service: root.ytService
          foreground: root.bar.foreground
          accent: Color.accent
          // The preset picker above replaces the cycle-through button.
          showPreset: false
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(2)
        visible: root.miniQueueOpen

        Repeater {
          model: root.ytService ? root.ytService.queue.slice(0, 4) : []
          TrackRow {
            width: column.width
            item: modelData
            compact: true
            fg: root.bar.foreground
            highlighted: index === (root.ytService ? root.ytService.queueIndex : -1)
            queueGlyph: "󰅖"
            onPlayRequested: root.ytService && root.ytService.playQueueFrom(root.ytService.queue, index)
            onQueueRequested: root.ytService && root.ytService.removeFromQueue(index)
          }
        }
        Text {
          visible: !root.ytService || root.ytService.queue.length === 0
          text: "Queue is empty"
          color: Qt.darker(root.bar.foreground, 1.5)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      TextField {
        id: miniSearchField
        width: parent.width
        placeholderText: "Search, or paste a YouTube link"
        text: root.miniSearchText
        onTextChanged: {
          root.miniSearchText = text
          // A link is only ever expanded on Enter — a playlist link replaces
          // the queue, which must not happen mid-paste from the live timer.
          if (root.miniSearchIsLink) miniLiveSearchTimer.stop()
          else miniLiveSearchTimer.restart()
        }
        onAccepted: {
          miniLiveSearchTimer.stop()
          if (root.miniSearchIsLink) { root.openMiniLink(); return }
          // Results are usually already in from live search — play the
          // selected one straight away. If the user hit Enter before they
          // landed, search now and play the first result when it arrives.
          if (root.miniSearchResults.length > 0) root.playSelectedResult()
          else root.runMiniSearch(true)
        }
        Keys.onDownPressed: root.moveMiniSelection(1)
        Keys.onUpPressed: root.moveMiniSelection(-1)
      }

      Timer {
        id: miniLiveSearchTimer
        interval: 300
        repeat: false
        onTriggered: root.runMiniSearch(false)
      }

      Column {
        width: parent.width
        spacing: Style.space(2)
        visible: root.miniSearchResults.length > 0

        Repeater {
          model: root.miniSearchResults
          TrackRow {
            width: column.width
            item: modelData
            compact: true
            fg: root.bar.foreground
            highlighted: index === root.miniSelected
            onPlayRequested: {
              root.miniSelected = index
              if (root.ytService) root.ytService.playNow(modelData)
            }
            onQueueRequested: root.ytService && root.ytService.addToQueue(modelData)
          }
        }
      }

      PanelSeparator { width: parent.width; foreground: root.bar.foreground }

      RowLayout {
        width: parent.width
        Text {
          Layout.fillWidth: true
          text: root.ytService && root.ytService.backendReady ? "" : "Starting up…"
          color: Qt.darker(root.bar.foreground, 1.5)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        Button {
          text: "Full player"
          onClicked: root.openFullPlayer()
        }
      }
    }
    }
    }
  }
}
