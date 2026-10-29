import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import QtQuick.Effects
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
  // The panel has always surfaced this, the bar never did — so a failure that
  // happened while the panel was closed was invisible: the chip went on
  // reading "Nothing playing" as though nothing had gone wrong.
  readonly property string lastError: ytService ? String(ytService.lastError || "") : ""
  // Three states, and what each one shows:
  //
  //   no track            the note, alone — it is the way into the player
  //   paused, or hovered  the note and the transport controls
  //   playing, at rest    the scrolling title, and nothing else
  //
  // Paused counts as "show me the controls" because a paused track is one you
  // are about to do something to; a playing one you only want to read.
  readonly property bool paused: hasTrack && !playing
  // How much of the chip is drawn, set per bar entry in shell.json
  // ({"id":"omar.ytwidget","size":"icon"}):
  //   icon   the note alone, tinted while a track plays; the tooltip names it
  //   title  the note and the scrolling title, no transport controls
  //   full   everything above (the default)
  // Anything else falls back to full, so a typo never hides the widget.
  readonly property string sizeMode: {
    if (root.uiSize !== "") return root.uiSize
    const s = String(root.setting("size", "full")).toLowerCase()
    return (s === "icon" || s === "title") ? s : "full"
  }
  readonly property bool showControls: sizeMode === "full" && hasTrack && (pillHover.hovered || paused)
  readonly property bool showTitle: sizeMode !== "icon" && hasTrack && !showControls
  // In title mode the note stays on screen, so the title starts after it.
  // The note takes the bar's own colour in every mode, like its neighbours.
  readonly property color noteColor: root.bar.barForeground
  readonly property real titleInset: sizeMode === "title" ? Style.bar.iconSlot + Style.space(8) : 0

  // The chip holds one width for as long as a track is loaded, whatever it is
  // showing, so it never resizes under the pointer and never shoves the bar
  // icons beside it. That works out exactly rather than by padding: hiding the
  // note frees precisely the room the title needs.
  //
  //   note + gap + controls  = 26 + 4 + 94 = 124
  //   title alone, no note   =              124
  //
  // Only losing the track shrinks it, down to the bare note.
  readonly property real ctrlGap: Style.space(8)
  // Note + prev + play + next, in the bar's own icon slots. The title is given
  // this same width, so the two simply cross-fade in place.
  readonly property real trackSpan: 4 * Style.bar.iconSlot + 3 * ctrlGap
  // The setting still widens the title, but it widens the locked width with
  // it, so the chip stays the same size in every state either way.
  readonly property real maxLabelWidth: Math.max(trackSpan,
    Style.space(Math.max(60, Number(root.setting("maxWidth", 0)) || 0)))
  readonly property string playIcon: playing ? "\u{f03e4}" : "\u{f040a}"
  // Plain ASCII, not a nerd-font codepoint: guaranteed to render in any font,
  // no tofu risk. The art placeholder in the popup, where a tofu box would sit
  // large and obvious in the middle of the card.
  readonly property string idleGlyph: "YT"
  // The bar's own resting mark. A note says "music" at a glance where "YT"
  // only says "YouTube", and it holds the widget's place while the title is
  // collapsed. Same codepoint the play button and the panel already use, so
  // it carries no new font risk in the bar.
  readonly property string musicGlyph: "󰝚"

  // Ambient full-bar spectrum. Off by default: it paints across the whole
  // screen width, which is a bigger change to someone's desktop than a bar
  // widget has any business making uninvited.
  // ---- lyrics
  readonly property bool lyricsEnabled: String(root.setting("lyrics", "true")) !== "false"
  readonly property bool lyricsInBar: lyricsEnabled && String(root.setting("lyricsInBar", "true")) !== "false"
  readonly property string lyricsSource: {
    var v = String(root.setting("lyricsSource", "auto"))
    return (v === "lrclib" || v === "captions") ? v : "auto"
  }
  readonly property bool lyricsReady: lyricsEnabled && !!(ytService && ytService.lyrics)
    && ["synced", "captions", "plain"].indexOf(ytService.lyrics.status) >= 0
    && (ytService.lyrics.lines || []).length > 0
  function sendLyricsConfig() {
    if (ytService) ytService.lyricsConfig(root.lyricsEnabled, root.lyricsSource)
  }
  onLyricsEnabledChanged: sendLyricsConfig()
  onLyricsSourceChanged: sendLyricsConfig()

  // The line being sung, for the wide chip. Empty between lines and for
  // songs without timed lyrics, so the title shows then.
  LyricsClock {
    id: barLyricsClock
    service: root.ytService
    active: root.lyricsInBar && root.sizeMode !== "icon" && root.hasTrack && root.playing
  }
  readonly property string barLyricLine: {
    if (!barLyricsClock.active || barLyricsClock.index < 0) return ""
    var line = barLyricsClock.lines[barLyricsClock.index]
    return line ? String(line.text || "").trim() : ""
  }

  // The card opens on Lyrics when the song has them, unless a tab was picked
  // by hand since the card opened.
  property bool miniTabTouched: false
  function pickMiniTabForLyrics() {
    if (root.miniTabTouched) return
    if (root.lyricsReady) root.miniTab = "lyrics"
    else if (root.miniTab === "lyrics" && ytService && ytService.lyrics
             && ytService.lyrics.status !== "loading") root.miniTab = "next"
  }
  onLyricsReadyChanged: if (root.popupOpen) pickMiniTabForLyrics()

  readonly property bool ambientDefault: String(root.setting("ambientWave", "false")) === "true"
  // The toggle in the hover controls is remembered in the widget's own state
  // file, so the spectrum stays on (or off) across shell restarts, plugin
  // reloads and every monitor's copy of this widget until it is toggled again.
  // (The host's settings API is not usable from a third-party bar widget; see
  // the note on serviceFor() above.) The shell.json setting only seeds it.
  property bool ambientEnabled: root.ambientDefault
  readonly property string uiStatePath: Quickshell.env("HOME") + "/.local/state/ytwidget/ui.json"

  // Bar-chip look chosen from the card below, remembered in the same file.
  // They override the shell.json settings, so the card is the one place you
  // need to touch. "" / -1 mean "not chosen here, use the setting".
  property string uiSize: ""
  property int uiIconWidth: -1

  function saveUi() {
    uiStateFile.setText(JSON.stringify({
      ambientWave: root.ambientEnabled,
      size: root.uiSize,
      iconWidth: root.uiIconWidth
    }) + "\n")
  }

  function setAmbient(on) {
    root.ambientEnabled = !!on
    root.saveUi()
    // The spectrum window shows or hides a moment from now.
    Qt.callLater(root.refocusPopup)
  }

  function toggleWide() {
    root.uiSize = root.sizeMode === "full" ? "icon" : "full"
    root.saveUi()
  }

  FileView {
    id: uiStateFile
    path: root.uiStatePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    // Another monitor's copy toggled it: follow.
    onFileChanged: reload()
    onLoaded: {
      try {
        var saved = JSON.parse(text() || "{}")
        if (typeof saved.ambientWave === "boolean") root.ambientEnabled = saved.ambientWave
        root.uiSize = (saved.size === "icon" || saved.size === "title" || saved.size === "full") ? saved.size : ""
        root.uiIconWidth = Number(saved.iconWidth) > 0 ? Number(saved.iconWidth) : -1
      } catch (e) {}
    }
  }

  readonly property real ambientOpacity: Math.max(0.05, Math.min(1,
    (Number(root.setting("ambientOpacity", 55)) || 55) / 100))
  readonly property real ambientHeight: Math.max(0.1, Math.min(1,
    (Number(root.setting("ambientHeight", 62)) || 62) / 100))

  property bool popupOpen: false
  property string miniSearchText: ""
  // How many results the mini card asks for, and how many of them it shows
  // without scrolling. Six used to be the whole list because the list was a
  // plain Column — every extra row grew the card, so the card had to stay
  // stingy. Now the list scrolls at `miniVisibleResults` rows, so asking for
  // more costs no height at all.
  readonly property int miniResultLimit: Math.max(3, Math.min(25,
    Number(root.setting("miniResults", 12)) || 12))
  readonly property int miniVisibleResults: 5
  readonly property real miniRowHeight: Style.space(38)
  readonly property real miniRowSpacing: Style.space(2)
  property var miniSearchResults: []
  property int miniSelected: 0
  property bool miniSearching: false
  property bool miniQueueOpen: false
  // The EQ section is opt-in: the mini player is a now-playing card first,
  // and ten sliders is not what you want to see every time it opens.
  property bool miniEqOpen: false

  visible: true
  // Icon mode sizes to the same slot as every other bar icon by default, so
  // it sits flush instead of keeping the padding the wider chip needs. The
  // "iconWidth" setting (px) widens or narrows just that mode; 0 = one slot.
  readonly property real iconModeWidth: {
    const w = root.uiIconWidth > 0 ? root.uiIconWidth : (Number(root.setting("iconWidth", 0)) || 0)
    return w > 0 ? Style.space(w) : Style.bar.iconSlot
  }
  // Size of the note glyph itself, in the bar's own icon-font units. 0 keeps
  // the bar default so it matches the neighbouring icons.
  readonly property real glyphSize: {
    const g = Number(root.setting("glyphSize", 0)) || 0
    return g > 0 ? g : Style.bar.iconFont
  }
  implicitWidth: sizeMode === "icon" ? iconModeWidth : row.implicitWidth + Style.space(14)
  implicitHeight: barSize

  // Nothing inside a popup surface gets keyboard focus automatically. Same
  // fix SearchableDropdown/go-prompt use: a short delay (not Qt.callLater,
  // which fires next tick) gives the focus grab time to establish the
  // compositor-level keyboard grab before we ask Qt for active focus —
  // otherwise the field can look focused (blinking cursor) while keystrokes
  // never arrive.
  onPopupOpenChanged: {
    // One popup at a time, like the bar's own: opening the card closes
    // whatever else is open (the bar calls close() on us the same way).
    if (root.bar) {
      if (popupOpen) root.bar.requestPopout(root)
      else if (root.bar.activePopout === root) root.bar.releasePopout(root)
    }
    if (!popupOpen) { root.grabIncludesBar = false; return }
    root.grabIncludesBar = false
    grabBarTimer.restart()
    root.miniTabTouched = false
    root.pickMiniTabForLyrics()
    // Baseline for the dismiss watcher further down: the window that was
    // focused as the card came up. Opening the card does not disturb it — a
    // layer surface taking the keyboard grab leaves the focused toplevel
    // exactly where it was.
    popupFocusToplevel = ToplevelManager.activeToplevel
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

  // Carries the mini card's search into the full player instead of opening it
  // on an empty Search tab: the query goes into its field and the rows the
  // card was already showing go with it, so the same results are on screen
  // immediately. The panel searches wider than the card does, so it re-runs
  // the query behind them and the list fills out (see Panel.open).
  //
  // `summon`, not `toggle`: this button means "show me the full player", and
  // toggle *closes* the panel whenever it happens to be open already — which
  // threw the payload away with it.
  function openFullPlayer() {
    var payload = {
      search: root.miniSearchText,
      results: root.miniSearchResults || [],
      lyrics: root.lyricsEnabled,
      lyricsSize: String(root.setting("lyricsSize", "normal")),
      tab: root.miniTab === "lyrics" ? "lyrics" : ""
    }
    popupOpen = false
    toggleProcess.running = false
    toggleProcess.command = ["/usr/bin/omarchy-shell", "shell", "summon", moduleName,
                             JSON.stringify(payload)]
    toggleProcess.running = true
  }

  function runMiniSearch(playFirstWhenDone) {
    if (!miniSearchText.trim()) { miniSearchResults = []; miniSelected = 0; return }
    if (!ytService) return
    miniSearching = true
    ytService.search(miniSearchText.trim(), root.miniResultLimit, function(ok, result) {
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
    playFromSearch(miniSearchResults[i])
  }

  // Search results take the pane over while they are up. Picking a tab or
  // playing a result puts the tabs back, so the Lyrics tab never sits
  // selected over a list of results.
  function clearMiniSearch() {
    root.miniSearchText = ""
    root.miniSearchResults = []
    root.miniSelected = 0
    root.miniPreview = null
  }
  function playFromSearch(item) {
    if (!ytService) return
    ytService.playNow(item)
    clearMiniSearch()
    // A new song: let the card move to its lyrics once they are found.
    root.miniTabTouched = false
    if (root.miniTab === "lyrics") root.miniTab = "next"
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
    var vpnMode = String(root.setting("vpnMode", "fallback") || "fallback")
    if (["off", "fallback", "always"].indexOf(vpnMode) >= 0 && typeof ytService.setVpnMode === "function")
      ytService.setVpnMode(vpnMode)
  }

  Connections {
    target: root.ytService
    function onBackendReadyChanged() {
      if (root.ytService && root.ytService.backendReady) root.pushSettings()
    }
  }

  // Keys while the card is open and the search box is not focused (Esc
  // leaves the box, "/" goes back into it). Returns true when handled.
  function cardKey(event) {
    var svc = ytService
    if (!svc) return false
    if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return false
    var seekBy = function(ms) { svc.seek(Math.max(0, Math.min(svc.durationMs, svc.positionMs + ms))) }
    switch (event.key) {
    case Qt.Key_Space: svc.togglePlayback(); return true
    case Qt.Key_N: svc.next(); return true
    case Qt.Key_P: svc.previous(); return true
    case Qt.Key_S: svc.setShuffle(!svc.shuffle); return true
    case Qt.Key_R: svc.cycleRepeat(); return true
    case Qt.Key_Left: seekBy(-5000); return true
    case Qt.Key_Right: seekBy(5000); return true
    case Qt.Key_Up: svc.setVolume(Math.min(100, svc.volume + 5)); return true
    case Qt.Key_Down: svc.setVolume(Math.max(0, svc.volume - 5)); return true
    case Qt.Key_M: svc.setVolume(svc.volume > 0 ? 0 : 50); return true
    case Qt.Key_1: root.miniTab = "next"; root.miniTabTouched = true; root.clearMiniSearch(); return true
    case Qt.Key_2: root.miniTab = "recent"; root.miniTabTouched = true; root.clearMiniSearch(); return true
    case Qt.Key_3: root.miniTab = "lists"; root.miniTabTouched = true; root.clearMiniSearch(); return true
    case Qt.Key_4:
    case Qt.Key_L:
      if (root.lyricsEnabled) { root.miniTab = "lyrics"; root.miniTabTouched = true; root.clearMiniSearch() }
      return true
    case Qt.Key_E: root.miniEqOpen = !root.miniEqOpen; return true
    case Qt.Key_V: root.toggleVideo(); return true
    case Qt.Key_F: root.openFullPlayer(); return true
    case Qt.Key_Slash: miniSearchField.forceActiveFocus(); return true
    }
    return false
  }

  function toggleVideo() {
    if (!ytService || !ytService.hasTrack) return
    if (ytService.videoActive) ytService.hideVideo()
    else ytService.showVideo("")
  }

  // The pane under the transport shows one of: next (queue), recent
  // (history), lists (smart + saved playlists), or a pasted playlist link.
  property string miniTab: "next"
  property var miniPreview: null          // { title, items } for a pasted playlist link
  property bool miniPreviewBusy: false
  // One height the card is built around, so it never changes size.
  readonly property real miniPaneHeight: Style.space(290)
  readonly property real miniCardHeight: Style.space(744)

  function isPlaylistLink(text) {
    return Api.isYouTubeLink(text) && /[?&]list=/.test(String(text))
  }

  function previewMiniLink() {
    var link = root.miniSearchText.trim()
    if (!link || !ytService) return
    miniPreviewBusy = true
    ytService.previewPlaylist(link, function(ok, data) {
      miniPreviewBusy = false
      miniPreview = ok && data && data.items && data.items.length > 0 ? data : null
    })
  }

  function playMiniPreview(shuffle) {
    if (!miniPreview || !ytService) return
    if (shuffle) ytService.setShuffle(true)
    ytService.playQueueFrom(miniPreview.items, 0)
    miniPreview = null
    root.miniSearchText = ""
    root.miniTab = "next"
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

  // No pill outline at all.
  //
  // It used to be on always, then on only while hovered as an affordance for
  // the transport buttons. But drawing a box is what made the width mismatch
  // visible: the slot is sized for the title, the three buttons need about
  // half that, and an outline around the difference turns ordinary bar
  // spacing into a conspicuously half-empty container. With no border the
  // buttons simply sit in the bar like every other icon and there is nothing
  // to look under-filled.

  Row {
    id: row
    // Sit above the click-to-open MouseArea below so the transport buttons
    // get first claim on clicks landing on them (same trick omamusic uses:
    // its inline bar buttons set z:1 over the chip's own click handler).
    z: 1
    anchors.centerIn: parent
    spacing: Style.space(4)

    // The title and the transport controls occupy the same space, crossfading
    // on pill hover: the track name at rest, prev/pause/next while hovered.
    //
    // There is no separate slot for the controls any more. One held the chip's
    // waveform, then the playback time, and both were really just filling
    // space the controls needed — the title is already there and can hand its
    // own space over. The slot is sized to whichever of the two is wider, so
    // the pill does not resize as you move onto it and shove the icons beside
    // it around.
    Item {
      id: mediaSlot
      anchors.verticalCenter: parent.verticalCenter
      // Whatever the chip is showing, the total stays root.maxLabelWidth: the
      // slot gives back exactly the room the note takes when the note is
      // there, and claims it when the note steps aside. So the widget holds
      // one width for as long as a track is loaded, and the bar icons beside
      // it never move while you use it.
      //
      // With no track there is nothing to show but the note, and the slot
      // closes entirely — the one size change left, and the one worth seeing.
      width: root.sizeMode !== "icon" && (root.hasTrack || root.lastError !== "")
        ? root.maxLabelWidth
        : Style.bar.iconSlot
      height: root.barSize
      // Without this the transport buttons spill out of the slot while it is
      // still animating shut.
      clip: true
      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }

      // Left-aligned, not centred: the title starts at this edge too, so the
      // swap happens in place rather than collapsing into the middle. What is
      // left over sits on the right, which is where it already sits whenever
      // a track has a short title.
      Row {
        id: controlsRow
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(8)
        // Shown whenever the controls are, and on its own when there is no
        // track at all — it is the way into the player either way.
        enabled: root.showControls || !root.hasTrack || root.sizeMode !== "full"
        opacity: (root.showControls || !root.hasTrack || root.sizeMode !== "full") ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 120 } }

        // The note lives inside the slot, ahead of the transport, rather than
        // outside it. Out there it was laid out beside the slot, so appearing
        // on hover pushed the controls sideways and the swap read as the chip
        // resizing even though the total never changed. In here both the
        // title and this row start at the same left edge and simply cross-
        // fade: nothing moves at all.
        // BarIconButton, like the bar's own icons: it centres the glyph by its
        // painted ink, not its advance width, so the note sits on the same
        // optical centre as its neighbours.
        BarIconButton {
          id: noteButton
          bar: root.bar
          text: root.musicGlyph
          fontSize: root.glyphSize
          foreground: root.lastError !== "" ? Color.urgent : root.noteColor
          fixedWidth: Style.bar.iconSlot
          fixedHeight: root.barSize
          tooltipText: root.lastError !== ""
            ? root.lastError
            : (root.hasTrack
              ? Api.barTrackText(root.title, root.artist, true, true)
              : "Nothing playing")
          onPressed: function(mouseButton) {
            if (mouseButton === Qt.LeftButton) root.popupOpen = !root.popupOpen
          }
        }

        WidgetButton {
          id: prevButton
          visible: root.hasTrack && root.sizeMode === "full"
          bar: root.bar
          text: "\u{f04ae}"
          fontSize: Style.bar.iconFont
          foreground: root.bar.barForeground
          fixedWidth: Style.bar.iconSlot
          fixedHeight: root.barSize
          tooltipText: "Previous"
          onPressed: function(mouseButton) {
            if (mouseButton === Qt.LeftButton && root.ytService) root.ytService.previous()
          }
        }
        WidgetButton {
          id: playButton
          visible: root.hasTrack && root.sizeMode === "full"
          bar: root.bar
          text: root.hasTrack ? root.playIcon : "󰝚"
          fontSize: Style.bar.iconFont
          foreground: root.bar.barForeground
          fixedWidth: Style.bar.iconSlot
          fixedHeight: root.barSize
          // Hovering the chip fades the marquee out and swaps these controls
          // in, so the error text disappears at the exact moment you lean in
          // to read it. The tooltip is where it has to survive.
          tooltipText: root.lastError !== ""
            ? root.lastError
            : (root.hasTrack ? (root.playing ? "Pause" : "Play") : "Nothing playing")
          onPressed: function(mouseButton) {
            if (mouseButton === Qt.LeftButton && root.ytService) root.ytService.togglePlayback()
          }
        }
        WidgetButton {
          id: nextButton
          visible: root.hasTrack && root.sizeMode === "full"
          bar: root.bar
          text: "\u{f04ad}"
          fontSize: Style.bar.iconFont
          foreground: root.bar.barForeground
          fixedWidth: Style.bar.iconSlot
          fixedHeight: root.barSize
          tooltipText: "Next"
          onPressed: function(mouseButton) {
            if (mouseButton === Qt.LeftButton && root.ytService) root.ytService.next()
          }
        }
        // The chevron that used to sit here opened the player — but so does
        // the note, which is permanent and always in the same place. Two
        // controls for one action, one of them only reachable on hover.
        // The note keeps the job.
      }

      // Scrolling title. Two copies separated by a gap, scrolled by exactly
      // one copy-plus-gap, so the second lands where the first started and the
      // loop is seamless with no visible jump.
      //
      // The earlier marquee here left a stray glyph in the bar. The guards that
      // prevent that: a hard clip, a width that can never go negative or zero,
      // scrolling only when the text genuinely overflows, and x reset to 0
      // whenever it stops — so a partial frame can't be left parked on screen.
      // The gradient the marquee is masked through. Not drawn itself — it is
      // here only to be a texture. White is opaque, transparent is cut away.
      Item {
        id: marqueeFade
        anchors.fill: marquee
        visible: false
        layer.enabled: true
        Rectangle {
          anchors.fill: parent
          gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: "#00ffffff" }
            GradientStop { position: 0.06; color: "#ffffffff" }
            GradientStop { position: 0.92; color: "#ffffffff" }
            GradientStop { position: 1.0; color: "#00ffffff" }
          }
        }
      }

      Item {
        id: marquee
        anchors.left: parent.left
        anchors.leftMargin: root.titleInset
        opacity: root.showTitle ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 120 } }
        anchors.verticalCenter: parent.verticalCenter
        visible: !root.bar.vertical
        // The clip stays: it is the hard guarantee against a stray glyph
        // parked outside the slot. The fade is layered over it so the text
        // dissolves at the edges instead of being guillotined mid-letter —
        // only worth paying for while it actually scrolls.
        clip: true
        layer.enabled: marquee.overflowing
        layer.effect: MultiEffect {
          maskEnabled: true
          maskSource: marqueeFade
        }
        height: titleA.implicitHeight
        width: Math.max(0, Math.min(root.maxLabelWidth - root.titleInset, titleA.implicitWidth))

        // An error outranks the track: it is the one thing here you cannot
        // act on from the bar, and it is why the title is stale or missing.
        // Idle is now said by the note alone — the slot has collapsed to
        // nothing by this point, so there is nowhere to print "Nothing
        // playing" and no need to: an empty bar widget is the message.
        //
        // Title only, no artist. On YouTube the "artist" is the channel and
        // the title usually already carries the artist, so asking for both
        // printed the same fact twice — "LatinHype - Tame Impala - Loser" —
        // and guaranteed the text could never fit, which is what made the
        // marquee scroll constantly. The channel is still one hover away in
        // the tooltip, and spelled out in the panel.
        readonly property string fullText: root.lastError !== ""
          ? root.lastError
          : (root.hasTrack
            ? (root.barLyricLine !== "" ? root.barLyricLine : Api.barTrackText(root.title, root.artist, true, false))
            : "")
        readonly property real gapPx: Style.space(28)
        readonly property bool overflowing: titleA.implicitWidth > width + 1

        Row {
          id: ticker
          spacing: marquee.gapPx

          Text {
            id: titleA
            textFormat: Text.PlainText
            text: marquee.fullText
            color: root.lastError !== ""
              ? Color.urgent
              : (root.hasTrack && root.playing
                ? root.bar.barForeground : Qt.darker(root.bar.barForeground, 1.5))
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

        // Still a loop — reading the whole title is the point of the thing —
        // but it now rests at the start of each pass instead of wrapping
        // straight back into motion. The old version never stood still, which
        // is what made it tiring to sit beside; this gives you a beat to read
        // the opening words, which is the part that identifies the track.
        SequentialAnimation {
          id: scrollAnim
          running: marquee.overflowing && marquee.visible
          loops: Animation.Infinite
          PauseAnimation { duration: 2200 }
          NumberAnimation {
            target: ticker
            property: "x"
            from: 0
            to: -(titleA.implicitWidth + marquee.gapPx)
            duration: Math.max(4000, (titleA.implicitWidth + marquee.gapPx) * 22)
          }
          // Back to the start before the next rest, so the pause is always
          // spent showing the beginning of the title rather than the end.
          ScriptAction { script: ticker.x = 0 }
          onRunningChanged: if (!running) ticker.x = 0
        }
      }

      // How far through the track we are, as a line under the title — the
      // same idea as the bar under a YouTube thumbnail. It stays put while
      // the controls swap in on hover: it is status, not a control, and
      // nothing about it changes when the pointer arrives.
      Rectangle {
        id: progressTrack
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Style.space(4)
        height: Math.max(1, Style.space(1))
        radius: height / 2
        visible: root.hasTrack && root.sizeMode !== "icon" && !!root.bar && !root.bar.vertical
                 && root.ytService && root.ytService.durationMs > 0
        color: Qt.rgba(root.bar.barForeground.r, root.bar.barForeground.g,
                       root.bar.barForeground.b, 0.18)

        Rectangle {
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          radius: parent.radius
          color: root.bar.barForeground
          width: {
            if (!root.ytService || root.ytService.durationMs <= 0) return 0
            var f = root.ytService.positionMs / root.ytService.durationMs
            return parent.width * Math.max(0, Math.min(1, f))
          }

          // Position arrives in steps as mpv reports it; interpolating
          // between them turns a twitching line into a moving one. Short
          // enough not to lag a seek.
          Behavior on width {
            NumberAnimation { duration: 250; easing.type: Easing.OutQuad }
          }
        }
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
  // True while the last measurement differed from the one before it, i.e.
  // while the bar is animating (a drawer opening, a title changing width).
  // The timer then ticks fast so the spectrum follows instead of lagging.
  property bool ambientMoving: false

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
      if (same) { ambientMoving = false; return }
    }
    ambientMoving = true
    ambientGaps = gaps
  }

  // The bar's contents resize constantly — a scrolling title, a ticking
  // clock — so this is re-measured on a timer rather than hooked to any one
  // widget's geometry. Cheap: a few hundred item reads, four times a second.
  Timer {
    interval: root.ambientMoving ? 40 : 250
    repeat: true
    running: root.ambientEnabled
    triggeredOnStart: true
    onTriggered: root.recomputeAmbientGaps()
  }

  // Whether the plugin is making any sound at this instant.
  //
  // `playing` alone is not enough to decide whether to draw. It stays true
  // across a track change while yt-dlp resolves the next URL, which is three
  // or four seconds with mpv's stream gone — the bars sit frozen at their
  // floor with the strip still faded in, which reads as the visualiser being
  // stuck on after the music stopped. It also stays true through any future
  // state bug of the kind that already cost us a stalled play button.
  readonly property bool ambientAudible: {
    var bands = ytService ? ytService.spectrumBands : null
    if (!bands) return false
    for (var i = 0; i < bands.length; i++) {
      if (Number(bands[i]) > 0.02) return true
    }
    return false
  }

  // Held, so a rest in the music does not blink the strip out and back. Only
  // a real stop lasts long enough to trip it.
  property bool ambientSilent: true

  onAmbientAudibleChanged: {
    if (ambientAudible) {
      silenceHold.stop()
      ambientSilent = false
    } else {
      silenceHold.restart()
    }
  }

  Timer {
    id: silenceHold
    interval: 1200
    repeat: false
    onTriggered: root.ambientSilent = true
  }

  // The monitor this copy of the widget is on.
  //
  // A bar surface is built per output (the bar's `Variants { model:
  // Quickshell.screens }`), so this file runs once per monitor — and a
  // PanelWindow that never sets `screen` lands on whichever output Quickshell
  // picks first. Every copy therefore stacked its windows on that one screen:
  // two ambient strips over the laptop panel, none over the external one, each
  // masking with gaps it had measured from a different bar. The strip that had
  // the other monitor's gaps painted the spectrum straight across this
  // monitor's modules, which is what put bars under the clock and the tray.
  //
  // Pinning both windows to this instance's own screen is also what puts the
  // spectrum on every monitor: one bar, one strip, its own gaps.
  readonly property var barWindow: root.QsWindow ? root.QsWindow.window : null
  readonly property var barScreen: barWindow ? barWindow.screen : null

  // Light/dark wallpaper under each ambient bar, so each bar picks the colour
  // that reads against what is actually behind it. Re-sampled when the
  // wallpaper, screen or bar changes.
  property var ambientTones: []
  Process {
    id: tonesProc
    stdout: SplitParser {
      onRead: function(line) {
        var v = String(line).trim().split(/\s+/).map(Number)
        root.ambientTones = v.length === 160 ? v : []
      }
    }
  }
  function refreshTones() {
    if (!root.barScreen || tonesProc.running) return
    tonesProc.command = ["/usr/bin/bash", Qt.resolvedUrl("scripts/strip-tones.sh").toString().replace("file://", ""),
      root.barScreen.name, String(root.barSize), "160", root.bar ? root.bar.position : "top"]
    tonesProc.running = true
  }
  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme.name"
    watchChanges: true
    printErrors: false
    onFileChanged: tonesDebounce.restart()
  }
  // The theme name changes before the wallpaper link does; sampling at once
  // reads the old wallpaper.
  Timer { id: tonesDebounce; interval: 900; onTriggered: root.refreshTones() }
  onBarScreenChanged: refreshTones()
  Component.onCompleted: { refreshTones(); sendLyricsConfig() }

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
    screen: root.barScreen
    // No screen yet means the window would fall back to Quickshell's first
    // output, which is the stacking this is here to avoid. Nothing is playing
    // that early anyway, so waiting costs nothing.
    visible: root.ambientEnabled && !!root.barScreen && !!root.bar && !root.bar.vertical
    // Follows the bar to whichever horizontal edge it sits on. Anchored to the
    // top unconditionally, a bottom bar left the strip stranded across the top
    // of the wallpaper. Vertical bars never show it at all (see `visible`).
    anchors {
      top: !root.bar || root.bar.position !== "bottom"
      bottom: !!root.bar && root.bar.position === "bottom"
      left: true
      right: true
    }
    implicitHeight: root.barSize
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omar-ytwidget-ambient"
    WlrLayershell.layer: root.bar && root.bar.transparent ? WlrLayer.Bottom : WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // Visual-only, same as Omarchy's own bar-drag-ghost window (Bar.qml):
    // an empty input region so this can never steal a click or an
    // in-progress drag (e.g. dragging a widget into an empty bar section)
    // meant for whatever is above or below it.
    mask: Region {}

    AmbientWave {
      anchors.fill: parent
      levels: root.ytService ? root.ytService.spectrumBands : []
      color: root.bar ? root.bar.foreground : "white"
      darkColor: root.bar ? root.bar.background : "#2d353b"
      tones: root.bar && root.bar.transparent ? root.ambientTones : []
      heightFraction: root.ambientHeight
      gaps: root.ambientGaps
      opacity: root.hasTrack && root.playing && !root.ambientSilent ? root.ambientOpacity : 0
      Behavior on opacity { NumberAnimation { duration: 420; easing.type: Easing.OutQuad } }
    }
  }

  // Dismissing the mini player.
  //
  // The card used to hold the keyboard with an exclusive layer-shell grab,
  // and that is what made it impossible to click away from: Hyprland routes
  // *all* input to an exclusive surface, so a click on any other output was
  // dropped by the compositor before anything could see it. Not the window
  // you clicked, and not a catcher surface of our own on that output either —
  // the click simply went nowhere, which is why the only way out was to click
  // the screen the card was already on.
  //
  // A focus grab is the primitive that actually fits: input is routed to the
  // listed windows, and a click anywhere else clears the grab rather than
  // vanishing into it. It is what every Omarchy bar popup uses (see
  // Ui/PopupCard.qml), so the card now dismisses the way the rest of the bar
  // already does.
  property var popupFocusToplevel: null

  // Showing or hiding the ambient spectrum window takes keyboard focus away
  // from the card: typing in the search field then lands in whatever window
  // was focused before. Dropping the grab for a moment and taking it again
  // gives the card its focus back.
  property bool grabPaused: false
  property bool grabIncludesBar: false
  Timer {
    id: grabBarTimer
    interval: 300
    onTriggered: root.grabIncludesBar = !cardHover.hovered
  }

  HyprlandFocusGrab {
    id: popupGrab
    // With two windows in a grab Hyprland hands the keyboard to either one,
    // which is why typing sometimes went nowhere. So the grab holds only
    // the card while it opens and whenever the pointer is on it (the card
    // gets the keyboard), and adds the bar's window only while the pointer
    // is elsewhere: a click on another bar icon then opens it in one go,
    // and the keyboard stays with the card, which is still in the grab.
    windows: root.grabIncludesBar && root.QsWindow.window ? [popup, root.QsWindow.window] : [popup]
    active: root.popupOpen && !root.grabPaused
    onCleared: if (!root.grabPaused) root.popupOpen = false
  }

  Timer {
    id: grabResume
    interval: 120
    onTriggered: root.grabPaused = false
  }

  function refocusPopup() {
    if (!root.popupOpen) return
    root.grabPaused = true
    grabResume.restart()
  }

  // Focus moving to a different window closes the card too. The grab only
  // hears about clicks, and focus moves perfectly well without one — a
  // keybind, a workspace switch, a window opening somewhere else.
  //
  // Deliberately the compositor's *toplevel*, not Hyprland's activewindow
  // event: Hyprland re-emits that every time the focused window's title
  // changes, so a background tab renaming itself would shut the card
  // mid-search, while the toplevel's identity only changes when the focus
  // really does.
  Connections {
    target: ToplevelManager

    function onActiveToplevelChanged() {
      if (!root.popupOpen) return
      var active = ToplevelManager.activeToplevel
      if (active && active !== root.popupFocusToplevel) root.popupOpen = false
    }
  }

  Connections {
    target: Hyprland

    function onRawEvent(event) {
      if (!root.popupOpen) return
      var name = String(event.name)

      if (name === "workspace" || name === "workspacev2") {
        // A layer surface outlives the workspace it was opened on, so without
        // this the card follows you to the next one, grab and all.
        root.popupOpen = false
      } else if (name === "openlayer") {
        // Someone else's popup, launcher or menu is opening and wants the
        // keyboard. This widget's own surfaces are not that — the card can
        // raise the ambient strip from inside itself.
        if (String(event.data || "").indexOf("omar-ytwidget") !== 0)
          root.popupOpen = false
      }
    }
  }

  // A real WlrLayershell surface rather than a PopupCard: PopupCard never
  // reliably delivered keyboard input to the search field here — a blinking
  // cursor with no characters landing, only "working" once the window had
  // lost and regained focus.
  //
  // The keyboard comes from the focus grab above, not from the surface
  // itself. Exclusive layer-shell focus delivers keystrokes too, and is what
  // this used to do, but it puts the compositor in a state where every click
  // on every other monitor is swallowed (see above). The grab hands this
  // surface the keyboard without that.
  PanelWindow {
    id: popup
    // Same per-monitor pinning as the ambient strip: without it the mini
    // player opens on whichever output Quickshell picked first, not the one
    // whose chip was clicked.
    screen: root.barScreen
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
    WlrLayershell.keyboardFocus: root.popupOpen ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    // Only the card takes input. The rest of this full-screen layer used to
    // catch every click (to dismiss), which also ate clicks on the bar: you
    // had to click once to close the card and again to open Audio. Outside
    // clicks now pass through; the focus grab below closes the card, and a
    // bar icon closes it through requestPopout like the bar's own popups.
    mask: Region { item: card }

    BorderSurface {
      id: card
      HoverHandler {
        id: cardHover
        onHoveredChanged: {
          if (hovered) { grabBarTimer.stop(); root.grabIncludesBar = false }
          else if (root.popupOpen) grabBarTimer.restart()
        }
      }
      // Clear the bar instead of covering it.
      //
      // This surface sits on the Overlay layer, above the bar's Top layer,
      // and spans the whole output — so anchoring the card to the screen
      // edge parked it on top of the bar, hiding the tray and status icons
      // behind it. Every other panel opens clear of the bar, and this one
      // looked wrong next to them for exactly that reason.
      //
      // The card lives in the top-right, so only a top bar or a right-hand
      // bar is ever in its way; a bottom or left bar needs no clearance.
      readonly property string barPos: root.bar ? root.bar.position : "top"
      readonly property int barThickness: root.bar ? root.bar.barSize : 0
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.topMargin: (barPos === "top" ? barThickness : 0) + Style.gapsOut
      anchors.rightMargin: (barPos === "right" ? barThickness : 0) + Style.gapsOut
      width: Style.space(320)
      height: root.miniCardHeight
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
      id: cardScope
      // Esc: first leaves the search box (so the keys below work), then closes.
      Keys.onEscapePressed: root.popupOpen = false
      Keys.onPressed: function(event) { if (root.cardKey(event)) event.accepted = true }

    CoverBlur {
      // Reaches the card edges (the surface insets its children), so the
      // blur has no visible rectangle of its own.
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.leftMargin: Style.space(2) - card.contentLeftInset
      anchors.rightMargin: Style.space(2) - card.contentRightInset
      anchors.topMargin: Style.space(2) - card.contentTopInset
      height: Style.space(230) + card.contentTopInset
      source: root.ytService ? root.ytService.trackThumbnail : ""
      strength: 0.55
    }

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(12)

      // Header: what this is, and the way into the full player.
      RowLayout {
        width: parent.width
        height: Style.space(26)
        Text {
          Layout.fillWidth: true
          text: root.hasTrack ? (root.playing ? "Now playing" : "Paused") : "Music"
          color: Qt.darker(root.bar.foreground, 1.3)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        FlatButton {
          buttonSize: Style.space(26)
          iconSize: Style.font.icon
          iconText: "\u{f0293}"
          foreground: root.bar.foreground
          tooltipText: "Full player"
          onClicked: root.openFullPlayer()
        }
      }

      // Art beside the title, not above it, so the card stays short.
      RowLayout {
        width: parent.width
        spacing: Style.space(14)

        Rectangle {
          Layout.preferredWidth: Style.space(124)
          Layout.preferredHeight: Style.space(124)
          radius: Style.space(22)
          color: root.ytService && root.ytService.trackThumbnail !== ""
            ? "transparent"
            : Qt.rgba(root.bar.barForeground.r, root.bar.barForeground.g, root.bar.barForeground.b, 0.08)

          RoundedImage {
            anchors.fill: parent
            radius: parent.radius
            lifted: true
            visible: root.ytService && root.ytService.trackThumbnail !== ""
            source: root.ytService ? root.ytService.trackThumbnail : ""
          }
          Text {
            anchors.fill: parent
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            visible: !root.ytService || root.ytService.trackThumbnail === ""
            text: root.idleGlyph
            color: root.bar.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.displayLarge
          }
          MouseArea {
            anchors.fill: parent
            enabled: root.hasTrack
            cursorShape: root.hasTrack ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: root.ytService && root.ytService.togglePlayback()
          }
        }

        Column {
          Layout.fillWidth: true
          spacing: Style.space(4)
          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.hasTrack ? root.title : "Nothing playing"
            color: root.bar.foreground
            font.family: Style.font.family
            font.bold: true
            font.pixelSize: Style.font.subtitle
            wrapMode: Text.Wrap
            maximumLineCount: 3
            elide: Text.ElideRight
          }
          Text {
            width: parent.width
            visible: root.artist !== ""
            textFormat: Text.PlainText
            text: root.artist
            color: Qt.darker(root.bar.foreground, 1.3)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
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
            color: Qt.darker(root.bar.foreground, 1.3)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          Item { Layout.fillWidth: true }
          Text {
            text: Api.formatTime(root.ytService ? root.ytService.durationMs : 0)
            color: Qt.darker(root.bar.foreground, 1.3)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }

      // Transport: one filled disc, everything else flat.
      RowLayout {
        width: parent.width
        spacing: 0

        FlatButton {
          iconText: "\u{f049f}"
          selected: !!(root.ytService && root.ytService.shuffle)
          foreground: root.bar.foreground
          tooltipText: "Shuffle"
          onClicked: root.ytService && root.ytService.setShuffle(!root.ytService.shuffle)
        }
        Item { Layout.fillWidth: true }
        FlatButton {
          iconText: "\u{f04ae}"
          iconSize: Style.font.iconLarge
          foreground: root.bar.foreground
          tooltipText: "Previous"
          onClicked: root.ytService && root.ytService.previous()
        }
        Item { Layout.fillWidth: true }
        FlatButton {
          primary: true
          buttonSize: Style.space(52)
          iconSize: Style.font.iconLarge
          iconText: root.playing ? "\u{f03e4}" : "\u{f040a}"
          tooltipText: root.playing ? "Pause" : "Play"
          onClicked: root.ytService && root.ytService.togglePlayback()
        }
        Item { Layout.fillWidth: true }
        FlatButton {
          iconText: "\u{f04ad}"
          iconSize: Style.font.iconLarge
          foreground: root.bar.foreground
          tooltipText: "Next"
          onClicked: root.ytService && root.ytService.next()
        }
        Item { Layout.fillWidth: true }
        FlatButton {
          iconText: root.ytService && root.ytService.repeat === "track" ? "\u{f0458}" : "\u{f0456}"
          selected: root.ytService && root.ytService.repeat !== "off"
          foreground: root.bar.foreground
          tooltipText: "Repeat"
          onClicked: root.ytService && root.ytService.cycleRepeat()
        }
      }

      // Volume and the four view toggles share one row.
      RowLayout {
        width: parent.width
        spacing: Style.space(8)

        Text {
          text: "\u{f057e}"
          textFormat: Text.PlainText
          color: Qt.darker(root.bar.foreground, 1.2)
          font.family: Style.font.family
          font.pixelSize: Style.font.icon
        }
        PanelSlider {
          Layout.fillWidth: true
          minimum: 0
          maximum: 100
          value: root.ytService ? root.ytService.volume : 80
          onMoved: function(v) { if (root.ytService) root.ytService.setVolume(v) }
        }
        FlatButton {
          buttonSize: Style.space(30)
          iconText: "\u{f0567}"
          selected: !!(root.ytService && root.ytService.videoActive)
          enabled: !!(root.ytService && root.ytService.hasTrack)
          foreground: root.bar.foreground
          tooltipText: root.ytService && root.ytService.videoActive ? "Close the video window" : "Watch the video"
          onClicked: root.toggleVideo()
        }
        FlatButton {
          buttonSize: Style.space(30)
          iconText: "\u{f147d}"
          selected: root.ambientEnabled
          foreground: root.bar.foreground
          tooltipText: root.ambientEnabled ? "Hide the spectrum across the bar" : "Show the spectrum across the bar"
          onClicked: root.setAmbient(!root.ambientEnabled)
        }
        FlatButton {
          buttonSize: Style.space(30)
          iconText: "\u{f066a}"
          selected: root.miniEqOpen
          foreground: root.bar.foreground
          tooltipText: root.miniEqOpen ? "Hide equaliser" : "Show equaliser"
          onClicked: root.miniEqOpen = !root.miniEqOpen
        }
        FlatButton {
          buttonSize: Style.space(30)
          iconText: "\u{f03cc}"
          enabled: !!(root.ytService && root.ytService.track && root.ytService.track.videoId)
          foreground: root.bar.foreground
          tooltipText: "Open in browser"
          onClicked: {
            var track = root.ytService ? root.ytService.track : null
            if (!track || !track.videoId) return
            var seconds = Math.floor(Number(root.ytService.positionMs || 0) / 1000)
            var url = "https://www.youtube.com/watch?v=" + encodeURIComponent(track.videoId)
              + (seconds > 5 ? "&t=" + seconds + "s" : "")
            if (root.playing) root.ytService.pause()
            Qt.openUrlExternally(url)
          }
        }
      }

      // Search and the bar-chip switch.
      RowLayout {
        width: parent.width
        spacing: Style.space(8)

        TextField {
          id: miniSearchField
          Layout.fillWidth: true
          placeholderText: root.lastError !== "" ? root.lastError
          : (root.ytService && root.ytService.backendReady ? "Search, or paste a link" : "Starting up…")
          text: root.miniSearchText
          onTextChanged: {
            root.miniSearchText = text
            if (root.miniSearchIsLink) {
              miniLiveSearchTimer.stop()
              if (root.isPlaylistLink(text)) previewTimer.restart()
              else root.miniPreview = null
            } else {
              root.miniPreview = null
              miniLiveSearchTimer.restart()
            }
          }
          onAccepted: {
            miniLiveSearchTimer.stop()
            if (root.miniSearchIsLink) {
              if (root.isPlaylistLink(text)) { root.previewMiniLink(); return }
              root.openMiniLink(); return
            }
            if (root.miniSearchResults.length > 0) root.playSelectedResult()
            else root.runMiniSearch(true)
          }
          Keys.onDownPressed: root.moveMiniSelection(1)
          Keys.onUpPressed: root.moveMiniSelection(-1)
          Keys.onEscapePressed: function(event) { cardScope.forceActiveFocus(); event.accepted = true }
        }
        FlatButton {
          buttonSize: Style.space(36)
          iconText: root.sizeMode === "full" ? "\u{f084c}" : "\u{f084e}"
          selected: root.sizeMode === "full"
          foreground: root.bar.foreground
          tooltipText: root.sizeMode === "full"
            ? "Wide bar chip. Click for compact (icon only)"
            : "Compact bar chip. Click for wide (title and controls)"
          onClicked: root.toggleWide()
        }
      }

      Segmented {
        id: miniTabs
        width: parent.width
        // The equaliser takes the tabs' row too while it is open, so it gets
        // room to breathe and the card still keeps its size.
        visible: !root.miniEqOpen
        foreground: root.bar.foreground
        current: root.miniTab
        model: [
          { key: "next", label: "Up next" },
          { key: "recent", label: "Recent" },
          { key: "lists", label: "Lists" }
        ].concat(root.lyricsEnabled ? [{ key: "lyrics", label: "Lyrics" }] : [])
        onPicked: function(key) { root.miniTab = key; root.miniTabTouched = true; root.clearMiniSearch() }
      }

      // One fixed-height pane. Results, a pasted playlist, the equaliser and
      // the video controls take it over while they are open, so the card
      // itself never changes size.
      Item {
        id: pane
        width: parent.width
        height: root.miniPaneHeight + (root.miniEqOpen ? miniTabs.implicitHeight + column.spacing : 0)
        clip: true

        readonly property bool showOptions: root.miniEqOpen || !!(root.ytService && root.ytService.videoActive)
        readonly property bool showResults: !showOptions && root.miniSearchResults.length > 0
        readonly property bool showPreview: !showOptions && !showResults && root.miniPreview !== null

        // ---- equaliser and video controls
        Flickable {
          anchors.fill: parent
          visible: pane.showOptions
          contentHeight: optionsColumn.implicitHeight
          boundsBehavior: Flickable.StopAtBounds
          ScrollBar.vertical: ScrollBar {}

          Column {
            id: optionsColumn
            width: parent.width
            spacing: Style.space(10)

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

              // The live sound and the ten bands in one control; presets as
              // chips above it.
              EqGraph {
                width: parent.width
                height: pane.height
                compact: true
                service: root.ytService
                foreground: root.bar.foreground
                accent: Color.accent
                fadeTo: Color.popups.background
              }
            }
          }
        }

        // ---- search results
        ListView {
          id: miniResultList
          anchors.fill: parent
          visible: pane.showResults
          model: root.miniSearchResults
          spacing: root.miniRowSpacing
          clip: true
          currentIndex: root.miniSelected
          highlightRangeMode: ListView.ApplyRange
          preferredHighlightBegin: 0
          preferredHighlightEnd: height
          ScrollBar.vertical: ScrollBar {}

          delegate: TrackRow {
            width: miniResultList.width
            item: modelData
            compact: true
            fg: root.bar.foreground
            highlighted: index === root.miniSelected
            onPlayRequested: {
              root.miniSelected = index
              root.playFromSearch(modelData)
            }
            onQueueRequested: root.ytService && root.ytService.addToQueue(modelData)
          }
        }

        // ---- pasted playlist link
        Column {
          anchors.fill: parent
          visible: pane.showPreview
          spacing: Style.space(6)

          RowLayout {
            width: parent.width
            spacing: Style.space(8)
            Column {
              Layout.fillWidth: true
              Text {
                width: parent.width
                text: root.miniPreview ? (root.miniPreview.title || "Playlist") : ""
                textFormat: Text.PlainText
                color: root.bar.foreground
                font.family: Style.font.family
                font.bold: true
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }
              Text {
                text: root.miniPreview ? root.miniPreview.items.length + " tracks" : ""
                color: Qt.darker(root.bar.foreground, 1.3)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
            FlatButton {
              iconText: "\u{f049f}"
              buttonSize: Style.space(32)
              foreground: root.bar.foreground
              tooltipText: "Shuffle the playlist"
              onClicked: root.playMiniPreview(true)
            }
            FlatButton {
              primary: true
              iconText: "\u{f040a}"
              buttonSize: Style.space(36)
              tooltipText: "Play the playlist"
              onClicked: root.playMiniPreview(false)
            }
          }

          ListView {
            width: parent.width
            height: parent.height - Style.space(44)
            clip: true
            spacing: root.miniRowSpacing
            model: root.miniPreview ? root.miniPreview.items : []
            ScrollBar.vertical: ScrollBar {}
            delegate: TrackRow {
              width: ListView.view.width
              item: modelData
              compact: true
              fg: root.bar.foreground
              onPlayRequested: root.ytService && root.ytService.playQueueFrom(root.miniPreview.items, index)
              onQueueRequested: root.ytService && root.ytService.addToQueue(modelData)
            }
          }
        }

        // ---- lyrics
        LyricsView {
          anchors.fill: parent
          visible: !pane.showOptions && !pane.showResults && !pane.showPreview && root.miniTab === "lyrics"
          compact: true
          service: root.ytService
          foreground: root.bar.foreground
          accent: Color.accent
          fadeTo: Color.popups.background
          onOpenPlayerRequested: root.openFullPlayer()
        }

        // ---- tabs
        ListView {
          id: tabList
          anchors.fill: parent
          visible: !pane.showOptions && !pane.showResults && !pane.showPreview && root.miniTab !== "lyrics"
          clip: true
          spacing: root.miniRowSpacing
          ScrollBar.vertical: ScrollBar {}
          model: root.miniTab === "next" ? (root.ytService ? root.ytService.queue : [])
               : root.miniTab === "recent" ? (root.ytService ? root.ytService.playHistory : [])
               : (root.ytService ? root.ytService.playlists : [])

          delegate: Loader {
            width: tabList.width
            sourceComponent: root.miniTab === "lists" ? listRow : trackRowComp
            property var rowData: modelData
            property int rowIndex: index
          }

          Text {
            anchors.centerIn: parent
            visible: tabList.count === 0
            text: root.miniTab === "next" ? "Queue is empty"
                : root.miniTab === "recent" ? "Nothing played yet" : "No playlists yet"
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        Component {
          id: trackRowComp
          TrackRow {
            item: rowData
            compact: true
            fg: root.bar.foreground
            highlighted: root.miniTab === "next" && rowIndex === (root.ytService ? root.ytService.queueIndex : -1)
            queueGlyph: root.miniTab === "next" ? "\u{f0156}" : "\u{f0415}"
            onPlayRequested: {
              if (!root.ytService) return
              if (root.miniTab === "next") root.ytService.playQueueFrom(root.ytService.queue, rowIndex)
              else root.ytService.playNow(rowData)
            }
            onQueueRequested: {
              if (!root.ytService) return
              if (root.miniTab === "next") root.ytService.removeFromQueue(rowIndex)
              else root.ytService.addToQueue(rowData)
            }
          }
        }

        Component {
          id: listRow
          Rectangle {
            height: Style.space(40)
            radius: Style.space(10)
            color: listHover.containsMouse ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"
            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(8)
              spacing: Style.space(10)
              Text {
                text: "\u{f0cb8}"
                font.family: Style.font.family
                font.pixelSize: Style.font.icon
                color: Color.accent
              }
              Text {
                Layout.fillWidth: true
                text: rowData.name
                textFormat: Text.PlainText
                color: root.bar.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }
              Text {
                text: rowData.count + " tracks"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
            MouseArea {
              id: listHover
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                if (!root.ytService) return
                root.ytService.getPlaylist(rowData.id, function(ok, data) {
                  if (ok && data && data.items && data.items.length > 0)
                    root.miniPreview = { title: rowData.name, items: data.items }
                })
              }
            }
          }
        }
      }


      Timer {
        id: miniLiveSearchTimer
        interval: 300
        repeat: false
        onTriggered: root.runMiniSearch(false)
      }

      Timer {
        id: previewTimer
        interval: 450
        repeat: false
        onTriggered: root.previewMiniLink()
      }
    }

    }
    }
  }
}
